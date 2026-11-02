"""Read-only DCIM catalog and byte streams. No phone writes, Photos database access or network."""
import base64
from datetime import datetime
import hashlib
import json
from pathlib import PurePosixPath
import re

from safety import SafeError, plan_digest, require, safe_name

READ_ACTIONS = {"media_catalog_page", "media_preview", "media_stream"}
IMAGES = {".png", ".jpg", ".jpeg", ".heic", ".heif", ".tif", ".tiff", ".gif", ".dng", ".raw", ".cr2", ".arw", ".avif", ".jxl"}
VIDEOS = {".mp4", ".mov", ".m4v"}
SIDECARS = {".aae", ".xmp", ".wav", ".m4a", ".mp3", ".aac", ".aif", ".aiff"}


def dcim_path(value, file=False):
    require(isinstance(value, str) and value.startswith("/DCIM") and len(value.encode()) <= 1800, "unsafe_media_path")
    path = PurePosixPath(value)
    require(str(path) == value and path.parts[1] == "DCIM" and 2 <= len(path.parts) <= 8, "unsafe_media_path")
    for part in path.parts[1:]:
        safe_name(part)
        require(not part.startswith(".") and not any(ord(c) < 32 for c in part), "unsafe_media_path")
    if file:
        require(len(path.parts) >= 3 and path.suffix.lower() in IMAGES | VIDEOS | SIDECARS, "unsupported_media_type")
    return value


def seconds(value):
    if isinstance(value, datetime):
        number = value.timestamp()
        require(abs(number) < 100_000_000_000, "invalid_media_date")
        return round(number, 6)
    return None


def media_row(path, stat):
    dcim_path(path, file=True)
    require(stat.get("st_ifmt") == "S_IFREG" and isinstance(stat.get("st_size"), int) and 0 <= stat["st_size"] <= 64 * 1024 ** 3, "invalid_media_entry")
    value = {"path": path, "name": PurePosixPath(path).name, "bytes": stat["st_size"],
             "created": seconds(stat.get("st_birthtime")), "modified": seconds(stat.get("st_mtime"))}
    return {**value, "fingerprint": plan_digest(value)}


async def directory(service, path):
    dcim_path(path)
    parts = PurePosixPath(path).parts
    for index in range(2, len(parts) + 1):
        ancestor = str(PurePosixPath(*parts[:index]))
        require((await service.stat(ancestor)).get("st_ifmt") == "S_IFDIR", "media_symlink_blocked")


async def checked_row(service, request):
    path = dcim_path(request.get("path"), file=True)
    fingerprint = request.get("fingerprint")
    require(isinstance(fingerprint, str) and re.fullmatch("[0-9a-f]{64}", fingerprint), "invalid_media_fingerprint")
    await directory(service, str(PurePosixPath(path).parent))
    row = media_row(path, await service.stat(path))
    require(row["fingerprint"] == fingerprint, "source_changed")
    return row


async def catalog_page(service, request):
    path = dcim_path(request.get("path", "/DCIM"))
    offset = request.get("offset", 0)
    require(isinstance(offset, int) and not isinstance(offset, bool) and 0 <= offset <= 100000, "invalid_media_page")
    await directory(service, path)
    names = sorted(name for name in await service.listdir(path) if name not in {".", ".."})
    require(len(names) <= 100000 and offset <= len(names), "media_catalog_limit")
    token = plan_digest({"folder": path, "names": names})
    if offset:
        require(request.get("catalog_token") == token, "media_catalog_changed")
    files, folders, skipped = [], [], 0
    for name in names[offset:offset + 300]:
        # iOS may keep hidden bookkeeping entries next to public DCIM media.
        # Never traverse them; they must not prevent visible media from loading.
        if isinstance(name, str) and name.startswith("."):
            skipped += 1
            continue
        safe_name(name)
        child = dcim_path(path + "/" + name)
        stat = await service.stat(child)
        if stat.get("st_ifmt") == "S_IFDIR":
            require(len(PurePosixPath(child).parts) < 8, "media_catalog_limit")
            folders.append(child)
        elif stat.get("st_ifmt") == "S_IFREG" and PurePosixPath(child).suffix.lower() in IMAGES | VIDEOS | SIDECARS:
            files.append(media_row(child, stat))
        else:
            skipped += 1
    return {"files": files, "folders": folders, "catalog_token": token, "next_offset": min(offset + 300, len(names)),
            "has_more": offset + 300 < len(names), "skipped": skipped, "transport": "usb_dcim_readonly"}


async def stream_file(service, request, emit):
    row = await checked_row(service, request)
    require(row["bytes"] > 0, "media_original_unavailable")
    handle = await service.fopen(row["path"], "r")
    offset, digest = 0, hashlib.sha256()
    try:
        emit({"event": "media_header", "bytes": row["bytes"], "fingerprint": row["fingerprint"]})
        while offset < row["bytes"]:
            chunk = await service.fread(handle, min(1024 ** 2, row["bytes"] - offset))
            require(isinstance(chunk, bytes) and 0 < len(chunk) <= min(1024 ** 2, row["bytes"] - offset), "short_device_read")
            digest.update(chunk)
            emit({"event": "media_chunk", "offset": offset, "data": base64.b64encode(chunk).decode()})
            offset += len(chunk)
    finally:
        await service.fclose(handle)
    await checked_row(service, request)
    return {"bytes": offset, "sha256": digest.hexdigest(), "fingerprint": row["fingerprint"], "source_deleted": False}


async def preview_file(service, request):
    row = await checked_row(service, request)
    require(PurePosixPath(row["path"]).suffix.lower() in IMAGES and 0 < row["bytes"] <= 8 * 1024 ** 2, "media_preview_unavailable")
    handle = await service.fopen(row["path"], "r")
    data = bytearray()
    try:
        while len(data) < row["bytes"]:
            chunk = await service.fread(handle, min(1024 ** 2, row["bytes"] - len(data)))
            require(isinstance(chunk, bytes) and 0 < len(chunk) <= min(1024 ** 2, row["bytes"] - len(data)), "short_device_read")
            data.extend(chunk)
    finally:
        await service.fclose(handle)
    await checked_row(service, request)
    require(len(data) == row["bytes"], "short_device_read")
    return {"data": base64.b64encode(data).decode(), "bytes": len(data)}


async def run_media(request, lockdown, emit):
    from pymobiledevice3.services.afc import AfcService
    async with AfcService(lockdown) as service:
        if request["action"] == "media_catalog_page":
            return await catalog_page(service, request)
        if request["action"] == "media_preview":
            return await preview_file(service, request)
        if request["action"] == "media_stream":
            return await stream_file(service, request, emit)
    raise SafeError("unsupported_action")
