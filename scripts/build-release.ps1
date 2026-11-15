param(
    [string]$BuildName = '0.1.2',
    [string]$ServerUrl
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

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
    throw "Close the running ConsentChat Windows app (PID $processIds) before building the release, so its files can be replaced."
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
if ([string]::IsNullOrWhiteSpace($ServerUrl)) {
    $ServerUrl = 'https://[2408:823c:4a15:62cc:8367:2c5c:20a3:38e5]:8443'
}
$serverUri = $null
if (-not [Uri]::TryCreate($ServerUrl, [UriKind]::Absolute, [ref]$serverUri) -or
    $serverUri.Scheme -ne 'https' -or
    $serverUri.AbsolutePath -ne '/') {
    throw 'ServerUrl must be an HTTPS origin such as https://192.168.1.14:8443.'
}
Write-Output "Using server URL for all builds: $ServerUrl"
Stop-GradleDaemons
Invoke-Flutter @('clean')
$buildDirectory = Join-Path $projectRoot 'build'
Clear-StaleBuildOutput -Path $buildDirectory
Invoke-Flutter @('pub', 'get')

foreach ($scriptName in @('build-server.ps1', 'build-client.ps1', 'build-windows.ps1')) {
    $scriptPath = Join-Path $PSScriptRoot $scriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Release build script not found: $scriptPath"
    }
    Write-Output "`nBuilding $scriptName"
    & $scriptPath -BuildName $BuildName -ServerUrl $ServerUrl -SkipPreparation
}

Write-Output "`nAll release files are ready in $(Join-Path $projectRoot 'dist\ConsentChat-Windows')"
