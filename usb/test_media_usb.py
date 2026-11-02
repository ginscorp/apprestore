import ast
import asyncio
import base64
from datetime import datetime, timezone
import hashlib
from pathlib import Path
import unittest

from media_usb import catalog_page, checked_row, dcim_path, media_row, preview_file, stream_file
from safety import SafeError


class MediaAFC:
    def __init__(self):
        self.data=b'ORIGINAL_PNG_BYTES'*170000
        self.position=0;self.closed=False;self.changed=False;self.link=False
    async def stat(self,path):
        if path in {'/DCIM','/DCIM/100APPLE'}:return {'st_ifmt':'S_IFLNK' if self.link else 'S_IFDIR'}
        return {'st_ifmt':'S_IFREG','st_size':len(self.data)+(1 if self.changed else 0),'st_birthtime':datetime(2026,10,30,tzinfo=timezone.utc),'st_mtime':datetime(2026,10,30,tzinfo=timezone.utc)}
    async def listdir(self,path):return ['.','..','100APPLE'] if path=='/DCIM' else ['IMG_0001.PNG','IMG_0002.MP4','credentials.json']
    async def fopen(self,path,mode):assert mode=='r';self.position=0;return 1
    async def fread(self,handle,count):result=self.data[self.position:self.position+count];self.position+=len(result);return result
    async def fclose(self,handle):self.closed=True


class MediaUSBChecks(unittest.TestCase):
    def request(self,service):
        row=asyncio.run(service.stat('/DCIM/100APPLE/IMG_0001.PNG'))
        return {'path':'/DCIM/100APPLE/IMG_0001.PNG','fingerprint':media_row('/DCIM/100APPLE/IMG_0001.PNG',row)['fingerprint']}
    def test_dcim_boundary_and_secret_extensions(self):
        for path in ['/DCIMevil/a.png','/PhotoData/Photos.sqlite','/DCIM/../a.png','/DCIM/100APPLE/.env','/DCIM/100APPLE/credentials.json','/DCIM//a.png','/DCIM/100APPLE/a\\b.png']:
            with self.assertRaises(SafeError):dcim_path(path,file=True)
    def test_catalog_includes_screenshots_and_videos(self):
        service=MediaAFC();root=asyncio.run(catalog_page(service,{'path':'/DCIM'}));self.assertEqual(root['folders'],['/DCIM/100APPLE'])
        page=asyncio.run(catalog_page(service,{'path':'/DCIM/100APPLE'}));self.assertEqual([x['name'] for x in page['files']],['IMG_0001.PNG','IMG_0002.MP4']);self.assertEqual(page['skipped'],1);self.assertFalse(page['has_more'])
        service.link=True
        with self.assertRaisesRegex(SafeError,'media_symlink_blocked'):asyncio.run(catalog_page(service,{'path':'/DCIM/100APPLE'}))
    def test_hidden_ios_bookkeeping_does_not_block_catalog(self):
        class Hidden(MediaAFC):
            async def listdir(self,path):return ['.','..','.metadata','100APPLE']
        page=asyncio.run(catalog_page(Hidden(),{'path':'/DCIM'}))
        self.assertEqual(page['folders'],['/DCIM/100APPLE']);self.assertEqual(page['skipped'],1)
    def test_preview_checks_source_and_bounds(self):
        service=MediaAFC();request=self.request(service);value=asyncio.run(preview_file(service,request));self.assertEqual(base64.b64decode(value['data']),service.data);self.assertTrue(service.closed)
        request['fingerprint']='0'*64
        with self.assertRaisesRegex(SafeError,'source_changed'):asyncio.run(preview_file(service,request))
    def test_page_token_rejects_changed_listing(self):
        class Many(MediaAFC):
            async def listdir(self,path):return [f'IMG_{i:04}.PNG' for i in range(602 if self.changed else 601)]
        service=Many();first=asyncio.run(catalog_page(service,{'path':'/DCIM/100APPLE'}));self.assertEqual(len(first['files']),300);self.assertTrue(first['has_more'])
        request={'path':'/DCIM/100APPLE','offset':300,'catalog_token':first['catalog_token']};self.assertEqual(len(asyncio.run(catalog_page(service,request))['files']),300)
        service.changed=True
        with self.assertRaisesRegex(SafeError,'media_catalog_changed'):asyncio.run(catalog_page(service,request))
    def test_stream_chunks_original_bytes_and_sha(self):
        service=MediaAFC();request=self.request(service);events=[];result=asyncio.run(stream_file(service,request,events.append))
        self.assertEqual(events[0]['event'],'media_header');chunks=[x for x in events if x['event']=='media_chunk'];self.assertGreater(len(chunks),1)
        actual=b''.join(base64.b64decode(x['data']) for x in chunks);self.assertEqual(actual,service.data);self.assertEqual(result['sha256'],hashlib.sha256(actual).hexdigest());self.assertEqual(result['bytes'],len(actual));self.assertFalse(result['source_deleted']);self.assertTrue(service.closed)
    def test_source_change_during_stream_stops_success(self):
        service=MediaAFC();request=self.request(service)
        def emitted(value):
            if value['event']=='media_chunk':service.changed=True
        with self.assertRaisesRegex(SafeError,'source_changed'):asyncio.run(stream_file(service,request,emitted))
        self.assertTrue(service.closed)
    def test_media_layer_has_no_device_write_calls(self):
        tree=ast.parse(Path(__file__).with_name('media_usb.py').read_text())
        methods={node.func.attr for node in ast.walk(tree) if isinstance(node,ast.Call) and isinstance(node.func,ast.Attribute) and isinstance(node.func.value,ast.Name) and node.func.value.id=='service'}
        self.assertLessEqual(methods,{'stat','listdir','fopen','fread','fclose'})
        for node in ast.walk(tree):
            if isinstance(node,ast.Call) and isinstance(node.func,ast.Attribute) and node.func.attr=='fopen':self.assertEqual(node.args[1].value,'r')


if __name__=='__main__':unittest.main()
