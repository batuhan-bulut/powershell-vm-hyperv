<#
.SYNOPSIS
    Automates the provisioning of an Ubuntu VM on Hyper-V using cloud-init.
.DESCRIPTION
    This script checks for QEMU, downloads the selected Ubuntu cloud image,
    converts it to a Hyper-V VHDX format, natively creates a cloud-init (NoCloud) seed disk,
    provisions a Generation 2 Hyper-V VM, and starts it.
.PARAMETER VMName
    The name of the Hyper-V Virtual Machine to be created. Default: "Ubuntu26-VM"
.PARAMETER WorkDir
    The directory where downloads, disk images, and temp files are stored. Default: "C:\HyperV-Ubuntu"
.PARAMETER UbuntuVersion
    The version of Ubuntu to download. Default: "26.04"
.PARAMETER Username
    The default admin username to create in the VM. Default: "ubuntu"
.PARAMETER Password
    The password for the default admin user. Only used with -AllowPasswordAuth.
.PARAMETER PasswordPlainText
    Plain text password for noninteractive runs. Prefer passing a pipeline secret variable or the UBUNTU_VM_PASSWORD environment variable.
.PARAMETER PasswordEnvironmentVariable
    Environment variable name to read the password from when -AllowPasswordAuth is used and -Password is not supplied. Default: UBUNTU_VM_PASSWORD.
.PARAMETER NonInteractive
    Prevents prompts. Useful in CI pipelines; required values must come from parameters or environment variables.
.PARAMETER SshPublicKey
    Optional SSH public key (e.g. "ssh-rsa AAAAB3N...") to add to authorized_keys for the user.
.PARAMETER MemorySize
    The startup memory size for the VM. Default: 2GB
.PARAMETER CpuCount
    The number of virtual processors for the VM. Default: 2
.PARAMETER SwitchName
    The name of the Hyper-V virtual switch to connect the VM to. If unspecified, it automatically
    detects the "Default Switch" or the first available internal/external switch.
.PARAMETER StartVM
    Switch to automatically start the VM after provisioning. Default: $true
.PARAMETER AllowPasswordAuth
    Enables password login in cloud-init. If omitted, SSH key authentication is required.
.PARAMETER InstallQemuWithWinget
    Allows the script to install QEMU with winget if qemu-img.exe is missing.
.PARAMETER InstallAria2WithWinget
    Allows the script to install aria2 with winget if aria2c.exe is missing and the selected download method needs it.
.PARAMETER DownloadMethod
    Downloader to use. Auto prefers aria2c, then BITS, then Invoke-WebRequest.
.PARAMETER Aria2Connections
    Number of parallel connections to use when aria2c is selected. Default: 8.
.EXAMPLE
    PS C:\> .\Create-UbuntuVM.ps1 -VMName "MyUbuntuServer" -SshPublicKey "ssh-ed25519 AAAA..."
.EXAMPLE
    PS C:\> .\Create-UbuntuVM.ps1 -VMName "MyUbuntuServer" -AllowPasswordAuth -Password (Read-Host -AsSecureString)
.EXAMPLE
    PS C:\> $env:UBUNTU_VM_PASSWORD = "PipelineSecret"; .\Create-UbuntuVM.ps1 -VMName "MyUbuntuServer" -AllowPasswordAuth
.EXAMPLE
    PS C:\> .\Create-UbuntuVM.ps1 -VMName "MyUbuntuServer" -SshPublicKey "ssh-ed25519 AAAA..." -InstallAria2WithWinget -DownloadMethod Aria2
#>

[CmdletBinding()]
param(
    [string]$VMName = "Ubuntu26-VM",
    [string]$WorkDir = "C:\HyperV-Ubuntu",
    [string]$UbuntuVersion = "26.04",
    [string]$Username = "ubuntu",
    [Securestring]$Password = $null,
    [string]$PasswordPlainText = $null,
    [string]$PasswordEnvironmentVariable = "UBUNTU_VM_PASSWORD",
    [switch]$NonInteractive,
    [string]$SshPublicKey = $null,
    [long]$MemorySize = 2GB,
    [int]$CpuCount = 2,
    [string]$SwitchName = $null,
    [bool]$StartVM = $true,
    [switch]$AllowPasswordAuth,
    [switch]$InstallQemuWithWinget,
    [switch]$InstallAria2WithWinget,
    [ValidateSet("Auto", "Aria2", "Bits", "WebRequest")]
    [string]$DownloadMethod = "Auto",
    [ValidateRange(1, 16)]
    [int]$Aria2Connections = 8
)

# Set Strict Mode and Error Action
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# -------------------------------------------------------------
# 1. PREREQUISITES CHECK
# -------------------------------------------------------------
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Ubuntu Hyper-V Provisioning Script Starting     " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# Check for Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "CRITICAL: This script must be run as Administrator (elevated privilege is required for disk partitioning and VM creation)."
    Exit
}

# Check if Hyper-V PowerShell module is installed and available
if (-not (Get-Command -Module Hyper-V -ErrorAction SilentlyContinue)) {
    Write-Error "CRITICAL: The Hyper-V PowerShell module is not available. Please ensure Hyper-V is enabled on this system."
    Exit
}

# Ensure working directory exists
if (-not (Test-Path $WorkDir)) {
    Write-Host "Creating working directory at: $WorkDir" -ForegroundColor Gray
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
}

# Determine Switch Name if not supplied
if (-not $SwitchName) {
    Write-Host "SwitchName parameter not provided. Detecting network switches..." -ForegroundColor Gray
    $defaultSwitch = Get-VMSwitch | Where-Object { $_.SwitchType -eq 'Internal' -and $_.Name -like "*Default*" } | Select-Object -First 1
    if ($defaultSwitch) {
        $SwitchName = $defaultSwitch.Name
        Write-Host "Detected and selected default internal switch: '$SwitchName'" -ForegroundColor Green
    }
    else {
        $anySwitch = Get-VMSwitch | Select-Object -First 1
        if ($anySwitch) {
            $SwitchName = $anySwitch.Name
            Write-Host "Selected first available switch: '$SwitchName'" -ForegroundColor Green
        }
        else {
            Write-Error "CRITICAL: No Hyper-V Virtual Switch was detected. Please create a virtual switch first."
            Exit
        }
    }
}

# -------------------------------------------------------------
# 2. QEMU INSTALLATION
# -------------------------------------------------------------
Function Get-QemuImgPath {
    # Check system PATH
    $cmd = Get-Command qemu-img -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    # Check default installation paths
    $defaultPaths = @(
        "C:\Program Files\qemu\qemu-img.exe",
        "C:\Program Files (x86)\qemu\qemu-img.exe"
    )
    foreach ($path in $defaultPaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    return $null
}

Function Get-Aria2Path {
    $cmd = Get-Command aria2c -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $candidateRoots = @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"),
        "C:\Program Files",
        "C:\Program Files (x86)"
    )

    foreach ($root in $candidateRoots) {
        if (-not (Test-Path $root)) {
            continue
        }

        $match = Get-ChildItem -Path $root -Filter "aria2c.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($match) {
            return $match.FullName
        }
    }

    return $null
}

Function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "winget is not available. Install $DisplayName manually or install App Installer from Microsoft Store."
    }

    Write-Host "Installing $DisplayName via Windows Package Manager (winget)..." -ForegroundColor Cyan
    $safeName = $DisplayName -replace '[^A-Za-z0-9_.-]', '-'
    $wingetStdOut = Join-Path $env:TEMP "$safeName-winget-stdout.log"
    $wingetStdErr = Join-Path $env:TEMP "$safeName-winget-stderr.log"
    Remove-Item -Path $wingetStdOut, $wingetStdErr -Force -ErrorAction SilentlyContinue

    $process = Start-Process `
        -FilePath $winget.Source `
        -ArgumentList @("install", "--id", $PackageId, "--exact", "--silent", "--accept-source-agreements", "--accept-package-agreements") `
        -Wait `
        -PassThru `
        -NoNewWindow `
        -RedirectStandardOutput $wingetStdOut `
        -RedirectStandardError $wingetStdErr

    if ($process.ExitCode -ne 0) {
        $wingetOutput = @()
        if (Test-Path $wingetStdOut) {
            $wingetOutput += Get-Content -Path $wingetStdOut -ErrorAction SilentlyContinue
        }
        if (Test-Path $wingetStdErr) {
            $wingetOutput += Get-Content -Path $wingetStdErr -ErrorAction SilentlyContinue
        }

        if ($wingetOutput.Count -gt 0) {
            Write-Host "winget output:" -ForegroundColor Yellow
            $wingetOutput | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        }

        throw "winget failed to install $DisplayName. Exit code: $($process.ExitCode)."
    }
}

Function Invoke-CheckedDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [string]$OutFile,
        [ValidateSet("Auto", "Aria2", "Bits", "WebRequest")]
        [string]$Method = $DownloadMethod,
        [switch]$AllowFallback
    )

    $outDir = Split-Path -Path $OutFile -Parent
    $outName = Split-Path -Path $OutFile -Leaf
    if (-not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $aria2Path = Get-Aria2Path
    if (-not $aria2Path -and $InstallAria2WithWinget -and ($Method -eq "Auto" -or $Method -eq "Aria2")) {
        Install-WingetPackage -PackageId "aria2.aria2" -DisplayName "aria2"
        $aria2Path = Get-Aria2Path
        if (-not $aria2Path) {
            throw "aria2 was installed, but aria2c.exe was not found. Open a new PowerShell session or add aria2c.exe to PATH."
        }
    }

    $bits = Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue
    $selectedMethod = $Method
    if ($selectedMethod -eq "Auto") {
        if ($aria2Path) {
            $selectedMethod = "Aria2"
        }
        elseif ($bits) {
            $selectedMethod = "Bits"
        }
        else {
            $selectedMethod = "WebRequest"
        }
    }

    if ($selectedMethod -eq "Aria2") {
        if (-not $aria2Path) {
            throw "DownloadMethod is Aria2, but aria2c was not found. Rerun with -InstallAria2WithWinget or install aria2 manually."
        }

        Write-Host "Downloading with aria2c ($Aria2Connections connections): $Uri" -ForegroundColor Gray
        $ariaArgs = @(
            "--continue=true",
            "--disable-ipv6=true",
            "--max-connection-per-server=$Aria2Connections",
            "--split=$Aria2Connections",
            "--min-split-size=1M",
            "--file-allocation=none",
            "--dir=$outDir",
            "--out=$outName",
            $Uri
        )
        $downloadProcess = Start-Process -FilePath $aria2Path -ArgumentList $ariaArgs -Wait -PassThru -NoNewWindow
        if ($downloadProcess.ExitCode -ne 0) {
            if ($AllowFallback) {
                if ($bits) {
                    Write-Warning "aria2c failed to download '$Uri'. Falling back to BITS."
                    $selectedMethod = "Bits"
                }
                else {
                    Write-Warning "aria2c failed to download '$Uri'. Falling back to WebRequest."
                    $selectedMethod = "WebRequest"
                }
            }
            else {
                throw "aria2c failed to download '$Uri'. Exit code: $($downloadProcess.ExitCode)."
            }
        }
        else {
            return
        }
    }

    if ($selectedMethod -eq "Bits") {
        if (-not $bits) {
            throw "DownloadMethod is Bits, but Start-BitsTransfer was not found."
        }

        Write-Host "Downloading with BITS: $Uri" -ForegroundColor Gray
        try {
            Start-BitsTransfer -Source $Uri -Destination $OutFile -ErrorAction Stop
        }
        catch {
            if ($AllowFallback) {
                Write-Warning "BITS failed to download '$Uri': $_"
                Write-Warning "Falling back to WebRequest."
                $selectedMethod = "WebRequest"
            }
            else {
                throw
            }
        }
        if ($selectedMethod -eq "Bits") {
            return
        }
    }

    $partialPath = "$OutFile.partial"
    if (Test-Path $partialPath) {
        Remove-Item -Path $partialPath -Force
    }

    Write-Host "Downloading with Invoke-WebRequest: $Uri" -ForegroundColor Gray
    Invoke-WebRequest -Uri $Uri -OutFile $partialPath -UseBasicParsing -ErrorAction Stop
    Move-Item -Path $partialPath -Destination $OutFile -Force
}

Function Convert-SecureStringToPlainText {
    param(
        [Parameter(Mandatory = $true)]
        [securestring]$SecureString
    )

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

Function Test-NonInteractiveRun {
    return $NonInteractive `
        -or $env:CI `
        -or $env:TF_BUILD `
        -or $env:GITHUB_ACTIONS `
        -or $env:BUILD_BUILDID
}

Function Get-ExpectedSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sha256SumsPath,
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $escapedFileName = [regex]::Escape($FileName)
    $line = Get-Content -Path $Sha256SumsPath | Where-Object { $_ -match "^\s*([A-Fa-f0-9]{64})\s+\*?$escapedFileName\s*$" } | Select-Object -First 1
    if (-not $line) {
        throw "Could not find '$FileName' in SHA256SUMS."
    }

    return ([regex]::Match($line, "^\s*([A-Fa-f0-9]{64})").Groups[1].Value).ToLowerInvariant()
}

Function Test-UbuntuImageChecksum {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,
        [Parameter(Mandatory = $true)]
        [string]$Sha256SumsPath,
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $expectedHash = Get-ExpectedSha256 -Sha256SumsPath $Sha256SumsPath -FileName $FileName
    $actualHash = (Get-FileHash -Path $ImagePath -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($actualHash -ne $expectedHash) {
        throw "Checksum mismatch for '$FileName'. Expected $expectedHash but got $actualHash."
    }
}

Function Write-IStreamToFile {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ComStream,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not ("ImapiStreamCopier" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class ImapiStreamCopier
{
    public static void CopyToFile(object comStream, string path)
    {
        IStream stream = (IStream)comStream;
        byte[] buffer = new byte[2048];
        IntPtr bytesReadPtr = Marshal.AllocHGlobal(sizeof(int));

        try
        {
            using (FileStream file = new FileStream(path, FileMode.Create, FileAccess.Write))
            {
                while (true)
                {
                    Marshal.WriteInt32(bytesReadPtr, 0);
                    stream.Read(buffer, buffer.Length, bytesReadPtr);
                    int bytesRead = Marshal.ReadInt32(bytesReadPtr);
                    if (bytesRead <= 0)
                    {
                        break;
                    }

                    file.Write(buffer, 0, bytesRead);
                }
            }
        }
        finally
        {
            Marshal.FreeHGlobal(bytesReadPtr);
        }
    }
}
"@
    }

    [ImapiStreamCopier]::CopyToFile($ComStream, $Path)
}

Function New-CidataIso {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IsoPath,
        [Parameter(Mandatory = $true)]
        [string]$UserData,
        [Parameter(Mandatory = $true)]
        [string]$MetaData
    )

    $seedSourceDir = Join-Path $WorkDir "cidata-source"
    if (Test-Path $seedSourceDir) {
        Remove-Item -Path $seedSourceDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $seedSourceDir -Force | Out-Null

    [System.IO.File]::WriteAllText((Join-Path $seedSourceDir "user-data"), $UserData, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $seedSourceDir "meta-data"), $MetaData, [System.Text.UTF8Encoding]::new($false))

    if (Test-Path $IsoPath) {
        Remove-Item -Path $IsoPath -Force
    }

    $fileSystemImage = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fileSystemImage.FileSystemsToCreate = 3
    $fileSystemImage.VolumeName = "cidata"
    $fileSystemImage.Root.AddTree($seedSourceDir, $false)

    $resultImage = $fileSystemImage.CreateResultImage()
    Write-IStreamToFile -ComStream $resultImage.ImageStream -Path $IsoPath
}

$qemuImg = Get-QemuImgPath

if (-not $qemuImg) {
    Write-Host "`nqemu-img.exe not found on the system." -ForegroundColor Yellow
    
    if ($InstallQemuWithWinget) {
        try {
            Install-WingetPackage -PackageId "SoftwareFreedomConservancy.QEMU" -DisplayName "QEMU"
        }
        catch {
            Write-Error "CRITICAL: $_ Install QEMU manually from https://www.qemu.org/download/#windows and ensure qemu-img.exe is on PATH."
            Exit
        }

        Start-Sleep -Seconds 5
        $qemuImg = Get-QemuImgPath
    }
    
    if (-not $qemuImg) {
        Write-Error "CRITICAL: qemu-img.exe is required. Install QEMU manually from https://www.qemu.org/download/#windows and add qemu-img.exe to PATH, or rerun with -InstallQemuWithWinget."
        Exit
    }
    
    Write-Host "QEMU successfully installed at: $qemuImg" -ForegroundColor Green
}
else {
    Write-Host "QEMU found at: $qemuImg" -ForegroundColor Green
}

# -------------------------------------------------------------
# 3. DOWNLOAD UBUNTU CLOUD IMAGE
# -------------------------------------------------------------
$ubuntuBaseUrl = "https://cloud-images.ubuntu.com/releases/$UbuntuVersion/release"
$imgFileName = "ubuntu-$UbuntuVersion-server-cloudimg-amd64.img"
$imgUrl = "$ubuntuBaseUrl/$imgFileName"
$localImgPath = Join-Path $WorkDir $imgFileName
$sha256SumsPath = Join-Path $WorkDir "SHA256SUMS-$UbuntuVersion"
$sha256SumsGpgPath = Join-Path $WorkDir "SHA256SUMS-$UbuntuVersion.gpg"

Write-Host "`nChecking for Ubuntu $UbuntuVersion Cloud Image..." -ForegroundColor Cyan
if (-not (Test-Path $localImgPath)) {
    Write-Host "Downloading Ubuntu Cloud Image from $imgUrl..." -ForegroundColor Cyan
    Write-Host "This is a large download and may take a moment. Please wait..." -ForegroundColor Gray
    
    Invoke-CheckedDownload -Uri $imgUrl -OutFile $localImgPath -AllowFallback
    Write-Host "Ubuntu image downloaded successfully: $localImgPath" -ForegroundColor Green
}
else {
    Write-Host "Ubuntu cloud image already exists at $localImgPath. Skipping download." -ForegroundColor Green
}

Write-Host "Downloading Ubuntu checksum files..." -ForegroundColor Cyan
Invoke-CheckedDownload -Uri "$ubuntuBaseUrl/SHA256SUMS" -OutFile $sha256SumsPath -Method "WebRequest" -AllowFallback
Invoke-CheckedDownload -Uri "$ubuntuBaseUrl/SHA256SUMS.gpg" -OutFile $sha256SumsGpgPath -Method "WebRequest" -AllowFallback

$gpg = Get-Command gpg -ErrorAction SilentlyContinue
if ($gpg) {
    Write-Host "Verifying SHA256SUMS signature with local GPG keyring..." -ForegroundColor Gray
    $gpgProcess = Start-Process -FilePath $gpg.Source -ArgumentList @("--verify", "`"$sha256SumsGpgPath`"", "`"$sha256SumsPath`"") -Wait -PassThru -NoNewWindow
    if ($gpgProcess.ExitCode -ne 0) {
        Write-Error "CRITICAL: Ubuntu SHA256SUMS signature verification failed. Import Canonical's signing key or inspect the checksum files before retrying."
        Exit
    }
}
else {
    Write-Warning "gpg was not found, so SHA256SUMS signature verification was skipped. The image checksum will still be verified against the downloaded SHA256SUMS file."
}

Write-Host "Verifying Ubuntu image SHA256 checksum..." -ForegroundColor Gray
try {
    Test-UbuntuImageChecksum -ImagePath $localImgPath -Sha256SumsPath $sha256SumsPath -FileName $imgFileName
}
catch {
    Write-Warning "Cached Ubuntu image failed checksum verification: $_"
    Write-Warning "Deleting the cached image and downloading it again."
    Remove-Item -Path $localImgPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$localImgPath.aria2", "$localImgPath.partial" -Force -ErrorAction SilentlyContinue
    Invoke-CheckedDownload -Uri $imgUrl -OutFile $localImgPath -AllowFallback
    Test-UbuntuImageChecksum -ImagePath $localImgPath -Sha256SumsPath $sha256SumsPath -FileName $imgFileName
}
Write-Host "Ubuntu image checksum verified." -ForegroundColor Green

# -------------------------------------------------------------
# 4. CONVERT DISK TO VHDX
# -------------------------------------------------------------
$vhdxFileName = "ubuntu-$UbuntuVersion-server-cloudimg-amd64.vhdx"
$osVhdxPath = Join-Path $WorkDir $vhdxFileName

Write-Host "`nConverting Ubuntu disk to Hyper-V VHDX format..." -ForegroundColor Cyan
if (-not (Test-Path $osVhdxPath)) {
    Write-Host "Converting $localImgPath to dynamic VHDX..." -ForegroundColor Gray
    $argList = @("convert", "-O", "vhdx", "-o", "subformat=dynamic", "`"$localImgPath`"", "`"$osVhdxPath`"")
    
    # Run the convert process
    $proc = Start-Process -FilePath $qemuImg -ArgumentList $argList -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        Write-Error "Disk conversion failed with exit code $($proc.ExitCode)."
        Exit
    }
    Write-Host "Disk conversion finished: $osVhdxPath" -ForegroundColor Green
}
else {
    Write-Host "OS VHDX file already exists at $osVhdxPath. Skipping conversion." -ForegroundColor Green
}

# -------------------------------------------------------------
# 5. CREATE CLOUD-INIT SEED ISO (CIDATA)
# -------------------------------------------------------------
$cidataIsoPath = Join-Path $WorkDir "cidata.iso"

Write-Host "`nGenerating cloud-init seed ISO (cidata)..." -ForegroundColor Cyan

try {
    Write-Host "Writing cloud-init metadata and user-data..." -ForegroundColor Gray

    if (-not $AllowPasswordAuth -and -not $SshPublicKey) {
        throw "Provide -SshPublicKey or explicitly enable password login with -AllowPasswordAuth."
    }

    if ($Password -and $PasswordPlainText) {
        throw "Use either -Password or -PasswordPlainText, not both."
    }

    $plainTextPassword = $null
    if ($AllowPasswordAuth) {
        if (-not $Password -and $PasswordPlainText) {
            $Password = ConvertTo-SecureString -String $PasswordPlainText -AsPlainText -Force
        }

        if (-not $Password -and $PasswordEnvironmentVariable) {
            $envPassword = [Environment]::GetEnvironmentVariable($PasswordEnvironmentVariable)
            if ($envPassword) {
                Write-Host "Using password from environment variable '$PasswordEnvironmentVariable'." -ForegroundColor Gray
                $Password = ConvertTo-SecureString -String $envPassword -AsPlainText -Force
            }
        }

        if (-not $Password -and [Environment]::UserInteractive -and -not (Test-NonInteractiveRun)) {
            $Password = Read-Host -Prompt "Enter password for '$Username'" -AsSecureString
        }

        if (-not $Password) {
            throw "Password authentication is enabled, but no password was supplied. Use -Password, -PasswordPlainText, or set the '$PasswordEnvironmentVariable' environment variable."
        }

        $plainTextPassword = Convert-SecureStringToPlainText -SecureString $Password
    }

$userDataContent = @"
#cloud-config
users:
  - name: $Username
    groups: sudo
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    lock_passwd: false
    
"@

    if ($SshPublicKey) {
        $userDataContent += "`n    ssh_authorized_keys:`n      - $SshPublicKey"
    }

    if ($AllowPasswordAuth) {
        $userDataContent += @"

chpasswd:
  list: |
    ${Username}:$plainTextPassword
  expire: false

ssh_pwauth: true
"@
        $plainTextPassword = $null
    }
    else {
        $userDataContent += @"

ssh_pwauth: false
"@
    }

    $userDataContent += @"

package_update: true
package_upgrade: true

packages:
  - linux-cloud-tools-virtual
  - linux-tools-virtual
  
runcmd:
  - systemctl enable hv-kvp-daemon || true
  - systemctl restart hv-kvp-daemon || true
  - systemctl enable hyperv-daemons.hv-kvp-daemon || true
  - systemctl restart hyperv-daemons.hv-kvp-daemon || true
  - reboot

"@

    $instanceId = "iid-" + [guid]::NewGuid().ToString().Substring(0, 8)
    $metaDataContent = @"
local-hostname: $VMName
instance-id: $instanceId
"@

    Write-Host "Creating cidata ISO at $cidataIsoPath..." -ForegroundColor Gray
    New-CidataIso -IsoPath $cidataIsoPath -UserData $userDataContent -MetaData $metaDataContent
    Write-Host "Cloud-init seed ISO created successfully." -ForegroundColor Green

}
catch {
    Write-Error "Error during seed ISO generation: $_"
    Exit
}

# -------------------------------------------------------------
# 6. PROVISION HYPER-V VM
# -------------------------------------------------------------
Write-Host "`nProvisioning Hyper-V Virtual Machine '$VMName'..." -ForegroundColor Cyan

# Create VM if it doesn't already exist
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Host "A VM named '$VMName' already exists. Skipping VM creation." -ForegroundColor Yellow
    Write-Host "Updating the VM's cloud-init seed ISO when possible..." -ForegroundColor Gray
    $existingVm = Get-VM -Name $VMName
    $existingVmFolder = $existingVm.ConfigurationLocation
    $existingSeedIsoDest = Join-Path $existingVmFolder "cidata.iso"
    $oldSeedDiskDest = Join-Path $existingVmFolder "cidata.vhdx"
    $oldSeedDrive = Get-VMHardDiskDrive -VMName $VMName | Where-Object { $_.Path -eq $oldSeedDiskDest } | Select-Object -First 1
    $existingDvdDrive = Get-VMDvdDrive -VMName $VMName | Select-Object -First 1

    if ($existingVm.State -ne 'Off') {
        Write-Warning "VM '$VMName' is $($existingVm.State). Stop it before updating the attached seed ISO."
    }
    else {
        if ($oldSeedDrive) {
            Remove-VMHardDiskDrive -VMName $VMName -ControllerType $oldSeedDrive.ControllerType -ControllerNumber $oldSeedDrive.ControllerNumber -ControllerLocation $oldSeedDrive.ControllerLocation -ErrorAction Stop
        }

        Copy-Item -Path $cidataIsoPath -Destination $existingSeedIsoDest -Force
        if ($existingDvdDrive) {
            Set-VMDvdDrive -VMName $VMName -ControllerNumber $existingDvdDrive.ControllerNumber -ControllerLocation $existingDvdDrive.ControllerLocation -Path $existingSeedIsoDest -ErrorAction Stop
        }
        else {
            Add-VMDvdDrive -VMName $VMName -Path $existingSeedIsoDest -ControllerNumber 0 -ControllerLocation 1 -ErrorAction Stop
        }

        Remove-Item -Path $oldSeedDiskDest -Force -ErrorAction SilentlyContinue
        Write-Host "Updated cloud-init seed ISO for existing VM." -ForegroundColor Green
    }
}
else {
    try {
        # Create VM without a default disk
        $vm = New-VM -Name $VMName `
            -MemoryStartupBytes $MemorySize `
            -Generation 2 `
            -Path $WorkDir `
            -SwitchName $SwitchName `
            -NoVHD `
            -ErrorAction Stop
        
        # Configure vCPUs
        Set-VMProcessor -VMName $VMName -Count $CpuCount -ErrorAction Stop
        Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $false -StartupBytes $MemorySize
        # Retrieve the directory where VM files are stored to copy disks there
        $vmFolder = (Get-VM -Name $VMName).ConfigurationLocation
        $vmOsDiskDest = Join-Path $vmFolder $vhdxFileName
        $vmSeedIsoDest = Join-Path $vmFolder "cidata.iso"
        
        Write-Host "Copying VM disk and seed ISO to the VM directory..." -ForegroundColor Gray
        Copy-Item -Path $osVhdxPath -Destination $vmOsDiskDest -Force
        Copy-Item -Path $cidataIsoPath -Destination $vmSeedIsoDest -Force
        
        # Attach OS disk (SCSI controller 0, Location 0)
        Write-Host "Attaching OS Disk..." -ForegroundColor Gray
        Add-VMHardDiskDrive -VMName $VMName -Path $vmOsDiskDest -ControllerNumber 0 -ControllerLocation 0 -ErrorAction Stop
        
        # Attach cloud-init seed ISO as a DVD drive (SCSI controller 0, Location 1)
        Write-Host "Attaching Cloud-Init Seed ISO..." -ForegroundColor Gray
        Add-VMDvdDrive -VMName $VMName -Path $vmSeedIsoDest -ControllerNumber 0 -ControllerLocation 1 -ErrorAction Stop
        
        # Disable Secure Boot (required for standard Ubuntu cloud images to boot smoothly on local Hyper-V)
        Write-Host "Disabling Secure Boot for compatibility..." -ForegroundColor Gray
        Set-VMFirmware -VMName $VMName -EnableSecureBoot Off -ErrorAction Stop
        
        Write-Host "VM '$VMName' created and configured successfully." -ForegroundColor Green
        
    }
    catch {
        Write-Error "Failed to configure the Hyper-V VM: $_"
        Exit
    }
}

# -------------------------------------------------------------
# 7. START VIRTUAL MACHINE
# -------------------------------------------------------------
if ($StartVM) {
    Write-Host "`nStarting VM '$VMName'..." -ForegroundColor Cyan
    try {
        Start-VM -Name $VMName -ErrorAction Stop
        Write-Host "VM '$VMName' started successfully!" -ForegroundColor Green
        Write-Host "`n==================================================" -ForegroundColor Cyan
        Write-Host "  Deployment complete!" -ForegroundColor Green
        Write-Host "  1. Open Hyper-V Manager to connect to the console." -ForegroundColor Yellow
        Write-Host "  2. Credential details:" -ForegroundColor Yellow
        Write-Host "     - Username: $Username" -ForegroundColor Yellow
        if ($AllowPasswordAuth) {
            Write-Host "     - Password authentication enabled for the supplied password." -ForegroundColor Yellow
        }
        else {
            Write-Host "     - SSH key authentication enabled; password login disabled." -ForegroundColor Yellow
        }
        Write-Host "  3. Wait 1-2 minutes for cloud-init to run on first boot." -ForegroundColor Yellow
        Write-Host "==================================================" -ForegroundColor Cyan
        $deadline = (Get-Date).AddMinutes(10)
        $vmIpAddresses = @()

        do {
            Write-Host "Waiting for VM IP address..."
            Start-Sleep -Seconds 15

            $vmIpAddresses = Get-VMNetworkAdapter -VMName $VMName |
            Select-Object -ExpandProperty IPAddresses |
            Where-Object {
                $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and
                $_ -notlike '169.254.*'
            }

        } while (-not $vmIpAddresses -and (Get-Date) -lt $deadline)

        if ($vmIpAddresses) {
            Write-Host "VM IP Addresses for SSH: $($vmIpAddresses -join ', ')" -ForegroundColor Green
        }
        else {
            Write-Warning "Timed out waiting for a Hyper-V reported IPv4 address. Check the VM console with 'ip addr'."
        }
    
    }
    catch {
        Write-Error "Failed to start VM '$VMName': $_"
    }
}
else {
    Write-Host "`nDeployment complete!" -ForegroundColor Green


}
