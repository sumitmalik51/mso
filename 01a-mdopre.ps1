param(
    [Parameter(Mandatory=$false)]
    [string]$ParametersFile = ""
)

$ErrorActionPreference = "Continue"

$scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptPath) { $scriptPath = $PWD.Path }
$scriptStartTime = Get-Date

# Resolve parameters file path
if ([string]::IsNullOrWhiteSpace($ParametersFile)) {
    $ParametersFile = Join-Path $scriptPath "..\..\parameters.json"
}

if (-not (Test-Path $ParametersFile)) {
    Write-Host "Parameters file not found: $ParametersFile"
    exit 1
}

$params = Get-Content $ParametersFile | ConvertFrom-Json

$tenantId = $params.tenantid
$orgDomain = $params.odlusername.Split("@")[1]

Write-Host "Phase 05b-01a: Enable MDO Organization Customization (MI)"
Write-Host "Tenant: $tenantId"
Write-Host "Domain: $orgDomain"

# Step 1: Install ExchangeOnlineManagement module
Write-Host "Checking ExchangeOnlineManagement module..."
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Host "Installing ExchangeOnlineManagement module..."
    Install-Module ExchangeOnlineManagement -Force -Scope CurrentUser -ErrorAction Stop 2>&1 | Out-Null
}
Import-Module ExchangeOnlineManagement -ErrorAction Stop

# Step 2: Get VM Managed Identity principal ID and grant Exchange.ManageAsApp
Write-Host "Getting VM Managed Identity info..."

# Get MI object ID from IMDS
$miToken = Invoke-RestMethod -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://graph.microsoft.com" -Headers @{Metadata="true"} -ErrorAction SilentlyContinue
$miClientId = $null
if ($miToken) {
    $miClientId = $miToken.client_id
    Write-Host "MI Client ID: $miClientId"
}

if ($miClientId) {
    # Get MI service principal object ID
    $miSpJson = az ad sp show --id $miClientId -o json 2>&1
    if ($LASTEXITCODE -eq 0) {
        $miSp = $miSpJson | ConvertFrom-Json
        $miSpId = $miSp.id
        Write-Host "MI SP Object ID: $miSpId"

        # Get Exchange Online service principal
        $exoSpJson = az ad sp list --all --filter "appId eq '00000002-0000-0ff1-ce00-000000000000'" --query "[0].id" -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and $exoSpJson) {
            $exoSpId = $exoSpJson.Trim()

            # Grant Exchange.ManageAsApp (dc50a0fb-09a3-484d-be87-e023b12c6440) to MI
            Write-Host "Granting Exchange.ManageAsApp to MI..."
            $roleBody = @{
                principalId = $miSpId
                resourceId  = $exoSpId
                appRoleId   = "dc50a0fb-09a3-484d-be87-e023b12c6440"
            } | ConvertTo-Json -Compress

            $bodyFile = Join-Path $env:TEMP "exo-mi-role.json"
            $roleBody | Set-Content -Path $bodyFile -Encoding UTF8

            $assignResult = az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$miSpId/appRoleAssignments" --body "@$bodyFile" --headers "Content-Type=application/json" 2>&1 | Out-String
            Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue

            if ($assignResult -match "appRoleId") {
                Write-Host "Exchange.ManageAsApp granted to MI"
            } elseif ($assignResult -match "already exists") {
                Write-Host "Exchange.ManageAsApp already assigned to MI"
            } else {
                Write-Host "Role assignment response (may need time to propagate)"
            }
            # Wait for permission propagation
            Write-Host "Waiting 30s for permission propagation..."
            Start-Sleep -Seconds 30
        }
    }
}

# Step 3: Connect to Exchange Online using Managed Identity
Write-Host "Connecting to Exchange Online via Managed Identity..."
$status = "unknown"
$connected = $false

# Try MI connection
try {
    Connect-ExchangeOnline -ManagedIdentity -Organization $orgDomain -ShowBanner:$false -ErrorAction Stop
    Write-Host "Connected via Managed Identity"
    $connected = $true
} catch {
    Write-Host "MI connection failed: $($_.Exception.Message)"
    # Fallback: try getting token via MI and using AccessToken param
    Write-Host "Trying token-based fallback..."
    try {
        $tokenResp = Invoke-RestMethod -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://outlook.office365.com" -Headers @{Metadata="true"}
        $accessToken = $tokenResp.access_token
        Connect-ExchangeOnline -AccessToken $accessToken -Organization $orgDomain -ShowBanner:$false -ErrorAction Stop
        Write-Host "Connected via MI token fallback"
        $connected = $true
    } catch {
        Write-Host "Token fallback also failed: $($_.Exception.Message)"
        # Last resort: try SPN if available
        $spnAppId = $params.spnclientid
        $spnSecret = $params.spnsecret
        if (-not [string]::IsNullOrWhiteSpace($spnAppId) -and -not [string]::IsNullOrWhiteSpace($spnSecret)) {
            Write-Host "Trying SPN fallback..."
            try {
                $tokenBody = @{
                    grant_type    = "client_credentials"
                    client_id     = $spnAppId
                    client_secret = $spnSecret
                    scope         = "https://outlook.office365.com/.default"
                }
                $tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
                $tokenResp = Invoke-RestMethod -Uri $tokenUrl -Method POST -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
                Connect-ExchangeOnline -AccessToken $tokenResp.access_token -Organization $orgDomain -ShowBanner:$false -ErrorAction Stop
                Write-Host "Connected via SPN fallback"
                $connected = $true
            } catch {
                Write-Host "SPN fallback failed: $($_.Exception.Message)"
            }
        }
    }
}

if ($connected) {
    try {
        # Check and enable organization customization
        $org = Get-OrganizationConfig
        Write-Host "IsDehydrated: $($org.IsDehydrated)"

        if ($org.IsDehydrated) {
            Write-Host "Enabling Organization Customization..."
            Enable-OrganizationCustomization
            Write-Host "Organization Customization enabled"
            $status = "enabled"
        } else {
            Write-Host "Organization already hydrated"
            $status = "ready"
        }

        Disconnect-ExchangeOnline -Confirm:$false
    } catch {
        Write-Host "EXO operation failed: $($_.Exception.Message)"
        $status = "failed"
    }
} else {
    Write-Host "Could not connect to Exchange Online with any method"
    $status = "failed"
}

# Update parameters.json
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$params | Add-Member -NotePropertyName "mdocustomizationenabled" -NotePropertyValue $status -Force
$params | Add-Member -NotePropertyName "mdocustomizationdate" -NotePropertyValue $timestamp -Force
$params | ConvertTo-Json -Depth 5 | Set-Content $ParametersFile

Write-Host "Updated parameters.json: mdocustomizationenabled=$status"
$duration = (Get-Date) - $scriptStartTime
Write-Host "Duration: $($duration.ToString('hh\:mm\:ss'))"
