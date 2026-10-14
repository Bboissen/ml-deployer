"""Verify an extracted release without relying on a .git directory."""
import hashlib
import json
from pathlib import Path
import re


def provenance(root):
    root=Path(root); metadata=root/'RELEASE.json'
    if not metadata.exists(): return None
    if metadata.is_symlink(): raise ValueError('release metadata cannot be a symlink')
    release=json.loads(metadata.read_text())
    if release['kind']!='aws-workspace-release' or release['schema_version']!='1.0.0' or not re.fullmatch(r'[0-9a-f]{40}',release['revision']):
        raise ValueError('invalid release provenance')
    changes=b''
    for name,record in sorted(release['files'].items()):
        path=root/name
        if Path(name).is_absolute() or any(p in ('..','.git','.tools') for p in Path(name).parts):
            raise ValueError('release manifest path rejected')
        if not path.is_file() or any(p.is_symlink() for p in (path,*path.parents)):
            raise ValueError('release source missing or symlinked')
        actual=hashlib.sha256(path.read_bytes()).hexdigest(); mode=0o755 if path.stat().st_mode & 0o111 else 0o644
        if actual!=record['sha256'] or mode!=record['mode']: changes+=name.encode()+b'\0'+actual.encode()+str(mode).encode()
    def walk(directory):
        nonlocal changes
        for path in directory.iterdir():
            name=path.relative_to(root).as_posix()
            if name in ('evidence','.tools','.release-sha256','RELEASE.json'): continue
            if path.is_symlink(): raise ValueError('release source symlink rejected')
            if path.is_dir(): walk(path)
            elif name not in release['files']: changes+=name.encode()+b'\0'+path.read_bytes()
    walk(root)
    return {'source':{'revision':release['revision'],'working_tree_sha256':hashlib.sha256(changes).hexdigest()},
            'accepted_ancestors':release['accepted_ancestors'],'version':release['version']}
