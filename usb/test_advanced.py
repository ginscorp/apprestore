import asyncio
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from advanced import normalized_layout, run_advanced, screenshot_result
from backup_reader import BackupReader, memory_database
from indicators import Matcher, load_feed, run_indicators, scan
from safety import SafeError
from test_workspace import make_backup, sql_image


class AdvancedChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="apprestore-advanced-fixture-")
        self.root = Path(self.tmp.name).resolve()
    def tearDown(self):
        self.tmp.cleanup()
    def feed(self, patterns):
        value = {"type":"bundle", "objects":[{"type":"indicator", "id":"indicator--fixture-"+str(i), "pattern":p} for i,p in enumerate(patterns)]}
        path = self.root/"fixture.stix2";path.write_text(json.dumps(value));return path
    def test_home_layout_bounded_and_allowlisted(self):
        result = normalized_layout([[{"bundleIdentifier":"fixture.app","displayName":"Name","opaqueSecret":"CANARY"},
                                    {"displayName":"Folder","iconLists":[[{"displayIdentifier":"fixture.other"}]]}, {"widgetSecret":"CANARY"}]])
        self.assertFalse(result["restorable"]);self.assertEqual(result["unsupported"],1)
        self.assertNotIn("CANARY",json.dumps(result))
        with self.assertRaises(SafeError):normalized_layout([{}]*101)
        nested=[]
        for _ in range(12):nested=[nested]
        with self.assertRaises(SafeError):normalized_layout(nested)
    def test_screenshot_bounds_and_explicit_confirmation(self):
        data=b'\x89PNG\r\n\x1a\n'+b'\0'*8+struct.pack('>II',1170,2532)
        self.assertEqual(base64.b64decode(screenshot_result(data)["png"]),data)
        with self.assertRaises(SafeError):screenshot_result(data[:16]+struct.pack('>II',50000,50000))
        with self.assertRaisesRegex(SafeError,"confirmation_required"):
            asyncio.run(run_advanced({"action":"screen_capture"},None))
    def test_literal_indicators_and_domain_boundaries(self):
        path=self.feed(["[domain-name:value = 'bad.example']", "[url:value = 'https://bad.example/exact']",
                        "[app:id = 'fixture.spy']", "[file:name = 'suspect.db']",
                        "[domain-name:value MATCHES '.*']", "[domain-name:value = 'x'] OR [app:id = 'x']"])
        indicators,meta=load_feed(path);self.assertEqual(meta["supported"],4);self.assertEqual(meta["unsupported_or_inactive"],2)
        matcher=Matcher(indicators)
        matcher.url('https://notbad.example/PRIVATE_CANARY','sms',1)
        self.assertEqual(matcher.matches,[])
        matcher.url('https://sub.bad.example/PRIVATE_CANARY?secret=TOKEN','sms',2)
        matcher.url('https://bad.example/exact','safari',3)
        self.assertEqual(len(matcher.matches),3)
        self.assertNotIn('PRIVATE_CANARY',json.dumps(matcher.matches));self.assertNotIn('TOKEN',json.dumps(matcher.matches))
    def test_partial_schema_and_no_network_resolution(self):
        path=self.feed(["[domain-name:value = 'bad.example']"]);indicators,meta=load_feed(path)
        class Reader:
            info={"Applications":{"fixture.normal":{}}}
            def dataset(self,kind):
                return memory_database(sql_image("CREATE TABLE message(text TEXT);INSERT INTO message VALUES('PRIVATE_CANARY https://bad.example/path?token=HIDDEN');"))
            def find(self,*_):raise SafeError("dataset_not_in_backup")
        with patch('socket.getaddrinfo',side_effect=AssertionError("network forbidden")):
            result=scan(Reader(),indicators,meta,["apps","sms","safari"])
        self.assertTrue(result["partial"]);self.assertTrue(result["not_a_clean_bill"]);self.assertFalse(result["network_used"])
        self.assertEqual(len(result["matches"]),1)
        self.assertNotIn('PRIVATE_CANARY',json.dumps(result));self.assertNotIn('HIDDEN',json.dumps(result))
    def test_encrypted_backup_ioc_and_changed_plan(self):
        root=self.root/'Backup';make_backup(root,encrypted=True)
        info=plistlib.loads((root/'Info.plist').read_bytes());info['Applications']={'fixture.spy':{'iTunesMetadata':b'PRIVATE_OWNER_CANARY'}}
        (root/'Info.plist').write_bytes(plistlib.dumps(info))
        path=self.feed(["[app:id = 'fixture.spy']"])
        before={p.relative_to(root):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
        request={"action":"ioc_check","backup_directory":str(root),"backup_password":"SYNTHETIC_PASSWORD_ONLY","indicator_file":str(path),"sources":["apps"]}
        result=run_indicators(request);self.assertEqual(len(result['matches']),1);self.assertNotIn('PRIVATE_OWNER_CANARY',json.dumps(result))
        request.update(action='ioc_export_plan',destination=str(self.root));plan=run_indicators(request)
        request.update(action='ioc_export',confirmed=True,plan_token=plan['plan_token']);result=run_indicators(request)
        self.assertTrue(result['verified']);self.assertEqual(result['count'],2)
        info['Applications']={};(root/'Info.plist').write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(SafeError,'plan_changed'):run_indicators(request)
        info['Applications']={'fixture.spy':{'iTunesMetadata':b'PRIVATE_OWNER_CANARY'}};(root/'Info.plist').write_bytes(plistlib.dumps(info))
        after={p.relative_to(root):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
        self.assertEqual(before,after)
    def test_protected_feed_rejected_before_read(self):
        with self.assertRaisesRegex(SafeError,'protected_file_blocked'):load_feed('/not/read/credentials.json')
    def test_indicator_match_limit_bounds_memory(self):
        matcher=Matcher({('domain-name:value','bad.example'):['id-'+str(i) for i in range(10000)]})
        for row in range(100):matcher.url('https://bad.example/private','sms',row)
        self.assertTrue(matcher.truncated);self.assertEqual(len(matcher.matches),5000);self.assertEqual(len(matcher.seen),5000)


if __name__=='__main__':unittest.main()
