param(
    [ValidateSet("linux_amd64", "linux_arm64", "macos_amd64", "macos_arm64", "windows_amd64")]
    [string]$Target = "windows_amd64"
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "../..")).Path
if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    throw "Burrito does not support Windows build hosts; cross-build windows_amd64 on Linux or macOS"
}
$hostOperatingSystem = if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
    "macos"
}
elseif ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)) {
    "linux"
}
else {
    throw "unsupported native build operating system"
}
$processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
$hostArchitecture = switch ($processArchitecture.ToString()) {
    "X64" { "amd64" }
    "Arm64" { "arm64" }
    default { throw "unsupported native build architecture: $processArchitecture" }
}
$hostTarget = "${hostOperatingSystem}_${hostArchitecture}"
if ($Target -ne "windows_amd64" -and $Target -ne $hostTarget) {
    throw "native target $Target requires its matching build host; detected $hostTarget"
}
foreach ($command in @("elixir", "gleam", "mix", "xz", "zig")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "required native build command not found: $command"
    }
}
if ($Target -eq "windows_amd64" -and -not (Get-Command 7z -ErrorAction SilentlyContinue)) {
    throw "required Windows target build command not found: 7z"
}
if ((zig version) -ne "0.15.2") {
    throw "native builds require Zig 0.15.2"
}

$buildDirectory = Join-Path ([IO.Path]::GetTempPath()) ("notify-native-build-" + [guid]::NewGuid().ToString("N"))
$stage = Join-Path $buildDirectory "source"
$pushedLocation = $false
$promotion = $null
$originalBurritoTarget = [Environment]::GetEnvironmentVariable("BURRITO_TARGET", "Process")
$originalMixEnvironment = [Environment]::GetEnvironmentVariable("MIX_ENV", "Process")
$originalErlLibraries = [Environment]::GetEnvironmentVariable("ERL_LIBS", "Process")

try {
    New-Item -ItemType Directory -Path (Join-Path $stage "packages/notify_core") -Force | Out-Null
    foreach ($file in @("gleam.toml", "mix.exs", "mix.lock")) {
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $stage $file)
    }
    foreach ($directory in @("config", "lib", "priv", "src")) {
        $source = Join-Path $root $directory
        if (Test-Path -LiteralPath $source -PathType Container) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $stage $directory) -Recurse
        }
    }
    foreach ($file in @("gleam.toml", "mix.exs")) {
        $source = Join-Path $root "packages/notify_core/$file"
        $destination = Join-Path $stage "packages/notify_core/$file"
        Copy-Item -LiteralPath $source -Destination $destination
    }
    Copy-Item -LiteralPath (Join-Path $root "packages/notify_core/src") `
        -Destination (Join-Path $stage "packages/notify_core/src") -Recurse

    $env:BURRITO_TARGET = $Target
    $env:MIX_ENV = "prod"
    Push-Location $stage
    $pushedLocation = $true
    mix archive.check
    mix deps.get --only prod --check-locked
    elixir (Join-Path $root "packaging/native/patch_burrito_launcher.exs") `
        (Join-Path $stage "deps/burrito/src/erlang_launcher.zig")
    mix deps.compile
    $hpackApplication = Join-Path $stage "_build/prod/lib/hpack_erl/ebin/hpack.app"
    if (-not (Test-Path -LiteralPath $hpackApplication -PathType Leaf)) {
        throw "hpack_erl did not publish the expected hpack OTP application"
    }
    $mistApplication = Join-Path $stage "_build/prod/lib/mist/ebin/mist.app"
    if (-not (Test-Path -LiteralPath $mistApplication -PathType Leaf)) {
        throw "mist did not publish the expected OTP application metadata"
    }
    elixir (Join-Path $root "packaging/native/normalize_hpack_app.exs") $mistApplication
    $otpLibrary = Join-Path $buildDirectory "otp_lib"
    New-Item -ItemType Directory -Path $otpLibrary | Out-Null
    Copy-Item -LiteralPath (Join-Path $stage "_build/prod/lib/hpack_erl") `
        -Destination (Join-Path $otpLibrary "hpack-0.3.0") -Recurse
    $env:ERL_LIBS = if ([string]::IsNullOrEmpty($originalErlLibraries)) {
        $otpLibrary
    }
    else {
        $otpLibrary + [IO.Path]::PathSeparator + $originalErlLibraries
    }
    mix compile --no-deps-check
    mix release --overwrite --no-compile

    $extension = if ($Target -eq "windows_amd64") { ".exe" } else { "" }
    $relativeArtifact = Join-Path "burrito_out" "notify_$Target$extension"
    if (-not (Test-Path -LiteralPath $relativeArtifact -PathType Leaf)) {
        throw "Burrito did not create expected artifact: $relativeArtifact"
    }

    $outputDirectory = Join-Path $root "burrito_out"
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $artifact = Join-Path $outputDirectory "notify_$Target$extension"
    $promotion = "$artifact.tmp-$PID"
    Copy-Item -LiteralPath $relativeArtifact -Destination $promotion
    Move-Item -LiteralPath $promotion -Destination $artifact -Force
}
finally {
    if ($pushedLocation) {
        Pop-Location
    }
    if (Test-Path -LiteralPath $buildDirectory) {
        Remove-Item -LiteralPath $buildDirectory -Recurse -Force
    }
    if ($null -ne $promotion -and (Test-Path -LiteralPath $promotion -PathType Leaf)) {
        Remove-Item -LiteralPath $promotion -Force
    }
    [Environment]::SetEnvironmentVariable("BURRITO_TARGET", $originalBurritoTarget, "Process")
    [Environment]::SetEnvironmentVariable("MIX_ENV", $originalMixEnvironment, "Process")
    [Environment]::SetEnvironmentVariable("ERL_LIBS", $originalErlLibraries, "Process")
}

Write-Output (Join-Path "burrito_out" "notify_$Target$extension")
