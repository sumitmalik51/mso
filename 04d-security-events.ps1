# Deploy Windows Security Events Solution
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

Write-Host "Deploying Windows Security Events solution..."
Write-Host "  Resource Group: $rgName"
Write-Host "  Workspace: $workspaceName"

# Download the Security Events solution template from GitHub
$secEventsTemplateUrl = "https://raw.githubusercontent.com/Azure/Azure-Sentinel/master/Solutions/Windows%20Security%20Events/Package/mainTemplate.json"
$secEventsTempFile = [System.IO.Path]::GetTempFileName() + ".json"

Write-Host "Downloading Security Events template from GitHub..."
Invoke-WebRequest -Uri $secEventsTemplateUrl -OutFile $secEventsTempFile

# Deploy the solution
$deploymentName = "SecurityEvents-Solution-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host "Starting deployment: $deploymentName"

az deployment group create `
    --resource-group $rgName `
    --template-file $secEventsTempFile `
    --parameters workspace=$workspaceName location=$location `
    --name $deploymentName `
    --output json | ConvertFrom-Json | Select-Object name, properties

# Clean up temp file
Remove-Item $secEventsTempFile -Force

Write-Host "[+] Windows Security Events solution deployed successfully"
Write-Host ""

# Configure Security Events collection (All events)
Write-Host "Configuring Security Events collection (All events)..."

# Get access token
$token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$headers = @{"Authorization"="Bearer $token"; "Content-Type"="application/json"}

$dataSourceName = "SecurityInsightsSecurityEventCollectionConfiguration"
$dataSourceUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/dataSources/$dataSourceName`?api-version=2020-08-01"

# Delete existing config if present
try {
    Invoke-RestMethod -Uri $dataSourceUri -Method Get -Headers $headers -ErrorAction SilentlyContinue | Out-Null
    Invoke-RestMethod -Uri $dataSourceUri -Method Delete -Headers $headers -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 5
    Write-Host "Removed existing Security Events configuration"
} catch {}

# Create new configuration for All events
$dataSourceBody = @{
    kind = "SecurityInsightsSecurityEventCollectionConfiguration"
    properties = @{
        tier = "All"
        dataTypes = @{
            securityEvent = @{
                state = "Enabled"
            }
        }
    }
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Uri $dataSourceUri -Method Put -Headers $headers -Body $dataSourceBody | Out-Null
Write-Host "[+] Security Events collection configured (All events)"
Write-Host ""

# Create Data Collection Rule (DCR) for Windows Security Events via AMA
Write-Host "Creating Data Collection Rule for Windows Security Events via AMA..."

$dcrName = "DCR-SecurityEvents-$workspaceName"
$dcrUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Insights/dataCollectionRules/$dcrName`?api-version=2021-09-01-preview"

$workspaceResourceId = "/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName"

$dcrBody = @{
    location = $location
    properties = @{
        dataSources = @{
            windowsEventLogs = @(
                @{
                    name = "eventLogsDataSource"
                    streams = @("Microsoft-SecurityEvent")
                    xPathQueries = @(
                        "Security!*[System[(EventID=4624 or EventID=4625 or EventID=4634 or EventID=4672 or EventID=4720 or EventID=4726 or EventID=4728 or EventID=4732 or EventID=4756)]]"
                    )
                }
            )
        }
        destinations = @{
            logAnalytics = @(
                @{
                    workspaceResourceId = $workspaceResourceId
                    name = "SecurityEventsDestination"
                }
            )
        }
        dataFlows = @(
            @{
                streams = @("Microsoft-SecurityEvent")
                destinations = @("SecurityEventsDestination")
            }
        )
    }
} | ConvertTo-Json -Depth 10

try {
    Invoke-RestMethod -Uri $dcrUri -Method Put -Headers $headers -Body $dcrBody | Out-Null
    Write-Host "[+] Data Collection Rule created: $dcrName"
} catch {
    Write-Host "[INFO] DCR may already exist or will be created when VMs connect"
}

Write-Host ""
Write-Host "Solution includes:"
Write-Host "  - Data connector: SecurityInsightsSecurityEventCollectionConfiguration"
Write-Host "  - Collection tier: All events"
Write-Host "  - Data Collection Rule: $dcrName"
Write-Host "  - Workbooks for Security Event analysis"
Write-Host "  - Parsers for Windows Security Events"
Write-Host ""
Write-Host "Note: Analytics rules can be enabled from Sentinel > Analytics > Rule templates"
