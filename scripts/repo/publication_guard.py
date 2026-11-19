#!/usr/bin/env python3
"""Reject likely private data before repository publication without printing it."""

from __future__ import annotations

import argparse
import io
import ipaddress
import re
import subprocess
import sys
from pathlib import Path


PRIVATE_COMPONENTS = {
    ".azure",
    ".ssh",
    "artifacts",
    "credentials",
    "logs",
    "private",
    "private-data",
    "receipts",
    "secrets",
}
PRIVATE_SUFFIXES = (
    ".pem",
    ".p12",
    ".pfx",
    ".key",
    ".tfstate",
    ".tfvars",
    ".kubeconfig",
    ".log",
    ".auth",
)
EXAMPLE_SUFFIXES = (".example", ".sample", ".template")
SENSITIVE_VALUE_KEYS = re.compile(
    r"(?i)\b(?:access[_-]?token|api[_-]?key|client[_-]?secret|"
    r"connection[_-]?string|password|private[_-]?key|refresh[_-]?token)\b"
    r"(?:[\"']\s*:\s*[\"']|:\s+[\"']?|=\s*[\"']?)([^\s,;\"'}\]]+)"
)
PLACEHOLDER_VALUE = re.compile(
    r"(?i)^(?:example|<[^>]+>|\$\{[^}]+\}|\$[\w:.-]+|"
    r"your[-_][\w-]*|replace[-_][\w-]*|change[-_][\w-]*|"
    r"synthetic[-_][\w-]*|todo|placeholder|dummy|redacted|none|null)$"
)
EMAIL = re.compile(
    r"(?i)(?<![\w.+-])[\w.!#$%&'*+/=?^_`{|}~-]+@"
    r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"[a-z]{2,63}\b"
)
PHONE = re.compile(
    r"(?<!\d)(?:\+?1[\s.-]?)?\(?([2-9]\d{2})\)?[\s.-]"
    r"([2-9]\d{2})[\s.-](\d{4})(?!\d)"
)
URL_HOST = re.compile(r"(?i)\bhttps?://([^/\s:?#]+)(?::\d+)?")
INTERNAL_HOST = re.compile(
    r"(?i)\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\."
    r"(?:corp|internal|intranet|lan|local)(?::\d+)?"
    r"(?=$|[\s/?#),;]|[.!?](?:\s|$))"
)
PRIVATE_IP = re.compile(
    r"(?<![\w.])(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|"
    r"172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})(?::\d{1,5})?(?![\w./])"
)
INTERNAL_SUFFIX = re.compile(r"(?i)(?:^|\.)(?:corp|internal|intranet|lan|local)$")
EXAMPLE_EMAIL_DOMAINS = ("example.com", "example.org", "example.net", "example.invalid")


def _is_documentation_number(value: str) -> bool:
    _, exchange, line = value
    return exchange == "555" and line.startswith("01")


def _is_private_host(host: str) -> bool:
    try:
        return ipaddress.ip_address(host).is_private
    except ValueError:
        return bool(INTERNAL_SUFFIX.search(host))


def _identifier_rules(value: str) -> set[str]:
    rules: set[str] = set()
    for match in EMAIL.finditer(value):
        domain = match.group(0).rsplit("@", 1)[1].lower()
        if not any(domain == allowed or domain.endswith("." + allowed) for allowed in EXAMPLE_EMAIL_DOMAINS):
            rules.add("personal-email")
    for match in PHONE.finditer(value):
        if not _is_documentation_number(match.groups()):
            rules.add("personal-phone")
    return rules


def _redact_location(location: str) -> str:
    return PHONE.sub("[redacted-personal-phone]", EMAIL.sub("[redacted-personal-email]", location))


def _path_rule(relative: Path) -> str | None:
    parts = [part.lower() for part in relative.parts]
    name = parts[-1]
    if any(part in PRIVATE_COMPONENTS for part in parts):
        return "private-path"

    if name == ".env" or (name.startswith(".env.") and name != ".env.example"):
        return "live-config-path"

    if name.endswith(PRIVATE_SUFFIXES) or ".tfstate." in name or name in {
        "id_rsa",
        "id_ed25519",
        "credentials.json",
        "auth.json",
    }:
        return "credential-path"

    if name.endswith((".json", ".yaml", ".yml", ".toml")) and any(
        word in name for word in ("profile", "parameters", "live-config")
    ):
        stem = name.rsplit(".", 1)[0]
        if not stem.endswith(EXAMPLE_SUFFIXES):
            return "live-config-path"

    return None


def _line_rules(line: str) -> set[str]:
    rules = _identifier_rules(line)

    if any(_is_private_host(match.group(1).lower()) for match in URL_HOST.finditer(line)):
        rules.add("internal-endpoint")
    if INTERNAL_HOST.search(line):
        rules.add("internal-endpoint")
    if any(_is_private_host(match.group(0).split(":")[0]) for match in PRIVATE_IP.finditer(line)):
        rules.add("internal-endpoint")

    for match in SENSITIVE_VALUE_KEYS.finditer(line):
        value = match.group(1)
        if not PLACEHOLDER_VALUE.fullmatch(value) and not value.startswith(
            ("$", "process.env.", "os.environ", "env:")
        ):
            rules.add("credential-value")

    return rules


def scan(root: Path) -> list[tuple[str, str, int | None]]:
    findings: set[tuple[str, str, int | None]] = set()
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if ".git" in relative.parts:
            continue

        location = _redact_location(relative.as_posix())
        rule = _path_rule(relative)
        if rule:
            findings.add((rule, location, None))
        for path_rule in _identifier_rules(relative.as_posix()):
            findings.add((path_rule, location, None))
        if path.is_dir() or path.is_symlink():
            if path.is_symlink():
                findings.add(("symlink", location, None))
            continue

        try:
            content = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            continue
        for line_number, line in enumerate(content.splitlines(), start=1):
            for line_rule in _line_rules(line):
                findings.add((line_rule, location, line_number))

    return sorted(findings, key=lambda finding: (finding[1], finding[2] or 0, finding[0]))


def scan_history(root: Path) -> list[tuple[str, str, int | None]]:
    def git(*args: str, input: bytes | None = None) -> bytes:
        return subprocess.run(
            ["git", "-C", str(root), *args],
            input=input,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=True,
        ).stdout

    if git("rev-parse", "--is-shallow-repository").strip() == b"true":
        raise ValueError("complete Git history is required")

    revisions = git("rev-list", "--all").decode("ascii").splitlines()
    entries: list[tuple[str, str, str, bool]] = []
    blob_ids: set[str] = set()
    findings: set[tuple[str, str, int | None]] = set()
    for revision in revisions:
        tree = git("ls-tree", "-r", "-z", "--full-tree", revision)
        for record in tree.split(b"\0"):
            if not record:
                continue
            metadata, raw_path = record.split(b"\t", 1)
            mode, object_type, object_id = metadata.decode("ascii").split()
            path = raw_path.decode("utf-8", errors="replace")
            is_symlink = mode == "120000"
            if object_type == "blob":
                entries.append((revision, path, object_id, is_symlink))
                blob_ids.add(object_id)
            else:
                location = _redact_location(f"{revision[:12]}:{path}")
                findings.add(("unscanned-history-object", location, None))
                for path_rule in _identifier_rules(path):
                    findings.add((path_rule, location, None))

    batch_input = "".join(f"{object_id}\n" for object_id in sorted(blob_ids)).encode("ascii")
    response = io.BytesIO(git("cat-file", "--batch", input=batch_input))
    blobs: dict[str, bytes] = {}
    for object_id in sorted(blob_ids):
        header = response.readline().decode("ascii").split()
        if len(header) != 3 or header[0] != object_id or header[1] != "blob":
            raise ValueError("unable to read Git history")
        content = response.read(int(header[2]))
        response.readline()
        blobs[object_id] = content

    for revision, path, object_id, is_symlink in entries:
        relative = Path(path)
        location = _redact_location(f"{revision[:12]}:{path}")
        rule = _path_rule(relative)
        if rule:
            findings.add((rule, location, None))
        for path_rule in _identifier_rules(path):
            findings.add((path_rule, location, None))
        if is_symlink:
            findings.add(("symlink", location, None))
        try:
            content = blobs[object_id].decode("utf-8")
        except UnicodeError:
            continue
        for line_number, line in enumerate(content.splitlines(), start=1):
            for line_rule in _line_rules(line):
                findings.add((line_rule, location, line_number))

    return sorted(findings, key=lambda finding: (finding[1], finding[2] or 0, finding[0]))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--history", action="store_true")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    if not root.is_dir():
        parser.error("--root must be an existing directory")

    findings = scan(root)
    if args.history:
        try:
            findings.extend(scan_history(root))
        except (OSError, subprocess.CalledProcessError, ValueError):
            print("publication guard: complete Git history could not be scanned", file=sys.stderr)
            return 2
    for rule, path, line in findings:
        location = f"{path}:{line}" if line is not None else path
        print(f"publication guard: {rule} at {location}", file=sys.stderr)
    if findings:
        print(
            f"publication guard: rejected {len(findings)} finding(s); "
            "sensitive values are never displayed",
            file=sys.stderr,
        )
        return 1
    print("publication guard: no configured privacy findings")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
