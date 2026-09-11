param(
    [string]$BaseDir = "C:\ProgramData\McpTunnelKit",
    [int]$HealthPort = 18090,
    [string]$TaskName = "McpTunnelKit"
)

$ErrorActionPreference = "SilentlyContinue"
$tunnel = Join-Path $BaseDir "tunnel-client\tunnel-client.exe"
$task = Get-ScheduledTask -TaskName $TaskName
$taskState = if ($task) { $task.State.ToString().ToLowerInvariant() } else { "missing" }
$version = if (Test-Path $tunnel) { (& $tunnel --version 2>$null) -join " " } else { "unavailable" }

function Get-Probe([string]$Path) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri "http://127.0.0.1:$HealthPort/$Path"
        return $r.Content.Trim()
    } catch {
        return "unavailable"
    }
}

$health = Get-Probe "healthz"
$ready = Get-Probe "readyz"
$processes = Get-CimInstance Win32_Process
$serena = @($processes | Where-Object { $_.CommandLine -match 'serena(.exe)?\s+start-mcp-server' }).Count
$github = @($processes | Where-Object { $_.CommandLine -match 'github-mcp-server(.exe)?\s+stdio' }).Count
$playwright = @($processes | Where-Object { $_.CommandLine -match 'playwright[\\/]mcp[\\/]cli\.js' }).Count
$tunnels = @($processes | Where-Object { $_.CommandLine -match 'tunnel-client\.exe\s+run' }).Count

Write-Output "task=$taskState"
Write-Output "tunnel_version=$version"
Write-Output "health=$health"
Write-Output "ready=$ready"
Write-Output "serena_processes=$serena"
Write-Output "github_mcp_processes=$github"
Write-Output "playwright_mcp_processes=$playwright"
Write-Output "tunnel_processes=$tunnels"

if ($health -ne "live" -or $ready -ne "ready") { exit 1 }
