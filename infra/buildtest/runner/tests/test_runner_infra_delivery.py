"""Infrastructure delivery regressions; offline fixtures, no Azure access."""
import hashlib
import json
import os
import subprocess
import unittest
from test_runner_provision import RunnerProvision, SUB


class InfrastructureDelivery(RunnerProvision):
    def test_registry_wrong_output_rejected(self):
        text = self.native.read_text()
        self.native.write_text(text.replace("'value':'example'", "'value':'wrong'"))
        result = self.invoke()
        self.assertNotEqual(0, result.returncode)
        self.assertEqual('attempted-unknown', json.loads(self.state.read_text())['status'])

    def test_validate_only_has_no_create_calls_or_receipt(self):
        result = self.invoke('-ValidateOnly')
        self.assertEqual(0, result.returncode, result.stderr)
        calls = self.call_log()
        self.assertTrue(any(c[:3] == ['deployment', 'group', 'validate'] for c in calls))
        self.assertFalse(any('create' in c for c in calls))
        self.assertFalse(self.state.exists())


class RegistryImageBuild(RunnerProvision):
    def setUp(self):
        super().setUp()
        self.build = self.repo / 'scripts/repo/Invoke-RunnerRegistryBuild.ps1'
        self.native.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]; root=Path(__file__).parent
with (root/'calls.jsonl').open('a') as f:f.write(json.dumps(args)+'\\n')
if args[:2]==['account','show']:
 print(json.dumps({'id':'11111111-1111-1111-1111-111111111111','tenantId':'22222222-2222-2222-2222-222222222222','user':{'type':'user','name':os.getenv('FIXTURE_ACCOUNT','operator@example.invalid')}}))
elif args[:2]==['acr','build']:
 dockerfile=Path(args[args.index('--file')+1])
 if not dockerfile.is_absolute() or not dockerfile.is_file() or dockerfile.parent!=Path(args[-1]):sys.exit(52)
 (root/'submitted').write_text(os.environ['SOURCE_COMMIT']); print(json.dumps({'runId':'build123'}))
elif args[:3]==['acr','task','show-run']:
 tag='src-'+os.environ['SOURCE_COMMIT']
 print(json.dumps({'runId':'build123','status':os.getenv('BUILD_STATUS','Succeeded'),'outputImages':[{'registry':'example.azurecr.io','repository':'runner','tag':tag,'digest':'sha256:'+'a'*64}]}))
elif args[:3]==['acr','repository','list']:
 print(json.dumps([] if os.getenv('NEW_REGISTRY') and not (root/'submitted').exists() else ['runner']))
elif args[:3]==['acr','repository','show-tags']:
 if os.getenv('NEW_REGISTRY') and not (root/'submitted').exists():sys.exit(44)
 print(json.dumps(['src-'+((root/'submitted').read_text() if (root/'submitted').exists() else os.environ['SOURCE_COMMIT'])] if (root/'submitted').exists() or os.getenv('TAG_EXISTS') else []))
elif args[:3]==['acr','manifest','show-metadata']:
 print(json.dumps({'name':'src-'+os.environ['SOURCE_COMMIT'],'digest':'sha256:'+('b' if os.getenv('DIGEST_WRONG') else 'a')*64}))
else:sys.exit(51)
''')
        self.native.chmod(0o700)

    def invoke_build(self, *extra, **environment):
        env = dict(os.environ, SOURCE_COMMIT=self.head, XDG_DATA_HOME=str(self.private/'journal-home'), **environment)
        cmd = ['pwsh','-NoProfile','-NonInteractive','-File',str(self.build),'-SourceRoot',str(self.repo),'-ExpectedCommit',self.head,'-ConfigurationPath',str(self.profile),'-ConfigurationSha256',hashlib.sha256(self.profile.read_bytes()).hexdigest(),'-PrivateRoot',str(self.private),'-StatePath',str(self.state),'-ProviderCommand',str(self.native),*extra]
        result = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=40)
        self.assertNotIn(str(self.root), result.stdout+result.stderr)
        self.assertNotIn('operator@example.invalid', result.stdout+result.stderr)
        return result

    def test_preview_no_side_effects(self):
        result=self.invoke_build('-WhatIf')
        self.assertEqual(0,result.returncode,result.stderr)
        self.assertFalse(self.calls.exists());self.assertFalse(self.state.exists())

    def test_build_publishes_and_reads_exact_digest(self):
        result=self.invoke_build()
        self.assertEqual(0,result.returncode,result.stderr)
        self.assertEqual('image-published',json.loads(result.stdout)['status'])
        state=json.loads(self.state.read_text())
        self.assertEqual('example.azurecr.io/runner@sha256:'+'a'*64,state['image'])
        self.assertEqual(1,sum(c[:2]==['acr','build'] for c in self.call_log()))
        self.assertNotEqual(0,self.invoke_build().returncode)

    def test_build_uses_context_dockerfile_from_unrelated_directory(self):
        self.assertNotEqual(self.repo / 'infra/buildtest/runner', __import__('pathlib').Path.cwd())
        result = self.invoke_build()
        self.assertEqual(0, result.returncode, result.stderr)
        call = next(c for c in self.call_log() if c[:2] == ['acr', 'build'])
        self.assertEqual(str(self.repo / 'infra/buildtest/runner/Dockerfile'), call[call.index('--file') + 1])

    def test_running_build_requires_reconcile_not_rebuild(self):
        result=self.invoke_build(BUILD_STATUS='Running')
        self.assertNotEqual(0,result.returncode)
        self.assertEqual('build123',json.loads(self.state.read_text())['runId'])
        self.assertNotEqual(0,self.invoke_build().returncode)
        self.assertEqual(0,self.invoke_build('-Reconcile').returncode)
        self.assertEqual(1,sum(c[:2]==['acr','build'] for c in self.call_log()))

    def test_wrong_digest_is_not_publication_success(self):
        result=self.invoke_build(DIGEST_WRONG='1')
        self.assertNotEqual(0,result.returncode)
        self.assertEqual('attempted-unknown',json.loads(self.state.read_text())['status'])

    def test_existing_tag_cannot_be_overwritten(self):
        result=self.invoke_build(TAG_EXISTS='1')
        self.assertNotEqual(0,result.returncode)
        self.assertFalse(any(c[:2]==['acr','build'] for c in self.call_log()))

    def test_fresh_registry_without_repository_builds(self):
        result=self.invoke_build(NEW_REGISTRY='1')
        self.assertEqual(0,result.returncode,result.stderr)
        self.assertEqual(1,sum(c[:2]==['acr','build'] for c in self.call_log()))

    def test_wrong_account_before_build(self):
        result=self.invoke_build(FIXTURE_ACCOUNT='other@example.invalid')
        self.assertNotEqual(0,result.returncode)
        self.assertFalse(any(c[:2]==['acr','build'] for c in self.call_log()))


class SubsequentUpdates(RegistryImageBuild):
    def new_candidate(self):
        (self.repo/'infra-update-note.txt').write_text('new source version')
        self.git('add','--force','infra-update-note.txt');self.git('commit','-qm','new fixture version')
        self.head=self.git('rev-parse','HEAD').strip()
        profile=json.loads(self.profile.read_text());profile['images']['buildTag']='example.azurecr.io/runner:src-'+self.head;self.profile.write_text(json.dumps(profile))
        self.state=self.private/'next-build.json'

    def test_next_image_version_after_success_allowed(self):
        self.assertEqual(0,self.invoke_build().returncode)
        self.new_candidate()
        self.assertEqual(0,self.invoke_build().returncode)
        self.assertEqual(2,sum(c[:2]==['acr','build'] for c in self.call_log()))

    def test_new_source_cannot_bypass_unknown_build(self):
        self.assertNotEqual(0,self.invoke_build(BUILD_STATUS='Running').returncode)
        self.new_candidate()
        self.assertNotEqual(0,self.invoke_build().returncode)
        self.assertEqual(1,sum(c[:2]==['acr','build'] for c in self.call_log()))


class InfrastructureUpdates(RunnerProvision):
    def test_existing_subnet_security_group_is_preserved(self):
        profile = json.loads(self.profile.read_text())
        profile['images']['desiredImage'] = 'example.azurecr.io/runner@sha256:' + 'a'*64
        profile['target']['managedIdentityResourceId'] = '/subscriptions/'+SUB+'/resourceGroups/fixture/providers/Microsoft.ManagedIdentity/userAssignedIdentities/runner'
        self.profile.write_text(json.dumps(profile))
        values = {'operatorObjectId':'33333333-3333-3333-3333-333333333333','runnerImageRepository':'example.azurecr.io/runner','runnerImageDigest':'a'*64,'projectConfigPath':'project.json','projectConfigSha256':'b'*64,'storageAccountName':'fixturestorage','identityName':'runner','environmentName':'runner','jobName':'runner','vnetName':'runner','subnetName':'runner','natGatewayName':'runner','publicIpName':'runner','subnetNetworkSecurityGroupId':'/subscriptions/'+SUB+'/resourceGroups/fixture/providers/Microsoft.Network/networkSecurityGroups/runner'}
        doc = json.loads(self.parameters.read_text())
        doc['parameters'].update({k:{'value':v} for k,v in values.items()})
        self.parameters.write_text(json.dumps(doc))
        result = self.invoke(phase='Infrastructure')
        self.assertEqual(0, result.returncode, result.stderr)
        for name in ['main.bicep', 'network.bicep']:
            text = (self.repo/'infra/buildtest'/name).read_text()
            self.assertIn('param subnetNetworkSecurityGroupId string', text)
            self.assertIn('id: subnetNetworkSecurityGroupId', text)

    def test_explicit_location_passed_to_template(self):
        result=self.invoke();self.assertEqual(0,result.returncode,result.stderr)
        create=next(c for c in self.call_log() if c[:3]==['deployment','group','create'])
        self.assertIn('location=eastus',create)

    def test_next_parameters_after_success_allowed(self):
        self.assertEqual(0,self.invoke().returncode)
        profile=json.loads(self.profile.read_text());profile['images']['buildTag']='changed.azurecr.io/runner:src-'+self.head;self.profile.write_text(json.dumps(profile))
        params=json.loads(self.parameters.read_text());params['parameters']['registryName']['value']='changed';self.parameters.write_text(json.dumps(params))
        self.native.write_text(self.native.read_text().replace("'value':'example'","'value':'changed'"))
        self.state=self.private/'next-provision.json'
        result=self.invoke();self.assertEqual(0,result.returncode,result.stderr)
        self.assertEqual(2,sum(c[:3]==['deployment','group','create'] for c in self.call_log()))

    def test_new_parameters_cannot_bypass_unknown_provision(self):
        self.assertNotEqual(0,self.invoke(env={'FIXTURE_STATUS':'Running'}).returncode)
        self.state=self.private/'next-provision.json'
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertEqual(1,sum(c[:3]==['deployment','group','create'] for c in self.call_log()))
