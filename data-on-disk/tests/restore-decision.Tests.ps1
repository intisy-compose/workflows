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
        Dumps = @(); Links = @(); HasValidator = $true; Rejections = @(); AllowFresh = $false
        ExpectedAction = $null; ExpectedDump = $null; ExpectedRejected = @(); ExpectedValidatorRuns = $null
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
            "fresh" { $case.AllowFresh = ($value -eq "true") }
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
    if ($Case.Folder -eq "unlistable") { icacls $folder /deny "${currentUser}:(RD)" /Q | Out-Null }
    return $folder
}

function Undo-DumpFolderDenial([object]$Case) {
    if ($Case.Folder -eq "unlistable") { icacls (Get-DumpFolder $Case) /remove:d $currentUser /Q | Out-Null }
}

function New-Validator([object]$Case) {
    if (-not $Case.HasValidator) { return $null }
    $rejections = $Case.Rejections
    return {
        param($dump)
        $global:validatorRuns++
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
    try { return Get-RestoreDecision $volume (New-DumpFolder $Case) $Case.Pattern (New-Validator $Case) -AllowFresh $Case.AllowFresh 3>$null }
    finally { Undo-DumpFolderDenial $Case }
}

$cases = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot "cases") -Filter "*.case" | Sort-Object Name | ForEach-Object { Read-DecisionCase $_ })

Describe "Get-RestoreDecision over the shared cases" {
    It "finds the cases" { $cases.Count -gt 0 | Should Be $true }
    foreach ($case in $cases) {
        It $case.Name {
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
    $unlistable = [pscustomobject]@{ Name = "unlistable-direct"; Folder = "unlistable"; Dumps = @(); Links = @() }
    $folder = New-DumpFolder $unlistable
    try {
        It "throws, naming the folder, so no caller takes it for empty" {
            { Get-CompleteDumps $folder "app-*.dump" } | Should Throw "Cannot list $folder"
        }
        It "throws from Get-NewestDump too" {
            { Get-NewestDump $folder "app-*.dump" } | Should Throw "Cannot list $folder"
        }
    }
    finally { Undo-DumpFolderDenial $unlistable }
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
