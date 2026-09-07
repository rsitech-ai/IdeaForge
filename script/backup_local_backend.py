#!/usr/bin/env python3
"""Create a verified local backend backup."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from local_backend.database import LocalBackendDatabase
from local_backend.operations import LocalBackupManager


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", type=Path, required=True)
    parser.add_argument("--backup-parent", type=Path, required=True)
    args = parser.parse_args()
    data_root = args.data_root.expanduser().resolve()
    destination = LocalBackupManager(
        data_root,
        LocalBackendDatabase(data_root / "backend.sqlite3"),
    ).create(args.backup_parent.expanduser().resolve(), datetime.now(UTC))
    print(json.dumps({"status": "created", "backupPath": str(destination)}, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
