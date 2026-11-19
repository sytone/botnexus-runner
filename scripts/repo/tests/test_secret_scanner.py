"""Smoke-test the pinned Gitleaks CLI supplied by the workflow action."""

from __future__ import annotations

import hashlib
import shutil
import subprocess
import tempfile
from pathlib import Path
import unittest


@unittest.skipUnless(shutil.which("gitleaks"), "Gitleaks is installed by the CI action")
class GitleaksSmokeTests(unittest.TestCase):
    def scan_directory(self, directory: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["gitleaks", "dir", str(directory), "--redact", "--exit-code", "2"],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_detects_synthetic_token_and_accepts_documented_example(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            unsafe = root / "unsafe"
            safe = root / "safe"
            unsafe.mkdir()
            safe.mkdir()
            token = "ghp_" + hashlib.sha256(b"publication guard test fixture").hexdigest()[:36]
            (unsafe / "sample.txt").write_text("token=" + token, encoding="utf-8")
            (safe / "example.txt").write_text(
                "https://api.example.invalid token=replace-me", encoding="utf-8"
            )

            rejected = self.scan_directory(unsafe)
            self.assertEqual(2, rejected.returncode)
            self.assertNotIn(token, rejected.stdout + rejected.stderr)
            self.assertEqual(0, self.scan_directory(safe).returncode)


if __name__ == "__main__":
    unittest.main()
