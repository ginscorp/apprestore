"""Selected iOS backup datasets. Own bounded SQL adapters; no web server or cloud SDK."""
import csv
from datetime import datetime, timezone
import hashlib
import html
import io
import json
from pathlib import Path, PurePosixPath
import plistlib
import re

from backup_reader import BackupReader, archived_file
from safety import (OutputJob, SafeError, bounded_read, digest, output_parent, plan_digest,
                    protected_name, require, safe_name)

OFFLINE_ACTIONS = {"backup_inspect", "backup_catalog", "archive_chats", "archive_messages", "archive_contacts",
                   "archive_export_plan", "archive_export", "finalize_pdf"}


def columns(db, table):
    require(table in {"chat", "message", "handle", "attachment", "message_attachment_join", "chat_message_join",
                      "ABPerson", "ABMultiValue", "ZWAMESSAGE", "ZWACHATSESSION", "ZWAMEDIAITEM"}, "unsupported_backup_schema")
    return {row["name"] for row in db.execute('PRAGMA table_info("' + table + '")')}


def text(value, limit=100000):
    if value is None:
        return ""
    require(isinstance(value, (str, int, float)), "unsupported_backup_schema")
    s = str(value)
    require(len(s) <= limit, "archive_text_limit")
    return s


def apple_date(value):
    if value is None:
        return ""
    try:
        value = float(value)
        value = value / 10 ** 9 if abs(value) > 10 ** 11 else value
        return datetime.fromtimestamp(value + 978307200, timezone.utc).isoformat()
    except (ValueError, TypeError, OverflowError, OSError):
        return ""


def chats(db, kind):
    if kind == "sms":
        require({"chat_identifier", "display_name"} <= columns(db, "chat") and "text" in columns(db, "message"), "unsupported_backup_schema")
        rows = db.execute("SELECT c.ROWID AS id,c.chat_identifier AS address,c.display_name AS name,COUNT(j.message_id) AS count FROM chat c LEFT JOIN chat_message_join j ON j.chat_id=c.ROWID GROUP BY c.ROWID ORDER BY c.ROWID DESC LIMIT 1001").fetchall()
    elif kind == "whatsapp":
        require({"ZCONTACTJID", "ZPARTNERNAME"} <= columns(db, "ZWACHATSESSION") and {"ZCHATSESSION", "ZTEXT", "ZMESSAGEDATE", "ZISFROMME"} <= columns(db, "ZWAMESSAGE"), "unsupported_backup_schema")
        rows = db.execute("SELECT c.Z_PK AS id,c.ZCONTACTJID AS address,c.ZPARTNERNAME AS name,COUNT(m.Z_PK) AS count FROM ZWACHATSESSION c LEFT JOIN ZWAMESSAGE m ON m.ZCHATSESSION=c.Z_PK GROUP BY c.Z_PK ORDER BY c.Z_PK DESC LIMIT 1001").fetchall()
    else:
        raise SafeError("unsupported_dataset")
    require(len(rows) <= 1000, "archive_chat_limit")
    return [{"id": str(row["id"]), "name": text(row["name"] or row["address"] or "—", 1000),
             "address": text(row["address"], 1000), "count": row["count"]} for row in rows]


def attributed_text(blob):
    # Decode only a recognized keyed archive. Never guess strings from typedstream bytes.
    if isinstance(blob, bytes) and len(blob) <= 2 * 1024 ** 2 and blob.startswith(b"bplist"):
        try:
            archive = plistlib.loads(blob)
            objects = archive.get("$objects", [])
            found = [x for x in objects if isinstance(x, str) and x not in {"$null", "NSAttributedString", "NSMutableAttributedString", "NSObject", "NSString"}]
            if len(found) == 1:
                return text(found[0])
        except Exception:
            pass
    return None


def messages(db, kind, chat_id, limit=500, offset=0):
    require(str(chat_id).isdigit() and 0 <= int(chat_id) < 2 ** 63 and 0 <= offset <= 50000 and 1 <= limit <= 50000, "invalid_archive_selection")
    if kind == "sms":
        attrs = columns(db, "message")
        require({"text", "date", "is_from_me"} <= attrs, "unsupported_backup_schema")
        attributed = "m.attributedBody" if "attributedBody" in attrs else "NULL"
        rows = db.execute("SELECT m.ROWID AS id,m.text AS text,m.date AS date,m.is_from_me AS from_me," + attributed + " AS rich FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID WHERE j.chat_id=? ORDER BY m.date,m.ROWID LIMIT ? OFFSET ?", (int(chat_id), limit, offset)).fetchall()
    elif kind == "whatsapp":
        rows = db.execute("SELECT Z_PK AS id,ZTEXT AS text,ZMESSAGEDATE AS date,ZISFROMME AS from_me,NULL AS rich FROM ZWAMESSAGE WHERE ZCHATSESSION=? ORDER BY ZMESSAGEDATE,Z_PK LIMIT ? OFFSET ?", (int(chat_id), limit, offset)).fetchall()
    else:
        raise SafeError("unsupported_dataset")
    output = []
    text_bytes = 0
    for row in rows:
        body = text(row["text"])
        unsupported = False
        if not body and row["rich"]:
            decoded = attributed_text(row["rich"])
            unsupported = decoded is None
            body = decoded or "[Unsupported attributed message body]"
        output.append({"id": str(row["id"]), "text": body, "date": apple_date(row["date"]),
                       "from_me": bool(row["from_me"]), "unsupported_body": unsupported})
        text_bytes += len(body.encode())
        require(text_bytes <= (4 * 1024 ** 2 if limit <= 500 else 32 * 1024 ** 2), "archive_text_limit")
    return output


def contacts(db):
    fields = columns(db, "ABPerson")
    require({"First", "Last"} <= fields, "unsupported_backup_schema")
    org = "Organization" if "Organization" in fields else "NULL"
    rows = db.execute("SELECT ROWID AS id,First,Last," + org + " AS organization FROM ABPerson ORDER BY Last,First LIMIT 10001").fetchall()
    require(len(rows) <= 10000, "archive_contact_limit")
    result = []
    multi = columns(db, "ABMultiValue")
    for row in rows:
        values = []
        if {"record_id", "value"} <= multi:
            prop = "property" if "property" in multi else "NULL"
            for v in db.execute("SELECT value," + prop + " AS property FROM ABMultiValue WHERE record_id=? AND value IS NOT NULL LIMIT 100", (row["id"],)):
                value = text(v["value"], 10000)
                # AB property ids vary. Classify conservatively by syntax instead of inventing labels.
                kind = "email" if re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", value) else "phone" if re.fullmatch(r"[+0-9 ()\-\.]{3,100}", value) else "other"
                values.append({"value": value, "kind": kind})
        first, last, organization = text(row["First"], 1000), text(row["Last"], 1000), text(row["organization"], 1000)
        result.append({"id": str(row["id"]), "name": " ".join(x for x in (first, last) if x) or organization or "—",
                       "first": first, "last": last, "organization": organization, "values": values})
    return result


def vcard(people):
    def escape(value):
        return value.replace("\\", "\\\\").replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\\n").replace(";", "\\;").replace(",", "\\,")
    def folded(line):
        chunks, current = [], ""
        for char in line:
            if len((current + char).encode()) > 73:
                chunks.append(current); current = " "
            current += char
        chunks.append(current)
        return "\r\n".join(chunks)
    lines = []
    for p in people:
        lines += ["BEGIN:VCARD", "VERSION:3.0", "FN:" + escape(p["name"]), "N:" + escape(p["last"]) + ";" + escape(p["first"]) + ";;;"]
        if p["organization"]:
            lines.append("ORG:" + escape(p["organization"]))
        for value in p["values"]:
            prefix = {"email": "EMAIL:", "phone": "TEL:", "other": "NOTE:"}[value["kind"]]
            lines.append(prefix + escape(value["value"]))
        lines.append("END:VCARD")
    return ("\r\n".join(folded(line) for line in lines) + "\r\n").encode()


def csv_bytes(rows):
    out = io.StringIO(newline="")
    writer = csv.writer(out)
    for row in rows:
        writer.writerow(["'" + x if isinstance(x, str) and x.lstrip().startswith(("=", "+", "-", "@")) else x for x in row])
    return out.getvalue().encode("utf-8-sig")


def html_document(title, sections):
    blocks = []
    for name, rows in sections:
        blocks.append("<h2>" + html.escape(name) + "</h2>")
        for row in rows:
            blocks.append('<article class="' + ("mine" if row["from_me"] else "theirs") + '"><time>' + html.escape(row["date"]) + "</time><p>" + html.escape(row["text"]).replace("\n", "<br>") + "</p></article>")
    return ('<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'; img-src \'self\'; base-uri \'none\'; form-action \'none\'"><title>' + html.escape(title) + '</title><style>body{font:15px system-ui;max-width:900px;margin:40px auto;color:#171717;background:#fff;padding:20px}article{border:1px solid #ddd;border-radius:12px;padding:14px;margin:10px 0;break-inside:avoid}.mine{background:#eef6ff}time{font-size:12px;color:#555}p{white-space:normal;overflow-wrap:anywhere}</style></head><body><h1>' + html.escape(title) + "</h1>" + "".join(blocks) + "</body></html>").encode()


def plaintext(sections):
    return "\n\n".join(name + "\n" + "\n\n".join(row["date"] + (" · Me" if row["from_me"] else "") + "\n" + row["text"] for row in rows) for name, rows in sections).encode()


def attachment_entries(reader, db, kind, selected):
    result = {}
    coverage = {"references": 0, "missing": 0, "unsupported": 0, "schema_supported": True}
    for message_id in selected:
        paths = []
        if kind == "sms" and {"filename"} <= columns(db, "attachment") and columns(db, "message_attachment_join"):
            paths = [r[0] for r in db.execute("SELECT a.filename FROM attachment a JOIN message_attachment_join j ON j.attachment_id=a.ROWID WHERE j.message_id=?", (int(message_id),))]
            domains = ["HomeDomain", "MediaDomain"]
        elif kind == "whatsapp" and "ZMEDIAITEM" in columns(db, "ZWAMESSAGE") and "ZMEDIALOCALPATH" in columns(db, "ZWAMEDIAITEM"):
            paths = [r[0] for r in db.execute("SELECT a.ZMEDIALOCALPATH FROM ZWAMEDIAITEM a JOIN ZWAMESSAGE m ON m.ZMEDIAITEM=a.Z_PK WHERE m.Z_PK=?", (int(message_id),))]
            domains = ["AppDomainGroup-group.net.whatsapp.WhatsApp.shared", "AppDomain-net.whatsapp.WhatsApp"]
        else:
            coverage["schema_supported"] = False
        for path in paths:
            coverage["references"] += 1
            if not isinstance(path, str) or not path:
                coverage["missing"] += 1
                continue
            for prefix in ("/private/var/mobile/", "/var/mobile/", "~/"):
                if path.startswith(prefix):
                    path = path[len(prefix):]
                    break
            require(not PurePosixPath(path).is_absolute() and ".." not in PurePosixPath(path).parts, "unsafe_backup_entry")
            suffix = PurePosixPath(path).suffix.lower()
            if suffix not in {".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".mov", ".mp4", ".m4a", ".aac", ".opus", ".wav", ".pdf", ".txt"}:
                coverage["unsupported"] += 1
                continue
            try:
                entry = reader.find(domains, path)
            except SafeError as e:
                if str(e) != "dataset_not_in_backup":
                    raise
                coverage["missing"] += 1
                continue
            stored = reader.root / entry["fileID"][:2] / entry["fileID"]
            if not stored.exists():
                coverage["missing"] += 1
                continue
            result[entry["fileID"]] = entry
    return list(result.values()), coverage


def run_offline(request, emit):
    action = request["action"]
    if action == "finalize_pdf":
        return finalize_pdf(request)
    root = request.get("backup_directory", "")
    if action == "backup_inspect":
        p = Path(root)
        require(p.is_absolute() and p.resolve() == p and p.is_dir(), "unsafe_backup_path")
        manifest = plistlib.loads(bounded_read(p / "Manifest.plist", 4 * 1024 ** 2))
        info = plistlib.loads(bounded_read(p / "Info.plist", 4 * 1024 ** 2))
        status = plistlib.loads(bounded_read(p / "Status.plist", 4 * 1024 ** 2))
        return {"name": str(info.get("Device Name", "iPhone"))[:120], "ios": str(info.get("Product Version", manifest.get("Lockdown", {}).get("ProductVersion", "")))[:32],
                "model": str(info.get("Product Type", ""))[:64], "encrypted": manifest.get("IsEncrypted") is True,
                "finished": status.get("SnapshotState") == "finished", "date": str(status.get("Date", ""))[:60]}
    with BackupReader(root, request.get("backup_password", "")) as reader:
        if action == "backup_catalog":
            return {**reader.summary(), **reader.catalog(request.get("search", ""), int(request.get("offset", 0)))}
        kind = request.get("kind")
        if action == "archive_contacts":
            db = reader.dataset("contacts")
            try:
                return {"contacts": contacts(db)}
            finally:
                db.close()
        if action in ("archive_chats", "archive_messages"):
            db = reader.dataset(kind)
            try:
                if action == "archive_chats":
                    return {"chats": chats(db, kind)}
                return {"messages": messages(db, kind, request.get("chat_id"), limit=500, offset=int(request.get("offset", 0)))}
            finally:
                db.close()
        if action in ("archive_export_plan", "archive_export"):
            return export_archive(reader, request, emit)
    raise SafeError("unsupported_action")


def export_archive(reader, request, emit):
    ids = request.get("selected_ids", [])
    require(isinstance(ids, list) and 0 < len(ids) <= 1000 and all(isinstance(x, str) and re.fullmatch(r"[0-9a-fA-F]{1,40}", x) for x in ids), "selection_required")
    ids = list(dict.fromkeys(ids))
    kind = request.get("kind")
    format_ = request.get("format", "html")
    parent = output_parent(request.get("destination", ""))
    require(format_ in {"html", "csv", "vcf", "txt", "pdf", "original"}, "invalid_export_format")
    payloads = []
    attachments = []
    unsupported = 0
    coverage = None
    export_limit = 256 * 1024 ** 2
    estimated = 0
    def reserve(row):
        nonlocal estimated
        size = archived_file(row["file"]).get("Size")
        require(isinstance(size, int) and 0 <= size <= 128 * 1024 ** 2, "file_size_limit")
        estimated += size
        require(estimated <= export_limit, "transfer_size_limit")
    if kind == "files":
        require(format_ == "original", "invalid_export_format")
        rows = [reader.row(file_id) for file_id in ids]
        for row in rows:
            reserve(row)
        for row in rows:
            file_id = row["fileID"]
            name = safe_name(PurePosixPath(row["relativePath"]).name)
            payloads.append((file_id + "-" + name, reader.content(row)))
    else:
        db = reader.dataset(kind)
        try:
            if kind == "contacts":
                people = [row for row in contacts(db) if row["id"] in ids]
                require(len(people) == len(ids), "invalid_archive_selection")
                require(format_ in {"vcf", "csv"}, "invalid_export_format")
                data = vcard(people) if format_ == "vcf" else csv_bytes([["Name", "Type", "Value"]] + [[p["name"], v["kind"], v["value"]] for p in people for v in (p["values"] or [{"kind":"", "value":""}])])
                payloads = [("contacts." + format_, data)]
            else:
                chosen = [row for row in chats(db, kind) if row["id"] in ids]
                require(len(chosen) == len(ids), "invalid_archive_selection")
                require(sum(row["count"] for row in chosen) <= 50000, "archive_message_limit")
                sections = [(chat["name"], messages(db, kind, chat["id"], limit=50000)) for chat in chosen]
                unsupported = sum(row["unsupported_body"] for _, rows in sections for row in rows)
                require(format_ in {"html", "txt", "pdf", "csv"}, "invalid_export_format")
                if format_ == "html":
                    data = html_document(kind, sections)
                elif format_ == "csv":
                    data = csv_bytes([["Conversation", "UTC date", "From me", "Text"]] + [[name, row["date"], row["from_me"], row["text"]] for name, rows in sections for row in rows])
                else:
                    data = plaintext(sections)
                require(len(data) <= 64 * 1024 ** 2, "archive_text_limit")
                payloads = [("conversation." + ("txt" if format_ == "pdf" else format_), data)]
                if request.get("include_attachments"):
                    entries, coverage = attachment_entries(reader, db, kind, [row["id"] for _, rows in sections for row in rows])
                    require(len(entries) <= 2000, "archive_attachment_limit")
                    estimated = len(data)
                    for row in entries:
                        reserve(row)
                    for row in entries:
                        attachments.append(("attachments/" + row["fileID"] + PurePosixPath(row["relativePath"]).suffix.lower(), reader.content(row)))
        finally:
            db.close()
    payloads += attachments
    total = sum(len(data) for _, data in payloads)
    require(total <= export_limit, "transfer_size_limit")
    plan = {"source": reader.source_identity, "kind": kind, "format": format_, "selection": ids, "destination": str(parent), "attachment_coverage": coverage,
            "files": [{"path": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()} for name, data in payloads]}
    token = plan_digest(plan)
    if request["action"] == "archive_export_plan":
        return {"plan_token": token, "bytes": total, "count": len(payloads), "unsupported_messages": unsupported, "attachment_coverage": coverage}
    require(request.get("confirmed") is True and request.get("plan_token") == token, "plan_changed")
    job = OutputJob(parent, "PrivateExport", total, export_limit, token)
    emit({"event": "job", "directory": str(job.root)})
    for index, (name, data) in enumerate(payloads):
        job.write(name, data)
        emit({"event": "progress", "fraction": (index + 1) / len(payloads)})
    result = job.finish("needs_pdf" if format_ == "pdf" else "verified")
    result["unsupported_messages"] = unsupported
    result["attachment_coverage"] = coverage
    if coverage is not None:
        receipt = job.root / "receipt.json"
        value = json.loads(receipt.read_bytes())
        value["attachment_coverage"] = coverage
        receipt.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    if format_ == "pdf":
        result["text_path"] = str(job.root / "conversation.txt")
    return result


def finalize_pdf(request):
    root = Path(request.get("directory", ""))
    require(root.is_absolute() and root.resolve() == root and root.name.startswith("AppRestore-PrivateExport-"), "unsafe_export_path")
    value = json.loads(bounded_read(root / "receipt.json", 1024 * 1024))
    require(value.get("component") == "apprestore-private-export" and value.get("status") == "needs_pdf", "invalid_export_receipt")
    rows = value["files"]
    require(len(rows) <= 2001, "invalid_export_receipt")
    for row in rows:
        relative = PurePosixPath(row["path"])
        require(not relative.is_absolute() and ".." not in relative.parts, "unsafe_export_path")
        require(digest(root / row["path"]) == {k: row[k] for k in ("bytes", "sha256")}, "copy_verification_failed")
    pdf = root / "conversation.pdf"
    require(bounded_read(pdf, 64 * 1024 ** 2).startswith(b"%PDF-"), "invalid_pdf_export")
    rows.append({"path": pdf.name, **digest(pdf)})
    value.update(status="verified", count=len(rows), bytes=sum(x["bytes"] for x in rows))
    with (root / "receipt.json").open("w", encoding="utf8") as f:
        json.dump(value, f, ensure_ascii=False, indent=2)
    return {"directory": str(root), "count": len(rows), "bytes": value["bytes"], "verified": True}
