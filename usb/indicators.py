"""Small OFFLINE IOC matcher, not MVT or an antivirus verdict. Decrypts selected databases in RAM only."""
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import html
import json
from pathlib import Path, PurePosixPath
import re
from urllib.parse import urlsplit, urlunsplit

from backup_reader import BackupReader, archived_file, memory_database
from safety import OutputJob, SafeError, bounded_read, output_parent, plan_digest, protected_name, require

OFFLINE_ACTIONS = {"ioc_check", "ioc_export_plan", "ioc_export"}
SUPPORTED = {"domain-name:value", "url:value", "app:id", "file:name"}
PATTERN = re.compile(r"^\[([a-z-]+:[a-z]+)\s*=\s*'((?:[^'\\\r\n]|\\['\\]){1,2048})'\]$")


def host(value):
    try:
        value = value.rstrip(".").encode("idna").decode().lower()
        require(len(value) <= 253 and re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", value), "invalid_indicator")
        require(all(x and len(x) <= 63 for x in value.split(".")), "invalid_indicator")
        return value
    except (UnicodeError, ValueError):
        raise SafeError("invalid_indicator") from None


def canonical_url(value):
    require(isinstance(value, str) and len(value) <= 8192 and not any(ord(x) < 32 for x in value), "invalid_indicator")
    parts = urlsplit(value)
    require(parts.scheme.lower() in {"http", "https"} and parts.hostname and not parts.username and not parts.password, "invalid_indicator")
    name = host(parts.hostname)
    port = parts.port
    netloc = name + ((":" + str(port)) if port and (parts.scheme.lower(), port) not in {("http", 80), ("https", 443)} else "")
    return urlunsplit((parts.scheme.lower(), netloc, parts.path or "/", parts.query, "")), name


def load_feed(path):
    require(not protected_name(path), "protected_file_blocked")
    raw = bounded_read(path, 8 * 1024 ** 2)
    try:
        bundle = json.loads(raw)
    except (ValueError, RecursionError):
        raise SafeError("invalid_indicator_feed") from None
    require(isinstance(bundle, dict) and bundle.get("type") == "bundle" and isinstance(bundle.get("objects"), list), "invalid_indicator_feed")
    require(len(bundle["objects"]) <= 50000, "indicator_feed_limit")
    table = defaultdict(list)
    skipped = 0
    for item in bundle["objects"]:
        if not isinstance(item, dict) or item.get("type") != "indicator":
            continue
        try:
            require(item.get("pattern_type", "stix") == "stix" and not item.get("revoked", False), "unsupported_indicator")
            expiry = item.get("valid_until")
            if expiry:
                require(datetime.fromisoformat(expiry.replace("Z", "+00:00")) > datetime.now(timezone.utc), "expired_indicator")
            since = item.get("valid_from")
            if since:
                require(datetime.fromisoformat(since.replace("Z", "+00:00")) <= datetime.now(timezone.utc), "future_indicator")
            pattern = item.get("pattern", "")
            require(isinstance(pattern, str) and len(pattern) <= 2300, "unsupported_indicator")
            match = PATTERN.fullmatch(pattern)
            require(match and match[1] in SUPPORTED, "unsupported_indicator")
            kind, value = match[1], re.sub(r"\\(['\\])", r"\1", match[2])
            if kind == "domain-name:value":
                value = host(value)
            elif kind == "url:value":
                value, _ = canonical_url(value)
            elif kind == "app:id":
                require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{1,239}", value), "invalid_indicator")
            else:
                require(PurePosixPath(value).name == value and not protected_name(value), "invalid_indicator")
            ident = str(item.get("id", ""))[:128]
            table[(kind, value)].append(ident)
        except (SafeError, ValueError, TypeError, OverflowError):
            skipped += 1
    supported = sum(map(len, table.values()))
    require(supported > 0, "no_supported_indicators")
    return table, {"sha256": hashlib.sha256(raw).hexdigest(), "supported": supported, "unsupported_or_inactive": skipped}


class Matcher:
    def __init__(self, indicators):
        self.indicators = indicators
        self.matches = []
        self.seen = set()
        self.truncated = False

    def match(self, kind, value, dataset, record):
        ids = self.indicators.get((kind, value), [])
        for ident in ids:
            if len(self.matches) >= 5000:
                self.truncated = True
                return
            key = (ident, kind, value, dataset, str(record))
            if key in self.seen:
                continue
            self.seen.add(key)
            # Only the PUBLIC indicator and a row/file ID are returned, never private text/URLs.
            self.matches.append({"indicator": ident, "kind": kind, "value": value, "dataset": dataset, "record": str(record)[:80]})

    def url(self, value, dataset, record):
        try:
            canonical, name = canonical_url(value)
        except (SafeError, ValueError):
            return
        self.match("url:value", canonical, dataset, record)
        parts = name.split(".")
        for index in range(len(parts)):
            self.match("domain-name:value", ".".join(parts[index:]), dataset, record)


def safari_database(reader):
    entry = reader.find(["HomeDomain", "AppDomain-com.apple.mobilesafari"], "Library/Safari/History.db")
    wal = reader.connection.execute("SELECT file FROM Files WHERE domain=? AND relativePath=? AND flags=1", (entry["domain"], entry["relativePath"] + "-wal")).fetchone()
    require(wal is None or archived_file(wal["file"]).get("Size", 0) <= 32, "backup_dataset_has_pending_wal")
    return memory_database(reader.content(entry))


def scan(reader, indicators, feed, sources):
    require(isinstance(sources, list) and 0 < len(sources) <= 4 and len(set(sources)) == len(sources) and set(sources) <= {"apps", "filenames", "sms", "safari"}, "selection_required")
    matcher = Matcher(indicators)
    coverage = []
    for source in sources:
        count = 0
        state = "checked"
        try:
            if source == "apps":
                apps = reader.info.get("Applications")
                require(isinstance(apps, dict) and len(apps) <= 5000, "dataset_not_in_backup")
                for key in apps:
                    require(not matcher.truncated, "indicator_match_limit")
                    if isinstance(key, str):
                        matcher.match("app:id", key, source, hashlib.sha256(key.encode()).hexdigest()[:20]);count += 1
            elif source == "filenames":
                rows = reader.connection.execute("SELECT fileID,relativePath,domain FROM Files WHERE flags=1 LIMIT 200001").fetchall()
                require(len(rows) <= 200000, "indicator_scope_limit")
                for row in rows:
                    require(not matcher.truncated, "indicator_match_limit")
                    if row["domain"] != "KeychainDomain" and isinstance(row["relativePath"], str) and not protected_name(row["relativePath"]):
                        matcher.match("file:name", PurePosixPath(row["relativePath"]).name, source, row["fileID"]);count += 1
            else:
                db = reader.dataset("sms") if source == "sms" else safari_database(reader)
                try:
                    query = "SELECT ROWID AS id,text AS value FROM message WHERE text IS NOT NULL LIMIT 50001" if source == "sms" else "SELECT id,url AS value FROM history_items LIMIT 50001"
                    rows = db.execute(query)
                    total = 0
                    for row in rows:
                        require(not matcher.truncated, "indicator_match_limit")
                        require(count < 50000, "indicator_scope_limit")
                        value = row["value"]
                        require(isinstance(value, str) and len(value) <= 100000, "unsupported_backup_schema")
                        total += len(value)
                        require(total <= 64 * 1024 ** 2, "indicator_scope_limit")
                        if source == "safari":
                            matcher.url(value, source, row["id"])
                        else:
                            for url in re.findall(r"https?://[^\s<>\"']{1,8192}", value):
                                matcher.url(url.rstrip(".,;!?)"), source, row["id"])
                        count += 1
                finally:
                    db.close()
        except Exception as error:
            # Schema failures are partial coverage, never a successful clean result.
            state = str(error) if isinstance(error, SafeError) else "unsupported_backup_schema"
        coverage.append({"source": source, "count": count, "status": state})
    return {"schema": 1, "component": "apprestore-limited-offline-ioc", "not_a_clean_bill": True,
            "network_used": False, "feed": feed, "coverage": coverage, "matches": matcher.matches,
            "matches_truncated": matcher.truncated, "partial": matcher.truncated or any(x["status"] != "checked" for x in coverage),
            "limitations": ["Only literal domain, URL, app ID and filename indicators are supported.",
                            "SMS text URLs only; attributed-only bodies, redirects and shortened URLs are not resolved.",
                            "No live filesystem, process, memory or full forensic analysis. Absence of matches does not prove safety."]}


def run_indicators(request):
    indicators, feed = load_feed(request.get("indicator_file", ""))
    with BackupReader(request.get("backup_directory", ""), request.get("backup_password", "")) as reader:
        result = scan(reader, indicators, feed, request.get("sources"))
        identity = reader.source_identity
    if request["action"] == "ioc_check":
        return result
    parent = output_parent(request.get("destination", ""))
    encoded = json.dumps(result, ensure_ascii=False, indent=2).encode()
    token = plan_digest({"source": identity, "result": hashlib.sha256(encoded).hexdigest(), "destination": str(parent)})
    if request["action"] == "ioc_export_plan":
        return {"plan_token": token, "count": 2, "bytes": len(encoded) * 6 + 1024, "partial": result["partial"]}
    require(request.get("confirmed") is True and request.get("plan_token") == token, "plan_changed")
    document = ("<!doctype html><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"><title>Limited offline IOC check</title><h1>Limited offline IOC check</h1><p>Matches require expert interpretation. No matches does NOT prove device safety.</p><pre>" + html.escape(encoded.decode()) + "</pre>").encode()
    job = OutputJob(parent, "Indicators", len(encoded) + len(document), 32 * 1024 ** 2, token)
    job.write("indicators.json", encoded)
    job.write("indicators.html", document)
    return job.finish()
