<#
.SYNOPSIS
Loads the private bounded ARM response transport without making requests.
.DESCRIPTION
Defines a private helper for an explicitly pinned existing CLI account. Responses
remain private: HTTP 202 is acceptance, never completion. No deployment caller is
integrated here. Import-RunnerOperation.ps1 and Import-RunnerDiagnostic.ps1 must
already be loaded for bounded native capture and owned process containment. Never print or
persist the returned envelope, which can contain private resource information.
.EXAMPLE
. ./Import-RunnerResponseTransport.ps1
Loads helpers only; does not request credentials or contact a provider.
.OUTPUTS
None. Defines private transport functions.
#>
[CmdletBinding()]
param()

# Private per-script operation store. Callers receive only an unguessable handle;
# only actual transport validation may populate credentials. Never global/cache.
$script:runnerResponseContexts = @{}

function New-RunnerResponseContext {
    <#
    .SYNOPSIS
    Opens an empty private credential lifetime for one original operation.
    .DESCRIPTION
    Does not obtain credentials. Only the transport can populate this handle after
    actual account and token validation. The owner must close it in finally.
    .PARAMETER Configuration
    Exact private account and resource configuration for every request.
    .PARAMETER ProviderCommand
    Exact approved executable for this operation.
    .PARAMETER RunClock
    Original running clock, compared by reference on reuse.
    .PARAMETER DeadlineSeconds
    Original allowance; cannot change during reuse.
    .EXAMPLE
    $context = New-RunnerResponseContext -Configuration $config -ProviderCommand $cli -RunClock $clock -DeadlineSeconds 120
    .OUTPUTS
    System.String. Opaque handle, not a credential or serializable proof.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([Collections.IDictionary]$Configuration, [string]$ProviderCommand, [Diagnostics.Stopwatch]$RunClock, [ValidateRange(1, 600)][int]$DeadlineSeconds)
    Assert-RunnerAccountBinding -Configuration $Configuration
    if ($null -eq $RunClock -or -not $RunClock.IsRunning -or $RunClock.Elapsed.TotalSeconds -ge $DeadlineSeconds) {
        throw 'Invalid response context.'
    }
    if (-not $PSCmdlet.ShouldProcess('private in-memory operation', 'Open credential lifetime')) {
        return
    }
    $handle = [guid]::NewGuid().ToString('N')
    $script:runnerResponseContexts[$handle] = @{
        Binding = ($Configuration | ConvertTo-Json -Compress -Depth 100)
        Provider = $ProviderCommand
        Clock = $RunClock
        Deadline = $DeadlineSeconds
        Account = $null
        Token = $null
        Failed = $false
    }
    return $handle
}

function Remove-RunnerResponseContext {
    <#
    .SYNOPSIS
    Closes one private credential lifetime and releases its references.
    .DESCRIPTION
    Clears token and account references and invalidates the opaque handle. Repeated
    disposal is safe; no credentials are emitted or persisted.
    .PARAMETER ContextId
    Opaque handle returned by New-RunnerResponseContext.
    .EXAMPLE
    Remove-RunnerResponseContext -ContextId $context
    .OUTPUTS
    None.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$ContextId)
    if (-not $PSCmdlet.ShouldProcess('private in-memory operation', 'Clear credential lifetime')) {
        return
    }
    if ($ContextId -and $script:runnerResponseContexts.ContainsKey($ContextId)) {
        $entry = $script:runnerResponseContexts[$ContextId]
        $entry.Token = $null
        $entry.Account = $null
        [void]$script:runnerResponseContexts.Remove($ContextId)
    }
}

function Get-RunnerResponseHandler {
    <#
    .SYNOPSIS
    Creates the production HTTP handler with explicit credential boundaries.
    .DESCRIPTION
    Disables redirects, cookies, default authentication and proxy use. Credentials
    are attached only to a validated ARM request by the private transport helper.
    .EXAMPLE
    $handler = Get-RunnerResponseHandler
    Creates an unconnected handler owned by the caller.
    .OUTPUTS
    System.Net.Http.HttpClientHandler. The caller must dispose the handler.
    #>
    [CmdletBinding()]
    [OutputType([Net.Http.HttpMessageHandler], [Net.Http.HttpClientHandler])]
    param()
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseDefaultCredentials = $false
    $handler.Credentials = $null
    $handler.DefaultProxyCredentials = $null
    $handler.UseProxy = $false
    $handler.PreAuthenticate = $false
    return $handler
}

function Assert-RunnerResponseUri {
    <#
    .SYNOPSIS
    Validates one exact job or bounded ARM operation reference before credentials.
    .DESCRIPTION
    Rejects redirects to alternate hosts, user information, fragments, encoded or
    ambiguous paths and query parameters other than the pinned API version. Only
    the configured job or subscription-scoped Microsoft.App operation paths pass.
    .PARAMETER Text
    Private absolute HTTPS URL, not suitable for public logging.
    .PARAMETER Configuration
    Existing pinned account and exact job resource configuration.
    .PARAMETER Operation
    Allows a bounded Microsoft.App operation-status URL in the same subscription.
    .EXAMPLE
    Assert-RunnerResponseUri -Text $privateUrl -Configuration $configuration
    Validates a job request without resolving credentials.
    .OUTPUTS
    System.Uri. Validated private URL; throws on unsafe input.
    #>
    [CmdletBinding()]
    [OutputType([uri])]
    param([string]$Text, [Collections.IDictionary]$Configuration, [switch]$Operation)
    $resource = $Configuration.resourceId
    $prefix = '/subscriptions/' + $Configuration.subscriptionId
    if ($resource -cnotmatch '^/subscriptions/[a-f0-9-]{36}/resourceGroups/[a-zA-Z0-9_.()-]{1,90}/providers/Microsoft\.App/jobs/[a-zA-Z0-9-]{1,60}$') {
        throw 'Invalid response target.'
    }
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 2048 -or $Text -cmatch '[%\\\x00-\x20\x7f#@]' -or -not $Text.StartsWith('https://management.azure.com/', [StringComparison]::Ordinal)) {
        throw 'Invalid response URL.'
    }
    $parsed = [uri]::new($Text, [UriKind]::Absolute)
    if ($parsed.Scheme -cne 'https' -or $parsed.Host -cne 'management.azure.com' -or $parsed.Port -ne 443 -or $parsed.UserInfo -or $parsed.Fragment -or $parsed.Query -cne '?api-version=2024-03-01' -or $parsed.AbsoluteUri -cne $Text) {
        throw 'Invalid response URL.'
    }
    $valid = $parsed.AbsolutePath -ceq $resource
    if ($Operation) {
        $operationPattern = '^' + [regex]::Escape($prefix) + '/(?:resourceGroups/[a-zA-Z0-9_.()-]{1,90}/)?providers/Microsoft\.App/locations/[a-z0-9-]{1,40}/(?:operationStatuses|operations|operationResults)/[a-zA-Z0-9_-]{1,128}$'
        $valid = $valid -or $parsed.AbsolutePath -cmatch $operationPattern
    }
    if (-not $valid) {
        throw 'Invalid response path.'
    }
    return $parsed
}

function Invoke-RunnerResponseTransport {
    <#
    .SYNOPSIS
    Returns a private actual HTTP response envelope under one original deadline.
    .DESCRIPTION
    Validates the target before any CLI call, matches the existing account, then
    captures an explicitly scoped token only in process memory. Disables redirect,
    cookie and implicit proxy/default credentials. Reads at most one MiB, checks
    declared length, strict UTF-8 and duplicate-free JSON, and rejects token echo
    in raw text and decoded JSON string values or property names at every depth.
    HTTP 200 and 202 remain distinct and neither establishes deployment completion.
    Uses the original clock and cancellation for native capture, request and body
    reads. Disposal is synchronous and is checked against the same deadline. No
    retry, polling, journal, deployment approval or live-use qualification occurs.
    Errors are fixed and redacted. Returned data is private and must not be logged.
    .PARAMETER Configuration
    Strict private existing account/tenant/subscription and exact job binding.
    .PARAMETER Uri
    Validated job or operation URL in the configured subscription.
    .PARAMETER ProviderCommand
    Explicit approved CLI executable; tests use an inert synthetic executable.
    .PARAMETER RunClock
    Already running clock for the original operation, never reset here.
    .PARAMETER DeadlineSeconds
    Original absolute deadline measured by RunClock, at most 600 seconds.
    .PARAMETER CancellationToken
    Original operation cancellation signal, including native capture and drain.
    .PARAMETER Handler
    Optional owned in-memory handler for offline tests. Omit in production.
    .PARAMETER Method
    GET for readback/status or PATCH for a future qualified caller; never retried.
    .PARAMETER ContextId
    Optional opaque operation handle. Cannot supply tokens or override validation.
    .PARAMETER IfMatch
    Optional exact quoted ETag precondition for PATCH only; no arbitrary headers.
    .PARAMETER Body
    Private bounded JSON PATCH payload. Never placed in native arguments or files.
    .EXAMPLE
    $private = Invoke-RunnerResponseTransport -Configuration $config -Uri $url -ProviderCommand $cli -RunClock $clock -DeadlineSeconds 120
    Captures one private envelope; it is not acceptance or terminal proof.
    .OUTPUTS
    System.Management.Automation.PSCustomObject. Private StatusCode, OperationUri,
    RetryAfterSeconds, Body and Completed=false. Never includes the access token.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Collections.IDictionary]$Configuration,
        [string]$Uri,
        [string]$ProviderCommand,
        [Diagnostics.Stopwatch]$RunClock,
        [ValidateRange(1, 600)][int]$DeadlineSeconds,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        [Net.Http.HttpMessageHandler]$Handler,
        [ValidateSet('GET', 'PATCH')][string]$Method = 'GET',
        [string]$Body,
        [string]$IfMatch,
        [string]$ContextId
    )
    $client = $null
    $request = $null
    $response = $null
    $stream = $null
    $capture = $null
    $cancellation = $null
    $tokenText = $null
    $token = $null
    $secret = $null
    $failed = $false
    $result = $null
    $context = $null
    try {
        $CancellationToken.ThrowIfCancellationRequested()
        if ($null -eq $RunClock -or -not $RunClock.IsRunning -or $RunClock.Elapsed.TotalSeconds -ge $DeadlineSeconds) {
            throw 'Invalid response clock.'
        }
        Assert-RunnerAccountBinding -Configuration $Configuration
        $target = Assert-RunnerResponseUri -Text $Uri -Configuration $Configuration -Operation
        if ($Method -ceq 'PATCH' -and ($target.AbsolutePath -cne $Configuration.resourceId -or [string]::IsNullOrWhiteSpace($Body) -or [Text.Encoding]::UTF8.GetByteCount($Body) -gt 1048576)) {
            throw 'Invalid response request.'
        }
        if ($IfMatch -and ($Method -cne 'PATCH' -or $IfMatch -cnotmatch '^"[A-Za-z0-9_.:-]+"$')) {
            throw 'Invalid response precondition.'
        }
        if ($Method -ceq 'GET' -and $Body) {
            throw 'Invalid response request.'
        }
        if ($Method -ceq 'PATCH') {
            $null = ConvertFrom-RunnerPrivateJson -Text $Body
        }
        if ($ContextId) {
            if (-not $script:runnerResponseContexts.ContainsKey($ContextId)) {
                throw 'Unknown response context.'
            }
            $context = $script:runnerResponseContexts[$ContextId]
            if ($context.Failed -or -not [object]::ReferenceEquals($context.Clock, $RunClock) -or $context.Deadline -ne $DeadlineSeconds -or $context.Provider -cne $ProviderCommand -or $context.Binding -cne ($Configuration | ConvertTo-Json -Compress -Depth 100)) {
                throw 'Mismatched response context.'
            }
        }
        if ($null -ne $context -and $null -ne $context.Token) {
            $account = $context.Account
            $token = $context.Token
        }
        else {
            $native = @{
                Executable = $ProviderCommand
                LimitSeconds = $DeadlineSeconds
                RunClock = $RunClock
                CancellationToken = $CancellationToken
                Owned = $true
                Capture = $true
            }
            $accountText = Invoke-PrivateCommand @native -Argument @('account', 'show', '--subscription', $Configuration.subscriptionId, '--output', 'json', '--only-show-errors')
            $account = ConvertFrom-RunnerPrivateJson -Text $accountText
            Assert-RunnerAccountBinding -Configuration $Configuration -Account $account
            $CancellationToken.ThrowIfCancellationRequested()
            $tokenText = Invoke-PrivateCommand @native -Argument @('account', 'get-access-token', '--subscription', $Configuration.subscriptionId, '--tenant', $Configuration.tenantId, '--resource', 'https://management.azure.com/', '--output', 'json', '--only-show-errors')
            $token = ConvertFrom-RunnerPrivateJson -Text $tokenText
        }
        Assert-RunnerAccountBinding -Configuration $Configuration -Account $account
        $CancellationToken.ThrowIfCancellationRequested()
        foreach ($key in @('accessToken', 'tokenType', 'subscription', 'tenant', 'expires_on')) {
            if (-not $token.Contains($key)) {
                throw 'Invalid response credential.'
            }
        }
        $expiry = 0L
        if ($token.accessToken -isnot [string] -or $token.accessToken.Length -lt 1 -or $token.accessToken.Length -gt 32768 -or $token.accessToken -cmatch '[^a-zA-Z0-9._~+/-]' -or $token.tokenType -cne 'Bearer' -or $token.subscription -cne $Configuration.subscriptionId -or $token.tenant -cne $Configuration.tenantId -or -not [long]::TryParse([string]$token.expires_on, [ref]$expiry)) {
            throw 'Invalid response credential.'
        }
        $remaining = $DeadlineSeconds - $RunClock.Elapsed.TotalSeconds
        if ($remaining -le 0 -or $expiry -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + [Math]::Ceiling($remaining)) {
            throw 'Expired response credential.'
        }
        if ($null -ne $context) {
            $context.Account = $account
            $context.Token = $token
        }
        $secret = $token.accessToken
        $cancellation = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken)
        $cancellation.CancelAfter([TimeSpan]::FromSeconds($remaining))
        if ($null -eq $Handler) {
            $Handler = Get-RunnerResponseHandler
        }
        $client = [Net.Http.HttpClient]::new($Handler, $true)
        $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
        $client.MaxResponseContentBufferSize = 1048576
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $target)
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $secret)
        if ($IfMatch) {
            $request.Headers.IfMatch.Add([Net.Http.Headers.EntityTagHeaderValue]::Parse($IfMatch))
        }
        if ($Method -ceq 'PATCH') {
            $request.Content = [Net.Http.StringContent]::new($Body, [Text.Encoding]::UTF8, 'application/merge-patch+json')
        }
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancellation.Token).GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        if ($status -notin @(200, 202)) {
            throw 'Unexpected response status.'
        }
        $operationUri = $null
        foreach ($name in @('Azure-AsyncOperation', 'Location')) {
            if ($response.Headers.Contains($name)) {
                $values = @($response.Headers.GetValues($name))
                if ($values.Count -ne 1 -or $values[0].Contains($secret, [StringComparison]::Ordinal)) {
                    throw 'Invalid operation header.'
                }
                $validated = Assert-RunnerResponseUri -Text $values[0] -Configuration $Configuration -Operation
                if ($null -eq $operationUri) {
                    $operationUri = $validated.AbsoluteUri
                }
            }
        }
        if ($status -eq 202 -and $null -eq $operationUri) {
            throw 'Missing operation reference.'
        }
        $retry = $null
        if ($response.Headers.Contains('Retry-After')) {
            $values = @($response.Headers.GetValues('Retry-After'))
            $retryValue = 0
            if ($values.Count -ne 1 -or $values[0] -cnotmatch '^[0-9]{1,3}$' -or -not [int]::TryParse($values[0], [ref]$retryValue) -or $retryValue -gt ($DeadlineSeconds - $RunClock.Elapsed.TotalSeconds)) {
                throw 'Invalid retry allowance.'
            }
            $retry = $retryValue
        }
        $length = $response.Content.Headers.ContentLength
        if ($null -ne $length -and ($length -gt 1048576 -or $length -lt 0)) {
            throw 'Invalid response size.'
        }
        $stream = $response.Content.ReadAsStreamAsync($cancellation.Token).GetAwaiter().GetResult()
        $capture = [IO.MemoryStream]::new()
        $buffer = [byte[]]::new(8192)
        while ($true) {
            $cancellation.Token.ThrowIfCancellationRequested()
            $count = $stream.ReadAsync($buffer, 0, $buffer.Length, $cancellation.Token).GetAwaiter().GetResult()
            if ($count -eq 0) {
                break
            }
            if ($capture.Length + $count -gt 1048576) {
                throw 'Response exceeded capture limit.'
            }
            $capture.Write($buffer, 0, $count)
        }
        if ($null -ne $length -and $length -ne $capture.Length) {
            throw 'Truncated response.'
        }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($capture.ToArray())
        if ($text.Contains($secret, [StringComparison]::Ordinal)) {
            throw 'Credential echo denied.'
        }
        $parsed = if ($capture.Length -eq 0 -and $status -eq 202) {
            $null
        }
        else {
            ConvertFrom-RunnerPrivateJson -Text $text
        }
        $pending = [Collections.Generic.Queue[object]]::new()
        $pending.Enqueue($parsed)
        while ($pending.Count -gt 0) {
            $cancellation.Token.ThrowIfCancellationRequested()
            $value = $pending.Dequeue()
            if ($value -is [string]) {
                if ($value.Contains($secret, [StringComparison]::Ordinal)) {
                    throw 'Credential echo denied.'
                }
            }
            elseif ($value -is [Collections.IDictionary]) {
                foreach ($key in $value.Keys) {
                    $pending.Enqueue($key)
                    $pending.Enqueue($value[$key])
                }
            }
            elseif ($value -is [array]) {
                foreach ($entry in $value) {
                    $pending.Enqueue($entry)
                }
            }
        }
        $result = [pscustomobject]@{ StatusCode = $status; OperationUri = $operationUri; RetryAfterSeconds = $retry; Body = $parsed; Completed = $false }
    }
    catch {
        $failed = $true
    }
    finally {
        if ($null -ne $request) {
            $request.Headers.Authorization = $null
        }
        foreach ($owned in @($stream, $capture, $response, $request, $client, $cancellation)) {
            if ($null -ne $owned) {
                try {
                    $owned.Dispose()
                }
                catch {
                    $failed = $true
                }
            }
        }
        $secret = $null
        $tokenText = $null
        $token = $null
        if ($null -eq $RunClock -or $RunClock.Elapsed.TotalSeconds -ge $DeadlineSeconds -or $CancellationToken.IsCancellationRequested) {
            $failed = $true
        }
    }
    if ($failed) {
        if ($null -ne $context) {
            $context.Token = $null
            $context.Account = $null
            $context.Failed = $true
        }
        throw 'Runner response transport failed; outcome is unknown.'
    }
    return $result
}
