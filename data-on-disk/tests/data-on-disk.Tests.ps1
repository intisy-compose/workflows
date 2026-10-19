# Pester 3.4: runs against real Docker (alpine:3.21, postgres:17.10-alpine) and removes everything it creates.

. (Join-Path (Split-Path $PSScriptRoot) "data-on-disk.ps1")

$runId = [guid]::NewGuid().ToString("N").Substring(0, 8)
$emptyVolume = "dod-test-empty-$runId"
$postgresVolume = "dod-test-pg-$runId"
$pg0Volume = "dod-test-pg0-$runId"
$postgresContainer = "dod-test-postgres-$runId"
$dumps = Join-Path ([System.IO.Path]::GetTempPath()) "dod-test-dumps-$runId"
$emptyFolder = Join-Path ([System.IO.Path]::GetTempPath()) "dod-test-empty-$runId"

function Initialize-Volume([string]$Volume, [string]$Command) {
    docker volume create $Volume | Out-Null
    docker run --rm -v "${Volume}:/v" alpine:3.21 sh -c $Command | Out-Null
}

function Wait-PostgresReady([string]$Container) {
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        docker exec $Container pg_isready -U postgres 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Start-Sleep -Seconds 1
            return
        }
        Start-Sleep -Seconds 1
    }
    throw "postgres in $Container did not become ready"
}

function Remove-Fixtures {
    $ErrorActionPreference = 'Continue'
    docker rm -f $postgresContainer 2>$null | Out-Null
    foreach ($volume in @($emptyVolume, $postgresVolume, $pg0Volume)) { docker volume rm -f $volume 2>$null | Out-Null }
    foreach ($folder in @($dumps, $emptyFolder)) {
        if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
    }
}

try {
    $ErrorActionPreference = 'Continue'
    New-Item -ItemType Directory -Path $dumps, $emptyFolder | Out-Null
    foreach ($name in "app-20261019-190000.dump", "app-20261019-200000.dump") {
        [System.IO.File]::WriteAllBytes((Join-Path $dumps $name), (New-Object byte[] 1024))
    }
    New-Item -ItemType File -Path (Join-Path $dumps "app-20261019-210000.dump") | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $dumps "app-20261019-220000.dump.tmp"), (New-Object byte[] 1024))

    docker volume create $emptyVolume | Out-Null
    Initialize-Volume $postgresVolume "echo 17 > /v/PG_VERSION"
    Initialize-Volume $pg0Volume "mkdir -p /v/instances/x/data && echo 17 > /v/instances/x/data/PG_VERSION"

    docker run -d --name $postgresContainer -e POSTGRES_HOST_AUTH_METHOD=trust postgres:17.10-alpine | Out-Null
    Wait-PostgresReady $postgresContainer
    docker exec $postgresContainer psql -U postgres -c "create table items (id int); insert into items values (1),(2),(3);" | Out-Null
    $postgresPsqlPath = (docker exec $postgresContainer which psql).Trim()
}
catch {
    Remove-Fixtures
    throw
}

Describe "Test-DatabaseVolumeIsEmpty" {
    It "is true for a volume that does not exist" { Test-DatabaseVolumeIsEmpty "dod-test-missing-$([guid]::NewGuid())" | Should Be $true }
    It "is true for an empty volume" { Test-DatabaseVolumeIsEmpty $emptyVolume | Should Be $true }
    It "is false for a volume with PG_VERSION at its root" { Test-DatabaseVolumeIsEmpty $postgresVolume | Should Be $false }
    It "is false for a pg0 layout, PG_VERSION under instances/x/data" { Test-DatabaseVolumeIsEmpty $pg0Volume | Should Be $false }
}

Describe "Get-NewestDump" {
    It "takes the newest complete dump by name" { (Get-NewestDump $dumps "app-*.dump").Name | Should Be "app-20261019-200000.dump" }
    It "skips a newer .tmp and a newer zero-byte dump" { (Get-NewestDump $dumps "app-*.dump").Name | Should Not Match "tmp|210000" }
    It "skips a .tmp even when the pattern would match it" { (Get-NewestDump $dumps "app-*").Name | Should Be "app-20261019-200000.dump" }
    It "is null for an empty folder" { Get-NewestDump $emptyFolder "app-*.dump" | Should Be $null }
}

Describe "Get-TableRowCounts" {
    It "counts every table" { (Get-TableRowCounts $postgresContainer "127.0.0.1" "postgres" "postgres")["public.items"] | Should Be 3 }
    It "works with an explicit psql path" {
        (Get-TableRowCounts $postgresContainer "127.0.0.1" "postgres" "postgres" -Psql $postgresPsqlPath)["public.items"] | Should Be 3
    }
    It "accepts a password" {
        (Get-TableRowCounts $postgresContainer "127.0.0.1" "postgres" "postgres" -Password "unused")["public.items"] | Should Be 3
    }
    It "leaves out system tables" {
        $counts = Get-TableRowCounts $postgresContainer "127.0.0.1" "postgres" "postgres"
        @($counts.Keys | Where-Object { $_ -like "pg_catalog.*" -or $_ -like "information_schema.*" }).Count | Should Be 0
    }
}

Describe "Get-DumpToRestore" {
    It "is null for a volume holding PG_VERSION even with dumps present" { Get-DumpToRestore $postgresVolume $dumps "app-*.dump" | Should Be $null }
    It "is null for an empty volume and an empty folder" { Get-DumpToRestore $emptyVolume $emptyFolder "app-*.dump" | Should Be $null }
    It "is the newest complete dump for an empty volume" { (Get-DumpToRestore $emptyVolume $dumps "app-*.dump").Name | Should Be "app-20261019-200000.dump" }
}

Describe "fixture cleanup" {
    It "removes every volume, container and folder" {
        Remove-Fixtures
        (docker volume ls -q --filter "name=dod-test-" | Where-Object { $_ -like "*$runId" }) | Should Be $null
        (docker ps -aq --filter "name=$postgresContainer") | Should Be $null
    }
}
