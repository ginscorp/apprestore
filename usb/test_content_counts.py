"""Offline fixtures authored synthetically; no device dumps or owner statistics."""
import asyncio
from pathlib import Path
import sqlite3
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

from content_counts import atc_counts, direct_counts, passport_fields, read_content_counts
from content_counts import passive_asset_metrics
from photo_counts import aggregate_photos, committed_database, read_photo_counts, MAX_DATABASE


class CounterParsing(unittest.TestCase):
    def test_zero_is_a_real_value_and_invalid_counts_are_absent(self):
        self.assertEqual(direct_counts({'SongCount':0,'PhotoCount':True,'VideoCount':-1,'ApplicationCount':2**60}), {'SongCount':0})
        self.assertEqual(direct_counts({'NumberOfPhotos':113,'NumberOfVideos':19,'InstalledApplicationCount':41}),
                         {'PhotoCount':113,'VideoCount':19,'ApplicationCount':41})

    def test_atc_combined_photo_counter_is_not_a_photo_count(self):
        self.assertEqual(atc_counts({'Photo':{'CameraRoll':{'_Count':4191}},'Media':{'Music':{'_Count':37}},
                                     'Application':{'_Count':41,'Names':['PRIVATE_CANARY']}}),
                         {'SongCount':37,'ApplicationCount':41})


class PhotoSnapshotTests(unittest.TestCase):
    @staticmethod
    def fixture(connection):
        connection.execute('CREATE TABLE ZASSET(ZKIND INTEGER,ZTRASHEDSTATE INTEGER,ZHIDDEN INTEGER,ZVISIBILITYSTATE INTEGER,PRIVATE_TEXT TEXT)')
        connection.executemany('INSERT INTO ZASSET VALUES(?,?,?,?,?)',[
            (0,0,0,0,'PRIVATE_CANARY'),(0,0,0,0,'PRIVATE_CANARY'),(1,0,0,0,'PRIVATE_CANARY'),
            (0,1,0,0,'PRIVATE_CANARY'),(1,0,1,0,'PRIVATE_CANARY'),(0,0,0,16,'PRIVATE_CANARY')])
        connection.commit()

    def test_visible_photo_and_video_totals_only(self):
        connection=sqlite3.connect(':memory:')
        try:
            self.fixture(connection)
            result=aggregate_photos(connection.serialize())
            self.assertEqual(result,{'PhotoCount':2,'VideoCount':1})
            self.assertNotIn('PRIVATE_CANARY',str(result))
        finally:connection.close()

    def test_committed_wal_is_applied_not_stale_main_database(self):
        with tempfile.TemporaryDirectory(prefix='counts-wal-',dir='/private/tmp') as directory:
            file=Path(directory)/'fixture.sqlite'
            connection=sqlite3.connect(file)
            try:
                self.fixture(connection)
                connection.execute('PRAGMA journal_mode=WAL')
                connection.execute('PRAGMA wal_autocheckpoint=0')
                connection.execute("INSERT INTO ZASSET VALUES(0,0,0,0,'PRIVATE_CANARY')")
                connection.commit()
                database=file.read_bytes();wal=Path(str(file)+'-wal').read_bytes()
                self.assertEqual(aggregate_photos(database,wal),{'PhotoCount':3,'VideoCount':1})
                self.assertEqual(aggregate_photos(database),{'PhotoCount':2,'VideoCount':1})
                broken=bytearray(wal);broken[24]^=1
                with self.assertRaises(ValueError):aggregate_photos(database,bytes(broken))
                broken=bytearray(wal);broken[-1]^=1
                with self.assertRaises(ValueError):aggregate_photos(database,bytes(broken))
            finally:connection.close()

    def test_limits_and_unknown_schema_do_not_produce_zero(self):
        with self.assertRaises(ValueError):committed_database(b'invalid')
        connection=sqlite3.connect(':memory:')
        try:
            connection.execute('CREATE TABLE unrelated(private TEXT)')
            with self.assertRaises(ValueError):aggregate_photos(connection.serialize())
        finally:connection.close()


class IntegrationCounts(unittest.IsolatedAsyncioTestCase):
    async def test_passive_atc_reads_metrics_without_sending_commands(self):
        messages=[{'Command':'InstalledAssets','Params':{'PRIVATE_CANARY':['private.name']}},
                  {'Command':'AssetMetrics','Params':{'Media':{'Music':{'_Count':0}}}}]
        chunks=[]
        for message in messages:
            raw=plistlib.dumps(message,fmt=plistlib.FMT_BINARY)
            chunks += [struct.pack('<I',len(raw)),raw]
        class Service:
            closed=False
            async def recvall(self,size):
                data=chunks.pop(0);assert len(data)==size;return data
            async def close(self):self.closed=True
            async def sendall(self,data):raise AssertionError('must not send ATC commands')
        service=Service()
        class Device:
            async def start_lockdown_service(self,name):
                assert name=='com.apple.atc';return service
        result=await passive_asset_metrics(Device())
        self.assertTrue(service.closed)
        self.assertNotIn('PRIVATE_CANARY',str(result))
        self.assertEqual(atc_counts(result),{'SongCount':0})

    async def test_oversized_photo_metadata_never_opens_or_reads_file(self):
        class Service:
            async def __aenter__(self):return self
            async def __aexit__(self,*args):pass
            async def stat(self,path):
                return {'st_ifmt':'S_IFDIR'} if path=='/PhotoData' else {'st_ifmt':'S_IFREG','st_size':MAX_DATABASE+1}
            async def fopen(self,*args):raise AssertionError('oversized database must not be opened')
        with patch('pymobiledevice3.services.afc.AfcService',return_value=Service()):
            with self.assertRaises(ValueError):await read_photo_counts(object())

    async def test_all_counters_and_sources_only_leave_collector(self):
        # All counts below are invented; they are not copied from device output.
        class Device:
            all_values={}
            async def get_value(self,domain=None):return {'Password':'PRIVATE_CANARY'}
        with patch('content_counts.passive_asset_metrics',AsyncMock(return_value={'Media':{'Music':{'_Count':37}},'Application':{'_Count':41},'Photo':{'CameraRoll':{'_Count':4191,'PRIVATE_TEXT':'PRIVATE_CANARY'}}})), \
             patch('photo_counts.read_photo_counts',AsyncMock(return_value={'PhotoCount':113,'VideoCount':19})):
            result=await read_content_counts(Device())
        self.assertEqual(result['values'],{'SongCount':37,'ApplicationCount':41,'PhotoCount':113,'VideoCount':19})
        self.assertEqual(result['diagnostics']['AppleCameraRollUsageCount'],4191)
        self.assertTrue(all(x=='available' for x in result['status'].values()))
        fields=passport_fields(result)
        self.assertNotIn('PRIVATE_CANARY',str(fields))
        self.assertEqual(len({f['key'] for f in fields}),len(fields))
        mapped={field['key']:field for field in fields}
        self.assertEqual(mapped['AppleCameraRollUsageCount']['value'],'4191')
        self.assertEqual(mapped['AppleCameraRollUsageCount']['source'],'apple_atc_metrics')
        self.assertEqual(mapped['AppleCameraRollUsageInterpretation']['value'],'requires_interpretation')
        self.assertNotIn('AppleCameraRollUsageCount',result['values'])

    async def test_absent_sources_report_missing_not_zero(self):
        class Device:
            all_values={}
            async def get_value(self,domain=None):return {}
        with patch('content_counts.passive_asset_metrics',AsyncMock(side_effect=ConnectionError)), \
             patch('photo_counts.read_photo_counts',AsyncMock(side_effect=ValueError)):
            result=await read_content_counts(Device())
        self.assertEqual(result['values'],{})
        self.assertIsNone(result['observed_at'])
        self.assertTrue(all(x=='not_returned' for x in result['status'].values()))

    async def test_direct_complete_values_do_not_open_extra_services(self):
        class Device:all_values={'SongCount':0,'VideoCount':19,'PhotoCount':113,'ApplicationCount':41}
        with patch('content_counts.passive_asset_metrics',AsyncMock()) as atc,patch('photo_counts.read_photo_counts',AsyncMock()) as photos:
            result=await read_content_counts(Device())
        atc.assert_not_awaited();photos.assert_not_awaited()
        self.assertEqual(result['values'],Device.all_values)
        self.assertEqual(result['diagnostics'],{})

    def test_invalid_diagnostic_counter_does_not_enter_passport(self):
        import time
        for invalid in (True,-1,2**60,'777',float('nan')):
            summary={'values':{},'sources':{},'status':{},'observed_at':None,
                'diagnostics':{'AppleCameraRollUsageCount':invalid,'AppleCameraRollUsageObservedAtUnixSeconds':int(time.time())}}
            self.assertEqual(passport_fields(summary),[])

    def test_invalid_diagnostic_time_does_not_enter_passport(self):
        import time
        for invalid in (True,0,'now',int(time.time())+3600):
            summary={'values':{},'sources':{},'status':{},'observed_at':None,
                'diagnostics':{'AppleCameraRollUsageCount':777,'AppleCameraRollUsageObservedAtUnixSeconds':invalid}}
            self.assertEqual(passport_fields(summary),[])
