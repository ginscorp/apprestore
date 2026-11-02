"""Fresh invented storage accounting; no device statistics or captured logs."""
import asyncio
from datetime import datetime
from types import SimpleNamespace
import time
import unittest
from unittest.mock import patch
from storage_settings import settings_storage_numbers, read_settings_storage
from device_storage import estimated_used_bytes

def message(available=110_000_000_000, free=97_000_000_000, purgeable=13_000_000_000):
    return f'SYNTHETIC publicClientAvailableSpaceForVolume kCacheDeleteAvailableSpaceClassEssential {available} ({available / 1_000_000_000:.2f} GB) = freespace {free} + purgeableSpace: {purgeable}'

class SettingsParserChecks(unittest.TestCase):
    def test_exact_settings_accounting(self):
        result=settings_storage_numbers('Preferences','com.apple.cache_delete',message(),390_000_000_000)
        self.assertEqual(result,{'SettingsAvailableBytes':110_000_000_000,'SettingsFreeBytes':97_000_000_000,'SettingsPurgeableBytes':13_000_000_000})

    def test_unrelated_logs_invalid_math_and_bounds_rejected(self):
        for process,subsystem,text,total in [
            ('Other','com.apple.cache_delete',message(),390_000_000_000),
            ('Preferences','other',message(),390_000_000_000),
            ('Preferences','com.apple.cache_delete',message(available=113_000_000_000),390_000_000_000),
            ('Preferences','com.apple.cache_delete',message(),80_000_000_000),
            ('Preferences','com.apple.cache_delete','<private>',390_000_000_000),
            ('Preferences','com.apple.cache_delete','x'*4097,390_000_000_000),
            ('Preferences','com.apple.cache_delete',message(),True),
        ]:self.assertIsNone(settings_storage_numbers(process,subsystem,text,total))

    def test_only_numbers_leave_parser(self):
        result=settings_storage_numbers('Preferences','com.apple.cache_delete',message()+' PRIVATE_CANARY',390_000_000_000)
        self.assertNotIn('PRIVATE_CANARY',str(result))
        self.assertTrue(all(type(n) is int for n in result.values()))

    def test_zero_available_and_no_double_count_for_backup(self):
        self.assertEqual(settings_storage_numbers('Preferences','com.apple.cache_delete',message(0,0,0),100)['SettingsAvailableBytes'],0)
        self.assertEqual(estimated_used_bytes({'TotalDiskCapacity':390_000_000_000,'AmountDataAvailable':97_000_000_000,'SettingsAvailableBytes':113_000_000_000}),293_000_000_000)

class SettingsStreamChecks(unittest.IsolatedAsyncioTestCase):
    async def read_entries(self, entries, require_new=False):
        calls=[]; readiness=[]
        class Service:
            def __init__(self,ld):pass
            async def __aenter__(self):return self
            async def __aexit__(self,*args):pass
            async def get_pid_list(self):return {'Payload':{'42':{'ProcessName':'/Applications/Preferences.app/Preferences'},'43':{'ProcessName':'Other'}}}
            async def syslog(self,**options):
                calls.append(options)
                for entry in entries:yield entry
        with patch('pymobiledevice3.services.os_trace.OsTraceService',Service):
            result=await read_settings_storage(object(),390_000_000_000,timeout=.1,require_new=require_new,ready=lambda:readiness.append(True))
        self.assertEqual(readiness,[True])
        self.assertEqual(calls[0]['pid'],42)
        self.assertTrue(calls[0]['stream_flags'] & 0x80)  # NO_SENSITIVE
        return result

    def entry(self,stamp,available=110_000_000_000,free=97_000_000_000):
        return SimpleNamespace(timestamp=datetime.fromtimestamp(stamp),filename='/Applications/Preferences.app/Preferences',label=SimpleNamespace(subsystem='com.apple.cache_delete'),message=message(available,free,available-free))

    async def test_newest_numeric_observation_selected_and_old_discarded(self):
        now=time.time()
        result=await self.read_entries([self.entry(now-1000),self.entry(now-.1,113_000_000_000),self.entry(now-.3,112_000_000_000)])
        self.assertEqual(result['SettingsAvailableBytes'],113_000_000_000)
        self.assertEqual(result['SettingsObservedAtUnixSeconds'],int(now-.1))

    async def test_explicit_comparison_does_not_reuse_old_settings_value(self):
        result=await self.read_entries([self.entry(time.time()-60)],require_new=True)
        self.assertEqual(result,{})

    async def test_timeout_is_bounded_and_returns_unavailable(self):
        class Service:
            def __init__(self,ld):pass
            async def __aenter__(self):await asyncio.sleep(1)
            async def __aexit__(self,*args):pass
        started=time.monotonic()
        with patch('pymobiledevice3.services.os_trace.OsTraceService',Service):
            self.assertEqual(await read_settings_storage(object(),390_000_000_000,timeout=.01),{})
        self.assertLess(time.monotonic()-started,.5)

    async def test_settings_unavailable_does_not_start_unfiltered_stream(self):
        class Service:
            def __init__(self,ld):pass
            async def __aenter__(self):return self
            async def __aexit__(self,*args):pass
            async def get_pid_list(self):return {'Payload':{'1':{'ProcessName':'Other'}}}
            async def syslog(self,**options):raise AssertionError('must not stream')
        with patch('pymobiledevice3.services.os_trace.OsTraceService',Service):
            self.assertEqual(await read_settings_storage(object(),390_000_000_000,timeout=.1),{})
