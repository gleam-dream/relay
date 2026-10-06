"""Counterexamples for upstream empty/skipped/failed server result acceptance."""

import json
from pathlib import Path
import tempfile
import unittest

import check_conformance_results as conformance


class ConformanceTest(unittest.TestCase):
    def result(self, directory, name, checks, suffix="2026-10-06T19-43-00-001Z"):
        folder = directory / f"server-{name}-{suffix}"
        folder.mkdir()
        (folder / "checks.json").write_text(json.dumps(checks))
        return folder

    def test_realistic_success_counts_info_separately(self):
        zero = "input-required-result-missing-input-response"
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            self.result(
                directory, "tools-list", [{"status": "SUCCESS"}, {"status": "INFO"}]
            )
            self.result(directory, zero, [{"status": "SUCCESS"}])
            summary = conformance.summarize(directory, ("tools-list", zero))
            self.assertTrue(summary["accepted"])
            self.assertEqual(summary["checks"]["SUCCESS"], 2)
            self.assertEqual(summary["zero_check_non_evidence"], [])

    def test_empty_suite_and_info_only_cannot_pass(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            self.assertFalse(conformance.summarize(directory, ())["accepted"])
            self.result(directory, "tools-list", [{"status": "INFO"}])
            self.assertFalse(
                conformance.summarize(directory, ("tools-list",))["accepted"]
            )

    def test_missing_skipped_or_unexpected_empty_case_cannot_pass(self):
        for checks in (None, [], [{"status": "SKIPPED"}]):
            with self.subTest(checks=checks), tempfile.TemporaryDirectory() as folder:
                directory = Path(folder)
                self.result(directory, "server-stateless", [{"status": "SUCCESS"}])
                if checks is not None:
                    self.result(directory, "tools-list", checks)
                self.assertFalse(
                    conformance.summarize(
                        directory, ("server-stateless", "tools-list")
                    )["accepted"]
                )

    def test_failed_warning_malformed_and_duplicate_results_cannot_pass(self):
        for checks in (
            [{"status": "FAILURE"}],
            [{"status": "WARNING"}],
            {},
            [{"status": "unknown"}],
            [{"status": []}],
        ):
            with self.subTest(checks=checks), tempfile.TemporaryDirectory() as folder:
                directory = Path(folder)
                self.result(directory, "tools-list", checks)
                self.assertFalse(
                    conformance.summarize(directory, ("tools-list",))["accepted"]
                )
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            self.result(directory, "tools-list", [{"status": "SUCCESS"}])
            self.result(
                directory,
                "tools-list",
                [{"status": "SUCCESS"}],
                "2026-10-06T19-43-00-002Z",
            )
            self.assertFalse(
                conformance.summarize(directory, ("tools-list",))["accepted"]
            )

    def test_selection_is_complete_nonempty_and_unique(self):
        self.assertEqual(
            conformance.selection(
                "Server scenarios (test against a server):\n  - tools-list [2026-07-28]\n"
            ),
            ("tools-list",),
        )
        for text in (
            "",
            "Server scenarios (test against a server):\n",
            "  - tools-list\n  - tools-list\n",
            "not a selection",
        ):
            with self.subTest(text=text), self.assertRaises(ValueError):
                conformance.selection(text)


if __name__ == "__main__":
    unittest.main()
