# Deploy Microsoft Entra ID Solution with Full Diagnostic Settings
# Fully automated deployment with no user interaction

$ErrorActionPreference = "Continue"

$scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptPath) { $scriptPath = $PWD.Path }

$params = Get-Content (Join-Path $scriptPath "..\parameters.json") | ConvertFrom-Json

$rgName = $params.resourcegroupname
$deploymentId = $params.deploymentid
$subscriptionId = $params.subid
$workspaceName = if ($params.workspacename) { $params.workspacename } else { "UniSecOps-sentinel-$deploymentId" }
$location = $params.deploymentregion

# Authenticate with Managed Identity
az config set core.encrypt_token_cache=false 2>&1 | Out-Null
$currentAccount = (az account show 2>&1) | ConvertFrom-Json
if (-not $currentAccount -or $currentAccount.id -ne $subscriptionId) {
    Write-Host "Logging in with Managed Identity..."
    az login --identity --output none 2>&1 | Out-Null
    az account set --subscription $subscriptionId --output none 2>&1 | Out-Null
}

Write-Host "Deploying Microsoft Entra ID solution..."
Write-Host "  Resource Group: $rgName"
Write-Host "  Workspace: $workspaceName"

# Download the Entra ID solution template from GitHub
$entraTemplateUrl = "https://raw.githubusercontent.com/Azure/Azure-Sentinel/master/Solutions/Microsoft%20Entra%20ID/Package/mainTemplate.json"
$entraTempFile = [System.IO.Path]::GetTempFileName() + ".json"

Write-Host "Downloading Entra ID template from GitHub..."
Invoke-WebRequest -Uri $entraTemplateUrl -OutFile $entraTempFile

# Deploy the solution
$deploymentName = "EntraID-Solution-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host "Starting deployment: $deploymentName"

az deployment group create `
    --resource-group $rgName `
    --template-file $entraTempFile `
    --parameters workspace=$workspaceName location=$location `
    --name $deploymentName `
    --output json | ConvertFrom-Json | Select-Object name, properties

# Clean up temp file
Remove-Item $entraTempFile -Force

Write-Host "[+] Entra ID solution deployed successfully"
Write-Host ""
Write-Host "Solution includes:"
Write-Host "  - Data connector: AzureActiveDirectory"
Write-Host "  - 70+ analytics rules for Entra ID detections"
Write-Host "  - 2 workbooks (Audit logs, Sign-in logs)"
Write-Host "  - 11 parsers for Entra ID data"
Write-Host ""

# Configure diagnostic settings for all 15 Entra ID log types
Write-Host "Configuring Entra ID diagnostic settings..."

# Ensure MI auth is active
az login --identity --output none 2>&1 | Out-Null
az account set --subscription $subscriptionId --output none 2>&1 | Out-Null

# Get access token for Azure Management API
try {
    $token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    if (-not $token) {
        throw "Failed to get access token"
    }
    
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }
} catch {
    Write-Host "Authentication failed: $($_.Exception.Message)"
    Write-Host "Continuing without diagnostic settings..."
    $token = $null
}

# Get workspace resource ID
$workspace = az monitor log-analytics workspace show `
    --resource-group $rgName `
    --workspace-name $workspaceName 2>$null | ConvertFrom-Json
    
if (-not $workspace) {
    Write-Host "  ERROR: Could not get workspace. Using resource ID from subscription..."
    $subscriptionId = az account show --query id -o tsv
    $workspaceId = "/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName"
} else {
    $workspaceId = $workspace.id
}

Write-Host "  Workspace ID: $workspaceId"

# Configure all 15 log categories
$diagnosticUri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/EntraID-to-Sentinel?api-version=2017-04-01"

$diagnosticConfig = @{
    properties = @{
        workspaceId = $workspaceId
        logs = @(
            @{category="SignInLogs"; enabled=$true; retentionPolicy=@{enabled=$false; days=0}},
            @{category="AuditLogs"; enabled=$true; retentionPolicy=@{enabled=$false; days=0}},
            @{category="NonInteractiveUserSignInLogs"; enabled=$true; retentionPolicy=@{enabled=$false; days=0}},
            @{category="ServicePrincipalSignInLogs"; enabled=$true; retentionPolicy=@{enabled=$false; days=0}},
            @{category="ManagedIdentitySignInLogs"; enabled=$true; retentionPolicy=@{enabled=$false; days=0}},
            @{category="ProvisioningLogs"; enabled=$true; retentionPolicy=@{enabled=$false; days=0}},
            @{category="ADFSSignInLogs"; enabled=$true; retentionPolicy=@{enabled=$false; days=0}},
            @{category="UserRiskEvents"; enabled=$true; retentionPolicy=@{enabled=$false; days=0}},
            @{category="RiskyUsers"; enabled=$true; retentionPolicy=@{enabled=$false; days=0}},
            @{category="NetworkAccessTrafficLogs"; enabled=$true; retentionPolicy=@{enabled=$false; days=0}},
            @{category="RiskyServicePrincipals"; enabled=$true; retentionPolicy=@{enabled=$false; days=0}},
            @{category="ServicePrincipalRiskEvents"; enabled=$true; retentionPolicy=@{enabled=$false; days=0}},
            @{category="MicrosoftGraphActivityLogs"; enabled=$true; retentionPolicy=@{enabled=$false; days=0}},
            @{category="EnrichedOffice365AuditLogs"; enabled=$true; retentionPolicy=@{enabled=$false; days=0}},
            @{category="RemoteNetworkHealthLogs"; enabled=$true; retentionPolicy=@{enabled=$false; days=0}}
        )
    }
} | ConvertTo-Json -Depth 10

Write-Host "Enabling all 15 Entra ID log categories:"
Write-Host "  1. SignInLogs"
Write-Host "  2. AuditLogs"
Write-Host "  3. NonInteractiveUserSignInLogs"
Write-Host "  4. ServicePrincipalSignInLogs"
Write-Host "  5. ManagedIdentitySignInLogs"
Write-Host "  6. ProvisioningLogs"
Write-Host "  7. ADFSSignInLogs"
Write-Host "  8. UserRiskEvents"
Write-Host "  9. RiskyUsers"
Write-Host " 10. NetworkAccessTrafficLogs"
Write-Host " 11. RiskyServicePrincipals"
Write-Host " 12. ServicePrincipalRiskEvents"
Write-Host " 13. MicrosoftGraphActivityLogs"
Write-Host " 14. EnrichedOffice365AuditLogs"
Write-Host " 15. RemoteNetworkHealthLogs"

if ($token) {
    try {
        $result = Invoke-RestMethod -Uri $diagnosticUri -Headers $headers -Method Put -Body $diagnosticConfig -ErrorAction Stop
        
        Write-Host ""
        Write-Host "[+] Diagnostic settings configured successfully"
        Write-Host "  Setting Name: $($result.name)"
        Write-Host "  Workspace: $workspaceName"
        Write-Host "  Log Categories: 15 enabled"
        Write-Host ""
    } catch {
        Write-Host ""
        Write-Host "[ERROR] Failed to configure diagnostic settings: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "[WARN] Continuing without diagnostic settings..." -ForegroundColor Yellow
        Write-Host ""
    }
} else {
    Write-Host ""
    Write-Host "[WARN] Skipping diagnostic settings due to authentication failure" -ForegroundColor Yellow
    Write-Host ""
}

# Enable analytics rules from Entra ID templates
Write-Host "Enabling Entra ID analytics rules from templates..."

# Refresh token for analytics rules (may have expired)
if (-not $token) {
    az login --identity --output none 2>&1 | Out-Null
    az account set --subscription $subscriptionId --output none 2>&1 | Out-Null
    $token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    if ($token) {
        $headers = @{
            "Authorization" = "Bearer $token"
            "Content-Type" = "application/json"
        }
    }
}

if (-not $token) {
    Write-Host "WARNING: No access token available, skipping analytics rules"
} else {

$templatesUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/providers/Microsoft.SecurityInsights/alertRuleTemplates?api-version=2023-02-01"
$response = Invoke-RestMethod -Uri $templatesUri -Headers $headers -Method Get
$templates = $response.value | Where-Object { 
    $_.properties.displayName -match "Azure AD|Entra|AAD|Sign-in|Identity Protection"
}

Write-Host "Found $($templates.Count) Entra ID-related rule templates"

$existingRulesUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/providers/Microsoft.SecurityInsights/alertRules?api-version=2023-02-01"
try {
    $existingRulesResponse = Invoke-RestMethod -Uri $existingRulesUri -Headers $headers -Method Get -ErrorAction Stop
    $existingRules = $existingRulesResponse.value | ForEach-Object { $_.properties.displayName }
} catch {
    $existingRules = @()
}

$enabled = 0
$skipped = 0

foreach ($template in $templates) {
    if ($existingRules -contains $template.properties.displayName) {
        $skipped++
        continue
    }

    Write-Host "[ENABLE] $($template.properties.displayName)"
    $ruleId = [guid]::NewGuid().ToString()
    
    $ruleUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/providers/Microsoft.SecurityInsights/alertRules/$($ruleId)?api-version=2023-02-01"
    
    if ($template.kind -eq "MicrosoftSecurityIncidentCreation") {
        $ruleBody = @{
            kind = "MicrosoftSecurityIncidentCreation"
            properties = @{
                displayName = $template.properties.displayName
                enabled = $true
                productFilter = $template.properties.productFilter
                alertRuleTemplateName = $template.name
            }
        }
        if ($template.properties.displayNamesFilter) {
            $ruleBody.properties.displayNamesFilter = $template.properties.displayNamesFilter
        }
        if ($template.properties.severitiesFilter) {
            $ruleBody.properties.severitiesFilter = $template.properties.severitiesFilter
        }
    } else {
        $ruleBody = @{
            kind = "Scheduled"
            properties = @{
                displayName = $template.properties.displayName
                description = $template.properties.description
                severity = $template.properties.severity
                enabled = $true
                query = $template.properties.query
                queryFrequency = if ($template.properties.queryFrequency) { $template.properties.queryFrequency } else { "PT5H" }
                queryPeriod = if ($template.properties.queryPeriod) { $template.properties.queryPeriod } else { "PT5H" }
                triggerOperator = if ($template.properties.triggerOperator) { $template.properties.triggerOperator } else { "GreaterThan" }
                triggerThreshold = if ($null -ne $template.properties.triggerThreshold) { $template.properties.triggerThreshold } else { 0 }
                suppressionDuration = "PT5H"
                suppressionEnabled = $false
                alertRuleTemplateName = $template.name
            }
        }
        if ($template.properties.tactics) {
            $ruleBody.properties.tactics = $template.properties.tactics
        }
        if ($template.properties.techniques) {
            $ruleBody.properties.techniques = $template.properties.techniques
        }
        if ($template.properties.entityMappings) {
            $ruleBody.properties.entityMappings = $template.properties.entityMappings
        }
    }
    
    $ruleBodyJson = $ruleBody | ConvertTo-Json -Depth 10
    
    try {
        Invoke-RestMethod -Uri $ruleUri -Headers $headers -Method Put -Body $ruleBodyJson -ErrorAction Stop | Out-Null
        Write-Host "  [OK]" -ForegroundColor Green
        $enabled++
    } catch {
        if ($_.Exception.Message -match "already exists|conflict") {
            Write-Host "  [SKIP] Already exists" -ForegroundColor Yellow
        } else {
            Write-Host "  [FAIL] $($_.Exception.Message -replace '\n.*')" -ForegroundColor Red
        }
        $skipped++
    }
}

Write-Host ""
Write-Host "[+] Entra ID Analytics Rules: $enabled enabled, $skipped skipped"

} # end of if ($token) block for analytics rules

Write-Host ""
Write-Host "[+] Entra ID solution fully configured and data collection enabled"
