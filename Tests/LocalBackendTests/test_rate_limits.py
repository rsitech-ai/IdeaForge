import sys
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from local_backend.database import LocalBackendDatabase
from local_backend.rate_limits import PersistentRateLimiter


NOW = datetime(2026, 8, 14, 15, 0, tzinfo=UTC)


class PersistentRateLimiterTests(unittest.TestCase):
    def test_limit_is_persistent_private_and_expires_at_window_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            database = LocalBackendDatabase(Path(temporary_directory) / "state" / "backend.sqlite3")
            database.migrate()
            limiter = PersistentRateLimiter(database)

            first = limiter.consume("device-secret-value", "workspace_read", 2, 60, NOW)
            second = limiter.consume("device-secret-value", "workspace_read", 2, 60, NOW)
            restarted = PersistentRateLimiter(database)
            denied = restarted.consume(
                "device-secret-value", "workspace_read", 2, 60, NOW + timedelta(seconds=1)
            )
            allowed_again = restarted.consume(
                "device-secret-value", "workspace_read", 2, 60, NOW + timedelta(seconds=60)
            )

            self.assertTrue(first.allowed)
            self.assertTrue(second.allowed)
            self.assertFalse(denied.allowed)
            self.assertEqual(denied.retry_after_seconds, 59)
            self.assertTrue(allowed_again.allowed)
            self.assertNotIn(b"device-secret-value", database.path.read_bytes())


if __name__ == "__main__":
    unittest.main()
