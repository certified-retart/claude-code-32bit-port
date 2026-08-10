[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "ClaudeCode-x86"),
    [switch]$AddToPath,
    [ValidateRange(60, 100)][int]$HighTemperatureC = 85,
    [ValidateRange(50, 95)][int]$ResumeTemperatureC = 75
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$TotalSteps = 7
$CurrentStep = 0
$TemperatureSensorState = "unknown"

$NodeVersion = "22.22.2"
$NodeArchive = "node-v$NodeVersion-win-x86.zip"
$NodeUrl = "https://nodejs.org/download/release/v$NodeVersion/$NodeArchive"
$NodeSha256 = "ca892f829a733109e341c43585fd2094177e9d2f2c45f97c7ed3cf329d5427c5"
$ClaudeVersion = "2.1.112"
$RipgrepVersion = "1.18.0"
$SharpVersion = "0.34.2"
$LibvipsVersion = "1.1.0"
$ClaudeUrl = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-$ClaudeVersion.tgz"
$RipgrepUrl = "https://registry.npmjs.org/@vscode/ripgrep-win32-ia32/-/ripgrep-win32-ia32-$RipgrepVersion.tgz"
$SharpUrl = "https://registry.npmjs.org/@img/sharp-win32-ia32/-/sharp-win32-ia32-$SharpVersion.tgz"
$LibvipsUrl = "https://registry.npmjs.org/@img/sharp-libvips-win32-ia32/-/sharp-libvips-win32-ia32-$LibvipsVersion.tgz"
$ClaudeSha512 = "f4552027410ebc82f2848ab114a35596279b8948cbebc770a445b77864927b4be4543275739a8c0cd59cdb6816df3903ef3440aad7d03d21afd2de2f30cd833c"
$RipgrepSha512 = "fffadf004f813b0e400b610c99ea66884dfa8d4b9ebed418350aaa970d6cde6f45951c63c44badf7b46444f1c0bbd046e264a88dab59c7e91765735dc88f5c69"
$SharpSha512 = "40b8c61af01b8f45ff15797c9f559bb50ea2541a5653b24ef78bbf3f63386bc08562cbd08b8196da6472fc9aa4471d2aa41cda39d2892b0f2e73ddf4117d801f"
$LibvipsSha512 = "8919194b78f39760546833eec8d5b3e5d093125297e4f81e0357343ad29d0058b469c2d51dc5af7b883b62da249973fa83d561f1d8bc0ea1203ed8eda47a8c30"

function Write-Step([string]$Message) {
    $script:CurrentStep++
    Write-Host "`n[$script:CurrentStep/$script:TotalSteps] $Message" -ForegroundColor Cyan
}

function Format-Megabytes([long]$Bytes) {
    return "{0:N1}" -f ($Bytes / 1MB)
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($Arguments -join ' ')"
    }
}

function Download-File([string]$Uri, [string]$Destination) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.UserAgent = "ClaudeCode-x86-port-installer"
    $response = $null
    $inputStream = $null
    $outputStream = $null

    try {
        $response = $request.GetResponse()
        $totalBytes = [long]$response.ContentLength
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] 65536
        $downloaded = [long]0
        $nextPercent = 0
        $lastReport = [DateTime]::UtcNow

        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $downloaded += $read

            if ($totalBytes -gt 0) {
                $percent = [Math]::Min(100, [Math]::Floor(($downloaded * 100.0) / $totalBytes))
                if ($percent -ge $nextPercent -or ([DateTime]::UtcNow - $lastReport).TotalSeconds -ge 2) {
                    Write-Host -NoNewline ("`r  {0,3}%  {1}/{2} MB" -f $percent, (Format-Megabytes $downloaded), (Format-Megabytes $totalBytes))
                    $nextPercent = [Math]::Min(100, $percent + 5)
                    $lastReport = [DateTime]::UtcNow
                }
            }
            elseif (([DateTime]::UtcNow - $lastReport).TotalSeconds -ge 2) {
                Write-Host -NoNewline ("`r  Downloaded {0} MB" -f (Format-Megabytes $downloaded))
                $lastReport = [DateTime]::UtcNow
            }
        }

        if ($totalBytes -gt 0) {
            Write-Host ("`r  100%  {0}/{1} MB" -f (Format-Megabytes $downloaded), (Format-Megabytes $totalBytes))
        }
        else {
            Write-Host ("`r  Downloaded {0} MB" -f (Format-Megabytes $downloaded))
        }
    }
    finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Get-CpuTemperatureC {
    try {
        $values = @(Get-WmiObject -Namespace "root\wmi" -Class "MSAcpi_ThermalZoneTemperature" -ErrorAction Stop |
            ForEach-Object { ($_.CurrentTemperature / 10.0) - 273.15 } |
            Where-Object { $_ -ge 1 -and $_ -le 115 })
        if ($values.Count -eq 0) { return $null }
        return [Math]::Round(($values | Measure-Object -Maximum).Maximum, 1)
    }
    catch {
        return $null
    }
}

function Protect-Temperature([string]$Activity) {
    $temperature = Get-CpuTemperatureC
    if ($null -eq $temperature) {
        if ($script:TemperatureSensorState -ne "unavailable") {
            Write-Host "Temperature sensor unavailable; using short conservative pauses between heavy stages." -ForegroundColor Yellow
            $script:TemperatureSensorState = "unavailable"
        }
        Start-Sleep -Seconds 3
        return
    }

    if ($script:TemperatureSensorState -ne "available") {
        Write-Host "Temperature monitoring active (pause at $HighTemperatureC C; resume at $ResumeTemperatureC C)." -ForegroundColor Green
        $script:TemperatureSensorState = "available"
    }

    Write-Host "Temperature before ${Activity}: $temperature C"
    if ($temperature -lt $HighTemperatureC) { return }

    $waitedSeconds = 0
    Write-Warning "Temperature is $temperature C. Pausing installation to cool down."
    while ($temperature -gt $ResumeTemperatureC) {
        Start-Sleep -Seconds 20
        $waitedSeconds += 20
        $temperature = Get-CpuTemperatureC

        if ($null -eq $temperature) {
            Write-Warning "Temperature sensor stopped responding. Waiting 30 more seconds before continuing."
            Start-Sleep -Seconds 30
            return
        }

        Write-Host "  Cooldown: $temperature C after $waitedSeconds seconds"
        if ($waitedSeconds -ge 600) {
            throw "The computer stayed above $ResumeTemperatureC C for 10 minutes. Installation stopped safely."
        }
    }

    Write-Host "Temperature is back to $temperature C. Continuing." -ForegroundColor Green
}

function Download-VerifiedPackage(
    [string]$Name,
    [string]$Uri,
    [string]$ExpectedSha512,
    [string]$Destination
) {
    Protect-Temperature "downloading $Name"
    Write-Host "Downloading $Name"
    Download-File $Uri $Destination
    Write-Host "  Verifying SHA-512..." -NoNewline
    $actual = (Get-FileHash -Algorithm SHA512 -Path $Destination).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha512) {
        throw "$Name checksum mismatch. Expected $ExpectedSha512 but received $actual."
    }
    Write-Host " OK" -ForegroundColor Green
}

function Add-UserPath([string]$Directory) {
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @()
    if ($current) {
        $parts = @($current.Split(';') | Where-Object { $_ })
    }

    if ($parts -notcontains $Directory) {
        $updated = (@($parts) + $Directory) -join ';'
        [Environment]::SetEnvironmentVariable("Path", $updated, "User")
        Write-Host "Added $Directory to your user PATH. Open a new terminal before using claude-x86."
    }
}

if (-not $env:LOCALAPPDATA) {
    throw "LOCALAPPDATA is unavailable. Pass an explicit -InstallDir."
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw "This installer only supports Windows."
}

if ($ResumeTemperatureC -ge $HighTemperatureC) {
    throw "ResumeTemperatureC must be lower than HighTemperatureC."
}

$workDir = Join-Path $env:TEMP ("claude-code-x86-" + [Guid]::NewGuid().ToString("N"))
$stageDir = Join-Path $workDir "stage"
$nodeZip = Join-Path $workDir $NodeArchive
$nodeExtract = Join-Path $workDir "node-extract"
$runtimeDir = Join-Path $stageDir "runtime"
$claudeDir = Join-Path $runtimeDir "node_modules\@anthropic-ai\claude-code"
$ripgrepTarget = Join-Path $claudeDir "vendor\ripgrep\ia32-win32"
$ripgrepPackageDir = Join-Path $runtimeDir "node_modules\@vscode\ripgrep-win32-ia32"
$sharpPackageDir = Join-Path $runtimeDir "node_modules\@img\sharp-win32-ia32"
$libvipsPackageDir = Join-Path $runtimeDir "node_modules\@img\sharp-libvips-win32-ia32"
$extractor = Join-Path $PSScriptRoot "extract-tgz.js"
$backupDir = $null
$installationCommitted = $false

try {
    Write-Step "Preparing installation"
    New-Item -ItemType Directory -Force -Path $stageDir, $nodeExtract, $runtimeDir | Out-Null
    Protect-Temperature "installation"

    Write-Step "Downloading official 32-bit Node.js $NodeVersion"
    Download-File $NodeUrl $nodeZip
    Write-Host "Verifying Node.js SHA-256..." -NoNewline
    $actualHash = (Get-FileHash -Algorithm SHA256 -Path $nodeZip).Hash.ToLowerInvariant()
    if ($actualHash -ne $NodeSha256) {
        throw "Node.js checksum mismatch. Expected $NodeSha256 but received $actualHash."
    }
    Write-Host " OK" -ForegroundColor Green

    Protect-Temperature "expanding Node.js"
    Write-Host "Expanding Node.js archive..."
    Expand-Archive -Path $nodeZip -DestinationPath $nodeExtract -Force
    $nodeSource = Join-Path $nodeExtract "node-v$NodeVersion-win-x86"
    if (-not (Test-Path (Join-Path $nodeSource "node.exe"))) {
        throw "The Node.js archive did not contain the expected x86 runtime."
    }
    Move-Item -Path $nodeSource -Destination (Join-Path $stageDir "node")

    Write-Step "Verifying the 32-bit runtime"
    $nodeExe = Join-Path $stageDir "node\node.exe"
    $detectedArch = (& $nodeExe -p "process.arch").Trim()
    if ($detectedArch -ne "ia32") {
        throw "Downloaded Node.js reported '$detectedArch', not 'ia32'."
    }

    if (-not (Test-Path $extractor)) {
        throw "extract-tgz.js is missing. Download the complete repository ZIP and extract every file."
    }

    $claudeArchive = Join-Path $workDir "claude-code.tgz"
    $ripgrepArchive = Join-Path $workDir "ripgrep-x86.tgz"
    $sharpArchive = Join-Path $workDir "sharp-x86.tgz"
    $libvipsArchive = Join-Path $workDir "libvips-x86.tgz"

    Write-Step "Downloading verified application packages"
    Download-VerifiedPackage "Claude Code $ClaudeVersion" $ClaudeUrl $ClaudeSha512 $claudeArchive
    Download-VerifiedPackage "ripgrep x86 $RipgrepVersion" $RipgrepUrl $RipgrepSha512 $ripgrepArchive
    Download-VerifiedPackage "Sharp x86 $SharpVersion" $SharpUrl $SharpSha512 $sharpArchive
    Download-VerifiedPackage "libvips x86 $LibvipsVersion" $LibvipsUrl $LibvipsSha512 $libvipsArchive

    Write-Step "Extracting packages with 32-bit Node.js"
    New-Item -ItemType Directory -Force -Path $claudeDir, $ripgrepPackageDir, $sharpPackageDir, $libvipsPackageDir | Out-Null
    Protect-Temperature "extracting Claude Code"
    Write-Host "Claude Code archive:"
    Invoke-Checked -FilePath $nodeExe -Arguments @($extractor, $claudeArchive, $claudeDir)
    Protect-Temperature "extracting ripgrep"
    Write-Host "ripgrep archive:"
    Invoke-Checked -FilePath $nodeExe -Arguments @($extractor, $ripgrepArchive, $ripgrepPackageDir)
    Protect-Temperature "extracting Sharp"
    Write-Host "Sharp archive:"
    Invoke-Checked -FilePath $nodeExe -Arguments @($extractor, $sharpArchive, $sharpPackageDir)
    Protect-Temperature "extracting libvips"
    Write-Host "libvips archive:"
    Invoke-Checked -FilePath $nodeExe -Arguments @($extractor, $libvipsArchive, $libvipsPackageDir)

    $ripgrepSource = Join-Path $ripgrepPackageDir "bin\rg.exe"
    if (-not (Test-Path $ripgrepSource)) {
        throw "The x86 ripgrep package did not contain rg.exe."
    }
    New-Item -ItemType Directory -Force -Path $ripgrepTarget | Out-Null
    Copy-Item -Force -Path $ripgrepSource -Destination (Join-Path $ripgrepTarget "rg.exe")

    $launcher = @'
@echo off
setlocal
set "DISABLE_AUTOUPDATER=1"
set "CLAUDE_CODE_USE_POWERSHELL_TOOL=1"
"%~dp0node\node.exe" --max-old-space-size=1024 "%~dp0runtime\node_modules\@anthropic-ai\claude-code\cli.js" %*
exit /b %errorlevel%
'@
    [IO.File]::WriteAllText((Join-Path $stageDir "claude-x86.cmd"), $launcher, [Text.Encoding]::ASCII)

    $versionLauncher = Join-Path $stageDir "claude-x86.cmd"
    Write-Step "Running x86 smoke tests"
    Protect-Temperature "running smoke tests"
    Invoke-Checked -FilePath (Join-Path $ripgrepTarget "rg.exe") -Arguments @("--version")
    Invoke-Checked -FilePath $versionLauncher -Arguments @("--version")

    Write-Step "Installing files"
    if (Test-Path $InstallDir) {
        $backupDir = "$InstallDir.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-Host "Moving the previous installation to $backupDir"
        Move-Item -Path $InstallDir -Destination $backupDir
    }

    $parentDir = Split-Path -Parent $InstallDir
    New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
    Move-Item -Path $stageDir -Destination $InstallDir
    $installationCommitted = $true

    if ($AddToPath) {
        Add-UserPath $InstallDir
    }

    Write-Host "`nClaude Code x86 installed successfully." -ForegroundColor Green
    Write-Host "Launcher: $(Join-Path $InstallDir 'claude-x86.cmd')"
    Write-Host "Version: $ClaudeVersion (pinned; automatic updates disabled)"
    Write-Host "Runtime: Node.js $NodeVersion ia32"
    if ($backupDir) {
        Write-Host "Previous installation backup: $backupDir"
    }
    if (-not $AddToPath) {
        Write-Host "Run with: `"$(Join-Path $InstallDir 'claude-x86.cmd')`""
    }
}
catch {
    if (-not $installationCommitted -and $backupDir -and
        -not (Test-Path $InstallDir) -and (Test-Path $backupDir)) {
        Move-Item -Path $backupDir -Destination $InstallDir
    }
    throw
}
finally {
    if (Test-Path $workDir) {
        Remove-Item -Recurse -Force -Path $workDir
    }
}
