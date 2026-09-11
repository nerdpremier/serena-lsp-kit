[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ProjectPath,
    [string]$SerenaTunnelId = $env:SERENA_TUNNEL_ID,
    [string]$GitHubTunnelId = $env:GITHUB_TUNNEL_ID,
    [string]$PlaywrightTunnelId = $env:PLAYWRIGHT_TUNNEL_ID,
    [switch]$SkipGitHub,
    [switch]$SkipPlaywright
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$TunnelVersion = "0.0.14"
$GitHubMcpVersion = "1.12.1"
$NodeVersion = "24.21.0"
$PlaywrightMcpVersion = "0.0.80"
$BaseDir = "C:\ProgramData\McpTunnelKit"
$TunnelDir = Join-Path $BaseDir "tunnel-client"
$GitHubDir = Join-Path $BaseDir "github-mcp"
$NodeDir = Join-Path $BaseDir "node"
$PlaywrightDir = Join-Path $BaseDir "playwright"
$BrowsersDir = Join-Path $BaseDir "ms-playwright"
$SerenaVenv = Join-Path $BaseDir "serena-venv"
$ConfigDir = Join-Path $BaseDir "config"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run PowerShell as Administrator."
    }
}

function Read-SecretText([string]$Prompt) {
    $secure = Read-Host $Prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Read-TunnelId([string]$Current, [string]$Label) {
    $value = $Current
    if ([string]::IsNullOrWhiteSpace($value)) { $value = Read-Host "$Label tunnel ID (tunnel_...)" }
    if ($value -notmatch '^tunnel_[a-z0-9]{32}$') { throw "$Label Tunnel ID must look like tunnel_..." }
    return $value
}

function Get-Uv {
    $cmd = Get-Command uv.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Write-Host "Installing uv from the official Astral installer..."
    $script = Invoke-RestMethod -Uri "https://astral.sh/uv/install.ps1"
    Invoke-Expression $script
    $candidate = Join-Path $env:USERPROFILE ".local\bin\uv.exe"
    if (-not (Test-Path $candidate)) { throw "uv installation completed but uv.exe was not found." }
    return $candidate
}

function Download-VerifiedZip([string]$Url, [string]$ChecksumUrl, [string]$AssetName, [string]$Destination) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("mcp-kit-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $archive = Join-Path $tmp $AssetName
        $checksums = Join-Path $tmp "checksums.txt"
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $archive
        Invoke-WebRequest -UseBasicParsing -Uri $ChecksumUrl -OutFile $checksums
        $line = Get-Content $checksums | Where-Object { $_ -match ("\s" + [regex]::Escape($AssetName) + "$") } | Select-Object -First 1
        if (-not $line) { throw "Checksum entry missing for $AssetName" }
        $expected = ($line -split "\s+")[0].ToLowerInvariant()
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "SHA256 mismatch for $AssetName" }
        if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
        New-Item -ItemType Directory -Path $Destination | Out-Null
        Expand-Archive -LiteralPath $archive -DestinationPath $Destination -Force
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

function Get-GoogleChromePath {
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles "Google\Chrome\Application\chrome.exe") }
    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    if ($programFilesX86) { $candidates += (Join-Path $programFilesX86 "Google\Chrome\Application\chrome.exe") }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe") }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    return $null
}

function Install-GoogleChromeStable {
    $existing = Get-GoogleChromePath
    if ($existing) { return $existing }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host "Google Chrome was not found. Installing Google Chrome Stable with winget..."
        & $winget.Source install --id Google.Chrome --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
        $installed = Get-GoogleChromePath
        if ($installed) { return $installed }
        Write-Warning "winget did not produce a detectable Google Chrome installation; trying the official Google MSI fallback."
    }

    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
        throw "Google Chrome is required for Playwright. Automatic ARM64 installation requires winget; install App Installer/winget or Google Chrome Stable, then rerun bootstrap.ps1."
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("mcp-kit-chrome-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $msi = Join-Path $tmp "GoogleChromeStandaloneEnterprise64.msi"
        $url = "https://dl.google.com/chrome/install/googlechromestandaloneenterprise64.msi"
        Write-Host "Downloading the official Google Chrome Stable MSI..."
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $msi
        $signature = Get-AuthenticodeSignature -LiteralPath $msi
        if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
            -not $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -notmatch '(^|,\s*)(CN|O)=Google LLC(,|$)') {
            throw "Google Chrome MSI Authenticode validation failed."
        }
        $process = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') -Wait -PassThru
        if ($process.ExitCode -notin @(0, 3010)) { throw "Google Chrome MSI installation failed with exit code $($process.ExitCode)." }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }

    $installed = Get-GoogleChromePath
    if (-not $installed) { throw "Google Chrome installation completed but chrome.exe was not found." }
    return $installed
}

function Protect-File([string]$Path) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $rights = [Security.AccessControl.FileSystemRights]::FullControl
    $inheritance = [Security.AccessControl.InheritanceFlags]::None
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sid in @($identity.User, (New-Object Security.Principal.SecurityIdentifier("S-1-5-18")), (New-Object Security.Principal.SecurityIdentifier("S-1-5-32-544")))) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, $rights, $inheritance, $propagation, $allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Register-ConnectorTask([string]$Name, [string]$Connector, [string]$RunScript) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $userName = $identity.Name
    $taskName = "McpTunnelKit-$Name"
    $actionArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$RunScript`" -BaseDir `"$BaseDir`" -Connector $Connector"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $actionArgs
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userName
    $principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
}

Assert-Administrator
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) { throw "Project directory not found: $ProjectPath" }

$SerenaTunnelId = Read-TunnelId $SerenaTunnelId "Serena"
if (-not $SkipGitHub) { $GitHubTunnelId = Read-TunnelId $GitHubTunnelId "GitHub" }
if (-not $SkipPlaywright) { $PlaywrightTunnelId = Read-TunnelId $PlaywrightTunnelId "Playwright" }

$ControlKey = $env:CONTROL_PLANE_API_KEY
if ([string]::IsNullOrWhiteSpace($ControlKey)) { $ControlKey = Read-SecretText "OpenAI Control Plane API key" }
if ([string]::IsNullOrWhiteSpace($ControlKey)) { throw "Control Plane API key is required." }

$GitHubToken = $env:GITHUB_PERSONAL_ACCESS_TOKEN
if (-not $SkipGitHub -and [string]::IsNullOrWhiteSpace($GitHubToken)) { $GitHubToken = Read-SecretText "GitHub Personal Access Token" }
if (-not $SkipGitHub -and [string]::IsNullOrWhiteSpace($GitHubToken)) { throw "GitHub token is required unless -SkipGitHub is used." }

New-Item -ItemType Directory -Force -Path $BaseDir, $ConfigDir | Out-Null
$uv = Get-Uv
$SerenaPython = Join-Path $SerenaVenv "Scripts\python.exe"
$SerenaExe = Join-Path $SerenaVenv "Scripts\serena.exe"
if (-not (Test-Path $SerenaExe) -or ((& $SerenaExe --version 2>$null) -ne "Serena 1.7.0")) {
    if (Test-Path $SerenaVenv) { Remove-Item -Recurse -Force $SerenaVenv }
    & $uv venv $SerenaVenv --python 3.12
    if ($LASTEXITCODE -ne 0) { throw "uv venv failed" }
    & $uv pip install --python $SerenaPython "serena-agent==1.7.0"
    if ($LASTEXITCODE -ne 0) { throw "Serena installation failed" }
}
if ((& $SerenaExe --version) -ne "Serena 1.7.0") { throw "Serena 1.7.0 validation failed" }

$SerenaConfig = Join-Path $env:USERPROFILE ".serena\serena_config.yml"
if (-not (Test-Path $SerenaConfig)) { & $SerenaExe init -b LSP }
if (-not (Test-Path (Join-Path $ProjectPath ".serena\project.yml"))) { & $SerenaExe project create $ProjectPath }
& $SerenaPython (Join-Path $PSScriptRoot "scripts\configure_runtime.py") serena-global $SerenaConfig
& $SerenaPython (Join-Path $PSScriptRoot "scripts\configure_runtime.py") project-local (Join-Path $ProjectPath ".serena\project.local.yml")
$PackageRoot = (& $SerenaPython -c "import pathlib,serena; print(pathlib.Path(serena.__file__).resolve().parent)").Trim()
& $SerenaPython (Join-Path $PSScriptRoot "scripts\patch_serena.py") $PackageRoot
if ($LASTEXITCODE -ne 0) { throw "Serena LSP-only patch failed" }

if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
    $TunnelArch = "windows-arm64"; $GitHubArch = "arm64"; $NodeArch = "win-arm64"
} else {
    $TunnelArch = "windows-amd64"; $GitHubArch = "x86_64"; $NodeArch = "win-x64"
}

$TunnelAsset = "tunnel-client-v$TunnelVersion-$TunnelArch.zip"
Download-VerifiedZip "https://github.com/openai/tunnel-client/releases/download/v$TunnelVersion/$TunnelAsset" "https://github.com/openai/tunnel-client/releases/download/v$TunnelVersion/SHA256SUMS.txt" $TunnelAsset $TunnelDir
$TunnelExe = Join-Path $TunnelDir "tunnel-client.exe"

$GitHubExe = $null
if (-not $SkipGitHub) {
    $asset = "github-mcp-server_Windows_$GitHubArch.zip"
    Download-VerifiedZip "https://github.com/github/github-mcp-server/releases/download/v$GitHubMcpVersion/$asset" "https://github.com/github/github-mcp-server/releases/download/v$GitHubMcpVersion/github-mcp-server_${GitHubMcpVersion}_checksums.txt" $asset $GitHubDir
    $GitHubExe = Join-Path $GitHubDir "github-mcp-server.exe"
}

$NodeExe = $null
$PlaywrightCli = $null
$PlaywrightBrowser = $null
if (-not $SkipPlaywright) {
    $nodeAsset = "node-v$NodeVersion-$NodeArch.zip"
    $nodeStage = Join-Path $BaseDir "node-stage"
    Download-VerifiedZip "https://nodejs.org/dist/v$NodeVersion/$nodeAsset" "https://nodejs.org/dist/v$NodeVersion/SHASUMS256.txt" $nodeAsset $nodeStage
    $nodeRoot = Get-ChildItem -LiteralPath $nodeStage -Directory | Select-Object -First 1
    if (Test-Path $NodeDir) { Remove-Item -Recurse -Force $NodeDir }
    Move-Item -LiteralPath $nodeRoot.FullName -Destination $NodeDir
    Remove-Item -Recurse -Force $nodeStage
    $NodeExe = Join-Path $NodeDir "node.exe"
    $Npm = Join-Path $NodeDir "npm.cmd"
    New-Item -ItemType Directory -Force -Path $PlaywrightDir, $BrowsersDir | Out-Null
    & $Npm install --prefix $PlaywrightDir --omit=dev --no-audit --no-fund "@playwright/mcp@$PlaywrightMcpVersion"
    if ($LASTEXITCODE -ne 0) { throw "Playwright MCP npm install failed" }
    $PlaywrightCli = Join-Path $PlaywrightDir "node_modules\@playwright\mcp\cli.js"
    $PlaywrightBrowser = Install-GoogleChromeStable
    Write-Host "playwright_browser=$PlaywrightBrowser"
}

$env:CONTROL_PLANE_API_KEY = $ControlKey
$SerenaProfile = Join-Path $ConfigDir "serena.yaml"
$SerenaEnv = Join-Path $ConfigDir "serena.env"
& $SerenaPython (Join-Path $PSScriptRoot "scripts\multi_mcp_config.py") serena $SerenaProfile $SerenaEnv $SerenaTunnelId --health-port 18090 $ProjectPath --serena-bin $SerenaExe

if (-not $SkipGitHub) {
    $env:GITHUB_PERSONAL_ACCESS_TOKEN = $GitHubToken
    $GitHubProfile = Join-Path $ConfigDir "github.yaml"
    $GitHubEnv = Join-Path $ConfigDir "github.env"
    & $SerenaPython (Join-Path $PSScriptRoot "scripts\multi_mcp_config.py") github $GitHubProfile $GitHubEnv $GitHubTunnelId --health-port 18091 --github-bin $GitHubExe
}

if (-not $SkipPlaywright) {
    $PlaywrightProfile = Join-Path $ConfigDir "playwright.yaml"
    $PlaywrightEnv = Join-Path $ConfigDir "playwright.env"
    & $SerenaPython (Join-Path $PSScriptRoot "scripts\multi_mcp_config.py") playwright $PlaywrightProfile $PlaywrightEnv $PlaywrightTunnelId --health-port 18092 --node-bin $NodeExe --playwright-cli $PlaywrightCli --output-dir (Join-Path $BaseDir "artifacts\playwright") --browsers-path $BrowsersDir --browser-executable $PlaywrightBrowser
}

Get-ChildItem -LiteralPath $ConfigDir -File | Where-Object { $_.Extension -in @('.yaml', '.env') } | ForEach-Object { Protect-File $_.FullName }

& $TunnelExe doctor --profile-file $SerenaProfile --health.listen-addr 127.0.0.1:0 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Serena tunnel doctor failed" }
if (-not $SkipGitHub) {
    & $TunnelExe doctor --profile-file $GitHubProfile --health.listen-addr 127.0.0.1:0 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "GitHub tunnel doctor failed" }
}
if (-not $SkipPlaywright) {
    & $TunnelExe doctor --profile-file $PlaywrightProfile --health.listen-addr 127.0.0.1:0 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Playwright tunnel doctor failed" }
}
Write-Host "tunnel_doctor=PASS"

$ScriptsDir = Join-Path $BaseDir "scripts"
New-Item -ItemType Directory -Force -Path $ScriptsDir | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot "scripts\Run-McpTunnel.ps1") (Join-Path $ScriptsDir "Run-McpTunnel.ps1")
Copy-Item -Force (Join-Path $PSScriptRoot "scripts\Mcp-Stack-Status.ps1") (Join-Path $ScriptsDir "Mcp-Stack-Status.ps1")
$runScript = Join-Path $ScriptsDir "Run-McpTunnel.ps1"

# Remove the old bundled task if upgrading from the one-tunnel layout.
$legacy = Get-ScheduledTask -TaskName "McpTunnelKit" -ErrorAction SilentlyContinue
if ($legacy) { Stop-ScheduledTask -TaskName "McpTunnelKit" -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName "McpTunnelKit" -Confirm:$false }

Register-ConnectorTask "Serena" "serena" $runScript
if (-not $SkipGitHub) { Register-ConnectorTask "GitHub" "github" $runScript }
if (-not $SkipPlaywright) { Register-ConnectorTask "Playwright" "playwright" $runScript }
Start-Sleep -Seconds 5

& (Join-Path $ScriptsDir "Mcp-Stack-Status.ps1") -BaseDir $BaseDir
if ($LASTEXITCODE -ne 0) { throw "One or more MCP tunnel tasks failed readiness checks" }

$env:CONTROL_PLANE_API_KEY = $null
$env:GITHUB_PERSONAL_ACCESS_TOKEN = $null
$env:PLAYWRIGHT_BROWSERS_PATH = $null
$ControlKey = $null
$GitHubToken = $null
Write-Host "bootstrap=PASS"
Write-Host "connectors=serena,github,playwright"
