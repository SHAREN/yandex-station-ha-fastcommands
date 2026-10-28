[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Serial,

    [Parameter(Mandatory = $true)]
    [string]$HomeAssistantUrl,

    [string]$StationName = "Yandex Station",
    [string]$WebhookId = "",
    [string]$Version = "latest",
    [string]$AdbPath = "adb",
    [switch]$OverwriteConfig
)

$ErrorActionPreference = "Stop"
$Repo = "SHAREN/yandex-station-ha-fastcommands"
$RemoteRoot = "/data/opt/alice-ha-fastcommands"
$RemoteInit = "/etc/init.d/S99zzalice-ha-fastcommands"
$PackageName = "alice-ha-fastcommands-linux-arm64.tar.gz"
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("alice-ha-fastcommands-" + [guid]::NewGuid().ToString("N"))

function Invoke-Adb {
    & $AdbPath @args
    if ($LASTEXITCODE -ne 0) {
        throw "adb failed: $($args -join ' ')"
    }
}

function Invoke-AdbShellChecked {
    param([Parameter(Mandatory = $true)][string]$Command)

    $okMarker = "__ALICE_HA_REMOTE_OK__"
    $failMarker = "__ALICE_HA_REMOTE_FAIL__"
    $remote = "if { $Command; }; then echo $okMarker; else echo $failMarker; fi"
    $output = @(& $AdbPath -s $Serial shell $remote)
    if ($LASTEXITCODE -ne 0) {
        throw "adb shell transport failed: $Command"
    }

    $text = $output -join "`n"
    foreach ($line in $output) {
        if ($line -ne $okMarker -and $line -ne $failMarker) {
            Write-Host $line
        }
    }
    if (-not $text.Contains($okMarker) -or $text.Contains($failMarker)) {
        throw "remote command failed: $Command"
    }
}

function New-RandomWebhookId {
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    return -join ($bytes | ForEach-Object { $_.ToString("x2") })
}

try {
    New-Item -ItemType Directory -Path $TempDir | Out-Null

    if ($Version -eq "latest") {
        $BaseUrl = "https://github.com/$Repo/releases/latest/download"
    }
    else {
        $BaseUrl = "https://github.com/$Repo/releases/download/$Version"
    }

    $PackagePath = Join-Path $TempDir $PackageName
    $SumsPath = Join-Path $TempDir "SHA256SUMS"

    Write-Host "Downloading release on the PC..."
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/$PackageName" -OutFile $PackagePath
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/SHA256SUMS" -OutFile $SumsPath

    $sumLine = Get-Content $SumsPath | Where-Object { $_ -match [regex]::Escape($PackageName) + '$' } | Select-Object -First 1
    if (-not $sumLine) {
        throw "Package checksum is missing from SHA256SUMS"
    }
    $expected = (($sumLine -split '\s+')[0]).ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 $PackagePath).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "SHA256 mismatch: expected $expected, got $actual"
    }
    Write-Host "SHA256: OK"

    $ExtractDir = Join-Path $TempDir "package"
    New-Item -ItemType Directory -Path $ExtractDir | Out-Null
    & tar.exe -xzf $PackagePath -C $ExtractDir
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to unpack release archive"
    }

    Write-Host "Connecting to $Serial..."
    & $AdbPath connect $Serial | Out-Host
    $id = & $AdbPath -s $Serial shell id
    if ($LASTEXITCODE -ne 0 -or $id -notmatch 'uid=0\(root\)') {
        throw "Root ADB is required. Received: $id"
    }

    Invoke-AdbShellChecked "mkdir -p $RemoteRoot && chmod 700 $RemoteRoot"
    Invoke-Adb -s $Serial push (Join-Path $ExtractDir "alice-ha-fastcommands") "$RemoteRoot/alice-ha-fastcommands"
    Invoke-Adb -s $Serial push (Join-Path $ExtractDir "S99zzalice-ha-fastcommands") "$RemoteRoot/S99zzalice-ha-fastcommands"
    Invoke-AdbShellChecked "chmod 700 $RemoteRoot/alice-ha-fastcommands $RemoteRoot/S99zzalice-ha-fastcommands"

    $configProbe = @(& $AdbPath -s $Serial shell "if [ -f $RemoteRoot/config.json ]; then echo __ALICE_HA_CONFIG_EXISTS__; else echo __ALICE_HA_CONFIG_MISSING__; fi")
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to inspect the remote configuration"
    }
    $configProbeText = $configProbe -join "`n"
    if ($configProbeText.Contains("__ALICE_HA_CONFIG_EXISTS__")) {
        $configExists = $true
    }
    elseif ($configProbeText.Contains("__ALICE_HA_CONFIG_MISSING__")) {
        $configExists = $false
    }
    else {
        throw "Remote configuration probe returned no marker"
    }
    $wroteConfig = $false

    if (-not $configExists -or $OverwriteConfig) {
        if ([string]::IsNullOrWhiteSpace($WebhookId)) {
            $WebhookId = New-RandomWebhookId
        }
        $haBase = $HomeAssistantUrl.TrimEnd('/')
        $config = [ordered]@{
            station = $StationName
            aliced_addr = "127.0.0.1:9875"
            webhook_url = "$haBase/api/webhook/$WebhookId"
            cancel_native_dialog = $true
            debounce_ms = 1200
            allowed_commands = @("включи свет", "выключи свет")
            log_file = "$RemoteRoot/fastcommands.log"
        }
        $configJson = $config | ConvertTo-Json -Depth 4
        $localConfig = Join-Path $TempDir "config.json"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($localConfig, $configJson + [Environment]::NewLine, $utf8NoBom)
        Invoke-Adb -s $Serial push $localConfig "$RemoteRoot/config.json"
        Invoke-AdbShellChecked "chmod 600 $RemoteRoot/config.json"
        $wroteConfig = $true
    }
    else {
        Write-Host "Keeping existing $RemoteRoot/config.json. Use -OverwriteConfig to replace it."
    }

    Invoke-AdbShellChecked "mount -o remount,rw / || exit 1; cp $RemoteRoot/S99zzalice-ha-fastcommands $RemoteInit || { mount -o remount,ro /; exit 1; }; chmod 755 $RemoteInit || { mount -o remount,ro /; exit 1; }; sync; mount -o remount,ro /"
    Invoke-AdbShellChecked "$RemoteRoot/alice-ha-fastcommands --self-test"
    Invoke-AdbShellChecked "$RemoteRoot/alice-ha-fastcommands -config $RemoteRoot/config.json --probe"
    Invoke-AdbShellChecked "$RemoteInit restart"
    Invoke-AdbShellChecked "$RemoteInit status"

    Write-Host ""
    Write-Host "Installed successfully."
    Write-Host "Blueprint: https://github.com/$Repo/blob/main/blueprints/automation/yandex_station_fastcommands.yaml"
    if ($wroteConfig) {
        Write-Host "Webhook ID for the Home Assistant Blueprint: $WebhookId"
    }
    Write-Host "Log: $RemoteRoot/fastcommands.log"
}
finally {
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
