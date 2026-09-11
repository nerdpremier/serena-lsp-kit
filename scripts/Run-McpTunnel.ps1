param(
    [string]$BaseDir = "C:\ProgramData\McpTunnelKit",
    [Parameter(Mandatory = $true)]
    [ValidateSet("serena", "github", "playwright")]
    [string]$Connector
)

$ErrorActionPreference = "Stop"
$envFile = Join-Path $BaseDir "config\$Connector.env"
$profile = Join-Path $BaseDir "config\$Connector.yaml"
$tunnel = Join-Path $BaseDir "tunnel-client\tunnel-client.exe"

if (-not (Test-Path $envFile)) { throw "Missing secrets file: $envFile" }
if (-not (Test-Path $profile)) { throw "Missing profile: $profile" }
if (-not (Test-Path $tunnel)) { throw "Missing tunnel-client: $tunnel" }

foreach ($line in Get-Content -LiteralPath $envFile) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { continue }
    $pair = $line.Split("=", 2)
    if ($pair.Count -ne 2) { continue }
    [Environment]::SetEnvironmentVariable($pair[0], $pair[1], "Process")
}

Set-Location $BaseDir
& $tunnel run --profile-file $profile
exit $LASTEXITCODE
