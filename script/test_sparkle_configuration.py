#!/usr/bin/env python3
"""Fail-closed validation for IdeaForge's sandboxed Sparkle configuration."""

from __future__ import annotations

import base64
import binascii
import hashlib
import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECT_PATH = ROOT / "project.yml"
INFO_PLIST_PATH = ROOT / "Sources/IdeaForgeMac/Info.plist"
ENTITLEMENTS_PATH = ROOT / "Sources/IdeaForgeMac/IdeaForgeMac.entitlements"
PACKAGE_SWIFT_PATH = ROOT / "Package.swift"
APP_UPDATER_PATH = ROOT / "Sources/IdeaForgeMac/AppUpdater.swift"
MAC_APP_PATH = ROOT / "Sources/IdeaForgeMac/IdeaForgeMacApp.swift"
IOS_INFO_PLIST_PATH = ROOT / "Sources/IdeaForgeiOS/Info.plist"
WATCH_INFO_PLIST_PATH = ROOT / "Sources/IdeaForgeWatch/Info.plist"
SPARKLE_LICENSE_PATH = ROOT / "ThirdPartyLicenses/Sparkle-2.9.4-LICENSE.txt"
SPARKLE_REVISION = "b6496a74a087257ef5e6da1c5b29a447a60f5bd7"
SPARKLE_LICENSE_SHA256 = "389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe"


def yaml_block(source: str, heading: str, indent: int) -> str:
    prefix = " " * indent
    marker = f"{prefix}{heading}:"
    lines = source.splitlines()
    try:
        start = lines.index(marker)
    except ValueError as error:
        raise AssertionError(f"Missing YAML heading: {heading}") from error

    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        line_indent = len(line) - len(line.lstrip())
        if line_indent <= indent:
            end = index
            break
    return "\n".join(lines[start:end])


class SparkleConfigurationTests(unittest.TestCase):
    def test_sparkle_is_pinned_to_secure_mac_only_configuration(self) -> None:
        project = PROJECT_PATH.read_text(encoding="utf-8")
        packages = yaml_block(project, "packages", 0)
        sparkle_package = yaml_block(packages, "Sparkle", 2)
        self.assertRegex(
            sparkle_package,
            r"(?m)^    url: https://github\.com/sparkle-project/Sparkle$",
        )
        self.assertRegex(
            sparkle_package,
            rf'(?m)^    revision: "?{SPARKLE_REVISION}"? # Sparkle 2\.9\.4$',
        )
        self.assertNotRegex(sparkle_package, r"(?m)^    (from|version|branch|exactVersion):")

        mac_target = yaml_block(project, "IdeaForgeMac", 2)
        self.assertRegex(mac_target, r"(?m)^      - package: Sparkle$")
        self.assertRegex(mac_target, r"(?m)^        product: Sparkle$")

        non_mac_targets = (
            "IdeaForgeiOS",
            "IdeaForgeWatch",
            "IdeaForgeMacUITests",
            "IdeaForgeiOSUITests",
        )
        for target in non_mac_targets:
            self.assertNotIn("package: Sparkle", yaml_block(project, target, 2), target)
        self.assertNotIn("Sparkle", PACKAGE_SWIFT_PATH.read_text(encoding="utf-8"))

        with INFO_PLIST_PATH.open("rb") as plist_file:
            info = plistlib.load(plist_file)
        self.assertEqual(info.get("CFBundleShortVersionString"), "$(MARKETING_VERSION)")
        self.assertEqual(info.get("CFBundleVersion"), "$(CURRENT_PROJECT_VERSION)")
        self.assertEqual(
            info.get("SUFeedURL"),
            "https://raw.githubusercontent.com/rsitech-ai/IdeaForge/main/updates/appcast.xml",
        )
        self.assertIs(info.get("SUEnableInstallerLauncherService"), True)
        self.assertNotIn("SUEnableDownloaderService", info)

        public_key = info.get("SUPublicEDKey")
        self.assertIsInstance(public_key, str)
        try:
            decoded_public_key = base64.b64decode(public_key, validate=True)
        except (binascii.Error, ValueError, TypeError) as error:
            self.fail(f"SUPublicEDKey is not valid base64: {error}")
        self.assertEqual(
            len(decoded_public_key),
            32,
            "SUPublicEDKey must encode a 32-byte EdDSA public key",
        )

        for plist_path in (IOS_INFO_PLIST_PATH, WATCH_INFO_PLIST_PATH):
            with plist_path.open("rb") as plist_file:
                platform_info = plistlib.load(plist_file)
            self.assertEqual(platform_info.get("CFBundleShortVersionString"), "$(MARKETING_VERSION)")
            self.assertEqual(platform_info.get("CFBundleVersion"), "$(CURRENT_PROJECT_VERSION)")

        self.assertEqual(
            hashlib.sha256(SPARKLE_LICENSE_PATH.read_bytes()).hexdigest(),
            SPARKLE_LICENSE_SHA256,
        )
        notices = (ROOT / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8")
        self.assertIn("ThirdPartyLicenses/Sparkle-2.9.4-LICENSE.txt", notices)

        with ENTITLEMENTS_PATH.open("rb") as plist_file:
            entitlements = plistlib.load(plist_file)
        self.assertIs(entitlements.get("com.apple.security.app-sandbox"), True)
        self.assertIs(entitlements.get("com.apple.security.network.client"), True)
        self.assertEqual(
            entitlements.get("com.apple.security.temporary-exception.mach-lookup.global-name"),
            [
                "$(PRODUCT_BUNDLE_IDENTIFIER)-spks",
                "$(PRODUCT_BUNDLE_IDENTIFIER)-spki",
            ],
        )

    def test_updater_lifecycle_and_command_suppress_ui_test_startup(self) -> None:
        self.assertTrue(APP_UPDATER_PATH.is_file(), "AppUpdater.swift must exist")
        updater_source = APP_UPDATER_PATH.read_text(encoding="utf-8")
        self.assertIn("import Sparkle", updater_source)
        self.assertRegex(updater_source, r"final class AppUpdater\s*\{")
        self.assertRegex(updater_source, r"init\(startingUpdater: Bool = true\)")
        self.assertRegex(
            updater_source,
            r"SPUStandardUpdaterController\(\s*startingUpdater: startingUpdater,\s*"
            r"updaterDelegate: nil,\s*userDriverDelegate: nil\s*\)",
        )
        self.assertRegex(updater_source, r"func checkForUpdates\(\)\s*\{")
        self.assertIn("updaterController.checkForUpdates(nil)", updater_source)

        app_source = MAC_APP_PATH.read_text(encoding="utf-8")
        self.assertIn('!ProcessInfo.processInfo.arguments.contains("-uiTesting")', app_source)
        self.assertIn("AppUpdater(startingUpdater: startingUpdater)", app_source)
        self.assertIn('Button("Check for Updates…")', app_source)
        self.assertIn("appUpdater.checkForUpdates()", app_source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
