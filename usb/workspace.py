"""Explicit USB workspace actions. Does not enumerate personal datasets on connection."""
import base64
import hashlib
import json
import math
from pathlib import Path
import plistlib
import re
import shutil
from advanced import READ_ACTIONS as ADVANCED_READ, WRITE_ACTIONS as ADVANCED_WRITE, run_advanced
from battery import read_battery, normalize as normalize_battery
from device_inventory import inventory
from device_storage import read_storage
from content_counts import read_content_counts
from media_usb import READ_ACTIONS as MEDIA_READ, run_media

from safety import (OutputJob, SafeError, bounded_read, digest, output_parent, plan_digest,
                    protected_name, regular_file, remote_path, require, safe_name)

READ_ACTIONS = {"inventory", "battery", "overview", "storage_settings", "icon", "crashes", "crash_summary", "sharing_apps", "files_list", "profiles"}
WRITE_ACTIONS = {"file_plan", "file_export", "file_upload_plan", "file_upload", "backup_plan", "backup_create"}
READ_ACTIONS |= ADVANCED_READ
READ_ACTIONS |= MEDIA_READ
WRITE_ACTIONS |= ADVANCED_WRITE


def bundle_id(value):
    require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{1,239}", value), "invalid_bundle")
    return value


def finite_number(value):
    try:
        number = float(value)
        return number if math.isfinite(number) and abs(number) <= 1024 ** 5 else None
    except (TypeError, ValueError):
        return None


async def overview(ld):
    from pymobiledevice3.services.diagnostics import DiagnosticsService
    result = {"model": str(ld.all_values.get("ProductType", "")), "ios": str(ld.product_version),
              "build": str(ld.all_values.get("BuildVersion", "")),
              "name": str(ld.all_values.get("DeviceName", "iPhone"))[:120],
              "camera_serial": str(ld.all_values.get("SerialNumber", "")),
              "battery": {}, "storage": {}, "battery_available": False}
    try:
        result["storage"] = await read_storage(ld,settings_timeout=2)
    except Exception:
        pass
    try:
        async with DiagnosticsService(ld) as service:
            battery = await service.get_battery() or {}
        # Never return full IORegistry (serials, opaque blobs and unrelated private keys).
        for name in ("CurrentCapacity", "MaxCapacity", "DesignCapacity", "AppleRawCurrentCapacity",
                     "AppleRawMaxCapacity", "CycleCount", "Temperature", "Voltage", "Amperage",
                     "IsCharging", "ExternalConnected", "FullyCharged"):
            value = battery.get(name)
            if isinstance(value, bool) or finite_number(value) is not None:
                result["battery"][name] = value
        result["battery_available"] = bool(result["battery"])
        result["battery_reading"] = normalize_battery(battery)
    except Exception:
        pass
    content=await read_content_counts(ld)
    result.update({'content_counts':content['values'],'content_count_sources':content['sources'],'content_count_observed_at':content['observed_at']})
    return result


async def installed(ld, sharing_only=False):
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    attrs = ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString",
             "MinimumOSVersion", "UIFileSharingEnabled", "UIDeviceFamily", "iTunesMetadata"]
    async with InstallationProxyService(ld) as proxy:
        apps = await proxy.lookup({"ApplicationType": "User", "ReturnAttributes": attrs}) or {}
    require(len(apps) <= 3000, "too_many_apps")
    output = []
    for bundle, info in apps.items():
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{1,239}", bundle):
            continue
        sharing = info.get("UIFileSharingEnabled") is True
        if sharing_only and not sharing:
            continue
        meta = info.get("iTunesMetadata", {})
        if isinstance(meta, bytes) and len(meta) <= 1024 * 1024:
            try:
                meta = plistlib.loads(meta)
            except Exception:
                meta = {}
        try:
            app_id = int(meta.get("itemId")) if isinstance(meta, dict) and meta.get("itemId") else None
        except (ValueError, TypeError):
            app_id = None
        output.append({"bundle": bundle, "name": str(info.get("CFBundleDisplayName") or info.get("CFBundleName") or bundle)[:240],
                       "version": str(info.get("CFBundleShortVersionString", ""))[:64], "app_id": app_id,
                       "minimum_ios": str(info.get("MinimumOSVersion", ""))[:32], "file_sharing": sharing})
    return {"apps": sorted(output, key=lambda app: app["name"].lower())}


async def afc_read(service, path, limit):
    value = await service.stat(path)
    require(value.get("st_ifmt") == "S_IFREG" and 0 <= value["st_size"] <= limit, "file_size_limit")
    handle = await service.fopen(path, "r")
    data = bytearray()
    try:
        while len(data) < value["st_size"]:
            chunk = await service.fread(handle, min(1024 * 1024, value["st_size"] - len(data)))
            require(chunk, "short_device_read")
            data.extend(chunk)
    finally:
        await service.fclose(handle)
    after = await service.stat(path)
    require((after.get("st_size"), after.get("st_mtime")) == (value.get("st_size"), value.get("st_mtime")), "source_changed")
    return bytes(data)


async def file_listing(service, path):
    path = remote_path(path)
    stat = await service.stat(path)
    require(stat.get("st_ifmt") == "S_IFDIR", "not_a_folder")
    names = await service.listdir(path)
    require(len(names) <= 5000, "folder_item_limit")
    result = []
    for name in names:
        if name in (".", ".."):
            continue
        safe_name(name)
        child = remote_path(path.rstrip("/") + "/" + name)
        entry = await service.stat(child)
        if entry.get("st_ifmt") not in ("S_IFDIR", "S_IFREG"):
            continue
        result.append({"id": child, "name": name, "directory": entry["st_ifmt"] == "S_IFDIR",
                       "bytes": entry.get("st_size", 0), "modified": str(entry.get("st_mtime", ""))[:40],
                       "exportable": not protected_name(name)})
    return {"path": path, "files": sorted(result, key=lambda x: (not x["directory"], x["name"].lower()))}


async def sharing_service(ld, bundle):
    from pymobiledevice3.services.house_arrest import HouseArrestService
    bundle = bundle_id(bundle)
    apps = await installed(ld, sharing_only=True)
    require(any(app["bundle"] == bundle for app in apps["apps"]), "file_sharing_not_enabled")
    return await HouseArrestService.create(ld, bundle, documents_only=True)


def crash_fields(data):
    text = data.decode("utf8", errors="replace")
    decoder = json.JSONDecoder()
    values = []
    while text.strip() and len(values) < 2:
        value, end = decoder.raw_decode(text.lstrip())
        require(isinstance(value, dict), "unsupported_crash_format")
        values.append(value)
        text = text.lstrip()[end:]
    header = values[0] if values else {}
    body = values[1] if len(values) > 1 else header
    # Only enum/identifier fields, never thread dumps, paths, register values or raw exception strings.
    safe = lambda value, n=120: str(value)[:n] if isinstance(value, (str, int, float)) else ""
    exception = body.get("exception", {})
    termination = body.get("termination", {})
    return {"app": safe(header.get("app_name", body.get("procName", ""))),
            "bundle": safe(header.get("bundleID", body.get("bundleInfo", {}).get("CFBundleIdentifier", "")), 240),
            "version": safe(header.get("app_version", body.get("bundleInfo", {}).get("CFBundleShortVersionString", "")), 64),
            "date": safe(header.get("timestamp", body.get("captureTime", ""))),
            "exception": safe(exception.get("type", "")), "signal": safe(exception.get("signal", "")),
            "termination_namespace": safe(termination.get("namespace", "")), "termination_code": safe(termination.get("code", "")),
            "interpretation": "reported_fields_only"}


async def run_workspace(request, ld, emit):
    action = request["action"]
    if action in MEDIA_READ:
        return await run_media(request, ld, emit)
    if action in ADVANCED_READ | ADVANCED_WRITE:
        return await run_advanced(request, ld)
    if action == "inventory":
        return await inventory(ld)
    if action == "battery":
        return await read_battery(ld)
    if action == "overview":
        return await overview(ld)
    if action == "storage_settings":
        diagnostics={}
        storage=await read_storage(ld,settings_timeout=30,require_new_settings=True,
            settings_ready=lambda:emit({"event":"storage_ready"}),settings_diagnostics=diagnostics)
        return {"storage":storage,"settings_probe":diagnostics}
    if action == "apps":
        return await installed(ld)
    if action == "sharing_apps":
        return await installed(ld, sharing_only=True)
    if action == "icon":
        from pymobiledevice3.services.springboard import SpringBoardServicesService
        bundle = bundle_id(request.get("bundle"))
        # Query only the chosen app; no bulk icon/wallpaper access.
        from pymobiledevice3.services.installation_proxy import InstallationProxyService
        async with InstallationProxyService(ld) as proxy:
            result = await proxy.lookup({"BundleIDs": [bundle], "ReturnAttributes": ["CFBundleIdentifier"]}) or {}
        require(bundle in result, "app_not_installed")
        async with SpringBoardServicesService(ld) as service:
            data = await service.get_icon_pngdata(bundle)
        require(isinstance(data, bytes) and 0 < len(data) <= 2 * 1024 * 1024 and data.startswith(b"\x89PNG"), "invalid_device_icon")
        return {"png": base64.b64encode(data).decode(), "bundle": bundle}
    if action in ("crashes", "crash_summary"):
        from pymobiledevice3.services.crash_reports import CrashReportsManager
        async with CrashReportsManager(ld) as reports:
            if action == "crashes":
                rows = []
                for name in await reports.afc.listdir("/"):
                    if name.lower().endswith(".ips"):
                        safe_name(name)
                        rows.append({"id": "/" + name, "name": name})
                require(len(rows) <= 3000, "report_item_limit")
                return {"reports": sorted(rows, key=lambda x: x["name"], reverse=True)[:500]}
            path = remote_path(request.get("path", ""))
            require(path.count("/") == 1 and path.endswith(".ips"), "invalid_crash_path")
            return crash_fields(await afc_read(reports.afc, path, 16 * 1024 * 1024))
    if action == "profiles":
        from pymobiledevice3.services.mobile_config import MobileConfigService
        async with MobileConfigService(ld) as service:
            result = await service.get_profile_list()
        profiles = result.get("ProfileMetadata", {})
        require(isinstance(profiles, dict) and len(profiles) <= 300, "invalid_profile_list")
        return {"profiles": [{"id": str(key)[:240], "name": str(value.get("PayloadDisplayName", key))[:240],
                              "organization": str(value.get("PayloadOrganization", ""))[:240]}
                             for key, value in profiles.items() if isinstance(value, dict)]}
    if action in ("backup_plan", "backup_create"):
        from private_backup import create_backup
        return await create_backup(request, ld, emit)
    if action in {"files_list", "file_plan", "file_export", "file_upload_plan", "file_upload"}:
        async with await sharing_service(ld, request.get("bundle")) as service:
            if action == "files_list":
                return await file_listing(service, request.get("path", "/"))
            return await transfer_documents(request, ld, service, emit)
    raise SafeError("unsupported_action")


async def transfer_documents(request, ld, service, emit):
    action = request["action"]
    parent = request.get("destination")
    limit = int(request.get("max_bytes", 4 * 1024 ** 3))
    require(0 < limit <= 16 * 1024 ** 3, "transfer_size_limit")
    upload = action.startswith("file_upload")
    rows = []
    if upload:
        folder = remote_path(request.get("path", "/"))
        require((await service.stat(folder)).get("st_ifmt") == "S_IFDIR", "not_a_folder")
        nonce = request.get("upload_nonce", "")
        require(isinstance(nonce, str) and re.fullmatch(r"[0-9a-f]{32}", nonce), "invalid_transfer_nonce")
        import_folder = remote_path(folder.rstrip("/") + "/AppRestore-Import-" + nonce)
        try:
            await service.stat(import_folder)
        except Exception as e:
            from pymobiledevice3.exceptions import AfcFileNotFoundError
            if not isinstance(e, AfcFileNotFoundError):
                raise
        else:
            raise SafeError("device_file_exists")
        paths = request.get("local_files", [])
        require(isinstance(paths, list) and 0 < len(paths) <= 100, "selection_required")
        for path in paths:
            p = regular_file(path, limit)
            require(not protected_name(p.name), "protected_file_blocked")
            remote = remote_path(import_folder + "/" + safe_name(p.name))
            require(all(row["remote"] != remote for row in rows), "duplicate_transfer_filename")
            rows.append({"local": str(p), "remote": remote, **digest(p)})
    else:
        output_parent(parent)
        paths = request.get("paths", [])
        require(isinstance(paths, list) and 0 < len(paths) <= 1000, "selection_required")
        for raw in paths:
            path = remote_path(raw)
            require(not protected_name(path), "protected_file_blocked")
            info = await service.stat(path)
            require(info.get("st_ifmt") == "S_IFREG", "regular_files_only")
            rows.append({"remote": path, "bytes": info["st_size"], "modified": str(info["st_mtime"])})
    total = sum(row["bytes"] for row in rows)
    require(0 <= total <= limit, "transfer_size_limit")
    plan = {"action": "upload" if upload else "export", "udid": ld.udid, "ios": ld.product_version,
            "bundle": request["bundle"], "rows": rows, "destination": parent if not upload else folder, "bytes": total}
    token = plan_digest(plan)
    if action.endswith("plan"):
        return {"plan_token": token, "count": len(rows), "bytes": total, "ios": ld.product_version}
    require(request.get("confirmed") is True and request.get("plan_token") == token, "plan_changed")
    if upload:
        private_parent = Path.home() / "Library/Application Support/AppRestore/PrivateReceipts"
        private_parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        require(private_parent.resolve() == private_parent, "unsafe_output_folder")
        journal = OutputJob(private_parent, "UploadReceipt", 4096, 1024 * 1024, token)
        emit({"event": "job", "directory": str(journal.root)})
        await service.makedirs(import_folder)
        require((await service.stat(import_folder)).get("st_ifmt") == "S_IFDIR", "unsafe_remote_path")
        for index, row in enumerate(rows):
            before = digest(row["local"])
            require(before == {k: row[k] for k in ("bytes", "sha256")}, "source_changed")
            # AFC WRONLY opens a new remote path; existence was checked above. No overwriting flow is offered.
            handle = await service.fopen(row["remote"], "w")
            try:
                with Path(row["local"]).open("rb") as f:
                    for chunk in iter(lambda: f.read(1024 * 1024), b""):
                        await service.fwrite(handle, chunk)
            finally:
                await service.fclose(handle)
            verify = hashlib.sha256()
            handle = await service.fopen(row["remote"], "r")
            try:
                remain = row["bytes"]
                while remain:
                    chunk = await service.fread(handle, min(remain, 1024 * 1024))
                    require(chunk and len(chunk) <= remain, "short_device_read")
                    verify.update(chunk)
                    remain -= len(chunk)
            finally:
                await service.fclose(handle)
            after = await service.stat(row["remote"])
            require(after.get("st_size") == row["bytes"] and verify.hexdigest() == row["sha256"] and digest(row["local"]) == before, "copy_verification_failed")
            journal.write(str(index + 1) + ".json", json.dumps({"remote": row["remote"], "bytes": row["bytes"], "sha256": row["sha256"], "verified": True}).encode())
            journal.state("incomplete")
            emit({"event": "progress", "fraction": (index + 1) / len(rows)})
        journal.finish()
        return {"count": len(rows), "bytes": total, "verified": True, "source_deleted": False, "device_path": import_folder, "directory": str(journal.root)}
    job = OutputJob(parent, "Documents", total, limit, token)
    emit({"event": "job", "directory": str(job.root)})
    for index, row in enumerate(rows):
        name = safe_name(Path(row["remote"]).name)
        if (job.root / name).exists():
            name = str(index) + "-" + name
        target = job.path(name)
        remote = row["remote"]
        handle = await service.fopen(remote, "r")
        h = hashlib.sha256()
        count = 0
        try:
            with target.open("xb") as f:
                target.chmod(0o600)
                while count < row["bytes"]:
                    chunk = await service.fread(handle, min(row["bytes"] - count, 1024 * 1024))
                    require(chunk and len(chunk) <= row["bytes"] - count, "short_device_read")
                    require(shutil.disk_usage(job.root).free > len(chunk) + 256 * 1024 ** 2, "insufficient_disk_space")
                    f.write(chunk)
                    h.update(chunk)
                    count += len(chunk)
        finally:
            await service.fclose(handle)
        after = await service.stat(remote)
        require(after["st_size"] == row["bytes"] and str(after["st_mtime"]) == row["modified"], "source_changed")
        require(digest(target) == {"bytes": count, "sha256": h.hexdigest()}, "copy_verification_failed")
        job.accept_existing(target)
        job.state("incomplete")
        emit({"event": "progress", "fraction": (index + 1) / len(rows)})
    return job.finish()
