param (
    [Parameter(Mandatory=$false)]
    [string]$TvIp = "192.168.1.xx",
    [Parameter(Mandatory=$false)]
    [string]$ProjectivyApkPath = "",
    [Parameter(Mandatory=$false)]
    [switch]$DisableMiracast
)

if ($TvIp -eq "192.168.1.xx" -or [string]::IsNullOrWhiteSpace($TvIp)) {
    $TvIp = Read-Host "Enter your TCL TV IP address (e.g., 192.168.1.50)"
}

Write-Host "[1/9] Connecting to $TvIp:5555..." -ForegroundColor Cyan
adb connect "$($TvIp):5555" | Out-Null

$devices = adb devices | Select-String "$($TvIp):5555\s+device"
if (-not $devices) {
    Write-Error "Could not connect to $TvIp:5555. Ensure Network Debugging is enabled on the TV and accept the RSA prompt."
    exit 1
}

Write-Host "[2/9] Creating Pre-Optimization Backup Snapshot..." -ForegroundColor Cyan
$backupDir = Join-Path $PSScriptRoot "backups"
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupFile = Join-Path $backupDir "tv_initial_state_$timestamp.txt"

@(
    "=== TCL ANDROID TV INITIAL STATE BACKUP ($timestamp) ===",
    "`n--- CURRENT HOME ROLE HOLDER ---",
    (adb shell cmd role get-role-holders android.app.role.HOME),
    "`n--- ENABLED PACKAGES ---",
    (adb shell pm list packages -e),
    "`n--- ALREADY DISABLED PACKAGES ---",
    (adb shell pm list packages -d),
    "`n--- GLOBAL SETTINGS ---",
    (adb shell settings list global),
    "`n--- SECURE SETTINGS ---",
    (adb shell settings list secure),
    "`n--- BASELINE MEMORY SNAPSHOT ---",
    (adb shell dumpsys meminfo --package-summary)
) | Out-File -Encoding utf8 $backupFile
Write-Host "  -> Saved initial state backup to: $backupFile" -ForegroundColor Green

if ($ProjectivyApkPath -and (Test-Path $ProjectivyApkPath)) {
    Write-Host "[3/9] Sideloading Projectivy Launcher from APK..." -ForegroundColor Cyan
    adb install -r $ProjectivyApkPath
} else {
    Write-Host "[3/9] Verifying Projectivy Launcher installation..." -ForegroundColor Cyan
    $projInstalled = adb shell pm list packages | Select-String "com.spocky.projengmenu"
    if (-not $projInstalled) {
        Write-Warning "Projectivy (com.spocky.projengmenu) not found. Install it from Play Store or pass -ProjectivyApkPath."
    }
}

Write-Host "[4/9] Granting Projectivy Permissions, Accessibility & Doze Whitelist..." -ForegroundColor Cyan
adb shell pm grant com.spocky.projengmenu android.permission.READ_EXTERNAL_STORAGE 2>$null
adb shell pm grant com.spocky.projengmenu android.permission.WRITE_EXTERNAL_STORAGE 2>$null
adb shell pm grant com.spocky.projengmenu android.permission.WRITE_SECURE_SETTINGS 2>$null

adb shell appops set com.spocky.projengmenu SYSTEM_ALERT_WINDOW allow 2>$null
adb shell appops set com.spocky.projengmenu AUTO_START allow 2>$null
adb shell appops set com.spocky.projengmenu BIND_ACCESSIBILITY_SERVICE allow 2>$null
adb shell dumpsys deviceidle whitelist +com.spocky.projengmenu | Out-Null

$currentServices = (adb shell settings get secure enabled_accessibility_services).Trim()
$projService = "com.spocky.projengmenu/com.spocky.projengmenu.services.ProjectivyAccessibilityService"

if ($currentServices -eq "null" -or [string]::IsNullOrWhiteSpace($currentServices)) {
    $newServices = $projService
} elseif ($currentServices -notmatch "com.spocky.projengmenu") {
    $newServices = "$currentServices:$projService"
} else {
    $newServices = $currentServices
}
adb shell settings put secure enabled_accessibility_services $newServices
adb shell settings put secure accessibility_enabled 1

Write-Host "[5/9] Setting Projectivy as Native Default & Disabling Stock Launchers..." -ForegroundColor Cyan
adb shell cmd role add-role-holder --user 0 android.app.role.HOME com.spocky.projengmenu 2>$null
$stockLaunchers = @(
    "com.google.android.apps.tv.launcherx",
    "com.google.android.tvlauncher",
    "com.google.android.tungsten.setupwraith",
    "com.tcl.waterfall",
    "com.tcl.cyberui"
)
foreach ($launcher in $stockLaunchers) {
    adb shell pm disable-user --user 0 $launcher 2>$null | Out-Null
}

Write-Host "[6/9] Dynamically Detecting & Disabling TCL Telemetry / Bloatware..." -ForegroundColor Cyan
$enabledAll = (adb shell pm list packages -e) | ForEach-Object { ($_ -replace "package:", "").Trim() }

$knownTclBloat = @(
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
    "com.tcl.bootadservice"
)
if ($DisableMiracast) { $knownTclBloat += "com.tcl.miracast" }

$foundBloat = $knownTclBloat | Where-Object { $enabledAll -contains $_ }
foreach ($pkg in $foundBloat) {
    Write-Host "  -> Disabling $pkg"
    adb shell pm disable-user --user 0 $pkg 2>$null | Out-Null
}

Write-Host "[7/9] Applying UI Animation, Memory, Radio & Play Store Tweaks..." -ForegroundColor Cyan
adb shell settings put global window_animation_scale 0.5
adb shell settings put global transition_animation_scale 0.5
adb shell settings put global animator_duration_scale 0.5

adb shell settings put global package_verifier_enable 0
adb shell settings put global standard_max_cached_processes 2
adb shell settings put global max_cached_processes 2

adb shell settings put global wifi_scan_always_enabled 0
adb shell settings put global ble_scan_always_enabled 0
adb shell settings put global captive_portal_mode 0

adb shell cmd appops set com.android.vending RUN_IN_BACKGROUND ignore 2>$null

Write-Host "[8/9] Dynamically Discovering Installed Apps for Background & Wake-Lock Control..." -ForegroundColor Cyan
# 1. Pull all user-installed 3rd-party apps dynamically
$userApps = (adb shell pm list packages -3 -e) | ForEach-Object { ($_ -replace "package:", "").Trim() } | Where-Object { $_ }

# 2. Check for common pre-installed system streaming apps present on this TV
$systemStreamingCatalog = @(
    "com.netflix.ninja",
    "com.google.android.youtube.tv",
    "com.google.android.youtube.tvmusic",
    "com.amazon.amazonvideo.livingroom",
    "com.disney.disneyplus",
    "com.hulu.livingroomplus",
    "com.apple.atve.androidtv.appletv",
    "com.wbd.stream",
    "com.plexapp.android",
    "tv.twitch.android.app",
    "com.spotify.tv.android",
    "com.crunchyroll.crunchyroid",
    "in.startv.hotstar",
    "com.sonyliv",
    "com.graymatrix.did",
    "com.jio.media.stb.ondemand"
)
$installedSystemStreaming = $systemStreamingCatalog | Where-Object { $enabledAll -contains $_ }

# 3. Combine and deduplicate discovered apps
$allTargetApps = ($userApps + $installedSystemStreaming) | Select-Object -Unique

# 4. Auto-detect active keyboard (IME) and accessibility apps so they are never restricted
$activeIme = (adb shell settings get secure default_input_method).Trim()
$activeAcc = (adb shell settings get secure enabled_accessibility_services).Trim()
$protectedApps = @("com.spocky.projengmenu")

foreach ($app in $allTargetApps) {
    if (($activeIme -match [regex]::Escape($app)) -or ($activeAcc -match [regex]::Escape($app))) {
        $protectedApps += $app
    }
}

$appsToRestrict = $allTargetApps | Where-Object { $protectedApps -notcontains $_ }

# Apps that use Cast receiver or media server wake locks
$wakeLockExempt = @("com.netflix.ninja", "com.google.android.youtube.tv", "com.google.android.youtube.tvmusic", "com.plexapp.android", "org.xbmc.kodi")

foreach ($app in $appsToRestrict) {
    Write-Host "  -> Restricting background activity: $app"
    adb shell cmd appops set $app RUN_IN_BACKGROUND ignore 2>$null
    if ($wakeLockExempt -notcontains $app) {
        adb shell cmd appops set $app WAKE_LOCK ignore 2>$null
    }
}

Write-Host "[9/9] Running Ahead-of-Time (AOT) speed-profile Compilation on Discovered Apps..." -ForegroundColor Cyan
$compileTargets = ($allTargetApps + @("com.spocky.projengmenu")) | Select-Object -Unique | Where-Object { $enabledAll -contains $_ }

foreach ($target in $compileTargets) {
    Write-Host "  -> Compiling $target..."
    adb shell cmd package compile -m speed-profile -f $target 2>$null | Out-Null
}

adb shell monkey -p com.spocky.projengmenu 1 2>$null | Out-Null

Write-Host "Done! Backup saved and all discovered apps optimized via terminal." -ForegroundColor Green
adb disconnect | Out-Null