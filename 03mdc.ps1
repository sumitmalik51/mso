param(
    [Parameter(Mandatory=$false)]
    [string]$ParametersFile = ""
)

$scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptPath) { $scriptPath = $PWD.Path }

if ([string]::IsNullOrWhiteSpace($ParametersFile)) {
    $ParametersFile = Join-Path $scriptPath "..\parameters.json"
}

<#
.SYNOPSIS
    Enables Microsoft Defender for Cloud plans for automated MDE onboarding
    
.DESCRIPTION
    This script enables Defender for Cloud pricing tiers to enable automatic
    MDE (Microsoft Defender for Endpoint) onboarding for Azure VMs.
    
    Plans enabled:
    - VirtualMachines (Defender for Servers P2) - Required for MDE auto-onboarding
    - CloudPosture (CSPM) - Security posture management
    - Containers - Container security
    - StorageAccounts - Storage threat detection
    
    When VMs are deployed, they will automatically onboard to MDE within 10-15 minutes.
    
.NOTES
    Prerequisites:
    - Azure CLI authenticated with sufficient permissions
    - Security Admin or Contributor role on subscription
    
    Cost: ~$15/VM/month for Defender for Servers P2
#>

$ErrorActionPreference = "Continue"

Write-Host "Phase 03mdc: Enable Microsoft Defender for Cloud Plans"
Write-Host ""

# Load parameters
if (!(Test-Path $ParametersFile)) {
    throw "Parameters file not found: $ParametersFile"
}

Write-Host "Loading parameters from: $ParametersFile"
$params = Get-Content $ParametersFile -Raw | ConvertFrom-Json

$subscriptionId = $params.subid
$tenantId = $params.tenantid

if (!$subscriptionId) {
    throw "Subscription ID not found in parameters file"
}

# Authenticate with Azure CLI
Write-Host "Authenticating with Azure CLI..."
az config set core.encrypt_token_cache=false 2>&1 | Out-Null
try {
    $currentAccount = (az account show 2>&1) | ConvertFrom-Json
    if (-not $currentAccount -or $currentAccount.id -ne $subscriptionId) {
        Write-Host "Logging in with Managed Identity..."
        az login --identity --output none 2>&1 | Out-Null
        az account set --subscription $subscriptionId --output none 2>&1 | Out-Null
    }
    
    $account = (az account show 2>&1) | ConvertFrom-Json
    Write-Host "Authenticated as: $($account.user.name)"
    Write-Host "Subscription: $($account.name)"
}
catch {
    throw "Failed to authenticate with Azure CLI: $($_.Exception.Message)"
}

# Check current Defender for Cloud pricing status
Write-Host "`nChecking current Defender for Cloud status..."
$pricingResult = az security pricing list | ConvertFrom-Json
$currentPricing = $pricingResult.value

Write-Host "`nCurrent Defender for Cloud Plans:"
$currentPricing | Where-Object { !$_.deprecated } | ForEach-Object {
    $planName = $_.name
    $status = if ($_.pricingTier -eq "Standard") { "ENABLED" } else { "FREE" }
    Write-Host "  ${planName}: $status"
    if ($_.subPlan) {
        Write-Host "    SubPlan: $($_.subPlan)"
    }
}

# Define plans to enable
$plansToEnable = @(
    "VirtualMachines"
    "SqlServers"
    "AppServices"
    "StorageAccounts"
    "SqlServerVirtualMachines"
    "KeyVaults"
    "Arm"
    "OpenSourceRelationalDatabases"
    "CosmosDbs"
    "Containers"
    "CloudPosture"
    "Api"
    "AI"
)

Write-Host "`nPlans to enable:"
$plansToEnable | ForEach-Object {
    Write-Host "  - $_"
}

# Enable plans
Write-Host "`nEnabling Defender for Cloud plans..."

foreach ($plan in $plansToEnable) {
    Write-Host "`nEnabling: $plan"
    
    try {
        $result = az security pricing create --name $plan --tier Standard 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "$plan enabled"
        } else {
            Write-Host "Failed to enable $plan"
        }
    }
    catch {
        Write-Host "Error enabling $plan : $($_.Exception.Message)"
    }
}

# Verify final status
Write-Host "`nVerifying final status..."
Start-Sleep -Seconds 5

$finalPricingResult = az security pricing list | ConvertFrom-Json
$finalPricing = $finalPricingResult.value

Write-Host "`nFinal Defender for Cloud Plans:"
$enabledCount = 0
foreach ($pricing in $finalPricing) {
    if (!$pricing.deprecated -and $pricing.pricingTier -eq "Standard") {
        $enabledCount++
        Write-Host "  $($pricing.name): ENABLED"
        if ($pricing.subPlan) {
            Write-Host "    SubPlan: $($pricing.subPlan)"
        }
    }
}

Write-Host "`nSummary:"
Write-Host "  Enabled plans: $enabledCount"
Write-Host "  Target plans: $($plansToEnable.Count)"

# Update parameters file with completion status
Write-Host "`nUpdating parameters file..."
$params | Add-Member -NotePropertyName "mdcenabled" -NotePropertyValue "true" -Force
$params | Add-Member -NotePropertyName "mdcdate" -NotePropertyValue (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Force
$params | ConvertTo-Json -Depth 10 | Set-Content $ParametersFile
Write-Host "Parameters file updated"

Write-Host "`nPhase 03mdc Complete"
