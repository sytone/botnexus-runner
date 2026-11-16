"""Synthetic private maintenance profile reader tests; offline container only."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[4]
SENTINEL = 'PRIVATE_PROFILE_SENTINEL_5162'
COMMIT = 'c' * 40
IMAGE = 'example.azurecr.io/runner@sha256:' + 'a' * 64
TAG = 'example.azurecr.io/runner:src-' + COMMIT
SUB = '11111111-1111-1111-1111-111111111111'


class RunnerProfile(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='profile-', dir='/work'))
        self.repo = self.root / 'source'
        self.repo.mkdir()
        (self.repo / '.git').mkdir()
        self.private = self.root / 'private'
        self.private.mkdir()
        self.path = self.private / 'profile.json'
        self.output = self.private / 'projection.json'
        self.profile = {
            'schemaVersion': 1,
            'account': {'tenantId': '22222222-2222-2222-2222-222222222222', 'subscriptionId': SUB,
                        'accountType': 'user', 'accountName': SENTINEL + '@example.invalid'},
            'target': {'resourceId': '/subscriptions/' + SUB + '/resourceGroups/fixture/providers/Microsoft.App/jobs/runner',
                       'managedIdentityResourceId': '/subscriptions/' + SUB + '/resourceGroups/fixture/providers/Microsoft.ManagedIdentity/userAssignedIdentities/runner',
                       'managedIdentityClientId': '33333333-3333-3333-3333-333333333333'},
            'images': {'buildTag': TAG, 'desiredImage': IMAGE},
            'transport': {'sourceBlobUrl': 'https://storage.example.invalid/source/run.tar.gz',
                          'artifactDestination': 'https://storage.example.invalid/results/run'}}
        self.write()

    def tearDown(self):
        shutil.rmtree(self.root)

    def write(self, profile=None):
        self.path.write_text(json.dumps(self.profile if profile is None else profile))

    def invoke(self, operation='deploy', path=None, expected_hash=None, boundary=None, source=None, commit=COMMIT):
        path = path or self.path
        expected_hash = expected_hash or hashlib.sha256(path.read_bytes()).hexdigest()
        # Private return is captured to an explicit fixture artifact, never public stdout.
        command = ". $args[0]; $env:PROFILE_EMPTY=''; Remove-Item Env:PROFILE_ABSENT -ErrorAction SilentlyContinue; $before=@{}; Get-ChildItem Env: | ForEach-Object { $before[$_.Name]=$_.Value }; try { $p=Read-RunnerMaintenanceProfile -Path $args[1] -ExpectedSha256 $args[2] -Operation $args[3] -SourceRoot $args[4] -PrivateRoot $args[5] -ExpectedCommit $args[6]; [IO.File]::WriteAllText($args[7], ($p | ConvertTo-Json -Depth 20 -Compress)); 'PROFILE_OK' } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 } finally { $after=@{}; Get-ChildItem Env: | ForEach-Object { $after[$_.Name]=$_.Value }; if (($before | ConvertTo-Json -Compress) -cne ($after | ConvertTo-Json -Compress)) { [Console]::Error.WriteLine('Environment changed'); exit 7 } }"
        result = subprocess.run(['pwsh', '-NoProfile', '-CommandWithArgs', command,
                                 str(SOURCE / 'scripts/repo/Import-RunnerMaintenanceProfile.ps1'), str(path), expected_hash,
                                 operation, str(source or self.repo), str(boundary or self.private), commit, str(self.output)],
                                capture_output=True, text=True, timeout=15)
        for private in [SENTINEL, str(self.root), IMAGE, TAG, self.profile['target']['resourceId']]:
            self.assertNotIn(private, result.stdout + result.stderr)
        if result.returncode:
            self.assertEqual('Runner maintenance profile validation failed.', result.stderr.strip())
            self.assertEqual('', result.stdout)
        return result

    def test_valid_four_operation_projections(self):
        common = dict(self.profile['account'], resourceId=self.profile['target']['resourceId'])
        expected = {
            'build': {'imageTag': TAG},
            'publish': {'imageTag': TAG},
            'deploy': dict(common, image=IMAGE, managedIdentityResourceId=self.profile['target']['managedIdentityResourceId']),
            'run': dict(common, managedIdentityClientId=self.profile['target']['managedIdentityClientId'], sourceBlobUrl=self.profile['transport']['sourceBlobUrl'])}
        before = self.path.read_bytes()
        for operation in expected:
            with self.subTest(operation=operation):
                result = self.invoke(operation)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual('PROFILE_OK', result.stdout.strip())
                projection = json.loads(self.output.read_text())
                self.assertEqual(expected[operation], projection['configuration'])
                self.assertEqual(operation, projection['operation'])
                self.assertEqual(hashlib.sha256(before).hexdigest(), projection['profileSha256'])
                if operation == 'run':
                    self.assertEqual(IMAGE, projection['runnerImage'])
                    self.assertEqual(self.profile['transport']['artifactDestination'], projection['artifactDestination'])
                self.assertEqual(before, self.path.read_bytes())

    def test_operation_specific_required_fields_and_no_defaults(self):
        for operation, section, field in [('build','images','buildTag'), ('publish','images','buildTag'),
                                          ('deploy','images','desiredImage'), ('deploy','target','managedIdentityResourceId'),
                                          ('run','target','managedIdentityClientId'), ('run','transport','sourceBlobUrl'),
                                          ('run','transport','artifactDestination'), ('run','images','desiredImage')]:
            with self.subTest(operation=operation, field=field):
                profile = copy.deepcopy(self.profile)
                del profile[section][field]
                self.write(profile)
                self.assertNotEqual(0, self.invoke(operation).returncode)
        minimal = copy.deepcopy(self.profile)
        del minimal['transport']
        minimal['images'] = {'buildTag': TAG}
        minimal['target'] = {'resourceId': minimal['target']['resourceId']}
        self.write(minimal)
        self.assertEqual(0, self.invoke('build').returncode)
        self.assertEqual(0, self.invoke('publish').returncode)
        self.assertNotEqual(0, self.invoke('deploy').returncode)
        self.assertNotEqual(0, self.invoke('run').returncode)

    def test_schema_unknown_missing_type_null_credentials(self):
        cases = []
        for field in ['schemaVersion', 'account', 'target', 'images']:
            value = copy.deepcopy(self.profile); del value[field]; cases.append(value)
        for value in [0, 2, '1', True, None, 1.0]:
            profile = copy.deepcopy(self.profile); profile['schemaVersion'] = value; cases.append(profile)
        for section in ['account', 'target', 'images', 'transport']:
            for value in [None, [], 'bad', 1]:
                profile = copy.deepcopy(self.profile); profile[section] = value; cases.append(profile)
            profile = copy.deepcopy(self.profile); profile[section]['password'] = SENTINEL; cases.append(profile)
            for field in self.profile[section]:
                for value in [None, True, 42, {}, []]:
                    profile = copy.deepcopy(self.profile); profile[section][field] = value; cases.append(profile)
        profile = copy.deepcopy(self.profile); profile['token'] = SENTINEL; cases.append(profile)
        for index, value in enumerate(cases):
            with self.subTest(case=index):
                self.write(value)
                self.assertNotEqual(0, self.invoke().returncode)

    def test_identity_subscription_resource_consistency(self):
        cases = [('account','accountType','unknown'), ('account','accountName',''), ('account','tenantId','bad'),
                 ('account','subscriptionId','44444444-4444-4444-4444-444444444444'),
                 ('target','resourceId','/wrong/' + SENTINEL), ('target','managedIdentityClientId','bad'),
                 ('target','managedIdentityResourceId',self.profile['target']['managedIdentityResourceId'].replace(SUB,'55555555-5555-5555-5555-555555555555'))]
        for section, field, value in cases:
            with self.subTest(field=field):
                profile = copy.deepcopy(self.profile); profile[section][field] = value; self.write(profile)
                self.assertNotEqual(0, self.invoke().returncode)
        profile = copy.deepcopy(self.profile); profile['account']['accountType'] = 'servicePrincipal'; self.write(profile)
        self.assertNotEqual(0, self.invoke().returncode)
        profile['account']['accountName'] = '66666666-6666-6666-6666-666666666666'; self.write(profile)
        self.assertEqual(0, self.invoke().returncode)

    def test_image_and_transport_boundaries(self):
        cases = [('images','buildTag',IMAGE), ('images','buildTag',TAG.replace(COMMIT,'b'*40)),
                 ('images','desiredImage',TAG), ('images','desiredImage','https://bad/image'),
                 ('transport','sourceBlobUrl','http://storage.example.invalid/source'),
                 ('transport','sourceBlobUrl','https://user:password@storage.example.invalid/source'),
                 ('transport','sourceBlobUrl','https://storage.example.invalid/source?sig='+SENTINEL),
                 ('transport','artifactDestination','https://storage.example.invalid/'),
                 ('transport','artifactDestination',self.profile['transport']['sourceBlobUrl'])]
        for section, field, value in cases:
            with self.subTest(field=field, index=cases.index((section,field,value))):
                profile = copy.deepcopy(self.profile); profile[section][field] = value; self.write(profile)
                self.assertNotEqual(0, self.invoke('run').returncode)

    def test_strict_bytes_hash_duplicates_utf8_size(self):
        valid = self.path.read_bytes()
        duplicate = valid.replace(b'"account": {', b'"account": {"accountName":"duplicate",', 1)
        for raw in [b'', b'[]', b'null', b'{bad', valid+b'{}', valid+b' '*4096, b'{"bad":"'+bytes([255])+b'"}', duplicate,
                    valid[:-1]+b',"schemaVersion":1}', valid.replace(b'"schemaVersion": 1',b'"schemaVersion": 1e0')]:
            with self.subTest(size=len(raw), digest=hashlib.sha256(raw).hexdigest()):
                self.path.write_bytes(raw)
                self.assertNotEqual(0, self.invoke().returncode)
        self.path.write_bytes(valid)
        self.assertNotEqual(0, self.invoke(expected_hash='0'*64).returncode)
        self.assertNotEqual(0, self.invoke(expected_hash='bad').returncode)
        self.assertNotEqual(0, self.invoke(operation='unknown').returncode)
        self.assertNotEqual(0, self.invoke(operation='').returncode)
        self.assertNotEqual(0, self.invoke(commit='bad').returncode)

    def test_observed_private_path_boundaries(self):
        missing = self.private / 'missing.json'
        self.assertNotEqual(0, self.invoke(path=missing, expected_hash='a'*64).returncode)
        inside = self.repo / 'profile.json'; inside.write_bytes(self.path.read_bytes())
        self.assertNotEqual(0, self.invoke(path=inside, boundary=self.root).returncode)
        outside = self.root / 'outside.json'; outside.write_bytes(self.path.read_bytes())
        self.assertNotEqual(0, self.invoke(path=outside).returncode)
        other_git = self.root / 'other-git'; other_git.mkdir(); (other_git / '.git').write_text('gitdir: synthetic')
        tracked = other_git / 'profile.json'; tracked.write_bytes(self.path.read_bytes())
        self.assertNotEqual(0, self.invoke(path=tracked, boundary=self.root).returncode)
        alias = self.private / 'link.json'; alias.symlink_to(self.path)
        self.assertNotEqual(0, self.invoke(path=alias).returncode)
        ancestor = self.root / 'linked-private'; ancestor.symlink_to(self.private, target_is_directory=True)
        self.assertNotEqual(0, self.invoke(path=ancestor / self.path.name, boundary=ancestor).returncode)
        fifo = self.private / 'fifo.json'; os.mkfifo(fifo, 0o600)
        self.assertNotEqual(0, self.invoke(path=fifo, expected_hash='a'*64).returncode)
        self.assertNotEqual(0, self.invoke(path=self.private, expected_hash='a'*64).returncode)

    def test_reader_no_generated_configs_or_environment_mutation(self):
        before = set(self.root.rglob('*'))
        self.assertEqual(0, self.invoke('run').returncode)
        self.assertEqual(before | {self.output}, set(self.root.rglob('*')))
        self.assertFalse(any(self.root.glob('**/runner-*.json')))

if __name__ == '__main__':
    unittest.main(verbosity=2)
