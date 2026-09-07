#!/usr/bin/env python3
"""Provision a private CA and HTTPS certificate for the LAN backend."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import ssl
import subprocess
import tempfile
import uuid
from pathlib import Path


def _run(arguments: list[str]) -> str:
    result = subprocess.run(arguments, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        raise RuntimeError("Certificate command failed")
    return result.stdout.strip()


def _report(root: Path, hostname: str, status: str) -> dict[str, str]:
    certificate = root / "server.cert.pem"
    fingerprint = _run(["openssl", "x509", "-in", str(certificate), "-noout", "-fingerprint", "-sha256"])
    expiry = _run(["openssl", "x509", "-in", str(certificate), "-noout", "-enddate"])
    return {
        "status": status,
        "hostname": hostname,
        "caCertificatePath": str(root / "ca.cert.pem"),
        "iPhoneConfigurationProfilePath": str(root / "ideaforge-local-ca.mobileconfig"),
        "serverCertificatePath": str(certificate),
        "sha256Fingerprint": fingerprint.split("=", 1)[1],
        "notAfter": expiry.split("=", 1)[1],
    }


def _write_iphone_profile(root: Path) -> None:
    certificate_pem = (root / "ca.cert.pem").read_text(encoding="ascii")
    certificate_der = ssl.PEM_cert_to_DER_cert(certificate_pem)
    fingerprint = hashlib.sha256(certificate_der).hexdigest()
    identifier = f"com.rsitech.ideaforge.local-ca.{fingerprint[:16]}"
    namespace = uuid.UUID("a752e2a1-ec8e-43ef-b109-104c3620732a")
    root_uuid = str(uuid.uuid5(namespace, f"{identifier}.root")).upper()
    profile_uuid = str(uuid.uuid5(namespace, identifier)).upper()
    payload = {
        "PayloadContent": [
            {
                "PayloadContent": certificate_der,
                "PayloadDisplayName": "IdeaForge Local CA",
                "PayloadIdentifier": f"{identifier}.root",
                "PayloadType": "com.apple.security.root",
                "PayloadUUID": root_uuid,
                "PayloadVersion": 1,
            }
        ],
        "PayloadDescription": "Trust the operator-owned CA for the IdeaForge private-LAN backend.",
        "PayloadDisplayName": "IdeaForge Local Backend CA",
        "PayloadIdentifier": identifier,
        "PayloadOrganization": "RSI Tech",
        "PayloadRemovalDisallowed": False,
        "PayloadType": "Configuration",
        "PayloadUUID": profile_uuid,
        "PayloadVersion": 1,
    }
    profile_path = root / "ideaforge-local-ca.mobileconfig"
    staging = Path(tempfile.mkdtemp(prefix=".profile-", dir=root))
    try:
        unsigned_path = staging / "profile.plist"
        signed_path = staging / "profile.mobileconfig"
        unsigned_path.write_bytes(plistlib.dumps(payload, fmt=plistlib.FMT_XML, sort_keys=True))
        _run([
            "openssl", "smime", "-sign", "-binary", "-nodetach",
            "-signer", str(root / "ca.cert.pem"),
            "-inkey", str(root / "ca.key.pem"),
            "-in", str(unsigned_path),
            "-out", str(signed_path),
            "-outform", "der",
        ])
        os.chmod(signed_path, 0o600)
        os.replace(signed_path, profile_path)
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def _validate_existing(root: Path, hostname: str) -> None:
    for name in ("ca.key.pem", "ca.cert.pem", "server.key.pem", "server.cert.pem"):
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise RuntimeError("TLS state is unsafe")
    _run(["openssl", "x509", "-in", str(root / "server.cert.pem"), "-noout", "-checkhost", hostname])
    _run(["openssl", "verify", "-CAfile", str(root / "ca.cert.pem"), str(root / "server.cert.pem")])
    certificate_key = _run(["openssl", "x509", "-in", str(root / "server.cert.pem"), "-pubkey", "-noout"])
    private_key = _run(["openssl", "pkey", "-in", str(root / "server.key.pem"), "-pubout"])
    if certificate_key != private_key:
        raise RuntimeError("TLS key does not match certificate")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tls-root", type=Path, required=True)
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--install-mac-trust", action="store_true")
    args = parser.parse_args()
    root = args.tls_root.expanduser().resolve()
    hostname = args.hostname.strip().lower()
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+", hostname):
        raise SystemExit("invalid hostname")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(root, 0o700)
    names = ("ca.key.pem", "ca.cert.pem", "server.key.pem", "server.cert.pem")
    existing = [root / name for name in names if (root / name).exists()]
    if existing:
        if len(existing) != len(names):
            raise SystemExit("incomplete TLS state")
        try:
            _validate_existing(root, hostname)
            _write_iphone_profile(root)
        except (OSError, RuntimeError):
            return 1
        report = _report(root, hostname, "existing")
        if args.install_mac_trust:
            _run([
                "security", "add-trusted-cert", "-d", "-r", "trustRoot",
                "-k", str(Path.home() / "Library/Keychains/login.keychain-db"),
                str(root / "ca.cert.pem"),
            ])
        report["macTrustInstalled"] = args.install_mac_trust
        print(json.dumps(report, sort_keys=True, separators=(",", ":")))
        return 0

    staging = Path(tempfile.mkdtemp(prefix=".tls-", dir=root))
    try:
        ca_key = staging / "ca.key.pem"
        ca_cert = staging / "ca.cert.pem"
        server_key = staging / "server.key.pem"
        server_csr = staging / "server.csr.pem"
        server_cert = staging / "server.cert.pem"
        extension = staging / "server.ext"
        extension.write_text(
            "basicConstraints=critical,CA:FALSE\n"
            "keyUsage=critical,digitalSignature,keyEncipherment\n"
            "extendedKeyUsage=serverAuth\n"
            f"subjectAltName=DNS:{hostname}\n",
            encoding="utf-8",
        )
        _run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:3072", "-out", str(ca_key)])
        _run(["openssl", "req", "-x509", "-new", "-sha256", "-key", str(ca_key), "-days", "3650", "-subj", "/CN=IdeaForge Local CA", "-out", str(ca_cert)])
        _run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:3072", "-out", str(server_key)])
        _run(["openssl", "req", "-new", "-sha256", "-key", str(server_key), "-subj", f"/CN={hostname}", "-out", str(server_csr)])
        _run(["openssl", "x509", "-req", "-sha256", "-in", str(server_csr), "-CA", str(ca_cert), "-CAkey", str(ca_key), "-CAcreateserial", "-days", "397", "-extfile", str(extension), "-out", str(server_cert)])
        for name in names:
            source = staging / name
            os.chmod(source, 0o600)
            os.replace(source, root / name)
        _write_iphone_profile(root)
        report = _report(root, hostname, "created")
        if args.install_mac_trust:
            _run([
                "security", "add-trusted-cert", "-d", "-r", "trustRoot",
                "-k", str(Path.home() / "Library/Keychains/login.keychain-db"),
                str(root / "ca.cert.pem"),
            ])
        report["macTrustInstalled"] = args.install_mac_trust
        print(json.dumps(report, sort_keys=True, separators=(",", ":")))
        return 0
    except (OSError, RuntimeError):
        return 1
    finally:
        shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
