"""Fresh provisioning contract; execute in an isolated offline Linux container only."""
import hashlib,json,os,shutil,subprocess,tempfile,unittest
from pathlib import Path

SOURCE=Path(__file__).resolve().parents[4]
ENTRY=Path('scripts/repo/New-RunnerInfrastructure.ps1')
SUB='11111111-1111-1111-1111-111111111111'
TENANT='22222222-2222-2222-2222-222222222222'
PRIVATE='PRIVATE_PROVISION_SENTINEL'


class RunnerProvision(unittest.TestCase):
    def setUp(self):
        self.root=Path(tempfile.mkdtemp(prefix='provision-',dir='/work'))
        self.repo=self.root/'source';shutil.copytree(SOURCE,self.repo,ignore=shutil.ignore_patterns('.git','__pycache__'))
        for args in [('init','-q'),('config','user.name','Synthetic Fixture'),('config','user.email','fixture@example.invalid'),('add','.'),('commit','-qm','fixture')]:self.git(*args)
        self.head=self.git('rev-parse','HEAD').strip()
        for name in self.git('ls-files','-z').split('\0')[:-1]:
            (self.repo/name).write_bytes(subprocess.check_output(['git','-C',str(self.repo),'show','HEAD:'+name]))
        tree=self.git('rev-parse','HEAD^{tree}');self.git('add','.');self.assertEqual(tree,self.git('write-tree'));self.assertEqual('',self.git('status','--porcelain'))
        self.private=self.root/'private';self.private.mkdir(mode=0o700)
        self.profile=self.private/'profile.json';self.state=self.private/'state.json';self.parameters=self.private/'parameters.json';self.calls=self.private/'calls.jsonl'
        self.profile.write_text(json.dumps({'schemaVersion':1,'account':{'tenantId':TENANT,'subscriptionId':SUB,'accountType':'user','accountName':'operator@example.invalid'},'target':{'resourceId':'/subscriptions/'+SUB+'/resourceGroups/fixture/providers/Microsoft.App/jobs/runner'},'images':{'buildTag':'example.azurecr.io/runner:src-'+self.head}}))
        self.parameters.write_text(json.dumps({'$schema':'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#','contentVersion':'1.0.0.0','parameters':{'registryName':{'value':'example'}}}))
        self.native=self.private/'az-fixture'
        self.native.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
a=sys.argv[1:]
p=Path(os.environ['FIXTURE_CALLS'])
with p.open('a') as f:f.write(json.dumps(a)+'\\n')
if a[:2]==['account','show']:print(json.dumps({'id':'11111111-1111-1111-1111-111111111111','tenantId':'22222222-2222-2222-2222-222222222222','user':{'type':'user','name':os.environ.get('FIXTURE_ACCOUNT','operator@example.invalid')}}))
elif a[:3]==['deployment','group','show']:
 name=a[a.index('--name')+1]
 outputs={'acrName':{'value':'example'}}
 if '-infrastructure-' in name:
  outputs.update({'storageAccountName':{'value':'fixturestorage'},'jobName':{'value':'runner'},'runnerIdentityId':{'value':'/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/fixture/providers/Microsoft.ManagedIdentity/userAssignedIdentities/runner'}})
 print(json.dumps({'id':'/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/fixture/providers/Microsoft.Resources/deployments/'+name,'name':('wrong' if os.environ.get('FIXTURE_WRONG_DEPLOYMENT') else name),'properties':{'provisioningState':os.environ.get('FIXTURE_STATUS','Succeeded'),'outputs':outputs}}))
elif a[:3]==['deployment','group','create'] and os.environ.get('FIXTURE_FAIL'):print('PRIVATE_PROVISION_SENTINEL',file=sys.stderr);sys.exit(37)
else:print('{}')
''');self.native.chmod(0o700)

    def git(self,*args):return subprocess.check_output(['git','-C',str(self.repo),*args],text=True,stderr=subprocess.DEVNULL)
    def tearDown(self):shutil.rmtree(self.root)
    def invoke(self,*args,phase='Registry',env=None):
        child=os.environ.copy();child['FIXTURE_CALLS']=str(self.calls);child['XDG_DATA_HOME']=str(self.private/'journal-home');child.update(env or {})
        command=['pwsh','-NoProfile','-NonInteractive','-File',str(self.repo/ENTRY),'-SourceRoot',str(self.repo),'-ExpectedCommit',self.head,'-ConfigurationPath',str(self.profile),'-ConfigurationSha256',hashlib.sha256(self.profile.read_bytes()).hexdigest(),'-PrivateRoot',str(self.private),'-ParametersPath',str(self.parameters),'-ParametersSha256',hashlib.sha256(self.parameters.read_bytes()).hexdigest(),'-StatePath',str(self.state),'-Location','eastus','-Phase',phase,'-ProviderCommand',str(self.native),*args]
        result=subprocess.run(command,capture_output=True,text=True,env=child,timeout=45)
        self.assertNotIn(PRIVATE,result.stdout+result.stderr);self.assertNotIn(str(self.root),result.stdout+result.stderr)
        return result
    def call_log(self):return [json.loads(v) for v in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_preview_no_provider_or_state(self):
        result=self.invoke('-WhatIf');self.assertEqual(result.returncode,0,result.stderr);self.assertFalse(self.calls.exists());self.assertFalse(self.state.exists())
    def test_registry_bootstrap_creates_group_then_registry(self):
        result=self.invoke();self.assertEqual(result.returncode,0,result.stderr)
        calls=self.call_log();self.assertEqual([x[:3] for x in calls],[['account','show','--output'],['group','create','--subscription'],['deployment','group','create'],['deployment','group','show']])
        self.assertIn('registry.bicep',' '.join(calls[2]));self.assertIn('--no-wait',calls[2]);self.assertEqual(json.loads(result.stdout)['status'],'provisioned')
        self.assertEqual(json.loads(self.state.read_text())['status'],'completed-reconciled')
    def test_unknown_does_not_repeat_remote_write(self):
        result=self.invoke(env={'FIXTURE_STATUS':'Running'});self.assertNotEqual(result.returncode,0);count=len(self.call_log())
        second=self.invoke();self.assertNotEqual(second.returncode,0);self.assertEqual(count,len(self.call_log()))
        final=self.invoke('-Reconcile');self.assertEqual(final.returncode,0,final.stderr)
        self.assertEqual(sum(x[:3]==['deployment','group','create'] for x in self.call_log()),1)
    def test_native_failure_keeps_unknown_fence(self):
        result=self.invoke(env={'FIXTURE_FAIL':'1'});self.assertNotEqual(result.returncode,0);self.assertEqual(json.loads(self.state.read_text())['status'],'attempted-unknown')
    def test_wrong_account_before_any_write(self):
        result=self.invoke(env={'FIXTURE_ACCOUNT':'different@example.invalid'});self.assertNotEqual(result.returncode,0);self.assertEqual(len(self.call_log()),1);self.assertFalse(self.state.exists())
    def test_infrastructure_uses_full_template_without_group_recreation(self):
        profile=json.loads(self.profile.read_text());profile['images']['desiredImage']='example.azurecr.io/runner@sha256:'+'a'*64;profile['target']['managedIdentityResourceId']='/subscriptions/'+SUB+'/resourceGroups/fixture/providers/Microsoft.ManagedIdentity/userAssignedIdentities/runner';self.profile.write_text(json.dumps(profile))
        doc=json.loads(self.parameters.read_text());doc['parameters'].update({'operatorObjectId':{'value':'33333333-3333-3333-3333-333333333333'},'runnerImageRepository':{'value':'example.azurecr.io/runner'},'runnerImageDigest':{'value':'a'*64},'projectConfigPath':{'value':'project.json'},'projectConfigSha256':{'value':'b'*64},'storageAccountName':{'value':'fixturestorage'},'identityName':{'value':'runner'},'environmentName':{'value':'runner'},'jobName':{'value':'runner'},'vnetName':{'value':'runner'},'subnetName':{'value':'runner'},'natGatewayName':{'value':'runner'},'publicIpName':{'value':'runner'}});self.parameters.write_text(json.dumps(doc))
        result=self.invoke(phase='Infrastructure');self.assertEqual(result.returncode,0,result.stderr);self.assertFalse(any(c[:2]==['group','create'] for c in self.call_log()));self.assertIn('main.bicep',' '.join(next(c for c in self.call_log() if c[:3]==['deployment','group','create'])))
    def test_wrong_registry_parameters_denied_before_provider(self):
        doc=json.loads(self.parameters.read_text());doc['parameters']['registryName']['value']='different';self.parameters.write_text(json.dumps(doc));self.assertNotEqual(self.invoke().returncode,0);self.assertFalse(self.calls.exists())
    def test_inline_secret_reference_denied_before_provider(self):
        doc=json.loads(self.parameters.read_text());doc['parameters']['password']={'value':PRIVATE};self.parameters.write_text(json.dumps(doc));self.assertNotEqual(self.invoke().returncode,0);self.assertFalse(self.calls.exists())


if __name__=='__main__':unittest.main(verbosity=2)


class ProvisionCausality(RunnerProvision):
    def test_wrong_deployment_readback_is_not_success(self):
        result=self.invoke(env={'FIXTURE_WRONG_DEPLOYMENT':'1'})
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(json.loads(self.state.read_text())['status'],'attempted-unknown')

    def test_completed_outputs_retained_only_in_private_receipt(self):
        result=self.invoke();self.assertEqual(result.returncode,0,result.stderr)
        state=json.loads(self.state.read_text());self.assertEqual(state['outputs']['acrName']['value'],'example')
        self.assertNotIn('acrName',result.stdout)
