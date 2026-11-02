"""Bounded local transfers. No shells, source removal, public-cache writes or overwrite."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import time
import uuid


class SafeError(Exception):
    pass


def require(value, code):
    if not value:
        raise SafeError(code)


def version_tuple(value):
    require(isinstance(value, str) and re.fullmatch(r"\d{1,3}(?:\.\d{1,4}){0,3}", value), "unknown_ios_version")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (4 - len(parts))


def package_compatibility(info, ios, device_class="iPhone"):
    minimum = info.get("MinimumOSVersion")
    require(isinstance(minimum, str), "package_minimum_ios_missing")
    supported = info.get("CFBundleSupportedPlatforms", [])
    require(supported == ["iPhoneOS"], "package_platform_mismatch")
    family = 1 if device_class == "iPhone" else 2 if device_class == "iPad" else None
    require(family is not None and family in info.get("UIDeviceFamily", []), "package_device_family_mismatch")
    require(version_tuple(ios) >= version_tuple(minimum), "ios_too_old")
    return {"ios": ios, "minimum_ios": minimum, "compatible": True,
            "version": str(info.get("CFBundleShortVersionString", ""))[:64],
            "bundle": str(info.get("CFBundleIdentifier", ""))[:240]}


def remote_path(value):
    require(isinstance(value, str) and 0 < len(value) <= 1024 and "\\" not in value and "\x00" not in value, "unsafe_remote_path")
    parts = PurePosixPath(value).parts
    require(".." not in parts and all(len(x) <= 240 for x in parts), "unsafe_remote_path")
    return "/" + "/".join(x for x in parts if x not in ("/", "."))


def safe_name(value):
    require(isinstance(value, str) and 0 < len(value) <= 240, "unsafe_filename")
    require(value not in (".", "..") and not any(c in value for c in "/\\\x00\r\n"), "unsafe_filename")
    return value


def protected_name(value):
    name = PurePosixPath(value).name.lower()
    return (name.startswith(".env") or name in {"tokens.json", "credentials.json", "id_rsa", "id_ed25519"}
            or name.endswith((".key", ".pem", ".p12")))


def regular_file(path, maximum=None):
    p = Path(path)
    require(p.is_absolute() and p.resolve() == p and p.is_file() and not p.is_symlink(), "unsafe_local_file")
    size = p.stat().st_size
    require(maximum is None or size <= maximum, "file_size_limit")
    return p


def bounded_read(path, maximum):
    p = regular_file(path, maximum)
    before = p.stat()
    with p.open("rb") as f:
        data = f.read(maximum + 1)
        after = os.fstat(f.fileno())
    require(len(data) <= maximum and (before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns), "source_changed")
    return data


def digest(path):
    p = regular_file(path)
    before = p.stat()
    h = hashlib.sha256()
    with p.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    after = p.stat()
    require((before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns), "source_changed")
    return {"bytes": after.st_size, "sha256": h.hexdigest()}


def output_parent(value):
    p = Path(value)
    require(p.is_absolute() and p.is_dir() and p.resolve() == p and len(p.parts) > 2, "unsafe_output_folder")
    # Private exports must never enter shared library or source/runtime folders.
    forbidden = [Path.home() / "Library/Application Support/AppRestore/Library",
                 Path(__file__).resolve().parents[1], Path("/Applications")]
    for root in forbidden:
        require(p != root and root not in p.parents, "private_data_in_public_folder")
    return p


def plan_digest(plan):
    return hashlib.sha256(json.dumps(plan, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


class OutputJob:
    def __init__(self, parent, kind, planned_bytes, max_bytes, token):
        parent = output_parent(parent)
        require(0 <= planned_bytes <= max_bytes <= 1024 ** 4, "transfer_size_limit")
        require(shutil.disk_usage(parent).free > planned_bytes + 512 * 1024 ** 2, "insufficient_disk_space")
        self.root = parent / ("AppRestore-" + kind + "-" + time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8])
        self.root.mkdir(mode=0o700)
        self.limit = max_bytes
        self.written = 0
        self.files = []
        self.token = token
        self.state("incomplete")

    def state(self, status):
        receipt = {"schema": 1, "component": "apprestore-private-export", "status": status,
                   "plan": self.token, "files": self.files, "count": len(self.files),
                   "bytes": sum(x["bytes"] for x in self.files), "source_deleted": False,
                   "shared_cache": False, "checked_at": time.time()}
        p = self.root / "receipt.json"
        # This exact receipt belongs to this new job, not an existing owner export.
        with p.open("w", encoding="utf8") as f:
            os.chmod(p, 0o600)
            json.dump(receipt, f, ensure_ascii=False, indent=2)

    def path(self, relative):
        parts = PurePosixPath(relative).parts
        require(parts and not PurePosixPath(relative).is_absolute() and all(x not in ("..", ".") for x in parts), "unsafe_export_path")
        for part in parts:
            safe_name(part)
        p = self.root.joinpath(*parts)
        require(not p.exists() and not p.is_symlink() and p.resolve().is_relative_to(self.root), "export_exists")
        p.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        return p

    def write(self, relative, data):
        require(self.written + len(data) <= self.limit, "transfer_size_limit")
        p = self.path(relative)
        with p.open("xb") as f:
            os.chmod(p, 0o600)
            f.write(data)
        actual = digest(p)
        require(actual == {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}, "copy_verification_failed")
        self.written += len(data)
        self.files.append({"path": relative, **actual})
        return p

    def accept_existing(self, path):
        p = regular_file(path)
        require(p.is_relative_to(self.root) and p.name != "receipt.json", "unsafe_export_path")
        value = digest(p)
        require(self.written + value["bytes"] <= self.limit, "transfer_size_limit")
        self.written += value["bytes"]
        self.files.append({"path": str(p.relative_to(self.root)), **value})

    def finish(self, status="verified"):
        for row in self.files:
            require(digest(self.root / row["path"]) == {k: row[k] for k in ("bytes", "sha256")}, "copy_verification_failed")
        require(self.files, "empty_export")
        self.state(status)
        return {"directory": str(self.root), "count": len(self.files), "bytes": self.written,
                "verified": status == "verified", "needs_pdf": status == "needs_pdf"}
