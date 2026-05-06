# Build media_player_helper.dex from MediaPlayerHelper.java
# Requires Android SDK build-tools (d8 or dx) and a JDK for javac.
#
# Usage (from any directory):
#   powershell -ExecutionPolicy Bypass -File build-dex.ps1
#
# Or with a custom SDK path:
#   $env:ANDROID_HOME = "C:\MyPath\Android\Sdk"; .\build-dex.ps1

$ScriptDir = $PSScriptRoot
$JavaFile  = Join-Path $ScriptDir "MediaPlayerHelper.java"
$ClassDir  = Join-Path $ScriptDir "classes"
$DexOut    = Join-Path $ScriptDir "media_player_helper.dex"

# ── Locate Android SDK ────────────────────────────────────────────────────────
$AndroidHome = if ($env:ANDROID_HOME) { $env:ANDROID_HOME }
               elseif (Test-Path "$env:LOCALAPPDATA\Android\Sdk") { "$env:LOCALAPPDATA\Android\Sdk" }
               elseif (Test-Path "C:\Android\Sdk")                { "C:\Android\Sdk" }
               else { $null }

if (-not $AndroidHome -or -not (Test-Path $AndroidHome)) {
    Write-Error "Android SDK not found. Set `$env:ANDROID_HOME or install Android Studio."
    exit 1
}
Write-Host "Android SDK: $AndroidHome"

$AndroidApi = if ($env:ANDROID_API) { $env:ANDROID_API } else { "21" }
$AndroidJar = Join-Path $AndroidHome "platforms\android-$AndroidApi\android.jar"
if (-not (Test-Path $AndroidJar)) {
    # Try higher API levels if the exact one is missing
    $PlatformsDir = Join-Path $AndroidHome "platforms"
    $AndroidJar = Get-ChildItem $PlatformsDir -Directory |
        Where-Object { $_.Name -match "^android-(\d+)$" } |
        Sort-Object { [int]($_.Name -replace 'android-', '') } |
        Select-Object -Last 1 |
        ForEach-Object { Join-Path $_.FullName "android.jar" }
    if (-not $AndroidJar -or -not (Test-Path $AndroidJar)) {
        Write-Error "android.jar not found. Install an Android SDK platform via SDK Manager."
        exit 1
    }
}
Write-Host "android.jar: $AndroidJar"

# ── Locate build tools (d8 preferred, dx fallback) ───────────────────────────
$BuildToolsDir = Join-Path $AndroidHome "build-tools"
$LatestBuildTools = Get-ChildItem $BuildToolsDir -Directory |
    Sort-Object Name -Descending | Select-Object -First 1

$D8  = if ($LatestBuildTools) { Join-Path $LatestBuildTools.FullName "d8.bat" }  else { $null }
$Dx  = if ($LatestBuildTools) { Join-Path $LatestBuildTools.FullName "dx.bat" }  else { $null }

$UseD8 = $D8 -and (Test-Path $D8)
$UseDx = $Dx -and (Test-Path $Dx)

if (-not $UseD8 -and -not $UseDx) {
    Write-Error "Neither d8 nor dx found in build-tools. Install build-tools via SDK Manager."
    exit 1
}
Write-Host "Build tool: $(if ($UseD8) { $D8 } else { $Dx })"

# ── Compile Java ──────────────────────────────────────────────────────────────
if (Test-Path $ClassDir) { Remove-Item $ClassDir -Recurse -Force }
New-Item -ItemType Directory -Path $ClassDir | Out-Null

Write-Host "Compiling MediaPlayerHelper.java..."
& javac -classpath $AndroidJar --release 8 -d $ClassDir $JavaFile
if ($LASTEXITCODE -ne 0) {
    Write-Error "javac failed. Make sure a JDK is installed and on your PATH."
    exit 1
}

# ── Convert to DEX ────────────────────────────────────────────────────────────
Write-Host "Converting to DEX..."
$ClassFile = Join-Path $ClassDir "org\koreader\plugin\readaloud\MediaPlayerHelper.class"

if ($UseD8) {
    & $D8 --release --min-api $AndroidApi --output $ScriptDir $ClassFile
} else {
    & $Dx --dex "--output=$DexOut" $ClassDir
}

if ($LASTEXITCODE -ne 0) {
    Write-Error "DEX conversion failed."
    Remove-Item $ClassDir -Recurse -Force
    exit 1
}

Remove-Item $ClassDir -Recurse -Force

# d8 outputs classes.dex; rename to our expected name
$D8Output = Join-Path $ScriptDir "classes.dex"
if (Test-Path $D8Output) { Move-Item $D8Output $DexOut -Force }

if (Test-Path $DexOut) {
    Write-Host "Done: $DexOut"
} else {
    Write-Error "DEX file not found after build. Check output above."
    exit 1
}
