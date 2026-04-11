# UniSecOps Lab Bootstrap - Phase 1 to 6 + Phase 8 (MDO) + Phase 11-13 (VMs, Kali, Attacks)
# NO SPN VERSION - SPN params removed, MI role assignment done manually
# Phases 1-6: Prerequisites, Auth, SecAdmin, MDC, Sentinel
# Phase 8: MDO pre-config
# Phase 11: Deploy AD VMs (DC + SMB) with MDE onboarding
# Phase 12: Deploy Kali Attack VM
# Phase 13: Execute Attack Simulations
# Phases 7, 9, 10: Playwright (done manually)

param(
    [Parameter(Mandatory=$true)]
    [string]$AzureUserName,

    [Parameter(Mandatory=$true)]
    [string]$AzurePassword,

    [Parameter(Mandatory=$false)]
    [string]$AzureTAP = "",

    [Parameter(Mandatory=$false)]
    [string]$AzureTAPExpiry = "",

    [Parameter(Mandatory=$true)]
    [string]$AzureTenantID,

    [Parameter(Mandatory=$true)]
    [string]$AzureSubscriptionID,

    [Parameter(Mandatory=$true)]
    [string]$ODLID,

    [Parameter(Mandatory=$true)]
    [string]$DeploymentID,

    [Parameter(Mandatory=$true)]
    [string]$adminPassword,

    [Parameter(Mandatory=$false)]
    [string]$vmAdminUsername = "LabAdmin",

    [Parameter(Mandatory=$false)]
    [string]$trainerUserName = "trainer",

    [Parameter(Mandatory=$false)]
    [string]$trainerUserPassword = "",

    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "secops",

    [Parameter(Mandatory=$false)]
    [string]$WorkspaceName = "",

    [Parameter(Mandatory=$false)]
    [string]$Location = "eastus"
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"


Start-Transcript -Path C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension.txt -Append
[Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls
[Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls" 

         
Function CreateCredFile($AzureUserName, $AzurePassword, $AzureTenantID, $AzureSubscriptionID, $DeploymentID)
{
    $WebClient = New-Object System.Net.WebClient
    $WebClient.DownloadFile("https://experienceazure.blob.core.windows.net/templates/cloudlabs-common/AzureCreds.txt","C:\LabFiles\AzureCreds.txt")
    $WebClient.DownloadFile("https://experienceazure.blob.core.windows.net/templates/cloudlabs-common/AzureCreds.ps1","C:\LabFiles\AzureCreds.ps1")
    
    New-Item -ItemType directory -Path C:\LabFiles -force

    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -Replace "AzureUserNameValue", "$AzureUserName"} | Set-Content -Path "C:\LabFiles\AzureCreds.txt"
    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -Replace "AzurePasswordValue", "$AzurePassword"} | Set-Content -Path "C:\LabFiles\AzureCreds.txt"
    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -Replace "AzureTenantIDValue", "$AzureTenantID"} | Set-Content -Path "C:\LabFiles\AzureCreds.txt"
    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -Replace "AzureSubscriptionIDValue", "$AzureSubscriptionID"} | Set-Content -Path "C:\LabFiles\AzureCreds.txt"
    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -Replace "DeploymentIDValue", "$DeploymentID"} | Set-Content -Path "C:\LabFiles\AzureCreds.txt"
    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -replace "clientIdValue", "$clientId" } | Set-Content -Path "C:\LabFiles\AzureCreds.txt"
    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -replace "clientSecretValue", "$clientSecret" } | Set-Content -Path "C:\LabFiles\AzureCreds.txt"

    (Get-Content -Path "C:\LabFiles\AzureCreds.ps1") | ForEach-Object {$_ -Replace "AzureUserNameValue", "$AzureUserName"} | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"
    (Get-Content -Path "C:\LabFiles\AzureCreds.ps1") | ForEach-Object {$_ -Replace "AzurePasswordValue", "$AzurePassword"} | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"
    (Get-Content -Path "C:\LabFiles\AzureCreds.ps1") | ForEach-Object {$_ -Replace "AzureTenantIDValue", "$AzureTenantID"} | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"
    (Get-Content -Path "C:\LabFiles\AzureCreds.ps1") | ForEach-Object {$_ -Replace "AzureSubscriptionIDValue", "$AzureSubscriptionID"} | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"
    (Get-Content -Path "C:\LabFiles\AzureCreds.ps1") | ForEach-Object {$_ -Replace "DeploymentIDValue", "$DeploymentID"} | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"
	(Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -replace "clientIdValue", "$clientId" } | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"
    (Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -replace "clientSecretValue", "$clientSecret" } | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"

    Copy-Item "C:\LabFiles\AzureCreds.txt" -Destination "C:\Users\Public\Desktop"
}

CreateCredFile $AzureUserName $AzurePassword $AzureTenantID $AzureSubscriptionID $DeploymentID $clientId $clientSecret


Function Enable-CloudLabsEmbeddedShadow($vmAdminUsername, $trainerUserName, $trainerUserPassword)
{
Write-Host "Enabling CloudLabsEmbeddedShadow"
#Created Trainer Account and Add to Administrators Group
$trainerUserPass = $trainerUserPassword | ConvertTo-SecureString -AsPlainText -Force

New-LocalUser -Name $trainerUserName -Password $trainerUserPass -FullName "$trainerUserName" -Description "CloudLabs EmbeddedShadow User" -PasswordNeverExpires
Add-LocalGroupMember -Group "Administrators" -Member "$trainerUserName"

#Add Windows regitary to enable Shadow
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v Shadow /t REG_DWORD /d 2 -f

#Download Shadow.ps1 and Shadow.xml file in VM
$drivepath="C:\Users\Public\Documents"
$WebClient = New-Object System.Net.WebClient
$WebClient.DownloadFile("https://experienceazure.blob.core.windows.net/templates/cloudlabs-common/Shadow.ps1","$drivepath\Shadow.ps1")
$WebClient.DownloadFile("https://experienceazure.blob.core.windows.net/templates/cloudlabs-common/shadow.xml","$drivepath\shadow.xml")
$WebClient.DownloadFile("https://experienceazure.blob.core.windows.net/templates/cloudlabs-common/ShadowSession.zip","C:\Packages\ShadowSession.zip")
$WebClient.DownloadFile("https://experienceazure.blob.core.windows.net/templates/cloudlabs-common/executetaskscheduler.ps1","$drivepath\executetaskscheduler.ps1")
$WebClient.DownloadFile("https://experienceazure.blob.core.windows.net/templates/cloudlabs-common/shadowshortcut.ps1","$drivepath\shadowshortcut.ps1")

# Unzip Shadow User Session Shortcut to Trainer Desktop
#$trainerloginuser= "$trainerUserName" + "." + "$($env:ComputerName)"
#Expand-Archive -LiteralPath 'C:\Packages\ShadowSession.zip' -DestinationPath "C:\Users\$trainerloginuser\Desktop" -Force
#Expand-Archive -LiteralPath 'C:\Packages\ShadowSession.zip' -DestinationPath "C:\Users\$trainerUserName\Desktop" -Force

#Replace vmAdminUsernameValue with VM Admin UserName in script content 
(Get-Content -Path "$drivepath\Shadow.ps1") | ForEach-Object {$_ -Replace "vmAdminUsernameValue", "$vmAdminUsername"} | Set-Content -Path "$drivepath\Shadow.ps1"
(Get-Content -Path "$drivepath\shadow.xml") | ForEach-Object {$_ -Replace "vmAdminUsernameValue", "$trainerUserName"} | Set-Content -Path "$drivepath\shadow.xml"
(Get-Content -Path "$drivepath\shadow.xml") | ForEach-Object {$_ -Replace "ComputerNameValue", "$($env:ComputerName)"} | Set-Content -Path "$drivepath\shadow.xml"
(Get-Content -Path "$drivepath\shadowshortcut.ps1") | ForEach-Object {$_ -Replace "vmAdminUsernameValue", "$trainerUserName"} | Set-Content -Path "$drivepath\shadowshortcut.ps1"
sleep 2

# Scheduled Task to Run Shadow.ps1 AtLogOn
schtasks.exe /Create /XML $drivepath\shadow.xml /tn Shadowtask

$Trigger= New-ScheduledTaskTrigger -AtLogOn
$User= "$($env:ComputerName)\$trainerUserName" 
$Action= New-ScheduledTaskAction -Execute "C:\Windows\System32\WindowsPowerShell\v1.0\Powershell.exe" -Argument "-executionPolicy Unrestricted -File $drivepath\shadowshortcut.ps1 -WindowStyle Hidden"
Register-ScheduledTask -TaskName "shadowshortcut" -Trigger $Trigger -User $User -Action $Action -RunLevel Highest -Force
}

Enable-CloudLabsEmbeddedShadow($vmAdminUsername, $trainerUserName, $trainerUserPassword)



# ============================================
# CONFIGURATION
# ============================================
$script:MaxRetries = 3
$script:RetryDelaySeconds = 10
$script:MaxRetryDelaySeconds = 60

$LabFilesPath = "C:\LabFiles"
$ScriptsPath = "$LabFilesPath\deploy"
$LogPath = "$LabFilesPath\logs"
$ParametersFile = "$ScriptsPath\parameters.json"
$StatusFile = "$LabFilesPath\deployment-status.json"
$TranscriptFile = "$LogPath\bootstrap-phase1-6-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

$BlobBaseUrl = "https://srikanth98493.blob.core.windows.net/unisecops"

# Create directory structure
New-Item -ItemType Directory -Path $LabFilesPath -Force | Out-Null
New-Item -ItemType Directory -Path $ScriptsPath -Force | Out-Null
New-Item -ItemType Directory -Path $LogPath -Force | Out-Null

Start-Transcript -Path $TranscriptFile -Append

Write-Host "============================================"
Write-Host "UniSecOps Bootstrap - Phase 1 to 6"
Write-Host "============================================"
Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Deployment ID: $DeploymentID"
Write-Host "Tenant ID: $AzureTenantID"
Write-Host "Subscription ID: $AzureSubscriptionID"
Write-Host "User: $AzureUserName"

# ============================================
# STATUS TRACKING
# ============================================
$deploymentStatus = @{
    startTime = (Get-Date).ToString("o")
    deploymentId = $DeploymentID
    phases = @{}
    currentPhase = ""
    completed = $false
    error = $null
}

$DetailedLogFile = "$ScriptsPath\bootstrap.log"
$CurrentPhaseFile = "$ScriptsPath\current-phase.txt"

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Add-Content -Path $DetailedLogFile -Value $logMessage -Force
    Write-Host $logMessage
}

function Update-Status {
    param(
        [string]$Phase,
        [string]$Status,
        [string]$Message = ""
    )
    $deploymentStatus.currentPhase = $Phase
    $deploymentStatus.phases[$Phase] = @{
        status = $Status
        message = $Message
        timestamp = (Get-Date).ToString("o")
    }
    $deploymentStatus | ConvertTo-Json -Depth 5 | Set-Content $StatusFile -Force
    "$Phase : $Status" | Set-Content $CurrentPhaseFile -Force
    Write-Log "[$Phase] $Status $(if($Message){': ' + $Message})" -Level "PHASE"
}

function Save-PhaseState {
    param(
        [string]$Phase,
        [string]$Status,
        [int]$Attempts = 1,
        [string]$Error = ""
    )
    $stateFile = "$ScriptsPath\deployment-state.json"
    if (Test-Path $stateFile) {
        try {
            $stateJson = Get-Content $stateFile -Raw | ConvertFrom-Json
            $state = @{
                deploymentId = $stateJson.deploymentId
                startTime = $stateJson.startTime
                phases = @{}
            }
            if ($stateJson.phases) {
                $stateJson.phases.PSObject.Properties | ForEach-Object {
                    $state.phases[$_.Name] = @{
                        status = $_.Value.status
                        attempts = $_.Value.attempts
                        lastUpdate = $_.Value.lastUpdate
                        error = $_.Value.error
                    }
                }
            }
        } catch {
            $state = @{ deploymentId = $DeploymentID; startTime = (Get-Date).ToString("o"); phases = @{} }
        }
    } else {
        $state = @{ deploymentId = $DeploymentID; startTime = (Get-Date).ToString("o"); phases = @{} }
    }
    $state.phases[$Phase] = @{
        status = $Status
        attempts = $Attempts
        lastUpdate = (Get-Date).ToString("o")
        error = $Error
    }
    $state.lastPhase = $Phase
    $state.lastUpdate = (Get-Date).ToString("o")
    $state | ConvertTo-Json -Depth 10 | Set-Content $stateFile -Force
}

function Invoke-Phase {
    param(
        [string]$PhaseName,
        [string]$ScriptPath,
        [hashtable]$Parameters = @{},
        [int]$MaxRetries = 2,
        [switch]$Required,
        [switch]$StopOnFailure
    )

    Write-Host ""
    Write-Host "============================================"
    Write-Host "Phase: $PhaseName"
    Write-Host "============================================"

    # Resume: skip if already completed
    $stateFile = "$ScriptsPath\deployment-state.json"
    if (Test-Path $stateFile) {
        try {
            $state = Get-Content $stateFile -Raw | ConvertFrom-Json
            if ($state.phases.$PhaseName.status -eq "completed") {
                Write-Host "Phase '$PhaseName' already completed, skipping"
                Update-Status -Phase $PhaseName -Status "skipped" -Message "Already completed"
                return $true
            }
        } catch { }
    }

    Update-Status -Phase $PhaseName -Status "running"

    if (-not (Test-Path $ScriptPath)) {
        $msg = "Script not found: $ScriptPath"
        Update-Status -Phase $PhaseName -Status "failed" -Message $msg
        if ($StopOnFailure) { throw "CRITICAL: $msg" }
        return $false
    }

    $attempt = 0
    $lastError = $null
    $phaseStart = Get-Date

    while ($attempt -lt $MaxRetries) {
        $attempt++
        try {
            if ($attempt -gt 1) {
                Write-Host "Phase '$PhaseName' retry attempt $attempt of $MaxRetries"
                Start-Sleep -Seconds ($script:RetryDelaySeconds * $attempt)
            }
            $result = & $ScriptPath @Parameters 2>&1
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
                throw "Script exited with code $LASTEXITCODE"
            }
            $duration = (Get-Date) - $phaseStart
            Update-Status -Phase $PhaseName -Status "completed" -Message "Duration: $($duration.TotalSeconds.ToString('F0'))s, Attempts: $attempt"
            Save-PhaseState -Phase $PhaseName -Status "completed" -Attempts $attempt
            return $true
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Host "Phase '$PhaseName' attempt $attempt failed: $lastError"
        }
    }

    $duration = (Get-Date) - $phaseStart
    Update-Status -Phase $PhaseName -Status "failed" -Message "$lastError (after $attempt attempts)"
    Save-PhaseState -Phase $PhaseName -Status "failed" -Attempts $attempt -Error $lastError
    Write-Host "ERROR in $PhaseName after $attempt attempts: $lastError"

    if ($StopOnFailure) {
        throw "CRITICAL: Required phase '$PhaseName' failed: $lastError"
    }
    return $false
}

function Download-Script {
    param(
        [string]$RelativePath,
        [string]$LocalPath
    )
    $url = "$BlobBaseUrl/$RelativePath"
    $localDir = Split-Path $LocalPath -Parent
    if (-not (Test-Path $localDir)) {
        New-Item -ItemType Directory -Path $localDir -Force | Out-Null
    }
    $attempt = 0
    $maxAttempts = $script:MaxRetries
    $delay = 5
    while ($attempt -lt $maxAttempts) {
        $attempt++
        try {
            Invoke-WebRequest -Uri $url -OutFile $LocalPath -UseBasicParsing -ErrorAction Stop -TimeoutSec 30
            Write-Host "Downloaded: $RelativePath"
            return $true
        }
        catch {
            $errMsg = $_.Exception.Message
            if ($attempt -ge $maxAttempts) {
                Write-Host "FAILED to download after $attempt attempts: $RelativePath - $errMsg"
                return $false
            }
            $jitter = Get-Random -Minimum 0 -Maximum 3
            $actualDelay = $delay + $jitter
            Write-Host "Download attempt $attempt failed for $RelativePath, retrying in $actualDelay seconds..."
            Start-Sleep -Seconds $actualDelay
            $delay = [math]::Min($delay * 2, 30)
        }
    }
    return $false
}

# ============================================
# PHASE 0: Create Parameters File
# ============================================
Write-Host ""
Write-Host "============================================"
Write-Host "Phase 0: Initialize Parameters"
Write-Host "============================================"

Update-Status -Phase "00-init" -Status "running"

# Sanitize placeholders
$sanitizedTAP = if ($AzureTAP -like 'GET-*') { "" } else { $AzureTAP }
$sanitizedTAPExpiry = if ($AzureTAPExpiry -like 'GET-*') { "" } else { $AzureTAPExpiry }

Write-Host "TAP provided: $(if ($sanitizedTAP) { 'YES' } else { 'NO' })"

$effectiveRGName = if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) { "secops" } else { $ResourceGroupName }
$effectiveWorkspaceName = if ([string]::IsNullOrWhiteSpace($WorkspaceName)) { "UniSecOps-sentinel-$DeploymentID" } else { $WorkspaceName }
$effectiveLocation = if ([string]::IsNullOrWhiteSpace($Location)) { "eastus" } else { $Location }

Write-Host "Using ResourceGroup: $effectiveRGName"
Write-Host "Using Workspace: $effectiveWorkspaceName"
Write-Host "Using Location: $effectiveLocation"

$params = @{
    odlusername = $AzureUserName
    odluserpass = $AzurePassword
    tenantid = $AzureTenantID
    subid = $AzureSubscriptionID
    deploymentid = $DeploymentID
    odlid = $ODLID
    oduserid = ""
    gausername = $AzureUserName
    gauserpass = $AzurePassword
    tap = $sanitizedTAP
    tapexpiry = $sanitizedTAPExpiry
    secadminenabled = ""
    secadmindate = ""
    mdcenabled = ""
    mdcdate = ""
    resourcegroupname = $effectiveRGName
    workspacename = $effectiveWorkspaceName
    workspaceid = ""
    workspacekey = ""
    deploymentregion = $effectiveLocation
    sentineldeployed = ""
    sentineldate = ""
    UEBAEnabled = ""
    uebadate = ""
    mdideployed = ""
    mdidate = ""
    vmsrgname = "UniSecOps-VMs-$DeploymentID"
    dcip = "10.0.1.4"
    smbip = "10.0.1.5"
    kaliip = "10.0.1.10"
    vnetname = "UniSecOps-VNet-$DeploymentID"
    domainname = "corp.contoso.com"
    vmadminpass = $adminPassword
    domainadminpass = $AzurePassword
}

$params | ConvertTo-Json -Depth 5 | Set-Content $ParametersFile -Force
Write-Host "Created parameters.json at $ParametersFile"
Update-Status -Phase "00-init" -Status "completed"

# ============================================
# PHASE 0.5: Download Scripts (Phase 1-6 only)
# ============================================
Write-Host ""
Write-Host "============================================"
Write-Host "Phase 0.5: Download Deployment Scripts"
Write-Host "============================================"

Update-Status -Phase "00-download" -Status "running"

$scriptsToDownload = @(
    # Phase 4 (Security Admin)
    @{ Remote = "02a-secadmin.ps1"; Local = "$ScriptsPath\02a-secadmin\02a-secadmin.ps1" }
    # Phase 5 (MDC)
    @{ Remote = "03mdc.ps1"; Local = "$ScriptsPath\03mdc\03mdc.ps1" }
    # Phase 6 (Sentinel)
    @{ Remote = "04b-mdi.ps1"; Local = "$ScriptsPath\04sentinel\04b-mdi.ps1" }
    @{ Remote = "04c-entraid.ps1"; Local = "$ScriptsPath\04sentinel\04c-entraid.ps1" }
    @{ Remote = "04d-security-events.ps1"; Local = "$ScriptsPath\04sentinel\04d-security-events.ps1" }
    @{ Remote = "04e-additional-solutions.ps1"; Local = "$ScriptsPath\04sentinel\04e-additional-solutions.ps1" }
    @{ Remote = "04f-defender-solutions.ps1"; Local = "$ScriptsPath\04sentinel\04f-defender-solutions.ps1" }
    @{ Remote = "05-enable-data-connectors.ps1"; Local = "$ScriptsPath\04sentinel\05-enable-data-connectors.ps1" }
    @{ Remote = "sentinel-template.json"; Local = "$ScriptsPath\04sentinel\sentinel-template.json" }
    # Phase 8 (MDO)
    @{ Remote = "01a-mdopre.ps1"; Local = "$ScriptsPath\05b-unprotect\01mdo\01a-mdopre.ps1" }
    # Phase 11 (VMs)
    @{ Remote = "phase11-06vms.ps1"; Local = "$ScriptsPath\06vms\06vms.ps1" }
    @{ Remote = "dc.json"; Local = "$ScriptsPath\06vms\nestedtemplates\dc.json" }
    @{ Remote = "smb.json"; Local = "$ScriptsPath\06vms\nestedtemplates\smb.json" }
    @{ Remote = "setup-dc.ps1"; Local = "$ScriptsPath\06vms\scripts\setup-dc.ps1" }
    @{ Remote = "setup-smb.ps1"; Local = "$ScriptsPath\06vms\scripts\setup-smb.ps1" }
    # Phase 12 (Kali)
    @{ Remote = "07kali.ps1"; Local = "$ScriptsPath\07kali\07kali.ps1" }
    # Phase 13 (Attacks)
    @{ Remote = "launch-attacks.ps1"; Local = "$ScriptsPath\08attacks\launch-attacks.ps1" }
    @{ Remote = "run-attacks-smb.ps1"; Local = "$ScriptsPath\08attacks\run-attacks-smb.ps1" }
	# Lab 03 - Security Copilot Agent YAML
    @{ Remote = "soc-threat-hunter.yaml"; Local = "$LabFilesPath\soc-threat-hunter.yaml" }
)

$downloadedCount = 0
$failedCount = 0
foreach ($script in $scriptsToDownload) {
    if (Download-Script -RelativePath $script.Remote -LocalPath $script.Local) {
        $downloadedCount++
    } else {
        $failedCount++
    }
}

Write-Host "Downloaded: $downloadedCount scripts, Failed: $failedCount"
if ($failedCount -gt 0) {
    Write-Host "WARNING: Some scripts failed to download"
}
Update-Status -Phase "00-download" -Status "completed" -Message "Downloaded $downloadedCount scripts"

# ============================================
# PHASE 1: Install Prerequisites
# ============================================
Write-Host ""
Write-Host "============================================"
Write-Host "Phase 1: Install Prerequisites"
Write-Host "============================================"

Update-Status -Phase "01-prereqs" -Status "running"

# Install Azure CLI if not present
$azPath = Get-Command az -ErrorAction SilentlyContinue
if (-not $azPath) {
    Write-Host "Installing Azure CLI..."
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi
    Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'
    Remove-Item .\AzureCLI.msi -Force
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    Write-Host "Azure CLI installed"
} else {
    Write-Host "Azure CLI already installed"
}

# Install VS Code if not present
$vscodePath = Get-Command code -ErrorAction SilentlyContinue
if (-not $vscodePath) {
    Write-Host "Installing VS Code..."
    $vscodeInstaller = "$env:TEMP\VSCodeSetup.exe"
    Invoke-WebRequest -Uri "https://update.code.visualstudio.com/latest/win32-x64/stable" -OutFile $vscodeInstaller -UseBasicParsing
    Start-Process -FilePath $vscodeInstaller -Wait -ArgumentList '/verysilent /suppressmsgboxes /mergetasks=!runcode,desktopicon,addcontextmenufiles,addcontextmenufolders,addtopath'
    Remove-Item $vscodeInstaller -Force -ErrorAction SilentlyContinue
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    Write-Host "VS Code installed with desktop shortcut"
} else {
    Write-Host "VS Code already installed"
}

# NuGet provider setup (3 fallback methods)
Write-Host "Setting up NuGet provider and PSGallery trust..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$nugetInstalled = $false

# Method 1: ForceBootstrap
try {
    Write-Host "Method 1: Using Get-PackageProvider -ForceBootstrap..."
    $null = Get-PackageProvider -Name NuGet -ForceBootstrap -Force -ErrorAction Stop
    $nugetInstalled = $true
    Write-Host "NuGet provider installed via ForceBootstrap"
} catch {
    Write-Host "Method 1 failed: $($_.Exception.Message)"
}

# Method 2: Direct download
if (-not $nugetInstalled) {
    try {
        Write-Host "Method 2: Direct download from NuGet.org..."
        $nugetProviderPath = "$env:ProgramFiles\PackageManagement\ProviderAssemblies\nuget\2.8.5.208"
        $nugetDllPath = "$nugetProviderPath\Microsoft.PackageManagement.NuGetProvider.dll"
        if (-not (Test-Path $nugetDllPath)) {
            New-Item -Path $nugetProviderPath -ItemType Directory -Force | Out-Null
            $nugetUrl = "https://www.powershellgallery.com/api/v2/package/Microsoft.PackageManagement.NuGetProvider/2.8.5.208"
            Invoke-WebRequest -Uri $nugetUrl -OutFile "$nugetProviderPath\temp.nupkg" -UseBasicParsing -ErrorAction Stop
            Expand-Archive -Path "$nugetProviderPath\temp.nupkg" -DestinationPath "$nugetProviderPath\extract" -Force
            Copy-Item "$nugetProviderPath\extract\lib\net45\Microsoft.PackageManagement.NuGetProvider.dll" $nugetDllPath -Force
            Remove-Item "$nugetProviderPath\temp.nupkg", "$nugetProviderPath\extract" -Recurse -Force -ErrorAction SilentlyContinue
            $nugetInstalled = $true
            Write-Host "NuGet provider installed via PSGallery nupkg"
        }
    } catch {
        Write-Host "Method 2 failed: $($_.Exception.Message)"
    }
}

# Method 3: Install-PackageProvider
if (-not $nugetInstalled) {
    try {
        Write-Host "Method 3: Using Install-PackageProvider..."
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction Stop | Out-Null
        $nugetInstalled = $true
        Write-Host "NuGet provider installed via Install-PackageProvider"
    } catch {
        Write-Host "Method 3 failed: $($_.Exception.Message)"
    }
}

if ($nugetInstalled) {
    Import-PackageProvider -Name NuGet -Force -ErrorAction SilentlyContinue
    Write-Host "NuGet provider loaded"
} else {
    Write-Host "WARNING: All NuGet install methods failed"
}

# Trust PSGallery
try {
    $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if ($repo.InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Write-Host "PSGallery trusted"
    } else {
        Write-Host "PSGallery already trusted"
    }
} catch {
    Write-Host "Warning: Failed to trust PSGallery: $($_.Exception.Message)"
}

# Install required modules with retry
$modules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Users",
    "Microsoft.Graph.Identity.SignIns",
    "Az.Accounts",
    "Az.Compute",
    "Az.Resources",
    "Az.OperationalInsights",
    "Az.SecurityInsights",
    "ExchangeOnlineManagement"
)

function Install-ModuleWithRetry {
    param([string]$ModuleName, [int]$MaxAttempts = 3)
    $attempt = 0
    $delay = 5
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        try {
            Write-Host "Installing module: $ModuleName (attempt $attempt/$MaxAttempts)"
            Install-Module -Name $ModuleName -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
            Write-Host "Installed: $ModuleName"
            return $true
        } catch {
            $errMsg = $_.Exception.Message
            if ($attempt -ge $MaxAttempts) {
                Write-Host "FAILED to install $ModuleName after $attempt attempts: $errMsg"
                return $false
            }
            $jitter = Get-Random -Minimum 0 -Maximum 5
            $actualDelay = $delay + $jitter
            Write-Host "Retrying $ModuleName in $actualDelay seconds..."
            Start-Sleep -Seconds $actualDelay
            $delay = [math]::Min($delay * 2, 30)
        }
    }
    return $false
}

$failedModules = @()
foreach ($module in $modules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        $success = Install-ModuleWithRetry -ModuleName $module
        if (-not $success) { $failedModules += $module }
    } else {
        Write-Host "Module already installed: $module"
    }
}

if ($failedModules.Count -gt 0) {
    Write-Host "WARNING: Failed to install modules: $($failedModules -join ', ')"
}

Update-Status -Phase "01-prereqs" -Status "completed"

# ============================================
# PHASE 1.5: Wait for Manual MI Role Assignment + Verify
# (GA + Owner must be assigned manually during this wait)
# ============================================
Write-Host ""
Write-Host "============================================"
Write-Host "Phase 1.5: Waiting 10 minutes for manual MI role assignment"
Write-Host "============================================"
Write-Host "Assign GA + Owner roles to the LabVM Managed Identity NOW"
Write-Host "Script will resume automatically after 10 minutes and verify roles"

Update-Status -Phase "01.5-mi" -Status "running" -Message "Waiting 10 min for manual role assignment"

$waitMinutes = 20
for ($i = $waitMinutes; $i -gt 0; $i--) {
    Write-Host "Resuming in $i minute(s)..."
    Start-Sleep -Seconds 60
}

Write-Host "Wait complete. Verifying MI roles..."

# Login as MI
$miElevated = $false
az login --identity --output none 2>&1
if ($LASTEXITCODE -eq 0) {
    az account set --subscription $AzureSubscriptionID --output none 2>&1
    Write-Host "MI login: SUCCESS"
} else {
    Write-Host "CRITICAL: MI login failed"
    Update-Status -Phase "01.5-mi" -Status "failed" -Message "MI login failed"
    throw "HARD BLOCK: Cannot login as Managed Identity"
}

# Get MI Principal ID
$vmName = "LabVM-$DeploymentID"
$miPrincipalId = az vm identity show --resource-group $ResourceGroupName --name $vmName --query principalId -o tsv 2>&1
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($miPrincipalId)) {
    Write-Host "MI Principal ID: $miPrincipalId"
} else {
    Write-Host "WARNING: Could not get MI Principal ID"
}

# Verify Owner at subscription scope
$ownerAssigned = $false
$ownerCheck = az role assignment list --assignee $miPrincipalId --all --query "[?roleDefinitionName=='Owner' && scope=='/subscriptions/$AzureSubscriptionID'].id" -o tsv 2>&1
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($ownerCheck)) {
    Write-Host "VERIFIED: Owner at subscription scope"
    $ownerAssigned = $true
} else {
    Write-Host "WARNING: Owner at subscription scope NOT found"
}

# Verify GA by testing Entra ID access
$gaAssigned = $false
$testUser = az ad user list --query "[0].displayName" -o tsv 2>&1
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($testUser)) {
    Write-Host "VERIFIED: GA active (can read Entra users: $testUser)"
    $gaAssigned = $true
    $miElevated = $true
} else {
    Write-Host "WARNING: GA not active yet, waiting 30s for propagation..."
    Start-Sleep -Seconds 30
    az login --identity --output none 2>&1
    $retryUser = az ad user list --query "[0].displayName" -o tsv 2>&1
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($retryUser)) {
        Write-Host "VERIFIED: GA active on retry (user: $retryUser)"
        $gaAssigned = $true
        $miElevated = $true
    } else {
        Write-Host "WARNING: GA still not active. Proceeding with Owner only."
        $miElevated = $ownerAssigned
    }
}

# Update parameters with MI info
$currentParams = Get-Content $ParametersFile | ConvertFrom-Json
$currentParams | Add-Member -NotePropertyName "miprincipalid" -NotePropertyValue $miPrincipalId -Force
$currentParams | Add-Member -NotePropertyName "miauth" -NotePropertyValue "true" -Force
$currentParams | Add-Member -NotePropertyName "migaassigned" -NotePropertyValue $(if ($gaAssigned) { "true" } else { "false" }) -Force
$currentParams | Add-Member -NotePropertyName "miowneratsubscription" -NotePropertyValue $(if ($ownerAssigned) { "true" } else { "false" }) -Force
$currentParams | Add-Member -NotePropertyName "authmethod" -NotePropertyValue "ManagedIdentity" -Force
$currentParams | ConvertTo-Json -Depth 5 | Set-Content $ParametersFile -Force

$phaseMsg = "Owner:$(if ($ownerAssigned){'YES'}else{'NO'}) GA:$(if ($gaAssigned){'YES'}else{'NO'})"
$phase15Status = if ($miElevated) { "completed" } else { "failed" }
Update-Status -Phase "01.5-mi" -Status $phase15Status -Message $phaseMsg

if (-not $miElevated) {
    Write-Host "CRITICAL: MI does not have required roles after 10 min wait"
    throw "HARD BLOCK: MI missing roles. Assign GA + Owner and re-run."
}

# ============================================
# PHASE 2: Verify Azure Authentication
# ============================================
Write-Host ""
Write-Host "============================================"
Write-Host "Phase 2: Verify Azure Authentication"
Write-Host "============================================"

Update-Status -Phase "02-auth" -Status "running"

$authMethod = $null
if ($miElevated) {
    Write-Host "Attempting Managed Identity authentication..."
    $loginResult = az login --identity 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        az account set --subscription $AzureSubscriptionID 2>&1 | Out-Null
        $accountInfo = az account show --query "user.name" -o tsv 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "MI Authentication: SUCCESS as $accountInfo"
            $authMethod = "ManagedIdentity"
        }
    }
}

if ($authMethod) {
    $currentParams = Get-Content $ParametersFile | ConvertFrom-Json
    $currentParams | Add-Member -NotePropertyName "authmethod" -NotePropertyValue $authMethod -Force
    $currentParams | ConvertTo-Json -Depth 5 | Set-Content $ParametersFile -Force
    Update-Status -Phase "02-auth" -Status "completed" -Message "Auth: $authMethod"
} else {
    Write-Host "WARNING: No working Azure authentication method"
    Update-Status -Phase "02-auth" -Status "failed" -Message "No working auth method"
}

# ============================================
# PHASE 3: TAP Creation - SKIPPED
# ============================================
Write-Host ""
Write-Host "Phase 3: TAP Creation - SKIPPED (MI auth, TAP not needed for CLI/PS)"
Update-Status -Phase "03-tap" -Status "skipped" -Message "TAP not needed with MI auth"

# ============================================
# PHASE 3.5: Lookup ODL User Object ID
# ============================================
Write-Host ""
Write-Host "============================================"
Write-Host "Phase 3.5: Lookup ODL User Object ID"
Write-Host "============================================"

Update-Status -Phase "03.5-userid" -Status "running"

$userIdFound = $false
$maxUserLookupAttempts = 3
$userLookupDelay = 15

for ($userAttempt = 1; $userAttempt -le $maxUserLookupAttempts; $userAttempt++) {
    try {
        $currentParams = Get-Content $ParametersFile | ConvertFrom-Json
        $odlUsername = $currentParams.odlusername
        Write-Host "Looking up user: $odlUsername (attempt $userAttempt/$maxUserLookupAttempts)"

        az login --identity --output none 2>&1
        az account set --subscription $AzureSubscriptionID --output none 2>&1

        $userJson = az ad user show --id $odlUsername 2>&1
        if ($LASTEXITCODE -eq 0) {
            $userObj = $userJson | ConvertFrom-Json
            $userId = $userObj.id
            Write-Host "User Object ID: $userId"
            $currentParams | Add-Member -NotePropertyName "oduserid" -NotePropertyValue $userId -Force
            $currentParams | ConvertTo-Json -Depth 5 | Set-Content $ParametersFile -Force
            Update-Status -Phase "03.5-userid" -Status "completed" -Message "User ID: $userId"
            $userIdFound = $true
            break
        } else {
            Write-Host "User lookup failed (attempt $userAttempt): $userJson"
            if ($userAttempt -lt $maxUserLookupAttempts) {
                Write-Host "Waiting ${userLookupDelay}s before retry..."
                Start-Sleep -Seconds $userLookupDelay
            }
        }
    } catch {
        Write-Host "User lookup error (attempt $userAttempt): $($_.Exception.Message)"
        if ($userAttempt -lt $maxUserLookupAttempts) { Start-Sleep -Seconds $userLookupDelay }
    }
}

if (-not $userIdFound) {
    Write-Host "FAILED: Could not lookup user after $maxUserLookupAttempts attempts"
    Update-Status -Phase "03.5-userid" -Status "failed" -Message "User lookup failed"
}

# ============================================
# PHASE 4: Assign Security Admin Role
# ============================================
if ($userIdFound) {
    Invoke-Phase -PhaseName "04-secadmin" -ScriptPath "$ScriptsPath\02a-secadmin\02a-secadmin.ps1" -Parameters @{
        ParametersFile = $ParametersFile
    }
} else {
    Write-Host "Skipping Phase 4 (secadmin): oduserid not available"
    Update-Status -Phase "04-secadmin" -Status "skipped" -Message "oduserid not available"
}

# ============================================
# PHASE 5: Enable Defender for Cloud Plans
# ============================================
Invoke-Phase -PhaseName "05-mdc" -ScriptPath "$ScriptsPath\03mdc\03mdc.ps1" -Parameters @{
    ParametersFile = $ParametersFile
}

# ============================================
# PHASE 6: Configure Sentinel
# ============================================
Write-Host ""
Write-Host "============================================"
Write-Host "Phase 6: Configure Sentinel"
Write-Host "============================================"

Update-Status -Phase "06-sentinel" -Status "running"

# Ensure MI auth is active
$currentParams = Get-Content $ParametersFile | ConvertFrom-Json

az login --identity 2>&1 | Out-Null
az account set --subscription $AzureSubscriptionID 2>&1 | Out-Null

# Get workspace details
$workspaceName = $currentParams.workspacename
$rgName = $currentParams.resourcegroupname

Write-Host "Looking up workspace info..."
Write-Host "  ResourceGroup: $rgName"
Write-Host "  WorkspaceName: $workspaceName"

if ($rgName -and $workspaceName) {
    try {
        $workspaceInfo = az monitor log-analytics workspace show --resource-group $rgName --workspace-name $workspaceName --query "{id:customerId, location:location}" -o json 2>$null | ConvertFrom-Json
        if ($workspaceInfo -and $workspaceInfo.id) {
            $currentParams.workspaceid = $workspaceInfo.id
            Write-Host "  WorkspaceID: $($workspaceInfo.id)"
        }
        if ($workspaceInfo -and $workspaceInfo.location) {
            $currentParams.deploymentregion = $workspaceInfo.location
            Write-Host "  Location: $($workspaceInfo.location)"
        }
        $keys = az monitor log-analytics workspace get-shared-keys --resource-group $rgName --workspace-name $workspaceName 2>$null | ConvertFrom-Json
        if ($keys -and $keys.primarySharedKey) {
            $currentParams.workspacekey = $keys.primarySharedKey
            Write-Host "  WorkspaceKey: [retrieved]"
        }
        $currentParams.sentineldeployed = "true"
        $currentParams.sentineldate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $currentParams | ConvertTo-Json -Depth 5 | Set-Content $ParametersFile -Force
        Write-Host "Updated parameters.json with workspace info"
    } catch {
        Write-Host "Warning: Could not retrieve workspace info: $_"
    }
}

# Phase 6 sub-scripts (sequential)
# 6a-UEBA: DISABLED (requires tenant onboarding for AD sync)

Invoke-Phase -PhaseName "06b-mdi-connector" -ScriptPath "$ScriptsPath\04sentinel\04b-mdi.ps1" -Parameters @{}

Invoke-Phase -PhaseName "06c-entraid" -ScriptPath "$ScriptsPath\04sentinel\04c-entraid.ps1" -Parameters @{}

Invoke-Phase -PhaseName "06d-security-events" -ScriptPath "$ScriptsPath\04sentinel\04d-security-events.ps1" -Parameters @{}

Invoke-Phase -PhaseName "06e-solutions" -ScriptPath "$ScriptsPath\04sentinel\04e-additional-solutions.ps1" -Parameters @{}

Invoke-Phase -PhaseName "06f-defender-solutions" -ScriptPath "$ScriptsPath\04sentinel\04f-defender-solutions.ps1" -Parameters @{}

# 6g-analytics-rules: DISABLED (causes long delays, not needed for lab)

Invoke-Phase -PhaseName "06h-data-connectors" -ScriptPath "$ScriptsPath\04sentinel\05-enable-data-connectors.ps1" -Parameters @{}

Update-Status -Phase "06-sentinel" -Status "completed"

# ============================================
# PHASE 7: MDI - SKIPPED (Playwright, done manually)
# ============================================
Write-Host "Phase 7: MDI Workspace - SKIPPED (Playwright, done manually)"
Update-Status -Phase "07-mdi" -Status "skipped" -Message "Playwright phase, done manually"

# ============================================
# PHASE 8: Disable MDO Protections (Part 1)
# ============================================
Invoke-Phase -PhaseName "08-mdo-pre" -ScriptPath "$ScriptsPath\05b-unprotect\01mdo\01a-mdopre.ps1" -Parameters @{
    ParametersFile = $ParametersFile
}

# ============================================
# PHASE 9: MDE Advanced Features - SKIPPED (Playwright, done manually)
# ============================================
Write-Host "Phase 9: MDE Advanced Features - SKIPPED (Playwright, done manually)"
Update-Status -Phase "09-mde-features" -Status "skipped" -Message "Playwright phase, done manually"

# ============================================
# PHASE 10: Defender Tables - SKIPPED (Playwright, done manually)
# ============================================
Write-Host "Phase 10: Defender Tables - SKIPPED (Playwright, done manually)"
Update-Status -Phase "10-defender-tables" -Status "skipped" -Message "Playwright phase, done manually"

# ============================================
# PHASE 10.5: Enable MDE Integration in MDC
# ============================================
Write-Host ""
Write-Host "============================================"
Write-Host "Phase 10.5: Enable MDE Integration (WDATP)"
Write-Host "============================================"

Update-Status -Phase "10.5-mde-integration" -Status "running"

try {
    az login --identity --output none 2>&1
    az account set --subscription $AzureSubscriptionID --output none 2>&1
    $token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    $mdeHeaders = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }

    # Enable WDATP (MDE integration)
    Write-Host "Enabling WDATP setting..."
    $wdatpBody = '{"kind":"DataExportSettings","properties":{"enabled":true}}'
    $wdatpUrl = "https://management.azure.com/subscriptions/$AzureSubscriptionID/providers/Microsoft.Security/settings/WDATP?api-version=2022-05-01"
    try {
        $resp = Invoke-RestMethod -Uri $wdatpUrl -Method PUT -Headers $mdeHeaders -Body $wdatpBody
        Write-Host "WDATP enabled: $($resp.properties.enabled)"
    } catch { Write-Host "WDATP setting: $($_.Exception.Message)" }

    # Enable WDATP_UNIFIED_SOLUTION
    Write-Host "Enabling WDATP_UNIFIED_SOLUTION..."
    $unifiedUrl = "https://management.azure.com/subscriptions/$AzureSubscriptionID/providers/Microsoft.Security/settings/WDATP_UNIFIED_SOLUTION?api-version=2022-05-01"
    try {
        $resp = Invoke-RestMethod -Uri $unifiedUrl -Method PUT -Headers $mdeHeaders -Body $wdatpBody
        Write-Host "WDATP_UNIFIED_SOLUTION enabled: $($resp.properties.enabled)"
    } catch { Write-Host "WDATP_UNIFIED_SOLUTION: $($_.Exception.Message)" }

    # Enable auto-provisioning
    Write-Host "Enabling auto-provisioning..."
    $apUrl = "https://management.azure.com/subscriptions/$AzureSubscriptionID/providers/Microsoft.Security/autoProvisioningSettings/default?api-version=2017-08-01-preview"
    $apBody = '{"properties":{"autoProvision":"On"}}'
    try {
        $resp = Invoke-RestMethod -Uri $apUrl -Method PUT -Headers $mdeHeaders -Body $apBody
        Write-Host "Auto-provisioning: $($resp.properties.autoProvision)"
    } catch { Write-Host "Auto-provisioning: $($_.Exception.Message)" }

    # Enable MdeDesignatedSubscription in VirtualMachines pricing
    Write-Host "Enabling MdeDesignatedSubscription extension..."
    $pricingUrl = "https://management.azure.com/subscriptions/$AzureSubscriptionID/providers/Microsoft.Security/pricings/VirtualMachines?api-version=2024-01-01"
    try {
        $pricing = Invoke-RestMethod -Uri $pricingUrl -Method GET -Headers $mdeHeaders
        $extensions = @($pricing.properties.extensions)
        $mdeFound = $false
        $newExtensions = @()
        foreach ($ext in $extensions) {
            if ($ext.name -eq "MdeDesignatedSubscription") {
                $newExtensions += @{ name = "MdeDesignatedSubscription"; isEnabled = "True" }
                $mdeFound = $true
            } else {
                $newExtensions += @{ name = $ext.name; isEnabled = $ext.isEnabled }
            }
        }
        if (-not $mdeFound) {
            $newExtensions += @{ name = "MdeDesignatedSubscription"; isEnabled = "True" }
        }
        $pricingBody = @{
            properties = @{
                pricingTier = $pricing.properties.pricingTier
                subPlan = $pricing.properties.subPlan
                extensions = $newExtensions
            }
        } | ConvertTo-Json -Depth 5
        $resp = Invoke-RestMethod -Uri $pricingUrl -Method PUT -Headers $mdeHeaders -Body $pricingBody -ContentType "application/json"
        Write-Host "MdeDesignatedSubscription enabled"
    } catch { Write-Host "MdeDesignatedSubscription: $($_.Exception.Message)" }

    Update-Status -Phase "10.5-mde-integration" -Status "completed" -Message "WDATP + MdeDesignatedSubscription enabled"
} catch {
    Write-Host "WARNING: MDE integration setup failed: $($_.Exception.Message)"
    Update-Status -Phase "10.5-mde-integration" -Status "failed" -Message $_.Exception.Message
}

# ============================================
# PHASE 11: Deploy AD VMs (DC + SMB)
# ============================================
Invoke-Phase -PhaseName "11-deploy-vms" -ScriptPath "$ScriptsPath\06vms\06vms.ps1" -Parameters @{
    ParametersFile = $ParametersFile
} -MaxRetries 2

# ============================================
# PHASE 11.5: Create RDP files on Desktop
# ============================================
Write-Host ""
Write-Host "============================================"
Write-Host "Phase 11.5: Creating RDP files on Desktop"
Write-Host "============================================"
try {
    $rdpParams = Get-Content $ParametersFile | ConvertFrom-Json
    $rdpDeployId = $rdpParams.deploymentid
    $rdpRegion = $rdpParams.deploymentregion
    if (-not $rdpRegion) { $rdpRegion = "eastus" }
    $dcVmName = "UniSecOps-DC-$rdpDeployId"
    $smbVmName = "UniSecOps-SMB-$rdpDeployId"
    $desktopPath = "$env:PUBLIC\Desktop"

    # Use DNS FQDN from ARM template pattern (no Az.Network module needed)
    $dcFqdn = "dc-$rdpDeployId.$rdpRegion.cloudapp.azure.com"
    $smbFqdn = "smb-$rdpDeployId.$rdpRegion.cloudapp.azure.com"

    $dcRdp = @"
full address:s:$dcFqdn
username:s:CORP\DomainAdmin
prompt for credentials:i:1
administrative session:i:1
"@
    $dcRdp | Out-File "$desktopPath\DC - $dcVmName.rdp" -Encoding ASCII
    Write-Host "DC RDP file created: $dcFqdn"

    $smbRdp = @"
full address:s:$smbFqdn
username:s:CORP\DomainAdmin
prompt for credentials:i:1
administrative session:i:1
"@
    $smbRdp | Out-File "$desktopPath\SMB - $smbVmName.rdp" -Encoding ASCII
    Write-Host "SMB RDP file created: $smbFqdn"

    Update-Status -Phase "11.5-rdp-files" -Status "completed" -Message "RDP files created on desktop"
} catch {
    Write-Host "RDP file error: $($_.Exception.Message)"
    Update-Status -Phase "11.5-rdp-files" -Status "failed" -Message $_.Exception.Message
}

# ============================================
# PHASE 11.6: Create LabCredentials file on Desktop
# ============================================
Write-Host ""
Write-Host "============================================"
Write-Host "Phase 11.6: Creating LabCredentials on Desktop"
Write-Host "============================================"
try {
    $credParams = Get-Content $ParametersFile | ConvertFrom-Json
    $credDeployId = $credParams.deploymentid
    $credUser = $credParams.odlusername
    $credTap = $credParams.tap
    $credWorkspace = $credParams.workspacename
    $desktopPath = "$env:PUBLIC\Desktop"

    $labCredsHeader = @"
Username: $credUser
TAP: $credTap
Workspace: $credWorkspace
Parameters File: C:\LabFiles\deploy\parameters.json

Security Copilot Capacity Command:
"@
    $labCredsCommand = @'
Connect-AzAccount -Identity
$params = Get-Content "C:\LabFiles\deploy\parameters.json" | ConvertFrom-Json
$sid = $params.subid
$did = $params.deploymentid
$rg = $params.resourcegroupname
Set-AzContext -SubscriptionId $sid
Register-AzResourceProvider -ProviderNamespace "Microsoft.SecurityCopilot" | Out-Null
$tokenObj = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
$tok = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenObj.Token))
$h = @{Authorization="Bearer $tok";"Content-Type"="application/json"}
$body = '{"location":"eastus","properties":{"numberOfUnits":3,"crossGeoCompute":"NotAllowed","geo":"US"}}'
$uri = "https://management.azure.com/subscriptions/$sid/resourceGroups/$rg/providers/Microsoft.SecurityCopilot/capacities/capacity-$($did)?api-version=2023-12-01-preview"
Invoke-WebRequest -Uri $uri -Method PUT -Headers $h -Body $body -UseBasicParsing

Security Copilot Portal: https://securitycopilot.microsoft.com
'@
    ($labCredsHeader + "`n" + $labCredsCommand) | Out-File "$desktopPath\LabCredentials-$credDeployId.txt" -Encoding UTF8
    Write-Host "LabCredentials file created on desktop"
    Update-Status -Phase "11.6-lab-creds" -Status "completed" -Message "LabCredentials file created"
} catch {
    Write-Host "LabCredentials error: $($_.Exception.Message)"
    Update-Status -Phase "11.6-lab-creds" -Status "failed" -Message $_.Exception.Message
}

# ============================================
# PHASE 12: Deploy Kali Attack VM
# ============================================
Invoke-Phase -PhaseName "12-deploy-kali" -ScriptPath "$ScriptsPath\07kali\07kali.ps1" -Parameters @{
    ParametersFile = $ParametersFile
} -MaxRetries 2

Write-Host ""
Write-Host "============================================"
Write-Host "Bootstrap Phase 1-13 Complete"
Write-Host "============================================"

$deploymentStatus.completed = $true
$deploymentStatus.endTime = (Get-Date).ToString("o")
$deploymentStatus | ConvertTo-Json -Depth 5 | Set-Content $StatusFile -Force

# Summary
$completedPhases = ($deploymentStatus.phases.GetEnumerator() | Where-Object { $_.Value.status -eq "completed" }).Count
$failedPhases = ($deploymentStatus.phases.GetEnumerator() | Where-Object { $_.Value.status -eq "failed" }).Count
$skippedPhases = ($deploymentStatus.phases.GetEnumerator() | Where-Object { $_.Value.status -eq "skipped" }).Count
$totalPhases = $deploymentStatus.phases.Count

Write-Host ""
Write-Host "Summary:"
Write-Host "  Completed: $completedPhases"
Write-Host "  Failed: $failedPhases"
Write-Host "  Skipped: $skippedPhases"
Write-Host "  Total: $totalPhases"
Write-Host ""
Write-Host "Deployment ID: $DeploymentID"
Write-Host "End Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Logs: $LogPath"
Write-Host "Parameters: $ParametersFile"
Write-Host "Status: $StatusFile"
Write-Host ""
Write-Host "Manual steps remaining: Phase 7 (MDI), Phase 9 (MDE Features), Phase 10 (Defender Tables)"

$finalParams = Get-Content $ParametersFile | ConvertFrom-Json
Write-Host ""
Write-Host "Key Resources:"
Write-Host "  Sentinel Workspace: $($finalParams.workspacename)"
Write-Host "  Resource Group: $($finalParams.resourcegroupname)"
Write-Host "  Auth Method: $($finalParams.authmethod)"

Stop-Transcript

# Desktop shortcut
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("$env:PUBLIC\Desktop\LabFiles.lnk")
$Shortcut.TargetPath = $LabFilesPath
$Shortcut.Save()

Write-Host "Bootstrap Phase 1-13 completed"
exit 0
