# Load parameters
$ErrorActionPreference = "Continue"

$scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptPath) { $scriptPath = $PWD.Path }

$params = Get-Content (Join-Path $scriptPath "..\parameters.json") | ConvertFrom-Json
$rgName = $params.resourcegroupname
$workspaceName = $params.workspacename
$subscriptionId = $params.subid
$tenantId = $params.tenantid
$workspaceId = $params.workspaceid

# Authenticate with Managed Identity
az config set core.encrypt_token_cache=false 2>&1 | Out-Null
$currentAccount = (az account show 2>&1) | ConvertFrom-Json
if (-not $currentAccount -or $currentAccount.id -ne $subscriptionId) {
    Write-Host "Logging in with Managed Identity..."
    az login --identity --output none 2>&1 | Out-Null
    az account set --subscription $subscriptionId --output none 2>&1 | Out-Null
}

# Get tenantId from az CLI if not in parameters
if (-not $tenantId) {
    $tenantId = az account show --query tenantId -o tsv 2>$null
}

Write-Host "Enabling Threat Intelligence Data Connectors..."
Write-Host "  Resource Group: $rgName"
Write-Host "  Workspace: $workspaceName"
Write-Host "  Tenant: $tenantId"
Write-Host ""

try {
    $token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    if (-not $token) {
        throw "Failed to get access token"
    }
    
    $headers = @{"Authorization"="Bearer $token"; "Content-Type"="application/json"}
    
    $enabled = 0
    $skipped = 0
    $failed = 0
    
    $baseUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/providers/Microsoft.SecurityInsights/dataConnectors"
    $baseWs = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/providers/Microsoft.SecurityInsights"
    
    # Install Threat Intelligence (NEW) Content Hub solution if not installed
    Write-Host "[Pre] Installing Threat Intelligence (NEW) Content Hub solution..."
    $installedUri = "$baseWs/contentPackages?api-version=2024-01-01-preview"
    $installed = (Invoke-RestMethod -Uri $installedUri -Headers $headers -Method Get -ErrorAction Stop).value
    $tiInstalled = $installed | Where-Object { $_.properties.displayName -eq 'Threat Intelligence (NEW)' }
    
    if ($tiInstalled) {
        Write-Host "  [SKIP] Already installed v$($tiInstalled.properties.version)"
    } else {
        # Find the product package
        $productPkgsUri = "$baseWs/contentProductPackages?api-version=2024-01-01-preview"
        $allPkgs = @()
        $pkgResp = Invoke-RestMethod -Uri $productPkgsUri -Headers $headers -Method Get -ErrorAction Stop
        $allPkgs += $pkgResp.value
        while ($pkgResp.nextLink) {
            $pkgResp = Invoke-RestMethod -Uri $pkgResp.nextLink -Headers $headers -Method Get -ErrorAction Stop
            $allPkgs += $pkgResp.value
        }
        $tiPkg = $allPkgs | Where-Object { $_.properties.displayName -eq 'Threat Intelligence (NEW)' }
        
        if ($tiPkg) {
            $installUri = "$baseWs/contentPackages/$($tiPkg.properties.contentId)?api-version=2024-01-01-preview"
            $installBody = @{
                properties = @{
                    contentId = $tiPkg.properties.contentId
                    displayName = $tiPkg.properties.displayName
                    contentKind = "Solution"
                    version = $tiPkg.properties.version
                    contentSchemaVersion = "3.0.0"
                    contentProductId = $tiPkg.properties.contentId
                    firstPublishDate = $tiPkg.properties.firstPublishDate
                    providers = $tiPkg.properties.providers
                    source = $tiPkg.properties.source
                    author = $tiPkg.properties.author
                    support = $tiPkg.properties.support
                }
            } | ConvertTo-Json -Depth 10
            
            try {
                Invoke-RestMethod -Uri $installUri -Headers $headers -Method Put -Body $installBody -ErrorAction Stop | Out-Null
                Write-Host "  [OK] Installed Threat Intelligence (NEW) v$($tiPkg.properties.version)"
            } catch {
                Write-Host "  [WARN] Could not install from Content Hub: $($_.ErrorDetails.Message)"
            }
        } else {
            Write-Host "  [WARN] Package not found in Content Hub catalog"
        }
    }
    Write-Host ""
    
    # Check existing connectors
    $existingKinds = @()
    try {
        $listUri = "$baseUri`?api-version=2024-01-01-preview"
        $existingConnectors = (Invoke-RestMethod -Uri $listUri -Headers $headers -Method Get -ErrorAction Stop).value
        $existingKinds = $existingConnectors | ForEach-Object { $_.kind }
    } catch { }
    
    # 1. Microsoft Defender Threat Intelligence (requires preview API)
    Write-Host "[1/3] Microsoft Defender Threat Intelligence..."
    if ($existingKinds -contains "MicrosoftThreatIntelligence") {
        Write-Host "  [SKIP] Already connected"
        $skipped++
    } else {
        $connectorId = [guid]::NewGuid().ToString()
        $connectorUri = "$baseUri/$($connectorId)?api-version=2024-01-01-preview"
        
        $body = @{
            kind = "MicrosoftThreatIntelligence"
            properties = @{
                tenantId = $tenantId
                dataTypes = @{
                    microsoftEmergingThreatFeed = @{
                        state = "Enabled"
                        lookbackPeriod = "1970-01-01T00:00:00.000Z"
                    }
                    bingSafetyPhishingURL = @{
                        state = "Enabled"
                        lookbackPeriod = "1970-01-01T00:00:00.000Z"
                    }
                }
            }
        } | ConvertTo-Json -Depth 10
        
        try {
            Invoke-RestMethod -Uri $connectorUri -Headers $headers -Method Put -Body $body -ErrorAction Stop | Out-Null
            Write-Host "  [OK]"
            $enabled++
        } catch {
            $errDetail = $_.ErrorDetails.Message
            if ($errDetail -match "same kind|already exists|duplicate") {
                Write-Host "  [SKIP] Already connected"
                $skipped++
            } else {
                $errMsg = if ($errDetail) { try { ($errDetail | ConvertFrom-Json).error.message } catch { $errDetail } } else { $_.Exception.Message }
                Write-Host "  [FAIL] $errMsg"
                $failed++
            }
        }
    }
    
    # 2. Threat Intelligence Platforms (TIP)
    Write-Host "[2/3] Threat Intelligence Platforms..."
    if ($existingKinds -contains "ThreatIntelligence") {
        Write-Host "  [SKIP] Already connected"
        $skipped++
    } else {
        $connectorId = [guid]::NewGuid().ToString()
        $connectorUri = "$baseUri/$($connectorId)?api-version=2023-02-01"
        
        $body = @{
            kind = "ThreatIntelligence"
            properties = @{
                tenantId = $tenantId
                dataTypes = @{
                    indicators = @{
                        state = "Enabled"
                    }
                }
            }
        } | ConvertTo-Json -Depth 10
        
        try {
            Invoke-RestMethod -Uri $connectorUri -Headers $headers -Method Put -Body $body -ErrorAction Stop | Out-Null
            Write-Host "  [OK]"
            $enabled++
        } catch {
            $errDetail = $_.ErrorDetails.Message
            if ($errDetail -match "same kind|already exists|duplicate") {
                Write-Host "  [SKIP] Already connected"
                $skipped++
            } else {
                $errMsg = if ($errDetail) { try { ($errDetail | ConvertFrom-Json).error.message } catch { $errDetail } } else { $_.Exception.Message }
                Write-Host "  [FAIL] $errMsg"
                $failed++
            }
        }
    }
    
    # 3. Threat Intelligence - TAXII (MITRE ATT&CK)
    Write-Host "[3/3] Threat Intelligence - TAXII..."
    if ($existingKinds -contains "ThreatIntelligenceTaxii") {
        Write-Host "  [SKIP] Already connected"
        $skipped++
    } else {
        $connectorId = [guid]::NewGuid().ToString()
        $connectorUri = "$baseUri/$($connectorId)?api-version=2024-01-01-preview"
        
        $body = @{
            kind = "ThreatIntelligenceTaxii"
            properties = @{
                tenantId = $tenantId
                workspaceId = $workspaceId
                friendlyName = "MITRE ATT&CK"
                taxiiServer = "https://cti-taxii.mitre.org/taxii/"
                collectionId = "95ecc380-afe9-11e4-9b6c-751b66dd541e"
                userName = ""
                password = ""
                taxiiLookbackPeriod = "1970-01-01T00:00:00.000Z"
                pollingFrequency = "OnceADay"
                dataTypes = @{
                    taxiiClient = @{
                        state = "Enabled"
                    }
                }
            }
        } | ConvertTo-Json -Depth 10
        
        try {
            Invoke-RestMethod -Uri $connectorUri -Headers $headers -Method Put -Body $body -ErrorAction Stop | Out-Null
            Write-Host "  [OK] Connected to MITRE ATT&CK TAXII feed"
            $enabled++
        } catch {
            $errDetail = $_.ErrorDetails.Message
            if ($errDetail -match "same kind|already exists|duplicate") {
                Write-Host "  [SKIP] Already connected"
                $skipped++
            } elseif ($errDetail -match "Timed out") {
                Write-Host "  [WARN] TAXII server unreachable (external network issue)"
                $failed++
            } else {
                $errMsg = if ($errDetail) { try { ($errDetail | ConvertFrom-Json).error.message } catch { $errDetail } } else { $_.Exception.Message }
                Write-Host "  [FAIL] $errMsg"
                $failed++
            }
        }
    }
    
    Write-Host ""
    Write-Host "============================================"
    Write-Host "Data Connector Summary"
    Write-Host "============================================"
    Write-Host "  Enabled: $enabled"
    Write-Host "  Skipped (already connected): $skipped"
    Write-Host "  Failed: $failed"
    Write-Host ""
    
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    exit 1
}
