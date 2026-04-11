param(
    [Parameter(Mandatory=$true)]
    [string]$adminUsername,
    
    [Parameter(Mandatory=$true)]
    [string]$adminPassword,
    
    [Parameter(Mandatory=$true)]
    [string]$domainName
)

$ErrorActionPreference = "Continue"
$logFile = "C:\WindowsAzure\Logs\DCSetup.log"

function Write-Log {
    param($Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $Message"
    Write-Host $logMessage
    Add-Content -Path $logFile -Value $logMessage
}

Write-Log "=========================================="
Write-Log "DC Setup Started"
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

# Install AD DS Role
Write-Log "Installing AD Domain Services role..."
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

# Compute netbiosName before the here-string so it interpolates correctly
$netbiosName = $domainName.Split('.')[0].ToUpper()
Write-Log "NetBIOS name: $netbiosName"

# Create post-reboot script for MDI sensor installation
Write-Log "Creating post-reboot MDI installation script..."
$postRebootScript = @"
`$logFile = "C:\WindowsAzure\Logs\DCSetup.log"
function Write-Log {
    param(`$Message)
    `$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    `$logMessage = "`$timestamp - `$Message"
    Write-Host `$logMessage
    Add-Content -Path `$logFile -Value `$logMessage
}

Start-Sleep -Seconds 120

Write-Log "Post-reboot configuration starting..."

# Wait for AD services
Write-Log "Waiting for Active Directory services..."
`$maxWait = 300
`$waited = 0
while ((`$waited -lt `$maxWait) -and -not (Get-Service NTDS -ErrorAction SilentlyContinue)) {
    Start-Sleep -Seconds 10
    `$waited += 10
}

if (Get-Service NTDS -ErrorAction SilentlyContinue) {
    Write-Log "Active Directory services started"
    
    # Import AD module
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
    
    # Create User01
    Write-Log "Creating domain user User01..."
    try {
        `$userPassword = ConvertTo-SecureString "$adminPassword" -AsPlainText -Force
        New-ADUser -Name "User01" ``
            -SamAccountName "User01" ``
            -UserPrincipalName "User01@$domainName" ``
            -AccountPassword `$userPassword ``
            -Enabled `$true ``
            -PasswordNeverExpires `$true ``
            -CannotChangePassword `$false ``
            -Description "Standard domain user" ``
            -ErrorAction Stop
        Write-Log "User01 created successfully"
    } catch {
        Write-Log "ERROR creating User01: `$_"
    }
    
    # Disable account lockout
    Write-Log "Disabling account lockout policy..."
    try {
        Set-ADDefaultDomainPasswordPolicy -Identity "$domainName" ``
            -LockoutThreshold 0 ``
            -ErrorAction SilentlyContinue
        Write-Log "Account lockout disabled"
    } catch {
        Write-Log "WARNING: Could not disable lockout: `$_"
    }
    
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
    
    # Configure auto-login for domain account AFTER DC promotion
    Write-Log "Configuring auto-login for domain account..."
    try {
        `$AutoLogonRegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        `$netbiosName = "$netbiosName"
        Set-ItemProperty -Path `$AutoLogonRegPath -Name "AutoAdminLogon" -Value "1" -Type String -Force
        Set-ItemProperty -Path `$AutoLogonRegPath -Name "DefaultUserName" -Value "`$netbiosName\$adminUsername" -Type String -Force
        Set-ItemProperty -Path `$AutoLogonRegPath -Name "DefaultPassword" -Value "$adminPassword" -Type String -Force
        Set-ItemProperty -Path `$AutoLogonRegPath -Name "DefaultDomainName" -Value `$netbiosName -Type String -Force
        Write-Log "Auto-login configured for `$netbiosName\$adminUsername"
    } catch {
        Write-Log "WARNING: Auto-login configuration failed: `$_"
    }
    
    # Prepare MDI installation directory (actual installation in Phase 05)
    Write-Log "Preparing MDI sensor directory..."
    try {
        `$mdiPath = "C:\Temp\MDI"
        New-Item -Path `$mdiPath -ItemType Directory -Force | Out-Null
        Write-Log "MDI directory created at `$mdiPath"
        Write-Log "MDI sensor will be installed via Phase 05 script after DC is fully operational"
    } catch {
        Write-Log "WARNING: MDI directory creation failed: `$_"
    }
} else {
    Write-Log "ERROR: AD services did not start in time"
}

Write-Log "=========================================="
Write-Log "DC Setup Completed"
Write-Log "Domain: $domainName"
Write-Log "Auto-login enabled for: $netbiosName\$adminUsername"
Write-Log "MDI sensor: Ready for Phase 05 deployment"
Write-Log "=========================================="

# Clean up scheduled task
Unregister-ScheduledTask -TaskName "DCPostReboot" -Confirm:`$false -ErrorAction SilentlyContinue
"@

$postRebootScript | Out-File -FilePath "C:\PostRebootSetup.ps1" -Encoding UTF8 -Force

# Create scheduled task for post-reboot
Write-Log "Creating post-reboot scheduled task..."
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\PostRebootSetup.ps1"
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName "DCPostReboot" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force

# Promote to Domain Controller
Write-Log "Promoting to Domain Controller..."
$secSafeModePassword = ConvertTo-SecureString $adminPassword -AsPlainText -Force

Install-ADDSForest `
    -DomainName $domainName `
    -DomainNetbiosName ($domainName.Split('.')[0].ToUpper()) `
    -SafeModeAdministratorPassword $secSafeModePassword `
    -InstallDns:$true `
    -CreateDnsDelegation:$false `
    -DatabasePath "C:\Windows\NTDS" `
    -LogPath "C:\Windows\NTDS" `
    -SysvolPath "C:\Windows\SYSVOL" `
    -NoRebootOnCompletion:$true `
    -Force:$true

Write-Log "DC promotion complete - reboot needed to finalize"
