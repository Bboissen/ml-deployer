"""Mocked streaming, version reuse, source changes and exact upload cleanup."""
from contextlib import contextmanager
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]; os.chdir(ROOT)
def module(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts/aws'/name)
    value=importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value
W=module('workspace.py'); I=module('workspace-ingest.py'); L=W.L

class Store:
    def __init__(self): self.objects={}; self.uploads={}; self.aborted=[]; self.parts=[]; self.fail=False; self.corrupt=False
    def put_object(self,**kw):
        key=kw['Key']; assert key not in self.objects
        self.objects[key]=(bytes(kw['Body']),'version-'+str(len(self.objects)))
        return {'VersionId':self.objects[key][1]}
    def get_object(self,**kw):
        data,version=self.objects[kw['Key']]
        assert kw['VersionId']==version
        if self.corrupt: data=b'x'*len(data)
        return {'ContentLength':len(data),'VersionId':version,'Body':io.BytesIO(data)}
    def create_multipart_upload(self,**kw):
        self.uploads['owned']={'Key':kw['Key'],'data':[]}; return {'UploadId':'owned'}
    def upload_part(self,**kw):
        self.parts.append(len(kw['Body']))
        if self.fail: raise RuntimeError('interrupted')
        self.uploads[kw['UploadId']]['data'].append(kw['Body'])
        return {'ETag':'part','ChecksumSHA256':kw['ChecksumSHA256']}
    def complete_multipart_upload(self,**kw):
        data=b''.join(self.uploads.pop(kw['UploadId'])['data'])
        return self.put_object(Key=kw['Key'],Body=data)
    def abort_multipart_upload(self,**kw): self.aborted.append(kw['UploadId']); self.uploads.pop(kw['UploadId'],None)
    def list_multipart_uploads(self,**kw):
        return {'Uploads':[{'UploadId':id,'Key':item['Key']} for id,item in self.uploads.items() if item['Key'].startswith(kw['Prefix'])]}

class Ingest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(dir=ROOT/'evidence'); self.addCleanup(self.tmp.cleanup)
        self.directory=Path(self.tmp.name); self.data=self.directory/'data'; self.data.mkdir()
        (self.data/'input with spaces').write_bytes(b'hello')
        self.store=Store(); self.deployment={'account_id':'111111111111','configuration':{'project':'demand','region':'us-east-1','dataset':{}},
            'names':{'workload_bucket':'owned-workload'},'dataset':{'adapter':'local','source':str(self.data)}}
    def ingest(self,name='first',**kwargs): return I.ingest(L,self.deployment,self.store,self.directory/name,**kwargs)
    def test_tree_and_repeat_reuse_exact_versions_without_upload(self):
        (self.data/'tree').mkdir(); (self.data/'tree'/'empty').write_bytes(b'')
        first=self.ingest(); count=len(self.store.objects)
        second=self.ingest('second',previous=first)
        self.assertEqual(first,second); self.assertEqual(len(self.store.objects),count)
        self.assertEqual(first['total_bytes'],5)
        self.assertEqual([r['path'] for r in first['objects']],['input with spaces','tree/empty'])
    def test_empty_input_and_symlink_are_rejected(self):
        (self.data/'input with spaces').unlink()
        with self.assertRaisesRegex(ValueError,'empty'): self.ingest()
        (self.data/'link').symlink_to('/etc/passwd')
        with self.assertRaises(OSError): self.ingest('linked')
    def test_multipart_is_bounded_and_failure_aborts_only_owned_id(self):
        (self.data/'input with spaces').write_bytes(b'a'*(I.CHUNK+123))
        self.store.fail=True; self.store.uploads['unrelated']={'Key':'unrelated/key','data':[]}
        with self.assertRaises(RuntimeError): self.ingest()
        self.assertEqual(self.store.aborted,['owned']); self.assertIn('unrelated',self.store.uploads)
        self.assertLessEqual(max(self.store.parts),I.MAX_PART)
        self.assertFalse((self.directory/'first'/'manifest.json').exists())
    def test_source_change_prevents_manifest_and_compute(self):
        adapter=I.Local(self.data); original=adapter.inventory; calls=[]
        def changed(deadline):
            calls.append(True)
            if len(calls)==2: (self.data/'new').write_bytes(b'changed')
            return original(deadline)
        adapter.inventory=changed
        with self.assertRaisesRegex(ValueError,'mixed snapshot'): self.ingest(adapter=adapter)
        self.assertFalse((self.directory/'first'/'manifest.json').exists())
    def test_duplicate_names_byte_ceiling_and_corruption_stop(self):
        adapter=I.Local(self.data); records=adapter.inventory(time.monotonic()+10)
        with self.assertRaisesRegex(ValueError,'duplicate'): self.ingest(inventory=records+records)
        self.deployment['configuration']['dataset']['maximum_bytes']=4
        with self.assertRaisesRegex(ValueError,'ceiling'): self.ingest('ceiling')
        self.deployment['configuration']['dataset'].clear(); self.store.corrupt=True
        with self.assertRaisesRegex(ValueError,'checksum'): self.ingest('checksum')
    def test_changed_retained_bytes_are_not_trusted_from_metadata(self):
        first=self.ingest(); self.store.corrupt=True
        with self.assertRaisesRegex(ValueError,'checksum'): self.ingest('repeat',previous=first)
    def test_lost_multipart_create_response_reconciles_unique_operation_key(self):
        (self.data/'input with spaces').write_bytes(b'a'*(I.CHUNK+1)); create=self.store.create_multipart_upload
        def uncertain(**kw): create(**kw); raise TimeoutError('lost response')
        self.store.create_multipart_upload=uncertain
        with self.assertRaises(TimeoutError): self.ingest()
        self.assertEqual(self.store.aborted,['owned']); self.assertFalse(self.store.uploads)
    def test_multipart_success_seals_all_parts(self):
        (self.data/'input with spaces').write_bytes(b'a'*(I.CHUNK+17))
        result=self.ingest()
        self.assertEqual(self.store.parts,[I.CHUNK,17])
        self.assertFalse(self.store.uploads)
        self.assertEqual(result['total_bytes'],I.CHUNK+17)
    def test_s3_pins_source_version_and_detects_replacement(self):
        from types import SimpleNamespace
        data=b'remote'; versions=['source-version']
        api=SimpleNamespace(get_bucket_location=lambda **_: {'LocationConstraint':None},
            head_object=lambda **_: {'ContentLength':len(data),'ETag':'etag','VersionId':versions[0]},
            get_object=lambda **kw: {'ContentLength':len(data),'ETag':'etag','VersionId':versions[0],'Body':io.BytesIO(data)})
        adapter=I.S3('s3://source-bucket/path/input',api,'us-east-1')
        record=adapter.inventory(time.monotonic()+10)[0]
        self.assertEqual(record['source_version'],'source-version')
        versions[0]='changed'
        with self.assertRaisesRegex(ValueError,'version changed'):
            with adapter.open(record): pass
    def test_https_conditional_stream_and_expired_url(self):
        from types import SimpleNamespace
        class Response(io.BytesIO):
            headers={'Content-Length':'3','ETag':'"strong"'}
        requests=[]
        def open_(request,**_): requests.append(request); return Response(b'abc')
        with patch.object(I,'public_url',side_effect=lambda url:url),patch.object(I,'build_opener',return_value=SimpleNamespace(open=open_)):
            adapter=I.HTTPS('https://example.org/file.csv')
        record=adapter.inventory(time.monotonic()+10)[0]
        self.assertEqual(record['sha256'],hashlib.sha256(b'abc').hexdigest())
        self.assertEqual(requests[-1].get_header('If-match'),'"strong"')
        adapter.opener.open=lambda *a,**kw: (_ for _ in ()).throw(TimeoutError('expired'))
        with self.assertRaises(TimeoutError): adapter.inventory(time.monotonic()+10)
    def test_https_refuses_private_credentials_and_redirect(self):
        addresses=[(None,None,None,None,('127.0.0.1',443))]
        with patch.object(I.socket,'getaddrinfo',return_value=addresses):
            with self.assertRaisesRegex(ValueError,'non-public'): I.public_url('https://example.org/file')
        for url in ('http://example.org/file','https://user:token@example.org/file','https://example.org/file?token=x'):
            with self.assertRaises(ValueError): I.public_url(url)
    def test_source_changed_after_inventory_before_upload(self):
        adapter=I.Local(self.data); records=adapter.inventory(time.monotonic()+10)
        (self.data/'input with spaces').write_bytes(b'other')
        with self.assertRaisesRegex(ValueError,'source changed'): self.ingest(adapter=adapter,inventory=records)

if __name__=='__main__': unittest.main(verbosity=2)
