"""Resource policy regression tests; no guest boot required."""
import contextlib
import io
import unittest
from unittest.mock import mock_open, patch

import check


class BudgetPolicy(unittest.TestCase):
    def result(self, overrides=None, missing=None):
        values = {key: limit for key, _, limit, _, _ in check.CHECKS}
        values.update(overrides or {})
        if missing:
            del values[missing]
        log = "".join(f"[budget] {key} {value}\n" for key, value in values.items())
        with patch("builtins.open", mock_open(read_data=log)), contextlib.redirect_stdout(io.StringIO()):
            return check.main("synthetic.log")

    def test_exact_ceiling_passes(self):
        self.assertEqual(self.result(), 0)

    def test_ram_over_ceiling_fails(self):
        self.assertEqual(self.result({"mem.used_bytes": check.RAM_BUDGET_MIB * check.MB + 1}), 1)

    def test_expensive_ui_is_advisory(self):
        self.assertEqual(self.result({"idle.busy_pct_x100": 7500, "image.total_bytes": 8 * check.MB}), 0)

    def test_missing_measurements_fail(self):
        self.assertEqual(self.result(missing="mem.used_bytes"), 1)
        self.assertEqual(self.result(missing="idle.busy_pct_x100"), 1)


if __name__ == "__main__":
    unittest.main()
