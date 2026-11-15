$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $elevatedProcess = Start-Process -FilePath 'powershell.exe' `
        -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    exit $elevatedProcess.ExitCode
}

$serverDirectory = $PSScriptRoot
$serverExecutable = Join-Path $serverDirectory 'consent_chat.exe'
$firewallScript = Join-Path $serverDirectory 'Configure-Server-Firewall.ps1'
$turnDirectory = Join-Path $env:ProgramData 'ConsentChatTurn'
$turnExecutable = Join-Path $turnDirectory 'turnserver.exe'
$turnConfiguration = Join-Path $turnDirectory 'turnserver.conf'
$serverPort = 8443
$turnPort = 3478

foreach ($requiredFile in @(
        $serverExecutable,
        $firewallScript,
        $turnExecutable,
        $turnConfiguration
    )) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required startup file was not found: $requiredFile"
    }
}

function Get-ServerProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name = 'consent_chat.exe'")
}

function Get-TurnProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name = 'turnserver.exe'")
}

function Test-TurnReady {
    $tcpListener = Get-NetTCPConnection -State Listen `
        -LocalPort $turnPort -ErrorAction SilentlyContinue
    $udpListener = Get-NetUDPEndpoint -LocalPort $turnPort `
        -ErrorAction SilentlyContinue
    return [bool]$tcpListener -and [bool]$udpListener
}

Write-Host 'Configuring Windows Firewall for chat and video traffic...'
& $firewallScript -Quiet
if (-not $?) {
    throw 'Windows Firewall configuration failed.'
}

$env:PATH = "$turnDirectory;$env:PATH"
$turnProcesses = Get-TurnProcesses
if ($turnProcesses | Where-Object {
        -not $_.ExecutablePath -or
        [IO.Path]::GetFullPath($_.ExecutablePath) -ine
            [IO.Path]::GetFullPath($turnExecutable)
    }) {
    throw 'Another turnserver.exe is already running from a different folder. Close it before using this launcher.'
}
if ($turnProcesses.Count -eq 0) {
    Write-Host 'Starting TURN video relay...'
    Start-Process -FilePath $turnExecutable `
        -ArgumentList @('-c', 'turnserver.conf') `
        -WorkingDirectory $turnDirectory `
        -WindowStyle Hidden | Out-Null
} elseif (-not (Test-TurnReady)) {
    throw 'TURN is already running but TCP/UDP 3478 is not listening. Check C:\ProgramData\ConsentChatTurn\turnserver.log.'
} else {
    Write-Host 'TURN video relay is already running.'
}

$turnDeadline = (Get-Date).AddSeconds(20)
while (-not (Test-TurnReady) -and (Get-Date) -lt $turnDeadline) {
    Start-Sleep -Seconds 1
}
if (-not (Test-TurnReady)) {
    throw 'TURN did not open both TCP and UDP port 3478. Check C:\ProgramData\ConsentChatTurn\turnserver.log.'
}
Write-Host 'TURN is listening on TCP/UDP 3478; UDP relay ports 49160-49200 are allowed.'

$serverProcesses = Get-ServerProcesses
$otherServerProcesses = @(
    $serverProcesses | Where-Object {
        -not $_.ExecutablePath -or
        [IO.Path]::GetFullPath($_.ExecutablePath) -ine
            [IO.Path]::GetFullPath($serverExecutable)
    }
)
if ($otherServerProcesses.Count -gt 0) {
    $processIds = ($otherServerProcesses.ProcessId -join ', ')
    throw "Consent Chat is already open from another folder (PID $processIds). Close that window first to avoid opening the same data twice."
}
$serverListeners = @(
    Get-NetTCPConnection -State Listen -LocalPort $serverPort `
        -ErrorAction SilentlyContinue
)
if ($serverProcesses.Count -gt 0) {
    if (-not ($serverListeners | Where-Object {
                $_.OwningProcess -in $serverProcesses.ProcessId
            })) {
        throw 'Consent Chat is already open but not listening on TCP 8443. Close that window, then run this launcher again.'
    }
    Write-Host 'Consent Chat server is already running.'
} else {
    if ($serverListeners.Count -gt 0) {
        $owners = ($serverListeners.OwningProcess | Sort-Object -Unique) -join ', '
        throw "TCP port 8443 is already used by another process (PID $owners). Close it before starting Consent Chat."
    }

    Write-Host 'Starting Consent Chat server...'
    Start-Process -FilePath $serverExecutable `
        -ArgumentList '--start-server' `
        -WorkingDirectory $serverDirectory | Out-Null

    $serverDeadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $serverDeadline) {
        Start-Sleep -Seconds 1
        $serverProcesses = Get-ServerProcesses
        $serverProcesses = @(
            $serverProcesses | Where-Object {
                $_.ExecutablePath -and
                [IO.Path]::GetFullPath($_.ExecutablePath) -ieq
                    [IO.Path]::GetFullPath($serverExecutable)
            }
        )
        $serverListeners = @(
            Get-NetTCPConnection -State Listen -LocalPort $serverPort `
                -ErrorAction SilentlyContinue
        )
        if ($serverProcesses.Count -gt 0 -and
            $serverListeners | Where-Object {
                $_.OwningProcess -in $serverProcesses.ProcessId
            }) {
            break
        }
    }

    if (-not ($serverListeners | Where-Object {
                $_.OwningProcess -in $serverProcesses.ProcessId
            })) {
        throw 'Consent Chat did not start listening on TCP 8443 within 60 seconds. If no administrator password is saved, enter it in the server window and press Start, then run this launcher again.'
    }
}

Write-Host 'Startup complete: firewall, chat server, and TURN relay are running.'
Write-Host 'This computer firewall allows chat TCP 8443, TURN TCP/UDP 3478, and TURN UDP 49160-49200.'
Write-Host 'External TURN/video reachability still depends on a publicly reachable relay address and router policy.'
Read-Host 'Press Enter to close'
