"""Extract only numeric storage accounting from Settings' CacheDelete message.

Never retain a syslog record or infer purgeable space from TotalDataAvailable.
"""
import re
import asyncio
import posixpath
import time
from device_storage import byte_count

_ESSENTIAL = re.compile(
    r'publicClientAvailableSpaceForVolume\s+kCacheDeleteAvailableSpaceClassEssential\s+'
    r'(\d{1,16})\s*\([^\r\n)]{0,40}\)\s*=\s*freespace\s+(\d{1,16})\s*'
    r'\+\s*purgeableSpace:\s*(\d{1,16})(?:\s|$)'
)


def settings_storage_numbers(process, subsystem, message, total):
    if process != 'Preferences' or subsystem != 'com.apple.cache_delete':
        return None
    if not isinstance(message, str) or len(message) > 4096:
        return None
    total = byte_count(total)
    if total is None or total <= 0:
        return None
    match = _ESSENTIAL.search(message)
    if not match:
        return None
    available, free, purgeable = (int(x) for x in match.groups())
    if not (0 <= free <= available <= total and 0 <= purgeable <= total and available == free+purgeable):
        return None
    return {'SettingsAvailableBytes':available, 'SettingsFreeBytes':free,
            'SettingsPurgeableBytes':purgeable}


async def read_settings_storage(ld, total, timeout=2, require_new=False, ready=None, diagnostics=None):
    """Bounded, PID-filtered, NO_SENSITIVE stream; retain numeric matches only.

    Automatic calls may use a Settings observation from the last two minutes.
    Explicit comparison waits for a new observation. Neither starts Settings or
    changes logging configuration. No archive, message, PID or process list is saved.
    """
    if byte_count(total) is None or total <= 0 or not 0 < timeout <= 30:
        return {}
    diag=diagnostics if diagnostics is not None else {}
    diag.update(stage='opening_process_list',records=0,recent=0,cachedelete=0,numeric_matches=0)
    from pymobiledevice3.services.os_trace import OsTraceService, OsActivityStreamFlag as F
    best = {}
    best_stamp = 0
    started = time.time()
    minimum = started-2 if require_new else started-120

    async def watch():
        nonlocal best, best_stamp
        async with OsTraceService(ld) as service:
            payload=(await service.get_pid_list()).get('Payload',{})
        if not isinstance(payload,dict):return
        pids=[int(pid) for pid,info in payload.items()
              if str(pid).isdigit() and isinstance(info,dict) and
              isinstance(info.get('ProcessName'),str) and
              posixpath.basename(info['ProcessName'])=='Preferences']
        if len(pids)!=1:return
        diag['stage']='opening_log_stream'
        flags=F.PAYLOAD|F.HISTORICAL|F.INFO|F.DEBUG|F.NO_SENSITIVE
        records=0
        async with OsTraceService(ld) as service:
            diag['stage']='reading'
            diag['ready_after_ms']=int((time.time()-started)*1000)
            if ready:ready()
            async for entry in service.syslog(pid=pids[0],stream_flags=int(flags)):
                records+=1
                diag['records']=records
                if records>20000:return
                stamp=entry.timestamp.timestamp()
                if entry.label and entry.label.subsystem=='com.apple.cache_delete':diag['cachedelete']+=1
                if not minimum<=stamp<=time.time()+5:continue
                diag['recent']+=1
                numbers=settings_storage_numbers(posixpath.basename(entry.filename),
                    entry.label.subsystem if entry.label else '',entry.message,total)
                if numbers and stamp>=best_stamp:
                    diag['numeric_matches']+=1
                    best_stamp=stamp
                    best={**numbers,'SettingsObservedAtUnixSeconds':int(stamp)}
                    if require_new:return
    try:await asyncio.wait_for(watch(),timeout+15 if require_new else timeout)
    except asyncio.TimeoutError:diag['stage']='timeout'
    except Exception as error:diag['stage']='unavailable';diag['error_type']=type(error).__name__
    return best
