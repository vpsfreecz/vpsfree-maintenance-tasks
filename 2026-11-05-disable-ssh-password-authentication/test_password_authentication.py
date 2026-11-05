#!/usr/bin/env python3
"""Run locally with Python 3, OpenSSH sshd/ssh-keygen and ordinary shell tools.
No daemon, node, container, database or mail operation is performed.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

TASK = Path(__file__).resolve().parent
BACKUP = 'sshd_config.before-2026-11-05-disable-password-authentication'


class PolicyChecks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ssh-password-policy-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.sshd = shutil.which('sshd')
        if not self.sshd:
            self.fail('A real OpenSSH sshd is required')
        self.key = self.root / 'host_key'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.key)], check=True)
        self.write_tool('sshd', '''#!/usr/bin/env python3
import os, subprocess, sys
from pathlib import Path
if '-t' in sys.argv and os.environ.get('FAIL_VALIDATION'): sys.exit(1)
r = subprocess.run([os.environ['REAL_SSHD'], *sys.argv[1:]])
if '-T' in sys.argv and os.environ.get('CHANGE_BACKUP'):
    with Path(os.environ['CHANGE_BACKUP']).open('a') as f: f.write('# concurrent writer\\n')
sys.exit(r.returncode)
''')
        self.write_tool('rc-service', '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
p = Path(os.environ['SERVICE_LOG'])
n = int(p.read_text()) + 1 if p.exists() else 1
p.write_text(str(n))
assert sys.argv[1:] == ['sshd', 'restart']
sys.exit(1 if os.environ.get('FAIL_RESTART') and n == 1 else 0)
''')

    def write_tool(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def guest(self, name, text):
        p = self.root / name
        p.mkdir()
        (p / 'sshd_config').write_text(f'HostKey {self.key}\n{text}')
        (p / 'sshd_config').chmod(0o640)
        self.install_payload(p)
        return p

    def install_payload(self, p):
        text = (TASK / 'disable_ssh_password_authentication_in_container.sh').read_text()
        text = text.replace('config=/etc/ssh/sshd_config', f'config={p}/sshd_config')
        text = text.replace('include_dir=/etc/ssh/sshd_config.d', f'include_dir={p}/sshd_config.d')
        (p / 'payload').write_text(text)
        (p / 'payload').chmod(0o755)

    def environment(self, p, **extra):
        return dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}', REAL_SSHD=self.sshd,
                    SERVICE_LOG=str(p / 'restarts'), **extra)

    def run_guest(self, p, mode=None, **extra):
        return subprocess.run([str(p / 'payload')] + ([mode] if mode else []),
                              env=self.environment(p, **extra), text=True, capture_output=True)

    def effective(self, p, user=None):
        args = [self.sshd, '-T', '-f', str(p / 'sshd_config')]
        if user:
            args += ['-C', f'user={user},host=localhost,addr=127.0.0.1']
        r = subprocess.run(args, text=True, capture_output=True, check=True)
        return [line.split()[1].lower() for line in r.stdout.splitlines()
                if line.split()[0].lower() == 'passwordauthentication'][0]

    def test_disabled_real_parser_preserves_bytes_metadata_and_backup(self):
        cases = [
            '# not first\nPasswordAuthentication no\n',
            '  pAsSwOrDaUtHeNtIcAtIoN = "no"\n',
            'PasswordAuthentication no\nPasswordAuthentication yes\n',
            'PasswordAuthentication no\nPasswordAuthentication no\n',
            'PasswordAuthentication no\nMatch User root\n PasswordAuthentication no\n PasswordAuthentication yes\n',
            'PasswordAuthentication yes\nMatch all\n PasswordAuthentication no\n',
            'Match all\n PasswordAuthentication no\n',
        ]
        for i, text in enumerate(cases):
            with self.subTest(text=text):
                p = self.guest(str(i), text)
                original = (p / 'sshd_config').read_bytes()
                before = (p / 'sshd_config').stat()
                self.assertEqual(self.effective(p), 'no')
                r = self.run_guest(p)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn('unchanged', r.stdout)
                self.assertEqual((p / 'sshd_config').read_bytes(), original)
                after = (p / 'sshd_config').stat()
                for field in ['st_ino', 'st_mode', 'st_uid', 'st_gid', 'st_mtime_ns']:
                    self.assertEqual(getattr(before, field), getattr(after, field))
                self.assertFalse((p / BACKUP).exists())
                self.assertFalse((p / 'restarts').exists())
                (p / BACKUP).write_text('retained original')
                self.assertEqual(self.run_guest(p).returncode, 0)
                self.assertEqual((p / BACKUP).read_text(), 'retained original')

    def test_mixed_and_invalid_policy_fails_without_mutation(self):
        cases = [
            'PasswordAuthentication no\nMatch User root\n PasswordAuthentication yes\n',
            'Match User root\n PasswordAuthentication no\n',
            'PasswordAuthentication no\nMatch User root\n PasswordAuthentication no\nMatch User root\n PasswordAuthentication yes\n',
            'BogusKeyword yes\n',
        ]
        for i, text in enumerate(cases):
            p = self.guest(str(i), text)
            original = (p / 'sshd_config').read_bytes()
            if i == 0:
                self.assertEqual(self.effective(p), 'no')
                self.assertEqual(self.effective(p, 'root'), 'yes')
            r = self.run_guest(p)
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual((p / 'sshd_config').read_bytes(), original)
            self.assertFalse((p / BACKUP).exists())
            self.assertFalse((p / 'restarts').exists())

    def test_enabled_validation_and_restart_recovery(self):
        for i, text in enumerate(['PasswordAuthentication yes\n', '# default yes\n']):
            p = self.guest(str(i), text)
            original = (p / 'sshd_config').read_bytes()
            self.assertEqual(self.effective(p), 'yes')
            r = self.run_guest(p)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(self.effective(p, 'root'), 'no')
            self.assertEqual((p / BACKUP).read_bytes(), original)
            self.assertEqual((p / 'restarts').read_text(), '1')
            self.assertEqual(self.run_guest(p).returncode, 0)
            self.assertEqual((p / 'restarts').read_text(), '1')
        p = self.guest('validation', 'PasswordAuthentication yes\n')
        original = (p / 'sshd_config').read_bytes()
        self.assertNotEqual(self.run_guest(p, FAIL_VALIDATION='1').returncode, 0)
        self.assertEqual((p / 'sshd_config').read_bytes(), original)
        self.assertFalse((p / BACKUP).exists())
        p = self.guest('restart', 'PasswordAuthentication yes\n')
        original = (p / 'sshd_config').read_bytes()
        self.assertNotEqual(self.run_guest(p, FAIL_RESTART='1').returncode, 0)
        self.assertEqual((p / 'sshd_config').read_bytes(), original)
        self.assertEqual((p / BACKUP).read_bytes(), original)
        self.assertEqual((p / 'restarts').read_text(), '2')
        self.assertNotEqual((p / BACKUP).stat().st_ino, (p / 'sshd_config').stat().st_ino)

    def test_backup_report_is_read_only_and_hashes_original(self):
        for name, text, policy in [('enabled', 'PasswordAuthentication yes\n', 'enabled'),
                                   ('disabled', 'PasswordAuthentication no\n', 'disabled'),
                                   ('mixed', 'PasswordAuthentication no\nMatch User root\n PasswordAuthentication yes\n', 'unknown')]:
            p = self.guest(name, 'PasswordAuthentication no\n')
            (p / BACKUP).write_text(f'HostKey {self.key}\n{text}')
            original = (p / BACKUP).read_bytes()
            config = (p / 'sshd_config').read_bytes()
            names = set(p.iterdir())
            r = self.run_guest(p, 'report-backup')
            self.assertEqual(r.stdout, f'{policy}\t{hashlib.sha256(original).hexdigest()}\n')
            self.assertEqual(r.returncode, 1 if policy == 'unknown' else 0)
            self.assertEqual((p / BACKUP).read_bytes(), original)
            self.assertEqual((p / 'sshd_config').read_bytes(), config)
            self.assertEqual(set(p.iterdir()), names)
            if name == 'enabled':
                r = self.run_guest(p, 'report-backup', CHANGE_BACKUP=str(p / BACKUP))
                self.assertEqual(r.stdout, 'unknown\t-\n')
                self.assertNotEqual(r.returncode, 0)
        for name in ['missing', 'directory', 'symlink']:
            p = self.guest(name, 'PasswordAuthentication no\n')
            if name == 'directory': (p / BACKUP).mkdir()
            if name == 'symlink': (p / BACKUP).symlink_to(p / 'sshd_config')
            r = self.run_guest(p, 'report-backup')
            self.assertEqual(r.stdout, 'unknown\t-\n')
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse((p / 'restarts').exists())

    def test_include_boundary(self):
        p = self.guest('include', 'Include /etc/ssh/sshd_config.d/*.conf\nPasswordAuthentication no\n')
        # The native parser also needs the isolated path, not the host's directory.
        text = (p / 'sshd_config').read_text().replace('/etc/ssh/sshd_config.d', str(p / 'sshd_config.d'))
        (p / 'sshd_config').write_text(text)
        payload = (p / 'payload').read_text().replace('"/etc/ssh/sshd_config.d/*.conf"', f'"{p}/sshd_config.d/*.conf"')
        (p / 'payload').write_text(payload)
        original = (p / 'sshd_config').read_bytes()
        self.assertEqual(self.run_guest(p).returncode, 0)
        (p / 'sshd_config.d').mkdir()
        (p / 'sshd_config.d' / 'override.conf').symlink_to(p / 'absent')
        self.assertNotEqual(self.run_guest(p).returncode, 0)
        self.assertEqual((p / 'sshd_config').read_bytes(), original)
        self.assertFalse((p / BACKUP).exists())

    def test_host_report_rows_and_guest_failure(self):
        guests = {}
        for i, policy in enumerate(['yes', 'no', None, 'failure'], 1):
            p = self.guest(f'guest{i}', 'PasswordAuthentication no\n')
            if policy in ['yes', 'no']:
                (p / BACKUP).write_text(f'HostKey {self.key}\nPasswordAuthentication {policy}\n')
            guests[str(i)] = dict(path=str(p), failure=policy == 'failure')
        (self.root / 'guests.json').write_text(json.dumps(guests))
        self.write_tool('hostname', '#!/bin/sh\nprintf "fixture-node.example\\n"\n')
        self.write_tool('osctl', '''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
guests = json.loads(Path(os.environ['GUESTS']).read_text())
if args == ['ct','ls','-H','-o','pool,id','--distribution','alpine','--state','running']:
    for id in guests: print('tank', id)
    sys.exit(0)
assert args[:2] == ['--pool','tank'] and args[2:4] == ['ct','runscript']
assert args[6:] == ['report-backup'] and Path(args[5]).is_absolute()
assert not sys.stdin.read()
g = guests[args[4]]
if g['failure']: print('unreliable guest output'); sys.exit(1)
env = dict(os.environ, SERVICE_LOG=str(Path(g['path'])/'restarts'))
sys.exit(subprocess.run([str(Path(g['path'])/'payload'), *args[6:]],env=env).returncode)
''')
        r = subprocess.run([str(TASK / 'disable_ssh_password_authentication.sh'), '--report-backup'],
                           env=self.environment(self.root, GUESTS=str(self.root / 'guests.json')),
                           text=True, capture_output=True, cwd=self.root)
        self.assertEqual(r.returncode, 1)
        rows = [line.split('\t') for line in r.stdout.splitlines()]
        self.assertEqual(len(rows), 4)
        self.assertEqual([row[:4] for row in rows], [['ssh-password-backup-v1','fixture-node.example','tank',str(i)] for i in range(1,5)])
        self.assertEqual([row[4] for row in rows], ['enabled','disabled','unknown','unknown'])
        self.assertEqual([row[5] for row in rows[2:]], ['-','-'])
        for i in [1,2]:
            self.assertEqual(rows[i-1][5], hashlib.sha256((Path(guests[str(i)]['path']) / BACKUP).read_bytes()).hexdigest())
        self.assertTrue(all(not (Path(g['path']) / 'restarts').exists() for g in guests.values()))


if __name__ == '__main__':
    unittest.main(verbosity=2)
