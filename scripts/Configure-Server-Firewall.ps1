param(
    [switch]$Restore,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$ruleName = 'ConsentChat-Server-TCP-8443'
$displayName = 'Consent Chat server TCP 8443'
$programPath = Join-Path $PSScriptRoot 'consent_chat.exe'
$backupDirectory = Join-Path $env:ProgramData 'ConsentChat'
$backupPath = Join-Path $backupDirectory 'firewall-backup.json'
$coreNetworkingGroup = '@FirewallAPI.dll,-25000'
$profileNames = @('Domain', 'Private', 'Public')

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Restore) {
        $arguments += ' -Restore'
    }
    if ($Quiet) {
        $arguments += ' -Quiet'
    }
    $elevatedProcess = Start-Process -FilePath 'powershell.exe' `
        -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    exit $elevatedProcess.ExitCode
}

if ($Restore) {
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        throw "Firewall backup was not found: $backupPath"
    }

    $backup = Get-Content -LiteralPath $backupPath -Raw |
        ConvertFrom-Json
    @(
        $ruleName,
        'ConsentChat-TURN-UDP-3478',
        'ConsentChat-TURN-TCP-3478',
        'ConsentChat-TURN-UDP-Relay'
    ) | ForEach-Object {
        Get-NetFirewallRule -Name $_ -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule
    }

    foreach ($rule in $backup.disabledRules) {
        Get-NetFirewallRule -Name $rule.name -ErrorAction SilentlyContinue |
            Set-NetFirewallRule -Enabled ([bool]$rule.enabled)
    }

    foreach ($profile in $backup.profiles) {
        Set-NetFirewallProfile -Profile $profile.name `
            -Enabled ([bool]$profile.enabled) `
            -DefaultInboundAction $profile.defaultInboundAction `
            -DefaultOutboundAction $profile.defaultOutboundAction
    }

    Remove-Item -LiteralPath $backupPath -Force
    Write-Host 'Original Windows Firewall settings have been restored.'
    if (-not $Quiet) {
        Read-Host 'Press Enter to close'
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $programPath -PathType Leaf)) {
    throw "Place this script beside consent_chat.exe before running it: $programPath"
}
$turnDirectory = Join-Path $env:ProgramData 'ConsentChatTurn'
$turnProgramPath = Join-Path $turnDirectory 'turnserver.exe'
if (-not (Test-Path -LiteralPath $turnProgramPath -PathType Leaf)) {
    throw "TURN server was not found: $turnProgramPath"
}
$hasBackup = Test-Path -LiteralPath $backupPath -PathType Leaf

$activeInboundAllows = @(
    Get-NetFirewallRule -PolicyStore ActiveStore `
        -Direction Inbound -Enabled True -Action Allow
)
$unmanagedAllows = @(
    $activeInboundAllows | Where-Object {
        $_.Group -ne $coreNetworkingGroup -and
        $_.Name -ne $ruleName -and
        $_.PolicyStoreSourceType -ne 'Local'
    }
)
$unrecognizedDynamicAllows = @(
    foreach ($rule in $unmanagedAllows) {
        $application = Get-NetFirewallApplicationFilter `
            -AssociatedNetFirewallRule $rule
        $port = Get-NetFirewallPortFilter `
            -AssociatedNetFirewallRule $rule
        $localPorts = @($port.LocalPort | ForEach-Object { "$_" })
        $isKnownNetworkRule =
            $rule.PolicyStoreSourceType -eq 'Dynamic' -and
            $application.Program -like '*\svchost.exe' -and
            $port.Protocol -eq 'UDP' -and
            @('53', '67', '68') -contains $localPorts[0] -and
            $localPorts.Count -eq 1
        if (-not $isKnownNetworkRule) {
            $rule.DisplayName
        }
    }
)
if ($unrecognizedDynamicAllows.Count -gt 0) {
    $names = $unrecognizedDynamicAllows -join ', '
    throw "Non-local inbound allow rules cannot be safely disabled by this script: $names"
}

$rulesToDisable = @(
    if (-not $hasBackup) {
        Get-NetFirewallRule -PolicyStore PersistentStore `
            -Direction Inbound -Enabled True -Action Allow |
            Where-Object {
                $_.Group -ne $coreNetworkingGroup -and
                $_.Name -notin @(
                    $ruleName,
                    'ConsentChat-TURN-UDP-3478',
                    'ConsentChat-TURN-TCP-3478',
                    'ConsentChat-TURN-UDP-Relay'
                )
            }
    } else {
        $existingBackup = Get-Content -LiteralPath $backupPath -Raw |
            ConvertFrom-Json
        $savedRuleNames = @(
            $existingBackup.disabledRules |
                ForEach-Object { $_.name }
        )
        if ($savedRuleNames.Count -gt 0) {
            Get-NetFirewallRule -PolicyStore PersistentStore `
                -Name $savedRuleNames -ErrorAction SilentlyContinue |
                Where-Object { $_.Enabled }
        }
    }
)
$profiles = @(
    foreach ($name in $profileNames) {
        $profile = Get-NetFirewallProfile -PolicyStore PersistentStore `
            -Name $name
        [PSCustomObject]@{
            name = $name
            enabled = [bool]$profile.Enabled
            defaultInboundAction = [string]$profile.DefaultInboundAction
            defaultOutboundAction = [string]$profile.DefaultOutboundAction
        }
    }
)
$disabledRules = @(
    $rulesToDisable | ForEach-Object {
        [PSCustomObject]@{
            name = $_.Name
            enabled = [bool]$_.Enabled
        }
    }
)

if (-not $hasBackup) {
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    [PSCustomObject]@{
        profiles = $profiles
        disabledRules = $disabledRules
    } | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $backupPath -Encoding UTF8

    if ($rulesToDisable.Count -gt 0) {
        Write-Host "Disabling $($rulesToDisable.Count) pre-existing inbound allow rules..."
        Disable-NetFirewallRule -InputObject $rulesToDisable
    }
}

Set-NetFirewallProfile -Profile $profileNames `
    -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Allow

$managedRules = @(
    @{
        Name = $ruleName
        DisplayName = $displayName
        Program = $programPath
        Protocol = 'TCP'
        LocalPort = '8443'
        Description = 'Allow Consent Chat server HTTPS on TCP port 8443.'
    },
    @{
        Name = 'ConsentChat-TURN-UDP-3478'
        DisplayName = 'Consent Chat TURN UDP 3478'
        Program = $turnProgramPath
        Protocol = 'UDP'
        LocalPort = '3478'
        Description = 'Allow TURN/STUN on UDP port 3478.'
    },
    @{
        Name = 'ConsentChat-TURN-TCP-3478'
        DisplayName = 'Consent Chat TURN TCP 3478'
        Program = $turnProgramPath
        Protocol = 'TCP'
        LocalPort = '3478'
        Description = 'Allow TURN/STUN on TCP port 3478.'
    },
    @{
        Name = 'ConsentChat-TURN-UDP-Relay'
        DisplayName = 'Consent Chat TURN UDP relay ports'
        Program = $turnProgramPath
        Protocol = 'UDP'
        LocalPort = '49160-49200'
        Description = 'Allow TURN media relay on UDP ports 49160-49200.'
    }
)
foreach ($rule in $managedRules) {
    Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule
    New-NetFirewallRule -Name $rule.Name -DisplayName $rule.DisplayName `
        -Description $rule.Description -Direction Inbound -Action Allow `
        -Enabled True -Profile Any -Program $rule.Program `
        -Protocol $rule.Protocol -LocalPort $rule.LocalPort `
        -EdgeTraversalPolicy Block | Out-Null
}

$disabledCount = $rulesToDisable.Count
$preservedDynamicCount = $unmanagedAllows.Count
Write-Host "Windows Firewall is enabled with inbound blocking."
Write-Host "Disabled $disabledCount other inbound allow rules."
Write-Host 'Preserved Windows Core Networking and required dynamic system network rules.'
Write-Host 'Allowed server TCP 8443 and TURN UDP/TCP 3478 plus UDP 49160-49200.'
Write-Host "Preserved dynamic rules: $preservedDynamicCount."
Write-Host "To undo these changes, run this script with -Restore."
if (-not $Quiet) {
    Read-Host 'Press Enter to close'
}
