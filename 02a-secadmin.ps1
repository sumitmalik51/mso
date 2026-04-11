param(
    [Parameter(Mandatory=$false)]
    [string]$ParametersFile = ""
)

$ErrorActionPreference = "Continue"

$scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptPath) { $scriptPath = $PWD.Path }

if ([string]::IsNullOrWhiteSpace($ParametersFile)) {
    $ParametersFile = Join-Path $scriptPath "..\parameters.json"
}

Write-Host "Phase 02a: Assign Security Admin Role"

if (!(Test-Path $ParametersFile)) {
    throw "Parameters file not found: $ParametersFile"
}

Write-Host "Loading parameters from: $ParametersFile"
$params = Get-Content $ParametersFile -Raw | ConvertFrom-Json

$tenantId = $params.tenantid
$subscriptionId = $params.subid
$odlUserId = $params.oduserid

if (!$odlUserId) {
    throw "ODL User ID not found in parameters file"
}

Write-Host "Authenticating with Azure CLI..."
az config set core.encrypt_token_cache=false 2>&1 | Out-Null
$currentAccount = (az account show 2>&1) | ConvertFrom-Json
if (-not $currentAccount -or $currentAccount.id -ne $subscriptionId) {
    Write-Host "Logging in with Managed Identity..."
    az login --identity --output none 2>&1 | Out-Null
    az account set --subscription $subscriptionId --output none 2>&1 | Out-Null
}

Write-Host "Authenticated"
Write-Host "ODL User ID: $odlUserId"

# Assign Entra ID "Security Administrator" directory role via Graph API
Write-Host "Assigning Entra ID Security Administrator role..."

$token = (az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>&1) | Where-Object { $_ -notmatch 'WARNING' }
$graphHeaders = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }

# Security Administrator role template ID (well-known)
$secAdminRoleId = "194ae4cb-b126-40b2-bd5b-6091b380977d"

# Check if already assigned
$existingUri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$odlUserId' and roleDefinitionId eq '$secAdminRoleId'"
try {
    $existing = Invoke-RestMethod -Uri $existingUri -Headers $graphHeaders -Method Get -ErrorAction Stop
    if ($existing.value.Count -gt 0) {
        Write-Host "Security Administrator role already assigned in Entra ID"
    } else {
        # Assign the role
        $body = @{
            principalId = $odlUserId
            roleDefinitionId = $secAdminRoleId
            directoryScopeId = "/"
        } | ConvertTo-Json
        
        $assignUri = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments"
        Invoke-RestMethod -Uri $assignUri -Headers $graphHeaders -Method Post -Body $body -ErrorAction Stop | Out-Null
        Write-Host "Security Administrator role assigned in Entra ID"
    }
} catch {
    Write-Host "Error assigning Entra role: $($_.Exception.Message)"
}

$params | Add-Member -NotePropertyName "secadminenabled" -NotePropertyValue "true" -Force
$params | Add-Member -NotePropertyName "secadmindate" -NotePropertyValue (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Force
$params | ConvertTo-Json -Depth 10 | Set-Content $ParametersFile
Write-Host "Parameters file updated"

Write-Host "`nPhase 02a Complete"
