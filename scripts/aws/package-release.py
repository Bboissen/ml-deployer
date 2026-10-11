"""Package only committed source; never archive state, credentials or local tools."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile


def require(condition,reason):
    if not condition: raise ValueError(reason)


def git(root, *arguments):
    return subprocess.check_output(['git', *arguments], cwd=root, timeout=30)


def package(root, output):
    root=Path(root).resolve(); output=Path(output).absolute()
    require(not output.exists() and not any(p.is_symlink() for p in output.parents), 'new non-symlink output directory required')
    require(shutil.disk_usage(output.parent).free>=2*1024**3, 'release build requires 2 GiB free')
    require(not git(root,'status','--porcelain'), 'release requires clean committed source')
    revision=git(root,'rev-parse','HEAD').decode().strip()
    release=json.loads(git(root,'show',revision+':shared/workspace/release.json')); version=release['version']
    require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-rc\.[0-9]+)?',version), 'invalid release version')
    files={}; content={}; modes={}
    # Git object archive pins every byte/mode to the captured commit, even if
    # another process edits the checkout while this package is being built.
    with tarfile.open(fileobj=io.BytesIO(git(root,'archive','--format=tar',revision))) as snapshot:
        for entry in snapshot:
            if entry.isdir(): continue
            name=entry.name
            require(entry.isfile(), 'release must contain regular committed files')
            require(not any(part in ('.git','.tools','evidence','__pycache__','.terraform') for part in Path(name).parts) or name in ('evidence/.gitignore','evidence/README.md'), 'operational material cannot enter a release')
            data=snapshot.extractfile(entry).read(); content[name]=data; modes[name]=0o755 if entry.mode & 0o111 else 0o644
            files[name]={'sha256':hashlib.sha256(data).hexdigest(),'mode':modes[name]}
    metadata={'kind':'aws-workspace-release','schema_version':'1.0.0','version':version,'revision':revision,
              'accepted_ancestors':git(root,'rev-list','--max-count=10000',revision).decode().splitlines(),
              'files':files,'native_acceptance':release['native_acceptance']}
    content['RELEASE.json']=(json.dumps(metadata,sort_keys=True,indent=2)+'\n').encode(); modes['RELEASE.json']=0o644
    output.mkdir(mode=0o700); archive=output/('aws-workspace-'+version+'.tar.gz'); top='aws-workspace-'+version
    try:
        with archive.open('xb') as raw, gzip.GzipFile(fileobj=raw,mode='wb',mtime=0,filename='') as compressed, tarfile.open(fileobj=compressed,mode='w') as tar:
            for name,data in sorted(content.items()):
                info=tarfile.TarInfo(top+'/'+name); info.size=len(data); info.mode=modes[name]; info.mtime=0
                tar.addfile(info,io.BytesIO(data))
        checksum=hashlib.sha256(archive.read_bytes()).hexdigest()
        archive.with_name(archive.name+'.sha256').write_text(checksum+'  '+archive.name+'\n')
        installer, count = re.subn(r'^version=.*$', 'version='+version,
            content['scripts/aws/install-release.sh'].decode(), count=1, flags=re.M)
        require(count == 1, 'release installer version placeholder missing')
        (output/'install.sh').write_text(installer)
        return {'version':version,'revision':revision,'archive':str(archive),'sha256':checksum,'native_acceptance':release['native_acceptance']}
    except BaseException:
        shutil.rmtree(output); raise


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('output'); args=parser.parse_args()
    print(json.dumps(package(Path(__file__).resolve().parents[2],args.output),indent=2))
