"""Inert native provider controls for the generic execution-only launcher."""
import hashlib, json, os, shutil, subprocess, tempfile, unittest
from pathlib import Path
SOURCE = Path(__file__).resolve().parents[4]
ENTRY = Path('scripts/repo/Invoke-RunnerRun.ps1')
SECRET = 'PRIVATE_RUN_SENTINEL_5162'

class RunnerRun(unittest.TestCase):

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='generic-run-', dir='/work'))
        self.repo = self.root / 'source'
        shutil.copytree(SOURCE, self.repo, ignore=shutil.ignore_patterns('.git', '__pycache__'))
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.project = {'schemaVersion': 1, 'protocolVersion': 1, 'requiredCapabilities': ['process-v1'], 'limits': {'budgetSeconds': 20, 'reserveSeconds': 5, 'maxConcurrency': 1, 'maxLogBytes': 65536, 'maxArtifactBytes': 65536, 'maxArtifacts': 8}, 'steps': [{'id': 'one', 'executable': 'pwsh', 'arguments': ['-NoProfile', '-Command', 'exit 0'], 'workingDirectory': '.', 'dependsOn': [], 'artifacts': ['.proof']}]}
        (self.repo / 'project.json').write_text(json.dumps(self.project))
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        self.head = self.git('rev-parse', 'HEAD').strip()
        for name in self.git('ls-files', '-z').split('\x00')[:-1]:
            (self.repo / name).write_bytes(subprocess.check_output(['git', '-C', str(self.repo), 'show', 'HEAD:' + name]))
        tree = self.git('rev-parse', 'HEAD^{tree}')
        self.git('add', '.')
        self.assertEqual(tree, self.git('write-tree'))
        self.image = 'registry.example/runner@sha256:' + '1' * 64
        self.artifact = 'https://storage.example/results/run'
        self.resource = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/fixture/providers/Microsoft.App/jobs/runner'
        self.config = self.root / (SECRET + '.json')
        self.configuration = {'resourceId': self.resource, 'tenantId': '22222222-2222-2222-2222-222222222222', 'accountType': 'servicePrincipal', 'accountName': '33333333-3333-3333-3333-333333333333', 'subscriptionId': '11111111-1111-1111-1111-111111111111', 'managedIdentityClientId': '44444444-4444-4444-4444-444444444444', 'sourceBlobUrl': 'https://storage.example/sources/run.tar.gz'}
        self.write_configuration()
        self.release = self.root / 'release.json'
        self.approval = {'schemaVersion': 1, 'releaseId': 'synthetic-only', 'image': self.image, 'approved': True, 'revoked': False, 'runnerInputDigest': '0'*64, 'modes': ['project'], 'payloadVersion': 1, 'evidenceVersion': 1, 'capabilities': ['exact-source-v1', 'project-execution-v1']}
        digest = subprocess.check_output(['pwsh','-NoProfile','-Command', "Import-Module '" + str(self.repo / 'scripts/repo/RunnerReleaseCompatibility.psm1') + "' -WarningAction SilentlyContinue; & (Get-Module RunnerReleaseCompatibility) { param($r) Get-RunnerReleaseInputDigest -Root $r } '" + str(self.repo) + "'"], text=True).strip()
        self.approval['runnerInputDigest'] = digest
        self.release.write_text(json.dumps(self.approval))
        self.state = self.root / 'state.json'
        self.marker = self.root / 'calls'
        self.body = self.root / 'request.json'
        self.native = self.root / 'provider'
        self.native.write_text('#!/usr/bin/python3\nimport sys,json,os,pathlib\na=sys.argv[1:];m=pathlib.Path(' + repr(str(self.marker)) + ');m.open("a").write(json.dumps(a)+"\\n")\nprint(' + repr(SECRET) + ',file=sys.stderr)\nif a[:2]==["account","show"]: print(json.dumps({"id":"11111111-1111-1111-1111-111111111111","tenantId":"22222222-2222-2222-2222-222222222222","user":{"type":"servicePrincipal","name":"33333333-3333-3333-3333-333333333333"}}))\nelif "get" in a: print(json.dumps({"id":' + repr(self.resource) + ',"identity":{"userAssignedIdentities":{"fixture":{"clientId":"44444444-4444-4444-4444-444444444444"}}},"properties":{"configuration":{"triggerType":"Manual","replicaTimeout":1200,"replicaRetryLimit":0,"manualTriggerConfig":{"parallelism":1,"replicaCompletionCount":1}},"template":{"containers":[{"name":"runner","image":' + repr(self.image) + ',"resources":{"cpu":8,"memory":"24Gi"}}]}}}))\nelif "post" in a:\n p=pathlib.Path(a[a.index("--body")+1][1:]);pathlib.Path(' + repr(str(self.body)) + ').write_bytes(p.read_bytes())\n if os.getenv("FIXTURE_TIMEOUT"): import time;time.sleep(20)\n if os.getenv("FIXTURE_FAIL"): sys.exit(9)\n print(json.dumps({"id":' + repr(self.resource + '/executions/fixture-execution') + ',"name":"fixture-execution"}))\nelse: print("{}")\n')
        self.native.chmod(448)

    def git(self, *a):
        return subprocess.check_output(['git', '-C', str(self.repo), *a], text=True, stderr=subprocess.DEVNULL)

    def tearDown(self):
        retained = Path('/work/retained-cases') / self.id().split('.')[-1]
        retained.mkdir(parents=True, exist_ok=True)
        for name in ('state.json', 'calls', 'request.json', 'runtime-native.json'):
            if (self.root / name).is_file():
                shutil.copyfile(self.root / name, retained / name)
        for name in ('failed-artifacts', 'good-artifacts', 'journal-home', 'failed-home', 'good-home'):
            if (self.root / name).exists():
                shutil.copytree(self.root / name, retained / name, dirs_exist_ok=True)
        shutil.rmtree(self.root)

    def write_configuration(self, value=None):
        value = self.configuration if value is None else value
        account_keys = ['accountName','accountType','tenantId','subscriptionId']
        target_keys = ['resourceId','managedIdentityResourceId','managedIdentityClientId']
        profile = {'schemaVersion':1, 'account':{k:value[k] for k in account_keys if k in value},
                   'target':{k:value[k] for k in target_keys if k in value},
                   'images':{'desiredImage':value.get('image', getattr(self,'image', 'registry.example/runner@sha256:'+'1'*64))}}
        if 'sourceBlobUrl' in value:
            profile['transport']={'sourceBlobUrl':value['sourceBlobUrl'],'artifactDestination':self.artifact}
        known=set(account_keys+target_keys+['image','sourceBlobUrl'])
        for k in value:
            if k not in known: profile[k]=value[k]
        self.config.write_text(json.dumps(profile))

    def invoke(self, *extra, image=None, hash_value=None, env=None, profile_hash=None, artifact=None):
        e = os.environ.copy()
        e['XDG_DATA_HOME'] = str(self.root / getattr(self, 'journal_home', 'journal-home'))
        e.update(env or {})
        p = subprocess.run(['pwsh', '-NoProfile', '-File', str(self.repo / ENTRY), '-SourceRoot', str(self.repo), '-ExpectedCommit', self.head, '-ProjectConfigPath', 'project.json', '-ProjectConfigSha256', hash_value or hashlib.sha256((self.repo / 'project.json').read_bytes()).hexdigest(), '-RunnerImage', image or self.image, '-ArtifactDestination', artifact or self.artifact, '-ConfigurationPath', str(self.config), '-PrivateRoot', str(self.root), '-ConfigurationSha256', profile_hash or hashlib.sha256(self.config.read_bytes()).hexdigest(), '-StatePath', str(self.state), '-ReleaseManifestPath', str(self.release), '-ProviderCommand', str(self.native), *extra], capture_output=True, text=True, env=e)
        self.assertNotIn(SECRET, p.stdout + p.stderr)
        self.assertNotIn(str(self.root), p.stdout + p.stderr)
        self.assertNotIn(self.resource, p.stdout + p.stderr)
        return p

    def test_preview_no_files_environment_index_or_provider(self):
        before = {str(p.relative_to(self.root)): p.read_bytes() if p.is_file() else None for p in self.root.rglob('*')}
        parent_environment = dict(os.environ)
        p = self.invoke('-WhatIf')
        self.assertEqual(0, p.returncode, p.stderr)
        self.assertEqual(before, {str(p.relative_to(self.root)): p.read_bytes() if p.is_file() else None for p in self.root.rglob('*')})
        self.assertEqual(parent_environment, dict(os.environ))
        self.assertFalse(self.marker.exists())

    def test_unresolved_deployment_blocks_run_before_provider(self):
        key=hashlib.sha256(self.resource.lower().encode()).hexdigest()
        journal=self.root/'journal-home/BotNexus/runner-operations'
        journal.mkdir(parents=True,mode=0o700)
        record=journal/(key+'.deployment.json')
        record.write_text(json.dumps({'status':'attempted-unknown'}));record.chmod(0o600)
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertTrue(all(json.loads(line)[:2]==['account','show'] for line in self.marker.read_text().splitlines()))
        self.assertFalse(self.state.exists())
        self.assertFalse(any(journal.glob('*.reservation')))

    def test_execution_only_once_image_owned_entrypoint(self):
        p = self.invoke()
        self.assertEqual(0, p.returncode, p.stderr)
        r = json.loads(p.stdout)
        self.assertEqual('submitted-unverified', r['status'])
        self.assertIsNone(r['tests'])
        self.assertFalse(r['accepted'])
        b = json.loads(self.body.read_text())
        c = b['containers'][0]
        self.assertNotIn('command', c)
        self.assertNotIn('args', c)
        env = {e['name']: e['value'] for e in c['env']}
        self.assertEqual('1200', env['REPLICA_TIMEOUT_SECONDS'])
        self.assertEqual(self.image, env['RUNNER_IMAGE'])
        self.assertEqual('project.json', env['PROJECT_CONFIG_PATH'])
        self.assertEqual(self.configuration['managedIdentityClientId'], env['AZURE_CLIENT_ID'])
        self.assertNotEqual(0, self.invoke().returncode)
        calls = [json.loads(x) for x in self.marker.read_text().splitlines()]
        self.assertEqual(1, sum(('post' in x for x in calls)))
        self.assertFalse(any(('patch' in x for x in calls)))

    def test_native_failure_retains_fence_and_no_retry(self):
        self.assertNotEqual(0, self.invoke(env={'FIXTURE_FAIL': '1'}).returncode)
        self.assertTrue(self.state.exists())
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertEqual(1, sum(('post' in json.loads(x) for x in self.marker.read_text().splitlines())))

    def test_timeout_unknown_retains_fence(self):
        import time
        start = time.monotonic()
        self.assertNotEqual(0, self.invoke('-TimeoutSeconds', '12', env={'FIXTURE_TIMEOUT': '1'}).returncode)
        self.assertTrue(self.state.exists())
        self.assertLess(time.monotonic() - start, 15)
        self.assertTrue(self.body.exists())
        self.assertFalse(list(self.root.glob('runner-run-*')))

    def test_wrong_config_hash(self):
        self.assertNotEqual(0, self.invoke(hash_value='0' * 64).returncode)
        self.assertFalse(self.marker.exists())

    def test_dirty_source(self):
        (self.repo / 'README.md').write_text('dirty')
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.marker.exists())

    def test_raw_byte_drift(self):
        p = self.repo / 'infra/buildtest/runner/Invoke-Runner.ps1'
        p.write_bytes(p.read_bytes().replace(b'\n', b'\r\n'))
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.marker.exists())

    def test_mutable_image_denied(self):
        self.assertNotEqual(0, self.invoke(image='registry.example/runner:latest').returncode)
        self.assertFalse(self.marker.exists())

    def test_private_json_duplicate_denied(self):
        self.config.write_text('{"resourceId":"' + SECRET + '","resourceId":"x"}')
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.marker.exists())

    def test_linked_project_denied(self):
        p = self.repo / 'project.json'
        p.unlink()
        p.symlink_to(self.config)
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.marker.exists())

    def test_missing_project_denied(self):
        (self.repo / 'project.json').unlink()
        self.assertNotEqual(0, self.invoke(hash_value='0' * 64).returncode)
        self.assertFalse(self.marker.exists())

    def test_unknown_private_fields_denied(self):
        c = dict(self.configuration, secret=SECRET)
        self.write_configuration(c)
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.marker.exists())

    def test_wrong_provider_identity_denied(self):
        self.native.write_text(self.native.read_text().replace('"type":"servicePrincipal"', '"type":"user"'))
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.state.exists())

    def test_wrong_existing_image_denied(self):
        self.native.write_text(self.native.read_text().replace(self.image, self.image.replace('1' * 64, '2' * 64)))
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.state.exists())

    def test_project_schema_denied(self):
        (self.repo / 'project.json').write_text('{}')
        self.git('add', 'project.json')
        self.git('commit', '-qm', 'bad schema')
        self.head = self.git('rev-parse', 'HEAD').strip()
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.marker.exists())

    def test_real_image_entrypoint_success_and_partial_failure(self):
        original_native = self.native.read_text()
        for fail in (False, True):
            with self.subTest(fail=fail):
                if self.state.exists():
                    self.state.unlink()
                self.journal_home = 'failed-home' if fail else 'good-home'
                self.artifact = 'https://storage.example/results/' + ('failed' if fail else 'good')
                self.write_configuration()
                run = self.root / ('failed-run' if fail else 'good-run')
                saved = self.root / ('failed-artifacts' if fail else 'good-artifacts')
                saved.mkdir()
                self.project['steps'][0]['arguments'] = ['-NoProfile', '-Command', "if ($env:AZURE_CLIENT_ID -or $env:SOURCE_BLOB_URL -or $env:ARTIFACT_BLOB_URL) { throw 'Framework credentials inherited' };[IO.File]::WriteAllText('partial.txt','retained');" + ('exit 9' if fail else 'exit 0')]
                self.project['steps'][0]['artifacts'] = ['partial.txt']
                (self.repo / 'project.json').write_text(json.dumps(self.project))
                self.git('add', '.')
                self.git('commit', '-qm', 'graph')
                self.head = self.git('rev-parse', 'HEAD').strip()
                image = self.root / 'image'
                shutil.copytree(self.repo / 'infra/buildtest/runner', image, dirs_exist_ok=True)
                tool = self.root / 'azcopy'
                tool.write_text('#!/usr/bin/python3\nimport sys,shutil,pathlib\na=sys.argv[1:]\nif a[1].startswith("https:"): shutil.copyfile(' + repr(str(self.root / 'uploaded.tar.gz')) + ',a[2])\nelse:\n for p in pathlib.Path(a[1].removesuffix("/*")).iterdir():\n  d=pathlib.Path(' + repr(str(saved)) + ')/p.name\n  shutil.copytree(p,d,dirs_exist_ok=True) if p.is_dir() else shutil.copyfile(p,d)\n')
                tool.chmod(448)
                native = original_native
                native = native.replace('else: print("{}")', 'elif a[:3]==["storage","blob","upload"]:\n import shutil;shutil.copyfile(a[a.index("--file")+1],' + repr(str(self.root / 'uploaded.tar.gz')) + ');print("{}")\nelse: print("{}")')
                native = native.replace(' if os.getenv("FIXTURE_TIMEOUT"):', ' if os.getenv("REAL_ENTRY"):\n  import subprocess\n  b=json.loads(p.read_text());e=os.environ.copy();e.update({x["name"]:x["value"] for x in b["containers"][0]["env"]});e["PATH"]=' + repr(str(self.root)) + ':os.pathsep+e["PATH"]\n  q=subprocess.run(["pwsh","-NoProfile","-File",' + repr(str(image / 'Invoke-Runner.ps1')) + ',"-WorkRoot",' + repr(str(run)) + ',"-BudgetSeconds","30","-ReserveSeconds","8"],env=e,capture_output=True)\n  pathlib.Path(' + repr(str(self.root / 'runtime-native.json')) + ').write_text(json.dumps({"exit":q.returncode,"stdout":q.stdout.decode(),"stderr":q.stderr.decode()}))\n if os.getenv("FIXTURE_TIMEOUT"):')
                native = native.replace(repr(str(self.root)) + ':os.pathsep', repr(str(self.root)) + '+os.pathsep')
                self.native.write_text(native)
                p = self.invoke(env={'REAL_ENTRY': '1'})
                self.assertEqual(0, p.returncode, p.stderr)
                runtime = json.loads((self.root / 'runtime-native.json').read_text())
                result = json.loads((saved / 'result.json').read_text())
                self.assertEqual(1 if fail else 0, runtime['exit'], runtime)
                self.assertIsNone(result['tests'])
                self.assertFalse(result['accepted'])
                self.assertTrue(result['sourceSnapshot']['verified'])
                self.assertEqual(hashlib.sha256((self.repo / 'project.json').read_bytes()).hexdigest(), result['projectConfiguration']['sha256'])
                self.assertTrue((saved / 'project/partial.txt').is_file())
                self.assertTrue(result['projectExecution']['cleanupComplete'])
                self.prepare_reconciliation('Failed' if fail else 'Succeeded')
                shutil.copytree(saved,self.downloads,dirs_exist_ok=True)
                reconciled=self.invoke('-Reconcile')
                self.assertEqual(0,reconciled.returncode,reconciled.stderr)
                self.assertTrue(json.loads(reconciled.stdout)['evidenceVerified'])

    def test_release_revoked_before_provider(self):
        self.approval['revoked'] = True
        self.release.write_text(json.dumps(self.approval))
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.marker.exists())

    def test_release_wrong_runtime(self):
        self.approval['runnerInputDigest'] = '0'*64
        self.release.write_text(json.dumps(self.approval))
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(self.marker.exists())

    def test_alternate_state_unknown_cannot_replay(self):
        self.assertNotEqual(0, self.invoke(env={'FIXTURE_FAIL':'1'}).returncode)
        self.state = self.root / 'alternate.json'
        self.assertNotEqual(0, self.invoke().returncode)
        calls = [json.loads(x) for x in self.marker.read_text().splitlines()]
        self.assertEqual(1, sum('post' in x for x in calls))
        self.assertEqual(1, sum('upload' in x for x in calls))

    def test_execution_identity_private_and_reconcile_readonly(self):
        self.assertEqual(0, self.invoke().returncode)
        state = json.loads(self.state.read_text())
        self.assertEqual(self.resource + '/executions/fixture-execution', state['executionId'])
        before = self.marker.read_text().splitlines()
        self.native.write_text(self.native.read_text().replace('elif "get" in a:', 'elif "get" in a and "/executions/" in a[a.index("--url")+1]: print(json.dumps({"id":' + repr(self.resource + '/executions/fixture-execution') + ',"name":"fixture-execution","properties":{"status":"Succeeded","template":{"containers":[{"name":"runner","image":' + repr(self.image) + '}]}}}))\nelif "get" in a:'))
        self.prepare_reconciliation()
        p = self.invoke('-Reconcile')
        self.assertEqual(0, p.returncode, p.stderr)
        result = json.loads(p.stdout)
        self.assertEqual('execution-observed-unverified', result['status'])
        self.assertIsNone(result['tests'])
        self.assertFalse(result['accepted'])
        calls = [json.loads(x) for x in self.marker.read_text().splitlines()[len(before):]]
        self.assertTrue(calls)
        self.assertFalse(any('post' in x or 'upload' in x for x in calls))

    def test_revoke_after_upload_blocks_start(self):
        self.native.write_text(self.native.read_text().replace('else: print("{}")', 'elif a[:3]==["storage","blob","upload"]:\n p=pathlib.Path(' + repr(str(self.release)) + ');d=json.loads(p.read_text());d["revoked"]=True;p.write_text(json.dumps(d));print("{}")\nelse: print("{}")'))
        self.assertNotEqual(0, self.invoke().returncode)
        calls = [json.loads(x) for x in self.marker.read_text().splitlines()]
        self.assertEqual(1, sum('upload' in x for x in calls))
        self.assertFalse(any('post' in x for x in calls))


    def test_release_unapproved_wrong_image_or_missing_capability(self):
        for field, value in [('approved', False), ('image', self.image.replace('1'*64, '2'*64)), ('capabilities', ['exact-source-v1'])]:
            with self.subTest(field=field):
                document = dict(self.approval)
                document[field] = value
                self.release.write_text(json.dumps(document))
                self.assertNotEqual(0, self.invoke().returncode)
                self.assertFalse(self.marker.exists())

    def test_revoke_after_readonly_preflight_blocks_upload(self):
        self.native.write_text(self.native.read_text().replace('elif "get" in a: print(', 'elif "get" in a:\n p=pathlib.Path(' + repr(str(self.release)) + ');d=json.loads(p.read_text());d["revoked"]=True;p.write_text(json.dumps(d))\n print('))
        self.assertNotEqual(0, self.invoke().returncode)
        calls = [json.loads(x) for x in self.marker.read_text().splitlines()]
        self.assertFalse(any('post' in x or 'upload' in x for x in calls))

    def test_source_changes_after_upload_blocks_start(self):
        self.native.write_text(self.native.read_text().replace('else: print("{}")', 'elif a[:3]==["storage","blob","upload"]:\n pathlib.Path(' + repr(str(self.repo / 'README.md')) + ').write_text("changed during upload");print("{}")\nelse: print("{}")'))
        self.assertNotEqual(0, self.invoke().returncode)
        calls = [json.loads(x) for x in self.marker.read_text().splitlines()]
        self.assertEqual(1, sum('upload' in x for x in calls))
        self.assertFalse(any('post' in x for x in calls))

    def test_missing_execution_identity_keeps_unknown_and_reconcile_readonly(self):
        self.native.write_text(self.native.read_text().replace(' print(json.dumps({"id":' + repr(self.resource + '/executions/fixture-execution') + ',"name":"fixture-execution"}))', ' print("{}")'))
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertTrue(self.state.exists())
        before = self.marker.read_text().splitlines()
        self.assertNotEqual(0, self.invoke('-Reconcile').returncode)
        calls = [json.loads(x) for x in self.marker.read_text().splitlines()[len(before):]]
        self.assertFalse(any('post' in x or 'upload' in x for x in calls))
        self.state = self.root / 'new-state.json'
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertEqual(1, sum('post' in json.loads(x) for x in self.marker.read_text().splitlines()))

    def test_changed_transport_does_not_bypass_target_journal(self):
        self.assertNotEqual(0, self.invoke(env={'FIXTURE_FAIL':'1'}).returncode)
        self.state = self.root / 'other-state.json'
        self.artifact = 'https://storage.example/other/result'
        self.configuration['sourceBlobUrl'] = 'https://storage.example/other/source'
        self.write_configuration()
        self.assertNotEqual(0, self.invoke().returncode)
        calls = [json.loads(x) for x in self.marker.read_text().splitlines()]
        self.assertEqual(1, sum('upload' in x for x in calls))
        self.assertEqual(1, sum('post' in x for x in calls))


    def prepare_reconciliation(self, status='Succeeded', defect=None):
        state = json.loads(self.state.read_text())
        payload = b'partial evidence'
        self.downloads = self.root / 'downloads'
        self.downloads.mkdir(exist_ok=True)
        failed = status != 'Succeeded'
        proof = {'runId':state['runId'], 'exitCode':1 if failed else 0, 'tests':None, 'accepted':False,
                 'sourceSnapshot':{'verified':True,'commit':self.head,'digest':state['sourceDigest'],'runId':state['runId']},
                 'pipelineExecution':{'cleanupComplete':True,'status':'failed' if failed else 'succeeded'},'runnerProtocol':1,'runnerImage':self.image,
                 'projectConfiguration':{'version':1,'path':'project.json','sha256':state['projectConfigSha256']},
                 'projectExecution':{'protocolVersion':1,'configSha256':state['projectConfigSha256'],'status':'failed' if failed else 'succeeded','cleanupComplete':True,'accepted':False,'steps':[{'id':'one','status':'failed' if failed else 'succeeded','exitCode':1 if failed else 0}], 'artifacts':[{'path':'.proof','bytes':len(payload),'sha256':hashlib.sha256(payload).hexdigest()}]}}
        execution = {'id':state['executionId'],'properties':{'status':status,'template':{'containers':[{'name':'runner','image':self.image,'env':[{'name':'RUN_ID','value':state['runId']},{'name':'PROJECT_CONFIG_SHA256','value':state['projectConfigSha256']},{'name':'PROJECT_CONFIG_PATH','value':'project.json'},{'name':'ARTIFACT_BLOB_URL','value':self.artifact},{'name':'SOURCE_BLOB_URL','value':self.configuration['sourceBlobUrl']}]}]}}}
        if defect == 'outer-cleanup': proof['pipelineExecution']['cleanupComplete']=False
        if defect == 'steps': proof['projectExecution']['steps'][0]['id']='different'
        if defect == 'environment': execution['properties']['template']['containers'][0]['env'][0]['value']='wrong'
        if defect == 'accepted': proof['accepted']=True
        if defect == 'tests': proof['tests']={'passed':1}
        if defect == 'protocol': proof['runnerProtocol']=99
        if defect == 'empty-artifacts': proof['projectExecution']['artifacts']=[]
        if defect == 'artifact-path': proof['projectExecution']['artifacts'][0]['path']='../escape'
        if defect == 'oversize': proof['projectExecution']['artifacts'][0]['bytes']=65537
        if defect == 'wrong-status': proof['exitCode']=1
        if defect == 'execution': execution['id'] += '-wrong'
        if defect == 'run': proof['runId']='wrong'
        if defect == 'source': proof['sourceSnapshot']['digest']='0'*64
        if defect == 'config': proof['projectConfiguration']['sha256']='0'*64
        if defect == 'image': proof['runnerImage']=self.image.replace('1'*64,'2'*64)
        if defect == 'partial': proof['projectExecution']['cleanupComplete']=False
        if defect == 'status': execution['properties']['status']={}
        (self.downloads/'result.json').write_text(json.dumps(proof) if defect != 'malformed' else '{')
        if defect == 'duplicate-json': (self.downloads/'result.json').write_text((self.downloads/'result.json').read_text().replace('{','{"runId":"forged",',1))
        (self.downloads/'project').mkdir(exist_ok=True)
        (self.downloads/'project/.proof').write_bytes(payload if defect != 'hash' else b'wrong')
        if defect == 'truncated': (self.downloads/'project/.proof').write_bytes(payload[:-1])
        if defect == 'missing': (self.downloads/'result.json').unlink()
        if defect == 'missing-artifact': (self.downloads/'project/.proof').unlink()
        native=self.native.read_text()
        prefix='elif "get" in a and "/executions/" in a[a.index("--url")+1]:'
        if prefix in native:
            start=native.index(prefix);end=native.index('elif "get" in a:',start)
            native=native[:start]+native[end:]
        native=native.replace('elif "get" in a:', 'elif "get" in a and "/executions/" in a[a.index("--url")+1]: print('+repr(json.dumps(execution))+')\nelif "get" in a:')
        if 'elif a[:3]==["storage","blob","download"]:' in native:
            start=native.index('elif a[:3]==["storage","blob","download"]:');end=native.index('else: print("{}")',start);native=native[:start]+native[end:]
        native=native.replace('else: print("{}")','elif a[:3]==["storage","blob","download"]:\n import shutil,urllib.parse\n if os.getenv("DOWNLOAD_TIMEOUT"): import time;time.sleep(20)\n relative=urllib.parse.unquote(a[a.index("--blob-url")+1].split('+repr(self.artifact+'/')+')[1]);shutil.copyfile(pathlib.Path('+repr(str(self.downloads))+')/relative,a[a.index("--file")+1]);print("{}")\nelse: print("{}")')
        self.native.write_text(native)

    def assert_terminal_reconciliation(self, status):
        self.assertEqual(0,self.invoke().returncode)
        self.prepare_reconciliation(status)
        p=self.invoke('-Reconcile')
        self.assertEqual(0,p.returncode,p.stderr)
        result=json.loads(p.stdout)
        self.assertEqual(status,result['terminalStatus'])
        self.assertTrue(result['evidenceVerified'])
        self.assertFalse(result['accepted'])
        self.assertIsNone(result['tests'])
        calls=[json.loads(x) for x in self.marker.read_text().splitlines()]
        self.assertEqual(1,sum('post' in x for x in calls))
        self.assertEqual(1,sum('upload' in x for x in calls))
        record = json.loads(self.state.read_text())
        self.assertEqual('completed-reconciled', record['status'])
        self.assertEqual(b'partial evidence', (Path(record['evidencePath']) / 'project/.proof').read_bytes())

    def test_reconciliation_retains_named_evidence_without_acceptance(self):
        self.assertEqual(0, self.invoke().returncode)
        self.prepare_reconciliation()
        p = self.invoke('-Reconcile')
        self.assertEqual(0, p.returncode, p.stderr)
        record = json.loads(self.state.read_text())
        retained = self.root / (record['runId'] + '.evidence')
        self.assertTrue(retained.is_dir(), 'Verified evidence must survive caller cleanup')
        self.assertEqual((self.downloads / 'result.json').read_bytes(), (retained / 'result.json').read_bytes())
        self.assertEqual(b'partial evidence', (retained / 'project/.proof').read_bytes())
        self.assertEqual(str(retained), record['evidencePath'])
        self.assertTrue(json.loads(p.stdout)['evidenceRetained'])
        self.assertFalse(json.loads(p.stdout)['accepted'])
        before = {str(f.relative_to(retained)): f.read_bytes() for f in retained.rglob('*') if f.is_file()}
        self.assertEqual(0, self.invoke('-Reconcile').returncode)
        self.assertEqual(before, {str(f.relative_to(retained)): f.read_bytes() for f in retained.rglob('*') if f.is_file()})

    def test_reconciliation_does_not_replace_conflicting_retained_evidence(self):
        self.assertEqual(0, self.invoke().returncode)
        self.prepare_reconciliation()
        record = json.loads(self.state.read_text())
        retained = self.root / (record['runId'] + '.evidence')
        retained.mkdir()
        (retained / 'result.json').write_bytes(b'original recovery evidence')
        self.assertNotEqual(0, self.invoke('-Reconcile').returncode)
        self.assertEqual(b'original recovery evidence', (retained / 'result.json').read_bytes())
        self.assertNotEqual('completed-reconciled', json.loads(self.state.read_text())['status'])
        self.assertFalse(list(self.root.glob('runner-run-*')))

    def test_reconciliation_rejects_retained_links_tampering_and_extra_files(self):
        self.assertEqual(0, self.invoke().returncode)
        self.prepare_reconciliation()
        self.assertEqual(0, self.invoke('-Reconcile').returncode)
        record = json.loads(self.state.read_text())
        retained = Path(record['evidencePath'])
        proof = retained / 'project/.proof'
        original = proof.read_bytes()
        proof.write_bytes(b'changed')
        self.assertNotEqual(0, self.invoke('-Reconcile').returncode)
        self.assertEqual(b'changed', proof.read_bytes())
        proof.write_bytes(original)
        extra = retained / '.unexpected'
        extra.write_bytes(b'preserve')
        self.assertNotEqual(0, self.invoke('-Reconcile').returncode)
        self.assertEqual(b'preserve', extra.read_bytes())
        extra.unlink()
        proof.unlink()
        proof.symlink_to(self.downloads / 'project/.proof')
        self.assertNotEqual(0, self.invoke('-Reconcile').returncode)
        self.assertTrue(proof.is_symlink())
        proof.unlink()
        proof.write_bytes(original)
        renamed = retained.with_suffix('.original')
        retained.rename(renamed)
        retained.symlink_to(renamed, target_is_directory=True)
        self.assertNotEqual(0, self.invoke('-Reconcile').returncode)
        self.assertTrue(retained.is_symlink())
        self.assertEqual(original, (renamed / 'project/.proof').read_bytes())
        self.assertFalse(list(self.root.glob('runner-run-*')))

    def test_terminal_reconciliation_statuses(self):
        self.assert_terminal_reconciliation('Succeeded')

    def test_terminal_failed_reconciliation(self):
        self.assert_terminal_reconciliation('Failed')

    def test_terminal_cancelled_reconciliation(self):
        self.assert_terminal_reconciliation('Cancelled')

    def test_reconciliation_rejects_nonterminal_or_malformed_status(self):
        self.assertEqual(0,self.invoke().returncode)
        for status,defect in [('Pending',None),('Unknown',None),('Succeeded','status')]:
            with self.subTest(status=status,defect=defect):
                self.prepare_reconciliation(status,defect)
                self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
                self.assertNotEqual('completed-reconciled',json.loads(self.state.read_text())['status'])

    def test_reconciliation_exact_evidence_negative_controls(self):
        self.assertEqual(0,self.invoke().returncode)
        for defect in ('execution','run','source','config','image','missing','missing-artifact','truncated','partial','malformed','hash','environment','accepted','tests','protocol','empty-artifacts','artifact-path','oversize','wrong-status','duplicate-json','outer-cleanup','steps'):
            with self.subTest(defect=defect):
                self.prepare_reconciliation(defect=defect)
                self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
                self.assertNotEqual('completed-reconciled',json.loads(self.state.read_text())['status'])

    def test_reconciliation_preview_and_timeout(self):
        self.assertEqual(0,self.invoke().returncode)
        self.prepare_reconciliation()
        before={str(p.relative_to(self.root)):p.read_bytes() if p.is_file() else None for p in self.root.rglob('*')}
        self.assertEqual(0,self.invoke('-Reconcile','-WhatIf').returncode)
        self.assertEqual(before,{str(p.relative_to(self.root)):p.read_bytes() if p.is_file() else None for p in self.root.rglob('*')})
        self.assertNotEqual(0,self.invoke('-Reconcile','-TimeoutSeconds','8',env={'DOWNLOAD_TIMEOUT':'1'}).returncode)
        self.assertNotEqual('completed-reconciled',json.loads(self.state.read_text())['status'])
        self.assertFalse(list(self.root.glob('runner-run-*')))

    def test_completed_operation_allows_only_explicit_different_transport(self):
        self.assertEqual(0,self.invoke().returncode)
        self.prepare_reconciliation()
        self.assertEqual(0,self.invoke('-Reconcile').returncode)
        self.assertEqual(0,self.invoke('-Reconcile').returncode)
        original=self.state.read_bytes()
        self.state=self.root/'next.json'
        self.assertNotEqual(0,self.invoke().returncode)
        self.artifact='https://storage.example/results/next'
        self.configuration['sourceBlobUrl']='https://storage.example/sources/next.tar.gz'
        self.write_configuration()
        self.assertEqual(0,self.invoke().returncode)
        self.assertEqual(original,(self.root/'state.json').read_bytes())
        self.assertTrue(list((self.root/'journal-home').rglob('*.completed.json')))
        self.prepare_reconciliation()
        self.assertEqual(0,self.invoke('-Reconcile').returncode)
        self.state=self.root/'replay.json'
        self.artifact='https://storage.example/results/run'
        self.configuration['sourceBlobUrl']='https://storage.example/sources/run.tar.gz'
        self.write_configuration()
        self.assertNotEqual(0,self.invoke().returncode)

    def test_torn_or_conflicting_journal_remains_fenced(self):
        self.assertEqual(0,self.invoke().returncode)
        state=json.loads(self.state.read_text());state['sourceDigest']='0'*64;self.state.write_text(json.dumps(state))
        self.prepare_reconciliation()
        self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
        self.state=self.root/'alternate.json'
        self.assertNotEqual(0,self.invoke().returncode)


    def test_explicit_configured_user_positive(self):
        self.configuration.update(accountType='user',accountName='operator@example.invalid')
        self.write_configuration()
        self.native.write_text(self.native.read_text().replace('"type":"servicePrincipal","name":"33333333-3333-3333-3333-333333333333"','"type":"user","name":"operator@example.invalid"'))
        self.assertEqual(0,self.invoke().returncode)
        calls=[json.loads(x) for x in self.marker.read_text().splitlines()]
        self.assertEqual(1,sum('post' in r for r in calls))
        self.assertTrue(all('--subscription' in r and r[r.index('--subscription')+1]==self.configuration['subscriptionId'] for r in calls if r[0]!='account'))

    def test_account_binding_mismatches_before_job_read(self):
        original=self.native.read_text()
        for old,new in [('servicePrincipal','user'),('33333333-3333-3333-3333-333333333333','wrong@example.invalid'),('22222222-2222-2222-2222-222222222222','55555555-5555-5555-5555-555555555555'),('11111111-1111-1111-1111-111111111111','66666666-6666-6666-6666-666666666666')]:
            with self.subTest(field=old):
                self.native.write_text(original.replace(old,new))
                self.assertNotEqual(0,self.invoke().returncode)
                calls=[json.loads(x) for x in self.marker.read_text().splitlines()]
                self.assertTrue(all(r[:2]==['account','show'] for r in calls))
                self.assertFalse(self.state.exists())
                self.assertFalse((self.root/'journal-home').exists())

    def test_account_configuration_missing_duplicate_unknown_denied(self):
        valid=dict(self.configuration)
        for field in ['accountType','accountName','tenantId','subscriptionId']:
            broken=dict(valid);del broken[field]
            self.write_configuration(broken)
            self.assertNotEqual(0,self.invoke().returncode)
            self.assertFalse(self.marker.exists())
        for field,value in [('accountType','unknown'),('accountName',''),('subscriptionId','invalid'),('subscriptionId','77777777-7777-7777-7777-777777777777'),('accountName',None),('accountType',True),('unknown','PRIVATE_RUN_SENTINEL_5162')]:
            self.write_configuration(dict(valid,**{field:value}))
            self.assertNotEqual(0,self.invoke().returncode)
            self.assertFalse(self.marker.exists())
        text=self.config.read_text()
        self.config.write_text(text[:-1]+',"schemaVersion":1}')
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertFalse(self.marker.exists())


    def test_account_response_missing_duplicate_unknown_type_denied(self):
        original=self.native.read_text()
        account={'id':self.configuration['subscriptionId'],'tenantId':self.configuration['tenantId'],'user':{'type':'servicePrincipal','name':self.configuration['accountName']}}
        valid=json.dumps(account)
        responses=[valid[:-1]+',"ID":"'+account['id']+'"}',valid.replace('"type": "servicePrincipal"','"type": "servicePrincipal", "TYPE": "servicePrincipal"')]
        for field in ('id','tenantId','user'):
            broken=dict(account);del broken[field];responses.append(json.dumps(broken))
        for field,value in [('type','unknown'),('name',None),('type',[]),('name',{})]:
            broken=dict(account,user=dict(account['user'],**{field:value}));responses.append(json.dumps(broken))
        for response in responses:
            with self.subTest(response=response):
                start=original.index('if a[:2]==["account","show"]:')
                end=original.index('elif "get" in a:',start)
                self.native.write_text(original[:start]+'if a[:2]==["account","show"]: print('+repr(response)+')\n'+original[end:])
                self.assertNotEqual(0,self.invoke().returncode)
                self.assertFalse(self.state.exists())
                self.assertFalse((self.root/'journal-home').exists())
                self.assertTrue(all(json.loads(x)[:2]==['account','show'] for x in self.marker.read_text().splitlines()))

    def test_profile_hash_missing_and_explicit_transport_mismatch_denied(self):
        self.assertNotEqual(0,self.invoke(profile_hash='0'*64).returncode)
        self.assertNotEqual(0,self.invoke(artifact='https://storage.example/other/results').returncode)
        self.assertNotEqual(0,self.invoke(image='registry.example/runner@sha256:'+'2'*64).returncode)
        self.assertFalse(self.marker.exists())
        self.assertFalse(self.state.exists())
        self.config.unlink()
        self.assertNotEqual(0,self.invoke(profile_hash='a'*64).returncode)
        self.assertFalse(self.marker.exists())

if __name__ == '__main__':
    unittest.main(verbosity=2)
