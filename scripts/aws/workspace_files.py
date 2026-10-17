"""Shared no-symlink local stream handling for inputs and outputs."""
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import stat
import time

# Keep execution receipts large enough for ordinary directory outputs and small
# enough for the controller's bounded, pretty-printed local evidence reader.
EXECUTION_RECEIPT_BYTES = 8 * 1024 * 1024
CHUNK = 8 * 1024 * 1024

def require(condition, reason):
    if not condition: raise ValueError(reason)

@contextmanager
def local_file(path):
    path=Path(path).absolute(); parent=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
    try:
        for part in path.parts[1:-1]:
            child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)
            os.close(parent); parent=child
        # A replaced FIFO must fail the regular-file check instead of blocking
        # before fstat can inspect the descriptor.
        descriptor=os.open(path.name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
        with os.fdopen(descriptor,'rb') as stream:
            require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode),'dataset special file unsupported')
            yield stream
    finally: os.close(parent)

def stat_stamp(value):
    return [value.st_dev,value.st_ino,value.st_size,value.st_mtime_ns,value.st_ctime_ns]


def local_stamp(stream):
    return stat_stamp(os.fstat(stream.fileno()))


def stream_hash(stream,size,deadline,cancelled=None,sink=None):
    """Hash exactly size bytes before deadline, optionally copying each chunk."""
    digest=hashlib.sha256(); count=0
    while True:
        require(time.monotonic()<deadline and not (cancelled and cancelled()),'dataset transfer cancelled/time bound exhausted')
        chunk=stream.read(CHUNK)
        if not chunk: break
        count+=len(chunk); require(count<=size,'source grew beyond reviewed bytes'); digest.update(chunk)
        if sink: sink.write(chunk)
    require(count==size,'source size changed or incomplete read')
    return digest.hexdigest()
