"""Read-only iOS backup catalog and bounded, memory-only decryption.

Reuses pinned pyiosbackup crypto, never its logging-heavy Backup.from_path,
SQL interpolation, extract_all or persistent temporary Manifest.db implementation.
"""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import sqlite3
import stat
import struct
import time

from safety import SafeError, bounded_read, protected_name, require, regular_file

MAX_MANIFEST = 256 * 1024 ** 2
MAX_ENTRY = 512 * 1024 ** 2


def memory_database(data):
    require(isinstance(data, bytes) and len(data) <= MAX_ENTRY and data.startswith(b"SQLite format 3\x00"), "invalid_backup_database")
    page = int.from_bytes(data[16:18], "big")
    page = 65536 if page == 1 else page
    pages = int.from_bytes(data[28:32], "big")
    require(page >= 512 and page <= 65536 and page & (page - 1) == 0 and pages > 0 and pages * page <= len(data), "invalid_backup_database")
    snapshot = bytearray(data[:pages * page])
    snapshot[18:20] = b"\x01\x01"  # Standalone in-memory image. WAL payloads are rejected below.
    connection = sqlite3.connect(":memory:")
    connection.deserialize(bytes(snapshot))
    connection.enable_load_extension(False)
    connection.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, MAX_ENTRY)
    connection.setlimit(sqlite3.SQLITE_LIMIT_SQL_LENGTH, 16384)
    connection.setlimit(sqlite3.SQLITE_LIMIT_ATTACHED, 0)
    deadline = time.monotonic() + 90
    steps = 0
    def bounded_query():
        nonlocal steps
        steps += 10000
        return int(steps > 50000000 or time.monotonic() > deadline)
    connection.set_progress_handler(bounded_query, 10000)
    connection.execute("PRAGMA trusted_schema=OFF")
    connection.execute("PRAGMA query_only=ON")
    connection.row_factory = sqlite3.Row
    return connection


def archived_file(blob):
    require(isinstance(blob, bytes) and len(blob) <= 2 * 1024 ** 2, "invalid_backup_entry")
    archive = plistlib.loads(blob)
    objects = archive.get("$objects", [])
    require(isinstance(objects, list) and len(objects) <= 10000, "invalid_backup_entry")
    def resolve(value):
        if isinstance(value, plistlib.UID):
            require(value.data < len(objects), "invalid_backup_entry")
            return objects[value.data]
        return value
    root = resolve(archive.get("$top", {}).get("root"))
    require(isinstance(root, dict), "invalid_backup_entry")
    result = {}
    for key in ("Size", "Mode", "ProtectionClass"):
        value = root.get(key)
        if isinstance(value, int):
            result[key] = value
    for key in ("EncryptionKey", "Digest"):
        value = resolve(root.get(key))
        if isinstance(value, dict):
            value = value.get("NS.data")
        if isinstance(value, bytes):
            result[key] = value
    return result


class BackupReader:
    def __init__(self, root, password=""):
        self.root = Path(root)
        require(self.root.is_absolute() and self.root.resolve() == self.root and self.root.is_dir(), "unsafe_backup_path")
        self.manifest_data = bounded_read(self.root / "Manifest.plist", 4 * 1024 ** 2)
        self.manifest = plistlib.loads(self.manifest_data)
        self.info = plistlib.loads(bounded_read(self.root / "Info.plist", 4 * 1024 ** 2))
        self.status = plistlib.loads(bounded_read(self.root / "Status.plist", 4 * 1024 ** 2))
        require(isinstance(self.manifest, dict) and isinstance(self.info, dict) and self.status.get("SnapshotState") == "finished", "incomplete_backup")
        require(isinstance(self.manifest.get("IsEncrypted"), bool), "invalid_backup_manifest")
        self.encrypted = self.manifest["IsEncrypted"]
        self.keybag = None
        wal = self.root / "Manifest.db-wal"
        require(not wal.exists() or regular_file(wal).stat().st_size == 0, "backup_source_in_use")
        data = bounded_read(self.root / "Manifest.db", MAX_MANIFEST)
        self.source_identity = hashlib.sha256(self.manifest_data + hashlib.sha256(data).digest()).hexdigest()
        if self.encrypted:
            require(isinstance(password, str) and password, "backup_password_required")
            from pyiosbackup.keybag import Keybag, keybag_struct
            from pyiosbackup.manifest_plist import ManifestPlist
            keybag = self.manifest.get("BackupKeyBag")
            require(isinstance(keybag, bytes) and len(keybag) <= 1024 * 1024, "invalid_backup_keybag")
            parsed = keybag_struct.parse(keybag)
            require(len(parsed) <= 5000, "invalid_backup_keybag")
            for item in parsed:
                if item.tag in (b"DPIC", b"ITER"):
                    require(isinstance(item.data, int) and 0 < item.data <= 20000000, "backup_kdf_limit")
            try:
                manifest = ManifestPlist(self.manifest)
                self.keybag = Keybag.from_manifest(manifest, password)
                data = self.keybag.decrypt(data, manifest.manifest_key)
            except Exception:
                raise SafeError("backup_password_invalid") from None
        try:
            self.connection = memory_database(data)
            require(self.connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='Files'").fetchone(), "invalid_backup_database")
        except Exception:
            raise SafeError("backup_password_invalid" if self.encrypted else "invalid_backup_database") from None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self):
        self.connection.close()
        self.keybag = None

    def summary(self):
        ios = str(self.info.get("Product Version", self.manifest.get("Lockdown", {}).get("ProductVersion", "")))[:32]
        return {"name": str(self.info.get("Device Name", self.info.get("Display Name", "iPhone")))[:120],
                "model": str(self.info.get("Product Type", self.manifest.get("Lockdown", {}).get("ProductType", "")))[:64],
                "ios": ios, "encrypted": self.encrypted, "finished": True,
                "date": str(self.status.get("Date", ""))[:50],
                "files": self.connection.execute("SELECT COUNT(*) FROM Files WHERE flags=1").fetchone()[0]}

    @staticmethod
    def validate_row(row):
        require(row is not None and re.fullmatch(r"[0-9a-fA-F]{40}", row["fileID"]), "invalid_backup_entry")
        path = PurePosixPath(row["relativePath"])
        require(not path.is_absolute() and ".." not in path.parts and "\\" not in row["relativePath"] and "\x00" not in row["relativePath"], "unsafe_backup_entry")
        require(isinstance(row["domain"], str) and re.fullmatch(r"[A-Za-z0-9._-]{1,240}", row["domain"]), "unsafe_backup_entry")
        return row

    def row(self, file_id):
        require(isinstance(file_id, str) and re.fullmatch(r"[0-9a-fA-F]{40}", file_id), "invalid_backup_entry")
        return self.validate_row(self.connection.execute("SELECT fileID,domain,relativePath,flags,file FROM Files WHERE fileID=? AND flags=1", (file_id,)).fetchone())

    def find(self, domains, path):
        for domain in domains:
            row = self.connection.execute("SELECT fileID,domain,relativePath,flags,file FROM Files WHERE domain=? AND relativePath=? AND flags=1", (domain, path)).fetchone()
            if row is not None:
                return self.validate_row(row)
        raise SafeError("dataset_not_in_backup")

    def catalog(self, search="", offset=0, limit=300):
        require(isinstance(search, str) and len(search) <= 240 and 0 <= offset <= 200000 and 1 <= limit <= 1000, "invalid_backup_query")
        # LIKE is parameterized. Escape wildcard characters for literal user search.
        query = "%" + search.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
        rows = self.connection.execute("SELECT fileID,domain,relativePath,flags,file FROM Files WHERE flags=1 AND relativePath LIKE ? ESCAPE '\\' ORDER BY domain,relativePath LIMIT ? OFFSET ?", (query, limit, offset)).fetchall()
        output = []
        for row in rows:
            self.validate_row(row)
            size = archived_file(row["file"]).get("Size", 0)
            output.append({"id": row["fileID"], "name": row["relativePath"], "domain": row["domain"], "bytes": size,
                           "exportable": not protected_name(row["relativePath"]) and row["domain"] != "KeychainDomain"})
        return {"files": output, "offset": offset, "has_more": len(rows) == limit}

    def content(self, row, maximum=MAX_ENTRY):
        self.validate_row(row)
        require(not protected_name(row["relativePath"]) and row["domain"] != "KeychainDomain", "protected_file_blocked")
        metadata = archived_file(row["file"])
        require(stat.S_ISREG(metadata.get("Mode", stat.S_IFREG)), "regular_files_only")
        size = metadata.get("Size")
        require(isinstance(size, int) and 0 <= size <= maximum, "file_size_limit")
        file_id = row["fileID"]
        p = self.root / file_id[:2] / file_id
        data = bounded_read(p, maximum + 32)
        if self.encrypted:
            from cryptography.hazmat.primitives import padding
            key = metadata.get("EncryptionKey")
            require(isinstance(key, bytes) and 4 < len(key) <= 128, "invalid_backup_entry")
            try:
                raw = self.keybag.decrypt(data, key)
                unpad = padding.PKCS7(128).unpadder()
                data = unpad.update(raw) + unpad.finalize()
            except Exception:
                raise SafeError("backup_entry_decryption_failed") from None
        require(len(data) == size, "backup_entry_size_mismatch")
        if "Digest" in metadata:
            expected = metadata["Digest"]
            if len(expected) == 20:
                require(hashlib.sha1(data).digest() == expected, "backup_entry_digest_mismatch")
        return data

    def dataset(self, kind):
        if kind == "sms":
            entry = self.find(["HomeDomain"], "Library/SMS/sms.db")
        elif kind == "contacts":
            entry = self.find(["HomeDomain"], "Library/AddressBook/AddressBook.sqlitedb")
        elif kind == "whatsapp":
            entry = self.find(["AppDomainGroup-group.net.whatsapp.WhatsApp.shared", "AppDomain-net.whatsapp.WhatsApp"], "ChatStorage.sqlite")
        else:
            raise SafeError("unsupported_dataset")
        wal = self.connection.execute("SELECT fileID,domain,relativePath,flags,file FROM Files WHERE domain=? AND relativePath=? AND flags=1", (entry["domain"], entry["relativePath"] + "-wal")).fetchone()
        if wal is not None:
            require(archived_file(wal["file"]).get("Size", 0) <= 32, "backup_dataset_has_pending_wal")
        db = memory_database(self.content(entry))
        return db
