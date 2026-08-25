# SPDX-License-Identifier: Apache-2.0
param(
    [Parameter(Mandatory = $true)]
    [string]$Artifact
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
$artifactPath = (Resolve-Path -LiteralPath $Artifact).Path
$smokeDirectory = Join-Path ([IO.Path]::GetTempPath()) ("notify-native-smoke-" + [guid]::NewGuid().ToString("N"))
$serverProcess = $null
$port = if ($env:NOTIFY_NATIVE_SMOKE_PORT) { [int]$env:NOTIFY_NATIVE_SMOKE_PORT } else { 18083 + (Get-Random -Minimum 0 -Maximum 1000) }
if ($port -lt 1024 -or $port -gt 65535) {
    throw "NOTIFY_NATIVE_SMOKE_PORT must be between 1024 and 65535"
}
$baseUrl = "http://127.0.0.1:$port"
$username = "admin"
$password = "native smoke password"
$topic = "native-smoke-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())-$PID"
$message = "durable native smoke message"

function Invoke-Notify {
    param([string[]]$Arguments)
    $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $output = @(& $script:artifactPath @Arguments 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
    }
    if ($exitCode -ne 0) {
        $redacted = ($output -join "`n") -replace 'tk_[A-Za-z0-9]{29}', '<redacted>'
        throw "native command failed: $($Arguments[0])`n$redacted"
    }
    return $output
}

function Invoke-ErlangNifProbe {
    param(
        [string]$Application,
        [string]$LibraryName,
        [string]$Expression
    )

    $ertsExecutables = @(Get-ChildItem -LiteralPath $env:NOTIFY_INSTALL_DIR `
        -Recurse -File -Filter "erl.exe")
    if ($ertsExecutables.Count -ne 1) {
        throw "native install did not contain exactly one erl.exe"
    }
    $bootFiles = @(Get-ChildItem -LiteralPath $env:NOTIFY_INSTALL_DIR `
        -Recurse -File -Filter "start.boot")
    if ($bootFiles.Count -ne 1) {
        throw "native install did not contain exactly one start.boot"
    }
    $releaseRoot = $bootFiles[0].Directory.Parent.Parent
    $releaseLibrary = Join-Path $releaseRoot.FullName "lib"
    if (-not (Test-Path -LiteralPath $releaseLibrary -PathType Container)) {
        throw "native install omitted its release library directory"
    }
    $bootPath = $bootFiles[0].FullName.Substring(
        0,
        $bootFiles[0].FullName.Length - ".boot".Length
    )
    $libraries = @(Get-ChildItem -LiteralPath $env:NOTIFY_INSTALL_DIR `
        -Recurse -File -Filter $LibraryName)
    if ($libraries.Count -ne 1) {
        throw "native install did not contain exactly one $LibraryName"
    }
    $applicationDirectory = $libraries[0].Directory.Parent
    if ($applicationDirectory.Name -notlike "$Application-*") {
        throw "$LibraryName was outside the expected $Application application"
    }
    $ebinPath = Join-Path $applicationDirectory.FullName "ebin"
    if (-not (Test-Path -LiteralPath $ebinPath -PathType Container)) {
        throw "$Application application omitted its ebin directory"
    }

    $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $probeOutput = @(& $ertsExecutables[0].FullName `
            -root $releaseRoot.FullName `
            -boot $bootPath `
            -boot_var RELEASE_LIB $releaseLibrary `
            -noshell `
            -pa $ebinPath `
            -eval $Expression 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
    }
    if ($exitCode -ne 0) {
        $redacted = ($probeOutput -join "`n") -replace 'tk_[A-Za-z0-9]{29}', '<redacted>'
        throw "$Application NIF probe failed`n$redacted"
    }
}

function Start-NotifyServer {
    $script:serverLog = Join-Path $script:smokeDirectory "server.log"
    $script:serverError = Join-Path $script:smokeDirectory "server-error.log"
    $arguments = @(
        "serve", "--listen-host", "127.0.0.1", "--port", "$script:port",
        "--base-url", $script:baseUrl, "--log-format", "json"
    )
    $script:serverProcess = Start-Process -FilePath $script:artifactPath `
        -ArgumentList $arguments `
        -RedirectStandardOutput $script:serverLog `
        -RedirectStandardError $script:serverError `
        -PassThru
    for ($attempt = 0; $attempt -lt 30; $attempt += 1) {
        try {
            Invoke-WebRequest -Uri "$script:baseUrl/healthz" -UseBasicParsing -TimeoutSec 2 | Out-Null
            return
        }
        catch {
            if ($script:serverProcess.HasExited) {
                throw "native Windows server exited before becoming healthy"
            }
            Start-Sleep -Seconds 1
        }
    }
    throw "native Windows server did not become healthy within 30 seconds"
}

function Stop-NotifyServerForRecovery {
    if ($null -ne $script:serverProcess -and -not $script:serverProcess.HasExited) {
        taskkill.exe /PID $script:serverProcess.Id /T /F | Out-Null
        $script:serverProcess.WaitForExit()

        for ($attempt = 0; $attempt -lt 10; $attempt += 1) {
            try {
                Invoke-WebRequest -Uri "$script:baseUrl/healthz" -UseBasicParsing -TimeoutSec 1 | Out-Null
                Start-Sleep -Milliseconds 250
            }
            catch {
                $script:serverProcess = $null
                return
            }
        }
        throw "native Windows listener survived forced process-tree stop"
    }
    $script:serverProcess = $null
}

try {
    New-Item -ItemType Directory -Path $smokeDirectory | Out-Null
    $env:NOTIFY_INSTALL_DIR = Join-Path $smokeDirectory "install"
    $env:NOTIFY_DATABASE_BACKEND = "sqlite"
    $env:NOTIFY_DATABASE_PATH = Join-Path $smokeDirectory "notify.db"
    $env:NOTIFY_ATTACHMENT_BACKEND = "filesystem"
    $env:NOTIFY_ATTACHMENT_DIRECTORY = Join-Path $smokeDirectory "attachments"
    $env:NOTIFY_PASSWORD = $password
    $env:ERL_CRASH_DUMP = Join-Path $smokeDirectory "erl_crash.dump"

    $help = Invoke-Notify @("help")
    if (($help -join "`n") -notmatch "Usage: notify <command> \[options\]") {
        throw "native help contract is missing"
    }
    Invoke-ErlangNifProbe `
        -Application "esqlite" `
        -LibraryName "esqlite3_nif.dll" `
        -Expression 'case esqlite3:open(":memory:") of {ok, Connection} -> ok = esqlite3:close(Connection), halt(0); Other -> io:format("~p~n", [Other]), halt(2) end.'
    Invoke-ErlangNifProbe `
        -Application "jargon" `
        -LibraryName "jargon.dll" `
        -Expression 'case jargon:hash(<<"native-smoke-password">>, <<"0123456789abcdef0123456789abcdef">>, argon2id, 1, 1024, 1, 16) of {ok, _, _} -> halt(0); Other -> io:format("~p~n", [Other]), halt(2) end.'
    Invoke-ErlangNifProbe `
        -Application "bcrypt" `
        -LibraryName "bcrypt_nif.dll" `
        -Expression 'try _ = bcrypt_nif:create_ctx(), halt(0) catch Class:Reason:Stack -> io:format("~p:~p~n~p~n", [Class, Reason, Stack]), halt(2) end.'
    $doctor = Invoke-Notify @("doctor")
    if (($doctor -join "`n") -notmatch "PASS doctor: all required dependencies are healthy") {
        throw "native doctor did not report healthy dependencies"
    }
    $setup = Invoke-Notify @("setup", "--username", $username, "--anonymous-access", "deny")
    if (($setup -join "`n") -notmatch "setup complete; administrator admin created") {
        throw "native setup did not complete"
    }
    $tokenOutput = Invoke-Notify @("token", "create", $username, "--label", "native-smoke")
    $rawToken = @($tokenOutput | Where-Object { $_ -match '^tk_[A-Za-z0-9]{29}$' } | Select-Object -Last 1)
    if ($rawToken.Count -ne 1) {
        throw "native token command did not return the fixed 32-character contract"
    }

    Start-NotifyServer
    $publishOutput = Invoke-Notify @("publish", $topic, $message, "--server", $baseUrl, "--token", $rawToken[0])
    $publishLine = $publishOutput | Where-Object { $_.TrimStart().StartsWith("{") } | Select-Object -Last 1
    $published = $publishLine | ConvertFrom-Json
    if ($published.id.Length -ne 12 -or $published.topic -ne $topic -or $published.message -ne $message) {
        throw "native publish response violated the message contract"
    }
    $messageId = $published.id
    $pollOutput = Invoke-Notify @("subscribe", $topic, "--server", $baseUrl, "--token", $rawToken[0], "--since", "all")
    $matches = @($pollOutput | Where-Object { $_.TrimStart().StartsWith("{") } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq "message" -and $_.id -eq $messageId })
    if ($matches.Count -ne 1) {
        throw "native poll did not return exactly one published message"
    }
    Stop-NotifyServerForRecovery

    Start-NotifyServer
    $pollOutput = Invoke-Notify @("subscribe", $topic, "--server", $baseUrl, "--token", $rawToken[0], "--since", "all")
    $matches = @($pollOutput | Where-Object { $_.TrimStart().StartsWith("{") } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq "message" -and $_.id -eq $messageId })
    if ($matches.Count -ne 1) {
        throw "native Windows restart did not recover exactly one published message"
    }
    Stop-NotifyServerForRecovery

    Write-Output "Windows native setup, publish/poll, and forced-stop recovery smoke passed"
}
catch {
    if (Test-Path -LiteralPath $env:ERL_CRASH_DUMP -PathType Leaf) {
        Write-Output "Erlang crash dump tail:"
        Get-Content -LiteralPath $env:ERL_CRASH_DUMP -Tail 120
    }
    throw
}
finally {
    Stop-NotifyServerForRecovery
    if (Test-Path -LiteralPath $smokeDirectory) {
        Remove-Item -LiteralPath $smokeDirectory -Recurse -Force
    }
}
