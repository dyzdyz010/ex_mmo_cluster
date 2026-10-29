"""只测试：缺失字段堆诊断必须明确缺失，不能当作零字节或整轮通过。"""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import compare


class CompareMemoryScopeTest(unittest.TestCase):
    def report(self, heap):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "probe").mkdir()
            (root / "startup.json").write_text(json.dumps({"ready_seconds": 1, "startup_peak_rss_sum": 1000}))
            (root / "idle.json").write_text(json.dumps({"field_heap": heap}))
            (root / "os.jsonl").write_text(json.dumps({"rss_sum": 2000}) + "\n")
            (root / "probe/events.jsonl").write_text("")
            output = io.StringIO()
            with patch("sys.argv", ["compare.py", str(root)]), contextlib.redirect_stdout(output):
                compare.main()
            return output.getvalue()

    def test_safe_summary_reports_unavailable_field_breakdown(self):
        text = self.report({"total_heap_mb": 2.0, "process_memory_mb": 2.1,
                            "stats": {"resident_pages": 5, "retained_transactions": 2},
                            "field_breakdown": {"status": "unavailable", "reason": "full-state copy disabled"}})
        self.assertIn("field breakdown unavailable", text)
        self.assertIn("full-state copy disabled", text)
        self.assertNotIn("prefabs 0", text)

    def test_absent_legacy_top_field_is_not_reported_as_zero(self):
        text = self.report({"seq": 1, "total_heap_mb": 2.0, "epochs": 3,
                            "top_fields_mb": {"refined": 1.0}})
        self.assertIn("prefabs unavailable", text)
        self.assertNotIn("prefabs 0", text)


if __name__ == "__main__":
    unittest.main()
