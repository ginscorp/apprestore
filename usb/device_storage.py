"""Read storage counters only. Never treat TotalDataAvailable as free space.

Modern iOS can return a much larger TotalDataAvailable than the filesystem has
free. AmountDataAvailable is the device's write-available counter; AFC is a
fallback when that counter is unavailable. No directory or user-file reads.
"""
import asyncio
import math

DISK_KEYS = (
    'TotalDiskCapacity', 'TotalDataCapacity', 'TotalDataAvailable',
    'TotalSystemCapacity', 'TotalSystemAvailable', 'AmountDataAvailable',
    'AmountDataReserved', 'AmountRestoreAvailable', 'AmountDataUsed',
    'AmountCameraUsage', 'AmountApplicationUsage', 'AmountMusicUsage',
    'AmountVideoUsage', 'AmountPhotoUsage',
)


def byte_count(value):
    if type(value) not in (int, float) or not math.isfinite(value):
        return None
    if not 0 <= value <= 2**50 or int(value) != value:
        return None
    return int(value)


def counters(raw):
    if not isinstance(raw, dict):
        return {}
    return {key: number for key in DISK_KEYS
            if (number := byte_count(raw.get(key))) is not None}


def available_bytes(storage):
    for free_key, total_key in [('AmountDataAvailable', 'TotalDiskCapacity'),
                                ('AFCFreeBytes', 'AFCTotalBytes')]:
        free = byte_count(storage.get(free_key))
        total = byte_count(storage.get(total_key))
        if free is not None and total is not None and total > 0 and 0 <= free <= total:
            return free
    return None


def estimated_used_bytes(storage):
    # A conservative preflight estimate, not the size of the eventual backup.
    total = byte_count(storage.get('TotalDataCapacity'))
    if total is None:
        total = byte_count(storage.get('TotalDiskCapacity'))
    free = available_bytes(storage)
    return total - free if total is not None and free is not None and free <= total else None


async def read_storage(ld, settings_timeout=0, require_new_settings=False, settings_ready=None, settings_diagnostics=None):
    try:
        raw = await asyncio.wait_for(ld.get_value(domain='com.apple.disk_usage'), timeout=5)
        result = counters(raw)
    except Exception:
        result = {}
    if available_bytes(result) is None:
        try:
            from pymobiledevice3.services.afc import AfcService
            async with AfcService(ld) as afc:
                info = await asyncio.wait_for(afc.get_device_info(), timeout=5)
            for source, target in [('FSTotalBytes', 'AFCTotalBytes'), ('FSFreeBytes', 'AFCFreeBytes')]:
                value = info.get(source)
                if isinstance(value, str) and value.isascii() and value.isdigit() and len(value) <= 16:
                    number = byte_count(int(value))
                    if number is not None:
                        result[target] = number
        except Exception:
            pass
    if settings_timeout:
        from storage_settings import read_settings_storage
        result.update(await read_settings_storage(ld,result.get('TotalDiskCapacity'),
            timeout=settings_timeout,require_new=require_new_settings,ready=settings_ready,diagnostics=settings_diagnostics))
    return result
