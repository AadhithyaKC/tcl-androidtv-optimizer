param (
    [Parameter(Mandatory=$false)]
    [string]$TvIp = "192.168.1.xx"
)

if ($TvIp -eq "192.168.1.xx" -or [string]::IsNullOrWhiteSpace($TvIp)) {$TvIp = Read-Host "Enter your TCL TV IP address (e.g., 192.168.1.50)"
}

Write-Host "[1/5] Connecting to $TvIp:5555..." -ForegroundColor Cyan
adb connect "$($TvIp):5555" | Out-Null

$devices = adb devices | Select-String "$($TvIp):5555\s+device"
if (-not $devices) {
    Write-Error "Could not connect to $TvIp:5555. Ensure Network Debugging is enabled on the TV."
    exit 1
}

Write-Host "[2/5] Checking './backups/' for Pre-Optimization Snapshot..." -ForegroundColor Cyan
$backupDir = Join-Path$PSScriptRoot "backups"
$earliestBackup =$null
if (Test-Path $backupDir) {
    $earliestBackup = Get-ChildItem -Path$backupDir -Filter "tv_initial_state_*.txt" | Sort-Object CreationTime | Select-Object -First 1
}

$currentlyDisabled = (adb shell pm list packages -d) | ForEach-Object { ($_ -replace "package:", "").Trim() } \vert{} Where-Object { $_ }

if ($earliestBackup) {
    Write-Host "  -> Found baseline snapshot: $($earliestBackup.Name)" -ForegroundColor Green
    $backupText = Get-Content$earliestBackup.FullName -Raw
    
    # Extract packages that were already disabled before optimization
    $factoryDisabled = @()
    if ($backupText -match "(?s)--- ALREADY DISABLED PACKAGES ---\r?\n(.*?)\r?\n--- GLOBAL SETTINGS ---") {
        $factoryDisabled =$Matches[1] -split "\r?\n" | ForEach-Object { ($_ -replace "package:", "").Trim() } \vert{} Where-Object { $_ }
    }
    $pkgsToReEnable =$currentlyDisabled | Where-Object { $factoryDisabled -notcontains$_ }
} else {
    Write-Host "  -> No backup file found; re-enabling known TCL & stock launcher packages..." -ForegroundColor Yellow
    $knownTargetedPkgs = @(
        "com.google.android.apps.tv.launcherx",
        "com.google.android.tvlauncher",
        "com.google.android.tungsten.setupwraith",
        "com.tcl.waterfall",
        "com.tcl.cyberui",
        "com.tcl.logman",
        "com.tcl.report",
        "com.tcl.diagnostics",
        "com.tcl.factory.view",
        "com.tcl.xian.beva",
        "com.tcl.useragreement",
        "com.tcl.messagebox",
        "com.tcl.versionUpdateApp",
        "com.tcl.assistant",
        "com.tcl.autopair",
        "com.tcl.bi",
        "com.tcl.notereminder",
        "com.tcl.bootadservice",
        "com.tcl.miracast"
    )
    $pkgsToReEnable =$currentlyDisabled | Where-Object { $knownTargetedPkgs -contains$_ }
}

Write-Host "[3/5] Re-enabling Stock Launchers & TCL Packages..." -ForegroundColor Cyan
foreach ($pkg in$pkgsToReEnable) {
    Write-Host "  -> Re-enabling $pkg"
    adb shell pm enable $pkg 2>$null | Out-Null
}

# Restore stock launcher as the native HOME role holder if present
$enabledNow = (adb shell pm list packages -e) \vert{} ForEach-Object { ($_ -replace "package:", "").Trim() }
foreach ($stockHome in @("com.google.android.apps.tv.launcherx", "com.google.android.tvlauncher", "com.tcl.waterfall", "com.tcl.cyberui")) {
    if ($enabledNow -contains$stockHome) {
        Write-Host "  -> Restoring native HOME role to $stockHome"
        adb shell cmd role add-role-holder --user 0 android.app.role.HOME $stockHome 2>$null | Out-Null
        break
    }
}

# Remove Projectivy Doze whitelist override
adb shell dumpsys deviceidle whitelist -com.spocky.projengmenu 2>$null | Out-Null

Write-Host "[4/5] Restoring Default AppOps Permissions on Installed Apps..." -ForegroundColor Cyan
adb shell cmd appops set com.android.vending RUN_IN_BACKGROUND allow 2>$null
foreach ($app in$enabledNow) {
    adb shell cmd appops set $app RUN_IN_BACKGROUND default 2>$null
    adb shell cmd appops set $app WAKE_LOCK default 2>$null
}

Write-Host "[5/5] Restoring Default Animation Scales, Process Limits & Radio Settings..." -ForegroundColor Cyan
adb shell settings put global window_animation_scale 1.0
adb shell settings put global transition_animation_scale 1.0
adb shell settings put global animator_duration_scale 1.0
adb shell settings put global package_verifier_enable 1
adb shell settings delete global standard_max_cached_processes 2>$null
adb shell settings delete global max_cached_processes 2>$null
adb shell settings put global wifi_scan_always_enabled 1
adb shell settings put global ble_scan_always_enabled 1
adb shell settings put global captive_portal_mode 1

adb disconnect | Out-Null
Write-Host "Factory defaults restored!" -ForegroundColor Green