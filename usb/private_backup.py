"""Explicit encrypted MobileBackup2 job. Never restores, wipes, disables encryption or reuses an old backup."""
import asyncio
from contextlib import asynccontextmanager, contextmanager
import os
from pathlib import Path
import plistlib
import shutil
import struct
import sys
import tempfile

from safety import OutputJob, SafeError, bounded_read, output_parent, plan_digest, require


@contextmanager
def temporary_files_in(root):
    # One request per helper process. TLS files created by the USB library must also
    # stay within this job's private temporary boundary, never the shared temp root.
    previous = tempfile.tempdir
    tempfile.tempdir = str(root)
    try:
        yield
    finally:
        tempfile.tempdir = previous


class WriteBoundary:
    def __init__(self, root, temporary):
        self.roots = [Path(root).resolve(), Path(temporary).resolve()]
        self.active = True

    def check(self, value):
        if isinstance(value, int):
            return
        p = Path(os.fsdecode(value)).absolute()
        require(any(p.resolve().is_relative_to(root) for root in self.roots), "backup_write_outside_job")

    def __call__(self, event, args):
        if not self.active:
            return
        if event == "open":
            mode = args[1] or ""
            flags = args[2] if len(args) > 2 else 0
            if any(x in mode for x in "wax+") or flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC):
                self.check(args[0])
        elif event in {"os.remove", "os.rmdir", "os.mkdir", "os.chmod", "os.utime", "os.truncate"}:
            self.check(args[0])
        elif event in {"os.rename", "os.link", "os.symlink"}:
            # Backup data never needs external links. Existing snapshots are never linked.
            require(event == "os.rename", "backup_link_blocked")
            self.check(args[0]); self.check(args[1])


async def create_backup(request, ld, emit):
    from pymobiledevice3.services.mobilebackup2 import Mobilebackup2Service
    from pymobiledevice3.services.device_link import DeviceLink, CODE_FILE_DATA, SIZE_FORMAT, CODE_FORMAT
    from pymobiledevice3.exceptions import ConnectionTerminatedError
    import contextlib
    import tempfile

    parent = output_parent(request.get("destination", ""))
    previous = [p for p in parent.iterdir() if p.name.startswith("AppRestore-EncryptedBackup-")]
    require(len(previous) < 8 and all(p.is_dir() and not p.is_symlink() for p in previous), "backup_history_limit")
    maximum = int(request.get("max_bytes", 256 * 1024 ** 3))
    require(1024 ** 3 <= maximum <= 1024 ** 4, "backup_size_limit")
    try:
        from device_storage import read_storage, estimated_used_bytes
        used = estimated_used_bytes(await read_storage(ld)) or 0
    except Exception:
        used = 0
    async with Mobilebackup2Service(ld) as probe:
        encrypted = await probe.get_will_encrypt()
    require(not used or used <= maximum, "backup_size_limit")
    require(shutil.disk_usage(parent).free > max(used, 1024 ** 3) + 512 * 1024 ** 2, "insufficient_disk_space")
    plan = {"action": "encrypted_backup", "destination": str(parent), "udid": ld.udid,
            "ios": ld.product_version, "encrypted": encrypted, "limit": maximum}
    # Free space/used bytes fluctuate; binding identity, encryption, destination and limit is stable.
    token = plan_digest(plan)
    if request["action"] == "backup_plan":
        return {"plan_token": token, "estimated_bytes": used, "estimate_known": bool(used),
                "encrypted": encrypted, "ios": ld.product_version, "max_bytes": maximum}
    require(request.get("confirmed") is True and request.get("plan_token") == token, "plan_changed")
    password = request.get("backup_password", "")
    require(isinstance(password, str) and 0 < len(password) <= 1024, "backup_password_required")
    if not encrypted:
        require(request.get("enable_encryption_confirmed") is True and len(password) >= 8, "backup_encryption_confirmation_required")
    job = OutputJob(parent, "EncryptedBackup", max(used, 1024 ** 3), maximum, token)
    emit({"event": "job", "directory": str(job.root)})

    class BoundedLink(DeviceLink):
        transferred = 0
        async def _consume_file_transfer(self, size, code, destination=None):
            while size and code == CODE_FILE_DATA:
                require(0 <= size <= maximum, "backup_size_limit")
                while size:
                    amount = min(size, 1024 * 1024)
                    require(self.transferred + amount <= maximum, "backup_size_limit")
                    require(shutil.disk_usage(job.root).free > amount + 256 * 1024 ** 2, "insufficient_disk_space")
                    chunk = await self._recvall(amount)
                    self.transferred += len(chunk)
                    size -= len(chunk)
                    if destination is not None:
                        destination.write(chunk)
                (size,) = struct.unpack(SIZE_FORMAT, await self._recvall(struct.calcsize(SIZE_FORMAT)))
                (code,) = struct.unpack(CODE_FORMAT, await self._recvall(struct.calcsize(CODE_FORMAT)))
                size -= struct.calcsize(CODE_FORMAT)
            return size, code

    class RestrictedBackup(Mobilebackup2Service):
        @asynccontextmanager
        async def device_link(self, backup_directory, filter_callback=None, password=""):
            await self.connect()
            link = BoundedLink(self._service, Path(backup_directory))
            await link.version_exchange()
            await self.version_exchange(link)
            try:
                yield link
            finally:
                with contextlib.suppress(ConnectionTerminatedError):
                    await link.disconnect()

    with tempfile.TemporaryDirectory(prefix="apprestore-backup-private-") as temp, temporary_files_in(temp):
        boundary = WriteBoundary(job.root, temp)
        sys.addaudithook(boundary)
        try:
            async with RestrictedBackup(ld) as service:
                if not encrypted:
                    # Persistent device setting: frontend names this effect in its confirmation.
                    await service.change_password(backup_directory=job.root, new=password)
                    require(await service.get_will_encrypt(), "backup_encryption_not_enabled")
                def progress(value):
                    emit({"event": "progress", "fraction": max(0, min(1, float(value) / 100))})
                await service.backup(full=True, backup_directory=job.root, progress_callback=progress)
            root = job.root / ld.udid
            manifest = plistlib.loads(bounded_read(root / "Manifest.plist", 4 * 1024 * 1024))
            status = plistlib.loads(bounded_read(root / "Status.plist", 4 * 1024 * 1024))
            require(manifest.get("IsEncrypted") is True and status.get("SnapshotState") == "finished", "incomplete_backup")
            from backup_reader import BackupReader
            # Prove the supplied password opens this completed backup; no plaintext DB file is made.
            with BackupReader(root, password) as reader:
                reader.summary()
            count = 0
            for p in root.rglob("*"):
                if p.is_dir():
                    p.chmod(0o700)
                else:
                    require(not p.is_symlink(), "unsafe_backup_path")
                    p.chmod(0o600)
                    job.accept_existing(p)
                    count += 1
                    require(count <= 200000, "backup_file_count_limit")
            result = job.finish()
            result["backup_directory"] = str(root)
            result["encrypted"] = True
            result["device_encryption_enabled"] = not encrypted
            result["restored_to_device"] = False
            return result
        finally:
            boundary.active = False
            request["backup_password"] = ""
            password = ""
