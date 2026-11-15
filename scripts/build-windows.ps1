param(
    [string]$BuildName = '0.1.2',
    [string]$ServerUrl,
    [switch]$SkipPreparation
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputDir = Join-Path $projectRoot 'dist\ConsentChat-Windows'

function Stop-GradleDaemons {
    $gradleWrapper = Join-Path $projectRoot 'android\gradlew.bat'
    if (-not (Test-Path -LiteralPath $gradleWrapper -PathType Leaf)) {
        return
    }

    if (-not (Get-Command java.exe -ErrorAction SilentlyContinue)) {
        Write-Warning 'Java was not found; cannot ask Gradle daemons to stop.'
        return
    }

    Push-Location (Split-Path -Parent $gradleWrapper)
    try {
        & $gradleWrapper --stop
        if ($LASTEXITCODE -ne 0) {
            throw "Gradle daemon shutdown failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
}

function Clear-StaleBuildOutput {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Stop-GradleDaemons
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            if ($attempt -eq 5) {
                throw "Could not clear stale build output at $Path. Close the running app or build tools and retry. $($_.Exception.Message)"
            }
            Write-Warning "Build output is still locked (attempt $attempt/5). Retrying in 2 seconds..."
            Start-Sleep -Seconds 2
        }
    }
}

$runningApp = Get-Process -Name 'consent_chat' -ErrorAction SilentlyContinue
if ($runningApp) {
    $processIds = ($runningApp.Id -join ', ')
    throw "Close the running ConsentChat Windows app (PID $processIds) before building, so its files can be replaced."
}

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
if (-not $SkipPreparation) {
    Stop-GradleDaemons
    Invoke-Flutter @('clean')
    $buildDirectory = Join-Path $projectRoot 'build'
    Clear-StaleBuildOutput -Path $buildDirectory
    Invoke-Flutter @('pub', 'get')
}
$flutterArguments = @(
    'build',
    'windows',
    '--release',
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
Invoke-Flutter -Arguments $flutterArguments

$windowsReleaseDir = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$windowsExe = Join-Path $windowsReleaseDir 'consent_chat.exe'
if (-not (Test-Path -LiteralPath $windowsExe -PathType Leaf)) {
    throw "Expected build output was not created: $windowsExe"
}

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
try {
    Copy-Item -Path (Join-Path $windowsReleaseDir '*') -Destination $outputDir -Recurse -Force -ErrorAction Stop
} catch {
    throw "Could not update $outputDir. Close the running app and retry. $($_.Exception.Message)"
}
Write-Output "Windows EXE and required runtime files are ready: $outputDir"