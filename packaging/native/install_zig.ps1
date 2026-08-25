# SPDX-License-Identifier: Apache-2.0
param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = "Stop"
if ($Version -ne "0.15.2") {
    throw "unsupported Zig version: $Version"
}
if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [Runtime.InteropServices.OSPlatform]::Windows)) {
    throw "the PowerShell Zig installer only supports Windows"
}
if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne
    [Runtime.InteropServices.Architecture]::X64) {
    throw "unsupported Zig Windows architecture"
}
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw "RUNNER_TEMP is required"
}
if ([string]::IsNullOrWhiteSpace($env:GITHUB_PATH)) {
    throw "GITHUB_PATH is required"
}

$downloadUrl = "https://ziglang.org/download/$Version/zig-x86_64-windows-$Version.zip"
$expectedChecksum = "3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c"
$archive = Join-Path $env:RUNNER_TEMP "notify-zig-$([guid]::NewGuid().ToString("N")).zip"
$installRoot = Join-Path $env:RUNNER_TEMP "notify-zig-$Version-$([guid]::NewGuid().ToString("N"))"
$installComplete = $false

try {
    Invoke-WebRequest `
        -Uri $downloadUrl `
        -OutFile $archive `
        -MaximumRetryCount 3 `
        -SslProtocol Tls12

    $actualChecksum = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualChecksum -ne $expectedChecksum) {
        throw "checksum mismatch for Zig $Version (x86_64-windows)"
    }

    Expand-Archive -LiteralPath $archive -DestinationPath $installRoot
    $zigDirectory = Join-Path $installRoot "zig-x86_64-windows-$Version"
    $zigExecutable = Join-Path $zigDirectory "zig.exe"
    if (-not (Test-Path -LiteralPath $zigExecutable -PathType Leaf)) {
        throw "Zig archive did not contain an executable"
    }
    if ((& $zigExecutable version) -ne $Version) {
        throw "installed Zig version does not match $Version"
    }

    Add-Content -LiteralPath $env:GITHUB_PATH -Value $zigDirectory -Encoding utf8
    $installComplete = $true
    Write-Output "installed Zig $Version for x86_64-windows"
}
finally {
    if (Test-Path -LiteralPath $archive -PathType Leaf) {
        Remove-Item -LiteralPath $archive -Force
    }
    if (-not $installComplete -and (Test-Path -LiteralPath $installRoot)) {
        Remove-Item -LiteralPath $installRoot -Recurse -Force
    }
}
