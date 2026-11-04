# Pester 3.4: the restore decision over the shared cases in cases/ (their format is in the header of
# restore-decision.test.sh, which reads the same files), with the volume check shadowed so no test reaches Docker.

. (Join-Path (Split-Path $PSScriptRoot) "data-on-disk.ps1")

$global:volumeIsEmpty = $true
$global:volumeChecks = @()
$global:validatorRuns = 0
function Test-DatabaseVolumeIsEmpty([string]$Volume) {
    $global:volumeChecks += $Volume
    return $global:volumeIsEmpty
}

$volume = "stack_db"
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) "restore-decision-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $scratch | Out-Null

function Read-DecisionCase([System.IO.FileInfo]$File) {
    $case = [pscustomobject]@{
        Name = $File.BaseName; VolumeIsEmpty = $true; Folder = "present"; Pattern = "app-*.dump"
        Dumps = @(); Links = @(); HasValidator = $true; Rejections = @(); Failures = @(); AllowFresh = $false
        ExpectedError = $null; ExpectedAction = $null; ExpectedDump = $null; ExpectedRejected = @(); ExpectedValidatorRuns = $null
    }
    foreach ($line in [System.IO.File]::ReadAllLines($File.FullName)) {
        if (-not $line -or $line.StartsWith("#")) { continue }
        $key, $value = $line -split " ", 2
        switch ($key) {
            "volume" { $case.VolumeIsEmpty = ($value -eq "empty") }
            "folder" { $case.Folder = $value }
            "pattern" { $case.Pattern = $value }
            "dump" { $name, $bytes = $value -split " ", 2; $case.Dumps += [pscustomobject]@{ Name = $name; Bytes = [int]$bytes } }
            "link" { $name, $target = $value -split " ", 2; $case.Links += [pscustomobject]@{ Name = $name; Target = $target } }
            "validator" { $case.HasValidator = ($value -ne "none") }
            "reject" { $name, $reason = $value -split " ", 2; $case.Rejections += [pscustomobject]@{ Name = $name; Reason = $reason } }
            "fail" { $name, $message = $value -split " ", 2; $case.Failures += [pscustomobject]@{ Name = $name; Message = $message } }
            "fresh" { $case.AllowFresh = ($value -eq "true") }
            "expect-error" { $case.ExpectedError = $value }
            "expect-action" { $case.ExpectedAction = $value }
            "expect-dump" { $case.ExpectedDump = $value }
            "expect-rejected" { $name, $reason = $value -split " ", 2; $case.ExpectedRejected += "$name`t$reason" }
            "expect-validator-runs" { $case.ExpectedValidatorRuns = [int]$value }
            default { throw "unknown key '$key' in $($File.Name)" }
        }
    }
    return $case
}

$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

function Get-DumpFolder([object]$Case) { return Join-Path $scratch $Case.Name }

function New-DumpFolder([object]$Case) {
    $folder = Get-DumpFolder $Case
    if ($Case.Folder -eq "missing") { return $folder }
    New-Item -ItemType Directory -Path $folder | Out-Null
    foreach ($dump in $Case.Dumps) { [System.IO.File]::WriteAllBytes((Join-Path $folder $dump.Name), (New-Object byte[] $dump.Bytes)) }
    foreach ($link in $Case.Links) { New-Item -ItemType SymbolicLink -Path (Join-Path $folder $link.Name) -Target (Join-Path $folder $link.Target) | Out-Null }
    return $folder
}

<#
.SYNOPSIS
Makes listing a folder fail as an access-denied Get-ChildItem does, whoever runs the suite.
.NOTES
Must be called inside an It block. A deny ACL alone does not stop an elevated shell from listing.
#>
function Set-FolderUnlistable([string]$Folder) {
    $global:unlistableFolder = $Folder
    Mock Get-ChildItem { throw [System.UnauthorizedAccessException]"Access to the path '$LiteralPath' is denied." } -ParameterFilter { $LiteralPath -eq $global:unlistableFolder }
}

<#
.SYNOPSIS
True when this shell may create a symlink, which Windows allows only elevated or in Developer Mode.
#>
function Test-CanCreateSymlink {
    $target = Join-Path $scratch "symlink-probe-target"
    [System.IO.File]::WriteAllBytes($target, (New-Object byte[] 1))
    try { New-Item -ItemType SymbolicLink -Path (Join-Path $scratch "symlink-probe") -Target $target -ErrorAction Stop | Out-Null; return $true }
    catch { return $false }
}

function Test-ListingIsDenied([string]$Folder) {
    try { Get-ChildItem -LiteralPath $Folder -ErrorAction Stop | Out-Null; return $false }
    catch { return $true }
}

function New-Validator([object]$Case) {
    if (-not $Case.HasValidator) { return $null }
    $rejections = $Case.Rejections
    $failures = $Case.Failures
    return {
        param($dump)
        $global:validatorRuns++
        foreach ($failure in $failures) {
            if ($failure.Name -eq "*" -or $failure.Name -eq $dump.Name) { throw $failure.Message }
        }
        foreach ($rejection in $rejections) {
            if ($rejection.Name -eq "*" -or $rejection.Name -eq $dump.Name) { return $rejection.Reason }
        }
        return ""
    }.GetNewClosure()
}

function Invoke-DecisionCase([object]$Case) {
    $global:volumeIsEmpty = $Case.VolumeIsEmpty
    $global:volumeChecks = @()
    $global:validatorRuns = 0
    $folder = New-DumpFolder $Case
    if ($Case.Folder -eq "unlistable") { Set-FolderUnlistable $folder }
    return Get-RestoreDecision $volume $folder $Case.Pattern (New-Validator $Case) -AllowFresh $Case.AllowFresh 3>$null
}

$cases = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot "cases") -Filter "*.case" | Sort-Object Name | ForEach-Object { Read-DecisionCase $_ })
$canCreateSymlink = Test-CanCreateSymlink

Describe "Get-RestoreDecision over the shared cases" {
    It "finds the cases" { $cases.Count -gt 0 | Should Be $true }
    foreach ($case in $cases) {
        It $case.Name {
            if ($case.Links.Count -gt 0 -and -not $canCreateSymlink) {
                Set-TestInconclusive "this shell may not create symlinks (not elevated, no Developer Mode); the bash run on Linux covers the case"
                return
            }
            if ($case.ExpectedError) {
                $thrown = $null
                try { Invoke-DecisionCase $case | Out-Null } catch { $thrown = $_.Exception.Message }
                ($global:volumeChecks -join ",") | Should Be $volume
                $thrown | Should Be $case.ExpectedError
                if ($null -ne $case.ExpectedValidatorRuns) { $global:validatorRuns | Should Be $case.ExpectedValidatorRuns }
                return
            }
            $decision = Invoke-DecisionCase $case
            ($global:volumeChecks -join ",") | Should Be $volume
            $decision.Action | Should Be $case.ExpectedAction
            if ($case.ExpectedDump) { $decision.Dump.Name | Should Be $case.ExpectedDump } else { $decision.Dump | Should Be $null }
            $expectedRejected = ($case.ExpectedRejected -join "`n").Replace("{folder}", (Get-DumpFolder $case))
            (@($decision.Rejected | ForEach-Object { "$($_.Name)`t$($_.Reason)" }) -join "`n") | Should Be $expectedRejected
            if ($null -ne $case.ExpectedValidatorRuns) { $global:validatorRuns | Should Be $case.ExpectedValidatorRuns }
        }
    }
}

Describe "Get-CompleteDumps on an unlistable folder" {
    $folder = New-DumpFolder ([pscustomobject]@{ Name = "unlistable-direct"; Folder = "present"; Dumps = @(); Links = @() })

    It "throws, naming the folder, so no caller takes it for empty" {
        Set-FolderUnlistable $folder
        { Get-CompleteDumps $folder "app-*.dump" } | Should Throw "Cannot list $folder"
    }
    It "throws from Get-NewestDump too" {
        Set-FolderUnlistable $folder
        { Get-NewestDump $folder "app-*.dump" } | Should Throw "Cannot list $folder"
    }
    It "refuses a folder a real deny ACL makes unlistable, where the ACL denies" {
        $denied = Join-Path $scratch "unlistable-acl"
        New-Item -ItemType Directory -Path $denied | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $denied "app-20261019-200000.dump"), (New-Object byte[] 64))
        icacls $denied /deny "${currentUser}:(RD)" /Q | Out-Null
        try {
            if (-not (Test-ListingIsDenied $denied)) {
                Set-TestInconclusive "a deny ACL does not stop $currentUser from listing (an elevated shell); the mocked cases cover the decision"
                return
            }
            $global:volumeIsEmpty = $true
            (Get-RestoreDecision $volume $denied "app-*.dump" 3>$null).Action | Should Be "Refuse"
        }
        finally { icacls $denied /remove:d $currentUser /Q | Out-Null }
    }
}

Describe "Format-RestoreRefusal" {
    $refusal = Read-DecisionCase (Get-Item -LiteralPath (Join-Path $PSScriptRoot "cases\refuse-when-every-dump-is-rejected.case"))
    $refusal.Name = "refusal-text"
    $lines = Format-RestoreRefusal (Invoke-DecisionCase $refusal) $volume "data\backups" "up"

    It "names the volume" { $lines[0] | Should Match $volume }
    It "names every rejected dump with its reason" {
        @($lines | Where-Object { $_ -match "app-2026101.*: it holds no table data" }).Count | Should Be 2
    }
    It "says how to start fresh on purpose" { $lines[-1] | Should Match ([regex]::Escape(".\docker-compose.ps1 up -Fresh")) }
}

Describe "test cleanup" {
    It "removes its dump folders" {
        Remove-Item -LiteralPath $scratch -Recurse -Force
        Test-Path -LiteralPath $scratch | Should Be $false
    }
}
