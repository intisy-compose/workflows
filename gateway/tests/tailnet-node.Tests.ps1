# The PowerShell twin of the tailnet node helper, with Invoke-WebRequest mocked as a fake Tailscale API
# over a list of devices, so no real API is called. Pester 3.4 syntax (`Should Be`).
$helper = Join-Path $PSScriptRoot "..\tailnet-node.ps1"
$token = "tskey-api-k123-SECRET456"

function New-StateText([string]$NodeId) {
    $current = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("profile-ab12"))
    $profiles = '{"cd34":{"ID":"cd34","Key":"profile-cd34","NodeID":"nOLDER99CNTRL"},"ab12":{"ID":"ab12","Key":"profile-ab12","NodeID":"' + $NodeId + '"}}'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($profiles))
    return '{"_current-profile":"' + $current + '","_profiles":"' + $encoded + '","_machinekey":"cHJpdmtleQ=="}'
}

function New-ApiError([int]$Code) {
    $exception = New-Object System.Exception "The remote server returned an error: ($Code)."
    if ($Code -ne 0) { $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Code }) }
    return $exception
}

Describe "the tailnet node helper" {
    . $helper
    $folder = Join-Path $TestDrive "stack\data\tailscale"
    $config = Join-Path $TestDrive "stack\config.env"

    function Reset-Stack([string]$TokenLine = "TS_API_TOKEN=$token") {
        if (Test-Path $folder) { Remove-Item $folder -Recurse -Force }
        New-Item -ItemType Directory -Force $folder | Out-Null
        [IO.File]::WriteAllText((Join-Path $folder "tailscaled.state"), (New-StateText "nOURS123CNTRL"))
        [IO.File]::WriteAllText($config, "TS_HOSTNAME=inventree`n$TokenLine`n")
        $script:devices = [System.Collections.ArrayList]@("nOURS123CNTRL inventree", "nOTHER45CNTRL inventree", "nDESK678CNTRL desktop")
        $script:calls = [System.Collections.ArrayList]@()
        $script:answer = $null
    }

    Mock Write-Host { $script:printed += "$Object`n" }
    Mock Invoke-WebRequest {
        [void]$script:calls.Add([pscustomobject]@{ Method = "$Method"; Uri = "$Uri"; Headers = $Headers })
        if ($script:answer -ne $null) {
            if ($script:answer -eq 200) { return [pscustomobject]@{ StatusCode = 200 } }
            throw (New-ApiError $script:answer)
        }
        $node = "$Uri".Substring("$Uri".LastIndexOf("/") + 1)
        $entry = $script:devices | Where-Object { $_ -like "$node *" }
        if ("$Method" -eq "Delete" -and $entry) {
            $script:devices.Remove($entry)
            return [pscustomobject]@{ StatusCode = 200 }
        }
        throw (New-ApiError 404)
    }

    Context "reading the node ID" {
        It "takes the current profile's node, not an older profile's" {
            Get-TailnetNodeId (New-StateText "nOURS123CNTRL") | Should Be "nOURS123CNTRL"
        }
        It "gives nothing for a state that is not JSON or names no current node" {
            Get-TailnetNodeId "not json" | Should Be $null
            Get-TailnetNodeId "{}" | Should Be $null
            Get-TailnetNodeId '{"_current-profile":"cHJvZmlsZS16eg==","_profiles":"e30="}' | Should Be $null
            Get-TailnetNodeId "" | Should Be $null
        }
        It "refuses a node ID that would change the API URL" {
            Get-TailnetNodeId (New-StateText "n1/../../tailnet") | Should Be $null
        }
    }

    Context "removing the node" {
        It "removes the node with the state's ID, then the state folder" {
            Reset-Stack; $script:printed = ""
            Remove-TailnetIdentity $folder "inventree.tail-test.ts.net" $config | Should Be $true
            $script:calls.Count | Should Be 1
            $script:calls[0].Method | Should Be "Delete"
            $script:calls[0].Uri | Should Be "https://api.tailscale.com/api/v2/device/nOURS123CNTRL"
            $script:calls[0].Headers.Authorization | Should Be "Bearer $token"
            ($script:devices -like "nOURS123CNTRL *").Count | Should Be 0
            $script:printed | Should Match "Removed inventree\.tail-test\.ts\.net from the tailnet\."
            Test-Path $folder | Should Be $false
            $script:printed | Should Match "the next up joins the tailnet fresh\."
        }
        It "leaves a node with the same name alone" {
            Reset-Stack
            Remove-TailnetIdentity $folder "inventree" $config | Should Be $true
            ($script:devices -like "nOTHER45CNTRL *").Count | Should Be 1
            ($script:devices -like "nDESK678CNTRL *").Count | Should Be 1
            ($script:calls | Where-Object { $_.Uri -match "nOLDER99CNTRL" }).Count | Should Be 0
        }
        It "carries the token only as a header, never in the URL or the output" {
            Reset-Stack; $script:printed = ""
            Remove-TailnetIdentity $folder "inventree" $config | Out-Null
            $script:calls[0].Uri | Should Not Match "tskey"
            $script:printed | Should Not Match "SECRET456"
        }
        It "prints the manual step without TS_API_TOKEN and still clears the folder" {
            Reset-Stack "TS_API_TOKEN="; $script:printed = ""
            Remove-TailnetIdentity $folder "inventree.tail-test.ts.net" $config | Should Be $true
            $script:calls.Count | Should Be 0
            $script:printed | Should Match "No TS_API_TOKEN in config\.env, so inventree\.tail-test\.ts\.net stays in the tailnet\."
            $script:printed | Should Match "Remove inventree\.tail-test\.ts\.net \(node ID nOURS123CNTRL\) on the Machines page: https://login\.tailscale\.com/admin/machines"
            Test-Path $folder | Should Be $false
            ($script:devices -like "nOURS123CNTRL *").Count | Should Be 1
        }
        It "counts a config without the line as no token" {
            Reset-Stack "# nothing"
            Remove-TailnetNode "nOURS123CNTRL" "inventree" $config | Should Be "manual"
            $script:calls.Count | Should Be 0
        }
        It "reads a quoted token" {
            Reset-Stack "TS_API_TOKEN=`"$token`""
            Remove-TailnetNode "nOURS123CNTRL" "inventree" $config | Should Be "gone"
            $script:calls[0].Headers.Authorization | Should Be "Bearer $token"
        }
        It "counts a node the tailnet no longer has as gone" {
            Reset-Stack; $script:printed = ""
            $script:devices = [System.Collections.ArrayList]@("nOTHER45CNTRL inventree")
            Remove-TailnetIdentity $folder "inventree" $config | Should Be $true
            $script:printed | Should Match "The tailnet has no node nOURS123CNTRL any more, so there is nothing to remove\."
            Test-Path $folder | Should Be $false
        }
        It "refuses a token that is not one before any call" {
            Reset-Stack 'TS_API_TOKEN=tskey" -o x'; $script:printed = ""
            Remove-TailnetIdentity $folder "inventree" $config | Should Be $false
            $script:calls.Count | Should Be 0
            $script:printed | Should Match "TS_API_TOKEN in config\.env is not a Tailscale API token"
            Test-Path (Join-Path $folder "tailscaled.state") | Should Be $true
        }
    }

    Context "an API error" {
        foreach ($code in 401, 403, 500, 0) {
            It "keeps everything locally on $code and says so" {
                Reset-Stack; $script:printed = ""
                $script:answer = $code
                Remove-TailnetIdentity $folder "inventree" $config | Should Be $false
                Test-Path (Join-Path $folder "tailscaled.state") | Should Be $true
                $script:printed | Should Match "is kept, so delete can run again\."
                $script:printed | Should Match "Remove inventree \(node ID nOURS123CNTRL\) on the Machines page"
                $script:printed | Should Not Match "Removed inventree"
                if ($code -eq 0) { $script:printed | Should Match "The Tailscale API did not answer, so inventree was not removed\." }
                elseif ($code -eq 500) { $script:printed | Should Match "The Tailscale API answered HTTP 500, so inventree was not removed\." }
                else { $script:printed | Should Match "The Tailscale API refused TS_API_TOKEN \(HTTP $code\)" }
            }
        }
    }

    Context "a state that identifies no node" {
        It "removes nothing, here or in the tailnet, when the state names no node" {
            Reset-Stack; $script:printed = ""
            [IO.File]::WriteAllText((Join-Path $folder "tailscaled.state"), "{}")
            Remove-TailnetIdentity $folder "inventree" $config | Should Be $false
            $script:calls.Count | Should Be 0
            Test-Path (Join-Path $folder "tailscaled.state") | Should Be $true
            $script:printed | Should Match "Remove inventree on the Machines page, https://login\.tailscale\.com/admin/machines, then delete"
        }
        It "removes no node and clears the folder when there is no state" {
            Reset-Stack; $script:printed = ""
            Remove-Item (Join-Path $folder "tailscaled.state")
            Remove-TailnetIdentity $folder "inventree" $config | Should Be $true
            $script:calls.Count | Should Be 0
            $script:printed | Should Match "No node identity in"
            Test-Path $folder | Should Be $false
        }
        It "is fine without a state folder at all" {
            Reset-Stack
            Remove-Item $folder -Recurse -Force
            Remove-TailnetIdentity $folder "inventree" $config | Should Be $true
            $script:calls.Count | Should Be 0
        }
    }
}
