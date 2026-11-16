<#
.SYNOPSIS
Frames native arguments without evaluating their contents.
.DESCRIPTION
Reports argument count and the first argument's exact UTF-8 bytes as base64 JSON.
.PARAMETER Literal
Literal argument payload received from the native process boundary.
.EXAMPLE
./Write-NativeArgument.ps1 'literal with spaces'
.OUTPUTS
System.String. JSON containing count and base64 UTF-8 payload.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Literal)
@{ count = 1 + $args.Count; utf8 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Literal)) } | ConvertTo-Json -Compress
