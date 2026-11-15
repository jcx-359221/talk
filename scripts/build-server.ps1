param(
    [string]$BuildName = '0.1.2',
    [string]$ServerUrl,
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
$flutterArguments = @(
    'build',
    'apk',
    '--release',
    '--flavor',
    'server',
    '--target',
    'lib/main_server.dart',
    '--build-name',
    $BuildName
)
if (-not [string]::IsNullOrWhiteSpace($ServerUrl)) {
    $serverUri = $null
    if (-not [Uri]::TryCreate($ServerUrl, [UriKind]::Absolute, [ref]$serverUri) -or
        $serverUri.Scheme -ne 'https' -or
        $serverUri.AbsolutePath -ne '/') {
        throw 'ServerUrl must be an HTTPS origin such as https://192.168.1.14:8443.'
    }
    $encodedUrlBytes = [System.Text.Encoding]::UTF8.GetBytes($ServerUrl)
    for ($index = 0; $index -lt $encodedUrlBytes.Length; $index++) {
        $encodedUrlBytes[$index] = $encodedUrlBytes[$index] -bxor 0x5A
    }
    $encodedUrl = [Convert]::ToBase64String($encodedUrlBytes)
    $flutterArguments += "--dart-define=CLIENT_SERVER_URL_XOR_B64=$encodedUrl"
}
if (-not $SkipPreparation) {
    Invoke-Flutter @('clean')
    Invoke-Flutter @('pub', 'get')
}
Invoke-Flutter -Arguments $flutterArguments

$serverApk = Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-server-release.apk'
if (-not (Test-Path -LiteralPath $serverApk -PathType Leaf)) {
    throw "Expected build output was not created: $serverApk"
}
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$destination = Join-Path $outputDir 'ConsentChat-Server.apk'
Copy-Item -LiteralPath $serverApk -Destination $destination -Force
Write-Output "Server APK is ready: $destination"