# Builds the signed multi-flavor Android APK on this machine, without CI.
#
# One-time setup this expects (already done on this box):
#   - Flutter SDK            C:\dev\flutter
#   - JDK 17                 C:\Program Files\Eclipse Adoptium\jdk-17*
#   - Rust + android target  %USERPROFILE%\.cargo  (rustup target add aarch64-linux-android)
#   - Android SDK + NDK      %LOCALAPPDATA%\Android\Sdk
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\build_local_apk.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\build_local_apk.ps1 -SkipSign
#
# The signed APK lands in dist\eSIM-Matrix-v<version>.apk.

param(
    [switch]$SkipSign,
    [string]$FlutterRoot = 'C:\dev\flutter',
    [string]$JdkRoot = 'C:\Program Files\Eclipse Adoptium\jdk-17.0.21.9-hotspot',
    [string]$AndroidSdk = "$env:LOCALAPPDATA\Android\Sdk"
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$env:JAVA_HOME = $JdkRoot
$env:ANDROID_HOME = $AndroidSdk
$env:ANDROID_SDK_ROOT = $AndroidSdk
$env:ANDROID_NDK_HOME = (Get-ChildItem "$AndroidSdk\ndk" -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$env:PATH = "$JdkRoot\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"

# Version comes from pubspec so the APK name cannot drift from the build.
$versionLine = Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*(\S+)' | Select-Object -First 1
if (-not $versionLine) { throw 'pubspec.yaml has no version line' }
$version = $versionLine.Matches[0].Groups[1].Value.Split('+')[0]

Write-Host "==> flutter build apk (multi, arm64, v$version)" -ForegroundColor Cyan
& "$FlutterRoot\bin\flutter.bat" build apk --release --flavor m --target-platform android-arm64 --no-pub `
    --dart-define=APP_VARIANT=multi `
    --dart-define=APP_DISPLAY_NAME=eSIM-Matrix `
    --dart-define=APP_UPDATE_FEED_URL=https://raw.githubusercontent.com/hg552/eSIM-Matrix/main/update_feed.json
if ($LASTEXITCODE -ne 0) { throw "flutter build failed ($LASTEXITCODE)" }

$unsigned = 'build\app\outputs\flutter-apk\app-m-release.apk'
if (-not (Test-Path $unsigned)) { throw "missing $unsigned" }

# Cargokit can fail (a host linker missing, say) and Gradle still emits an APK
# without the Rust library; the app then installs and loses QRTR/SE HAL at
# runtime. Refuse to hand out such a build.
$entries = & 'C:\Windows\System32\tar.exe' -tf $unsigned
if ($LASTEXITCODE -ne 0) { throw 'could not list the built APK' }
if (-not ($entries | Select-String -SimpleMatch 'lib/arm64-v8a/librust_lib_nlpa2.so')) {
    throw 'the APK has no lib/arm64-v8a/librust_lib_nlpa2.so: the Rust build failed (see the cargokit output above)'
}

if ($SkipSign) {
    Write-Host "==> unsigned APK: $unsigned" -ForegroundColor Yellow
    exit 0
}

New-Item -ItemType Directory -Force -Path 'dist' | Out-Null
$out = "dist\eSIM-Matrix-v$version.apk"

# Same three certificates as the published builds, so this installs over them.
$apksigner = Get-ChildItem "$AndroidSdk\build-tools" -Directory |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'apksigner.bat' } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
if (-not $apksigner) { throw 'apksigner not found in the Android SDK build-tools' }

Write-Host "==> signing with the three release certificates" -ForegroundColor Cyan
& $apksigner sign `
    --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled false `
    --ks android\app\community.jks --ks-pass pass:CommunityKey --ks-key-alias communitykey --key-pass pass:CommunityKey `
    --next-signer `
    --ks android\app\9eSIMCommunityKey.jks --ks-pass pass:147258369 --ks-key-alias key0 --key-pass pass:147258369 `
    --next-signer `
    --ks android\app\sakurasim.jks --ks-pass pass:sakurasim --ks-key-alias sakurasim --key-pass pass:sakurasim `
    --out $out $unsigned
if ($LASTEXITCODE -ne 0) { throw "apksigner failed ($LASTEXITCODE)" }

& $apksigner verify --print-certs $out | Select-String 'SHA-1 digest'
$hash = (Get-FileHash $out -Algorithm SHA256).Hash
$size = [math]::Round((Get-Item $out).Length / 1MB, 2)
Write-Host "==> $out  ($size MB)" -ForegroundColor Green
Write-Host "==> SHA-256 $hash" -ForegroundColor Green
