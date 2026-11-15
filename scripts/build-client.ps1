param(
    [string]$BuildName = '0.1.2',
    [string]$ServerUrl,
    [string]$ExpectedDeviceIdentity,
    [string]$OutputName,
    [switch]$Trial,
    [switch]$SkipPreparation
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputDir = Join-Path $projectRoot 'dist\ConsentChat-Windows'

$flutterCommand = (Get-Command flutter.bat -ErrorAction SilentlyContinue).Source
if (-not $flutterCommand) {
    $flutterCommand = 'D:\BuildTools\flutter\bin\flutter.bat'
}
if (-not (Test-Path -LiteralPath $flutterCommand)) {
    throw "Flutter was not found. Add flutter.bat to PATH or install it at D:\BuildTools\flutter."
}

if (-not (Get-Command git -ErrorAction SilentlyContinue) -and
    -not $env:FLUTTER_PREBUILT_ENGINE_VERSION) {
    $flutterRoot = Split-Path -Parent (Split-Path -Parent $flutterCommand)
    $engineVersionPath = Join-Path $flutterRoot 'bin\internal\engine.version'
    if (Test-Path -LiteralPath $engineVersionPath) {
        $env:FLUTTER_PREBUILT_ENGINE_VERSION =
            (Get-Content -LiteralPath $engineVersionPath -Raw).Trim()
    }
}

function Invoke-Flutter {
    param([string[]]$Arguments)

    & $flutterCommand @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter command failed with exit code $LASTEXITCODE`: flutter $($Arguments -join ' ')"
    }
}

Set-Location $projectRoot
if ([string]::IsNullOrWhiteSpace($ServerUrl)) {
    $ServerUrl = 'https://[2408:823c:4a15:62cc:8367:2c5c:20a3:38e5]:8443'
    Write-Output "Using configured public IPv6 server address: $ServerUrl"
}
$serverUri = $null
if (-not [Uri]::TryCreate($ServerUrl, [UriKind]::Absolute, [ref]$serverUri) -or
    $serverUri.Scheme -ne 'https' -or
    -not $serverUri.IsDefaultPort -and ($serverUri.Port -lt 1 -or $serverUri.Port -gt 65535) -or
    $serverUri.AbsolutePath -ne '/') {
    throw 'ServerUrl must be an HTTPS origin such as https://chat.example.com:8443.'
}
$encodedServerUrlBytes = [System.Text.Encoding]::UTF8.GetBytes($ServerUrl)
for ($index = 0; $index -lt $encodedServerUrlBytes.Length; $index++) {
    $encodedServerUrlBytes[$index] = $encodedServerUrlBytes[$index] -bxor 0x5A
}
$encodedServerUrl = [Convert]::ToBase64String($encodedServerUrlBytes)
if ($Trial -and $ExpectedDeviceIdentity) {
    throw 'A trial APK cannot also be restricted to a device identity.'
}
if ($ExpectedDeviceIdentity -and
    $ExpectedDeviceIdentity -notmatch '^[a-fA-F0-9]{64}$') {
    throw 'ExpectedDeviceIdentity must be a 64-character SHA-256 hash.'
}
$customOutputName = -not [string]::IsNullOrWhiteSpace($OutputName)
if ($Trial) {
    $trialDate = Get-Date -Format 'yyyy-MM-dd'
    if (-not $OutputName) {
        $OutputName = "chat_client_trial_$trialDate.apk"
    }
} else {
    $trialDate = ''
}
if ($OutputName) {
    if ($OutputName -ne [IO.Path]::GetFileName($OutputName) -or
        [IO.Path]::GetExtension($OutputName) -ne '.apk' -or
        $OutputName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw 'OutputName must be a safe APK file name without a directory path.'
    }
}

if (-not $SkipPreparation) {
    Invoke-Flutter @('clean')
    Invoke-Flutter @('pub', 'get')
}
$trialValue = if ($Trial) { 'true' } else { 'false' }
$flutterArguments = @(
    'build',
    'apk',
    '--release',
    '--flavor',
    'client',
    '--target',
    'lib/main_client.dart',
    '--build-name',
    $BuildName,
    "--dart-define=CLIENT_SERVER_URL_XOR_B64=$encodedServerUrl",
    "--dart-define=CLIENT_TRIAL=$trialValue",
    "--dart-define=CLIENT_TRIAL_DATE=$trialDate",
    "--dart-define=CLIENT_EXPECTED_DEVICE_IDENTITY=$ExpectedDeviceIdentity"
)
Invoke-Flutter -Arguments $flutterArguments

$clientApk = Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-client-release.apk'
if (-not (Test-Path -LiteralPath $clientApk -PathType Leaf)) {
    throw "Expected build output was not created: $clientApk"
}
$destinationDirectory = if ($OutputName) {
    if ($customOutputName) {
        Join-Path $projectRoot 'dist'
    } else {
        $outputDir
    }
} else {
    $outputDir
}
New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
$destinationFileName = if ($OutputName) {
    $OutputName
} else {
    'ConsentChat-Client.apk'
}
$destination = Join-Path $destinationDirectory $destinationFileName
Copy-Item -LiteralPath $clientApk -Destination $destination -Force
Write-Output "Client APK is ready: $destination"