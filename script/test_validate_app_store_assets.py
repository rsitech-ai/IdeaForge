#!/usr/bin/env python3
"""Regression tests for App Store and public-source asset validation."""

from __future__ import annotations

import unittest

from validate_app_store_assets import parse_accessed_api_reasons


class PrivacyManifestValidationTests(unittest.TestCase):
    def test_parses_required_reason_declarations(self) -> None:
        reasons = parse_accessed_api_reasons(
            {
                "NSPrivacyAccessedAPITypes": [
                    {
                        "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryDiskSpace",
                        "NSPrivacyAccessedAPITypeReasons": ["E174.1"],
                    },
                    {
                        "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                        "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
                    },
                ]
            }
        )

        self.assertEqual(reasons["NSPrivacyAccessedAPICategoryDiskSpace"], {"E174.1"})
        self.assertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], {"CA92.1"})

    def test_rejects_non_array_accessed_api_value(self) -> None:
        with self.assertRaisesRegex(ValueError, "must be an array"):
            parse_accessed_api_reasons({"NSPrivacyAccessedAPITypes": "invalid"})

    def test_rejects_non_dictionary_entry(self) -> None:
        with self.assertRaisesRegex(ValueError, "must be dictionaries"):
            parse_accessed_api_reasons({"NSPrivacyAccessedAPITypes": ["invalid"]})

    def test_rejects_non_string_reason(self) -> None:
        with self.assertRaisesRegex(ValueError, "string reason array"):
            parse_accessed_api_reasons(
                {
                    "NSPrivacyAccessedAPITypes": [
                        {
                            "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryDiskSpace",
                            "NSPrivacyAccessedAPITypeReasons": [174],
                        }
                    ]
                }
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
