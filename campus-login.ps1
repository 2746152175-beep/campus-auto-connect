[CmdletBinding()]
param(
    [ValidateSet('Once', 'Watch', 'Status', 'Library')]
    [string]$Mode = 'Watch',
    [string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'CampusAutoConnect')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:PortalBase = 'http://10.2.5.251'
$script:LastState = ''

function Get-Field($Object, [string]$Name, $Default = '') {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Invoke-PortalGet([string]$Url) {
    $uri = [uri]$Url
    if ($uri.Scheme -ne 'http' -or $uri.Host -ne '10.2.5.251' -or $uri.Port -notin @(80, 801) -or $uri.UserInfo) {
        throw '拒绝访问未配置的认证服务器。'
    }
    $request = [System.Net.HttpWebRequest]::Create($uri)
    $request.Proxy = $null
    $request.AllowAutoRedirect = $false
    $request.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $request.Timeout = 8000
    $request.ReadWriteTimeout = 8000
    $request.UserAgent = 'CampusAutoConnect/1.0'
    $request.Headers['Cache-Control'] = 'no-cache'
    $response = $null
    try {
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200) { throw 'Unexpected response' }
        $stream = $response.GetResponseStream()
        $memory = New-Object System.IO.MemoryStream
        try {
            $buffer = New-Object byte[] 8192
            while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                if ($memory.Length + $count -gt 2097152) { throw 'Response too large' }
                $memory.Write($buffer, 0, $count)
            }
            $encoding = [System.Text.Encoding]::UTF8
            if ($response.CharacterSet) {
                try { $encoding = [System.Text.Encoding]::GetEncoding($response.CharacterSet) } catch { }
            }
            return $encoding.GetString($memory.ToArray())
        } finally { $memory.Dispose(); $stream.Dispose() }
    } catch {
        # Never forward HTTP exception text: the school's JSONP URL contains credentials.
        throw '认证服务器暂不可达或响应异常。请确认已连接学校 Wi-Fi 或有线网络。'
    } finally { if ($null -ne $response) { $response.Dispose() } }
}

function ConvertFrom-PortalJson([string]$Text) {
    $body = $Text.Trim().TrimStart([char]0xFEFF).Trim()
    $match = [regex]::Match($body, '(?s)\A[A-Za-z_$][\w$]*\s*\(\s*(\{.*\})\s*\)\s*;?\s*\z')
    if ($match.Success) { $body = $match.Groups[1].Value }
    if (-not $body.StartsWith('{') -or -not $body.EndsWith('}')) { throw '无法识别认证服务器的响应。' }
    try { return ($body | ConvertFrom-Json) } catch { throw '无法识别认证服务器的响应。' }
}

function Get-PortalState {
    $reply = ConvertFrom-PortalJson (Invoke-PortalGet "$script:PortalBase/drcom/chkstatus?callback=campusStatus")
    $result = [string](Get-Field $reply 'result' 'unknown')
    if ($result -eq '1') { return 'Online' }
    if ($result -eq '0') { return 'Offline' }
    throw '认证服务器没有返回已知的在线状态。'
}

function Get-JsString([string]$Text, [string]$Name) {
    $pattern = '(?m)(?:^|[;\s])' + [regex]::Escape($Name) + '\s*=\s*[''"]([^''"\r\n]*)[''"]'
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return ''
}

function Get-LocalIPv4Addresses {
    foreach ($adapter in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($adapter.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        foreach ($address in $adapter.GetIPProperties().UnicastAddresses) {
            if ($address.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                $address.Address.ToString()
            }
        }
    }
}

function Get-PortalContext([string]$Html) {
    if ($Html -notmatch 'Dr\.COMWebLoginID_\d+\.htm') { throw '未识别到已核实的 Dr.COM 门户页面，已跳过认证。' }
    $ip = ''
    foreach ($name in @('ss5', 'v4ip', 'v46ip')) {
        $candidate = Get-JsString $Html $name
        if ($candidate -and $candidate -ne '0.0.0.0') { $ip = $candidate; break }
    }
    if (-not $ip) {
        $hex = Get-JsString $Html 'ss3'
        if ($hex -match '^[0-9a-fA-F]{8}$') {
            $ip = ((0..3 | ForEach-Object { [Convert]::ToInt32($hex.Substring($_ * 2, 2), 16) }) -join '.')
        }
    }
    if (-not $ip -or $ip -notin @(Get-LocalIPv4Addresses)) {
        throw '门户提供的地址与本机网卡不匹配。请检查校园网连接或 VPN。'
    }
    $mac = Get-JsString $Html 'ss4'
    if (-not $mac) { $mac = Get-JsString $Html 'olmac' }
    $mac = $mac -replace '[-:]', ''
    if (-not $mac) { $mac = '000000000000' }
    if ($mac -notmatch '^[0-9a-fA-F]{12}$') { throw '门户返回的设备参数格式异常。' }
    return [pscustomobject]@{ IP = $ip; Mac = $mac }
}

function ConvertTo-IPv4Number([string]$Address) {
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed) -or
        $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw 'IP 地址格式异常。' }
    $b = $parsed.GetAddressBytes()
    return ([uint64]$b[0] * 16777216 + [uint64]$b[1] * 65536 + [uint64]$b[2] * 256 + [uint64]$b[3])
}

function Resolve-LoginProfile([string]$ConfigText, [string]$IP) {
    if ($ConfigText -notmatch '\bpageSetting\s*=\s*2\s*;') { throw '学校已改变认证配置，需要更新工具。' }
    $entries = [regex]::Matches($ConfigText, 'ipPageAry\[(\d+)\]\s*=\s*"([^"\r\n]*)"\s*;')
    $selected = $null
    $number = ConvertTo-IPv4Number $IP
    foreach ($entry in $entries) {
        $index = [int]$entry.Groups[1].Value
        $parts = $entry.Groups[2].Value.Split('|')
        if ($parts.Count -lt 7) { continue }
        if ($index -eq 0) { $selected = [pscustomobject]@{ Index = 0; Method = $parts[-1] }; continue }
        if ($parts[5] -ne '1') { continue }
        $starts = $parts[1].Split(';'); $ends = $parts[2].Split(';')
        if ($starts.Count -ne $ends.Count) { throw '学校网段配置格式异常。' }
        for ($i = 0; $i -lt $starts.Count; $i++) {
            if ($number -ge (ConvertTo-IPv4Number $starts[$i]) -and $number -le (ConvertTo-IPv4Number $ends[$i])) {
                # The original portal uses the LAST matching enabled range.
                $selected = [pscustomobject]@{ Index = $index; Method = $parts[-1] }
                break
            }
        }
    }
    if ($null -eq $selected -or $selected.Method -ne '1') { throw '当前网段不使用已验证的 Portal 认证方式，请先手动登录。' }
    return $selected
}

function Get-LoginProfile($Context) {
    $pageScript = Invoke-PortalGet "$script:PortalBase/a41.js"
    foreach ($setting in @('accountPrefix', 'enMd5', 'enPerceive')) {
        if ($pageScript -notmatch ('\b' + $setting + '\s*=\s*0\s*;')) { throw '学校已改变登录流程，需要更新工具。' }
    }
    if ($pageScript -notmatch 'radiusIP\s*=\s*"10\.2\.5\.251"') { throw '门户配置与已核实的服务器不匹配。' }
    $configText = Invoke-PortalGet "$($script:PortalBase):801/eportal/extern/123/config.js"
    $profile = Resolve-LoginProfile $configText $Context.IP
    $form = Invoke-PortalGet "$($script:PortalBase):801/eportal/extern/123/ip/$($profile.Index)/pc.js"
    if ($form -notmatch 'name="ISP_select"' -or $form -match 'name="captcha"') {
        throw '登录表单已改变或需要验证码，请打开网页完成认证。'
    }
    return $profile
}

function New-LoginUrl($Context, [string]$Username, [string]$Password) {
    $fields = [ordered]@{
        c = 'Portal'; a = 'login'; callback = 'campusLogin'; login_method = '1'
        user_account = $Username; user_password = $Password
        wlan_user_ip = $Context.IP; wlan_user_mac = $Context.Mac
        wlan_ac_ip = ''; wlan_ac_name = ''; jsVersion = '3.0'
    }
    $pairs = foreach ($key in $fields.Keys) {
        [uri]::EscapeDataString([string]$key) + '=' + [uri]::EscapeDataString([string]$fields[$key])
    }
    return "$($script:PortalBase):801/eportal/?$($pairs -join '&')"
}

function Get-ConfigurationStamp {
    $settings = Get-Item -LiteralPath (Join-Path $DataDirectory 'settings.json')
    $credential = Get-Item -LiteralPath (Join-Path $DataDirectory 'credential.xml')
    return "$($settings.LastWriteTimeUtc.Ticks):$($credential.LastWriteTimeUtc.Ticks)"
}

function Write-LocalStatus([string]$State, [string]$Message) {
    if (-not (Test-Path -LiteralPath $DataDirectory)) { New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null }
    $data = [ordered]@{ State = $State; Message = $Message; UpdatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    $temp = Join-Path $DataDirectory 'status.tmp'
    $data | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination (Join-Path $DataDirectory 'status.json') -Force
    if ($script:LastState -ne "$State|$Message") {
        $log = Join-Path $DataDirectory 'connection.log'
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 262144) {
            Move-Item -LiteralPath $log -Destination (Join-Path $DataDirectory 'connection.previous.log') -Force
        }
        "$($data.UpdatedAt) [$State] $Message" | Add-Content -LiteralPath $log -Encoding UTF8
        $script:LastState = "$State|$Message"
    }
    return [pscustomobject]$data
}

function New-CycleResult([string]$State, [string]$Message, [int]$RetrySeconds = 60) {
    return [pscustomobject]@{ State = $State; Message = $Message; RetrySeconds = $RetrySeconds }
}

function Invoke-ConnectionCycle {
    try { $online = Get-PortalState } catch {
        return New-CycleResult 'WaitingForNetwork' '等待校园网络或认证服务器恢复。' 60
    }
    if ($online -eq 'Online') {
        return New-CycleResult 'Online' '已通过校园网认证；本轮无需登录。' 60
    }
    $settingsPath = Join-Path $DataDirectory 'settings.json'
    $credentialPath = Join-Path $DataDirectory 'credential.xml'
    if (-not (Test-Path -LiteralPath $settingsPath) -or -not (Test-Path -LiteralPath $credentialPath)) {
        return New-CycleResult 'NeedsSetup' '请先运行 Configure.cmd，填写账号密码并保存。' 60
    }
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ((Get-Field $settings 'PortalBaseUrl') -ne $script:PortalBase) { throw 'Invalid portal' }
        $credential = Import-Clixml -LiteralPath $credentialPath
        if ($credential -isnot [System.Management.Automation.PSCredential] -or
            $credential.UserName -ne (Get-Field $settings 'Username') -or $credential.Password.Length -eq 0) { throw 'Invalid credential' }
        $stamp = Get-ConfigurationStamp
    } catch {
        return New-CycleResult 'NeedsSetup' '配置无效或无法解密密码，请在当前 Windows 账户下重新配置。' 60
    }
    $blockPath = Join-Path $DataDirectory 'auth-block.json'
    if (Test-Path -LiteralPath $blockPath) {
        try { $block = Get-Content -LiteralPath $blockPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
            return New-CycleResult 'NeedsSetup' '暂停记录损坏，请打开配置窗口重新保存。' 60
        }
        if ((Get-Field $block 'ConfigurationStamp') -eq $stamp) {
            return New-CycleResult 'AuthRejected' '服务器拒绝了上次认证，已暂停重试。请检查账号、密码和运营商后重新保存。' 60
        }
    }
    try {
        $context = Get-PortalContext (Invoke-PortalGet "$script:PortalBase/")
        $null = Get-LoginProfile $context
    } catch {
        return New-CycleResult 'NeedsAttention' $_.Exception.Message 120
    }
    # Recheck after fetching the form: a browser may have authenticated in the meantime.
    try {
        if ((Get-PortalState) -eq 'Online') { return New-CycleResult 'Online' '已通过校园网认证；本轮无需登录。' 60 }
    } catch { return New-CycleResult 'WaitingForNetwork' '认证前状态检查失败，等待网络恢复。' 120 }
    if (Test-Path -LiteralPath (Join-Path $DataDirectory 'stop.flag')) {
        return New-CycleResult 'Stopped' '自动认证已停止，当前网络连接保持原状。' 60
    }
    $url = $null; $password = $null; $response = $null
    try {
        $password = $credential.GetNetworkCredential().Password
        $url = New-LoginUrl $context $credential.UserName $password
        $response = ConvertFrom-PortalJson (Invoke-PortalGet $url)
    } catch {
        return New-CycleResult 'RetryLater' '认证请求超时或响应异常，稍后先检查状态再重试。' 120
    } finally { $url = $null; $password = $null; $credential = $null }
    $result = [string](Get-Field $response 'result' 'unknown')
    if ($result -eq '0') {
        try {
            if ((Get-PortalState) -eq 'Online') { return New-CycleResult 'Online' '当前已通过校园网认证。' 60 }
        } catch { }
        # Persist rejection across restarts to avoid repeatedly submitting a wrong password.
        @{ ConfigurationStamp = $stamp } | ConvertTo-Json | Set-Content -LiteralPath $blockPath -Encoding UTF8
        return New-CycleResult 'AuthRejected' '服务器拒绝认证，已暂停重试。请检查账号、密码、运营商或账户状态后重新保存。' 60
    }
    if ($result -notin @('1', 'ok')) { return New-CycleResult 'RetryLater' '认证结果无法确认，稍后先检查状态再重试。' 120 }
    Start-Sleep -Seconds 2
    try {
        if ((Get-PortalState) -eq 'Online') { return New-CycleResult 'Online' '校园网自动认证成功。' 60 }
    } catch { }
    return New-CycleResult 'RetryLater' '服务器已接受认证，等待在线状态确认。' 120
}

function Start-CampusWorker {
    if ($Mode -eq 'Status') {
        try {
            $state = Get-PortalState
            [pscustomobject]@{ State = $state; Message = $(if ($state -eq 'Online') { '当前已通过校园网认证。' } else { '当前需要校园网认证。' }) } | ConvertTo-Json
        } catch { [pscustomobject]@{ State = 'Unknown'; Message = '无法读取校园网认证状态。' } | ConvertTo-Json }
        return
    }
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex = New-Object System.Threading.Mutex($false, "Local\CampusAutoConnect-$sid")
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(3000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { if ($Mode -eq 'Once') { Write-Output '后台程序已在运行，请在配置窗口查看状态。' }; return }
        $failureCount = 0
        do {
            if ($Mode -eq 'Watch' -and (Test-Path -LiteralPath (Join-Path $DataDirectory 'stop.flag'))) { break }
            try { $cycle = Invoke-ConnectionCycle } catch {
                $cycle = New-CycleResult 'NeedsAttention' '程序无法完成检查，请查看配置或重新安装。' 120
            }
            $stateRecord = Write-LocalStatus $cycle.State $cycle.Message
            if ($Mode -eq 'Once') { $stateRecord | ConvertTo-Json; break }
            $delay = $cycle.RetrySeconds
            if ($cycle.State -eq 'RetryLater') { $failureCount++; $delay = [Math]::Min(900, 120 * [Math]::Pow(2, [Math]::Min($failureCount - 1, 3))) }
            elseif ($cycle.State -eq 'Online') { $failureCount = 0 }
            $configStamp = ''
            try { $configStamp = Get-ConfigurationStamp } catch { }
            for ($elapsed = 0; $elapsed -lt $delay; $elapsed += 2) {
                if (Test-Path -LiteralPath (Join-Path $DataDirectory 'stop.flag')) { break }
                Start-Sleep -Seconds 2
                try { if ((Get-ConfigurationStamp) -ne $configStamp) { break } } catch { }
            }
        } while ($Mode -eq 'Watch')
        if ($Mode -eq 'Watch') { $null = Write-LocalStatus 'Stopped' '自动认证已停止，当前网络连接保持原状。' }
    } finally { if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

if ($Mode -ne 'Library') { Start-CampusWorker }
