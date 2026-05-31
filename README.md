# Ubuntu Hyper-V Provisioning Script

Automate the creation of an Ubuntu Server virtual machine on Hyper-V using PowerShell, Ubuntu Cloud Images, QEMU, and cloud-init.

This script downloads an Ubuntu cloud image, verifies its checksum, converts it to Hyper-V VHDX format, creates a cloud-init seed ISO, provisions a Generation 2 Hyper-V VM, and optionally starts it automatically.

## Features

- Downloads official Ubuntu Server cloud images
- Verifies image integrity with SHA256 checksums
- Converts Ubuntu `.img` files to dynamic `.vhdx` format using `qemu-img`
- Creates a native cloud-init NoCloud seed ISO without external ISO tools
- Provisions a Generation 2 Hyper-V virtual machine
- Supports SSH key authentication
- Supports optional password authentication
- Supports non-interactive usage for CI/CD pipelines
- Automatically detects a Hyper-V virtual switch if one is not provided
- Can install QEMU and aria2 via `winget`
- Supports multiple download methods:
  - aria2
  - BITS
  - Invoke-WebRequest
  - Auto-selection

## Requirements

Run this script on Windows with:

- PowerShell
- Administrator privileges
- Hyper-V enabled
- Hyper-V PowerShell module installed
- QEMU / `qemu-img.exe`

Optional but recommended:

- `winget`
- `aria2c`
- `gpg`

## Script Name

Example script filename:

```powershell
Create-Ubuntu-HyperV.ps1
```

## Quick Start

Create an Ubuntu VM using SSH key authentication:

```powershell
.\Create-Ubuntu-HyperV.ps1 `
  -VMName "UbuntuServer" `
  -SshPublicKey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA..."
```

Create and start the VM with the default settings:

```powershell
.\Create-Ubuntu-HyperV.ps1 `
  -SshPublicKey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA..."
```

## Password Authentication

By default, password login is disabled unless you explicitly enable it.

To enable password authentication interactively:

```powershell
.\Create-Ubuntu-HyperV.ps1 `
  -VMName "UbuntuServer" `
  -AllowPasswordAuth `
  -Password (Read-Host -AsSecureString)
```

Using an environment variable:

```powershell
$env:UBUNTU_VM_PASSWORD = "YourStrongPassword"

.\Create-Ubuntu-HyperV.ps1 `
  -VMName "UbuntuServer" `
  -AllowPasswordAuth
```

Using plain text for non-interactive automation:

```powershell
.\Create-Ubuntu-HyperV.ps1 `
  -VMName "UbuntuServer" `
  -AllowPasswordAuth `
  -PasswordPlainText "YourStrongPassword" `
  -NonInteractive
```

> Prefer secure secrets or environment variables instead of hardcoding passwords.

## Install Dependencies Automatically

Install QEMU with `winget` if `qemu-img.exe` is missing:

```powershell
.\Create-Ubuntu-HyperV.ps1 `
  -SshPublicKey "ssh-ed25519 AAAAC3Nza..." `
  -InstallQemuWithWinget
```

Use aria2 for faster downloads and install it automatically if missing:

```powershell
.\Create-Ubuntu-HyperV.ps1 `
  -SshPublicKey "ssh-ed25519 AAAAC3Nza..." `
  -InstallAria2WithWinget `
  -DownloadMethod Aria2
```

## Parameters

| Parameter | Default | Description |
|---|---:|---|
| `VMName` | `Ubuntu26-VM` | Name of the Hyper-V virtual machine |
| `WorkDir` | `C:\HyperV-Ubuntu` | Directory used for downloads, converted disks, and temporary files |
| `UbuntuVersion` | `26.04` | Ubuntu cloud image version to download |
| `Username` | `ubuntu` | Default admin user created inside the VM |
| `Password` | `$null` | SecureString password used when password authentication is enabled |
| `PasswordPlainText` | `$null` | Plain text password for non-interactive runs |
| `PasswordEnvironmentVariable` | `UBUNTU_VM_PASSWORD` | Environment variable used to read the password |
| `NonInteractive` | disabled | Prevents interactive prompts |
| `SshPublicKey` | `$null` | SSH public key added to the user's `authorized_keys` |
| `MemorySize` | `2GB` | Startup memory assigned to the VM |
| `CpuCount` | `2` | Number of virtual CPUs |
| `SwitchName` | auto-detect | Hyper-V virtual switch name |
| `StartVM` | `$true` | Starts the VM after provisioning |
| `AllowPasswordAuth` | disabled | Enables password login through cloud-init |
| `InstallQemuWithWinget` | disabled | Installs QEMU using `winget` if missing |
| `InstallAria2WithWinget` | disabled | Installs aria2 using `winget` if missing |
| `DownloadMethod` | `Auto` | Download method: `Auto`, `Aria2`, `Bits`, or `WebRequest` |
| `Aria2Connections` | `8` | Number of parallel aria2 download connections |

## Examples

### Create a VM with SSH key authentication

```powershell
.\Create-Ubuntu-HyperV.ps1 `
  -VMName "MyUbuntuServer" `
  -SshPublicKey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA..."
```

### Create a VM with password authentication

```powershell
.\Create-Ubuntu-HyperV.ps1 `
  -VMName "MyUbuntuServer" `
  -AllowPasswordAuth `
  -Password (Read-Host -AsSecureString)
```

### Use a custom working directory

```powershell
.\Create-Ubuntu-HyperV.ps1 `
  -VMName "UbuntuLab" `
  -WorkDir "D:\HyperV\Ubuntu" `
  -SshPublicKey "ssh-ed25519 AAAAC3Nza..."
```

### Use a specific Hyper-V switch

```powershell
.\Create-Ubuntu-HyperV.ps1 `
  -VMName "UbuntuServer" `
  -SwitchName "Default Switch" `
  -SshPublicKey "ssh-ed25519 AAAAC3Nza..."
```

### Create the VM without starting it

```powershell
.\Create-Ubuntu-HyperV.ps1 `
  -VMName "UbuntuServer" `
  -SshPublicKey "ssh-ed25519 AAAAC3Nza..." `
  -StartVM:$false
```

### Use aria2 with more parallel connections

```powershell
.\Create-Ubuntu-HyperV.ps1 `
  -VMName "UbuntuServer" `
  -SshPublicKey "ssh-ed25519 AAAAC3Nza..." `
  -DownloadMethod Aria2 `
  -Aria2Connections 16
```

## CI/CD Pipeline Usage

The script is pipeline-friendly for non-interactive runs, but the pipeline runner must be a Windows machine that can actually create Hyper-V VMs:

- Use a self-hosted Windows runner or agent.
- Run the job with Administrator privileges.
- Enable Hyper-V and the Hyper-V PowerShell module on the runner.
- Use a machine with nested virtualization enabled if the runner itself is virtualized.
- Provide `qemu-img.exe` ahead of time or allow `winget` installation with `-InstallQemuWithWinget`.
- Provide credentials through a secret-backed environment variable or use SSH key authentication.

Hosted GitHub Actions or hosted Azure DevOps Windows runners are not suitable for creating Hyper-V VMs because they do not expose the required Hyper-V virtualization environment.

Example non-interactive command for a self-hosted runner:

```powershell
$env:UBUNTU_VM_PASSWORD = $env:PIPELINE_UBUNTU_VM_PASSWORD

.\Create-Ubuntu-HyperV.ps1 `
  -VMName "PipelineUbuntu" `
  -AllowPasswordAuth `
  -PasswordEnvironmentVariable "UBUNTU_VM_PASSWORD" `
  -NonInteractive `
  -StartVM:$false
```

## What the Script Does

The script performs the following steps:

1. Checks for Administrator privileges
2. Verifies that the Hyper-V PowerShell module is available
3. Detects or validates the Hyper-V virtual switch
4. Locates or installs QEMU
5. Downloads the selected Ubuntu cloud image
6. Downloads Ubuntu checksum files
7. Verifies the downloaded image checksum
8. Converts the Ubuntu cloud image to Hyper-V VHDX format
9. Generates a cloud-init `cidata.iso`
10. Creates or updates the Hyper-V VM
11. Attaches the OS disk and cloud-init ISO
12. Disables Secure Boot for compatibility
13. Starts the VM if enabled
14. Waits for Hyper-V to report the VM IPv4 address

## Authentication Behavior

The script requires at least one login method:

- SSH key authentication using `-SshPublicKey`
- Password authentication using `-AllowPasswordAuth`

If password authentication is not enabled, SSH password login is disabled inside the VM.

Recommended usage:

```powershell
.\Create-Ubuntu-HyperV.ps1 `
  -SshPublicKey "ssh-ed25519 AAAAC3Nza..."
```

## Connecting to the VM

After the VM starts, the script waits for Hyper-V to report an IPv4 address.

You can then connect using SSH:

```powershell
ssh ubuntu@<VM-IP-ADDRESS>
```

If you used a custom username:

```powershell
ssh <username>@<VM-IP-ADDRESS>
```

You can also open the VM console from Hyper-V Manager.

## Notes

- The VM is created as a Generation 2 Hyper-V VM.
- Secure Boot is disabled for compatibility with standard Ubuntu cloud images.
- The OS disk is created as a dynamic VHDX.
- The cloud-init seed ISO is attached as a DVD drive.
- The first boot may take a few minutes because cloud-init performs package updates and configuration.
- The VM may reboot once during the first boot process.

## Troubleshooting

### `qemu-img.exe` not found

Install QEMU manually or rerun the script with:

```powershell
-InstallQemuWithWinget
```

### No Hyper-V virtual switch found

Create a virtual switch in Hyper-V Manager or provide one explicitly:

```powershell
-SwitchName "Default Switch"
```

### VM does not get an IP address

Check the VM console and run:

```bash
ip addr
```

Also verify that the selected Hyper-V switch has network connectivity.

### Checksum verification fails

The script deletes the cached image and attempts to download it again.

If the issue continues, remove the working directory manually and rerun the script:

```powershell
Remove-Item "C:\HyperV-Ubuntu" -Recurse -Force
```

### GPG warning during checksum verification

If `gpg` is not installed, the script still verifies the image checksum against the downloaded `SHA256SUMS` file, but it cannot verify the signature of that checksum file.

For stronger verification, install GPG and import Canonical's signing key.

## Security Considerations

- Prefer SSH key authentication over password authentication.
- Avoid committing passwords or secrets to source control.
- Use environment variables or CI/CD secret stores for non-interactive runs.
- Review downloaded images and checksum verification behavior before using in production environments.

## Recommended Repository Name

```text
ubuntu-hyperv-cloudinit
```

## Recommended Script Filename

```text
Create-Ubuntu-HyperV.ps1
```

## License

MIT License
