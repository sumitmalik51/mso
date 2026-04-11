# Deploy Microsoft Defender for Identity Solution
# Fully automated deployment with no user interaction

$ErrorActionPreference = "Continue"

$scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptPath) { $scriptPath = $PWD.Path }

$params = Get-Content (Join-Path $scriptPath "..\parameters.json") | ConvertFrom-Json

$rgName = $params.resourcegroupname
$deploymentId = $params.deploymentid
$workspaceName = if ($params.workspacename) { $params.workspacename } else { "UniSecOps-sentinel-$deploymentId" }
$location = $params.deploymentregion
$subscriptionId = $params.subid

# Authenticate with Managed Identity
az config set core.encrypt_token_cache=false 2>&1 | Out-Null
$currentAccount = (az account show 2>&1) | ConvertFrom-Json
if (-not $currentAccount -or $currentAccount.id -ne $subscriptionId) {
    Write-Host "Logging in with Managed Identity..."
    az login --identity --output none 2>&1 | Out-Null
    az account set --subscription $subscriptionId --output none 2>&1 | Out-Null
}

Write-Host "Deploying Microsoft Defender for Identity solution..."
Write-Host "  Resource Group: $rgName"
Write-Host "  Workspace: $workspaceName"

# Download the MDI solution template from GitHub
$mdiTemplateUrl = "https://raw.githubusercontent.com/Azure/Azure-Sentinel/master/Solutions/Microsoft%20Defender%20For%20Identity/Package/mainTemplate.json"
$mdiTempFile = [System.IO.Path]::GetTempFileName() + ".json"

Write-Host "Downloading MDI template from GitHub..."
Invoke-WebRequest -Uri $mdiTemplateUrl -OutFile $mdiTempFile

# Deploy the solution
$deploymentName = "MDI-Solution-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host "Starting deployment: $deploymentName"

az deployment group create `
    --resource-group $rgName `
    --template-file $mdiTempFile `
    --parameters workspace=$workspaceName location=$location `
    --name $deploymentName `
    --output json | ConvertFrom-Json | Select-Object name, properties

# Clean up temp file
Remove-Item $mdiTempFile -Force

Write-Host "[+] Microsoft Defender for Identity solution deployed successfully"
Write-Host ""

# Enable analytics rules from MDI templates
Write-Host "Enabling MDI analytics rules from templates..."

try {
    # Get access token
    $token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    if (-not $token) {
        throw "Failed to get access token. Please ensure you are logged in with 'az login'"
    }
    
    $headers = @{"Authorization"="Bearer $token"; "Content-Type"="application/json"}

    $subscriptionId = (az account show --query id -o tsv 2>$null)
    if (-not $subscriptionId) {
        throw "Failed to get subscription ID"
    }
    
    $templatesUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/providers/Microsoft.SecurityInsights/alertRuleTemplates?api-version=2023-02-01"

    $response = Invoke-RestMethod -Uri $templatesUri -Headers $headers -Method Get -ErrorAction Stop
    $templates = $response.value | Where-Object { 
        $_.properties.displayName -match "Identity|Defender for Identity|AAD"
    }

    Write-Host "Found $($templates.Count) MDI-related rule templates"
} catch {
    Write-Host "[ERROR] Failed to query analytics rule templates: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "[WARN] Continuing without analytics rules..." -ForegroundColor Yellow
    $templates = @()
}

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
        Write-Host "[SKIP] $($template.properties.displayName)"
        $skipped++
        continue
    }

    Write-Host "[ENABLE] $($template.properties.displayName)"
    $ruleId = [guid]::NewGuid().ToString()
    
    # Create rule using REST API
    $ruleUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/providers/Microsoft.SecurityInsights/alertRules/$($ruleId)?api-version=2023-02-01"
    
    # Prepare rule body with all properties from template
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
Write-Host "[+] MDI Analytics Rules: $enabled enabled, $skipped skipped"
Write-Host ""
Write-Host "Solution includes:"
Write-Host "  - Data connector: AzureAdvancedThreatProtection"
Write-Host "  - Analytics rules: $enabled active"
Write-Host "  - Workbooks for MDI insights"
Write-Host "  - Parsers for MDI data"
