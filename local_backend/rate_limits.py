"""Persistent privacy-safe rate limits for private-LAN operations."""

from __future__ import annotations

import hashlib
import math
from dataclasses import dataclass
from datetime import UTC, datetime

from .database import LocalBackendDatabase


@dataclass(frozen=True)
class RateLimitDecision:
    allowed: bool
    retry_after_seconds: int = 0


@dataclass(frozen=True)
class RateLimitPolicy:
    workspace_reads_per_minute: int = 120
    workspace_writes_per_minute: int = 30
    uploads_per_hour: int = 20
    pairing_attempts_per_five_minutes: int = 10


class PersistentRateLimiter:
    def __init__(self, database: LocalBackendDatabase) -> None:
        self.database = database

    def consume(
        self,
        scope: str,
        category: str,
        limit: int,
        window_seconds: int,
        now: datetime,
    ) -> RateLimitDecision:
        if not scope or not category or limit < 1 or window_seconds < 1:
            raise ValueError("Rate limit inputs are invalid")
        if now.tzinfo is None or now.utcoffset() is None:
            raise ValueError("Timestamp must include a timezone")
        scope_digest = hashlib.sha256(scope.encode("utf-8")).hexdigest()
        current = now.astimezone(UTC).timestamp()
        cutoff = current - window_seconds
        with self.database.transaction() as connection:
            connection.execute(
                "DELETE FROM rate_limit_events WHERE occurred_at <= ?",
                (cutoff,),
            )
            rows = connection.execute(
                """
                SELECT occurred_at FROM rate_limit_events
                WHERE scope_digest = ? AND category = ? AND occurred_at > ?
                ORDER BY occurred_at LIMIT ?
                """,
                (scope_digest, category, cutoff, limit),
            ).fetchall()
            if len(rows) >= limit:
                retry_after = max(1, math.ceil(rows[0]["occurred_at"] + window_seconds - current))
                return RateLimitDecision(False, min(window_seconds, retry_after))
            connection.execute(
                "INSERT INTO rate_limit_events(scope_digest, category, occurred_at) VALUES (?, ?, ?)",
                (scope_digest, category, current),
            )
            return RateLimitDecision(True)
