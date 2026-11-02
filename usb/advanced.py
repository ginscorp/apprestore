"""Explicit, bounded USB utilities. Never mounts developer images or changes pairing/settings."""
import base64
from contextlib import AsyncExitStack, asynccontextmanager
import hashlib
import html
import json
import os
import struct
import sys
import tempfile

from safety import OutputJob, SafeError, output_parent, plan_digest, remote_path, require, safe_name, version_tuple

READ_ACTIONS = {"home_layout", "developer_status", "screen_capture"}
WRITE_ACTIONS = {"home_export_plan", "home_export", "crash_export_plan", "crash_export", "launch_plan", "launch_app"}


def normalized_layout(raw):
    require(isinstance(raw, list) and len(raw) <= 100, "unsupported_home_layout")
    count = 0
    unknown = 0

    def node(value, depth, path):
        nonlocal count, unknown
        count += 1
        require(count <= 2500 and depth <= 8, "home_layout_limit")
        if isinstance(value, list):
            require(len(value) <= 2500, "home_layout_limit")
            return {"id": path, "name": "Section " + path, "kind": "section", "bundle": "",
                    "children": [node(v, depth + 1, path + "." + str(i + 1)) for i, v in enumerate(value)]}
        require(isinstance(value, dict), "unsupported_home_layout")
        bundle = value.get("bundleIdentifier") or value.get("displayIdentifier") or ""
        if not isinstance(bundle, str) or len(bundle) > 240:
            bundle = ""
        name = value.get("displayName") or value.get("name") or bundle or "Unknown"
        name = str(name)[:240]
        children = value.get("iconLists")
        if isinstance(children, list):
            require(len(children) <= 100, "home_layout_limit")
            return {"id": path, "name": name, "kind": "folder", "bundle": "",
                    "children": [node(v, depth + 1, path + "." + str(i + 1)) for i, v in enumerate(children)]}
        kind = "app" if bundle else "unsupported"
        if not bundle:
            unknown += 1
        return {"id": path, "name": name, "kind": kind, "bundle": bundle, "children": None}

    return {"items": [node(v, 0, str(i + 1)) for i, v in enumerate(raw)], "count": count,
            "unsupported": unknown, "restorable": False}


async def home(ld):
    from pymobiledevice3.services.springboard import SpringBoardServicesService
    async with SpringBoardServicesService(ld) as service:
        result = normalized_layout(await service.get_icon_state(format_version="2"))
    return {**result, "ios": str(ld.product_version)}


async def developer_status(ld):
    result = {"ios": str(ld.product_version), "usb_tunnel_supported": version_tuple(str(ld.product_version)) >= version_tuple("17.4"),
              "developer_mode": "unknown", "image_mounted": "unknown", "settings_changed": False}
    try:
        value = await ld.get_developer_mode_status()
        if isinstance(value, bool):
            result["developer_mode"] = "enabled" if value else "disabled"
    except Exception:
        pass
    try:
        from pymobiledevice3.services.mobile_image_mounter import MobileImageMounterService, image_type_for_device
        async with MobileImageMounterService(ld) as service:
            value = await service.is_image_mounted(image_type_for_device(ld))
            result["image_mounted"] = "mounted" if value else "not_mounted"
    except Exception:
        pass
    return result


@asynccontextmanager
async def developer_rsd(ld):
    """Reuse the caller's trusted USB connection; no Wi-Fi fallback, listener or pairing creation."""
    from private_backup import WriteBoundary, temporary_files_in
    from pymobiledevice3.remote import userspace_tunnel as userspace, tunnel_service
    from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
    status = await developer_status(ld)
    require(status["usb_tunnel_supported"], "developer_ios_unsupported")
    require(status["developer_mode"] != "disabled", "developer_mode_required")
    with tempfile.TemporaryDirectory(prefix="apprestore-developer-") as temporary:
        os.chmod(temporary, 0o700)
        boundary = WriteBoundary(temporary, temporary)
        sys.addaudithook(boundary)
        try:
            with temporary_files_in(temporary):
                async with userspace._lifecycle_lock():
                    tunnel_service.USE_USERSPACE_TUNNEL = True
                    try:
                        async with AsyncExitStack() as stack:
                            provider = await tunnel_service.CoreDeviceTunnelProxy.create(ld)
                            stack.push_async_callback(provider.close)
                            result = await stack.enter_async_context(provider.start_tcp_tunnel())
                            tun = result.client.tun
                            tun.set_peer(result.address)
                            plane = await stack.enter_async_context(userspace.UserspaceDialPlane(tun, result.address))
                            rsd = RemoteServiceDiscoveryService((result.address, result.port), open_connection=plane.dial,
                                                                 auxiliary_metadata=result.auxiliary_metadata)
                            stack.push_async_callback(rsd.close)
                            await rsd.connect()
                            normalized = lambda value: str(value).replace("-", "").lower()
                            require(normalized(rsd.udid) == normalized(ld.udid), "device_identity_mismatch")
                            userspace.USERSPACE_ACTIVE = True
                            yield rsd
                    finally:
                        userspace.USERSPACE_ACTIVE = False
                        tunnel_service.USE_USERSPACE_TUNNEL = False
        finally:
            boundary.active = False


def screenshot_result(data):
    require(isinstance(data, bytes) and 24 <= len(data) <= 8 * 1024 ** 2 and data.startswith(b"\x89PNG\r\n\x1a\n"), "invalid_screenshot")
    width, height = struct.unpack(">II", data[16:24])
    require(0 < width <= 20000 and 0 < height <= 20000 and width * height <= 48_000_000, "invalid_screenshot")
    return {"png": base64.b64encode(data).decode(), "width": width, "height": height}


async def run_advanced(request, ld):
    from workspace import afc_read, bundle_id, installed
    action = request["action"]
    if action == "developer_status":
        return await developer_status(ld)
    if action == "home_layout":
        return await home(ld)
    if action == "screen_capture":
        require(request.get("confirmed") is True, "confirmation_required")
        from pymobiledevice3.remote.core_device.screen_capture_service import ScreenCaptureService
        async with developer_rsd(ld) as rsd:
            async with ScreenCaptureService(rsd) as service:
                result = await service.capture_screenshot(requested_format="png")
        return screenshot_result(result.get("image"))
    if action in {"launch_plan", "launch_app"}:
        bundle = bundle_id(request.get("bundle"))
        apps = await installed(ld)
        require(any(app["bundle"] == bundle for app in apps["apps"]), "app_not_installed")
        plan = {"action": "launch", "device": ld.udid, "ios": str(ld.product_version), "bundle": bundle}
        token = plan_digest(plan)
        if action == "launch_plan":
            return {"plan_token": token, "count": 1, "bytes": 0, "ios": plan["ios"]}
        require(request.get("confirmed") is True and request.get("plan_token") == token, "plan_changed")
        from pymobiledevice3.remote.core_device.app_service import AppServiceService
        async with developer_rsd(ld) as rsd:
            async with AppServiceService(rsd) as service:
                await service.launch_application(bundle, kill_existing=False)
        return {"launch_requested": True, "health_verified": False}
    if action in {"home_export_plan", "home_export"}:
        result = await home(ld)
        payloads = {"layout.json": json.dumps(result, ensure_ascii=False, indent=2).encode()}
        body = "<pre>" + html.escape(payloads["layout.json"].decode()) + "</pre>"
        payloads["layout.html"] = ("<!doctype html><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'\"><title>Home screen snapshot</title><h1>Home screen snapshot</h1><p>Read-only snapshot; widgets and layout restoration may be unsupported.</p>" + body).encode()
    elif action in {"crash_export_plan", "crash_export"}:
        from pymobiledevice3.services.crash_reports import CrashReportsManager
        path = remote_path(request.get("path", ""))
        require(path.count("/") == 1 and path.endswith(".ips"), "invalid_crash_path")
        async with CrashReportsManager(ld) as reports:
            require(path[1:] in await reports.afc.listdir("/"), "report_not_found")
            data = await afc_read(reports.afc, path, 16 * 1024 ** 2)
        payloads = {safe_name(path[1:]): data}
    else:
        raise SafeError("unsupported_action")
    parent = output_parent(request.get("destination", ""))
    plan = {"action": action.removesuffix("_plan"), "device": ld.udid, "ios": str(ld.product_version),
            "destination": str(parent), "files": {name: hashlib.sha256(data).hexdigest() for name, data in payloads.items()}}
    token = plan_digest(plan)
    total = sum(map(len, payloads.values()))
    if action.endswith("_plan"):
        return {"plan_token": token, "bytes": total, "count": len(payloads), "ios": plan["ios"]}
    require(request.get("confirmed") is True and request.get("plan_token") == token, "plan_changed")
    job = OutputJob(parent, "HomeLayout" if action.startswith("home_") else "Crash", total, 32 * 1024 ** 2, token)
    for name, data in payloads.items():
        job.write(name, data)
    return job.finish()
