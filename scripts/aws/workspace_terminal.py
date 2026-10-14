"""Shared terminal detection; recognize RTK's relay through stdin like Zelab."""
import os
import sys


def terminal_output(stream=None):
    stream = sys.stdout if stream is None else stream
    return stream.isatty() or (stream in (sys.stdout, sys.stderr, sys.__stdout__, sys.__stderr__)
                              and sys.stdin.isatty())


def interactive():
    return sys.stdin.isatty() and terminal_output()


def ssh_session():
    return any(os.environ.get(key) for key in ('SSH_CONNECTION', 'SSH_CLIENT', 'SSH_TTY'))
