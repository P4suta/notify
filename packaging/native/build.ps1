param(
    [ValidateSet("linux_amd64", "linux_arm64", "macos_amd64", "macos_arm64", "windows_amd64")]
    [string]$Target = "windows_amd64"
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [Runtime.InteropServices.OSPlatform]::Windows)) {
    throw "Burrito does not support Windows build hosts; build on Linux or macOS"
}

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "../..")).Path
$buildScript = Join-Path $root "packaging/native/build.sh"
$previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference

try {
    $PSNativeCommandUseErrorActionPreference = $false
    $output = @(& /bin/sh $buildScript $Target 2>&1 | ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
}
finally {
    $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
}

if ($exitCode -ne 0) {
    throw "native build failed for $Target`n$($output -join "`n")"
}
$output | Write-Output
