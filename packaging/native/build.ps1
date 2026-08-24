$ErrorActionPreference = "Stop"
$env:BURRITO_TARGET = "windows_amd64"
$env:MIX_ENV = "prod"
mix deps.get
mix release
