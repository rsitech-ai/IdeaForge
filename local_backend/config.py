"""Fail-closed configuration for the production-local backend."""

from __future__ import annotations

import ipaddress
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping


class LocalBackendConfigError(ValueError):
    """Raised when local-backend configuration is unsafe or incomplete."""


def _required(environment: Mapping[str, str], name: str) -> str:
    value = environment.get(name, "").strip()
    if not value:
        raise LocalBackendConfigError(f"{name} is required")
    return value


def _absolute_dedicated_path(value: str, name: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute() or path in {Path("/"), Path("/tmp"), Path("/var/tmp")}:
        raise LocalBackendConfigError(f"{name} must be a dedicated absolute directory")
    return path


def _absolute_file_path(value: str, name: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        raise LocalBackendConfigError(f"{name} must be an absolute path")
    return path


def _parse_port(value: str) -> int:
    try:
        port = int(value)
    except ValueError as error:
        raise LocalBackendConfigError("IDEAFORGE_LOCAL_BACKEND_PORT must be an integer") from error
    if port < 1 or port > 65_535:
        raise LocalBackendConfigError("IDEAFORGE_LOCAL_BACKEND_PORT must be between 1 and 65535")
    return port


def _parse_cidrs(value: str) -> tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, ...]:
    networks: list[ipaddress.IPv4Network | ipaddress.IPv6Network] = []
    for raw_network in value.split(","):
        candidate = raw_network.strip()
        if not candidate:
            continue
        try:
            network = ipaddress.ip_network(candidate, strict=False)
        except ValueError as error:
            raise LocalBackendConfigError(
                "IDEAFORGE_LOCAL_BACKEND_ALLOWED_CIDRS contains an invalid network"
            ) from error
        if network.prefixlen == 0 or not (network.is_private or network.is_loopback):
            raise LocalBackendConfigError(
                "IDEAFORGE_LOCAL_BACKEND_ALLOWED_CIDRS must contain only bounded private or loopback networks"
            )
        networks.append(network)
    if not networks:
        raise LocalBackendConfigError("IDEAFORGE_LOCAL_BACKEND_ALLOWED_CIDRS is required")
    return tuple(networks)


def _parse_bind_host(value: str) -> str:
    try:
        address = ipaddress.ip_address(value)
    except ValueError as error:
        raise LocalBackendConfigError(
            "IDEAFORGE_LOCAL_BACKEND_BIND_HOST must be a literal private or loopback address"
        ) from error
    if address.is_unspecified or not (address.is_private or address.is_loopback):
        raise LocalBackendConfigError(
            "IDEAFORGE_LOCAL_BACKEND_BIND_HOST must be a private or loopback address"
        )
    return str(address)


@dataclass(frozen=True)
class LocalBackendConfig:
    data_root: Path
    workspace_id: str
    bind_host: str
    allowed_cidrs: tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, ...]
    tls_certificate_path: Path
    tls_private_key_path: Path
    port: int = 8_765
    workspace_body_limit_bytes: int = 10 * 1024 * 1024
    recording_body_limit_bytes: int = 200 * 1024 * 1024
    openai_enabled: bool = False

    @property
    def database_path(self) -> Path:
        return self.data_root / "backend.sqlite3"

    @classmethod
    def load(cls, environment: Mapping[str, str]) -> "LocalBackendConfig":
        data_root = _absolute_dedicated_path(
            _required(environment, "IDEAFORGE_LOCAL_BACKEND_DATA_ROOT"),
            "IDEAFORGE_LOCAL_BACKEND_DATA_ROOT",
        )
        workspace_id = _required(environment, "IDEAFORGE_LOCAL_BACKEND_WORKSPACE_ID")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{2,127}", workspace_id):
            raise LocalBackendConfigError(
                "IDEAFORGE_LOCAL_BACKEND_WORKSPACE_ID has an unsupported format"
            )
        bind_host = _parse_bind_host(
            environment.get("IDEAFORGE_LOCAL_BACKEND_BIND_HOST", "127.0.0.1").strip()
        )
        allowed_cidrs = _parse_cidrs(
            environment.get("IDEAFORGE_LOCAL_BACKEND_ALLOWED_CIDRS", "127.0.0.0/8")
        )
        tls_certificate_path = _absolute_file_path(
            _required(environment, "IDEAFORGE_LOCAL_BACKEND_TLS_CERT"),
            "IDEAFORGE_LOCAL_BACKEND_TLS_CERT",
        )
        tls_private_key_path = _absolute_file_path(
            _required(environment, "IDEAFORGE_LOCAL_BACKEND_TLS_KEY"),
            "IDEAFORGE_LOCAL_BACKEND_TLS_KEY",
        )
        port = _parse_port(environment.get("IDEAFORGE_LOCAL_BACKEND_PORT", "8765"))
        openai_enabled = environment.get("IDEAFORGE_LOCAL_BACKEND_OPENAI_ENABLED", "0") == "1"
        return cls(
            data_root=data_root,
            workspace_id=workspace_id,
            bind_host=bind_host,
            allowed_cidrs=allowed_cidrs,
            tls_certificate_path=tls_certificate_path,
            tls_private_key_path=tls_private_key_path,
            port=port,
            openai_enabled=openai_enabled,
        )
