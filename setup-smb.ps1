param(
    [Parameter(Mandatory=$true)]
    [string]$adminUsername,
    
    [Parameter(Mandatory=$true)]
    [string]$adminPassword,
    
    [Parameter(Mandatory=$true)]
    [string]$domainName
)

$ErrorActionPreference = "Continue"
$logFile = "C:\WindowsAzure\Logs\SMBSetup.log"

function Write-Log {
    param($Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $Message"
    Write-Host $logMessage
    Add-Content -Path $logFile -Value $logMessage
}

Write-Log "=========================================="
Write-Log "File Server Setup Started"
Write-Log "Domain: $domainName"
Write-Log "=========================================="

# Disable IE Enhanced Security
Write-Log "Disabling IE Enhanced Security Configuration..."
$AdminKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
$UserKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
Set-ItemProperty -Path $AdminKey -Name "IsInstalled" -Value 0 -Force
Set-ItemProperty -Path $UserKey -Name "IsInstalled" -Value 0 -Force

# Disable screen lock timeout
Write-Log "Disabling screen lock and power settings..."
powercfg /change monitor-timeout-ac 0
powercfg /change monitor-timeout-dc 0
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "InactivityTimeoutSecs" -Value 0 -Type DWord -Force
# Disable lock screen entirely (Windows 11)
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows" -Name "Personalization" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoLockScreen" -Value 1 -Type DWord -Force

# Wait for DC to be ready
Write-Log "Waiting for domain controller to be ready..."
$maxWait = 600
$waited = 0
$dcReady = $false

while (($waited -lt $maxWait) -and -not $dcReady) {
    try {
        $dcTest = Test-Connection -ComputerName $domainName -Count 1 -Quiet
        if ($dcTest) {
            $dcReady = $true
            Write-Log "Domain controller is responding"
        }
    } catch {
        Write-Log "Waiting for DC... ($waited seconds)"
    }
    
    if (-not $dcReady) {
        Start-Sleep -Seconds 30
        $waited += 30
    }
}

if (-not $dcReady) {
    Write-Log "WARNING: Domain controller did not respond in time, attempting join anyway..."
}

# Join domain
Write-Log "Joining domain $domainName..."
$secPassword = ConvertTo-SecureString $adminPassword -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential("$domainName\$adminUsername", $secPassword)

try {
    Add-Computer -DomainName $domainName -Credential $credential -Force -ErrorAction Stop
    Write-Log "Successfully joined domain"
    
    # Configure auto-login for domain account
    Write-Log "Configuring auto-login..."
    $AutoLogonRegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $netbiosName = $domainName.Split('.')[0].ToUpper()
    Set-ItemProperty -Path $AutoLogonRegPath -Name "AutoAdminLogon" -Value "1" -Type String -Force
    Set-ItemProperty -Path $AutoLogonRegPath -Name "DefaultUserName" -Value "$netbiosName\$adminUsername" -Type String -Force
    Set-ItemProperty -Path $AutoLogonRegPath -Name "DefaultPassword" -Value $adminPassword -Type String -Force
    Set-ItemProperty -Path $AutoLogonRegPath -Name "DefaultDomainName" -Value $netbiosName -Type String -Force
    
    # Create post-reboot script for share creation
    Write-Log "Creating post-reboot share creation script..."
    $postRebootScript = @"
`$logFile = "C:\WindowsAzure\Logs\SMBSetup.log"
function Write-Log {
    param(`$Message)
    `$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    `$logMessage = "`$timestamp - `$Message"
    Write-Host `$logMessage
    Add-Content -Path `$logFile -Value `$logMessage
}

Start-Sleep -Seconds 60

Write-Log "Post-reboot configuration starting..."

# Install File Server role
Write-Log "Installing File Server role..."
Install-WindowsFeature -Name FS-FileServer -IncludeManagementTools

# Create share folder
Write-Log "Creating share folder..."
`$sharePath = "C:\Share"
New-Item -Path `$sharePath -ItemType Directory -Force

# Create dummy files
Write-Log "Creating dummy files in share..."
"This is a dummy file for testing" | Out-File "`$sharePath\readme.txt"
New-Item -Path "`$sharePath\Data" -ItemType Directory -Force
"Confidential data" | Out-File "`$sharePath\Data\confidential.txt"

# Create SMB share
Write-Log "Creating SMB share..."
New-SmbShare -Name "Share" ``
    -Path `$sharePath ``
    -FullAccess "Domain Users" ``
    -ChangeAccess "Domain Users" ``
    -Description "Shared folder for domain users"

# Set NTFS permissions
Write-Log "Setting NTFS permissions..."
`$acl = Get-Acl `$sharePath
`$domainUsersRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Domain Users", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
`$acl.SetAccessRule(`$domainUsersRule)
Set-Acl `$sharePath `$acl

Write-Log "Share created: \\SMB01\Share"

# Defender is managed by MDE extension - do not disable
Write-Log "Defender managed by MDE extension"

# Disable SmartScreen
Write-Log "Disabling SmartScreen..."
try {
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" -Name "SmartScreenEnabled" -Value "Off" -Force -ErrorAction SilentlyContinue
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableSmartScreen" -Value 0 -Force -ErrorAction SilentlyContinue
    Write-Log "SmartScreen disabled"
} catch {
    Write-Log "WARNING: SmartScreen disable had issues: `$_"
}

# Disable Firewall
Write-Log "Disabling Windows Firewall..."
try {
    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
    Write-Log "Firewall disabled"
} catch {
    Write-Log "WARNING: Firewall disable failed: `$_"
}

Write-Log "=========================================="
Write-Log "File Server Setup Completed"
Write-Log "Share: \\SMB01\Share"
Write-Log "Permissions: Domain Users (Modify)"
Write-Log "=========================================="

# Clean up scheduled task
Unregister-ScheduledTask -TaskName "SMBPostReboot" -Confirm:`$false -ErrorAction SilentlyContinue
"@

    $postRebootScript | Out-File -FilePath "C:\PostRebootSetup.ps1" -Encoding UTF8 -Force
    
    # Create scheduled task for post-reboot
    Write-Log "Creating post-reboot scheduled task..."
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\PostRebootSetup.ps1"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName "SMBPostReboot" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
    
    Write-Log "Domain join complete - external restart will finalize"
    
} catch {
    Write-Log "ERROR: Failed to join domain: $_"
    Write-Log "This may be due to DC not being fully ready. Manual join may be required."
    exit 1
}
