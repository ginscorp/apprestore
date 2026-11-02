"""Restricted USB helper. No Apple credentials, arbitrary CLI, network devices or pairing creation."""
import asyncio
import json
import logging
import os
from pathlib import Path
import plistlib
import re
import resource
import socket
import signal
import sys
import tempfile
import zipfile
from safety import SafeError, package_compatibility, require
from archive_data import OFFLINE_ACTIONS, run_offline
from workspace import READ_ACTIONS, WRITE_ACTIONS, run_workspace
from indicators import OFFLINE_ACTIONS as INDICATOR_ACTIONS, run_indicators

sys.dont_write_bytecode = True

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
logging.disable(logging.CRITICAL)


def network_policy(event, args):
    if event in {"socket.bind", "socket.sendto"}:
        # USB developer relays use socketpair(), never an externally reachable listener or UDP.
        raise PermissionError("usb_network_blocked")
    if event == "socket.connect":
        sock, address = args
        if sock.family != socket.AF_UNIX or address not in ("/var/run/usbmuxd", "/private/var/run/usbmuxd"):
            raise PermissionError("usb_network_blocked")
    elif event == "socket.getaddrinfo":
        raise PermissionError("usb_network_blocked")


sys.addaudithook(network_policy)


def valid_udid(value):
    return isinstance(value, str) and bool(re.fullmatch(r"[A-Fa-f0-9-]{8,64}", value))


def valid_package(value):
    # Only packages produced by our download engine; no directory installs or arbitrary file reads.
    if not isinstance(value, str):
        return None
    p = Path(value)
    if p.name != "application.ipa" or not p.parent.name.startswith("apprestore-session-") or p.is_symlink() or p.parent.is_symlink():
        return None
    resolved = p.resolve(strict=True)
    if Path(tempfile.gettempdir()).resolve() not in resolved.parents:
        return None
    if not p.is_file() or p.stat().st_size < 100 or p.stat().st_size > 4 * 1024**3:
        return None
    try:
        with zipfile.ZipFile(p) as package:
            infos = [f for f in package.infolist() if f.filename.startswith("Payload/") and f.filename.count("/") == 2 and f.filename.endswith(".app/Info.plist")]
            if len(infos) != 1 or infos[0].file_size > 4 * 1024**2:
                return None
            info = plistlib.loads(package.read(infos[0]))
            executable = info.get("CFBundleExecutable")
            if not isinstance(executable, str) or "/" in executable or "\\" in executable:
                return None
            prefix = infos[0].filename.removesuffix("Info.plist")
            if not any(f.filename.startswith(prefix) and f.filename.endswith(".sinf") and 0 < f.file_size < 2 * 1024**2 for f in package.infolist()):
                return None
    except (OSError, ValueError, zipfile.BadZipFile, plistlib.InvalidFileException):
        return None
    return p


async def run(request, pairing_dir):
    from pymobiledevice3 import usbmux
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    action = request.get("action")
    if action in INDICATOR_ACTIONS:
        return await asyncio.to_thread(run_indicators, request)
    if action in OFFLINE_ACTIONS:
        return await asyncio.to_thread(run_offline, request, emit)
    if action == "selftest":
        return {"transport": "usb_only", "autopair": False, "pymobiledevice3": "11.41.2"}
    if action not in {"devices", "apps", "install", "package_check"} | READ_ACTIONS | WRITE_ACTIONS:
        raise ValueError("unsupported_action")
    devices = [d for d in await usbmux.list_devices(usbmux_address="/var/run/usbmuxd") if d.is_usb]
    if action == "devices":
        result = []
        for dev in devices:
            try:
                async with await create_using_usbmux(dev.serial, autopair=False, connection_type="USB", pairing_records_cache_folder=pairing_dir, usbmux_address="/var/run/usbmuxd") as ld:
                    info = ld.short_info
                    result.append({"udid": dev.serial, "name": str(info.get("DeviceName") or "iPhone")[:120], "model": str(info.get("ProductType") or ""), "ios": str(info.get("ProductVersion") or ""), "build": str(ld.all_values.get("BuildVersion") or ""), "paired": bool(ld.paired)})
            except Exception:
                result.append({"udid": dev.serial, "name": "iPhone", "model": "", "ios": "", "paired": False})
        return {"devices": result}
    udid = request.get("udid")
    if not valid_udid(udid) or not any(d.serial == udid for d in devices):
        raise ValueError("device_not_found")
    async with await create_using_usbmux(udid, autopair=False, connection_type="USB", pairing_records_cache_folder=pairing_dir, usbmux_address="/var/run/usbmuxd") as ld:
        if not ld.paired:
            raise ValueError("not_paired")
        if action in {"apps"} | READ_ACTIONS | WRITE_ACTIONS:
            return await run_workspace(request, ld, emit)
        async with InstallationProxyService(lockdown=ld) as proxy:
            if action == "install" and request.get("confirmed") is not True:
                raise ValueError("confirmation_required")
            package = valid_package(request.get("path"))
            if package is None:
                raise ValueError("invalid_package")
            with zipfile.ZipFile(package) as archive:
                entry = next(f for f in archive.infolist() if f.filename.startswith("Payload/") and f.filename.count("/") == 2 and f.filename.endswith(".app/Info.plist"))
                metadata = plistlib.loads(archive.read(entry))
            # Fresh device connection, actual IPA requirements. Catalog metadata is insufficient.
            compatible = package_compatibility(metadata, str(ld.product_version), str(ld.all_values.get("DeviceClass", "")))
            if action == "package_check":
                return compatible
            expected = request.get("compatibility")
            require(isinstance(expected, dict) and expected == compatible, "installation_plan_changed")
            await proxy.install_from_local(package)
            return {"installed": True, **compatible}


def emit(event):
    sys.stdout.write(json.dumps(event, ensure_ascii=False) + "\n")
    sys.stdout.flush()


async def cancellable_run(request, directory, timeout):
    loop = asyncio.get_running_loop()
    task = asyncio.current_task()
    loop.add_signal_handler(signal.SIGTERM, task.cancel)
    try:
        return await asyncio.wait_for(run(request, directory), timeout=timeout)
    except asyncio.CancelledError:
        raise SafeError("operation_cancelled") from None
    finally:
        loop.remove_signal_handler(signal.SIGTERM)


def main():
    try:
        line = sys.stdin.buffer.readline(524289)
        if len(line) > 524288:
            raise ValueError("invalid_request")
        request = json.loads(line)
        if not isinstance(request, dict):
            raise ValueError("invalid_request")
        # Existing pairing is read from usbmuxd, never copied to a permanent application folder.
        with tempfile.TemporaryDirectory(prefix="apprestore-usb-") as tmp:
            action=request.get("action")
            timeout=28800 if action=="backup_create" else 7200 if action=="media_stream" else 3600 if action in {"file_export","file_upload","archive_export"} else 1800 if action=="install" else 180 if action in OFFLINE_ACTIONS | INDICATOR_ACTIONS else 75 if action=="storage_settings" else 60 if action=="inventory" else 45
            result = asyncio.run(cancellable_run(request, Path(tmp), timeout))
        response = {"ok": True, "data": result}
    except Exception as error:
        allowed = {"invalid_request", "unsupported_action", "device_not_found", "not_paired", "confirmation_required", "invalid_package", "usb_network_blocked"}
        code = str(error) if str(error) in allowed or isinstance(error, SafeError) and re.fullmatch(r"[a-z_]{1,64}",str(error)) else "usb_failed"
        if "ApplicationVerificationFailed" in str(error):
            code = "verification_failed"
        response = {"ok": False, "error": code}
    sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
