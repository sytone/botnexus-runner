"""Offline operation boundaries. Run in an authorized isolated Linux container only."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[4]
ENTRY = Path('scripts/repo/Invoke-RunnerImageBuild.ps1')
SENTINEL = 'PRIVATE_OPERATION_SENTINEL_74291'


class RunnerOperations(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='operations-', dir='/work'))
        self.repo = self.root / 'source'
        shutil.copytree(SOURCE, self.repo, ignore=shutil.ignore_patterns('.git', '__pycache__'))
        self.git('init', '-q')
        self.git('config', 'user.name', 'Synthetic Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        self.head = self.git('rev-parse', 'HEAD').strip()
        # Fixture input must itself match Git blobs; do not relax production hashes.
        for name in self.git('ls-files', '-z').split('\0')[:-1]:
            (self.repo / name).write_bytes(subprocess.check_output(['git', '-C', str(self.repo), 'show', 'HEAD:' + name]))
        # Refresh only the synthetic index; prove its content tree is unchanged.
        original_tree = self.git('rev-parse', 'HEAD^{tree}')
        self.git('add', '.')
        self.assertEqual(original_tree, self.git('write-tree'))
        self.assertEqual('', self.git('status', '--porcelain'))
        self.config = self.root / (SENTINEL + '.json')
        self.write_build_profile('localhost/private-' + SENTINEL.lower() + ':src-' + self.head)
        self.marker = self.root / 'native-called'
        self.native = self.root / 'container-tool'
        self.native.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "' + str(self.marker) + '"\necho ' + SENTINEL + '\necho ' + SENTINEL + ' >&2\nexit "${FIXTURE_EXIT:-0}"\n')
        self.native.chmod(0o700)

    def tearDown(self):
        shutil.rmtree(self.root)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True, stderr=subprocess.DEVNULL)

    def write_build_profile(self, tag):
        profile={'schemaVersion':1,'account':{'tenantId':'22222222-2222-2222-2222-222222222222','subscriptionId':'11111111-1111-1111-1111-111111111111','accountType':'user','accountName':'operator@example.invalid'},'target':{'resourceId':'/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/fixture/providers/Microsoft.App/jobs/runner'},'images':{'buildTag':tag}}
        self.config.write_text(json.dumps(profile))

    def invoke(self, *extra, expected=None, config=None, code=0, source=None):
        env = os.environ.copy()
        env['FIXTURE_EXIT'] = str(code)
        before = dict(os.environ)
        p = subprocess.run(['pwsh', '-NoProfile', '-File', str(self.repo / ENTRY), '-SourceRoot', str(source or self.repo), '-ExpectedCommit', expected or self.head, '-ConfigurationPath', str(config or self.config), '-PrivateRoot', str(self.root), '-ConfigurationSha256', hashlib.sha256((config or self.config).read_bytes()).hexdigest() if (config or self.config).is_file() and not (config or self.config).is_fifo() else 'a'*64, '-ContainerCommand', str(self.native), *extra], capture_output=True, text=True, env=env)
        self.assertNotIn(SENTINEL.lower(), (p.stdout + p.stderr).lower())
        self.assertNotIn(str(self.root), p.stdout + p.stderr)
        self.assertNotIn(str(self.config), p.stdout + p.stderr)
        self.assertNotIn(str(self.native), p.stdout + p.stderr)
        self.assertEqual(before, dict(os.environ))
        return p

    def test_preview_is_read_only(self):
        before = {str(p.relative_to(self.root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.root.rglob('*') if p.is_file()}
        p = self.invoke('-WhatIf')
        self.assertEqual(0, p.returncode, p.stderr)
        self.assertFalse(self.marker.exists())
        after = {str(p.relative_to(self.root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(before, after)

    def test_preview_does_not_refresh_stale_index(self):
        target = self.repo / 'README.md'
        target.write_bytes(target.read_bytes())
        before = {str(p.relative_to(self.root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.root.rglob('*') if p.is_file()}
        p = self.invoke('-WhatIf')
        self.assertEqual(0, p.returncode, p.stderr)
        after = {str(p.relative_to(self.root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(before, after)
        self.assertFalse(self.marker.exists())

    def test_exact_identity_and_literal_native_arguments(self):
        p = self.invoke()
        self.assertEqual(0, p.returncode, p.stderr)
        receipt = json.loads(p.stdout)
        self.assertEqual(self.head, receipt['sourceCommit'])
        self.assertIsNone(receipt['tests'])
        self.assertFalse(receipt['accepted'])
        self.assertEqual('build', self.marker.read_text().splitlines()[0])
        self.assertIn('--label', self.marker.read_text().splitlines())
        self.assertEqual(str(self.repo / 'infra/buildtest/runner'), self.marker.read_text().splitlines()[-1])

    def test_native_nonzero_is_failure_without_private_output(self):
        p = self.invoke(code=9)
        self.assertNotEqual(0, p.returncode)
        self.assertIn('exit code 9', p.stderr)
        self.assertTrue(self.marker.exists())

    def test_wrong_commit_denied_before_native(self):
        self.assertNotEqual(0, self.invoke(expected='0' * 40).returncode)
        self.assertFalse(self.marker.exists())

    def test_dirty_source_denied_before_native(self):
        (self.repo / 'README.md').write_text('dirty')
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.marker.exists())

    def test_private_configuration_must_be_external(self):
        internal = self.repo / 'private.json'
        shutil.copyfile(self.config, internal)
        self.assertNotEqual(0, self.invoke(config=internal).returncode)
        self.assertFalse(self.marker.exists())

    def test_image_tag_must_match_source_identity(self):
        self.write_build_profile('localhost/runner:latest')
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.marker.exists())

    def test_invalid_private_configuration_is_not_disclosed(self):
        self.config.write_text('{invalid-' + SENTINEL)
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.marker.exists())

    def test_missing_native_tool_does_not_disclose_path(self):
        self.native.unlink()
        p = self.invoke()
        self.assertNotEqual(0, p.returncode)
        self.assertIn('Native command could not start', p.stderr)

    def test_runtime_closure_mismatch_denied(self):
        manifest = self.repo / 'infra/buildtest/runner/image-runtime.json'
        data = json.loads(manifest.read_text())
        data['runtimeFiles'].remove('RunnerTimeout.psm1')
        manifest.write_text(json.dumps(data))
        self.git('add', '.')
        self.git('commit', '-qm', 'broken closure fixture')
        self.head = self.git('rev-parse', 'HEAD').strip()
        self.write_build_profile('localhost/runner:src-' + self.head)
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.marker.exists())

    def test_repeat_execution_is_source_stable(self):
        self.assertEqual(0, self.invoke().returncode)
        self.assertEqual(0, self.invoke().returncode)
        self.assertEqual('', self.git('status', '--porcelain'))

    def test_byte_drift_is_not_normalized(self):
        target = self.repo / 'infra/buildtest/runner/Invoke-Runner.ps1'
        target.write_bytes(target.read_bytes().replace(b'\n', b'\r\n'))
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.marker.exists())

    def test_image_owned_closure_is_complete(self):
        runner = self.repo / 'infra/buildtest/runner'
        manifest = json.loads((runner / 'image-runtime.json').read_text())
        docker = (runner / 'Dockerfile').read_text()
        copied = []
        for line in docker.splitlines():
            if line.startswith('COPY ') and '--from=' not in line:
                self.assertEqual('/runner/', line.split()[-1])
                copied.extend(line.split()[1:-1])
        self.assertEqual(sorted(manifest['runtimeFiles']), sorted(copied))
        self.assertEqual(len(copied), len(set(copied)))
        for name in copied:
            self.assertTrue((runner / name).is_file(), name)
        required = ['Invoke-Runner.ps1', 'Invoke-RunnerPipeline.ps1', 'Invoke-RunnerTransport.ps1', 'RunnerProject.psm1', 'Import-RunnerDiagnostic.ps1', 'DiagnosticContainment.cs', 'Invoke-DiagnosticOwnedCommand.ps1', 'Invoke-ProjectCommand.ps1', 'project.schema.json', 'RunnerTimeout.psm1']
        self.assertTrue(set(required).issubset(copied))
        self.assertNotIn('SourceSnapshot.psm1', copied)
        self.assertNotIn('RunnerEvidence.psm1', copied)

    def test_infrastructure_generic_immutable_inputs(self):
        source = (self.repo / 'infra/buildtest/main.bicep').read_text()
        self.assertIn('param runnerImageRepository string', source)
        self.assertIn('param runnerImageDigest string', source)
        self.assertIn("var runnerImage = '${runnerImageRepository}@sha256:${runnerImageDigest}'", source)
        self.assertIn('image: runnerImage', source)
        for name in ['PROJECT_CONFIG_PATH', 'PROJECT_CONFIG_SHA256', 'RUNNER_IMAGE', 'REPLICA_TIMEOUT_SECONDS']:
            self.assertIn("name: '" + name + "'", source)
        self.assertNotIn("name: 'TEST_MODE'", source)
        self.assertNotIn("name: 'BASE_REF'", source)
        self.assertIn('replicaTimeout: 1200', source)
        self.assertIn("triggerType: 'Manual'", source)
        self.assertIn("memory: '24Gi'", source)
        self.assertIn("cpu: json('8.0')", source)
        self.assertIn("type: 'UserAssigned'", source)


    def test_output_capture_is_bounded_and_continues_draining(self):
        source = (self.repo / ENTRY).read_text() + (self.repo / 'scripts/repo/Import-RunnerOperation.ps1').read_text()
        self.assertNotIn('ReadToEndAsync', source)
        self.assertIn('ReadAsync', source)
        self.native.write_text('#!/usr/bin/env python3\nimport os, threading\ndef emit(fd):\n for _ in range(4096): os.write(fd, b"PRIVATE_OPERATION_SENTINEL_74291" * 128)\na=threading.Thread(target=emit,args=(1,)); b=threading.Thread(target=emit,args=(2,))\na.start(); b.start(); a.join(); b.join()\n')
        p = self.invoke('-TimeoutSeconds', '20')
        self.assertEqual(0, p.returncode, p.stderr)
        self.assertLess(len(p.stdout) + len(p.stderr), 4096)

    def test_duplicate_private_json_keys_denied(self):
        tag = json.loads(self.config.read_text())['images']['buildTag']
        self.config.write_text(self.config.read_text()[:-1]+',"schemaVersion":1}')
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.marker.exists())

    def test_oversize_private_json_denied(self):
        self.config.write_text(self.config.read_text() + ' ' * 8192)
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.marker.exists())

    def test_linked_private_file_denied(self):
        alias = self.root / 'config-link'
        alias.symlink_to(self.config)
        self.assertNotEqual(0, self.invoke(config=alias).returncode)
        self.assertFalse(self.marker.exists())

    def test_linked_private_ancestor_denied(self):
        private = self.root / 'private'
        private.mkdir()
        target = private / 'build.json'
        shutil.copyfile(self.config, target)
        alias = self.root / 'private-link'
        alias.symlink_to(private, target_is_directory=True)
        self.assertNotEqual(0, self.invoke(config=alias / 'build.json').returncode)
        self.assertFalse(self.marker.exists())

    def test_linked_source_root_denied(self):
        alias = self.root / 'source-link'
        alias.symlink_to(self.repo, target_is_directory=True)
        p = self.invoke(source=alias)
        self.assertNotEqual(0, p.returncode)
        self.assertFalse(self.marker.exists())

    def test_private_json_schema_types_and_case_collisions(self):
        tag = json.loads(self.config.read_text())['images']['buildTag']
        for value in ['[]', 'null', 'true', '9', '{"imageTag":null}', '{"imageTag":42}', '{"imageTag":[]}', '{"imageTag":{}}', '{"imageTag":' + json.dumps(tag) + ',"ImageTag":' + json.dumps(tag) + '}', '{"imageTag":' + json.dumps(tag) + ',"secret":"' + SENTINEL + '"}', '{"imageTag":']:
            with self.subTest(valueType=value[:16]):
                self.marker.unlink(missing_ok=True)
                self.config.write_text(value)
                self.assertNotEqual(0, self.invoke().returncode)
                self.assertFalse(self.marker.exists())

    def test_private_directory_denied(self):
        private = self.root / SENTINEL
        private.mkdir()
        self.assertNotEqual(0, self.invoke(config=private).returncode)
        self.assertFalse(self.marker.exists())

    def test_owned_descendant_terminated_before_receipt(self):
        import time
        pidfile = self.root / 'child.pid'
        self.native.write_text('#!/bin/sh\nsleep 60 </dev/null >/dev/null 2>&1 &\necho $! > "' + str(pidfile) + '"\nexit 0\n')
        started = time.monotonic()
        p = self.invoke('-TimeoutSeconds', '5')
        elapsed = time.monotonic() - started
        self.assertTrue(pidfile.exists(), p.stderr)
        pid = int(pidfile.read_text())
        stat = Path('/proc') / str(pid) / 'stat'
        live = stat.exists() and stat.read_text().split(') ')[1].split()[0] != 'Z'
        if live:
            os.kill(pid, 9)
        self.assertFalse(live, 'Owned descendant survived command completion')
        self.assertNotEqual(0, p.returncode)
        self.assertLess(elapsed, 15)

    def test_timeout_redacted_and_owned_cleanup(self):
        import time
        self.native.write_text('#!/bin/sh\necho ' + SENTINEL + '\necho ' + SENTINEL + ' >&2\nsleep 60\n')
        before = {p.name for p in Path('/tmp').glob('runner-build-*')}
        started = time.monotonic()
        p = self.invoke('-TimeoutSeconds', '4')
        self.assertNotEqual(0, p.returncode)
        self.assertLess(time.monotonic() - started, 15)
        self.assertIn('allowance', p.stderr)
        self.assertEqual(before, {p.name for p in Path('/tmp').glob('runner-build-*')})


    def test_unknown_anchor_outcome_fails_closed_and_kills_descendant(self):
        pidfile = self.root / 'unknown.pid'
        self.native.write_text('#!/bin/sh\nsleep 60 </dev/null >/dev/null 2>&1 &\necho $! > "' + str(pidfile) + '"\nkill -9 "$PPID"\nexit 0\n')
        p = self.invoke('-TimeoutSeconds', '6')
        self.assertNotEqual(0, p.returncode)
        self.assertIn('unknown', p.stderr)
        self.assertNotIn('built-unqualified', p.stdout)
        self.assertTrue(pidfile.exists(), p.stderr)
        pid = int(pidfile.read_text())
        stat = Path('/proc') / str(pid) / 'stat'
        live = stat.exists() and stat.read_text().split(') ')[1].split()[0] != 'Z'
        if live:
            os.kill(pid, 9)
        self.assertFalse(live, 'Descendant survived unknown anchor outcome')

    def test_same_process_preview_preserves_environment_and_directories(self):
        # Compare inside PowerShell, not only in the Python parent environment.
        command = "$env:RUNNER_BUILD_PREVIEW_EMPTY = ''; Remove-Item Env:RUNNER_BUILD_PREVIEW_ABSENT -ErrorAction SilentlyContinue; $before = @{}; Get-ChildItem Env: | ForEach-Object { $before[$_.Name] = $_.Value }; & $args[0] -SourceRoot $args[1] -ExpectedCommit $args[2] -ConfigurationPath $args[3] -PrivateRoot ([IO.Path]::GetDirectoryName($args[3])) -ConfigurationSha256 $args[5] -ContainerCommand $args[4] -WhatIf; $after = @{}; Get-ChildItem Env: | ForEach-Object { $after[$_.Name] = $_.Value }; if (($before | ConvertTo-Json -Compress) -cne ($after | ConvertTo-Json -Compress)) { exit 3 }"
        # -CommandWithArgs binds literal arguments; no private path is interpolated.
        before = {str(p.relative_to(self.root)) for p in self.root.rglob('*')}
        p = subprocess.run(['pwsh', '-NoProfile', '-CommandWithArgs', command, str(self.repo / ENTRY), str(self.repo), self.head, str(self.config), str(self.native), hashlib.sha256(self.config.read_bytes()).hexdigest()], capture_output=True, text=True)
        self.assertEqual(0, p.returncode, p.stderr)
        self.assertEqual(before, {str(p.relative_to(self.root)) for p in self.root.rglob('*')})
        self.assertFalse(self.marker.exists())


    def test_private_fifo_and_invalid_utf8_denied(self):
        fifo = self.root / 'private-fifo'
        os.mkfifo(fifo)
        self.assertNotEqual(0, self.invoke(config=fifo).returncode)
        self.assertFalse(self.marker.exists())
        self.config.write_bytes(b'{"imageTag":"' + bytes([255]) + b'"}')
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.marker.exists())

    def test_private_empty_and_trailing_json_denied(self):
        valid = self.config.read_text()
        for value in ['', valid + '{}', valid + '//private', valid + ',']:
            with self.subTest(case=value[-8:]):
                self.config.write_text(value)
                self.assertNotEqual(0, self.invoke().returncode)
                self.assertFalse(self.marker.exists())


    def test_profile_hash_missing_and_unknown_denied(self):
        valid=self.config.read_bytes()
        for profile in [{}, {'schemaVersion':1,'unknown':'PRIVATE_OPERATION_SENTINEL_74291'}]:
            self.config.write_text(json.dumps(profile))
            self.assertNotEqual(0,self.invoke().returncode)
            self.assertFalse(self.marker.exists())
        self.config.write_bytes(valid)
        command=['pwsh','-NoProfile','-File',str(self.repo/ENTRY),'-SourceRoot',str(self.repo),'-ExpectedCommit',self.head,'-ConfigurationPath',str(self.config),'-PrivateRoot',str(self.root),'-ConfigurationSha256','0'*64,'-ContainerCommand',str(self.native)]
        p=subprocess.run(command,capture_output=True,text=True)
        self.assertNotEqual(0,p.returncode)
        self.assertNotIn(SENTINEL,p.stdout+p.stderr)
        self.assertFalse(self.marker.exists())
        self.config.unlink()
        p=subprocess.run(command,capture_output=True,text=True)
        self.assertNotEqual(0,p.returncode)
        self.assertNotIn(str(self.root),p.stdout+p.stderr)
        self.assertFalse(self.marker.exists())

if __name__ == '__main__':
    unittest.main(verbosity=2)
