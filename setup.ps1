[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:InstallDirectory = Join-Path $env:LOCALAPPDATA 'CampusAutoConnect'
$script:SettingsPath = Join-Path $script:InstallDirectory 'settings.json'
$script:CredentialPath = Join-Path $script:InstallDirectory 'credential.xml'
$script:InstalledScript = Join-Path $script:InstallDirectory 'campus-login.ps1'
$script:SourceScript = Join-Path $PSScriptRoot 'campus-login.ps1'
$script:StartupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'CampusAutoConnect.lnk'
$script:PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:StopFlagPath = Join-Path $script:InstallDirectory 'stop.flag'
$script:AuthBlockPath = Join-Path $script:InstallDirectory 'auth-block.json'
$script:StatusPath = Join-Path $script:InstallDirectory 'status.json'

function Get-CompleteUsername {
    $username = $script:UsernameBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($username)) {
        throw '请填写校园网账号。'
    }
    if ($username -match '[\r\n\x00]') {
        throw '账号不能包含换行或空字符。'
    }
    $suffix = ''
    switch ($script:OperatorBox.SelectedIndex) {
        2 { $suffix = '@telecom' }
        3 { $suffix = '@cmcc' }
        4 { $suffix = '@unicom' }
        5 { $suffix = $script:SuffixBox.Text.Trim() }
    }
    if ($script:OperatorBox.SelectedIndex -eq 5) {
        if ([string]::IsNullOrWhiteSpace($suffix)) {
            throw '已选择自定义后缀，请填写学校实际使用的完整后缀。'
        }
        if ($suffix -match '[\s\x00]') {
            throw '后缀不能包含空白或空字符。'
        }
    }
    if (-not [string]::IsNullOrEmpty($suffix)) {
        if (($username -match '@(telecom|cmcc|unicom)$') -and
            (-not $username.EndsWith($suffix, [StringComparison]::Ordinal))) {
            throw '账号已包含不同的运营商后缀，请修正账号或选择“账号已含后缀 / 不添加”。'
        }
        if (-not $username.EndsWith($suffix, [StringComparison]::Ordinal)) {
            $username += $suffix
        }
    }
    return $username
}

function Set-StartupShortcut {
    param([bool]$Enabled)

    if (-not $Enabled) {
        if (Test-Path -LiteralPath $script:StartupShortcut) {
            Remove-Item -LiteralPath $script:StartupShortcut -Force -ErrorAction Stop
        }
        return
    }

    $startupDirectory = Split-Path -Parent $script:StartupShortcut
    if (-not (Test-Path -LiteralPath $startupDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $startupDirectory -Force)
    }
    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($script:StartupShortcut)
        $shortcut.TargetPath = $script:PowerShellExe
        $shortcut.Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Mode Watch' -f $script:InstalledScript
        $shortcut.WorkingDirectory = $script:InstallDirectory
        $shortcut.Description = '登录 Windows 后，自动完成校园网认证。'
        $shortcut.WindowStyle = 7
        $shortcut.Save()
        if (-not (Test-Path -LiteralPath $script:StartupShortcut -PathType Leaf)) {
            throw '未能创建当前 Windows 账户的自启动快捷方式。'
        }
    }
    finally {
        if ($null -ne $shortcut) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        }
        if ($null -ne $shell) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function Save-LocalConfiguration {
    param([bool]$StartNow = $false)

    $username = Get-CompleteUsername
    $credential = $null
    $newSecurePassword = $null
    $temporaryFiles = New-Object 'System.Collections.Generic.List[string]'
    try {
        if ([string]::IsNullOrEmpty($script:PasswordBox.Text)) {
            if (-not (Test-Path -LiteralPath $script:CredentialPath -PathType Leaf)) {
                throw '首次配置时必须填写密码。'
            }
            try {
                $credential = Import-Clixml -LiteralPath $script:CredentialPath -ErrorAction Stop
            }
            catch {
                throw '无法读取本机保存的密码，请重新填写密码。'
            }
            if (($credential -isnot [Management.Automation.PSCredential]) -or
                ($credential.UserName -cne $username) -or
                ($credential.Password.Length -eq 0)) {
                throw '账号已更改或保存的凭据无效，请填写该账号的密码。'
            }
        }
        else {
            $newSecurePassword = ConvertTo-SecureString -String $script:PasswordBox.Text -AsPlainText -Force
            $credential = New-Object Management.Automation.PSCredential ($username, $newSecurePassword)
        }

        if (-not (Test-Path -LiteralPath $script:SourceScript -PathType Leaf)) {
            throw '找不到 campus-login.ps1，请保留它与 setup.ps1 在同一文件夹。'
        }
        if (-not (Test-Path -LiteralPath $script:InstallDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $script:InstallDirectory -Force)
        }

        $suffix = [Guid]::NewGuid().ToString('N')
        $stagedScript = Join-Path $script:InstallDirectory ('program-' + $suffix + '.tmp')
        $stagedCredential = Join-Path $script:InstallDirectory ('credential-' + $suffix + '.tmp')
        $stagedSettings = Join-Path $script:InstallDirectory ('settings-' + $suffix + '.tmp')
        $temporaryFiles.Add($stagedScript)
        $temporaryFiles.Add($stagedCredential)
        $temporaryFiles.Add($stagedSettings)

        Copy-Item -LiteralPath $script:SourceScript -Destination $stagedScript -Force
        $credential | Export-Clixml -LiteralPath $stagedCredential -Encoding UTF8 -Force
        [ordered]@{
            PortalBaseUrl = 'http://10.2.5.251'
            Username = $username
            PollSeconds = 60
        } | ConvertTo-Json | Set-Content -LiteralPath $stagedSettings -Encoding UTF8

        # Publish settings last so an existing watcher can detect an account mismatch.
        Move-Item -LiteralPath $stagedScript -Destination $script:InstalledScript -Force
        Move-Item -LiteralPath $stagedCredential -Destination $script:CredentialPath -Force
        Move-Item -LiteralPath $stagedSettings -Destination $script:SettingsPath -Force
        Set-StartupShortcut -Enabled $script:StartupCheck.Checked
        if ($script:StartupCheck.Checked -and (Test-Path -LiteralPath $script:StopFlagPath -PathType Leaf)) {
            Remove-Item -LiteralPath $script:StopFlagPath -Force -ErrorAction Stop
        }
        elseif ((-not $script:StartupCheck.Checked) -and (-not $StartNow)) {
            Set-Content -LiteralPath $script:StopFlagPath -Value 'Stop requested by local configuration.' -Encoding UTF8
        }
        $script:PasswordBox.Clear()
    }
    finally {
        foreach ($temporaryFile in $temporaryFiles) {
            if (Test-Path -LiteralPath $temporaryFile -PathType Leaf) {
                Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
            }
        }
        if ($null -ne $newSecurePassword) {
            $newSecurePassword.Dispose()
        }
    }
}

function Set-Status {
    param([string]$Text, [bool]$IsError = $false)
    $script:StatusLabel.Text = $Text
    if ($IsError) {
        $script:StatusLabel.ForeColor = [Drawing.Color]::Firebrick
    }
    else {
        $script:StatusLabel.ForeColor = [Drawing.Color]::DarkGreen
    }
}

function Invoke-SaveAction {
    param([bool]$StartNow)
    try {
        Save-LocalConfiguration -StartNow $StartNow
        if ($StartNow) {
            foreach ($controlFile in @($script:StopFlagPath, $script:AuthBlockPath)) {
                if (Test-Path -LiteralPath $controlFile -PathType Leaf) {
                    Remove-Item -LiteralPath $controlFile -Force -ErrorAction Stop
                }
            }
            $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Mode Watch' -f $script:InstalledScript
            [void](Start-Process -FilePath $script:PowerShellExe -ArgumentList $arguments -WorkingDirectory $script:InstallDirectory -WindowStyle Hidden -PassThru)
            Set-Status '配置已保存，已请求启动后台；已有后台会读取新配置。认证结果请稍后刷新状态。现在可以关闭此窗口。'
        }
        elseif ($script:StartupCheck.Checked) {
            Set-Status '配置已保存，已启用登录 Windows 后自动启动。正在运行的后台程序会读取新配置。'
        }
        else {
            Set-Status '配置已保存，已取消自启动，并请求后台停止自动认证。当前网络不会被注销。'
        }
    }
    catch {
        Set-Status ('操作未完整完成：' + $_.Exception.Message + ' 请修正后重试。已完成的本机保存步骤可能仍会保留。') $true
    }
}

function Show-CurrentStatus {
    try {
        if (-not (Test-Path -LiteralPath $script:StatusPath -PathType Leaf)) {
            Set-Status '尚无后台状态记录。请先保存并启动；认证结果可稍后点击“刷新状态”查看。'
            return
        }
        $status = Get-Content -LiteralPath $script:StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $message = [string]$status.Message
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = [string]$status.State
        }
        if ($message.Length -gt 350) {
            $message = $message.Substring(0, 350)
        }
        Set-Status ('最近记录：' + $message + [Environment]::NewLine + '更新时间：' + [string]$status.UpdatedAt)
        $script:StatusLabel.ForeColor = [Drawing.Color]::DimGray
    }
    catch {
        Set-Status ('暂时无法读取状态，请稍后刷新。' + $_.Exception.Message) $true
    }
}

function Add-Label {
    param([string]$Text, [int]$Left, [int]$Top, [int]$Width, [int]$Height = 26)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.SetBounds($Left, $Top, $Width, $Height)
    $script:Form.Controls.Add($label)
    return $label
}

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = '校园网自动连接 · 本机配置'
$script:Form.ClientSize = New-Object Drawing.Size (650, 610)
$script:Form.StartPosition = 'CenterScreen'
$script:Form.FormBorderStyle = 'FixedDialog'
$script:Form.MaximizeBox = $false
$script:Form.Font = New-Object Drawing.Font ('Microsoft YaHei UI', 9)
$script:Form.AutoScaleMode = 'Font'

[void](Add-Label '认证地址' 22 24 100)
$portalBox = New-Object Windows.Forms.TextBox
$portalBox.SetBounds(128, 20, 496, 28)
$portalBox.Text = 'http://10.2.5.251'
$portalBox.ReadOnly = $true
$portalBox.TabStop = $false
$script:Form.Controls.Add($portalBox)

[void](Add-Label '校园网账号' 22 68 100)
$script:UsernameBox = New-Object Windows.Forms.TextBox
$script:UsernameBox.SetBounds(128, 64, 496, 28)
$script:UsernameBox.MaxLength = 256
$script:UsernameBox.TabIndex = 0
$script:Form.Controls.Add($script:UsernameBox)

[void](Add-Label '校园网密码' 22 112 100)
$script:PasswordBox = New-Object Windows.Forms.TextBox
$script:PasswordBox.SetBounds(128, 108, 496, 28)
$script:PasswordBox.UseSystemPasswordChar = $true
$script:PasswordBox.MaxLength = 256
$script:PasswordBox.TabIndex = 1
$script:Form.Controls.Add($script:PasswordBox)
[void](Add-Label '首次请填写密码；以后账号未变时，留空可保留已保存的密码。' 128 140 496 34)

[void](Add-Label '运营商' 22 181 100)
$script:OperatorBox = New-Object Windows.Forms.ComboBox
$script:OperatorBox.SetBounds(128, 177, 496, 28)
$script:OperatorBox.DropDownStyle = 'DropDownList'
[void]$script:OperatorBox.Items.AddRange([object[]]@('账号已含后缀 / 不添加', '校园网', '中国电信', '中国移动', '中国联通', '自定义后缀'))
$script:OperatorBox.SelectedIndex = 0
$script:OperatorBox.TabIndex = 2
$script:Form.Controls.Add($script:OperatorBox)

[void](Add-Label '自定义后缀' 22 222 100)
$script:SuffixBox = New-Object Windows.Forms.TextBox
$script:SuffixBox.SetBounds(128, 218, 496, 28)
$script:SuffixBox.Enabled = $false
$script:SuffixBox.MaxLength = 128
$script:SuffixBox.TabIndex = 3
$script:Form.Controls.Add($script:SuffixBox)
$script:OperatorBox.Add_SelectedIndexChanged({ $script:SuffixBox.Enabled = ($script:OperatorBox.SelectedIndex -eq 5) })
[void](Add-Label '选择与网页登录一致的运营商。只有选择“自定义后缀”时，才需填写完整后缀，例如 @cmcc。' 128 250 496 38)

$script:StartupCheck = New-Object Windows.Forms.CheckBox
$script:StartupCheck.SetBounds(22, 295, 600, 28)
$script:StartupCheck.Text = '登录当前 Windows 账户后，在后台自动连接校园网'
$script:StartupCheck.Checked = $true
$script:StartupCheck.TabIndex = 4
$script:Form.Controls.Add($script:StartupCheck)

[void](Add-Label '密码只保存在当前 Windows 账户的加密凭据文件中，不写入脚本或启动命令。本窗口保存本机配置；后台运行时会读取配置并向校园网认证。' 22 336 604 56)

$saveButton = New-Object Windows.Forms.Button
$saveButton.Text = '保存配置'
$saveButton.SetBounds(22, 409, 150, 38)
$saveButton.TabIndex = 5
$saveButton.Add_Click({ Invoke-SaveAction -StartNow $false })
$script:Form.Controls.Add($saveButton)

$startButton = New-Object Windows.Forms.Button
$startButton.Text = '保存并启动'
$startButton.SetBounds(185, 409, 150, 38)
$startButton.TabIndex = 6
$startButton.Add_Click({ Invoke-SaveAction -StartNow $true })
$script:Form.Controls.Add($startButton)

$disableButton = New-Object Windows.Forms.Button
$disableButton.Text = '取消自启动并停止后台'
$disableButton.SetBounds(348, 409, 276, 38)
$disableButton.TabIndex = 7
$disableButton.Add_Click({
    try {
        Set-StartupShortcut -Enabled $false
        if (-not (Test-Path -LiteralPath $script:InstallDirectory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $script:InstallDirectory -Force)
        }
        Set-Content -LiteralPath $script:StopFlagPath -Value 'Stop requested by local configuration.' -Encoding UTF8
        $script:StartupCheck.Checked = $false
        Set-Status '已取消自启动，并请求后台停止自动认证。后台会在下一次检查时退出，不会注销当前网络。'
    }
    catch {
        Set-Status ('停止操作未完整完成：' + $_.Exception.Message + ' 已完成的步骤可能仍会保留。') $true
    }
})
$script:Form.Controls.Add($disableButton)

$refreshButton = New-Object Windows.Forms.Button
$refreshButton.Text = '刷新状态'
$refreshButton.SetBounds(22, 459, 150, 38)
$refreshButton.TabIndex = 8
$refreshButton.Add_Click({ Show-CurrentStatus })
$script:Form.Controls.Add($refreshButton)

$closeButton = New-Object Windows.Forms.Button
$closeButton.Text = '关闭'
$closeButton.SetBounds(523, 459, 101, 38)
$closeButton.TabIndex = 9
$closeButton.Add_Click({ $script:Form.Close() })
$script:Form.Controls.Add($closeButton)
$script:Form.CancelButton = $closeButton

$script:StatusLabel = Add-Label '请在本机填写校园网账号和密码。无需把密码发送到聊天中。' 22 510 604 85
$script:StatusLabel.ForeColor = [Drawing.Color]::DimGray

if (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf) {
    try {
        $existingSettings = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $existingSettings.Username) {
            $script:UsernameBox.Text = [string]$existingSettings.Username
        }
        $script:StartupCheck.Checked = Test-Path -LiteralPath $script:StartupShortcut -PathType Leaf
        Set-Status '已载入本机配置。账号未变时，密码留空即可保留；也可以填写新密码。'
    }
    catch {
        Set-Status '本机旧配置无法读取，请重新填写账号和密码。' $true
    }
}

try {
    [void]$script:Form.ShowDialog()
}
finally {
    $script:PasswordBox.Clear()
    $script:Form.Dispose()
}
