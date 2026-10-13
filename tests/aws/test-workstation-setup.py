"""Offline bootstrap faults and authentication boundaries; no network or login."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
spec = importlib.util.spec_from_file_location('workstation_auth', ROOT/'scripts/aws/workstation-auth.py')
A = importlib.util.module_from_spec(spec); spec.loader.exec_module(A)
BASE = ROOT/'evidence/aws/tests/workstation'
BASE.mkdir(parents=True, exist_ok=True)


def executable(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o755)


class Bootstrap(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=BASE)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root/'repo'
        (self.repo/'scripts/aws').mkdir(parents=True)
        for name in ('workstation-setup.sh', 'workspace.sh'):
            shutil.copy(ROOT/'scripts/aws'/name, self.repo/'scripts/aws'/name)
        shutil.copy(ROOT/'workspace', self.repo/'workspace')
        self.shims = self.root/'shims'; self.shims.mkdir()
        self.cache = self.root/'archives'; self.cache.mkdir()
        self.prefix = self.root/'tools'
        self.ledger = self.root/'calls'
        self.env = {**os.environ, 'PATH': str(self.shims) + ':' + os.environ['PATH'],
                    'WORKSPACE_TOOLS_DIR': str(self.prefix)}
        self.env.pop('WORKSPACE_PYTHON', None)
        self.host_home = self.root/'home'
        (self.host_home/'.aws').mkdir(parents=True)
        self.protected = [self.host_home/'.aws/config', self.host_home/'.aws/credentials', self.host_home/'.zshrc']
        for path in self.protected: path.write_text('preserve existing user settings\n')
        self.env['HOME'] = str(self.host_home)
        executable(self.shims/'uname', '#!/bin/sh\ncase "$1" in -s) echo "${MOCK_OS:-Linux}";; -m) echo "${MOCK_ARCH:-x86_64}";; *) exec ' + shlex.quote(shutil.which('uname')) + ' "$@";; esac\n')
        executable(self.shims/'getconf', '#!/bin/sh\necho "${MOCK_LIBC:-glibc 2.35}"\n')
        executable(self.shims/'sw_vers', '#!/bin/sh\necho "${MOCK_MAC:-13.0}"\n')
        executable(self.shims/'xcode-select', '#!/bin/sh\nexit 0\n')
        self.fixture_programs()
        self.fixtures()

    def fixture_programs(self):
        # Mock publisher installers and executables; real Bash, hash, tar and zip
        # operations exercise verification, activation and preservation behavior.
        py = '#!/bin/sh\nif [ "$1" = --version ]; then echo "Python 3.13.16"; exit; fi\ncase "$*" in *controller-requirements.lock) cat >/dev/null; exit 0;; esac\nexec ' + shlex.quote(sys.executable) + ' "$@"\n'
        executable(self.root/'fixture-python', py)
        uv = '#!' + sys.executable + '\nimport pathlib,sys,os\na=sys.argv[1:]\nif a==["--version"]: print("uv 0.12.23 (mock)")\nelif "venv" in a:\n p=pathlib.Path(a[-1]); (p/"bin").mkdir(parents=True); (p/"bin/python").symlink_to(' + repr(str(self.root/'fixture-python')) + ')\n'
        executable(self.root/'fixture-uv', uv)
        curl = '#!' + sys.executable + '\nimport pathlib,shutil,sys\na=sys.argv[1:]\nwith pathlib.Path(' + repr(str(self.ledger)) + ').open("a") as f: f.write(a[-1]+"\\n")\nshutil.copyfile(pathlib.Path(' + repr(str(self.cache)) + ')/a[-1].rsplit("/",1)[-1],a[a.index("-o")+1])\n'
        executable(self.shims/'curl', curl)
        deb = '#!/bin/sh\nmkdir -p "$3/usr/local/sessionmanagerplugin/bin"\ncp ' + shlex.quote(str(self.root/'fixture-ssm')) + ' "$3/usr/local/sessionmanagerplugin/bin/session-manager-plugin"\n'
        executable(self.root/'fixture-ssm', '#!/bin/sh\necho 1.2.835.0\n')
        executable(self.shims/'dpkg-deb', deb)
        executable(self.shims/'pkgutil', '#!/bin/sh\nexit "${MOCK_SIGNATURE_FAILURE:-0}"\n')
        installer = '#!' + sys.executable + '\nimport pathlib,sys,xml.etree.ElementTree as E\na=sys.argv[1:]; root=E.parse(a[a.index("-applyChoiceChangesXML")+1]); p=pathlib.Path(root.findall(".//string")[1].text)/"aws-cli"; p.mkdir(); dest=p/"aws"; dest.write_text("#!/bin/sh\\necho \'aws-cli/2.36.14 Python/mock\'\\n"); dest.chmod(0o755)\n'
        executable(self.shims/'installer', installer)

    def archive(self, name, files, zipped=False):
        path = self.cache/name
        if zipped:
            with zipfile.ZipFile(path, 'w') as out:
                for entry, content in files.items():
                    info = zipfile.ZipInfo(entry); info.external_attr = (0o100755 << 16)
                    out.writestr(info, content)
        else:
            with tarfile.open(path, 'w:gz') as out:
                for entry, content in files.items():
                    value = content.encode(); info = tarfile.TarInfo(entry); info.size = len(value); info.mode = 0o755
                    out.addfile(info, io.BytesIO(value))
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def fixtures(self):
        uv = (self.root/'fixture-uv').read_text(); py = (self.root/'fixture-python').read_text()
        linux_aws = '#!/bin/sh\necho "aws-cli/2.36.14 Python/mock"\n'
        hashes = {
            'uv.tgz': self.archive('uv.tgz', {'uv/uv': uv}),
            'python.tgz': self.archive('python.tgz', {'python/bin/python3.13': py}),
            'tofu.zip': self.archive('tofu.zip', {'tofu': '#!/bin/sh\necho "OpenTofu v1.12.3"\n'}, True),
            'aws.zip': self.archive('aws.zip', {'aws/dist/aws': linux_aws, 'aws/install': '#!/bin/sh\nexit 9\n'}, True),
            'ssm.zip': self.archive('ssm.zip', {'sessionmanager-bundle/bin/session-manager-plugin': '#!/bin/sh\necho 1.2.835.0\n'}, True),
            'gh.tgz': self.archive('gh.tgz', {'gh/bin/gh': '#!/bin/sh\necho "gh version 2.102.0 (mock)"\n'}),
            'gh.zip': self.archive('gh.zip', {'gh_2.102.0_macOS_arm64/bin/gh': '#!/bin/sh\necho "gh version 2.102.0 (mock)"\n'}, True)}
        for name in ('aws.pkg', 'ssm.deb'):
            (self.cache/name).write_bytes(b'mock signed package')
            hashes[name] = hashlib.sha256((self.cache/name).read_bytes()).hexdigest()
        rows=[]
        for platform in ('linux-x86_64', 'linux-aarch64', 'darwin-x86_64', 'darwin-aarch64'):
            linux = platform.startswith('linux')
            for tool, version, name in [('uv','0.12.23','uv.tgz'),('python','3.13.16','python.tgz'),
                ('tofu','1.12.3','tofu.zip'),('aws','2.36.14','aws.zip' if linux else 'aws.pkg'),
                ('ssm','1.2.835.0','ssm.deb' if linux else 'ssm.zip'),('gh','2.102.0','gh.tgz' if linux else 'gh.zip')]:
                rows.append('\t'.join((platform,tool,version,'https://publisher.invalid/'+name,hashes[name])))
        (self.repo/'scripts/aws/workstation-tools.lock.tsv').write_text('\n'.join(rows)+'\n')
        (self.repo/'scripts/aws/controller-requirements.lock').write_text('# mocked packages\n')

    def run_setup(self, *args):
        return subprocess.run(['bash', str(self.repo/'scripts/aws/workspace.sh'), 'setup', *args],
                              env=self.env, capture_output=True, text=True, timeout=30)

    def test_check_only_has_no_writes_or_downloads(self):
        result = self.run_setup('--check')
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.prefix.exists()); self.assertFalse(self.ledger.exists())

    def test_linux_install_rerun_and_conflicting_path_version(self):
        executable(self.shims/'aws', '#!/bin/sh\necho aws-cli/1.0\n')
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        original = (self.prefix/'current').resolve(); calls = self.ledger.read_text()
        self.assertEqual(self.run_setup().returncode, 0)
        self.assertEqual(self.run_setup('--check').returncode, 0)
        self.assertEqual((self.prefix/'current').resolve(), original)
        self.assertEqual(self.ledger.read_text(), calls)
        self.assertNotIn('gh.tgz', calls)
        self.assertIn('aws-cli/1.0', (self.shims/'aws').read_text())
        for path in self.protected: self.assertEqual(path.read_text(),'preserve existing user settings\n')

    def test_all_platforms_and_optional_github(self):
        for os_name, arch in [('Linux','aarch64'), ('Darwin','x86_64'), ('Darwin','arm64')]:
            with self.subTest(os=os_name, arch=arch):
                self.env.update(MOCK_OS=os_name, MOCK_ARCH=arch, WORKSPACE_TOOLS_DIR=str(self.root/(os_name+arch)))
                result = self.run_setup('--github')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.run_setup('--check', '--github').returncode, 0)

    def test_wrong_download_hash_stops_before_execution_or_activation(self):
        (self.cache/'uv.tgz').write_bytes(b'corrupted')
        result = self.run_setup()
        self.assertEqual(result.returncode, 2)
        self.assertIn('checksum mismatch', result.stderr)
        self.assertFalse((self.prefix/'current').exists())
        self.assertEqual(len(self.ledger.read_text().splitlines()), 1)
        self.assertFalse((self.prefix/'install.lock').exists())
        self.assertEqual(list((self.prefix/'releases').iterdir()),[])

    def test_failed_upgrade_keeps_previous_runtime_selected(self):
        self.assertEqual(self.run_setup().returncode, 0)
        before = (self.prefix/'current').resolve()
        lock = self.repo/'scripts/aws/workstation-tools.lock.tsv'
        lock.write_text(lock.read_text()+'# new reviewed release\n')
        (self.cache/'uv.tgz').write_bytes(b'corrupted')
        result = self.run_setup()
        self.assertEqual(result.returncode, 2); self.assertIn('download checksum mismatch', result.stderr)
        self.assertEqual((self.prefix/'current').resolve(), before)

    def test_unsigned_macos_package_stops_before_activation(self):
        self.env.update(MOCK_OS='Darwin', MOCK_ARCH='arm64', MOCK_SIGNATURE_FAILURE='1')
        self.assertNotEqual(self.run_setup().returncode, 0)
        self.assertFalse((self.prefix/'current').exists())

    def test_unsupported_hosts_fail_before_writes(self):
        for values in [{'MOCK_ARCH':'riscv64'}, {'MOCK_OS':'Windows'}, {'MOCK_LIBC':'musl 1.2'}]:
            with self.subTest(values=values), patch.dict(self.env, values):
                self.assertEqual(self.run_setup().returncode, 2)
                self.assertFalse(self.prefix.exists())

    def test_old_but_capable_os_versions_install(self):
        # No distribution or OS-version gate: the pinned binaries are verified by running them.
        for values in [{'MOCK_LIBC':'glibc 2.17'}, {'MOCK_OS':'Darwin','MOCK_ARCH':'arm64','MOCK_MAC':'12.7'}]:
            with self.subTest(values=values), patch.dict(self.env, {**values, 'WORKSPACE_TOOLS_DIR': str(self.root/values.get('MOCK_LIBC', 'mac'))}):
                result = self.run_setup()
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_binary_that_cannot_run_is_reported_with_repair(self):
        (self.cache/'tofu.zip').unlink()
        broken = self.archive('tofu.zip', {'tofu': '#!/bin/sh\necho "cannot execute binary"; exit 127\n'}, True)
        lock = self.repo/'scripts/aws/workstation-tools.lock.tsv'
        lock.write_text(lock.read_text().replace(lock.read_text().split('tofu.zip\t')[1].split('\n')[0], broken))
        result = self.run_setup()
        self.assertEqual(result.returncode, 2)
        self.assertIn('tofu 1.12.3 does not run', result.stderr); self.assertIn('glibc', result.stderr)
        self.assertFalse((self.prefix/'current').exists())

    def test_foreign_prefix_and_symlinks_are_preserved(self):
        self.prefix.mkdir(); (self.prefix/'valuable').write_text('keep')
        self.assertEqual(self.run_setup().returncode, 2)
        self.assertEqual((self.prefix/'valuable').read_text(), 'keep')
        self.env['WORKSPACE_TOOLS_DIR'] = str(self.root/'link')
        (self.root/'link').symlink_to(self.prefix)
        self.assertEqual(self.run_setup().returncode, 2)

    def test_prefix_metacharacters_fail_but_spaces_install(self):
        for suffix in ('semi;colon', '../other', 'dollar$HOME', "quote'dir"):
            with self.subTest(suffix=suffix):
                self.assertEqual(self.run_setup('--prefix', str(self.root)+'/'+suffix).returncode, 2)
        spaced = self.root/'tools with spaces'
        result = self.run_setup('--prefix', str(spaced))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((spaced/'current/bin/aws').exists())
        self.assertEqual(self.run_setup('--prefix', str(spaced), '--check').returncode, 0)

    def test_symlinked_ancestor_resolves_to_the_owned_directory(self):
        real = self.root/'real-home'; real.mkdir(); (self.root/'home-link').symlink_to(real)
        self.env['WORKSPACE_TOOLS_DIR'] = str(self.root/'home-link/tools')
        result = self.run_setup(); self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((real/'tools/owner').is_file())
        self.assertEqual(self.run_setup('--check').returncode, 0)

    def lock(self, owner):
        (self.prefix/'install.lock').mkdir(parents=True)
        (self.prefix/'owner').write_text('aws-workstation-v1:%d\n' % os.getuid())
        if owner is not None: (self.prefix/'install.lock/owner').write_text(owner)

    def test_stale_lock_of_exited_process_is_recovered(self):
        exited = subprocess.run(['sh', '-c', 'echo $$'], capture_output=True, text=True).stdout.strip()
        self.lock(exited+'\n'+os.uname().nodename+'\n')
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr); self.assertIn('recovering install.lock', result.stderr)
        self.assertFalse((self.prefix/'install.lock').exists()); self.assertTrue((self.prefix/'current').exists())

    def test_live_setup_lock_is_never_removed(self):
        holder = self.root/'workstation-setup.sh'; executable(holder, '#!/bin/sh\nsleep 30\n')
        process = subprocess.Popen(['bash', str(holder)]); self.addCleanup(process.wait); self.addCleanup(process.kill)
        self.lock(str(process.pid)+'\n'+os.uname().nodename+'\n')
        result = self.run_setup(); self.assertEqual(result.returncode, 2)
        self.assertIn('another setup (process '+str(process.pid)+')', result.stderr)
        self.assertTrue((self.prefix/'install.lock/owner').exists()); self.assertFalse((self.prefix/'current').exists())

    def test_uncertain_locks_are_preserved_with_exact_instructions(self):
        process = subprocess.Popen(['sleep', '30']); self.addCleanup(process.wait); self.addCleanup(process.kill)
        cases = {'unrelated live process': str(process.pid)+'\n'+os.uname().nodename+'\n',
                 'other host': '1\nother-host\n', 'missing owner': None}
        for label, owner in cases.items():
            with self.subTest(label=label):
                shutil.rmtree(self.prefix, ignore_errors=True); self.lock(owner)
                result = self.run_setup(); self.assertEqual(result.returncode, 2)
                self.assertIn('rm -r', result.stderr); self.assertTrue((self.prefix/'install.lock').is_dir())
                self.assertFalse((self.prefix/'current').exists())

    def test_fresh_rebuilds_verified_tools_and_removes_the_previous_release(self):
        self.assertEqual(self.run_setup().returncode, 0)
        before = (self.prefix/'current').resolve(); downloads = len(self.ledger.read_text().splitlines())
        result = self.run_setup('--fresh'); self.assertEqual(result.returncode, 0, result.stderr)
        after = (self.prefix/'current').resolve()
        self.assertNotEqual(before, after); self.assertFalse(before.exists()); self.assertTrue((after/'complete').is_file())
        self.assertEqual(len(self.ledger.read_text().splitlines()), 2*downloads)
        self.assertEqual([p.name for p in (self.prefix/'releases').iterdir()], [after.name])
        for path in self.protected: self.assertEqual(path.read_text(), 'preserve existing user settings\n')
        self.assertEqual(self.run_setup('--check', '--fresh').returncode, 2)

    def test_corrupt_tool_is_reported_by_check_and_repaired_by_setup(self):
        self.assertEqual(self.run_setup().returncode, 0)
        before = (self.prefix/'current').resolve()
        (before/'bin/tofu').write_text('#!/bin/sh\nexit 1\n')
        result = self.run_setup('--check'); self.assertEqual(result.returncode, 2); self.assertIn('--fresh', result.stderr)
        result = self.run_setup(); self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual((self.prefix/'current').resolve(), before); self.assertFalse(before.exists())
        self.assertEqual(self.run_setup('--check').returncode, 0)

    def test_failed_fresh_rebuild_preserves_the_working_installation(self):
        self.assertEqual(self.run_setup().returncode, 0)
        before = (self.prefix/'current').resolve()
        (self.cache/'uv.tgz').write_bytes(b'corrupted')
        result = self.run_setup('--fresh'); self.assertEqual(result.returncode, 2); self.assertIn('checksum mismatch', result.stderr)
        self.assertEqual((self.prefix/'current').resolve(), before); self.assertTrue(before.exists())
        self.assertEqual(self.run_setup('--check').returncode, 0)
        self.assertFalse((self.prefix/'install.lock').exists())

    def test_interrupted_installation_leftovers_are_removed_on_the_next_setup(self):
        self.assertEqual(self.run_setup().returncode, 0)
        leftover = self.prefix/'releases/abandoned.partial'; leftover.mkdir(); (leftover/'bin').mkdir()
        self.assertEqual(self.run_setup('--fresh').returncode, 0)
        self.assertFalse(leftover.exists())

    def test_debug_diagnostics_are_bounded_and_never_show_values(self):
        self.assertEqual(self.run_setup().returncode, 0)
        self.env['AWS_SECRET_ACCESS_KEY'] = 'SECRETVALUE'
        result = self.run_setup('--check', '--debug'); self.assertEqual(result.returncode, 0, result.stderr)
        for expected in ('debug: platform=linux-x86_64', 'debug: lock=none', 'debug: pins=match', 'debug: aws: aws-cli/2.36.14'):
            self.assertIn(expected, result.stderr)
        self.assertNotIn('SECRETVALUE', result.stderr)

    def test_doctor_without_tools_reports_setup_without_installing(self):
        result = subprocess.run(['bash', str(self.repo/'workspace'), 'doctor', 'project.json'], env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Managed tools   Action needed  managed tools are not installed', result.stdout)
        self.assertIn('next: ./workspace setup', result.stdout); self.assertIn('Unknown', result.stdout)
        self.assertFalse(self.prefix.exists()); self.assertFalse(self.ledger.exists())

    def test_doctor_json_without_tools_is_valid_for_the_guide(self):
        result = subprocess.run(['bash', str(self.repo/'workspace'), 'doctor', '--json'], env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 1)
        page = json.loads(result.stdout)
        self.assertFalse(page['ready']); self.assertEqual(page['rows'][0]['state'], 'Action needed')
        self.assertEqual(page['rows'][0]['next'], './workspace setup'); self.assertFalse(self.prefix.exists())

    def test_guide_records_readiness_and_opens_the_page_without_login(self):
        minimal = self.root/'minimal'; minimal.mkdir()
        for name in ('bash','dirname','basename','tar','sha256sum','cat','id','mkdir','df','awk','ps','grep','head','cut','mktemp','mv','rm','date'):
            (minimal/name).symlink_to(shutil.which(name))
        for name in ('uname','getconf','curl','dpkg-deb'):
            (minimal/name).symlink_to(self.shims/name)
        opened = self.root/'opened'
        executable(minimal/'xdg-open', '#!/bin/sh\necho "$1" > ' + shlex.quote(str(opened)) + '\n')
        shutil.copy(ROOT/'scripts/aws/workspace-guide.sh', self.repo/'scripts/aws/workspace-guide.sh')
        self.env.update(PATH=str(minimal), DISPLAY=':0')
        result = subprocess.run(['bash', str(self.repo/'workspace'), 'guide'], env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr); self.assertIn('--system-packages', result.stderr)
        self.assertEqual(opened.read_text().strip(), str(self.repo/'docs/aws-setup-guide.html'))
        status = (self.repo/'.tools/guide/status.js').read_text()
        self.assertTrue(status.startswith('window.WORKSPACE_STATUS = {'))
        page = json.loads(status.split(' = ', 1)[1].rstrip().rstrip(';'))
        self.assertEqual(page['rows'][0]['next'], './workspace setup --system-packages')
        self.assertEqual(sorted(p.name for p in (self.repo/'.tools/guide').iterdir()), ['status.js'])
        self.assertFalse(self.prefix.exists()); self.assertFalse(self.ledger.exists())

    def test_check_cannot_install_system_packages(self):
        self.assertEqual(self.run_setup('--check', '--system-packages').returncode, 2)
        self.assertFalse(self.prefix.exists())

    def test_missing_system_tools_and_privileges_have_repair_instructions(self):
        minimal = self.root/'minimal'; minimal.mkdir()
        for name in ('bash','dirname','basename','tar','sha256sum','cat','id','mkdir','df','awk','ps','grep','head','cut'):
            (minimal/name).symlink_to(shutil.which(name))
        for name in ('uname','getconf','curl','dpkg-deb'):
            (minimal/name).symlink_to(self.shims/name)
        self.env['PATH'] = str(minimal)
        result = self.run_setup()
        self.assertEqual(result.returncode, 2); self.assertIn('--system-packages',result.stderr)
        (minimal/'apt-get').symlink_to('/bin/true')
        result = self.run_setup('--system-packages')
        self.assertEqual(result.returncode, 2); self.assertIn('administrator',result.stderr)
        self.assertFalse(self.prefix.exists()); self.assertFalse(self.ledger.exists())

    def test_failed_native_package_install_does_not_start_downloads(self):
        minimal = self.root/'minimal'; minimal.mkdir()
        for name in ('bash','dirname','basename','tar','sha256sum','cat','id','mkdir','df','awk','ps','grep','head','cut'):
            (minimal/name).symlink_to(shutil.which(name))
        for name in ('uname','getconf','curl','dpkg-deb'):
            (minimal/name).symlink_to(self.shims/name)
        (minimal/'apt-get').symlink_to('/bin/true')
        executable(minimal/'sudo','#!/bin/sh\nexit 1\n')
        self.env['PATH'] = str(minimal)
        self.assertNotEqual(self.run_setup('--system-packages').returncode,0)
        self.assertFalse(self.prefix.exists()); self.assertFalse(self.ledger.exists())


class Authentication(unittest.TestCase):
    def setUp(self):
        self.identity = {'Account':'111111111111', 'Arn':'arn:aws:iam::111111111111:user/operator'}
        self.env = {'PATH':os.environ['PATH']}

    def test_cli_sdk_identity_match_is_bounded_and_never_authorizes_deployment(self):
        commands=[]
        def request(command, env, timeout):
            commands.append(command); self.assertEqual(timeout,30)
            return subprocess.CompletedProcess(command,0,json.dumps(self.identity),'')
        with patch.dict(A.B, profile_environment=lambda p,r:self.env, request=request):
            result = A.auth_check('temporary','us-east-1')
        self.assertTrue(result['cli_sdk_principal_match']); self.assertFalse(result['deployment_authorized'])
        self.assertIn('pending',result['backend_identity']); self.assertEqual(len(commands),2)
        self.assertIn('get-caller-identity',commands[0]); self.assertIn('_sdk-identity',commands[1])

    def test_identity_mismatch_rejects(self):
        for arns in [('arn:aws:iam::111111111111:user/operator','arn:aws:iam::111111111111:user/other'),
                     ('arn:aws:sts::111111111111:assumed-role/first/session','arn:aws:sts::111111111111:assumed-role/second/session')]:
            identities=[{**self.identity,'Arn':arn} for arn in arns]
            def request(command,env,timeout): return subprocess.CompletedProcess(command,0,json.dumps(identities.pop(0)),'')
            with self.subTest(arns=arns), patch.dict(A.B, profile_environment=lambda p,r:self.env, request=request), self.assertRaisesRegex(A.B['Failure'],'different identities'):
                A.auth_check('temporary','us-east-1')

    def test_same_assumed_role_with_different_sessions_matches(self):
        identities=[{'Account':'111111111111','Arn':'arn:aws:sts::111111111111:assumed-role/reviewed/cli-session'},
                    {'Account':'111111111111','Arn':'arn:aws:sts::111111111111:assumed-role/reviewed/sdk-session'}]
        def request(command,env,timeout): return subprocess.CompletedProcess(command,0,json.dumps(identities.pop(0)),'')
        with patch.dict(A.B, profile_environment=lambda p,r:self.env, request=request):
            result=A.auth_check('temporary','us-east-1')
        self.assertTrue(result['cli_sdk_principal_match'])
        self.assertNotEqual(result['identity']['Arn'],result['sdk_identity']['Arn'])

    def test_expired_login_is_actionable_and_redacted(self):
        def request(command,env,timeout): return subprocess.CompletedProcess(command,1,'','ExpiredToken SECRET-VALUE')
        with patch.dict(A.B, profile_environment=lambda p,r:self.env, request=request), self.assertRaises(A.B['Failure']) as error:
            A.auth_check('temporary','us-east-1')
        self.assertIn('expired_login',str(error.exception)); self.assertNotIn('SECRET',str(error.exception))

    def test_timeout_is_bounded(self):
        def request(command,env,timeout): raise subprocess.TimeoutExpired(command,timeout)
        with patch.dict(A.B, profile_environment=lambda p,r:self.env, request=request), self.assertRaisesRegex(A.B['Failure'],'timed out'):
            A.auth_check('temporary','us-east-1')

    def test_root_default_and_invalid_arn_are_rejected(self):
        with self.assertRaises(A.B['Failure']): A.selection('default','us-east-1')
        for arn in ('arn:aws:iam::111111111111:root','arn:aws:iam::222222222222:user/operator','arn:aws:iam::111111111111:assumed-role/role/session','arn:aws:sts::111111111111:assumed-role/missing-session'):
            with self.subTest(arn=arn), self.assertRaises(A.B['Failure']): A.identity({**self.identity,'Arn':arn})

    def test_new_console_login_is_native_and_arguments_are_literal(self):
        commands=[]
        with patch.object(A,'profile_method',return_value='new'), patch.object(A,'interactive',side_effect=commands.append), patch.object(A,'auth_check',return_value={'status':'authenticated'}):
            A.login('temporary','us-east-1','auto',True)
        self.assertEqual(commands,[['aws','login','--profile','temporary','--region','us-east-1','--remote']])

    def test_sso_renewal_does_not_reconfigure_existing_profile(self):
        commands=[]
        with patch.object(A,'profile_method',return_value='sso'), patch.object(A,'interactive',side_effect=commands.append), patch.object(A,'auth_check',return_value={}):
            A.login('temporary','us-east-1','auto',False)
        self.assertEqual(commands,[['aws','sso','login','--profile','temporary','--region','us-east-1']])

    def test_new_sso_configures_then_logs_in(self):
        commands=[]
        with patch.object(A,'profile_method',side_effect=['new','sso']), patch.object(A,'interactive',side_effect=commands.append), patch.object(A,'auth_check',return_value={}):
            A.login('temporary','us-east-1','sso',True)
        self.assertEqual(commands[0],['aws','configure','sso','--profile','temporary'])
        self.assertEqual(commands[1][-2:],['--no-browser','--use-device-code'])

    def test_login_method_conflict_stops_before_interactive_command(self):
        with patch.object(A,'profile_method',return_value='sso'), patch.object(A,'interactive') as native, self.assertRaises(A.B['Failure']):
            A.login('temporary','us-east-1','console',False)
        native.assert_not_called()

    def test_headless_login_requires_user_terminal(self):
        with patch.object(sys.stdin,'isatty',return_value=False), patch.object(subprocess,'call') as call, self.assertRaises(A.B['Failure']):
            A.interactive(['aws','login'])
        call.assert_not_called()

    def test_conflicting_credentials_are_rejected_before_new_profile_creation(self):
        with patch.dict(os.environ,{'AWS_ACCESS_KEY_ID':'SECRET'},clear=True), self.assertRaisesRegex(A.B['Failure'],'conflicting environment'):
            A.profile_method('new','us-east-1')

    def test_github_ambient_token_is_rejected(self):
        with patch.dict(os.environ,{'GH_TOKEN':'SECRET'},clear=True), patch.object(A,'interactive') as native, self.assertRaises(A.B['Failure']):
            A.github_login()
        native.assert_not_called()

    def test_region_only_profile_can_complete_first_login_without_changing_files(self):
        with tempfile.TemporaryDirectory(dir=BASE) as directory:
            config=Path(directory)/'config'; credentials=Path(directory)/'credentials'
            config.write_text('[profile first]\nregion = us-east-1\n')
            credentials.write_text('')
            with patch.dict(os.environ, {'AWS_CONFIG_FILE':str(config), 'AWS_SHARED_CREDENTIALS_FILE':str(credentials)}, clear=True):
                self.assertEqual(A.profile_method('first','us-east-1'),'new')
            self.assertEqual(config.read_text(),'[profile first]\nregion = us-east-1\n')

    def test_implicit_ini_defaults_rejected_even_for_new_profile(self):
        with tempfile.TemporaryDirectory(dir=BASE) as directory:
            config=Path(directory)/'config'; credentials=Path(directory)/'credentials'
            config.write_text('[DEFAULT]\nregion = us-east-1\n'); credentials.write_text('')
            with patch.dict(os.environ, {'AWS_CONFIG_FILE':str(config), 'AWS_SHARED_CREDENTIALS_FILE':str(credentials)}, clear=True), self.assertRaisesRegex(A.B['Failure'],'implicit INI'):
                A.profile_method('new','us-east-1')

    def test_static_key_profile_rejected_before_native_login(self):
        with tempfile.TemporaryDirectory(dir=BASE) as directory:
            config=Path(directory)/'config'; credentials=Path(directory)/'credentials'
            config.write_text(''); credentials.write_text('[static]\naws_access_key_id = SECRET\naws_secret_access_key = SECRET\n')
            with patch.dict(os.environ, {'AWS_CONFIG_FILE':str(config), 'AWS_SHARED_CREDENTIALS_FILE':str(credentials)}, clear=True), self.assertRaises(A.B['Failure']) as error:
                A.profile_method('static','us-east-1')
            self.assertNotIn('SECRET',str(error.exception))


class PinCompatibility(unittest.TestCase):
    def test_operator_pins_match_the_existing_native_engine_and_workspace_roots(self):
        toolbox=json.loads((ROOT/'infra/aws/runner/workspace/toolbox/versions.json').read_text())
        rows=[line.split('\t') for line in (ROOT/'scripts/aws/workstation-tools.lock.tsv').read_text().splitlines() if not line.startswith('#')]
        for platform in ('linux-x86_64','linux-aarch64','darwin-x86_64','darwin-aarch64'):
            with self.subTest(platform=platform):
                tools={tool:version for host,tool,version,url,checksum in rows if host==platform}
                self.assertEqual(set(tools),{'uv','python','tofu','aws','ssm','gh'})
                self.assertEqual(tools['aws'],toolbox['aws_cli']['version'])
                self.assertEqual(tools['ssm'],toolbox['session_plugin_version'])
                for root in ('bootstrap','platform','runner'):
                    self.assertIn('required_version = "= '+tools['tofu']+'"',(ROOT/f'infra/aws/{root}/workspace/versions.tf').read_text())
        lock=(ROOT/'scripts/aws/controller-requirements.lock').read_text()
        for package in ('boto3','botocore'):
            self.assertIn(package+'=='+toolbox['sdk_version']+' ',lock)
        self.assertIn('awscrt==',lock)


if __name__ == '__main__':
    unittest.main(verbosity=2)
