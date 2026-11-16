<#
.SYNOPSIS
Returns a deliberate nonzero exit with misleading success text.
.DESCRIPTION
Inert negative fixture proves output alone cannot certify a wrapper.
.EXAMPLE
./Invoke-WrapperExit.ps1
.OUTPUTS
System.String. Misleading success marker; always exits seven.
#>
[CmdletBinding()]
param()
Write-Output 'RESULT failed=0'
exit 7
