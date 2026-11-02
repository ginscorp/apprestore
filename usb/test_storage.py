"""Fresh invented storage accounting; no device statistics or captured logs."""
import unittest
from unittest.mock import patch
from device_storage import counters, available_bytes, estimated_used_bytes, read_storage


class StorageChecks(unittest.TestCase):
    def test_inflated_ios_counter_is_not_free_space(self):
        storage = counters({'TotalDiskCapacity': 390_000_000_000,
                            'TotalDataCapacity': 380_000_000_000,
                            'TotalDataAvailable': 337_000_000_000,
                            'AmountDataAvailable': 110_000_000_000})
        self.assertEqual(available_bytes(storage), 110_000_000_000)
        self.assertEqual(estimated_used_bytes(storage), 270_000_000_000)

    def test_no_guess_from_total_data_available(self):
        storage = {'TotalDiskCapacity': 390_000_000_000, 'TotalDataAvailable': 337_000_000_000}
        self.assertIsNone(available_bytes(storage))
        self.assertIsNone(estimated_used_bytes(storage))

    def test_invalid_counts_excluded_and_zero_free_valid(self):
        for value in [True, False, -1, float('nan'), float('inf'), 1.5, 2**51, '238000000000']:
            self.assertEqual(counters({'AmountDataAvailable': value}), {})
        self.assertEqual(available_bytes({'TotalDiskCapacity': 100, 'AmountDataAvailable': 0}), 0)
        self.assertIsNone(available_bytes({'TotalDiskCapacity': 100, 'AmountDataAvailable': 101}))

    def test_invalid_pair_does_not_hide_valid_afc(self):
        storage = {'TotalDiskCapacity': 100, 'AmountDataAvailable': 101,
                   'AFCTotalBytes': 90, 'AFCFreeBytes': 50}
        self.assertEqual(available_bytes(storage), 50)


class ReadStorageChecks(unittest.IsolatedAsyncioTestCase):
    async def test_available_counter_needs_no_afc_or_user_file_access(self):
        class Device:
            async def get_value(self, domain):
                assert domain == 'com.apple.disk_usage'
                return {'TotalDiskCapacity': 100, 'AmountDataAvailable': 30, 'Opaque': b'secret'}
        with patch('pymobiledevice3.services.afc.AfcService', side_effect=AssertionError('unexpected AFC')):
            self.assertEqual(await read_storage(Device()), {'TotalDiskCapacity': 100, 'AmountDataAvailable': 30})

    async def test_fallback_reads_only_filesystem_counters(self):
        class Device:
            async def get_value(self, domain):
                return {'TotalDataAvailable': 99}
        class AFC:
            def __init__(self, device): pass
            async def __aenter__(self): return self
            async def __aexit__(self, *args): pass
            async def get_device_info(self):
                return {'FSTotalBytes': '100', 'FSFreeBytes': '30', 'Model': 'CANARY'}
        with patch('pymobiledevice3.services.afc.AfcService', AFC):
            storage = await read_storage(Device())
        self.assertEqual(storage, {'TotalDataAvailable': 99, 'AFCTotalBytes': 100, 'AFCFreeBytes': 30})
        self.assertEqual(available_bytes(storage), 30)

    async def test_failed_services_leave_unknown_not_zero(self):
        class Device:
            async def get_value(self, domain): raise ValueError('unavailable')
        with patch('pymobiledevice3.services.afc.AfcService', side_effect=ValueError('unavailable')):
            storage = await read_storage(Device())
        self.assertEqual(storage, {})
        self.assertIsNone(available_bytes(storage))
