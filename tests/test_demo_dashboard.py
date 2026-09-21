"""The recording's graphs must reflect executable queries, not scripted outcomes."""

import importlib.util
from pathlib import Path
import shutil
import sqlite3
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts/demo/dashboard"
spec = importlib.util.spec_from_file_location("dashboard", SOURCE / "app.py")
dashboard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dashboard)


class DashboardDemoTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        for name in ("error-rate.sql", "failed-checkouts.sql"):
            shutil.copyfile(SOURCE / name, self.directory / name)
        dashboard.seed(self.directory / "demo.sqlite")

    def test_spike_requires_query_grain_investigation(self):
        rate, failures = dashboard.dashboard(self.directory)["panels"]
        self.assertEqual(
            [row["error_rate"] for row in rate["rows"]], [2.0] * 6 + [10.91] * 6
        )
        self.assertTrue(
            all(
                row["failed"] == 20 and row["total"] == 1000 for row in failures["rows"]
            )
        )
        with sqlite3.connect(self.directory / "demo.sqlite") as database:
            before, after = [
                row[0]
                for row in database.execute("""
                SELECT COUNT(*) FROM checkout_events e JOIN checkouts c ON c.id = e.checkout_id
                GROUP BY c.minute >= '14:30' ORDER BY c.minute >= '14:30'
            """)
            ]
        self.assertEqual((before, after), (6000, 6600))

    def test_editing_the_actual_sql_changes_the_live_chart(self):
        query = "SELECT minute, ROUND(100.0 * SUM(outcome = 'failed') / COUNT(*), 2) AS error_rate FROM checkouts GROUP BY minute ORDER BY minute"
        (self.directory / "error-rate.sql").write_text(query)
        result = dashboard.dashboard(self.directory)["panels"][0]
        self.assertEqual(result["query"], query)
        self.assertEqual([row["error_rate"] for row in result["rows"]], [2.0] * 12)

    def test_a_refresh_does_not_reset_agent_changes_or_reseed_data(self):
        with sqlite3.connect(self.directory / "demo.sqlite") as database:
            database.execute(
                "DELETE FROM checkout_events WHERE event_type = 'retry_logged'"
            )
        dashboard.seed(self.directory / "demo.sqlite")
        self.assertTrue(
            all(
                row["error_rate"] == 2.0
                for row in dashboard.dashboard(self.directory)["panels"][0]["rows"]
            )
        )

    def test_chart_requests_cannot_mutate_the_database(self):
        (self.directory / "error-rate.sql").write_text("DELETE FROM checkouts")
        with self.assertRaises(sqlite3.OperationalError):
            dashboard.dashboard(self.directory)


if __name__ == "__main__":
    unittest.main()
