import asyncio
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import stat
import tempfile
import unittest
import subprocess
import sys
import signal
import time
from types import SimpleNamespace
from unittest.mock import patch

from archive_data import (chats, contacts, export_archive, html_document, messages,
                          run_offline, vcard, csv_bytes)
from backup_reader import BackupReader, memory_database
from safety import SafeError, OutputJob, package_compatibility, remote_path, protected_name
from workspace import crash_fields, transfer_documents
from private_backup import WriteBoundary, temporary_files_in


def sql_image(statements):
    db=sqlite3.connect(":memory:")
    db.executescript(statements)
    data=db.serialize(); db.close()
    return data


def archived_metadata(data, key=None):
    obj={"Size":len(data),"Mode":stat.S_IFREG|0o600,"Digest":plistlib.UID(2)}
    objects=["$null",obj,hashlib.sha1(data).digest()]
    if key:
        obj["EncryptionKey"]=plistlib.UID(3);objects.append({"NS.data":key})
    return plistlib.dumps({"$version":100000,"$archiver":"NSKeyedArchiver","$top":{"root":plistlib.UID(1)},"$objects":objects},fmt=plistlib.FMT_BINARY)


def make_backup(root, encrypted=False):
    root.mkdir()
    now=datetime(2026,10,30,tzinfo=timezone.utc)
    manifest={"IsEncrypted":encrypted,"Lockdown":{"ProductVersion":"26.7.1","ProductType":"iPhone12,1"}}
    wrapping=None
    password="SYNTHETIC_PASSWORD_ONLY"
    if encrypted:
        from cryptography.hazmat.primitives.keywrap import aes_key_wrap
        salt=b"s"*20; dpsalt=b"d"*20
        derived=hashlib.pbkdf2_hmac('sha256',password.encode(),dpsalt,1000,32)
        derived=hashlib.pbkdf2_hmac('sha1',derived,salt,1000,32)
        wrapping=b"w"*32
        def tlv(tag,value):
            value=value.to_bytes(4,'big') if isinstance(value,int) else value
            return tag+len(value).to_bytes(4,'big')+value
        root_values=[(b'VERS',3),(b'TYPE',1),(b'UUID',b'u'*16),(b'WRAP',2),(b'SALT',salt),(b'ITER',1000),(b'DPSL',dpsalt),(b'DPIC',1000)]
        cls=[(b'UUID',b'c'*16),(b'CLAS',4),(b'WRAP',2),(b'KTYP',0),(b'WPKY',aes_key_wrap(derived,wrapping))]
        manifest['BackupKeyBag']=b''.join(tlv(k,v) for k,v in root_values+cls)
    def encrypt(data):
        from cryptography.hazmat.primitives.ciphers import Cipher,algorithms,modes
        from cryptography.hazmat.primitives.keywrap import aes_key_wrap
        from cryptography.hazmat.primitives import padding
        key=b'f'*32
        pad=padding.PKCS7(128).padder();payload=pad.update(data)+pad.finalize()
        enc=Cipher(algorithms.AES(key),modes.CBC(b'\x00'*16)).encryptor()
        return enc.update(payload)+enc.finalize(),(4).to_bytes(4,'little')+aes_key_wrap(wrapping,key)
    files={
      ('HomeDomain','Library/SMS/sms.db'):sql_image("""
        CREATE TABLE chat(chat_identifier TEXT,display_name TEXT);
        INSERT INTO chat VALUES('fixture-a','Selected Chat'); INSERT INTO chat VALUES('fixture-b','Unselected Chat');
        CREATE TABLE message(text TEXT,date INTEGER,is_from_me INTEGER,attributedBody BLOB);
        INSERT INTO message VALUES('<script>not executable</script>',1000000000,1,NULL);
        INSERT INTO message VALUES('UNSELECTED_SECRET_CANARY',2000000000,0,NULL);
        CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
        INSERT INTO chat_message_join VALUES(1,1); INSERT INTO chat_message_join VALUES(2,2);
        CREATE TABLE attachment(filename TEXT); CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
      """),
      ('HomeDomain','Library/AddressBook/AddressBook.sqlitedb'):sql_image("""
        CREATE TABLE ABPerson(First TEXT,Last TEXT,Organization TEXT);
        INSERT INTO ABPerson VALUES('Тест','Фамилия',NULL);
        CREATE TABLE ABMultiValue(record_id INTEGER,value TEXT,property INTEGER);
        INSERT INTO ABMultiValue VALUES(1,'+123456789',3);
      """),
      ('AppDomainGroup-group.net.whatsapp.WhatsApp.shared','ChatStorage.sqlite'):sql_image("""
        CREATE TABLE ZWACHATSESSION(Z_PK INTEGER,ZCONTACTJID TEXT,ZPARTNERNAME TEXT);
        INSERT INTO ZWACHATSESSION VALUES(1,'fixture@invalid','Fixture');
        CREATE TABLE ZWAMESSAGE(Z_PK INTEGER,ZCHATSESSION INTEGER,ZTEXT TEXT,ZMESSAGEDATE REAL,ZISFROMME INTEGER);
        INSERT INTO ZWAMESSAGE VALUES(1,1,'WhatsApp fixture',1000.0,0);
      """),
      ('HomeDomain','Documents/public.txt'):b'Fixture export',
      ('HomeDomain','Documents/credentials.json'):b'SECRET_CANARY_NEVER_EXPORT',
    }
    db=sqlite3.connect(":memory:");db.execute('CREATE TABLE Files(fileID TEXT,domain TEXT,relativePath TEXT,flags INTEGER,file BLOB)')
    ids={}
    for (domain,path),data in files.items():
        file_id=hashlib.sha1((domain+'-'+path).encode()).hexdigest();ids[path]=file_id
        payload,key=encrypt(data) if encrypted else (data,None)
        folder=root/file_id[:2];folder.mkdir(exist_ok=True);(folder/file_id).write_bytes(payload)
        db.execute('INSERT INTO Files VALUES(?,?,?,?,?)',(file_id,domain,path,1,archived_metadata(data,key)))
    image=db.serialize();db.close()
    if encrypted:
        image,key=encrypt(image);manifest['ManifestKey']=key
    (root/'Manifest.db').write_bytes(image)
    (root/'Manifest.plist').write_bytes(plistlib.dumps(manifest))
    (root/'Info.plist').write_bytes(plistlib.dumps({'Device Name':'Synthetic Phone','Product Version':'26.7.1','Product Type':'iPhone12,1'}))
    (root/'Status.plist').write_bytes(plistlib.dumps({'Date':now,'SnapshotState':'finished'}))
    return ids,password


class WorkspaceChecks(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='apprestore-fixtures-')
        self.root=Path(self.temp.name).resolve();self.backup=self.root/'Backup';self.ids,self.password=make_backup(self.backup)
    def tearDown(self):self.temp.cleanup()
    def test_exact_ios_and_family(self):
        info={'MinimumOSVersion':'26.7','CFBundleSupportedPlatforms':['iPhoneOS'],'UIDeviceFamily':[1],'CFBundleIdentifier':'fixture.app'}
        self.assertTrue(package_compatibility(info,'26.7.1')['compatible'])
        for version in ['26.6.9','unknown','26.beta']:
            with self.assertRaises(SafeError):package_compatibility(info,version)
        with self.assertRaises(SafeError):package_compatibility(info,'26.7.1','iPad')
    def test_paths_and_secrets(self):
        for path in ['../escape','/Documents/../escape','/a\\b','/a\x00']:
            with self.assertRaises(SafeError):remote_path(path)
        for name in ['credentials.json','.env','id_ed25519','sample.p12']:
            self.assertTrue(protected_name(name))
    def test_manifest_memory_only_and_parameterized_search(self):
        before={str(p.relative_to(self.backup)):p.read_bytes() for p in self.backup.rglob('*') if p.is_file()}
        with BackupReader(self.backup) as reader:
            self.assertEqual(reader.summary()['ios'],'26.7.1')
            self.assertEqual(reader.catalog("' OR 1=1 --")['files'],[])
            self.assertEqual(reader.content(reader.row(self.ids['Documents/public.txt'])),b'Fixture export')
            with self.assertRaises(SafeError):reader.content(reader.row(self.ids['Documents/credentials.json']))
        after={str(p.relative_to(self.backup)):p.read_bytes() for p in self.backup.rglob('*') if p.is_file()}
        self.assertEqual(before,after)
    def test_selected_sms_export_excludes_other_chat_and_escapes_html(self):
        request={'kind':'sms','selected_ids':['1'],'format':'html','destination':str(self.root),'action':'archive_export_plan'}
        with BackupReader(self.backup) as reader:
            plan=export_archive(reader,request,lambda _:None)
            request.update(action='archive_export',confirmed=True,plan_token=plan['plan_token'])
            result=export_archive(reader,request,lambda _:None)
        data=(Path(result['directory'])/'conversation.html').read_text()
        self.assertIn('&lt;script&gt;',data);self.assertNotIn('UNSELECTED_SECRET_CANARY',data)
        self.assertIn("default-src 'none'",data)
        self.assertEqual((Path(result['directory'])/'conversation.html').stat().st_mode&0o777,0o600)
    def test_changed_plan_rejected_without_export(self):
        with BackupReader(self.backup) as reader:
            request={'kind':'contacts','selected_ids':['1'],'format':'vcf','destination':str(self.root),'action':'archive_export','confirmed':True,'plan_token':'bad'}
            with self.assertRaises(SafeError):export_archive(reader,request,lambda _:None)
        self.assertFalse(list(self.root.glob('AppRestore-*')))
    def test_contacts_and_whatsapp(self):
        with BackupReader(self.backup) as reader:
            with reader.dataset('contacts') as db:
                people=contacts(db);self.assertEqual(people[0]['values'][0]['kind'],'phone')
                output=vcard(people).decode();self.assertIn('BEGIN:VCARD',output);self.assertIn('Тест',output)
            with reader.dataset('whatsapp') as db:
                self.assertEqual(chats(db,'whatsapp')[0]['count'],1)
                self.assertEqual(messages(db,'whatsapp','1')[0]['text'],'WhatsApp fixture')
        self.assertIn("'=FORMULA",csv_bytes([['=FORMULA']]).decode('utf-8-sig'))
    def test_real_encrypted_fixture_and_wrong_password(self):
        encrypted=self.root/'Encrypted';ids,password=make_backup(encrypted,True)
        with self.assertRaises(SafeError):BackupReader(encrypted,'WRONG_SYNTHETIC')
        with BackupReader(encrypted,password) as reader:
            self.assertTrue(reader.summary()['encrypted'])
            self.assertEqual(reader.content(reader.row(ids['Documents/public.txt'])),b'Fixture export')
        self.assertFalse(list(encrypted.glob('*.sqlite3')))
    def test_symlink_and_incomplete_rejected(self):
        link=self.root/'Linked';link.symlink_to(self.backup,target_is_directory=True)
        with self.assertRaises(SafeError):BackupReader(link)
        (self.backup/'Status.plist').write_bytes(plistlib.dumps({'SnapshotState':'writing'}))
        with self.assertRaises(SafeError):BackupReader(self.backup)
    def test_output_budget_and_no_overwrite(self):
        job=OutputJob(self.root,'Fixture',1,2,'fixture')
        job.write('a.txt',b'x')
        with self.assertRaises(SafeError):job.write('a.txt',b'y')
        with self.assertRaises(SafeError):job.write('../out',b'y')
        with self.assertRaises(SafeError):job.write('b.txt',b'large')
        self.assertTrue(job.finish()['verified'])
    def test_crash_response_allowlist(self):
        data=(json.dumps({'app_name':'Fixture','timestamp':'2026','bundleID':'fixture.app'})+'\n'+json.dumps({'exception':{'type':'EXC_CRASH','signal':'SIGABRT','secret':'CANARY'},'termination':{'namespace':'CODESIGNING','code':1},'threads':['SECRET_CANARY']})).encode()
        summary=crash_fields(data);self.assertEqual(summary['termination_namespace'],'CODESIGNING')
        self.assertNotIn('CANARY',json.dumps(summary))

    def test_backup_write_boundary_and_symlink_escape(self):
        job=self.root/'Job';job.mkdir();outside=self.root/'Outside';outside.mkdir()
        boundary=WriteBoundary(job,job)
        boundary('open',(str(job/'owned'), 'w', os.O_WRONLY))
        for event,args in [('open',(str(outside/'untouched'),'w',os.O_WRONLY)),('os.remove',(str(outside/'untouched'),)),('os.rename',(str(job/'a'),str(outside/'b'))),('os.symlink',('a',str(job/'link')))]:
            with self.assertRaises(SafeError):boundary(event,args)
        (job/'escape').symlink_to(outside,target_is_directory=True)
        with self.assertRaises(SafeError):boundary.check(job/'escape'/'anything')
        self.assertFalse(list(outside.iterdir()))

    def test_pending_wal_stops_dataset_export(self):
        file_id='1'*40;folder=self.backup/'11';folder.mkdir(exist_ok=True)
        payload=b'wal-not-a-consistent-snapshot'*4;(folder/file_id).write_bytes(payload)
        db=sqlite3.connect(self.backup/'Manifest.db')
        db.execute('INSERT INTO Files VALUES(?,?,?,?,?)',(file_id,'HomeDomain','Library/SMS/sms.db-wal',1,archived_metadata(payload)));db.commit();db.close()
        with BackupReader(self.backup) as reader:
            with self.assertRaisesRegex(SafeError,'pending_wal'):reader.dataset('sms')

    def test_export_limit_checked_before_content_read(self):
        db=sqlite3.connect(self.backup/'Manifest.db')
        huge=plistlib.dumps({'$objects':['$null',{'Size':200*1024**2,'Mode':stat.S_IFREG}], '$top':{'root':plistlib.UID(1)}},fmt=plistlib.FMT_BINARY)
        db.execute('UPDATE Files SET file=? WHERE fileID=?',(huge,self.ids['Documents/public.txt']));db.commit();db.close()
        with BackupReader(self.backup) as reader,patch.object(reader,'content',side_effect=AssertionError('must not load')):
            with self.assertRaisesRegex(SafeError,'file_size_limit'):
                export_archive(reader,{'action':'archive_export_plan','kind':'files','format':'original','selected_ids':[self.ids['Documents/public.txt']],'destination':str(self.root)},lambda _:None)

    def test_pdf_stays_incomplete_until_verified(self):
        request={'action':'archive_export_plan','kind':'sms','format':'pdf','selected_ids':['1'],'destination':str(self.root)}
        with BackupReader(self.backup) as reader:
            plan=export_archive(reader,request,lambda _:None);request.update(action='archive_export',confirmed=True,plan_token=plan['plan_token'])
            result=export_archive(reader,request,lambda _:None)
        folder=Path(result['directory']);self.assertFalse(result['verified']);self.assertTrue(result['needs_pdf'])
        self.assertEqual(json.loads((folder/'receipt.json').read_text())['status'],'needs_pdf')
        with self.assertRaises(SafeError):run_offline({'action':'finalize_pdf','directory':str(folder)},lambda _:None)

    def test_document_export_is_planned_and_checked(self):
        class AFC:
            data=b'Only selected document';offset=0;opened=0
            async def stat(self,path):return {'st_ifmt':'S_IFREG','st_size':len(self.data),'st_mtime':'stable'}
            async def fopen(self,path,mode):self.offset=0;self.opened+=1;return 1
            async def fread(self,h,size):chunk=self.data[self.offset:self.offset+size];self.offset+=len(chunk);return chunk
            async def fclose(self,h):pass
        service=AFC();device=SimpleNamespace(udid='SYNTHETIC_ONLY',product_version='26.7.1')
        request={'action':'file_plan','bundle':'fixture.app','paths':['/document.txt'],'destination':str(self.root)}
        plan=asyncio.run(transfer_documents(request,device,service,lambda _:None));self.assertEqual(service.opened,0)
        request.update(action='file_export',confirmed=True,plan_token=plan['plan_token'])
        result=asyncio.run(transfer_documents(request,device,service,lambda _:None))
        self.assertEqual((Path(result['directory'])/'document.txt').read_bytes(),service.data)
        self.assertTrue(result['verified'])
        request['paths']=['/another.txt']
        with self.assertRaisesRegex(SafeError,'plan_changed'):asyncio.run(transfer_documents(request,device,service,lambda _:None))

    def test_attachment_coverage_explicit_when_schema_absent(self):
        request={'action':'archive_export_plan','kind':'whatsapp','format':'html','include_attachments':True,'selected_ids':['1'],'destination':str(self.root)}
        with BackupReader(self.backup) as reader:plan=export_archive(reader,request,lambda _:None)
        self.assertFalse(plan['attachment_coverage']['schema_supported'])

    def test_sql_work_budget_blocks_unbounded_query(self):
        db=memory_database(sql_image('CREATE TABLE fixture(value INTEGER);'))
        try:
            with self.assertRaises(sqlite3.OperationalError):db.execute('WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<1000000000) SELECT sum(x) FROM n').fetchone()
        finally:db.close()

    def test_library_temporary_files_stay_in_private_boundary(self):
        job=self.root/'Job';job.mkdir();temporary=self.root/'PrivateTemporary';temporary.mkdir()
        boundary=WriteBoundary(job,temporary)
        before=tempfile.tempdir
        with temporary_files_in(temporary):
            with tempfile.NamedTemporaryFile() as f:
                boundary.check(f.name);f.write(b'SYNTHETIC TLS DATA ONLY')
                self.assertTrue(Path(f.name).is_relative_to(temporary))
        self.assertEqual(tempfile.tempdir,before)
        self.assertFalse(list(temporary.iterdir()))

    def test_cancellation_runs_private_temporary_cleanup(self):
        created=[]
        async def operation():
            with tempfile.TemporaryDirectory(dir=self.root) as directory,temporary_files_in(directory):
                with tempfile.NamedTemporaryFile(delete=False) as f:
                    created.append(Path(f.name));f.write(b'NO OWNER DATA')
                await asyncio.Event().wait()
        async def check():
            task=asyncio.create_task(operation());await asyncio.sleep(0);task.cancel()
            with self.assertRaises(asyncio.CancelledError):await task
        asyncio.run(check());self.assertTrue(created);self.assertFalse(created[0].exists());self.assertFalse(created[0].parent.exists())

    def test_sigterm_cleans_temporary_scope(self):
        marker=self.root/'ready.txt'
        script='''import asyncio,sys,tempfile
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import bridge
from private_backup import temporary_files_in
async def fixture(request,directory):
    with tempfile.TemporaryDirectory(dir=sys.argv[2]) as temporary,temporary_files_in(temporary):
        with tempfile.NamedTemporaryFile(delete=False) as f:f.write(b"SYNTHETIC ONLY")
        Path(sys.argv[3]).write_text(temporary)
        await asyncio.Event().wait()
bridge.run=fixture
try:asyncio.run(bridge.cancellable_run({},Path(sys.argv[2]),30))
except bridge.SafeError as error:print(str(error))
'''
        child=subprocess.Popen([sys.executable,'-c',script,str(Path(__file__).parent),str(self.root),str(marker)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            deadline=time.monotonic()+5
            while not marker.exists() and time.monotonic()<deadline:time.sleep(0.01)
            self.assertTrue(marker.exists());directory=Path(marker.read_text())
            child.send_signal(signal.SIGTERM);output,error=child.communicate(timeout=5)
            self.assertEqual(child.returncode,0);self.assertEqual(output.strip(),'operation_cancelled');self.assertEqual(error,'');self.assertFalse(directory.exists())
        finally:
            if child.poll() is None:child.kill();child.wait()


if __name__=='__main__':unittest.main()
