"""Regression tests for publication checks; all unsafe values are synthetic."""

from __future__ import annotations

import contextlib
import io
from pathlib import Path
import subprocess
import tempfile
import unittest

from scripts.repo.publication_guard import main, scan, scan_history


class PublicationGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, name: str, content: str) -> None:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def assert_rejected(self, name: str, content: str, rule: str) -> None:
        self.write(name, content)
        findings = scan(self.root)
        self.assertIn(rule, {finding[0] for finding in findings})

    def test_rejects_private_paths_and_live_configuration(self) -> None:
        self.assert_rejected("secrets/deployment.json", "{}", "private-path")
        self.assert_rejected("target.profile.json", "{}", "live-config-path")
        self.assert_rejected("operator.pem", "not a real key", "credential-path")

    def test_rejects_internal_endpoints_without_printing_values(self) -> None:
        endpoint = "https://10." + "24.8.9/service"
        hostname = "build." + "corp"
        self.write("notes.txt", endpoint + " " + hostname)
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            self.assertEqual(1, main(["--root", str(self.root)]))
        self.assertIn("internal-endpoint", output.getvalue())
        self.assertNotIn(endpoint, output.getvalue())
        self.assertNotIn(hostname, output.getvalue())

    def test_rejects_credential_values_without_printing_them(self) -> None:
        key = "pass" + "word"
        value = "unsafe-fixture-credential"
        self.write("settings.yml", f'{key}: "{value}"')
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            self.assertEqual(1, main(["--root", str(self.root)]))
        self.assertIn("credential-value", output.getvalue())
        self.assertNotIn(value, output.getvalue())

    def test_rejects_non_example_personal_identifiers(self) -> None:
        email = "fixture.user@" + "sample.invalid"
        phone = "+1 555-" + "867-5309"
        self.assert_rejected("contact.txt", email, "personal-email")
        self.assert_rejected("contact.txt", phone, "personal-phone")

    def test_redacts_personal_identifiers_in_paths(self) -> None:
        email = "fixture.user@" + "sample.invalid"
        self.write(f"contacts/{email}.txt", "synthetic fixture")
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            self.assertEqual(1, main(["--root", str(self.root)]))
        self.assertIn("personal-email", output.getvalue())
        self.assertIn("[redacted-personal-email]", output.getvalue())
        self.assertNotIn(email, output.getvalue())

    def test_accepts_documented_examples_and_placeholders(self) -> None:
        self.write(
            "docs/example.txt",
            "https://api.example.invalid/v1 192.0.2.10 "
            "user@example.com +1-202-555-0100\n"
            'password: "replace-me"\n',
        )
        self.write("target.profile.example.json", '{"password":"replace-me"}')
        self.assertEqual([], scan(self.root))

    def test_history_guard_rejects_data_removed_from_current_tree(self) -> None:
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.name", "Fixture"], check=True)
        subprocess.run(
            ["git", "-C", str(self.root), "config", "user.email", "fixture@example.invalid"],
            check=True,
        )
        historical_email = "fixture.user@" + "sample.invalid"
        self.write("notes.txt", historical_email)
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", "synthetic fixture"], check=True)
        self.write("notes.txt", "user@example.com")
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", "replace fixture"], check=True)

        self.assertEqual([], scan(self.root))
        findings = scan_history(self.root)
        self.assertIn("personal-email", {finding[0] for finding in findings})
        self.assertNotIn(historical_email, repr(findings))

    def test_history_guard_redacts_removed_personal_identifier_paths(self) -> None:
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.name", "Fixture"], check=True)
        subprocess.run(
            ["git", "-C", str(self.root), "config", "user.email", "fixture@example.invalid"],
            check=True,
        )
        email = "fixture.user@" + "sample.invalid"
        historical_path = self.root / f"{email}.txt"
        historical_path.write_text("synthetic fixture", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", "synthetic path"], check=True)
        historical_path.unlink()
        self.write("notes.txt", "safe example")
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", "remove synthetic path"], check=True)

        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            self.assertEqual(1, main(["--root", str(self.root), "--history"]))
        self.assertIn("personal-email", output.getvalue())
        self.assertIn("[redacted-personal-email]", output.getvalue())
        self.assertNotIn(email, output.getvalue())


if __name__ == "__main__":
    unittest.main()
