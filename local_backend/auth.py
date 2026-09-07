"""Single-use device pairing and revocable authorization."""

from __future__ import annotations

import hashlib
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from .database import LocalBackendDatabase


class PairingCodeInvalidError(ValueError):
    """Raised when a pairing code is missing, consumed, or otherwise invalid."""


class PairingCodeExpiredError(PairingCodeInvalidError):
    """Raised when a pairing code is valid but expired."""


class DeviceUnauthorizedError(PermissionError):
    """Raised when a device token is missing, invalid, or revoked."""


class DeviceForbiddenError(PermissionError):
    """Raised when a valid device token is used outside its workspace scope."""


@dataclass(frozen=True)
class PairingCode:
    value: str
    expires_at: datetime


@dataclass(frozen=True)
class IssuedDeviceToken:
    device_id: str
    workspace_id: str
    token: str


@dataclass(frozen=True)
class AuthorizedDevice:
    device_id: str
    workspace_id: str
    label: str


@dataclass(frozen=True)
class RegisteredDevice:
    device_id: str
    label: str
    revoked: bool


def _utc(value: datetime) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("Timestamp must include a timezone")
    return value.astimezone(UTC)


def _timestamp(value: datetime) -> str:
    return _utc(value).isoformat(timespec="seconds").replace("+00:00", "Z")


def _parse_timestamp(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _validated_label(value: str) -> str:
    normalized = " ".join(value.split())
    if not normalized or len(normalized) > 80 or any(ord(character) < 32 for character in normalized):
        raise ValueError("Device label must contain 1 to 80 visible characters")
    return normalized


class PairingService:
    def __init__(self, database: LocalBackendDatabase, workspace_id: str) -> None:
        self.database = database
        self.workspace_id = workspace_id

    def create_code(self, label: str, now: datetime) -> PairingCode:
        normalized_label = _validated_label(label)
        created_at = _utc(now)
        expires_at = created_at + timedelta(minutes=5)
        clear_code = secrets.token_urlsafe(16)
        with self.database.transaction() as connection:
            connection.execute(
                """
                INSERT INTO pairing_codes(
                    code_digest, workspace_id, label, created_at, expires_at, consumed_at
                ) VALUES (?, ?, ?, ?, ?, NULL)
                """,
                (
                    _digest(clear_code),
                    self.workspace_id,
                    normalized_label,
                    _timestamp(created_at),
                    _timestamp(expires_at),
                ),
            )
        return PairingCode(value=clear_code, expires_at=expires_at)

    def exchange(self, code: str, device_label: str, now: datetime) -> IssuedDeviceToken:
        normalized_code = code.strip()
        if not normalized_code or len(normalized_code) > 256:
            raise PairingCodeInvalidError("Pairing code is invalid")
        normalized_label = _validated_label(device_label)
        exchanged_at = _utc(now)
        code_digest = _digest(normalized_code)
        with self.database.transaction() as connection:
            row = connection.execute(
                """
                SELECT code_digest, workspace_id, expires_at, consumed_at
                FROM pairing_codes
                WHERE code_digest = ?
                """,
                (code_digest,),
            ).fetchone()
            if row is None or not secrets.compare_digest(code_digest, row["code_digest"]):
                raise PairingCodeInvalidError("Pairing code is invalid")
            if row["consumed_at"] is not None:
                raise PairingCodeInvalidError("Pairing code is invalid")
            if exchanged_at > _parse_timestamp(row["expires_at"]):
                raise PairingCodeExpiredError("Pairing code expired")

            consumed = connection.execute(
                """
                UPDATE pairing_codes
                SET consumed_at = ?
                WHERE code_digest = ? AND consumed_at IS NULL
                """,
                (_timestamp(exchanged_at), code_digest),
            )
            if consumed.rowcount != 1:
                raise PairingCodeInvalidError("Pairing code is invalid")

            clear_token = secrets.token_urlsafe(32)
            device_id = f"device_{secrets.token_hex(16)}"
            connection.execute(
                """
                INSERT INTO devices(
                    device_id, workspace_id, token_digest, label, created_at, last_used_at, revoked_at
                ) VALUES (?, ?, ?, ?, ?, NULL, NULL)
                """,
                (
                    device_id,
                    row["workspace_id"],
                    _digest(clear_token),
                    normalized_label,
                    _timestamp(exchanged_at),
                ),
            )
        return IssuedDeviceToken(
            device_id=device_id,
            workspace_id=row["workspace_id"],
            token=clear_token,
        )


class DeviceAuthorizer:
    def __init__(self, database: LocalBackendDatabase) -> None:
        self.database = database

    def authorize(self, token: str, workspace_id: str, now: datetime) -> AuthorizedDevice:
        if not token or len(token) > 512:
            raise DeviceUnauthorizedError("Device authorization failed")
        token_digest = _digest(token)
        with self.database.transaction() as connection:
            row = connection.execute(
                """
                SELECT device_id, workspace_id, token_digest, label, revoked_at
                FROM devices
                WHERE token_digest = ?
                """,
                (token_digest,),
            ).fetchone()
            if (
                row is None
                or not secrets.compare_digest(token_digest, row["token_digest"])
                or row["revoked_at"] is not None
            ):
                raise DeviceUnauthorizedError("Device authorization failed")
            if not secrets.compare_digest(workspace_id, row["workspace_id"]):
                raise DeviceForbiddenError("Workspace authorization failed")
            connection.execute(
                "UPDATE devices SET last_used_at = ? WHERE device_id = ? AND revoked_at IS NULL",
                (_timestamp(now), row["device_id"]),
            )
        return AuthorizedDevice(
            device_id=row["device_id"],
            workspace_id=row["workspace_id"],
            label=row["label"],
        )

    def revoke(self, device_id: str, now: datetime) -> bool:
        with self.database.transaction() as connection:
            result = connection.execute(
                """
                UPDATE devices
                SET revoked_at = ?
                WHERE device_id = ? AND revoked_at IS NULL
                """,
                (_timestamp(now), device_id),
            )
        return result.rowcount == 1

    def list_devices(self, workspace_id: str) -> list[RegisteredDevice]:
        with self.database.connection() as connection:
            rows = connection.execute(
                """
                SELECT device_id, label, revoked_at FROM devices
                WHERE workspace_id = ? ORDER BY created_at, device_id
                """,
                (workspace_id,),
            ).fetchall()
        return [
            RegisteredDevice(
                device_id=row["device_id"],
                label=row["label"],
                revoked=row["revoked_at"] is not None,
            )
            for row in rows
        ]
