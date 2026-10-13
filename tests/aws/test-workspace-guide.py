"""Offline checks for the local first-use guide server; no login, no cloud calls."""
import http.client
import importlib.util
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('workspace_guide', ROOT/'scripts/aws/workspace-guide.py')
G = importlib.util.module_from_spec(spec); spec.loader.exec_module(G)
REPORT = {'ready': False, 'checked_at': '2026-10-13T00:00:00Z', 'config': None, 'deploy': None, 'rows': [
    {'check': 'Managed tools', 'state': 'Ready', 'detail': 'ok', 'next': None},
    {'check': 'Project config', 'state': 'To do', 'detail': 'no project file yet', 'next': 'cp example project.json'},
    {'check': 'AWS identity', 'state': 'Not checked', 'detail': 'later', 'next': 'ignored'}]}


class GuideServer(unittest.TestCase):
    def setUp(self):
        self.calls = 0
        def run():
            self.calls += 1; return dict(REPORT)
        self.doctor = G.Doctor(Path('/nonexistent/project.json')); self.doctor.run = run
        self.server = G.bind(0, 1, self.doctor)
        self.addCleanup(self.server.server_close)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True); thread.start()
        self.addCleanup(self.server.shutdown)
        self.port = self.server.server_address[1]

    def get(self, path, host=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=10)
        connection.request('GET', path, headers={'Host': host or '127.0.0.1:%d' % self.port})
        response = connection.getresponse(); body = response.read(); connection.close()
        return response, body

    def test_serves_the_page_bound_to_loopback_with_safe_headers(self):
        self.assertEqual(self.server.server_address[0], '127.0.0.1')
        response, body = self.get('/')
        self.assertEqual(response.status, 200); self.assertIn(b'first-use guide', body)
        self.assertEqual(response.getheader('Cache-Control'), 'no-store')
        self.assertIn("frame-ancestors 'none'", response.getheader('Content-Security-Policy'))
        self.assertIsNone(response.getheader('Access-Control-Allow-Origin'))

    def test_status_is_the_cached_doctor_report(self):
        for _ in range(3):
            response, body = self.get('/status.json?t=1')
            self.assertEqual(response.status, 200); self.assertEqual(json.loads(body)['rows'][1]['state'], 'To do')
        self.assertEqual(self.calls, 1)

    def test_doctor_failure_is_reported_not_raised(self):
        self.doctor.run = lambda: (_ for _ in ()).throw(ValueError('bad json'))
        self.assertIn('ValueError', self.doctor.report()['error'])

    def test_expired_cache_picks_up_the_next_step(self):
        self.get('/status.json')
        self.doctor.run = lambda: {'ready': False, 'rows': [
            {'check': 'Project config', 'state': 'Ready', 'detail': 'created', 'next': None},
            {'check': 'AWS identity', 'state': 'To do', 'detail': 'sign in', 'next': './workspace login'}]}
        self.doctor.at -= G.CACHE_SECONDS + 1
        _, body = self.get('/status.json')
        self.assertIn('AWS identity: sign in', G.next_step(json.loads(body)))

    def test_only_documents_under_docs_are_served(self):
        self.assertEqual(self.get('/operations/aws-project-configuration.md')[0].status, 200)
        self.assertEqual(self.get('/CONTRIBUTING.md')[0].status, 200)
        for path in ('/../workspace', '/operations/../../README.md', '/%2e%2e/workspace', '/opentofu-architecture.css', '/missing.md'):
            self.assertEqual(self.get(path)[0].status, 404, path)

    def test_foreign_host_names_are_refused_but_forwarded_ports_work(self):
        self.assertEqual(self.get('/status.json', 'attacker.example:%d' % self.port)[0].status, 403)
        self.assertEqual(self.get('/', 'localhost:9000')[0].status, 200)
        self.assertEqual(self.get('/', '[::1]:9000')[0].status, 200)
        self.assertEqual(self.calls, 0)

    def test_post_cannot_trigger_a_readiness_check(self):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=10)
        self.addCleanup(connection.close)
        connection.request('POST', '/status.json')
        response = connection.getresponse(); response.read()
        self.assertEqual(response.status, 501); self.assertEqual(self.calls, 0)


class GuideTerminal(unittest.TestCase):
    def test_next_step_is_the_first_to_do_row(self):
        self.assertEqual(G.next_step(REPORT), 'Project config: no project file yet\n    cp example project.json')
        self.assertIsNone(G.next_step({'rows': [REPORT['rows'][0]]}))

    def test_inconclusive_check_is_never_reported_as_ready(self):
        report = {'ready': False, 'rows': [REPORT['rows'][0], REPORT['rows'][2]]}
        self.assertEqual(G.next_step(report), 'AWS identity: later\n    ignored')

    def test_terminal_distinguishes_done_next_wait_and_required_editing(self):
        report = {**REPORT, 'expected_config': '/custom/project.json'}
        text = G.readiness_text(report)
        self.assertIn('[DONE] Managed tools', text)
        self.assertIn('[NEXT] Project config', text)
        self.assertIn('[WAIT] AWS identity', text)
        self.assertIn('second terminal on this server', text)
        self.assertIn('replace the example profile', text)

    def test_ssh_never_opens_a_browser_on_the_server(self):
        with patch.dict(os.environ, {'SSH_CONNECTION': 'client server', 'DISPLAY': ':0'}), \
             patch.object(G.subprocess, 'run', side_effect=AssertionError('remote browser opened')):
            self.assertFalse(G.open_browser('http://127.0.0.1:8765/'))

    def test_doctor_always_checks_the_selected_path_even_before_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory)/'custom project.json'
            result = subprocess.CompletedProcess([], 1, json.dumps(REPORT), '')
            with patch.object(G.subprocess, 'run', return_value=result) as run:
                self.assertFalse(G.Doctor(config).run()['ready'])
            self.assertEqual(run.call_args.args[0][-1], str(config))
            with patch.object(G.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'null', '')):
                self.assertIn('ValueError', G.Doctor(config).report()['error'])

    def test_server_is_ready_when_the_browser_opens_and_closes_on_interrupt(self):
        doctor = G.Doctor(Path('/nonexistent/project.json')); doctor.run = lambda: dict(REPORT)
        server = G.bind(0, 1, doctor)
        self.addCleanup(server.server_close)
        def open_browser(url):
            connection = http.client.HTTPConnection('127.0.0.1', server.server_address[1], timeout=10)
            try:
                connection.request('GET', '/status.json')
                response = connection.getresponse(); body = response.read()
                self.assertEqual(response.status, 200)
                self.assertEqual(json.loads(body)['rows'][1]['state'], 'To do')
            finally:
                connection.close()
            raise KeyboardInterrupt()
        with patch.object(sys, 'argv', ['workspace-guide.py', '/nonexistent/project.json']), \
             patch.object(G, 'bind', return_value=server), patch.object(G, 'Doctor', return_value=doctor), \
             patch.object(G, 'open_browser', side_effect=open_browser):
            G.main()
        self.assertEqual(server.fileno(), -1)

    def test_browser_opens_only_with_a_display(self):
        with tempfile.TemporaryDirectory() as directory:
            opened = Path(directory)/'opened'; opener = Path(directory)/'xdg-open'
            opener.write_text('#!/bin/sh\necho "$1" > "%s"\n' % opened); opener.chmod(0o755)
            with patch.object(G.platform, 'system', return_value='Linux'), \
                 patch.dict(os.environ, {'PATH': directory}, clear=True):
                self.assertFalse(G.open_browser('http://127.0.0.1:1/')); self.assertFalse(opened.exists())
                os.environ['DISPLAY'] = ':0'
                self.assertTrue(G.open_browser('http://127.0.0.1:1/'))
            self.assertEqual(opened.read_text().strip(), 'http://127.0.0.1:1/')


if __name__ == '__main__':
    unittest.main(verbosity=2)
