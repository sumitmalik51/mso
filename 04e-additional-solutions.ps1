# Load parameters
$ErrorActionPreference = "Continue"

$scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptPath) { $scriptPath = $PWD.Path }

$params = Get-Content (Join-Path $scriptPath "..\parameters.json") | ConvertFrom-Json
$rgName = $params.resourcegroupname
$workspaceName = $params.workspacename
$location = $params.deploymentregion
$subscriptionId = $params.subid

Write-Host "Deploying Additional Sentinel Solutions..."
Write-Host "  Resource Group: $rgName"
Write-Host "  Workspace: $workspaceName"
Write-Host ""

# Authenticate with Managed Identity
az config set core.encrypt_token_cache=false 2>&1 | Out-Null
$currentAccount = (az account show 2>&1) | ConvertFrom-Json
if (-not $currentAccount -or $currentAccount.id -ne $subscriptionId) {
    Write-Host "Logging in with Managed Identity..."
    az login --identity --output none 2>&1 | Out-Null
    az account set --subscription $subscriptionId --output none 2>&1 | Out-Null
}
Write-Host "Authenticated as: $((az account show --query user.name -o tsv 2>$null))"
Write-Host ""

# Solution mapping with GitHub paths
$solutions = @(
    @{
        Name = "Endpoint Threat Protection Essentials"
        Path = "Endpoint%20Threat%20Protection%20Essentials"
        DisplayName = "Endpoint Threat Protection Essentials"
    },
    @{
        Name = "Log4j Vulnerability Detection"
        Path = "Apache%20Log4j%20Vulnerability%20Detection"
        DisplayName = "Log4j Vulnerability Detection"
    },
    @{
        Name = "Microsoft Defender for Cloud"
        Path = "Microsoft%20Defender%20for%20Cloud"
        DisplayName = "Defender for Cloud"
    },
    @{
        Name = "Network Session Essentials"
        Path = "Network%20Session%20Essentials"
        DisplayName = "Network Session Essentials"
    },
    @{
        Name = "Security Threat Essentials"
        Path = "SecurityThreatEssentialSolution"
        DisplayName = "Security Threat Essentials"
    },
    @{
        Name = "Sentinel SOAR Essentials"
        Path = "SentinelSOARessentials"
        DisplayName = "SOAR Essentials"
    },
    @{
        Name = "Microsoft Defender Threat Intelligence"
        Path = "Microsoft%20Defender%20Threat%20Intelligence"
        DisplayName = "Defender Threat Intelligence"
    },
    @{
        Name = "UEBA Essentials"
        Path = "UEBA%20Essentials"
        DisplayName = "UEBA Essentials"
    },
    @{
        Name = "Attacker Tools Threat Protection Essentials"
        Path = "Attacker%20Tools%20Threat%20Protection%20Essentials"
        DisplayName = "Attacker Tools Protection"
    },
    @{
        Name = "Azure Activity"
        Path = "Azure%20Activity"
        DisplayName = "Azure Activity"
    }
)

$successCount = 0
$failCount = 0

foreach ($solution in $solutions) {
    Write-Host "[$($successCount + $failCount + 1)/$($solutions.Count)] Deploying $($solution.DisplayName)..." -ForegroundColor Cyan
    
    try {
        $githubUrl = "https://raw.githubusercontent.com/Azure/Azure-Sentinel/master/Solutions/$($solution.Path)/Package/mainTemplate.json"
        $tempFile = Join-Path $env:TEMP "$($solution.Name.Replace(' ', '-'))-mainTemplate.json"
        
        Invoke-WebRequest -Uri $githubUrl -OutFile $tempFile -UseBasicParsing -ErrorAction Stop | Out-Null
        
        $deploymentName = "$($solution.Name.Replace(' ', ''))-$(Get-Date -Format 'yyyyMMddHHmmss')"
        $deployResult = az deployment group create `
            --resource-group $rgName `
            --template-file $tempFile `
            --parameters workspace=$workspaceName location=$location `
            --name $deploymentName `
            --output json 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            throw "Deployment failed: $deployResult"
        }
        
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] $($solution.DisplayName) deployed" -ForegroundColor Green
        $successCount++
        
    } catch {
        Write-Host "  [FAIL] $($solution.DisplayName): $($_.Exception.Message -replace '\n.*')" -ForegroundColor Red
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        $failCount++
    }
    
    Write-Host ""
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Deployment Summary" -ForegroundColor White
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Successful: $successCount" -ForegroundColor Green
Write-Host "  Failed: $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Total: $($solutions.Count)" -ForegroundColor White
Write-Host ""

# Now enable analytics rules from all deployed solutions
Write-Host "Enabling analytics rules from deployed solutions..." -ForegroundColor Cyan
Write-Host ""

try {
    # Get access token
    $token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    if (-not $token) {
        throw "Failed to get access token"
    }
    
    $headers = @{"Authorization"="Bearer $token"; "Content-Type"="application/json"}
    $subscriptionId = (az account show --query id -o tsv 2>$null)
    
    if (-not $subscriptionId) {
        throw "Failed to get subscription ID"
    }
    
    # Get all templates
    $templatesUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/providers/Microsoft.SecurityInsights/alertRuleTemplates?api-version=2023-02-01"
    $response = Invoke-RestMethod -Uri $templatesUri -Headers $headers -Method Get -ErrorAction Stop
    
    # Filter for templates from our solutions
    $keywords = @(
        "Endpoint", "Log4j", "Defender for Cloud", "Network", "Threat", 
        "SOAR", "Intelligence", "UEBA", "Attacker", "Azure Activity"
    )
    
    $templates = $response.value | Where-Object { 
        $displayName = $_.properties.displayName
        $keywords | Where-Object { $displayName -match $_ }
    }
    
    Write-Host "Found $($templates.Count) templates from deployed solutions"
    
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
    Write-Host "[+] Analytics Rules: $enabled enabled, $skipped skipped"
    Write-Host ""
    
} catch {
    Write-Host "[ERROR] Failed to enable analytics rules: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "[WARN] Solutions deployed but analytics rules need manual enablement" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "All solutions deployment complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
