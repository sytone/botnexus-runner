<#
.SYNOPSIS
Returns zero without the required wrapper proof.
.DESCRIPTION
Inert negative fixture proves exit zero alone cannot certify a wrapper.
.EXAMPLE
./Invoke-WrapperOutput.ps1
.OUTPUTS
System.String. Non-proof output; exits zero.
#>
[CmdletBinding()]
param()
Write-Output 'No required proof was emitted.'
exit 0
