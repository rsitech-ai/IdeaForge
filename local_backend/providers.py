"""Fail-closed policy for optional external providers."""

from __future__ import annotations

from collections.abc import Callable


class ExternalProviderDisabledError(RuntimeError):
    """Raised when a request does not explicitly select an enabled provider."""


class ExternalProviderKeyUnavailableError(RuntimeError):
    """Raised when an enabled provider has no credential in local Keychain."""


class ExternalProviderPolicy:
    def __init__(self, *, openai_enabled: bool, openai_key_loader: Callable[[], str | None]) -> None:
        self.openai_enabled = openai_enabled
        self._openai_key_loader = openai_key_loader

    def _available_openai_key(self) -> str | None:
        if not self.openai_enabled:
            return None
        key = self._openai_key_loader()
        return key if key and key.strip() else None

    def capabilities(self) -> dict[str, bool]:
        return {"localSync": True, "openAI": self._available_openai_key() is not None}

    def authorize_explicit_request(self, provider: str) -> str:
        if provider != "openai" or not self.openai_enabled:
            raise ExternalProviderDisabledError("External provider is disabled")
        key = self._available_openai_key()
        if key is None:
            raise ExternalProviderKeyUnavailableError("OpenAI credential is unavailable")
        return key
