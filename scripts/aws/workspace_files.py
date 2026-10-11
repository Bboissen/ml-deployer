"""Shared no-symlink local stream handling for inputs and outputs."""
from contextlib import contextmanager
import os
from pathlib import Path
import stat

# Keep execution receipts large enough for ordinary directory outputs and small
# enough for the controller's bounded, pretty-printed local evidence reader.
EXECUTION_RECEIPT_BYTES = 8 * 1024 * 1024

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

def local_stamp(stream):
    value=os.fstat(stream.fileno())
    return [value.st_dev,value.st_ino,value.st_size,value.st_mtime_ns,value.st_ctime_ns]

