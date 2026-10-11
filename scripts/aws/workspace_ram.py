"""Disposable RAM storage for private keys on supported operator hosts."""
from contextlib import contextmanager
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import uuid


@contextmanager
def key_directory():
    device = None
    if platform.system() == 'Linux':
        filesystem = subprocess.check_output(['findmnt', '-no', 'FSTYPE', '--target', '/dev/shm'], timeout=5).strip()
        if filesystem != b'tmpfs':
            raise ValueError('private keys require /dev/shm mounted as tmpfs')
        parent = Path('/dev/shm')
    elif platform.system() == 'Darwin':
        # 16 MiB native RAM disk. Never fall back to a persistent key file.
        raw = subprocess.check_output(['hdiutil', 'attach', '-nomount', 'ram://32768'], timeout=15).decode().strip()
        if not re.fullmatch(r'/dev/disk[0-9]+', raw):
            raise ValueError('unexpected RAM disk identity')
        device = raw
        name = 'workspace-key-'+uuid.uuid4().hex
        try:
            subprocess.run(['diskutil', 'eraseVolume', 'HFS+', name, device], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        except BaseException:
            subprocess.run(['hdiutil', 'detach', device], check=True, capture_output=True, timeout=15)
            raise
        parent = Path('/Volumes')/name
    else:
        raise ValueError('private key handling supports Linux and macOS')
    try:
        with tempfile.TemporaryDirectory(prefix='workspace-key-', dir=parent) as directory:
            os.chmod(directory, 0o700)
            yield Path(directory)
    finally:
        if device:
            subprocess.run(['hdiutil', 'detach', device], check=True, capture_output=True, timeout=15)
