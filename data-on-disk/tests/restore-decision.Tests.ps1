# Pester 3.4: the restore decision, with the volume check shadowed so no test reaches Docker.

. (Join-Path (Split-Path $PSScriptRoot) "data-on-disk.ps1")

$global:volumeIsEmpty = $true
$global:volumeChecks = @()
function Test-DatabaseVolumeIsEmpty([string]$Volume) {
    $global:volumeChecks += $Volume
    return $global:volumeIsEmpty
}

$dumps = Join-Path ([System.IO.Path]::GetTempPath()) "restore-decision-$([guid]::NewGuid().ToString('N'))"
$emptyFolder = Join-Path $dumps "empty"
New-Item -ItemType Directory -Path $dumps, $emptyFolder | Out-Null
foreach ($name in "app-20261019-190000.dump", "app-20261019-200000.dump") {
    [System.IO.File]::WriteAllBytes((Join-Path $dumps $name), (New-Object byte[] 64))
}

$rejectAll = { param($dump) "it holds no table data" }
$acceptAll = { param($dump) "" }
$rejectNewest = { param($dump) if ($dump.Name -eq "app-20261019-200000.dump") { "pg_restore cannot list it" } }

Describe "Get-RestoreDecision" {
    BeforeEach { $global:volumeIsEmpty = $true; $global:volumeChecks = @() }

    It "asks about the volume it was given" {
        Get-RestoreDecision "stack_db" $dumps "app-*.dump" $acceptAll | Out-Null
        $global:volumeChecks | Should Be @("stack_db")
    }
    It "refuses an empty volume when complete dumps exist but none is restorable" {
        $decision = Get-RestoreDecision "stack_db" $dumps "app-*.dump" $rejectAll
        $decision.Action | Should Be "Refuse"
        $decision.Dump | Should Be $null
        @($decision.Rejected.Name) | Should Be @("app-20261019-200000.dump", "app-20261019-190000.dump")
        @($decision.Rejected.Reason | Sort-Object -Unique) | Should Be @("it holds no table data")
    }
    It "starts fresh on that same volume with -Fresh" {
        (Get-RestoreDecision "stack_db" $dumps "app-*.dump" $rejectAll -AllowFresh $true).Action | Should Be "Fresh"
    }
    It "starts fresh with -Fresh even when a dump would restore" {
        (Get-RestoreDecision "stack_db" $dumps "app-*.dump" $acceptAll -AllowFresh $true).Action | Should Be "Fresh"
    }
    It "starts fresh on an empty volume with no dumps" {
        (Get-RestoreDecision "stack_db" $emptyFolder "app-*.dump" $rejectAll).Action | Should Be "Fresh"
    }
    It "starts fresh on an empty volume with a missing folder" {
        (Get-RestoreDecision "stack_db" (Join-Path $dumps "missing") "app-*.dump" $rejectAll).Action | Should Be "Fresh"
    }
    It "restores the newest restorable dump and lists the newer ones it skipped" {
        $decision = Get-RestoreDecision "stack_db" $dumps "app-*.dump" $rejectNewest
        $decision.Action | Should Be "Restore"
        $decision.Dump.Name | Should Be "app-20261019-190000.dump"
        @($decision.Rejected.Name) | Should Be @("app-20261019-200000.dump")
    }
    It "restores the newest dump when no validator is given" {
        (Get-RestoreDecision "stack_db" $dumps "app-*.dump").Dump.Name | Should Be "app-20261019-200000.dump"
    }
    foreach ($fresh in $false, $true) {
        It "never restores into a volume that holds data (-Fresh $fresh)" {
            $global:volumeIsEmpty = $false
            $decision = Get-RestoreDecision "stack_db" $dumps "app-*.dump" $acceptAll -AllowFresh $fresh
            $decision.Action | Should Be "Keep"
            $decision.Dump | Should Be $null
        }
    }
    It "does not run the validator for a volume that holds data" {
        $global:volumeIsEmpty = $false
        $global:validatorRuns = 0
        Get-RestoreDecision "stack_db" $dumps "app-*.dump" { param($dump) $global:validatorRuns++; "" } | Out-Null
        $global:validatorRuns | Should Be 0
    }
}

Describe "Format-RestoreRefusal" {
    $global:volumeIsEmpty = $true
    $lines = Format-RestoreRefusal (Get-RestoreDecision "stack_db" $dumps "app-*.dump" $rejectAll) "stack_db" "data\backups" "up"

    It "names the volume" { $lines[0] | Should Match "stack_db" }
    It "names every rejected dump with its reason" {
        @($lines | Where-Object { $_ -match "app-2026101.*: it holds no table data" }).Count | Should Be 2
    }
    It "says how to start fresh on purpose" { $lines[-1] | Should Match ([regex]::Escape(".\docker-compose.ps1 up -Fresh")) }
}

Describe "test cleanup" {
    It "removes its dump folder" {
        Remove-Item -LiteralPath $dumps -Recurse -Force
        Test-Path -LiteralPath $dumps | Should Be $false
    }
}
