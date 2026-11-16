<#
.SYNOPSIS
Exercises the private response transport without network or real credentials.
.DESCRIPTION
Uses an in-memory .NET handler and an inert CLI executable. Every assertion calls
actual transport code. Emits only named outcomes, never private response values.
.PARAMETER SourceRoot
Exact candidate source root.
.PARAMETER ProviderCommand
Inert synthetic account/token executable, never the real CLI.
.EXAMPLE
./Test-RunnerResponseTransport.ps1 -SourceRoot /tmp/source -ProviderCommand /tmp/provider
.OUTPUTS
System.String. JSON array of named successful offline assertions.
#>
[CmdletBinding()]
param([string]$SourceRoot, [string]$ProviderCommand)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $SourceRoot 'scripts/repo/Import-RunnerOperation.ps1')
. (Join-Path $SourceRoot 'infra/buildtest/runner/Import-RunnerDiagnostic.ps1')
. (Join-Path $SourceRoot 'scripts/repo/Import-RunnerResponseTransport.ps1')
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public sealed class SyntheticBodyStream : Stream {
 public static bool Disposed;
 public static int Reads;
 readonly string mode;
 int position;
 public SyntheticBodyStream(string mode) { this.mode = mode; Disposed = false; Reads = 0; }
 public override bool CanRead => true;
 public override bool CanSeek => false;
 public override bool CanWrite => false;
 public override long Length => throw new NotSupportedException();
 public override long Position { get => position; set => throw new NotSupportedException(); }
 public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
 public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token) {
  Reads++;
  if (mode == "streamTimeout" || mode == "streamCancel") await Task.Delay(10000, token);
  if (mode == "streamFailure") throw new IOException("PRIVATE_STREAM_7812");
  if (position >= 1048577) return 0;
  int size = Math.Min(count, 1048577 - position);
  Array.Fill<byte>(buffer, (byte)'x', offset, size);
  position += size;
  return size;
 }
 protected override void Dispose(bool disposing) { Disposed = true; base.Dispose(disposing); }
 public override void Flush() => throw new NotSupportedException();
 public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
 public override void SetLength(long value) => throw new NotSupportedException();
 public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
public sealed class SyntheticResponseHandler : HttpMessageHandler {
 public int Status = 200;
 public string Body = "{\"status\":\"Succeeded\"}";
 public string AsyncUrl;
 public string LocationUrl;
 public string Retry;
 public bool Duplicate;
 public bool Slow;
 public bool ThrowPrivate;
 public bool Truncated;
 public string StreamMode;
 public bool Disposed;
 protected override void Dispose(bool disposing) { Disposed = true; base.Dispose(disposing); }
 public int Calls;
 public bool SawBearer;
 public string Method;
 public string RequestBody;
 public string IfMatch;
 protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
  Calls++;
  Method = request.Method.Method;
  IfMatch = request.Headers.IfMatch.ToString();
  if (request.Content != null) RequestBody = await request.Content.ReadAsStringAsync(token);
  SawBearer = request.Headers.Authorization?.Scheme == "Bearer" && request.Headers.Authorization.Parameter == "SYNTHETIC_TOKEN_7812";
  if (Slow) await Task.Delay(10000, token);
  if (ThrowPrivate) throw new Exception("PRIVATE_PROVIDER_ERROR_7812");
  var result = new HttpResponseMessage((HttpStatusCode)Status);
  result.Content = StreamMode == null ? (HttpContent)new StringContent(Body) : new StreamContent(new SyntheticBodyStream(StreamMode));
  if (Truncated) result.Content.Headers.ContentLength = 100000;
  if (AsyncUrl != null) result.Headers.TryAddWithoutValidation("Azure-AsyncOperation", Duplicate ? new [] {AsyncUrl, AsyncUrl} : new [] {AsyncUrl});
  if (LocationUrl != null) result.Headers.TryAddWithoutValidation("Location", LocationUrl);
  if (Retry != null) result.Headers.TryAddWithoutValidation("Retry-After", Retry);
  return result;
 }
}
'@
$configuration = @{
    accountType = 'user'
    accountName = 'fixture@example.invalid'
    tenantId = '22222222-2222-2222-2222-222222222222'
    subscriptionId = '11111111-1111-1111-1111-111111111111'
    resourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/fixture/providers/Microsoft.App/jobs/runner'
}
$url = 'https://management.azure.com' + $configuration.resourceId + '?api-version=2024-03-01'
$operation = 'https://management.azure.com/subscriptions/' + $configuration.subscriptionId + '/providers/Microsoft.App/locations/westus/operationStatuses/operation-1?api-version=2024-03-01'
$results = [Collections.Generic.List[string]]::new()
$productionHandler = Get-RunnerResponseHandler
try {
    if ($productionHandler.AllowAutoRedirect -or $productionHandler.UseCookies -or $productionHandler.UseDefaultCredentials -or $productionHandler.UseProxy -or $productionHandler.PreAuthenticate -or $null -ne $productionHandler.Credentials -or $null -ne $productionHandler.DefaultProxyCredentials) {
        throw 'Production handler has implicit credentials or redirects.'
    }
    $results.Add('productionHandlerConfiguration')
}
finally {
    $productionHandler.Dispose()
}
foreach ($case in @('ok200', 'accepted202', 'priority', 'location', 'duplicate', 'invalidHeader', 'retry', 'retryOversize', 'malformed', 'empty', 'oversize', 'truncated', 'timeout', 'cancel', 'redirect', 'hostileHost', 'hostileSubscription', 'fragment', 'userinfo', 'query', 'path', 'encodedPath', 'accountMismatch', 'expiredToken', 'tokenBinding', 'privateError', 'tokenEcho', 'streamTimeout', 'streamCancel', 'streamOversize', 'streamFailure', 'nativeCancel', 'nativeTimeout', 'nativeOverflow', 'accountTenant', 'accountSubscription', 'tokenTenant', 'tokenHeaderEcho', 'acceptedEmpty', 'missing202Header', 'jsonDuplicate', 'statusCrossSubscription', 'statusFragment', 'statusUserinfo', 'statusQuery', 'statusEncodedPath', 'operationRead', 'patch', 'tokenNativeTimeout', 'tokenNativeCancel', 'nativeDualOverflow', 'encodedTokenValue', 'encodedTokenKey', 'encodedTokenNestedValue', 'encodedTokenNestedKey', 'encodedTokenArrayValue', 'encodedTokenArrayKey', 'encodedTokenMixedValue', 'encodedTokenMixedKey', 'encodedTokenFullValue', 'encodedTokenFullKey', 'encodedTokenScalar', 'encodedTokenRootArray', 'safeEncodedUnicode', 'safeEncodedNonsecret', 'safeLiteralEscape', 'patchPrecondition', 'invalidPrecondition', 'getPrecondition')) {
    $handler = [SyntheticResponseHandler]::new()
    $requestUrl = $url
    $env:RESPONSE_FIXTURE = $case
    $env:RESPONSE_CALLS = '/tmp/response-calls-' + $case
    $deadline = 15
    $method = 'GET'
    $body = $null
    $ifMatch = $null
    $cancellation = [Threading.CancellationTokenSource]::new()
    switch ($case) {
        'patchPrecondition' {
            $method = 'PATCH'
            $body = '{"private":"safe"}'
            $ifMatch = '"fixture-etag"'
        }
        'invalidPrecondition' {
            $method = 'PATCH'
            $body = '{"private":"safe"}'
            $ifMatch = "bad`r`nInjected: private"
        }
        'getPrecondition' {
            $ifMatch = '"fixture-etag"'
        }
        'accepted202' {
            $handler.Status = 202
            $handler.AsyncUrl = $operation
        }
        'priority' {
            $handler.AsyncUrl = $operation
            $handler.LocationUrl = $url
        }
        'location' {
            $handler.LocationUrl = $operation
        }
        'duplicate' {
            $handler.AsyncUrl = $operation
            $handler.Duplicate = $true
        }
        'invalidHeader' {
            $handler.AsyncUrl = 'https://evil.invalid/private'
        }
        'retry' {
            $handler.Retry = '2'
        }
        'retryOversize' {
            $handler.Retry = '999999'
        }
        'malformed' {
            $handler.Body = '{PRIVATE_PROVIDER_ERROR_7812'
        }
        'empty' {
            $handler.Body = ''
        }
        'oversize' {
            $handler.Body = 'x' * 1048577
        }
        'truncated' {
            $handler.Truncated = $true
        }
        'timeout' {
            $handler.Slow = $true
            $deadline = 3
        }
        'cancel' {
            $cancellation.Cancel()
        }
        'redirect' {
            $handler.Status = 302
            $handler.LocationUrl = 'https://evil.invalid/private'
        }
        'hostileHost' {
            $requestUrl = $url.Replace('management.azure.com', 'evil.invalid')
        }
        'hostileSubscription' {
            $requestUrl = $url.Replace('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333')
        }
        'fragment' {
            $requestUrl += '#private'
        }
        'userinfo' {
            $requestUrl = $url.Replace('https://', 'https://private@')
        }
        'query' {
            $requestUrl += '&private=value'
        }
        'path' {
            $requestUrl = $url.Replace('/jobs/runner', '/secrets/private')
        }
        'encodedPath' {
            $requestUrl = $url.Replace('/jobs/runner', '/jobs/%72unner')
        }
        'privateError' {
            $handler.ThrowPrivate = $true
        }
        'tokenEcho' {
            $handler.Body = '{"private":"SYNTHETIC_TOKEN_7812"}'
        }
        'encodedTokenValue' {
            $handler.Body = '{"private":"\u0053YNTHETIC_TOKEN_7812"}'
        }
        'encodedTokenKey' {
            $handler.Body = '{"\u0053YNTHETIC_TOKEN_7812":"safe"}'
        }
        'encodedTokenNestedValue' {
            $handler.Body = '{"outer":{"inner":"prefix-\u0053YNTHETIC_TOKEN_7812-suffix"}}'
        }
        'encodedTokenNestedKey' {
            $handler.Body = '{"outer":{"prefix-\u0053YNTHETIC_TOKEN_7812-suffix":0}}'
        }
        'encodedTokenArrayValue' {
            $handler.Body = '{"outer":[0,null,true,["prefix-\u0053YNTHETIC_TOKEN_7812-suffix"]]}'
        }
        'encodedTokenArrayKey' {
            $handler.Body = '{"outer":[0,{"nested":[{"\u0053YNTHETIC_TOKEN_7812":false}]}]}'
        }
        'encodedTokenMixedValue' {
            $handler.Body = '{"private":"SYN\u0054HETIC\u005fTOKEN_781\u0032"}'
        }
        'encodedTokenMixedKey' {
            $handler.Body = '{"SYN\u0054HETIC\u005fTOKEN_781\u0032":null}'
        }
        'encodedTokenFullValue' {
            $handler.Body = '{"private":"\u0053\u0059\u004e\u0054\u0048\u0045\u0054\u0049\u0043\u005f\u0054\u004f\u004b\u0045\u004e\u005f\u0037\u0038\u0031\u0032"}'
        }
        'encodedTokenFullKey' {
            $handler.Body = '{"\u0053\u0059\u004e\u0054\u0048\u0045\u0054\u0049\u0043\u005f\u0054\u004f\u004b\u0045\u004e\u005f\u0037\u0038\u0031\u0032":[]}'
        }
        'encodedTokenScalar' {
            $handler.Body = '"\u0053YNTHETIC_TOKEN_7812"'
        }
        'encodedTokenRootArray' {
            $handler.Body = '["\u0053YNTHETIC_TOKEN_7812"]'
        }
        'safeEncodedUnicode' {
            $handler.Body = '{"status":"Succeeded","\u006eote":{"array":[null,true,42,"\u2603","\ud83d\ude80"]}}'
        }
        'safeEncodedNonsecret' {
            $handler.Body = '{"status":"Succeeded","note":"\u0053YNTHETIC_NOT_A_CREDENTIAL"}'
        }
        'safeLiteralEscape' {
            $handler.Body = '{"status":"Succeeded","note":"\\u0053YNTHETIC_TOKEN_7812"}'
        }
        'tokenHeaderEcho' {
            $handler.AsyncUrl = $operation.Replace('operation-1', 'SYNTHETIC_TOKEN_7812')
        }
        'acceptedEmpty' {
            $handler.Status = 202
            $handler.AsyncUrl = $operation
            $handler.Body = ''
        }
        'missing202Header' {
            $handler.Status = 202
        }
        'jsonDuplicate' {
            $handler.Body = '{"status":"Succeeded","Status":"Failed"}'
        }
        'statusCrossSubscription' {
            $handler.AsyncUrl = $operation.Replace($configuration.subscriptionId, '33333333-3333-3333-3333-333333333333')
        }
        'statusFragment' {
            $handler.AsyncUrl = $operation + '#private'
        }
        'statusUserinfo' {
            $handler.AsyncUrl = $operation.Replace('https://', 'https://private@')
        }
        'statusQuery' {
            $handler.AsyncUrl = $operation + '&private=value'
        }
        'statusEncodedPath' {
            $handler.AsyncUrl = $operation.Replace('operation-1', '%6fperation-1')
        }
        'nativeCancel' {
            $cancellation.CancelAfter(2000)
        }
        'nativeTimeout' {
            $deadline = 4
        }
        'operationRead' {
            $requestUrl = $operation
        }
        'patch' {
            $method = 'PATCH'
            $body = '{"properties":{"template":{"containers":[{"name":"runner","image":"fixture.invalid/runner@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}}}'
        }
        'tokenNativeTimeout' {
            $deadline = 4
        }
        'tokenNativeCancel' {
            $cancellation.CancelAfter(2000)
        }
    }
    if ($case.StartsWith('stream', [StringComparison]::Ordinal)) {
        $handler.StreamMode = $case
        $deadline = 8
        if ($case -eq 'streamCancel') {
            $cancellation.CancelAfter(4000)
        }
    }
    $succeeded = $false
    $errorText = ''
    try {
        $response = Invoke-RunnerResponseTransport -Configuration $configuration -Uri $requestUrl -ProviderCommand $ProviderCommand -RunClock ([Diagnostics.Stopwatch]::StartNew()) -DeadlineSeconds $deadline -CancellationToken $cancellation.Token -Handler $handler -Method $method -Body $body -IfMatch $ifMatch
        $succeeded = $true
    }
    catch {
        $errorText = $_.Exception.Message
        if ($errorText -cne 'Runner response transport failed; outcome is unknown.') {
            throw ('Unredacted error: ' + $case)
        }
    }
    finally {
        $cancellation.Dispose()
    }
    if ($case.StartsWith('stream', [StringComparison]::Ordinal) -and (-not [SyntheticBodyStream]::Disposed -or -not $handler.Disposed -or [SyntheticBodyStream]::Reads -eq 0)) {
        throw ('Body or handler was not disposed: ' + $case)
    }
    $positive = $case -in @('patchPrecondition', 'ok200', 'accepted202', 'priority', 'location', 'retry', 'acceptedEmpty', 'operationRead', 'patch', 'safeEncodedUnicode', 'safeEncodedNonsecret', 'safeLiteralEscape')
    if ($succeeded -ne $positive) {
        throw ('Unexpected outcome: ' + $case)
    }
    if ($positive) {
        $expectedStatus = if ($case -in @('accepted202', 'acceptedEmpty')) {
            202
        }
        else {
            200
        }
        if ($response.StatusCode -ne $expectedStatus -or $response.Completed -or -not $handler.SawBearer -or $handler.Calls -ne 1) {
            throw ('Invalid actual envelope: ' + $case)
        }
        if ($case -in @('priority', 'location', 'accepted202', 'acceptedEmpty') -and $response.OperationUri -cne $operation) {
            throw ('Invalid operation priority: ' + $case)
        }
        if ($case -ne 'acceptedEmpty' -and $response.Body.status -cne 'Succeeded') {
            throw ('Actual JSON body was not parsed: ' + $case)
        }
        if ($case -eq 'safeEncodedUnicode' -and ($response.Body.note.array[3] -cne [string][char]0x2603 -or $response.Body.note.array[4] -cne [char]::ConvertFromUtf32(0x1F680))) {
            throw 'Safe encoded Unicode was not preserved.'
        }
        if ($case -eq 'safeEncodedNonsecret' -and $response.Body.note -cne 'SYNTHETIC_NOT_A_CREDENTIAL') {
            throw 'Safe encoded nonsecret text changed.'
        }
        if ($case -eq 'safeLiteralEscape' -and $response.Body.note -cne '\u0053YNTHETIC_TOKEN_7812') {
            throw 'Literal JSON escape was decoded twice.'
        }
        if ($handler.Method -cne $method -or ($case -eq 'patch' -and $handler.RequestBody -cne $body)) {
            throw ('Request method or private PATCH body changed: ' + $case)
        }
        if ($case -eq 'patchPrecondition' -and ($handler.IfMatch -cne '"fixture-etag"' -or $handler.RequestBody -cne $body)) {
            throw 'PATCH precondition or body changed.'
        }
        if ($case -eq 'retry' -and $response.RetryAfterSeconds -ne 2) {
            throw 'Retry-After was not retained.'
        }
        if (($response | ConvertTo-Json -Depth 20 -Compress) -match 'SYNTHETIC_TOKEN_7812') {
            throw 'Token escaped in envelope.'
        }
    }
    if ($case -in @('invalidPrecondition', 'getPrecondition', 'hostileHost', 'hostileSubscription', 'fragment', 'userinfo', 'query', 'path', 'encodedPath', 'cancel')) {
        if (Test-Path -LiteralPath $env:RESPONSE_CALLS) {
            throw ('Unsafe URL requested credentials: ' + $case)
        }
    }
    if ($case -in @('accountMismatch', 'expiredToken', 'tokenBinding', 'accountTenant', 'accountSubscription', 'tokenTenant', 'nativeCancel', 'nativeTimeout', 'nativeOverflow', 'tokenNativeCancel', 'tokenNativeTimeout', 'nativeDualOverflow') -and $handler.Calls -ne 0) {
        throw ('Invalid binding reached HTTP: ' + $case)
    }
    if ($case -in @('accountMismatch', 'accountTenant', 'accountSubscription')) {
        $nativeArguments = [IO.File]::ReadAllText($env:RESPONSE_CALLS)
        if ($nativeArguments.Contains('get-access-token', [StringComparison]::Ordinal)) {
            throw ('Account mismatch requested token: ' + $case)
        }
    }
    $results.Add($case)
}
foreach ($contextCase in @('reuse', 'wrongConfiguration', 'wrongClock', 'wrongDeadline', 'wrongProvider', 'expired', 'disposed', 'forged', 'tokenBindingContext', 'accountBindingContext', 'decodedEchoContext')) {
    $env:RESPONSE_FIXTURE = 'ok200'
    $env:RESPONSE_CALLS = '/tmp/response-context-' + $contextCase
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $contextId = New-RunnerResponseContext -Configuration $configuration -ProviderCommand $ProviderCommand -RunClock $clock -DeadlineSeconds 30
    $firstHandler = [SyntheticResponseHandler]::new()
    $private = Invoke-RunnerResponseTransport -Configuration $configuration -Uri $url -ProviderCommand $ProviderCommand -RunClock $clock -DeadlineSeconds 30 -Handler $firstHandler -ContextId $contextId
    if ($private.StatusCode -ne 200) {
        throw 'Initial context request failed.'
    }
    $nativeBefore = [IO.File]::ReadAllText($env:RESPONSE_CALLS)
    $parameters = @{
        Configuration = $configuration.Clone()
        Uri = $url
        ProviderCommand = $ProviderCommand
        RunClock = $clock
        DeadlineSeconds = 30
        Handler = [SyntheticResponseHandler]::new()
        ContextId = $contextId
    }
    switch ($contextCase) {
        'wrongConfiguration' {
            $parameters.Configuration.accountName = 'wrong@example.invalid'
        }
        'wrongClock' {
            $parameters.RunClock = [Diagnostics.Stopwatch]::StartNew()
        }
        'wrongDeadline' {
            $parameters.DeadlineSeconds = 31
        }
        'wrongProvider' {
            $parameters.ProviderCommand = '/tmp/not-approved'
        }
        'expired' {
            $script:runnerResponseContexts[$contextId].Token.expires_on = 0
        }
        'disposed' {
            Remove-RunnerResponseContext -ContextId $contextId
        }
        'forged' {
            $parameters.ContextId = 'SYNTHETIC_TOKEN_7812'
        }
        'tokenBindingContext' {
            $script:runnerResponseContexts[$contextId].Token.tenant = 'wrong'
        }
        'accountBindingContext' {
            $script:runnerResponseContexts[$contextId].Account.user.name = 'wrong@example.invalid'
        }
        'decodedEchoContext' {
            $parameters.Handler.Body = '{"private":"\u0053YNTHETIC_TOKEN_7812"}'
        }
    }
    $contextSucceeded = $false
    try {
        $private = Invoke-RunnerResponseTransport @parameters
        $contextSucceeded = $true
    }
    catch {
        if ($_.Exception.Message -cne 'Runner response transport failed; outcome is unknown.') {
            throw 'Unredacted context error.'
        }
    }
    finally {
        Remove-RunnerResponseContext -ContextId $contextId
        $parameters.Handler.Dispose()
    }
    if ($contextSucceeded -ne ($contextCase -ceq 'reuse')) {
        throw ('Unexpected context outcome: ' + $contextCase)
    }
    if ($script:runnerResponseContexts.ContainsKey($contextId) -or [IO.File]::ReadAllText($env:RESPONSE_CALLS) -cne $nativeBefore) {
        throw 'Context disposal failed or credentials were acquired twice.'
    }
    if ($contextCase -notin @('reuse', 'decodedEchoContext') -and $parameters.Handler.Calls -ne 0) {
        throw 'Invalid context reached HTTP.'
    }
    $results.Add('context-' + $contextCase)
}
ConvertTo-Json -InputObject @($results) -Compress
