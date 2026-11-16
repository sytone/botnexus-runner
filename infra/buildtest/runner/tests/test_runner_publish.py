"""Synthetic publisher boundaries. Execute only inside authorized offline container."""
import copy
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[4]
ENTRY = Path('scripts/repo/Publish-RunnerImage.ps1')
SECRET = 'PRIVATE_PUBLISH_SENTINEL_5162'
ID = 'b' * 64
DIGEST = 'sha256:' + 'a' * 64


class RunnerPublish(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='operations-publish-', dir='/work'))
        self.repo = self.root / 'source'
        shutil.copytree(SOURCE, self.repo, ignore=shutil.ignore_patterns('.git', '__pycache__'))
        # Inert-only source-copy seam: remove ONLY the unconditional native denial call.
        # Never a production parameter/env flag. Actual entrypoint test keeps exact bytes.
        self.production_entry = self._testMethodName == 'test_actual_entrypoint_native_selection_unqualified_denied'
        if not self.production_entry:
            entry = self.repo / ENTRY
            text = entry.read_text()
            seam = '\n    Assert-RunnerPublishNativeSelection\n    $clock = [Diagnostics.Stopwatch]::StartNew()'
            if seam in text:
                self.assertEqual(1, text.count(seam))
                entry.write_text(text.replace(seam, '\n    # Inert fixture only: native selection denial removed.\n    $clock = [Diagnostics.Stopwatch]::StartNew()'))
        for args in [('init','-q'),('config','user.name','Synthetic'),('config','user.email','fixture@example.invalid'),('add','.'),('commit','-qm','fixture')]:
            subprocess.check_call(['git','-C',str(self.repo),*args],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        # Refresh synthetic index after raw-byte restoration below.
        self.head = subprocess.check_output(['git','-C',str(self.repo),'rev-parse','HEAD'],text=True).strip()
        for name in subprocess.check_output(['git','-C',str(self.repo),'ls-files','-z'],text=True).split('\0')[:-1]:
            (self.repo/name).write_bytes(subprocess.check_output(['git','-C',str(self.repo),'show','HEAD:'+name]))
        subprocess.check_call(['git','-C',str(self.repo),'add','.'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        self.tag = 'example.azurecr.io/runner:src-' + self.head
        self.profile = self.root / 'target.json'
        self.target = {'schemaVersion':1,'account':{'tenantId':'22222222-2222-2222-2222-222222222222','subscriptionId':'11111111-1111-1111-1111-111111111111','accountType':'user','accountName':SECRET+'@example.invalid'},'target':{'resourceId':'/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/fixture/providers/Microsoft.App/jobs/runner'},'images':{'buildTag':self.tag}}
        self.profile.write_text(json.dumps(self.target))
        self.evidence = self.root/'qualification.json'; self.evidence.write_text('{"syntheticOnly":true}')
        self.auth = self.root/'existing-auth.json'; self.auth.write_text(json.dumps({'auths':{'example.azurecr.io':{'auth':base64.b64encode((SECRET+':synthetic:password').encode()).decode()}}})); self.auth.chmod(0o600)
        self.approval = self.root/'approval.json'
        self.qualified = {'approved':True,'revoked':False,'sourceCommit':self.head,'imageTag':self.tag,'localImageId':ID,'manifestDigest':DIGEST,'runtimeManifestSha256':hashlib.sha256((self.repo/'infra/buildtest/runner/image-runtime.json').read_bytes()).hexdigest(),'evidenceSha256':self.hash(self.evidence)}
        self.approval.write_text(json.dumps(self.qualified))
        self.state = self.root/'receipt.json'
        self.tool = self.root/'native'
        self.tool.write_text('''#!/usr/bin/env python3
import os,sys,json
from pathlib import Path
r=Path(__file__).parent;a=sys.argv[1:];mode=os.getenv('PUBLISH_MODE','success')
with (r/'calls').open('a') as f:f.write(json.dumps(a)+'\\n')
print('PRIVATE_PUBLISH_SENTINEL_5162',file=sys.stderr)
if a[:2]==['image','inspect']:
 value={'Id':'b'*64,'Digest':'sha256:'+'a'*64,'Config':{'Labels':{'org.opencontainers.image.revision':json.loads((r/'approval.json').read_text())['sourceCommit']}}}
 if mode=='localid':value['Id']='c'*64
 if mode=='revision':value['Config']['Labels']['org.opencontainers.image.revision']='0'*40
 if mode=='localdigest':value['Digest']='sha256:'+'d'*64
 if mode=='authbeforedrift':(r/'existing-auth.json').write_text('{}')
 if mode=='localnull':value=None
 print(json.dumps(value));sys.exit(0)
if a[:2]==['account','show']:
 value={'id':'11111111-1111-1111-1111-111111111111','tenantId':'22222222-2222-2222-2222-222222222222','user':{'type':'user','name':'PRIVATE_PUBLISH_SENTINEL_5162@example.invalid'}}
 if mode=='account':value['user']['name']='other@example.invalid'
 if mode=='profiledrift':(r/'target.json').write_text('{}')
 print(json.dumps(value));sys.exit(0)
if a[0]=='push':
 assert '--retry=0' in a and '--tls-verify=true' in a and '--authfile' in a
 assert a[-2]=='b'*64 and a[-1].startswith('docker://example.azurecr.io/runner:src-')
 assert list((r/'home').rglob('*.publish.json'))
 (r/'remote').write_text('present')
 if mode=='revoke':
  d=json.loads((r/'approval.json').read_text());d['revoked']=True;(r/'approval.json').write_text(json.dumps(d))
 if mode=='authpushdrift':(r/'existing-auth.json').write_text('{}')
 if mode in ['lost','failure']:sys.exit(9)
 print('PRIVATE_PUBLISH_SENTINEL_5162');sys.exit(0)
assert a[:3]==['acr','manifest','show-metadata']
assert '--subscription' in a and a[a.index('--registry')+1]=='example'
q=a[a.index('--name')+1];digest='sha256:'+'a'*64
countfile=r/'reads';count=int(countfile.read_text())+1 if countfile.exists() else 1;countfile.write_text(str(count))
if mode=='authreadbackdrift' and count==3:(r/'existing-auth.json').write_text('{}')
if mode=='finalrace' and count==3:digest='sha256:'+'f'*64
if mode=='wrongdigest':digest='sha256:'+'e'*64
if mode=='malformed':print('{PRIVATE_PUBLISH_SENTINEL_5162');sys.exit(0)
if mode=='null':print('null');sys.exit(0)
if '@' in q:
 assert q=='runner@sha256:'+'a'*64
 value={'digest':digest,'tags':[json.loads((r/'approval.json').read_text())['imageTag'].split(':')[-1]]}
else:
 assert q.startswith('runner:src-');value={'digest':digest,'name':q.split(':')[-1]}
 if mode=='tagrace':value['name']='other'
if mode=='manifestnull' and '@' in q:value['tags']=None
if mode=='manifestwrongtag' and '@' in q:value['tags']=['other']
if mode=='duplicate':print('{"digest":"'+digest+'","digest":"'+digest+'"}');sys.exit(0)
print(json.dumps(value))
''')
        self.tool.chmod(0o700)

    def tearDown(self):
        shutil.rmtree(self.root)

    def hash(self, path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def calls(self):
        return [json.loads(l) for l in (self.root/'calls').read_text().splitlines()] if (self.root/'calls').exists() else []

    def invoke(self, *extra, mode='success', profile_hash=None, approval_hash=None, private_root=None, auth_hash=None):
        env=dict(os.environ,XDG_DATA_HOME=str(self.root/'home'),PUBLISH_MODE=mode)
        command=['pwsh','-NoProfile','-File',str(self.repo/ENTRY),'-SourceRoot',str(self.repo),'-ExpectedCommit',self.head,'-ConfigurationPath',str(self.profile),'-ConfigurationSha256',profile_hash or (self.hash(self.profile) if self.profile.exists() else 'a'*64),'-PrivateRoot',str(private_root or self.root),'-ApprovalPath',str(self.approval),'-ApprovalSha256',approval_hash or self.hash(self.approval),'-QualificationEvidencePath',str(self.evidence),'-RegistryAuthFile',str(self.auth),'-RegistryAuthFileSha256',auth_hash or self.hash(self.auth),'-StatePath',str(self.state),'-ContainerCommand',str(self.tool),'-ProviderCommand',str(self.tool),*extra]
        # Same-process environment check includes empty/absent variables for preview and failures.
        wrapper="$env:PUBLISH_EMPTY=''; Remove-Item Env:PUBLISH_ABSENT -ErrorAction SilentlyContinue; $before=@{}; Get-ChildItem Env: | ForEach-Object { $before[$_.Name]=$_.Value }; try { $entry=$args[0]; $parameters=@{}; for ($i=1; $i -lt $args.Count; $i++) { $name=$args[$i].TrimStart([char]45); if ($name -in @('WhatIf','Reconcile')) { $parameters[$name]=$true } else { $i++; $parameters[$name]=$args[$i] } }; & $entry @parameters; $nativeExit=$LASTEXITCODE } finally { $after=@{}; Get-ChildItem Env: | ForEach-Object { $after[$_.Name]=$_.Value }; if (($before | ConvertTo-Json -Compress) -cne ($after | ConvertTo-Json -Compress)) { [Console]::Error.WriteLine('Environment changed'); exit 7 } }; exit $nativeExit"
        command=['pwsh','-NoProfile','-CommandWithArgs',wrapper]+command[3:]
        p=subprocess.run(command,capture_output=True,text=True,env=env,timeout=40)
        for private in [SECRET,str(self.root),self.tag,ID,DIGEST]:self.assertNotIn(private,p.stdout+p.stderr)
        if self.auth.exists():
            for private in [self.auth.read_text(errors='replace'),base64.b64encode((SECRET+':synthetic:password').encode()).decode()]:
                if private: self.assertNotIn(private,p.stdout+p.stderr)
        return p

    def test_qualified_push_exact_readback_and_repeat_denied(self):
        p=self.invoke();self.assertEqual(0,p.returncode,p.stderr)
        public=json.loads(p.stdout);self.assertEqual('published',public['status']);self.assertIsNone(public['tests']);self.assertFalse(public['accepted'])
        self.assertEqual(1,sum(c[0]=='push' for c in self.calls()))
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertEqual(1,sum(c[0]=='push' for c in self.calls()))
        self.assertEqual('completed-reconciled',json.loads(self.state.read_text())['status'])

    def test_preview_zero_native_files_environment(self):
        before={str(p):p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        p=self.invoke('-WhatIf');self.assertEqual(0,p.returncode,p.stderr)
        self.assertEqual([],self.calls());self.assertEqual(before,{str(p):p.read_bytes() for p in self.root.rglob('*') if p.is_file()})
        self.assertFalse((self.root/'home').exists())

    def test_unqualified_revoked_source_image_and_hash_denials(self):
        original=copy.deepcopy(self.qualified)
        for field,value in [('approved',False),('revoked',True),('sourceCommit','0'*40),('imageTag','example.azurecr.io/other:src-'+self.head),('localImageId','bad'),('runtimeManifestSha256','0'*64),('evidenceSha256','0'*64),('unknown',SECRET)]:
            with self.subTest(field=field):
                document=dict(original);document[field]=value;self.approval.write_text(json.dumps(document))
                self.assertNotEqual(0,self.invoke().returncode);self.assertEqual([],self.calls());self.assertFalse(self.state.exists())
        self.approval.write_text(json.dumps(original))
        self.assertNotEqual(0,self.invoke(profile_hash='0'*64).returncode)
        self.assertNotEqual(0,self.invoke(approval_hash='0'*64).returncode)
        self.assertEqual([],self.calls())

    def test_local_image_and_account_denials_no_push(self):
        for mode in ['localid','revision','localdigest','localnull','account']:
            with self.subTest(mode=mode):
                self.assertNotEqual(0,self.invoke(mode=mode).returncode)
                self.assertFalse(any(c[0]=='push' for c in self.calls()));self.assertFalse(self.state.exists())

    def test_lost_response_unknown_reconcile_readonly(self):
        self.assertNotEqual(0,self.invoke(mode='lost').returncode)
        self.assertEqual('attempted-unknown',json.loads(self.state.read_text())['status'])
        original=self.state;self.state=self.root/'alternate.json'
        self.assertNotEqual(0,self.invoke().returncode);self.assertFalse(self.state.exists());self.state=original
        self.assertEqual(0,self.invoke('-Reconcile').returncode)
        self.assertEqual(1,sum(c[0]=='push' for c in self.calls()))
        self.assertEqual(1,sum(c[:2]==['image','inspect'] for c in self.calls()))

    def test_wrong_digest_tag_race_malformed_null_duplicate_keep_unknown(self):
        for mode in ['wrongdigest','tagrace','malformed','null','duplicate','finalrace','manifestnull','manifestwrongtag']:
            with self.subTest(mode=mode):
                # Separate operator-data fixture per independent negative, no production replay bypass.
                (self.root/'reads').unlink(missing_ok=True)
                self.state=self.root/('receipt-'+mode+'.json')
                envhome=self.root/'home';saved=self.root/('saved-'+mode)
                if envhome.exists():envhome.rename(saved)
                self.assertNotEqual(0,self.invoke(mode=mode).returncode)
                self.assertTrue(self.state.exists());self.assertEqual('attempted-unknown',json.loads(self.state.read_text())['status'])
        self.assertEqual(8,sum(c[0]=='push' for c in self.calls()))

    def test_invalid_missing_duplicate_profile_denied(self):
        valid=self.profile.read_bytes()
        for raw in [b'{}',b'null',b'{bad',valid[:-1]+b',"schemaVersion":1}']:
            with self.subTest(rawlen=len(raw)):
                self.profile.write_bytes(raw);self.assertNotEqual(0,self.invoke().returncode);self.assertEqual([],self.calls())
        self.profile.unlink();self.assertNotEqual(0,self.invoke().returncode);self.assertEqual([],self.calls())

    def test_native_failure_keeps_unknown_and_reconcile_mismatch_no_push(self):
        p=self.invoke(mode='failure');self.assertNotEqual(0,p.returncode)
        self.assertIn('unknown',p.stderr)
        self.assertEqual('attempted-unknown',json.loads(self.state.read_text())['status'])
        self.assertNotEqual(0,self.invoke('-Reconcile',mode='wrongdigest').returncode)
        self.assertEqual(1,sum(c[0]=='push' for c in self.calls()))
        self.assertEqual('attempted-unknown',json.loads(self.state.read_text())['status'])

    def test_revoke_during_push_prevents_success_and_replay(self):
        self.assertNotEqual(0,self.invoke(mode='revoke').returncode)
        self.assertEqual('attempted-unknown',json.loads(self.state.read_text())['status'])
        self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
        self.assertEqual(1,sum(c[0]=='push' for c in self.calls()))

    def test_profile_drift_before_push_denied(self):
        self.assertNotEqual(0,self.invoke(mode='profiledrift').returncode)
        self.assertFalse(any(c[0]=='push' for c in self.calls()))
        self.assertFalse(self.state.exists())

    def test_dirty_source_and_missing_qualification_denied(self):
        (self.repo/'README.md').write_text('dirty')
        self.assertNotEqual(0,self.invoke().returncode)
        self.assertEqual([],self.calls())
        self.assertFalse(self.state.exists())
        self.evidence.unlink()
        self.assertNotEqual(0,self.invoke('-WhatIf').returncode)
        self.assertEqual([],self.calls())

    def test_linux_case_sibling_private_artifacts_denied_before_native(self):
        private = self.root / 'private'
        sibling = self.root / 'PRIVATE'
        private.mkdir(); sibling.mkdir()
        for attribute in ['profile', 'approval', 'evidence', 'auth']:
            source = getattr(self, attribute)
            target = private / source.name
            shutil.move(source, target); setattr(self, attribute, target)
        self.state = private / 'receipt.json'
        for attribute in ['approval', 'evidence', 'auth', 'state']:
            with self.subTest(attribute=attribute):
                original = getattr(self, attribute)
                other = sibling / original.name
                if attribute != 'state': shutil.copyfile(original, other)
                setattr(self, attribute, other)
                p = self.invoke('-WhatIf', private_root=private)
                self.assertNotEqual(0, p.returncode)
                self.assertEqual([], self.calls())
                self.assertFalse(self.state.exists())
                self.assertNotEqual(0, self.invoke(private_root=private).returncode)
                self.assertEqual([], self.calls())
                setattr(self, attribute, original)

    def test_nested_git_private_artifacts_denied_before_native(self):
        nested = self.root / 'nested'
        nested.mkdir(); (nested / '.git').write_text('gitdir: synthetic-only')
        for attribute in ['approval', 'evidence', 'auth', 'state']:
            with self.subTest(attribute=attribute):
                original = getattr(self, attribute)
                other = nested / original.name
                if attribute != 'state': shutil.copyfile(original, other)
                setattr(self, attribute, other)
                p = self.invoke('-WhatIf')
                self.assertNotEqual(0, p.returncode)
                self.assertEqual([], self.calls())
                self.assertFalse(self.state.exists())
                self.assertNotEqual(0, self.invoke().returncode)
                self.assertEqual([], self.calls())
                setattr(self, attribute, original)

    def test_private_artifact_alias_links_special_missing_hash_denied(self):
        original = self.approval
        for attribute in ['approval', 'evidence', 'auth']:
            with self.subTest(attribute=attribute):
                saved = getattr(self, attribute)
                alias = self.root / ('alias-' + attribute)
                alias.symlink_to(saved)
                setattr(self, attribute, alias)
                self.assertNotEqual(0, self.invoke('-WhatIf').returncode)
                self.assertEqual([], self.calls())
                setattr(self, attribute, saved)
        self.approval = self.evidence
        self.assertNotEqual(0, self.invoke('-WhatIf').returncode)
        self.approval = original
        self.assertNotEqual(0, self.invoke('-WhatIf', approval_hash='bad').returncode)
        fifo = self.root / 'receipt-fifo'; os.mkfifo(fifo, 0o600)
        self.state = fifo
        self.assertNotEqual(0, self.invoke('-WhatIf').returncode)
        self.assertEqual([], self.calls())

    def test_four_guide_examples_bind_actual_named_parameters(self):
        output = self.root / 'binding-proof.json'
        p = subprocess.run(['pwsh','-NoProfile','-File',str(self.repo/'infra/buildtest/runner/tests/Test-RunnerMaintenanceBinding.ps1'),
                            '-SourceRoot',str(self.repo),'-OutputPath',str(output)], capture_output=True,text=True,timeout=20)
        self.assertEqual(0,p.returncode,p.stderr)
        proof = json.loads(output.read_text())
        self.assertEqual(4,len(proof))
        for record in proof:
            self.assertEqual('/synthetic/source',record['bound']['SourceRoot'])
            self.assertEqual('c'*40,record['bound']['ExpectedCommit'])
            self.assertEqual('/synthetic/private/target.json',record['bound']['ConfigurationPath'])
            self.assertTrue(record['bound']['WhatIf'])
        self.assertEqual([],self.calls())


    def test_actual_entrypoint_native_selection_unqualified_denied(self):
        before={str(p):p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        p=self.invoke()
        self.assertNotEqual(0,p.returncode)
        self.assertEqual([],self.calls())
        self.assertFalse(self.state.exists())
        self.assertFalse((self.root/'home').exists())
        self.assertEqual(before,{str(p):p.read_bytes() for p in self.root.rglob('*') if p.is_file()})
        self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
        self.assertEqual([],self.calls());self.assertFalse((self.root/'home').exists())

    def test_auth_schema_encoding_alias_and_helper_denials(self):
        good=base64.b64encode(b'user:password:later-colon').decode()
        host='example.azurecr.io'
        records=[b'\xff', b'', b' '*4097, b'null', b'[]', b'{bad', ('{"'+SECRET+'":').encode(), b'{"auths":{}} trailing',
                 b'{"auths":{},"AUTHS":{}}', b'{"auths":{"example.azurecr.io":{"auth":"x","AUTH":"y"}}}',
                 json.dumps({SECRET:True}).encode()]
        records += [json.dumps(v).encode() for v in [
            {'syntheticOnly':True}, {'auths':None}, {'auths':{}}, {'auths':[]},
            {'auths':{host:{'auth':good}},'credHelpers':{}},
            {'auths':{host:{'auth':good}},'credsStore':''},
            {'auths':{host:{'auth':good,'identitytoken':SECRET}}},
            {'auths':{host:{'auth':good,'registrytoken':SECRET}}},
            {'auths':{host:{'auth':good,'username':SECRET}}},
            {'auths':{host:{'auth':good,'unknown':SECRET}}},
            {'auths':{host:{'auth':None}}}, {'auths':{host:{'auth':42}}},
            {'auths':{host:{'auth':good},'other.azurecr.io':{'auth':good}}}]]
        for key in ['EXAMPLE.azurecr.io','https://'+host,host+'/',host+':443',host+'/runner',host+':tag',host+'@sha256:abc','*']:
            records.append(json.dumps({'auths':{key:{'auth':good}}}).encode())
        for value in ['', '???',good+' ',good.rstrip('='),'dXNlcjpwYXNzd29yZDp4====',
                      *[base64.b64encode(v).decode() for v in [b'nocolon',b':password',b'user:',b'user:   ',b'user:p\x00',b'user:p\n',b'user:\xff',b' user:pass']]]:
            records.append(json.dumps({'auths':{host:{'auth':value}}}).encode())
        for raw in records:
            with self.subTest(case=records.index(raw)):
                self.auth.write_bytes(raw)
                before={str(p):p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
                p=self.invoke('-WhatIf')
                self.assertNotEqual(0,p.returncode)
                self.assertEqual([],self.calls());self.assertFalse(self.state.exists())
                self.assertFalse((self.root/'home').exists())
                self.assertEqual(before,{str(p):p.read_bytes() for p in self.root.rglob('*') if p.is_file()})

    def test_auth_private_permissions_and_hardlink_denied(self):
        self.assertNotEqual(0,self.invoke('-WhatIf',auth_hash='0'*64).returncode)
        self.assertEqual([],self.calls())
        self.root.chmod(0o755)
        self.assertNotEqual(0,self.invoke('-WhatIf').returncode)
        self.assertEqual([],self.calls());self.root.chmod(0o700)
        self.auth.chmod(0o644)
        self.assertNotEqual(0,self.invoke('-WhatIf').returncode)
        self.assertEqual([],self.calls())
        self.auth.chmod(0o600)
        link=self.root/'hardlink-auth';os.link(self.auth,link)
        self.assertNotEqual(0,self.invoke('-WhatIf').returncode)
        self.assertEqual([],self.calls())

    def test_auth_binding_original_journal_receipt_and_drift_unknown(self):
        self.assertNotEqual(0,self.invoke(mode='lost').returncode)
        journal=next((self.root/'home').rglob('*.publish.json'))
        prior=json.loads(journal.read_text());receipt=json.loads(self.state.read_text())
        for key,value in {'authContractVersion':1,'authFilePath':str(self.auth),'authFileSha256':self.hash(self.auth),'authRegistryHost':'example.azurecr.io','authRegistryKey':'example.azurecr.io'}.items():
            self.assertEqual(value,prior[key]);self.assertEqual(value,receipt[key])
        self.assertNotIn(SECRET,self.state.read_text())
        self.assertNotIn(base64.b64encode((SECRET+':synthetic:password').encode()).decode(),self.state.read_text())
        alias=self.root/'other-auth.json';alias.write_bytes(self.auth.read_bytes());alias.chmod(0o600)
        selected=self.auth;self.auth=alias
        self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
        self.auth=selected
        original=self.auth.read_bytes()
        self.auth.write_text(json.dumps({'auths':{'example.azurecr.io':{'auth':base64.b64encode(b'other:password').decode()}}}))
        self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
        self.assertEqual('attempted-unknown',json.loads(self.state.read_text())['status'])
        self.auth.write_bytes(original)
        for key in ['authContractVersion','authFilePath','authFileSha256','authRegistryHost','authRegistryKey']:
            with self.subTest(key=key):
                old=dict(prior);old.pop(key);journal.write_text(json.dumps(old))
                self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
                self.assertEqual(old,json.loads(journal.read_text()))
                journal.write_text(json.dumps(prior))
                changed=dict(receipt);changed[key]='mismatch';self.state.write_text(json.dumps(changed))
                self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
                self.assertEqual(changed,json.loads(self.state.read_text()))
                self.state.write_text(json.dumps(receipt))
        for invalid in ['1',True,1.0,[],{}]:
            with self.subTest(versionType=type(invalid).__name__):
                changed=dict(prior);changed['authContractVersion']=invalid
                journal.write_text(json.dumps(changed))
                self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
                self.assertEqual(changed,json.loads(journal.read_text()))
                journal.write_text(json.dumps(prior))
        self.assertEqual(1,sum(c[0]=='push' for c in self.calls()))
        self.assertEqual(1,sum(c[:2]==['image','inspect'] for c in self.calls()))
        self.assertEqual(0,self.invoke('-Reconcile').returncode)

    def test_auth_drift_before_push_denied_without_journal(self):
        self.assertNotEqual(0,self.invoke(mode='authbeforedrift').returncode)
        self.assertFalse(any(c[0]=='push' for c in self.calls()))
        self.assertFalse(self.state.exists())
        self.assertFalse(list((self.root/'home').rglob('*.publish.json')))

    def test_auth_drift_during_push_and_readback_retains_unknown(self):
        valid=self.auth.read_bytes()
        for mode in ['authpushdrift','authreadbackdrift']:
            with self.subTest(mode=mode):
                self.auth.write_bytes(valid)
                self.state=self.root/('receipt-'+mode+'.json')
                home=self.root/'home'
                if home.exists():home.rename(self.root/('saved-'+mode))
                (self.root/'reads').unlink(missing_ok=True)
                self.assertNotEqual(0,self.invoke(mode=mode).returncode)
                self.assertEqual('attempted-unknown',json.loads(self.state.read_text())['status'])
                journal=next(home.rglob('*.publish.json'))
                self.assertEqual('attempted-unknown',json.loads(journal.read_text())['status'])
                self.assertNotEqual(0,self.invoke('-Reconcile').returncode)
        self.assertEqual(2,sum(c[0]=='push' for c in self.calls()))

if __name__=='__main__':unittest.main(verbosity=2)
