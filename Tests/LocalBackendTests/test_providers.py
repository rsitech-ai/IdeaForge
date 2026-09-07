import sys
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from local_backend.providers import (
    ExternalProviderDisabledError,
    ExternalProviderKeyUnavailableError,
    ExternalProviderPolicy,
)


class ExternalProviderPolicyTests(unittest.TestCase):
    def test_openai_is_disabled_by_default_and_local_capabilities_remain(self) -> None:
        policy = ExternalProviderPolicy(openai_enabled=False, openai_key_loader=lambda: "should-not-load")

        self.assertEqual(policy.capabilities(), {"localSync": True, "openAI": False})
        with self.assertRaises(ExternalProviderDisabledError):
            policy.authorize_explicit_request("openai")

    def test_enabled_openai_requires_key_and_explicit_provider_selection(self) -> None:
        missing = ExternalProviderPolicy(openai_enabled=True, openai_key_loader=lambda: None)
        with self.assertRaises(ExternalProviderKeyUnavailableError):
            missing.authorize_explicit_request("openai")

        available = ExternalProviderPolicy(openai_enabled=True, openai_key_loader=lambda: "sk-local-secret")
        self.assertEqual(available.capabilities(), {"localSync": True, "openAI": True})
        with self.assertRaises(ExternalProviderDisabledError):
            available.authorize_explicit_request("automatic")
        credential = available.authorize_explicit_request("openai")
        self.assertEqual(credential, "sk-local-secret")


if __name__ == "__main__":
    unittest.main()
