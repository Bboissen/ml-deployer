"""Serve the first-use guide on 127.0.0.1 with live doctor readiness.

Read-only: GET of the guide, its linked documents and the doctor report. It
never logs in, deploys or changes cloud resources. Stops on Ctrl+C.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT/'docs'
PAGE = DOCS/'aws-setup-guide.html'
EXTRA = {'/CONTRIBUTING.md': ROOT/'CONTRIBUTING.md'}
TYPES = {'.html': 'text/html; charset=utf-8', '.md': 'text/plain; charset=utf-8'}
LOCAL_HOSTS = {'127.0.0.1', 'localhost', '::1'}
CACHE_SECONDS = 5


class Doctor:
    """Run `workspace doctor --json` at most once per CACHE_SECONDS, one at a time."""
    def __init__(self, config):
        self.config, self.lock, self.cached, self.at = config, threading.Lock(), None, 0.0

    def run(self):
        result = subprocess.run(['bash', str(ROOT/'workspace'), 'doctor', '--json', str(self.config)],
                                capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
        if result.returncode not in (0, 1): raise ValueError('doctor did not complete')
        report = json.loads(result.stdout)
        if not isinstance(report, dict) or not isinstance(report.get('rows'), list):
            raise ValueError('invalid doctor report')
        return report

    def report(self):
        with self.lock:
            if self.cached is None or time.monotonic() - self.at > CACHE_SECONDS:
                try:
                    self.cached = self.run()
                except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
                    self.cached = {'error': 'readiness check failed (' + type(exc).__name__ + '); run ./workspace doctor --debug'}
                self.at = time.monotonic()
            return self.cached


def next_step(report):
    for row in report.get('rows', []):
        if row['state'] != 'Ready':
            return row['check'] + ': ' + row['detail'] + ('\n    ' + row['next'] if row.get('next') else '')
    return None


def resolve(path):
    """Map a URL path to a guide page or document; nothing outside docs/ except EXTRA."""
    path = path.split('?', 1)[0]
    if path == '/': return PAGE
    if path in EXTRA: return EXTRA[path]
    candidate = (DOCS/path.lstrip('/')).resolve()
    if candidate.suffix in TYPES and candidate.is_relative_to(DOCS) and candidate.is_file(): return candidate
    return None


def handler(doctor):
    class Guide(BaseHTTPRequestHandler):
        def send(self, code, body, kind):
            self.send_response(code)
            for name, value in (('Content-Type', kind), ('Content-Length', str(len(body))), ('Cache-Control', 'no-store'),
                                ('X-Content-Type-Options', 'nosniff'), ('Referrer-Policy', 'no-referrer'),
                                ('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; "
                                 "style-src 'unsafe-inline'; frame-ancestors 'none'")):
                self.send_header(name, value)
            self.end_headers(); self.wfile.write(body)

        def do_GET(self):
            # Host check blocks DNS rebinding; the port may differ behind an SSH or editor forward.
            try:
                host = urlsplit('//' + self.headers.get('Host', '')).hostname
            except ValueError:
                host = None
            if host not in LOCAL_HOSTS: return self.send(403, b'forbidden host\n', TYPES['.md'])
            if self.path.split('?', 1)[0] == '/status.json':
                return self.send(200, json.dumps(doctor.report()).encode(), 'application/json')
            target = resolve(self.path)
            if target is None: return self.send(404, b'not found\n', TYPES['.md'])
            self.send(200, target.read_bytes(), TYPES[target.suffix])

        def log_message(self, *args):
            pass
    return Guide


def bind(port, tries, doctor):
    for candidate in range(port, port + tries):
        try:
            return ThreadingHTTPServer(('127.0.0.1', candidate), handler(doctor))
        except OSError:
            continue
    raise SystemExit('workspace guide: ports %d-%d are busy; set WORKSPACE_GUIDE_PORT' % (port, port + tries - 1))


def open_browser(url):
    """Open only a graphical browser; never a terminal one."""
    if platform.system() == 'Darwin': opener = 'open'
    elif (os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY')) and shutil.which('xdg-open'): opener = 'xdg-open'
    else: return False
    try:
        return subprocess.run([opener, url], capture_output=True, timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('config', type=Path)
    parser.add_argument('--port', type=int, default=os.environ.get('WORKSPACE_GUIDE_PORT', '8765'))
    args = parser.parse_args()
    if not 1 <= args.port <= 65535: parser.error('port must be between 1 and 65535')
    doctor = Doctor(args.config.expanduser().absolute())
    server = bind(args.port, 1 if 'WORKSPACE_GUIDE_PORT' in os.environ or '--port' in sys.argv else min(10, 65536 - args.port), doctor)
    port = server.server_address[1]; url = 'http://127.0.0.1:%d/' % port
    serving = threading.Thread(target=server.serve_forever, daemon=True)
    serving.start()
    try:
        print('First-use guide: ' + url, flush=True)
        if open_browser(url):
            print('  Opened in your browser.')
        else:
            print('  Open that address in your browser. On another computer, forward the port first:\n'
                  '    ssh -L %d:127.0.0.1:%d %s   (then open the same address there)' % (port, port, platform.node() or 'this-host'), flush=True)
        report = doctor.report(); step = next_step(report)
        if step: print('Next: ' + step)
        elif report.get('ready'): print('All checks are ready: the page shows the Deploy command.')
        else: print(report.get('error', 'Readiness is not confirmed; see the guide page.'))
        print('The page updates itself as you complete each step. Press Ctrl+C here to stop the guide.', flush=True)
        serving.join()
    except KeyboardInterrupt:
        print('\nworkspace guide: stopped')
    finally:
        server.shutdown()
        serving.join()
        server.server_close()


if __name__ == '__main__':
    main()
