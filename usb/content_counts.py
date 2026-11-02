"""Read aggregate counters over existing USB trust; never start a sync session."""
import asyncio
import plistlib
import struct
import time

MAX_COUNT = 100_000_000
ALIASES = {
    'SongCount': ('SongCount', 'NumberOfSongs'),
    'VideoCount': ('VideoCount', 'NumberOfVideos'),
    'PhotoCount': ('PhotoCount', 'NumberOfPhotos'),
    'ApplicationCount': ('ApplicationCount', 'NumberOfApplications', 'InstalledApplicationCount'),
}


def count(value):
    if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= MAX_COUNT:
        return value
    return None


def direct_counts(values):
    if not isinstance(values, dict):
        return {}
    result = {}
    for key, aliases in ALIASES.items():
        for alias in aliases:
            number = count(values.get(alias))
            if number is not None:
                result[key] = number
                break
    return result


def atc_counts(metrics):
    if not isinstance(metrics, dict):
        return {}
    result = {}
    for key, path in [('SongCount', ('Media','Music')), ('ApplicationCount', ('Application',))]:
        node = metrics
        for part in path:
            node = node.get(part) if isinstance(node, dict) else None
        number = count(node.get('_Count')) if isinstance(node, dict) else None
        if number is not None:
            result[key] = number
    # Photo.CameraRoll includes other records and is not the About photo count.
    return result


async def read_content_counts(ld, values=None):
    result = direct_counts(ld.all_values if values is None else values)
    sources = {key:'apple_lockdown' for key in result}
    diagnostics = {}
    if len(result) < 4:
        try:
            summary = await asyncio.wait_for(ld.get_value(domain='com.apple.mobile.iTunes'), timeout=1)
            for key, value in direct_counts(summary).items():
                if key not in result:
                    result[key] = value
                    sources[key] = 'apple_itunes_summary'
        except Exception:
            pass
    if not {'SongCount','ApplicationCount'} <= result.keys():
        try:
            metrics = await asyncio.wait_for(passive_asset_metrics(ld), timeout=2)
            photo = metrics.get('Photo') if isinstance(metrics, dict) else None
            camera = photo.get('CameraRoll') if isinstance(photo, dict) else None
            raw_count = count(camera.get('_Count')) if isinstance(camera, dict) else None
            if raw_count is not None:
                diagnostics = {'AppleCameraRollUsageCount':raw_count,
                    'AppleCameraRollUsageObservedAtUnixSeconds':int(time.time())}
            for key, value in atc_counts(metrics).items():
                if key not in result:
                    result[key] = value
                    sources[key] = 'apple_atc_metrics'
        except Exception:
            pass
    if not {'PhotoCount','VideoCount'} <= result.keys():
        try:
            from photo_counts import read_photo_counts
            photo = await asyncio.wait_for(read_photo_counts(ld), timeout=6)
            for key, value in direct_counts(photo).items():
                if key not in result:
                    result[key] = value
                    sources[key] = 'apple_photos_aggregate'
        except Exception:
            pass
    statuses = {key:'available' if key in result else 'not_returned' for key in ALIASES}
    return {'values':result,'sources':sources,'status':statuses,
            'observed_at':int(time.time()) if result else None,'diagnostics':diagnostics}


def passport_fields(summary):
    values, sources, statuses = summary['values'], summary['sources'], summary['status']
    fields = [{'key':key,'section':'storage','value':str(value),'source':sources[key]}
              for key, value in values.items()]
    for key, value in statuses.items():
        fields.append({'key':key+'Status','section':'availability','value':value,'source':'apprestore_capability'})
    if summary['observed_at'] is not None:
        fields.append({'key':'ContentCountsObservedAtUnixSeconds','section':'storage',
                       'value':str(summary['observed_at']),'source':'apprestore_measurement'})
    diagnostics = summary.get('diagnostics', {})
    raw = count(diagnostics.get('AppleCameraRollUsageCount'))
    stamp = diagnostics.get('AppleCameraRollUsageObservedAtUnixSeconds')
    if raw is not None and type(stamp) is int and 1_577_836_800 <= stamp <= int(time.time())+60:
        fields.extend([
            {'key':'AppleCameraRollUsageCount','section':'storage','value':str(raw),'source':'apple_atc_metrics'},
            {'key':'AppleCameraRollUsageObservedAtUnixSeconds','section':'storage','value':str(stamp),'source':'apprestore_measurement'},
            {'key':'AppleCameraRollUsageInterpretation','section':'availability','value':'requires_interpretation','source':'apprestore_capability'},
        ])
    return fields


async def passive_asset_metrics(ld):
    """ATC sends startup metrics without any host command or sync negotiation.

    The frame prefix is little-endian (unlike most lockdown services). After a
    cancelled/failed read the connection is closed; no attempt to reuse it.
    """
    service = None
    try:
        service = await ld.start_lockdown_service('com.apple.atc')
        for _ in range(8):
            length = struct.unpack('<I', await service.recvall(4))[0]
            if not 0 < length <= 1024 * 1024:
                raise ValueError('metrics_frame_limit')
            message = plistlib.loads(await service.recvall(length))
            if not isinstance(message, dict):
                raise ValueError('invalid_metrics')
            if message.get('Command') == 'AssetMetrics':
                params = message.get('Params')
                return params if isinstance(params, dict) else {}
            if message.get('Command') == 'SyncAllowed':
                return {}
        return {}
    finally:
        if service is not None:
            await service.close()
