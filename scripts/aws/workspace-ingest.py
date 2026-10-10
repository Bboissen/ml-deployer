"""Streamed dataset ingestion; exact versions and checksums precede compute."""
from contextlib import contextmanager
import base64
import importlib.util
import hashlib
import http.client
import ipaddress
import json
import math
import os
from pathlib import Path
import socket
import stat
import time
from urllib.parse import urlsplit, unquote
from urllib.request import Request, build_opener, HTTPRedirectHandler, ProxyHandler, HTTPSHandler
import uuid

spec=importlib.util.spec_from_file_location('workspace_files',Path(__file__).with_name('workspace_files.py'))
files=importlib.util.module_from_spec(spec); spec.loader.exec_module(files)
local_file,local_stamp=files.local_file,files.local_stamp

CHUNK=8*1024*1024
MAX_PART=64*1024*1024

def require(condition, reason):
    if not condition: raise ValueError(reason)

def canonical(value):
    return (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()

def relative(path):
    require(isinstance(path,str) and path and not path.startswith('/') and '\\' not in path and
            all(p not in ('','.','..') for p in path.split('/')), 'relative dataset path without traversal required')
    return path

def stream_hash(stream,size,deadline,cancelled=None):
    digest=hashlib.sha256(); count=0
    while True:
        require(time.monotonic()<deadline and not (cancelled and cancelled()),'dataset transfer cancelled/time bound exhausted')
        chunk=stream.read(CHUNK)
        if not chunk: break
        count+=len(chunk); require(count<=size,'source grew beyond reviewed bytes'); digest.update(chunk)
    require(count==size,'source size changed or incomplete read')
    return digest.hexdigest()

def inventory_bound(adapter, size, used=0):
    require(size>=0 and size<=640*1024**3 and used+size<=getattr(adapter,'maximum_bytes',640*1024**3),'dataset exceeds selected byte bound')

class Local:
    def __init__(self,source): self.root=Path(source).absolute()
    def paths(self):
        require(not any(p.is_symlink() for p in (self.root,*self.root.parents)),'dataset symlinks unsupported')
        require(self.root.is_file() or self.root.is_dir(),'local source missing or unsupported')
        if self.root.is_file(): return [(self.root.name,self.root)]
        result=[]
        def denied(_): raise ValueError('dataset directory cannot be read')
        for directory,folders,files in os.walk(self.root,followlinks=False,onerror=denied):
            require(not any((Path(directory)/d).is_symlink() for d in folders),'directory symlink unsupported')
            for name in files:
                path=Path(directory)/name; result.append((relative(path.relative_to(self.root).as_posix()),path))
                require(len(result)<=100000,'dataset file-count bound exceeded')
        return sorted(result)
    def inventory(self,deadline):
        records=[]
        for name,path in self.paths():
            with local_file(path) as stream:
                before=local_stamp(stream); inventory_bound(self,before[2],sum(r['bytes'] for r in records))
                checksum=stream_hash(stream,before[2],deadline,getattr(self,'cancelled',None))
                require(local_stamp(stream)==before,'source changed while hashing')
            records.append({'path':name,'bytes':before[2],'sha256':checksum,'source_stamp':before})
        require(records,'empty dataset directory'); return records
    @contextmanager
    def open(self,record):
        with local_file(self.root if self.root.is_file() else self.root/record['path']) as stream:
            require(local_stamp(stream)==record['source_stamp'],'source changed before upload')
            yield stream
            require(local_stamp(stream)==record['source_stamp'],'source changed during upload')

class S3:
    def __init__(self,source,s3,region):
        parts=urlsplit(source); self.bucket=parts.netloc; self.key=parts.path.lstrip('/'); self.api=s3
        require((s3.get_bucket_location(Bucket=self.bucket)['LocationConstraint'] or 'us-east-1')==region,'S3 source must be in selected region')
    def inventory(self,deadline):
        keys=[]
        if self.key.endswith('/') or not self.key:
            args={'Bucket':self.bucket,'Prefix':self.key,'MaxKeys':1000}; tokens=set()
            for _ in range(100):
                page=self.api.list_objects_v2(**args)
                keys.extend(i['Key'] for i in page.get('Contents',[]) if not i['Key'].endswith('/'))
                require(len(keys)<=100000 and time.monotonic()<deadline,'S3 inventory bound exceeded')
                if not page.get('IsTruncated'): break
                token=page['NextContinuationToken']; require(token not in tokens,'repeated S3 token')
                tokens.add(token); args['ContinuationToken']=token
            else: raise ValueError('S3 source pagination exhausted')
        else: keys=[self.key]
        records=[]
        for key in sorted(keys):
            head=self.api.head_object(Bucket=self.bucket,Key=key)
            record={'path':relative(key[len(self.key):] if not self.key or self.key.endswith('/') else key.rsplit('/',1)[-1]),
                'bytes':head['ContentLength'],'source_key':key,'source_etag':head['ETag'],'source_version':head.get('VersionId')}
            inventory_bound(self,record['bytes'],sum(r['bytes'] for r in records))
            with self.open(record) as stream: record['sha256']=stream_hash(stream,record['bytes'],deadline,getattr(self,'cancelled',None))
            records.append(record)
        require(records,'empty S3 input'); return records
    @contextmanager
    def open(self,record):
        args={'Bucket':self.bucket,'Key':record['source_key'],'IfMatch':record['source_etag']}
        if record['source_version'] not in (None,'null'): args['VersionId']=record['source_version']
        response=self.api.get_object(**args)
        try:
            require(response['ContentLength']==record['bytes'] and response['ETag']==record['source_etag'] and
                    response.get('VersionId')==record['source_version'],'S3 source version changed')
            yield response['Body']
        finally: response['Body'].close()

def public_url(url):
    parsed=urlsplit(url)
    require(parsed.scheme=='https' and parsed.hostname and not parsed.username and not parsed.password and
            parsed.port in (None,443) and not parsed.query and not parsed.fragment,'public credential-free HTTPS required')
    addresses=socket.getaddrinfo(parsed.hostname,443,type=socket.SOCK_STREAM)
    require(addresses and all(ipaddress.ip_address(i[4][0]).is_global for i in addresses),'HTTPS resolved to non-public address')
    return url

class PublicRedirect(HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        public_url(newurl)
        return super().redirect_request(req,fp,code,msg,headers,newurl)

class PublicConnection(http.client.HTTPSConnection):
    def connect(self):
        super().connect()
        try:
            require(ipaddress.ip_address(self.sock.getpeername()[0]).is_global, 'HTTPS peer is non-public')
        except BaseException:
            self.close(); raise

class PublicHandler(HTTPSHandler):
    def https_open(self, request):
        return self.do_open(PublicConnection, request, context=self._context)

class HTTPS:
    def __init__(self,source): self.url=public_url(source); self.opener=build_opener(ProxyHandler({}),PublicRedirect(),PublicHandler())
    def inventory(self,deadline):
        with self.opener.open(Request(self.url,method='HEAD',headers={'Accept-Encoding':'identity'}),timeout=15) as head:
            size=head.headers.get('Content-Length'); etag=head.headers.get('ETag')
            require(size and size.isdigit() and etag and not etag.startswith('W/'),'HTTPS requires size and strong ETag')
            record={'path':relative(unquote(urlsplit(self.url).path.rsplit('/',1)[-1]) or 'dataset'),
                    'bytes':int(size),'source_etag':etag}
        inventory_bound(self,record['bytes'])
        with self.open(record) as stream: record['sha256']=stream_hash(stream,record['bytes'],deadline,getattr(self,'cancelled',None))
        return [record]
    @contextmanager
    def open(self,record):
        response=self.opener.open(Request(self.url,headers={'If-Match':record['source_etag'],'Accept-Encoding':'identity'}),timeout=15)
        try:
            require(response.headers.get('ETag')==record['source_etag'] and response.headers.get('Content-Length')==str(record['bytes'])
                    and response.headers.get('Content-Encoding') in (None,'identity'),'HTTPS source changed/encoded')
            yield response
        finally: response.close()

def source_adapter(dataset,s3,region):
    adapter={'local':lambda:Local(dataset['source']),'s3':lambda:S3(dataset['source'],s3,region),'https':lambda:HTTPS(dataset['source'])}[dataset['adapter']]()
    adapter.maximum_bytes=dataset.get('maximum_bytes',640*1024**3)
    return adapter

def verify_object(s3,account,bucket,record,deadline):
    response=s3.get_object(Bucket=bucket,Key=record['key'],VersionId=record['version_id'],ExpectedBucketOwner=account)
    try:
        require(response.get('VersionId')==record['version_id'] and response['ContentLength']==record['bytes'],'dataset version/size differs')
        require(stream_hash(response['Body'],record['bytes'],deadline)==record['sha256'],'dataset checksum differs')
    finally: response['Body'].close()

def incomplete(L,s3,directory,account):
    """Reconcile only unique operation keys, including a lost create response."""
    for intent_path in sorted(Path(directory).glob('*/intent.json')):
        ledger=intent_path.parent; intent=L['read'](intent_path)
        require('/objects/'+intent['operation_id']+'/' in intent['key'],'incomplete-upload ownership mismatch')
        if (ledger/'completed.json').exists() or (ledger/'aborted.json').exists(): continue
        args={'Bucket':intent['bucket'],'Prefix':intent['key'],'ExpectedBucketOwner':account,'MaxUploads':1000}
        page=s3.list_multipart_uploads(**args)
        require(not page.get('IsTruncated'),'operation upload inventory exceeds bound')
        identifiers=[]
        for upload in page.get('Uploads',[]):
            if upload['Key']!=intent['key']: continue
            s3.abort_multipart_upload(Bucket=intent['bucket'],Key=intent['key'],UploadId=upload['UploadId'],ExpectedBucketOwner=account)
            identifiers.append(upload['UploadId'])
        L['write'](ledger/'aborted.json',{'upload_ids':identifiers,'aborted':True})

def upload(L,s3,account,bucket,prefix,record,adapter,directory,deadline):
    size=max(CHUNK,math.ceil(record['bytes']/10000/CHUNK)*CHUNK)
    require(size<=MAX_PART,'single-object ingestion supports at most 640 GiB')
    identifier=uuid.uuid4().hex; key=prefix+'objects/'+identifier+'/'+record['path']
    ledger=directory/identifier; ledger.mkdir(mode=0o700)
    owner={'Bucket':bucket,'Key':key,'ExpectedBucketOwner':account}
    L['write'](ledger/'intent.json',{'bucket':bucket,'key':key,'operation_id':identifier,'bytes':record['bytes'],'sha256':record['sha256']})
    upload_id=None
    try:
        with adapter.open(record) as stream:
            digest=hashlib.sha256(); count=0
            if record['bytes']<=CHUNK:
                data=stream.read(CHUNK+1); digest.update(data)
                require(len(data)==record['bytes'] and not stream.read(1) and digest.hexdigest()==record['sha256'],'source changed before upload')
                result=s3.put_object(**owner,Body=data,ChecksumSHA256=base64.b64encode(digest.digest()).decode(),IfNoneMatch='*')
            else:
                response=s3.create_multipart_upload(**owner,ChecksumAlgorithm='SHA256',Metadata={'operation-id':identifier})
                upload_id=response['UploadId']; L['write'](ledger/'multipart.json',{'upload_id':upload_id,**owner}); parts=[]
                while True:
                    require(time.monotonic()<deadline and not (getattr(adapter,'cancelled',None) and adapter.cancelled()),'transfer cancelled/time bound exhausted')
                    data=stream.read(size)
                    if not data: break
                    count+=len(data); digest.update(data)
                    require(count<=record['bytes'] and len(parts)<10000,'multipart exceeded reviewed bytes/parts')
                    checksum=base64.b64encode(hashlib.sha256(data).digest()).decode(); number=len(parts)+1
                    response=s3.upload_part(**owner,UploadId=upload_id,PartNumber=number,Body=data,ChecksumSHA256=checksum)
                    require(response.get('ChecksumSHA256')==checksum,'part checksum mismatch')
                    part={'PartNumber':number,'ETag':response['ETag'],'ChecksumSHA256':checksum}; parts.append(part)
                    L['write'](ledger/(str(number)+'.json'),part)
                require(count==record['bytes'] and digest.hexdigest()==record['sha256'],'source changed during multipart')
                result=s3.complete_multipart_upload(**owner,UploadId=upload_id,MultipartUpload={'Parts':parts},IfNoneMatch='*'); upload_id=None
        version=result.get('VersionId'); require(version not in (None,'','null'),'versioned destination required')
        completed={'path':record['path'],'bytes':record['bytes'],'sha256':record['sha256'],'key':key,'version_id':version}
        L['write'](ledger/'completed.json',completed); verify_object(s3,account,bucket,completed,deadline)
        return completed
    finally:
        if upload_id:
            s3.abort_multipart_upload(**owner,UploadId=upload_id)
            L['write'](ledger/'aborted.json',{'upload_ids':[upload_id],'aborted':True})

def ingest(L,deployment,s3,directory,adapter=None,previous=None,inventory=None,seconds=3600):
    directory=L['checked_path'](directory); directory.mkdir(parents=True,mode=0o700,exist_ok=False)
    deadline=time.monotonic()+seconds; cfg=deployment['configuration']; account=deployment['account_id']
    bucket=deployment['names']['workload_bucket']; project=cfg['project']
    adapter=adapter or source_adapter(deployment['dataset'],s3,cfg['region']); records=inventory or adapter.inventory(deadline)
    total=sum(r['bytes'] for r in records); require(total<=cfg['dataset'].get('maximum_bytes',total),'selected transfer ceiling exceeded')
    require(len({relative(r['path']) for r in records})==len(records),'duplicate dataset names')
    content=[{k:r[k] for k in ('path','bytes','sha256')} for r in records]
    digest=hashlib.sha256(canonical(content)).hexdigest(); prefix=f'projects/{project}/data/snapshots/{digest}/'
    L['write'](directory/'source.json',{'records':records,'total_bytes':total,'content_sha256':digest})
    try:
        if previous:
            require(previous['content_sha256']==digest and previous['bucket']==bucket and
                    [{k:r[k] for k in ('path','bytes','sha256')} for r in previous['objects']]==content,'retained dataset differs')
            objects=previous['objects']
            for item in objects:
                suffix=item['key'].removeprefix(prefix+'objects/'); owner,sep,path=suffix.partition('/')
                require(sep and len(owner)==32 and all(c in '0123456789abcdef' for c in owner) and path==item['path'],'retained namespace differs')
                verify_object(s3,account,bucket,item,deadline)
        else: objects=[upload(L,s3,account,bucket,prefix,r,adapter,directory,deadline) for r in records]
        require(adapter.inventory(deadline)==records,'source changed; mixed snapshot cannot be sealed')
        manifest={'schema_version':'1.0.0','kind':'dataset-manifest','bucket':bucket,'content_sha256':digest,'total_bytes':total,'objects':objects}
        if previous:
            require(manifest=={k:v for k,v in previous.items() if k not in ('manifest_key','manifest_version_id','manifest_sha256')},'retained manifest differs')
            result=previous
        else:
            raw=canonical(manifest); key=prefix+'manifests/'+directory.name+'.json'
            response=s3.put_object(Bucket=bucket,Key=key,Body=raw,ContentType='application/json',ExpectedBucketOwner=account,IfNoneMatch='*')
            version=response.get('VersionId'); require(version not in (None,'','null'),'versioned manifest required')
            result={**manifest,'manifest_key':key,'manifest_version_id':version,'manifest_sha256':hashlib.sha256(raw).hexdigest()}
        verify_object(s3,account,bucket,{'key':result['manifest_key'],'version_id':result['manifest_version_id'],
            'bytes':len(canonical(manifest)),'sha256':result['manifest_sha256']},deadline)
        L['write'](directory/'manifest.json',result); return result
    finally: incomplete(L,s3,directory,account)
