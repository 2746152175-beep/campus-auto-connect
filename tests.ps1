[CmdletBinding()]
param()

# Run with Windows PowerShell 5.1. Every HTTP entry point is mocked before tests run.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $PSScriptRoot '.test-data'
$testDirectory = Join-Path $testRoot ('run-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testDirectory -Force
. (Join-Path $PSScriptRoot 'campus-login.ps1') -Mode Library -DataDirectory $testDirectory

$script:Passed = 0
$script:Failed = 0
$script:OriginalPortalState = ${function:Get-PortalState}
$script:FakeUsername = 'test-user+中文@example.invalid'
$script:FakePassword = 'test-only &+%=# 中文; $()'
$script:ValidHtml = 'Dr.COMWebLoginID_1.htm; ss5="10.9.8.7"; ss4="aa:bb:cc:dd:ee:ff";'

function Assert-Equal($Expected, $Actual, [string]$Reason = '') {
    if ($Expected -cne $Actual) { throw "Expected [$Expected], actual [$Actual]. $Reason" }
}

function Assert-True([bool]$Condition, [string]$Reason) {
    if (-not $Condition) { throw $Reason }
}

function Assert-Throws([scriptblock]$Action) {
    $thrown = $false
    try { $null = & $Action } catch { $thrown = $true }
    if (-not $thrown) { throw 'Expected an exception.' }
}

function Test-Case([string]$Name, [scriptblock]$Action) {
    try {
        & $Action
        $script:Passed++
        Write-Host "PASS $Name"
    } catch {
        $script:Failed++
        Write-Host "FAIL $Name -- $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Save-TestConfiguration {
    @{ PortalBaseUrl = 'http://10.2.5.251'; Username = $script:FakeUsername } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $DataDirectory 'settings.json') -Encoding UTF8
    $secret = ConvertTo-SecureString $script:FakePassword -AsPlainText -Force
    $fakeCredential = New-Object System.Management.Automation.PSCredential($script:FakeUsername, $secret)
    $fakeCredential | Export-Clixml -LiteralPath (Join-Path $DataDirectory 'credential.xml')
}

function Reset-Scenario {
    foreach ($name in @('auth-block.json', 'credential.xml', 'settings.json', 'status.json', 'status.tmp', 'connection.log')) {
        $path = Join-Path $DataDirectory $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Save-TestConfiguration
    $script:LastState = ''
    $script:Requests = New-Object 'System.Collections.Generic.List[string]'
    $script:LoginCalls = 0
    $script:ProfileCalls = 0
    $script:ImportCalls = 0
    $script:StateIndex = 0
    $script:States = @('Offline')
    $script:Html = $script:ValidHtml
    $script:LocalAddresses = @('10.9.8.7')
    $script:LoginReply = 'campusLogin({"result":1});'
    $script:ProfileError = $false
    $script:RejectCredentialRead = $false
}

# These replacements make accidental unmocked HTTP calls fail closed.
function Invoke-PortalGet([string]$Url) {
    $script:Requests.Add($Url)
    $uri = [uri]$Url
    if ($uri.Host -ne '10.2.5.251') { throw 'Unexpected host in mocked request.' }
    if ($uri.AbsolutePath -eq '/') { return $script:Html }
    if ($uri.AbsolutePath -eq '/eportal/' -and $uri.Query -match 'a=login') {
        $script:LoginCalls++
        return $script:LoginReply
    }
    if ($uri.AbsolutePath -eq '/drcom/chkstatus') { return $script:StatusReply }
    throw 'Unexpected URL: all tests prohibit network access.'
}

function Get-LocalIPv4Addresses { return $script:LocalAddresses }
function Get-LoginProfile($Context) {
    $script:ProfileCalls++
    if ($script:ProfileError) { throw 'Simulated changed portal profile.' }
    return [pscustomobject]@{ Index = 1; Method = '1' }
}
function Get-PortalState {
    $index = [Math]::Min($script:StateIndex, $script:States.Count - 1)
    $script:StateIndex++
    $state = $script:States[$index]
    if ($state -eq 'Throw') { throw 'Simulated unavailable status.' }
    return $state
}
function Import-Clixml([string]$LiteralPath) {
    $script:ImportCalls++
    Assert-True ($LiteralPath -eq (Join-Path $testDirectory 'credential.xml')) 'Attempt to read credentials outside the isolated test directory.'
    if ($script:RejectCredentialRead) { throw 'Online cycles must not read credentials.' }
    return Microsoft.PowerShell.Utility\Import-Clixml -LiteralPath $LiteralPath
}
function Start-Sleep { param([int]$Seconds) }

try {
    Test-Case 'JSON and JSONP are parsed as data' {
        Assert-Equal '1' ([string](ConvertFrom-PortalJson '{"result":1}').result)
        Assert-Equal '0' ([string](ConvertFrom-PortalJson 'campusStatus({"result":0});').result)
        Assert-Equal 'ok' (ConvertFrom-PortalJson ([char]0xFEFF + ' callback_1 ({"result":"ok"});')).result
    }
    Test-Case 'JSONP rejects executable or appended content' {
        $script:UnexpectedExecution = $false
        foreach ($payload in @(
            'campusStatus({"result":1}); $script:UnexpectedExecution=$true',
            'campusStatus({"result":1}); anotherCallback({"result":0});',
            'function callback(){ return {"result":1}; }',
            '{"result":$(Set-Variable UnexpectedExecution $true -Scope Script)}',
            'campusStatus({"result":1}, {"result":0});'
        )) { Assert-Throws { ConvertFrom-PortalJson $payload } }
        Assert-Equal $false $script:UnexpectedExecution
    }
    Test-Case 'Special characters survive URL encoding without adding fields' {
        $context = [pscustomobject]@{ IP = '10.9.8.7'; Mac = 'aabbccddeeff' }
        $uri = [uri](New-LoginUrl $context $script:FakeUsername $script:FakePassword)
        $query = @{}
        foreach ($pair in $uri.Query.TrimStart('?').Split('&')) {
            $parts = $pair.Split('=', 2)
            $query[[uri]::UnescapeDataString($parts[0])] = [uri]::UnescapeDataString($parts[1])
        }
        Assert-Equal 11 $query.Count
        Assert-Equal $script:FakeUsername $query['user_account']
        Assert-Equal $script:FakePassword $query['user_password']
        Assert-Equal '' $uri.Fragment
        Assert-Equal '10.2.5.251' $uri.Host
        Assert-Equal 801 $uri.Port
    }
    Test-Case 'Last matching enabled IP profile wins, including multiple ranges' {
        $config = @'
pageSetting = 2;
ipPageAry[0] = "default|||||1|1";
ipPageAry[1] = "first|10.0.0.0|10.255.255.255|||1|1";
ipPageAry[2] = "last|10.8.0.0;10.9.8.0|10.8.255.255;10.9.8.255|||1|1";
ipPageAry[3] = "disabled|10.9.8.0|10.9.8.255|||0|0";
'@
        Assert-Equal 2 (Resolve-LoginProfile $config '10.9.8.7').Index
        Assert-Equal 0 (Resolve-LoginProfile $config '192.0.2.4').Index
        $unsupported = $config + "`nipPageAry[4] = `"other|10.9.8.0|10.9.8.255|||1|0`";"
        Assert-Throws { Resolve-LoginProfile $unsupported '10.9.8.7' }
        Assert-Throws { Resolve-LoginProfile 'pageSetting=2; ipPageAry[1]="bad|10.0.0.0;10.1.0.0|10.255.255.255|||1|1";' '10.9.8.7' }
    }
    Test-Case 'IPv4 comparison covers unsigned range and rejects IPv6' {
        Assert-Equal ([uint64]4294967295) (ConvertTo-IPv4Number '255.255.255.255')
        Assert-Equal ([uint64]0) (ConvertTo-IPv4Number '0.0.0.0')
        Assert-Throws { ConvertTo-IPv4Number '::1' }
    }
    Test-Case 'Portal context validates local IP and normalizes MAC' {
        Reset-Scenario
        $context = Get-PortalContext $script:ValidHtml
        Assert-Equal '10.9.8.7' $context.IP
        Assert-Equal 'aabbccddeeff' $context.Mac
        Assert-Equal '10.9.8.7' (Get-PortalContext 'Dr.COMWebLoginID_1.htm; ss3="0a090807";').IP
        Assert-Equal '10.9.8.7' (Get-PortalContext 'Dr.COMWebLoginID_1.htm; ss5="0.0.0.0"; v4ip="10.9.8.7";').IP
        Assert-Throws { Get-PortalContext 'Dr.COMWebLoginID_1.htm; ss5="10.9.8.7"; ss4="bad";' }
    }
    Test-Case 'Status parser rejects unknown results' {
        Reset-Scenario
        $script:StatusReply = 'campusStatus({"result":1});'
        Assert-Equal 'Online' (& $script:OriginalPortalState)
        $script:StatusReply = 'campusStatus({"result":0});'
        Assert-Equal 'Offline' (& $script:OriginalPortalState)
        $script:StatusReply = 'campusStatus({"result":2});'
        Assert-Throws { & $script:OriginalPortalState }
    }
    Test-Case 'Already online never reads credentials or sends login' {
        Reset-Scenario
        $script:States = @('Online')
        $script:RejectCredentialRead = $true
        Assert-Equal 'Online' (Invoke-ConnectionCycle).State
        Assert-Equal 0 $script:ImportCalls
        Assert-Equal 0 $script:Requests.Count
        Assert-Equal 0 $script:ProfileCalls
    }
    Test-Case 'Unavailable status waits without reading credentials' {
        Reset-Scenario
        $script:States = @('Throw')
        Assert-Equal 'WaitingForNetwork' (Invoke-ConnectionCycle).State
        Assert-Equal 0 $script:ImportCalls
        Assert-Equal 0 $script:LoginCalls
    }
    Test-Case 'Missing configuration requires setup' {
        Reset-Scenario
        Remove-Item -LiteralPath (Join-Path $DataDirectory 'credential.xml')
        Assert-Equal 'NeedsSetup' (Invoke-ConnectionCycle).State
        Assert-Equal 0 $script:LoginCalls
    }
    Test-Case 'Non-DrCOM page blocks submission' {
        Reset-Scenario
        $script:Html = '<html>Unrelated hotspot</html>'
        Assert-Equal 'NeedsAttention' (Invoke-ConnectionCycle).State
        Assert-Equal 0 $script:LoginCalls
        Assert-Equal 0 $script:ProfileCalls
    }
    Test-Case 'Mismatched local IP blocks submission' {
        Reset-Scenario
        $script:LocalAddresses = @('192.0.2.1')
        Assert-Equal 'NeedsAttention' (Invoke-ConnectionCycle).State
        Assert-Equal 0 $script:LoginCalls
    }
    Test-Case 'Changed login profile blocks submission' {
        Reset-Scenario
        $script:ProfileError = $true
        Assert-Equal 'NeedsAttention' (Invoke-ConnectionCycle).State
        Assert-Equal 0 $script:LoginCalls
    }
    Test-Case 'Browser authentication between checks avoids duplicate submission' {
        Reset-Scenario
        $script:States = @('Offline', 'Online')
        Assert-Equal 'Online' (Invoke-ConnectionCycle).State
        Assert-Equal 0 $script:LoginCalls
    }
    Test-Case 'Authentication rejection persists and blocks subsequent submissions' {
        Reset-Scenario
        $script:LoginReply = 'campusLogin({"result":0});'
        Assert-Equal 'AuthRejected' (Invoke-ConnectionCycle).State
        Assert-Equal 1 $script:LoginCalls
        Assert-True (Test-Path -LiteralPath (Join-Path $DataDirectory 'auth-block.json')) 'Rejection was not persisted.'
        # Reset transient state only, as would happen after restarting the worker.
        $script:LastState = ''
        $script:StateIndex = 0
        Assert-Equal 'AuthRejected' (Invoke-ConnectionCycle).State
        Assert-Equal 1 $script:LoginCalls
    }
    Test-Case 'Updating configuration clears rejection through a new configuration stamp' {
        Reset-Scenario
        $script:LoginReply = 'campusLogin({"result":0});'
        Assert-Equal 'AuthRejected' (Invoke-ConnectionCycle).State
        $settingsFile = Get-Item -LiteralPath (Join-Path $DataDirectory 'settings.json')
        $settingsFile.LastWriteTimeUtc = $settingsFile.LastWriteTimeUtc.AddSeconds(3)
        $script:LoginReply = 'campusLogin({"result":1});'
        $script:States = @('Offline', 'Offline', 'Online')
        $script:StateIndex = 0
        Assert-Equal 'Online' (Invoke-ConnectionCycle).State
        Assert-Equal 2 $script:LoginCalls
    }
    Test-Case 'Accepted response without verified online status stays RetryLater' {
        Reset-Scenario
        Assert-Equal 'RetryLater' (Invoke-ConnectionCycle).State
        Assert-Equal 1 $script:LoginCalls
        Reset-Scenario
        $script:States = @('Offline', 'Offline', 'Throw')
        Assert-Equal 'RetryLater' (Invoke-ConnectionCycle).State
    }
    Test-Case 'Malformed and unknown login responses cannot claim Online' {
        foreach ($reply in @('<html>failure</html>', 'campusLogin({"result":"unknown"});')) {
            Reset-Scenario
            $script:LoginReply = $reply
            Assert-Equal 'RetryLater' (Invoke-ConnectionCycle).State
            Assert-Equal 1 $script:LoginCalls
        }
    }
    Test-Case 'Status and logs omit credentials and server-provided failure text' {
        Reset-Scenario
        $script:LoginReply = @{ result = 0; msg = $script:FakeUsername + $script:FakePassword } | ConvertTo-Json -Compress
        $cycle = Invoke-ConnectionCycle
        $null = Write-LocalStatus $cycle.State $cycle.Message
        foreach ($name in @('status.json', 'connection.log', 'auth-block.json')) {
            $contents = Get-Content -LiteralPath (Join-Path $DataDirectory $name) -Raw -Encoding UTF8
            Assert-True (-not $contents.Contains($script:FakeUsername)) 'Status or log contains a username.'
            Assert-True (-not $contents.Contains($script:FakePassword)) 'Status or log contains a password.'
        }
    }
} finally {
    # Restrict cleanup to the uniquely created direct child of this workspace's test directory.
    $resolvedRoot = [System.IO.Path]::GetFullPath($testRoot).TrimEnd('\') + '\'
    $resolvedRun = [System.IO.Path]::GetFullPath($testDirectory)
    if ($resolvedRun.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Path]::GetFileName($resolvedRun) -match '^run-[0-9a-f]{32}$') {
        if (Test-Path -LiteralPath $resolvedRun) { Remove-Item -LiteralPath $resolvedRun -Recurse -Force }
    } else { throw 'Refused to clean up an unexpected test path.' }
}

Write-Host "Tests: $script:Passed passed; $script:Failed failed. No network requests were made."
if ($script:Failed -gt 0) { exit 1 }
