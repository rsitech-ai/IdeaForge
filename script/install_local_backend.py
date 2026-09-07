#!/usr/bin/env python3
"""Install or remove the user LaunchAgent without deleting backend data."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from local_backend.config import LocalBackendConfig, LocalBackendConfigError


LABEL = "com.rsitech.ideaforge.local-backend"


def _atomic_write(path: Path, contents: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(contents)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, path)
    finally:
        Path(temporary_name).unlink(missing_ok=True)


def _install_runtime(data_root: Path, backend_script: Path) -> Path:
    source_script = backend_script.expanduser().resolve()
    source_package = source_script.parents[1] / "local_backend"
    if source_script.is_symlink() or not source_script.is_file():
        raise LocalBackendConfigError("Backend runtime source is unavailable")
    package_files = sorted(source_package.glob("*.py"))
    if source_package.is_symlink() or not source_package.is_dir() or not package_files:
        raise LocalBackendConfigError("Backend runtime package is unavailable")
    if any(path.is_symlink() or not path.is_file() for path in package_files):
        raise LocalBackendConfigError("Backend runtime package is unsafe")

    digest = hashlib.sha256()
    sources = [(Path("script/local_backend.py"), source_script)] + [
        (Path("local_backend") / path.name, path) for path in package_files
    ]
    for relative_path, source in sources:
        digest.update(str(relative_path).encode("utf-8"))
        digest.update(b"\0")
        digest.update(source.read_bytes())
    version = digest.hexdigest()[:16]
    runtime_root = data_root / "runtime"
    runtime_root.mkdir(exist_ok=True, mode=0o700)
    os.chmod(runtime_root, 0o700)
    destination = runtime_root / version
    deployed_script = destination / "script" / "local_backend.py"
    if destination.exists():
        if destination.is_symlink() or not deployed_script.is_file():
            raise LocalBackendConfigError("Installed backend runtime is unsafe")
        return deployed_script

    staging = Path(tempfile.mkdtemp(prefix=".runtime-", dir=runtime_root))
    try:
        for relative_path, source in sources:
            target = staging / relative_path
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            target.write_bytes(source.read_bytes())
            os.chmod(target, 0o700 if relative_path == Path("script/local_backend.py") else 0o600)
        os.replace(staging, destination)
        return deployed_script
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def _activate(plist_path: Path, install: bool) -> None:
    domain = f"gui/{os.getuid()}"
    if install:
        subprocess.run(["launchctl", "bootout", domain, str(plist_path)], capture_output=True)
        subprocess.run(["launchctl", "bootstrap", domain, str(plist_path)], check=True)
        subprocess.run(["launchctl", "kickstart", "-k", f"{domain}/{LABEL}"], check=True)
    else:
        subprocess.run(["launchctl", "bootout", domain, str(plist_path)], capture_output=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    install = subparsers.add_parser("install")
    uninstall = subparsers.add_parser("uninstall")
    for command in (install, uninstall):
        command.add_argument("--plist-path", type=Path, required=True)
        command.add_argument("--no-activate", action="store_true")
    install.add_argument("--data-root", type=Path, required=True)
    install.add_argument("--python", type=Path, required=True)
    install.add_argument("--backend-script", type=Path, required=True)
    install.add_argument("--workspace-id", required=True)
    install.add_argument("--bind-host", required=True)
    install.add_argument("--allowed-cidrs", required=True)
    install.add_argument("--tls-cert", type=Path, required=True)
    install.add_argument("--tls-key", type=Path, required=True)
    install.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    plist_path = args.plist_path.expanduser().resolve()

    if args.command == "uninstall":
        if not args.no_activate and plist_path.exists():
            _activate(plist_path, False)
        plist_path.unlink(missing_ok=True)
        print(json.dumps({"status": "uninstalled", "dataPreserved": True}, sort_keys=True, separators=(",", ":")))
        return 0

    data_root = args.data_root.expanduser().resolve()
    python_path = args.python.expanduser().absolute()
    if not python_path.is_file() or not os.access(python_path, os.X_OK):
        print(json.dumps({"error": "runtime_install_error"}, separators=(",", ":")))
        return 2
    data_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(data_root, 0o700)
    logs = data_root / "logs"
    logs.mkdir(exist_ok=True, mode=0o700)
    os.chmod(logs, 0o700)
    environment = {
        "IDEAFORGE_LOCAL_BACKEND_DATA_ROOT": str(data_root),
        "IDEAFORGE_LOCAL_BACKEND_WORKSPACE_ID": args.workspace_id,
        "IDEAFORGE_LOCAL_BACKEND_BIND_HOST": args.bind_host,
        "IDEAFORGE_LOCAL_BACKEND_ALLOWED_CIDRS": args.allowed_cidrs,
        "IDEAFORGE_LOCAL_BACKEND_TLS_CERT": str(args.tls_cert.expanduser().resolve()),
        "IDEAFORGE_LOCAL_BACKEND_TLS_KEY": str(args.tls_key.expanduser().resolve()),
        "IDEAFORGE_LOCAL_BACKEND_PORT": str(args.port),
    }
    try:
        LocalBackendConfig.load(environment)
    except LocalBackendConfigError:
        print(json.dumps({"error": "configuration_error"}, separators=(",", ":")))
        return 2
    try:
        deployed_backend_script = _install_runtime(data_root, args.backend_script)
    except (LocalBackendConfigError, OSError):
        print(json.dumps({"error": "runtime_install_error"}, separators=(",", ":")))
        return 2
    _atomic_write(
        data_root / "runtime-config.json",
        json.dumps(environment, sort_keys=True, separators=(",", ":")).encode("utf-8"),
    )
    payload = {
        "Label": LABEL,
        "ProgramArguments": [str(python_path), str(deployed_backend_script), "serve"],
        "EnvironmentVariables": environment,
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 10,
        "ProcessType": "Background",
        "SoftResourceLimits": {"NumberOfFiles": 1024},
        "StandardOutPath": str(logs / "service.stdout.log"),
        "StandardErrorPath": str(logs / "service.stderr.log"),
    }
    _atomic_write(plist_path, plistlib.dumps(payload, sort_keys=True))
    if not args.no_activate:
        _activate(plist_path, True)
    print(json.dumps({"status": "installed", "activated": not args.no_activate}, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
