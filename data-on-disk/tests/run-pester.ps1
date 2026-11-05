# Runs the Pester suites that need no Docker, the data-on-disk helper's and the tailnet node helper's,
# and exits with the number of failures.
# They use the Pester 3.4 syntax (`Should Be`), which Pester 5 dropped: 3.4.0 where Windows ships it,
# otherwise 4.10.1, the last version that still reads it.
$ErrorActionPreference = 'Stop'
if (Get-Module -ListAvailable Pester | Where-Object { $_.Version -eq [version]'3.4.0' }) {
    Import-Module Pester -RequiredVersion 3.4.0
}
else {
    Install-Module Pester -RequiredVersion 4.10.1 -Force -SkipPublisherCheck -Scope CurrentUser
    Import-Module Pester -RequiredVersion 4.10.1
}
Write-Host "Pester $((Get-Module Pester).Version)"
$suites = @(
    (Join-Path $PSScriptRoot 'restore-decision.Tests.ps1'),
    (Join-Path $PSScriptRoot '..\..\gateway\tests\tailnet-node.Tests.ps1')
)
$result = Invoke-Pester -Script $suites -PassThru
exit $result.FailedCount
