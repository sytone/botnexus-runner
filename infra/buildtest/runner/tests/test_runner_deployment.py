"""Offline existing-job update checks; authorized isolated Linux container only."""
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
ENTRY = Path('scripts/repo/Update-RunnerJobImage.ps1')
SENTINEL = 'PRIVATE_DEPLOY_SENTINEL_87352'
IMAGE = 'private.example.invalid/runner@sha256:' + 'a' * 64
OLD = 'private.example.invalid/runner@sha256:' + 'b' * 64


class RunnerDeployment(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='deployment-', dir='/work'))
        self.repo = self.root / 'source'
        shutil.copytree(SOURCE, self.repo, ignore=shutil.ignore_patterns('.git', '__pycache__'))
        transport=self.repo / 'scripts/repo/Import-RunnerResponseTransport.ps1'
        text=transport.read_text()
        start=text.index('    $handler = [Net.Http.HttpClientHandler]::new()')
        end=text.index('    return $handler',start)+len('    return $handler')
        transport.write_text(text[:start]+'    return [DeploymentResponseHandler]::new()'+text[end:])
        for args in [('init', '-q'), ('config', 'user.name', 'Synthetic Fixture'), ('config', 'user.email', 'fixture@example.invalid'), ('add', '.'), ('commit', '-qm', 'fixture')]:
            self.git(*args)
        self.head = self.git('rev-parse', 'HEAD').strip()
        for name in self.git('ls-files', '-z').split('\0')[:-1]:
            (self.repo / name).write_bytes(subprocess.check_output(['git', '-C', str(self.repo), 'show', 'HEAD:' + name]))
        self.git('add', '.')
        self.target = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/' + SENTINEL + '/providers/Microsoft.App/jobs/runner'
        self.managed_identity = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/fixture/providers/Microsoft.ManagedIdentity/userAssignedIdentities/runner'
        self.config = self.root / (SENTINEL + '.json')
        self.configuration = {'resourceId': self.target, 'managedIdentityResourceId': self.managed_identity, 'tenantId': '22222222-2222-2222-2222-222222222222', 'accountType': 'servicePrincipal', 'accountName': '33333333-3333-3333-3333-333333333333', 'subscriptionId': '11111111-1111-1111-1111-111111111111', 'image': IMAGE}
        self.write_configuration()
        self.approval = self.root / 'approval.json'
        self.approval.write_text(json.dumps({'approved': True, 'sourceCommit': self.head, 'image': IMAGE, 'runtimeManifestSha256': hashlib.sha256((self.repo / 'infra/buildtest/runner/image-runtime.json').read_bytes()).hexdigest()}))
        self.state = self.root / 'private-operation.json'
        self.journal_home = self.root / 'local-data'
        self.calls = self.root / 'calls.jsonl'
        self.jobfile = self.root / 'job.json'
        self.job = {'id': self.target, 'name': 'runner', 'type': 'Microsoft.App/jobs', 'location': 'fixture', 'etag': '"fixture-etag"', 'tags': {'private': SENTINEL}, 'identity': {'type': 'UserAssigned', 'userAssignedIdentities': {self.managed_identity: {}}}, 'properties': {'environmentId': '/private/environment', 'workloadProfileName': 'D8', 'provisioningState': 'Succeeded', 'configuration': {'triggerType': 'Manual', 'replicaTimeout': 1200, 'replicaRetryLimit': 0, 'manualTriggerConfig': {'parallelism': 1, 'replicaCompletionCount': 1}, 'registries': [{'server': 'private.example.invalid', 'identity': '/private/identity'}], 'secrets': [{'name': 'opaque-reference'}]}, 'template': {'containers': [{'name': 'runner', 'image': OLD, 'resources': {'cpu': 8.0, 'memory': '24Gi'}, 'env': [{'name': 'PRIVATE', 'secretRef': 'opaque-reference'}], 'probes': [{'type': 'Liveness', 'tcpSocket': {'port': 1234}}], 'volumeMounts': [{'volumeName': 'cache', 'mountPath': '/cache'}]}], 'initContainers': [{'name': 'init', 'image': OLD, 'resources': {'cpu': 0.25, 'memory': '0.5Gi'}}], 'volumes': [{'name': 'cache', 'storageType': 'EmptyDir'}]}}}
        self.jobfile.write_text(json.dumps(self.job))
        self.native = self.root / 'provider'
        self.native.write_text('''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
root=Path(__file__).parent
args=sys.argv[1:]
with (root/'calls.jsonl').open('a') as f: f.write(json.dumps(args)+'\\n')
mode=os.environ.get('DEPLOY_FIXTURE','success')
if mode=='dualoutput':
 import threading
 def emit(fd):
  for _ in range(256): os.write(fd,b'PRIVATE_DEPLOY_SENTINEL_87352'*256)
 a=threading.Thread(target=emit,args=(1,)); b=threading.Thread(target=emit,args=(2,)); a.start(); b.start(); a.join(); b.join(); sys.exit(0)
if args[:2]==['account','show']:
 if mode=='human': print(json.dumps({'id':'11111111-1111-1111-1111-111111111111','tenantId':'22222222-2222-2222-2222-222222222222','user':{'type':'user','name':'PRIVATE_DEPLOY_SENTINEL_87352'}})); sys.exit(0)
 print(json.dumps({'id':'11111111-1111-1111-1111-111111111111','tenantId':'22222222-2222-2222-2222-222222222222','user':{'type':'servicePrincipal','name':'33333333-3333-3333-3333-333333333333'}})); sys.exit(0)
if args[:2]==['account','get-access-token']:
 if '--subscription' in args and '--tenant' in args:sys.exit(64)
 print(json.dumps({'accessToken':'SYNTHETIC_DEPLOY_TOKEN','tokenType':'Bearer','subscription':'11111111-1111-1111-1111-111111111111','tenant':'22222222-2222-2222-2222-222222222222','expires_on':str(int(time.time())+3600)})); sys.exit(0)
assert args[0]=='rest'
method=args[args.index('--method')+1]
jobfile=root/'job.json'
job=json.loads(jobfile.read_text())
if method=='patch':
 body=json.loads(Path(args[args.index('--body')+1][1:]).read_text())
 (root/'patch.json').write_text(json.dumps(body))
 assert set(body)=={'properties'} and set(body['properties'])=={'template'} and set(body['properties']['template'])=={'containers'}
 job['properties']['template']['containers']=body['properties']['template']['containers']
 if mode!='async': jobfile.write_text(json.dumps(job))
 if mode=='drift': job['properties']['template']['containers'][0]['resources']['memory']='1Gi'; jobfile.write_text(json.dumps(job))
 if mode=='unknown': print('PRIVATE_DEPLOY_SENTINEL_87352',file=sys.stderr); sys.exit(9)
 if mode=='timeout': time.sleep(60)
 if mode=='async': print('{}'); sys.exit(0)
 print(json.dumps(job)); sys.exit(0)
assert method=='get'
if mode=='dualoutput':
 import threading
 def emit(fd):
  for _ in range(256): os.write(fd,b'PRIVATE_DEPLOY_SENTINEL_87352'*256)
 a=threading.Thread(target=emit,args=(1,)); b=threading.Thread(target=emit,args=(2,)); a.start(); b.start(); a.join(); b.join(); sys.exit(0)
if mode=='malformed': print('{PRIVATE_DEPLOY_SENTINEL_87352'); sys.exit(0)
if mode=='identity': job['id']='/wrong/PRIVATE_DEPLOY_SENTINEL_87352'
if mode=='failure': print('PRIVATE_DEPLOY_SENTINEL_87352',file=sys.stderr); sys.exit(9)
if mode=='highoutput': print('PRIVATE_DEPLOY_SENTINEL_87352'*100000); sys.exit(0)
print(json.dumps(job))
''')
        self.native.chmod(0o700)

    def tearDown(self):
        shutil.rmtree(self.root)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True, stderr=subprocess.DEVNULL)

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

    def invoke(self, *args, mode='success', config=None, approval=None, config_hash=None):
        env = os.environ.copy()
        env['XDG_DATA_HOME'] = str(self.journal_home)
        env['DEPLOY_FIXTURE'] = mode
        env['DEPLOY_ROOT'] = str(self.root)
        env['DEPLOY_HANDLER'] = str(self.repo / 'infra/buildtest/runner/tests/DeploymentResponseHandler.cs')
        p = subprocess.run(['pwsh', '-NoProfile', '-CommandWithArgs', 'Add-Type -Path $env:DEPLOY_HANDLER; $entry=$args[0]; $parameters=@{}; for ($i=1; $i -lt $args.Count; $i++) { $name=$args[$i].TrimStart([char]45); if ($name -in @("WhatIf","Reconcile")) { $parameters[$name]=$true } else { $i++; $parameters[$name]=$args[$i] } }; & $entry @parameters', str(self.repo / ENTRY), '-SourceRoot', str(self.repo), '-ExpectedCommit', self.head, '-ConfigurationPath', str(config or self.config), '-PrivateRoot', str(self.root), '-ConfigurationSha256', config_hash or hashlib.sha256((config or self.config).read_bytes()).hexdigest(), '-ApprovalPath', str(approval or self.approval), '-StatePath', str(self.state), '-ProviderCommand', str(self.native), *args], capture_output=True, text=True, env=env, timeout=40)
        for private in [SENTINEL, str(self.root), self.target, IMAGE, '22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333']:
            self.assertNotIn(private, p.stdout + p.stderr)
        return p

    def records(self):
        return [json.loads(s) for s in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_preview_has_no_provider_or_output_creation(self):
        before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.root.rglob('*') if p.is_file()}
        p = self.invoke('-WhatIf')
        self.assertEqual(0, p.returncode, p.stderr)
        self.assertEqual([], self.records())
        self.assertFalse(self.state.exists())
        self.assertEqual(before, {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.root.rglob('*') if p.is_file()})

    def test_patch_preserves_full_shape_and_receipt_is_not_acceptance(self):
        p = self.invoke()
        self.assertEqual(0, p.returncode, p.stderr)
        expected = copy.deepcopy(self.job)
        expected['properties']['template']['containers'][0]['image'] = IMAGE
        self.assertEqual(expected, json.loads(self.jobfile.read_text()))
        result = json.loads(p.stdout)
        self.assertEqual('updated', result['status'])
        self.assertIsNone(result['tests'])
        self.assertFalse(result['accepted'])
        patch = json.loads((self.root / 'patch.json').read_text())
        self.assertEqual(expected['properties']['template']['containers'], patch['properties']['template']['containers'])
        self.assertEqual(1, sum('patch' in r for r in self.records()))
        self.assertTrue(any('If-Match="fixture-etag"' in r for r in self.records()))

    def test_async_is_unknown_not_completed_and_no_second_write(self):
        p = self.invoke(mode='async')
        self.assertNotEqual(0, p.returncode)
        self.assertIn('unknown', p.stderr)
        self.assertTrue(self.state.exists())
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertEqual(1, sum('patch' in r for r in self.records()))
        job = json.loads(self.jobfile.read_text())
        job['properties']['template']['containers'][0]['image'] = IMAGE
        self.jobfile.write_text(json.dumps(job))
        p = self.invoke('-Reconcile')
        self.assertEqual(0, p.returncode, p.stderr)
        self.assertEqual(1, sum('patch' in r for r in self.records()))

    def test_write_nonzero_without_causal_proof_stays_unknown_without_retry(self):
        p = self.invoke(mode='unknown')
        self.assertNotEqual(0, p.returncode)
        self.assertIn('unknown',p.stderr)
        self.assertTrue(self.state.exists())
        self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
        self.assertEqual(1, sum('patch' in r for r in self.records()))

    def test_causal_200_requires_terminal_bound_write_response(self):
        for mode in ['accepted200','wrongimage200','wrongtarget200','ambiguous200','partialbody','http500','missingref','unsafe']:
            with self.subTest(mode=mode):
                self.state.unlink(missing_ok=True)
                self.journal_home = self.root / ('local-data-' + mode)
                self.jobfile.write_text(json.dumps(self.job))
                p=self.invoke(mode=mode)
                self.assertNotEqual(0,p.returncode)
                self.assertIn('unknown',p.stderr)
                self.assertTrue(self.state.exists())
                self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
        self.assertEqual(8,sum('patch' in r for r in self.records()))

    def test_async_operation_priority_location_and_status_denial(self):
        for mode in ['priority','asynclocation']:
            with self.subTest(mode=mode):
                self.state.unlink(missing_ok=True)
                self.journal_home = self.root / ('local-data-' + mode)
                self.jobfile.write_text(json.dumps(self.job))
                self.assertNotEqual(0,self.invoke(mode=mode).returncode)
                state=json.loads(self.state.read_text())
                self.assertIn('/operationStatuses/operation-1?',state['operationUri'])
                self.assertNotEqual(0,self.invoke('-Reconcile',mode='statusdenied').returncode)
                self.assertNotEqual(0,self.invoke('-Reconcile',mode='pending').returncode)
                self.assertNotEqual(0,self.invoke('-Reconcile',mode='opfailed').returncode)
                self.assertEqual(0,self.invoke('-Reconcile').returncode)
        self.assertEqual(2,sum('patch' in r for r in self.records()))

    def test_torn_causal_record_cannot_use_matching_job_as_proof(self):
        self.assertEqual(0,self.invoke().returncode)
        state=json.loads(self.state.read_text())
        state.pop('causalStatus')
        self.state.write_text(json.dumps(state))
        self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
        self.assertEqual(1,sum('patch' in r for r in self.records()))

    def test_terminal_write_still_requires_fresh_full_readback(self):
        p=self.invoke(mode='readbackdrift')
        self.assertNotEqual(0,p.returncode)
        self.assertIn('unknown',p.stderr)
        self.assertEqual(200,json.loads(self.state.read_text())['causalStatus'])
        self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
        self.assertEqual(1,sum('patch' in r for r in self.records()))
        self.assertGreaterEqual(sum('get' in r for r in self.records()),3)

    def test_torn_json_causal_fence_cannot_replay_or_complete(self):
        self.assertEqual(0,self.invoke().returncode)
        self.state.write_text('{"causalStatus":200,')
        self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertEqual(1,sum('patch' in r for r in self.records()))

    def test_missing_current_etag_or_mutable_image_remains_denied(self):
        # Mapped stronger contract: no ETag is valid only with exact approved
        # account binding and canonical once-only journal; mutable image still denies.
        job=copy.deepcopy(self.job)
        del job['etag']
        self.jobfile.write_text(json.dumps(job))
        self.assertNotEqual(0,self.invoke(mode='human').returncode)
        self.assertFalse(self.state.exists())
        self.assertEqual(0,self.invoke().returncode)
        self.assertEqual(1,sum('patch' in r for r in self.records()))
        self.assertNotEqual(0,self.invoke().returncode)
        job['properties']['template']['containers'][0]['image']='private.example.invalid/runner:latest'
        self.jobfile.write_text(json.dumps(job))
        self.state=self.root/'alternate.json'
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertFalse(self.state.exists())
        self.assertEqual(1,sum('patch' in r for r in self.records()))

    def test_unknown_canonical_target_blocks_alternate_receipt_config_and_image(self):
        self.assertNotEqual(0,self.invoke(mode='unknown').returncode)
        first=self.state
        self.state=self.root/'alternate.json'
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertFalse(self.state.exists())
        other=self.root/'alternate-config.json'
        other.write_bytes(self.config.read_bytes())
        self.assertNotEqual(0,self.invoke(config=other).returncode)
        self.configuration['image']='private.example.invalid/runner@sha256:'+'c'*64
        self.write_configuration()
        approval=json.loads(self.approval.read_text()); approval['image']=self.configuration['image']
        self.approval.write_text(json.dumps(approval))
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertTrue(first.exists())
        self.assertEqual(1,sum('patch' in r for r in self.records()))

    def test_completed_canonical_journal_audit_and_history_deny_replay(self):
        self.assertEqual(0,self.invoke().returncode)
        journals=list(self.journal_home.rglob('*.deployment.json'))
        self.assertEqual(1,len(journals))
        record=json.loads(journals[0].read_text())
        self.assertEqual('completed-reconciled',record['status'])
        audit=journals[0].parent/(record['operationId']+'.deployment-completed.json')
        self.assertEqual(record,json.loads(audit.read_text()))
        self.assertEqual(record,json.loads(self.state.read_text()))
        self.assertEqual(0o600,journals[0].stat().st_mode & 0o777)
        self.state=self.root/'new-receipt.json'
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertEqual(1,sum('patch' in r for r in self.records()))

    def test_receipt_journal_conflict_denies_readonly_reconciliation(self):
        self.assertNotEqual(0,self.invoke(mode='async').returncode)
        record=json.loads(self.state.read_text()); record['operationId']='0'*32
        self.state.write_text(json.dumps(record))
        self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
        self.assertEqual(1,sum('patch' in r for r in self.records()))

    def test_later_distinct_deployment_requires_completed_audit_and_denies_history(self):
        self.assertEqual(0,self.invoke().returncode)
        original_config=self.config.read_bytes()
        original_approval=self.approval.read_bytes()
        self.configuration['image']='private.example.invalid/runner@sha256:'+'c'*64
        self.write_configuration()
        approval=json.loads(self.approval.read_text()); approval['image']=self.configuration['image']
        self.approval.write_text(json.dumps(approval))
        self.state=self.root/'second-operation.json'
        self.assertEqual(0,self.invoke().returncode)
        self.assertEqual(2,sum('patch' in r for r in self.records()))
        self.config.write_bytes(original_config); self.approval.write_bytes(original_approval)
        self.state=self.root/'history-replay.json'
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertEqual(2,sum('patch' in r for r in self.records()))

    def test_canonical_journal_torn_duplicate_link_and_permissions_fail_closed(self):
        self.assertNotEqual(0,self.invoke(mode='async').returncode)
        journal=next(self.journal_home.rglob('*.deployment.json'))
        original=journal.read_bytes()
        for malformed in [b'{"status":', b'{"status":"completed-reconciled","status":"attempted-unknown"}']:
            with self.subTest(value=malformed.decode()):
                journal.write_bytes(malformed)
                self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
                self.state=self.root/'alternate-journal-receipt.json'
                self.assertNotEqual(0,self.invoke().returncode)
        journal.write_bytes(original)
        journal.chmod(0o644)
        self.assertNotEqual(0,self.invoke().returncode)
        journal.chmod(0o600)
        journal.unlink(); journal.symlink_to(self.root/'private-operation.json')
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertEqual(1,sum('patch' in r for r in self.records()))

    def test_crossprocess_reservation_contention_and_unknown_run_deny_deployment(self):
        import time
        holder=self.root/'holder.ps1'
        ready=self.root/'ready'
        holder.write_text(". '"+str(self.repo/'scripts/repo/Import-RunnerOperation.ps1')+"'; . '"+str(self.repo/'scripts/repo/Import-RunnerTargetJournal.ps1')+"'; $r=Enter-RunnerTargetReservation -Resource $args[0]; [IO.File]::WriteAllText($args[1], 'ready'); [Console]::ReadLine() | Out-Null; Exit-RunnerTargetReservation -Reservation $r")
        env=os.environ.copy(); env['XDG_DATA_HOME']=str(self.journal_home)
        child=subprocess.Popen(['pwsh','-NoProfile','-File',str(holder),self.target,str(ready)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
        try:
            deadline=time.monotonic()+10
            while not ready.exists() and child.poll() is None and time.monotonic()<deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists())
            self.assertNotEqual(0,self.invoke().returncode)
            self.assertEqual([],self.records())
        finally:
            out,err=child.communicate(input=b'\n',timeout=10)
        self.assertEqual(0,child.returncode,err)
        key=hashlib.sha256(self.target.lower().encode()).hexdigest()
        run=next(self.journal_home.rglob('runner-operations'))/(key+'.json')
        run.write_text(json.dumps({'status':'submitted-unverified'}));run.chmod(0o600)
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertEqual([],self.records())

    def test_private_receipt_special_node_and_canonical_hardlink_deny(self):
        os.mkfifo(self.state,0o600)
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertEqual([],self.records())
        self.state.unlink()
        self.assertNotEqual(0,self.invoke(mode='async').returncode)
        journal=next(self.journal_home.rglob('*.deployment.json'))
        os.link(journal,self.root/'duplicate-link')
        self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
        self.assertEqual(1,sum('patch' in r for r in self.records()))

    def test_receipt_copy_failure_retains_canonical_unknown_without_patch(self):
        # The path is absent at preflight, then becomes a directory during GET.
        native=self.native.read_text()
        native=native.replace("if args[:2]==['account','get-access-token']:","if args[:2]==['account','get-access-token']:\n (root/'private-operation.json').mkdir()")
        self.native.write_text(native)
        self.assertNotEqual(0,self.invoke().returncode)
        journal=next(self.journal_home.rglob('*.deployment.json'))
        self.assertEqual('attempted-unknown',json.loads(journal.read_text())['status'])
        self.assertFalse(any('patch' in r for r in self.records()))
        self.state=self.root/'alternate-after-copy-failure.json'
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertFalse(any('patch' in r for r in self.records()))

    def test_private_input_drift_after_preflight_denies_patch(self):
        native=self.native.read_text()
        native=native.replace("if args[:2]==['account','get-access-token']:","if args[:2]==['account','get-access-token']:\n (root/'approval.json').write_text('{}')")
        self.native.write_text(native)
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertFalse(self.state.exists())
        self.assertFalse(any('patch' in r for r in self.records()))

    def test_native_failure_malformed_and_highoutput_redacted(self):
        for mode in ['failure', 'malformed', 'highoutput', 'identity']:
            with self.subTest(mode=mode):
                self.assertNotEqual(0, self.invoke(mode=mode).returncode)
                self.assertFalse(self.state.exists())
                self.assertFalse(any('patch' in r for r in self.records()))

    def test_reject_topology_overrides_and_budget_without_write(self):
        for mutation in ['extra', 'command', 'args', 'budget', 'trigger', 'retry', 'parallel', 'identity', 'identity-id']:
            with self.subTest(mutation=mutation):
                job = copy.deepcopy(self.job)
                container = job['properties']['template']['containers'][0]
                if mutation == 'extra': job['properties']['template']['containers'].append(copy.deepcopy(container))
                if mutation == 'command': container['command'] = ['sh']
                if mutation == 'args': container['args'] = ['override']
                if mutation == 'budget': job['properties']['configuration']['replicaTimeout'] = 9999
                if mutation == 'trigger': job['properties']['configuration']['triggerType'] = 'Schedule'
                if mutation == 'retry': job['properties']['configuration']['replicaRetryLimit'] = 1
                if mutation == 'parallel': job['properties']['configuration']['manualTriggerConfig']['parallelism'] = 2
                if mutation == 'identity': job['identity']['type'] = 'SystemAssigned'
                if mutation == 'identity-id': job['identity']['userAssignedIdentities'] = {'/unexpected/identity': {}}
                self.jobfile.write_text(json.dumps(job))
                self.assertNotEqual(0, self.invoke().returncode)
                self.assertFalse(self.state.exists())
                self.assertFalse(any('patch' in r for r in self.records()))

    def test_dirty_source_missing_approval_and_mutable_image_deny_before_provider(self):
        valid_approval = self.approval.read_text()
        self.approval.write_text('{}')
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertEqual([], self.records())
        self.approval.write_text(valid_approval)
        self.configuration['image'] = 'private.example.invalid/runner:latest'
        self.write_configuration()
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertEqual([], self.records())
        self.configuration['image'] = IMAGE
        self.write_configuration()
        (self.repo / 'README.md').write_text('dirty')
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertEqual([], self.records())

    def test_private_duplicate_and_linked_configuration_denied(self):
        valid = self.config.read_text()
        self.config.write_text(valid[:-1] + ',"schemaVersion":1}')
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertEqual([], self.records())
        self.config.write_text(valid)
        link = self.root / 'link.json'
        link.symlink_to(self.config)
        self.assertNotEqual(0, self.invoke(config=link).returncode)
        self.assertEqual([], self.records())

    def test_timeout_keeps_uncertain_state_and_one_write(self):
        import time
        start = time.monotonic()
        p = self.invoke('-TimeoutSeconds', '6', mode='timeout')
        self.assertNotEqual(0, p.returncode)
        self.assertIn('unknown', p.stderr)
        self.assertLess(time.monotonic() - start, 20)
        self.assertTrue(self.state.exists())
        self.assertEqual(1, sum('patch' in r for r in self.records()))
        self.assertEqual([], list(self.root.glob('runner-update-*')))
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertEqual(1, sum('patch' in r for r in self.records()))


    def test_unknown_operator_identity_denied_before_job_read(self):
        self.assertNotEqual(0, self.invoke(mode='human').returncode)
        self.assertEqual(1, len(self.records()))
        self.assertFalse(self.state.exists())

    def test_readback_invariant_change_is_not_success(self):
        p = self.invoke(mode='drift')
        self.assertNotEqual(0, p.returncode)
        self.assertIn('unknown', p.stderr)
        self.assertTrue(self.state.exists())
        self.assertEqual(1, sum('patch' in r for r in self.records()))
        self.assertNotEqual(0, self.invoke('-Reconcile').returncode)
        self.assertEqual(1, sum('patch' in r for r in self.records()))

    def test_dual_stream_overflow_drains_and_denies(self):
        p = self.invoke(mode='dualoutput')
        self.assertNotEqual(0, p.returncode)
        self.assertLess(len(p.stdout) + len(p.stderr), 1024)
        self.assertFalse(self.state.exists())

    def test_approval_and_configuration_exact_hash_bindings(self):
        approval = json.loads(self.approval.read_text())
        for field in ['sourceCommit', 'runtimeManifestSha256', 'image', 'approved']:
            with self.subTest(field=field):
                broken = copy.deepcopy(approval)
                broken[field] = False if field == 'approved' else 'mismatch'
                self.approval.write_text(json.dumps(broken))
                self.assertNotEqual(0, self.invoke().returncode)
                self.assertEqual([], self.records())
        self.approval.write_text(json.dumps(approval))
        p = self.invoke(config_hash='0' * 64)
        self.assertNotEqual(0, p.returncode)
        self.assertEqual([], self.records())

    def test_observed_private_paths_invalid_json_and_types(self):
        valid = self.config.read_bytes()
        for value in [b'', b'[]', b'null', b'{bad', valid + b'{}', valid + b' ' * 4096, b'{"image":"'+bytes([255])+b'"}', b'{"image":true}']:
            with self.subTest(size=len(value)):
                self.config.write_bytes(value)
                self.assertNotEqual(0, self.invoke().returncode)
                self.assertEqual([], self.records())
        self.config.write_bytes(valid)
        alias = self.root / 'linked-private'
        alias.symlink_to(self.root, target_is_directory=True)
        self.assertNotEqual(0, self.invoke(config=alias / self.config.name).returncode)
        self.assertEqual([], self.records())

    def test_same_process_preview_preserves_empty_absent_environment(self):
        command = "$env:RUNNER_UPDATE_EMPTY = ''; Remove-Item Env:RUNNER_UPDATE_ABSENT -ErrorAction SilentlyContinue; $before = @{}; Get-ChildItem Env: | ForEach-Object { $before[$_.Name] = $_.Value }; & $args[0] -SourceRoot $args[1] -ExpectedCommit $args[2] -ConfigurationPath $args[3] -PrivateRoot ([IO.Path]::GetDirectoryName($args[3])) -ConfigurationSha256 $args[4] -ApprovalPath $args[5] -StatePath $args[6] -ProviderCommand $args[7] -WhatIf; $after = @{}; Get-ChildItem Env: | ForEach-Object { $after[$_.Name] = $_.Value }; if (($before | ConvertTo-Json -Compress) -cne ($after | ConvertTo-Json -Compress)) { exit 3 }"
        before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.root.rglob('*') if p.is_file()}
        p = subprocess.run(['pwsh', '-NoProfile', '-CommandWithArgs', command, str(self.repo / ENTRY), str(self.repo), self.head, str(self.config), hashlib.sha256(self.config.read_bytes()).hexdigest(), str(self.approval), str(self.state), str(self.native)], capture_output=True, text=True)
        self.assertEqual(0, p.returncode, p.stderr)
        self.assertEqual(before, {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.root.rglob('*') if p.is_file()})
        self.assertEqual([], self.records())

    def test_private_state_permissions_and_cleanup(self):
        before = set(self.root.glob('runner-update-*'))
        self.assertEqual(0, self.invoke().returncode)
        self.assertEqual(0o600, self.state.stat().st_mode & 0o777)
        self.assertEqual(before, set(self.root.glob('runner-update-*')))
        self.assertEqual(0, self.invoke('-Reconcile').returncode)
        self.assertEqual(1, sum('patch' in r for r in self.records()))


    def test_provider_resource_id_case_matches_without_changing_identity(self):
        job = copy.deepcopy(self.job)
        identity = job['identity']['userAssignedIdentities'].pop(self.managed_identity)
        job['identity']['userAssignedIdentities'][self.managed_identity.replace('/resourceGroups/', '/resourcegroups/')] = identity
        self.jobfile.write_text(json.dumps(job))
        self.assertEqual(0, self.invoke().returncode)
        self.assertEqual(1, sum('patch' in r for r in self.records()))

    def test_different_managed_identity_remains_denied(self):
        job = copy.deepcopy(self.job)
        identity = job['identity']['userAssignedIdentities'].pop(self.managed_identity)
        job['identity']['userAssignedIdentities'][self.managed_identity + '-other'] = identity
        self.jobfile.write_text(json.dumps(job))
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertFalse(any('patch' in r for r in self.records()))

    def test_explicit_configured_user_positive(self):
        job=copy.deepcopy(self.job); del job['etag']; self.jobfile.write_text(json.dumps(job))
        self.configuration.update(accountType='user', accountName='operator@example.invalid')
        self.write_configuration()
        native=self.native.read_text().replace("'type':'servicePrincipal','name':'33333333-3333-3333-3333-333333333333'", "'type':'user','name':'operator@example.invalid'")
        self.native.write_text(native)
        self.assertEqual(0, self.invoke().returncode)
        self.assertEqual(1, sum('patch' in r for r in self.records()))
        self.assertTrue(all('--subscription' in r and r[r.index('--subscription')+1]==self.configuration['subscriptionId'] for r in self.records() if r[0]!='account'))

    def test_account_binding_mismatches_before_job_read(self):
        original=self.native.read_text()
        for old,new in [('servicePrincipal','user'), ('33333333-3333-3333-3333-333333333333','wrong@example.invalid'), ('22222222-2222-2222-2222-222222222222','55555555-5555-5555-5555-555555555555'), ('11111111-1111-1111-1111-111111111111','66666666-6666-6666-6666-666666666666')]:
            with self.subTest(field=old):
                self.native.write_text(original.replace(old,new))
                self.assertNotEqual(0,self.invoke().returncode)
                self.assertTrue(all(r[:2]==['account','show'] for r in self.records()))
                self.assertFalse(self.state.exists())

    def test_account_configuration_missing_duplicate_unknown_denied(self):
        valid=dict(self.configuration)
        for field in ['accountType','accountName','tenantId','subscriptionId']:
            broken=dict(valid);del broken[field]
            self.write_configuration(broken)
            self.assertNotEqual(0,self.invoke().returncode)
            self.assertEqual([],self.records())
        for field,value in [('accountType','unknown'),('accountName',''),('subscriptionId','invalid'),('subscriptionId','77777777-7777-7777-7777-777777777777'),('accountName',None),('accountType',True),('unknown', 'PRIVATE_DEPLOY_SENTINEL_87352')]:
            self.write_configuration(dict(valid,**{field:value}))
            self.assertNotEqual(0,self.invoke().returncode)
            self.assertEqual([],self.records())
        text=self.config.read_text()
        self.config.write_text(text[:-1]+',"schemaVersion":1}')
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertEqual([],self.records())

    def test_account_response_missing_duplicate_unknown_type_denied(self):
        original=self.native.read_text()
        for response in ['{}', '{"id":"11111111-1111-1111-1111-111111111111","ID":"11111111-1111-1111-1111-111111111111","tenantId":"22222222-2222-2222-2222-222222222222","user":{"type":"servicePrincipal","name":"33333333-3333-3333-3333-333333333333"}}', '{"tenantId":"22222222-2222-2222-2222-222222222222","user":{"type":"servicePrincipal","name":"33333333-3333-3333-3333-333333333333"}}', '{"id":"11111111-1111-1111-1111-111111111111","tenantId":"22222222-2222-2222-2222-222222222222","user":{"type":"unknown","name":"33333333-3333-3333-3333-333333333333"}}']:
            start=original.index(" print(json.dumps(",original.index("if args[:2]==['account','show']:"))
            end=original.index("if args[:2]==['account','get-access-token']:",start)
            self.native.write_text(original[:start]+" print("+repr(response)+"); sys.exit(0)\n"+original[end:])
            self.assertNotEqual(0,self.invoke().returncode)
            self.assertFalse(self.state.exists())
            self.assertTrue(all(r[:2]==['account','show'] for r in self.records()))

    def prepare_current_tag(self, fault=None):
        tag = 'private.azurecr.io/runner:src-historical'
        self.current_digest = 'private.azurecr.io/runner@sha256:' + 'b' * 64
        self.job['properties']['template']['containers'][0]['image'] = tag
        self.job['properties']['template']['containers'][0]['unknownNull'] = None
        self.jobfile.write_text(json.dumps(self.job))
        self.current_approval = self.root / 'current-approval.json'
        evidence = {'approved': True, 'observedImage': tag, 'image': self.current_digest,
                    'sourceCommit': 'c' * 40, 'runtimeManifestSha256': 'd' * 64}
        if fault == 'wrongrepo': evidence['image'] = 'private.azurecr.io/other@sha256:' + 'b' * 64
        if fault == 'unapproved': evidence['approved'] = False
        if fault == 'source': evidence['sourceCommit'] = 'opaque'
        if fault == 'runtime': evidence['runtimeManifestSha256'] = None
        if fault == 'unknown': evidence['unknown'] = 'PRIVATE_DEPLOY_SENTINEL_87352'
        self.current_approval.write_text(json.dumps(evidence))
        if not hasattr(self, 'current_native_original'):
            self.current_native_original = self.native.read_text()
        native = self.current_native_original
        branch = """if args[:3]==['acr','manifest','show-metadata']:
 countfile=root/'metadata-count'
 count=int(countfile.read_text())+1 if countfile.exists() else 1
 countfile.write_text(str(count))
 fault=FAULT
 if fault=='unresolved': sys.exit(7)
 if fault=='malformed': print('{PRIVATE_DEPLOY_SENTINEL_87352'); sys.exit(0)
 digest='sha256:'+'b'*64
 if fault=='mismatch' or (fault=='race' and count==3): digest='sha256:'+'e'*64
 # CLI extracts inner tag or manifest attributes from the REST envelope.
 query=args[args.index('--name')+1]
 is_tag='@' not in query
 assert args[args.index('--registry')+1]=='private'
 assert query==('runner:src-historical' if is_tag else 'runner@sha256:'+'b'*64)
 assert args[args.index('--subscription')+1]=='11111111-1111-1111-1111-111111111111'
 response={'digest':digest,'createdTime':'2018-10-05T20:54:24Z','lastUpdateTime':'2018-10-05T20:54:24Z',
           'changeableAttributes':{'deleteEnabled':True,'listEnabled':True,'readEnabled':True,'writeEnabled':False}}
 if is_tag: response['name']='src-historical'
 else: response.update(tags=['src-historical'],architecture='amd64',os='linux',imageSize=2401606)
 if fault in ['wrongname','wrongtag'] and is_tag: response['name']='other'
 if fault=='missingname' and is_tag: response.pop('name')
 if fault=='nullname' and is_tag: response['name']=None
 if fault=='missingdigest': response.pop('digest')
 if fault=='nulldigest': response['digest']=None
 if fault=='manifestmismatch' and not is_tag: response['digest']='sha256:'+'e'*64
 if fault=='manifestmissing' and not is_tag: response.pop('digest')
 if fault=='manifestnull' and not is_tag: response['digest']=None
 if fault=='manifesttagsmissing' and not is_tag: response.pop('tags')
 if fault=='manifesttagsnull' and not is_tag: response['tags']=None
 if fault=='manifestwrongtag' and not is_tag: response['tags']=['other']
 if fault=='manifesttagtype' and not is_tag: response['tags']=[None]
 if fault=='manifesttagduplicate' and not is_tag: response['tags']=['src-historical','src-historical']
 if fault=='opaque': response['digest']={}
 if fault=='duplicate' or (fault=='manifestduplicate' and not is_tag):
  raw=json.dumps(response); print(raw[:-1]+',"digest":'+json.dumps(digest)+'}'); sys.exit(0)
 if fault=='duplicatename' and is_tag:
  raw=json.dumps(response); print(raw[:-1]+',"name":"src-historical"}'); sys.exit(0)
 if fault=='approvaldrift' and count==3: (root/'current-approval.json').write_text('{}')
 if fault=='desireddrift' and count==3: (root/'approval.json').write_text('{}')
 if fault=='configdrift' and count==3:
  config=next(root.glob('PRIVATE_DEPLOY*.json')); config.write_text('{}')
 if fault=='sourcedrift' and count==3: (root/'source/README.md').write_text('drift')
 (root/('metadata-'+str(count)+'.json')).write_text(json.dumps(response))
 print(json.dumps(response)); sys.exit(0)
""".replace('FAULT', repr(fault))
        self.native.write_text(native.replace("assert args[0]=='rest'", branch+"assert args[0]=='rest'"))
        return ['-CurrentImageApprovalPath', str(self.current_approval),
                '-CurrentImageApprovalSha256', hashlib.sha256(self.current_approval.read_bytes()).hexdigest()]

    def test_current_tag_verified_immutable_provenance_preserves_shape(self):
        args = self.prepare_current_tag()
        p = self.invoke(*args)
        self.assertEqual(0, p.returncode, p.stderr)
        expected = copy.deepcopy(self.job)
        expected['properties']['template']['containers'][0]['image'] = IMAGE
        self.assertEqual(expected, json.loads(self.jobfile.read_text()))
        self.assertEqual(3, sum(r[:3] == ['acr','manifest','show-metadata'] for r in self.records()))
        self.assertEqual('src-historical', json.loads((self.root / 'metadata-1.json').read_text())['name'])
        self.assertNotIn('name', json.loads((self.root / 'metadata-2.json').read_text()))
        self.assertEqual(['src-historical'], json.loads((self.root / 'metadata-2.json').read_text())['tags'])
        self.assertEqual(1, sum('patch' in r for r in self.records()))
        state = json.loads(self.state.read_text())
        self.assertEqual(self.current_digest, state['currentImage'])
        self.assertEqual('c' * 40, state['currentSourceCommit'])
        self.assertEqual(hashlib.sha256(self.current_approval.read_bytes()).hexdigest(), state['currentApprovalSha256'])
        self.assertEqual(0, self.invoke('-Reconcile', *args).returncode)
        self.assertEqual(1, sum('patch' in r for r in self.records()))

    def test_current_tag_unverified_and_race_metadata_deny_before_write(self):
        source_readme = (self.repo / 'README.md').read_bytes()
        desired_approval = self.approval.read_bytes()
        for fault in ['unresolved', 'malformed', 'mismatch', 'wrongrepo', 'wrongname', 'opaque', 'unapproved', 'race', 'source', 'runtime', 'unknown', 'duplicate', 'approvaldrift', 'desireddrift', 'configdrift', 'sourcedrift', 'wrongtag', 'missingname', 'nullname', 'missingdigest', 'nulldigest', 'duplicatename', 'manifestmismatch', 'manifestmissing', 'manifestnull', 'manifesttagsmissing', 'manifesttagsnull', 'manifestwrongtag', 'manifesttagtype', 'manifesttagduplicate', 'manifestduplicate']:
            with self.subTest(fault=fault):
                (self.repo / 'README.md').write_bytes(source_readme)
                self.approval.write_bytes(desired_approval)
                self.write_configuration()
                args = self.prepare_current_tag(fault)
                (self.root / 'metadata-count').unlink(missing_ok=True)
                p = self.invoke(*args)
                self.assertNotEqual(0, p.returncode)
                self.assertFalse(self.state.exists())
                self.assertFalse(any('patch' in r for r in self.records()))
                expected = 0 if fault in ['wrongrepo','unapproved','source','runtime','unknown'] else 3 if fault in ['race','approvaldrift','desireddrift','configdrift','sourcedrift'] else 2 if fault.startswith('manifest') else 1
                countfile = self.root / 'metadata-count'
                self.assertEqual(expected, int(countfile.read_text()) if countfile.exists() else 0)

    def test_current_tag_requires_pinned_external_approval(self):
        args = self.prepare_current_tag()
        self.assertNotEqual(0, self.invoke().returncode)
        self.assertNotEqual(0, self.invoke(*args[:-1], '0' * 64).returncode)
        self.assertFalse(self.state.exists())
        self.assertFalse(any('patch' in r for r in self.records()))

    def test_current_tag_preview_no_metadata_or_output(self):
        args = self.prepare_current_tag()
        before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(0, self.invoke('-WhatIf', *args).returncode)
        self.assertEqual([], self.records())
        self.assertEqual(before, {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in self.root.rglob('*') if p.is_file()})

    def test_current_tag_async_unknown_no_replay_and_provenance_reconcile(self):
        args = self.prepare_current_tag()
        p = self.invoke(*args, mode='async')
        self.assertNotEqual(0, p.returncode)
        self.assertIn('unknown', p.stderr)
        state = json.loads(self.state.read_text())
        self.assertEqual(202, state['causalStatus'])
        self.assertEqual(self.current_digest, state['currentImage'])
        original = self.state
        self.state = self.root / 'alternate-tagged.json'
        self.assertNotEqual(0, self.invoke(*args).returncode)
        self.assertFalse(self.state.exists())
        self.state = original
        job = json.loads(self.jobfile.read_text())
        job['properties']['template']['containers'][0]['image'] = IMAGE
        self.jobfile.write_text(json.dumps(job))
        self.assertNotEqual(0, self.invoke('-Reconcile').returncode)
        self.assertEqual(0, self.invoke('-Reconcile', *args).returncode)
        self.assertEqual(1, sum('patch' in r for r in self.records()))

    def test_current_tag_explicit_empty_overrides_still_denied(self):
        args = self.prepare_current_tag()
        for field in ['command', 'args']:
            with self.subTest(field=field):
                job = copy.deepcopy(self.job)
                job['properties']['template']['containers'][0][field] = []
                self.jobfile.write_text(json.dumps(job))
                self.assertNotEqual(0, self.invoke(*args).returncode)
                self.assertFalse(self.state.exists())
                self.assertFalse(any('patch' in r for r in self.records()))
                self.assertFalse((self.root / 'metadata-count').exists())

    def test_profile_hash_missing_and_unknown_denied(self):
        self.assertNotEqual(0,self.invoke(config_hash='0'*64).returncode)
        self.assertEqual([],self.records())
        valid=self.config.read_bytes()
        for value in [{}, {'schemaVersion':1,'unknown':'PRIVATE_DEPLOY_SENTINEL_87352'}]:
            self.config.write_text(json.dumps(value))
            self.assertNotEqual(0,self.invoke().returncode)
            self.assertEqual([],self.records())
        self.config.write_bytes(valid)
        self.config.unlink()
        self.assertNotEqual(0,self.invoke(config_hash='a'*64).returncode)
        self.assertEqual([],self.records())
        self.assertFalse(self.state.exists())

if __name__ == '__main__':
    unittest.main(verbosity=2)
