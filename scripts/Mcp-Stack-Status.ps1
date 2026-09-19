param(
    [string]$BaseDir = "C:\ProgramData\McpTunnelKit"
)

$ErrorActionPreference = "SilentlyContinue"
$tunnel = Join-Path $BaseDir "tunnel-client\tunnel-client.exe"
$version = if (Test-Path $tunnel) { (& $tunnel --version 2>$null) -join " " } else { "unavailable" }
Write-Output "tunnel_version=$version"

$failed = $false
$connectors = @(
    @{ Name = "serena"; Task = "McpTunnelKit-Serena"; Port = 18090 },
    @{ Name = "playwright"; Task = "McpTunnelKit-Playwright"; Port = 18092 },
    @{ Name = "stitch"; Task = "McpTunnelKit-Stitch"; Port = 18093 }
)

foreach ($connector in $connectors) {
    $profile = Join-Path $BaseDir ("config\" + $connector.Name + ".yaml")
    if (-not (Test-Path $profile)) {
        Write-Output ($connector.Name + "_task=not-installed")
        continue
    }
    $task = Get-ScheduledTask -TaskName $connector.Task
    $taskState = if ($task) { $task.State.ToString().ToLowerInvariant() } else { "missing" }
    try { $health = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri ("http://127.0.0.1:" + $connector.Port + "/healthz")).Content.Trim() } catch { $health = "unavailable" }
    try { $ready = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri ("http://127.0.0.1:" + $connector.Port + "/readyz")).Content.Trim() } catch { $ready = "unavailable" }
    Write-Output ($connector.Name + "_task=" + $taskState)
    Write-Output ($connector.Name + "_health=" + $health)
    Write-Output ($connector.Name + "_ready=" + $ready)
    if ($health -ne "live" -or $ready -ne "ready") { $failed = $true }
}

$processes = Get-CimInstance Win32_Process
$tunnels = @($processes | Where-Object { $_.CommandLine -match 'tunnel-client\.exe\s+run' }).Count
Write-Output "tunnel_processes=$tunnels"
if ($failed) { exit 1 }
