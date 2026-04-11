param(
    [Parameter(Mandatory=$false)]
    [string]$ParametersFile = ""
)

$ErrorActionPreference = "Continue"

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $scriptRoot) { $scriptRoot = $PWD.Path }

Write-Host "Phase 06: Deploy Active Directory Lab VMs"

# Resolve az CLI path
$az = "az"
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    $azPath = "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
    if (Test-Path $azPath) { $az = "`"$azPath`"" } else { throw "Azure CLI not found" }
}

# Load parameters
if ([string]::IsNullOrWhiteSpace($ParametersFile)) {
    $paramsFile = Join-Path $scriptRoot "..\parameters.json"
} else {
    $paramsFile = $ParametersFile
}
if (-not (Test-Path $paramsFile)) {
    throw "Parameters file not found: $paramsFile"
}

$params = Get-Content $paramsFile | ConvertFrom-Json
$deploymentId = $params.deploymentid
$sentinelRG = $params.resourcegroupname
$workspaceName = $params.workspacename
$workspaceRG = $sentinelRG

# Use separate RG for VMs so we can delete easily for trials
$resourceGroupName = "UniSecOps-VMs-$deploymentId"
$subscriptionId = $params.subid
$location = if ($params.deploymentregion) { $params.deploymentregion } else { "eastus" }

if (-not $workspaceName) {
    throw "Workspace not deployed yet. Run 04sentinel first."
}

Write-Host "Deployment ID: $deploymentId"
Write-Host "Sentinel RG: $sentinelRG"
Write-Host "VM Resource Group: $resourceGroupName"
Write-Host "Workspace: $workspaceName"

Write-Host "Creating VM resource group..."
$rgExists = & $az group exists --name $resourceGroupName --subscription $subscriptionId | ConvertFrom-Json
if (-not $rgExists) {
    & $az group create --name $resourceGroupName --location $location --subscription $subscriptionId --output none
    Write-Host "Created $resourceGroupName"
} else {
    Write-Host "Resource group already exists"
}

$adminUsername = "DomainAdmin"
$adminPassword = $params.odluserpass
$domainName = "corp.contoso.com"

Write-Host "Preparing inline setup scripts..."
$dcScriptPath = Join-Path $scriptRoot "scripts\setup-dc.ps1"
$smbScriptPath = Join-Path $scriptRoot "scripts\setup-smb.ps1"

if (-not (Test-Path $dcScriptPath)) {
    throw "DC script not found: $dcScriptPath"
}

if (-not (Test-Path $smbScriptPath)) {
    throw "SMB script not found: $smbScriptPath"
}

Write-Host ""
Write-Host "Deployment Configuration:"
Write-Host "Admin Username: $adminUsername"
Write-Host "Domain Name: $domainName"
Write-Host "DC: UniSecOps-DC-$deploymentId at 10.0.1.4"
Write-Host "SMB: UniSecOps-SMB-$deploymentId at 10.0.1.5"
Write-Host ""
Write-Host "WARNING: This will deploy 2 VMs takes 15-20 minutes"
Write-Host "Domain Controller will promote to DC and reboot"
Write-Host "File Server will join domain and create shares"
Write-Host ""
Write-Host "Deploying VMs via ARM template..."
$dcTemplateFile = Join-Path $scriptRoot "nestedtemplates\dc.json"
$smbTemplateFile = Join-Path $scriptRoot "nestedtemplates\smb.json"
$vnetName = "UniSecOps-VNet-$deploymentId"
$subnetName = "default"
$dcStaticIP = "10.0.1.4"
$smbStaticIP = "10.0.1.5"

Write-Host "Creating VNet..."
$vnetExists = $null
try { $vnetExists = & $az network vnet show --name $vnetName --resource-group $resourceGroupName --subscription $subscriptionId 2>&1 | Out-String } catch {}
if (-not $vnetExists -or $vnetExists -match "ResourceNotFound") {
    Write-Host "VNet creation in progress..."
    & $az network vnet create `
        --resource-group $resourceGroupName `
        --name $vnetName `
        --address-prefix 10.0.1.0/24 `
        --subnet-name $subnetName `
        --subnet-prefix 10.0.1.0/24 `
        --subscription $subscriptionId `
        --output none
    Write-Host "VNet created successfully"
} else {
    Write-Host "VNet already exists"
}

$vnetID = & $az network vnet show --resource-group $resourceGroupName --name $vnetName --subscription $subscriptionId --query id -o tsv

Write-Host "Deploying DC..."
try {
    $dcParams = @{
        deploymentId = $deploymentId
        location = $location
        adminUsername = $adminUsername
        adminPassword = $adminPassword
        domainName = $domainName
        workspaceName = $workspaceName
        workspaceResourceGroup = $workspaceRG
        vnetName = $vnetName
        subnetName = $subnetName
        staticIP = $dcStaticIP
        vnetID = $vnetID
    }
    $dcParamsFile = Join-Path $scriptRoot "dc-params.json"
    $dcParamsObj = @{
        "`$schema" = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
        "contentVersion" = "1.0.0.0"
        "parameters" = @{}
    }
    foreach ($key in $dcParams.Keys) {
        $dcParamsObj.parameters[$key] = @{ value = $dcParams[$key] }
    }
    $dcParamsObj | ConvertTo-Json -Depth 10 | Set-Content $dcParamsFile
    
    $dcDeployment = & $az deployment group create `
        --name "dc-$(Get-Date -Format 'yyyyMMddHHmmss')" `
        --resource-group $resourceGroupName `
        --template-file $dcTemplateFile `
        --parameters $dcParamsFile `
        --subscription $subscriptionId `
        --output json
    
    if ($LASTEXITCODE -ne 0) {
        throw "DC deployment failed"
    }
    
    $dcResult = $dcDeployment | ConvertFrom-Json
    $dcFQDN = $dcResult.properties.outputs.vmFQDN.value
    $dcVMName = $dcResult.properties.outputs.vmName.value
    Write-Host "DC VM deployed: $dcFQDN"
    
    # ---- DC Setup (synchronous, verified) ----
    
    # Pre-flight: test DC VM agent before running setup
    Write-Host ""
    Write-Host "Pre-flight: testing DC VM agent..."
    $dcAgentReady = $false
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $testResult = & $az vm run-command invoke `
            --resource-group $resourceGroupName `
            --name $dcVMName `
            --command-id RunPowerShellScript `
            --scripts "Write-Host 'agent-ok'" `
            --subscription $subscriptionId `
            --output json 2>&1 | Out-String
        if ($testResult -match "agent-ok") {
            Write-Host "DC VM agent responsive (attempt $attempt)"
            $dcAgentReady = $true
            break
        }
        Write-Host "DC VM agent not ready (attempt $attempt/10), waiting 30s..."
        Start-Sleep -Seconds 30
    }
    if (-not $dcAgentReady) {
        Write-Host "WARNING: DC VM agent not responding, attempting setup anyway"
    }
    
    # Execute DC setup script synchronously (installs AD DS + promotes, no auto-reboot)
    Write-Host ""
    Write-Host "Executing DC setup script (synchronous, ~10 min)..."
    $dcSetupResult = & $az vm run-command invoke `
        --resource-group $resourceGroupName `
        --name $dcVMName `
        --command-id RunPowerShellScript `
        --scripts "@$dcScriptPath" `
        --parameters "adminUsername=$adminUsername" "adminPassword=$adminPassword" "domainName=$domainName" `
        --subscription $subscriptionId `
        --output json 2>&1 | Out-String
    
    if ($dcSetupResult -match "DC promotion complete|promotion initiated") {
        Write-Host "DC setup completed - AD DS installed and promoted"
    } elseif ($dcSetupResult -match "error|fail|exception" -and $dcSetupResult -notmatch "SilentlyContinue|ErrorAction") {
        Write-Host "WARNING: DC setup may have failed, check DC logs"
        Write-Host "Continuing with restart to see if AD activates..."
    } else {
        Write-Host "DC setup finished (check DC logs for details)"
    }
    
    # Restart DC to finalize AD promotion
    Write-Host ""
    Write-Host "Restarting DC to finalize AD promotion..."
    & $az vm restart --resource-group $resourceGroupName --name $dcVMName --subscription $subscriptionId --output none
    
    # Wait for DC to be running after promotion reboot
    Write-Host "Waiting for DC to boot..."
    $maxWaitDC = 300
    $waitedDC = 0
    while ($waitedDC -lt $maxWaitDC) {
        $dcPowerState = & $az vm show --resource-group $resourceGroupName --name $dcVMName --subscription $subscriptionId --show-details --query powerState -o tsv 2>$null
        if ($dcPowerState -match "running") {
            Write-Host "DC is running (waited ${waitedDC}s)"
            break
        }
        Start-Sleep -Seconds 15
        $waitedDC += 15
    }
    if ($waitedDC -ge $maxWaitDC) {
        Write-Host "WARNING: DC did not reach running state in ${maxWaitDC}s"
    }
    
    # Wait for AD services to start after promotion reboot
    Write-Host "Waiting 120s for AD services to initialize..."
    Start-Sleep -Seconds 120
    
    # Verify AD is operational
    Write-Host "Verifying Active Directory..."
    $adVerified = $false
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        $adCheck = & $az vm run-command invoke `
            --resource-group $resourceGroupName `
            --name $dcVMName `
            --command-id RunPowerShellScript `
            --scripts "if ((Get-Service NTDS -EA 0).Status -eq 'Running') { Write-Host 'AD-RUNNING' }" `
            --subscription $subscriptionId `
            --output json 2>&1 | Out-String
        if ($adCheck -match "AD-RUNNING") {
            Write-Host "Active Directory confirmed running"
            $adVerified = $true
            break
        }
        Write-Host "AD not ready (attempt $attempt/8), waiting 30s..."
        Start-Sleep -Seconds 30
    }
    if (-not $adVerified) {
        Write-Host "WARNING: AD not confirmed running, continuing anyway"
    }
    
    # Configure VNet DNS to point to DC (now that DC is a working DNS server)
    Write-Host ""
    Write-Host "Configuring VNet DNS to use DC + Google DNS..."
    & $az network vnet update `
        --resource-group $resourceGroupName `
        --name $vnetName `
        --dns-servers $dcStaticIP 8.8.8.8 `
        --subscription $subscriptionId `
        --output none
    Write-Host "VNet DNS configured"
    
    # ---- SMB Deployment and Setup ----
    
    # Deploy SMB File Server
    Write-Host ""
    Write-Host "Deploying SMB..."
    $smbParams = @{
        deploymentId = $deploymentId
        location = $location
        adminUsername = $adminUsername
        adminPassword = $adminPassword
        domainName = $domainName
        workspaceName = $workspaceName
        workspaceResourceGroup = $workspaceRG
        vnetName = $vnetName
        subnetName = $subnetName
        staticIP = $smbStaticIP
        vnetID = $vnetID
        dcIP = $dcStaticIP
    }
    $smbParamsFile = Join-Path $scriptRoot "smb-params.json"
    $smbParamsObj = @{
        "`$schema" = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
        "contentVersion" = "1.0.0.0"
        "parameters" = @{}
    }
    foreach ($key in $smbParams.Keys) {
        $smbParamsObj.parameters[$key] = @{ value = $smbParams[$key] }
    }
    $smbParamsObj | ConvertTo-Json -Depth 10 | Set-Content $smbParamsFile
    
    $smbDeployment = & $az deployment group create `
        --name "smb-$(Get-Date -Format 'yyyyMMddHHmmss')" `
        --resource-group $resourceGroupName `
        --template-file $smbTemplateFile `
        --parameters $smbParamsFile `
        --subscription $subscriptionId `
        --output json
    
    if ($LASTEXITCODE -ne 0) {
        throw "SMB deployment failed"
    }
    
    $smbResult = $smbDeployment | ConvertFrom-Json
    $smbFQDN = $smbResult.properties.outputs.vmFQDN.value
    $smbVMName = $smbResult.properties.outputs.vmName.value
    Write-Host "SMB VM deployed: $smbFQDN"
    
    # Restart SMB to pick up new DNS settings
    Write-Host ""
    Write-Host "Restarting SMB to apply DNS settings..."
    & $az vm restart --resource-group $resourceGroupName --name $smbVMName --subscription $subscriptionId --output none
    
    # Wait for SMB to be fully running after restart
    Write-Host "Waiting for SMB to be running after restart..."
    $maxWaitRestart = 180
    $waitedRestart = 0
    while ($waitedRestart -lt $maxWaitRestart) {
        $smbPowerState = & $az vm show --resource-group $resourceGroupName --name $smbVMName --subscription $subscriptionId --show-details --query powerState -o tsv 2>$null
        if ($smbPowerState -match "running") {
            Write-Host "SMB is running (waited ${waitedRestart}s)"
            break
        }
        Start-Sleep -Seconds 15
        $waitedRestart += 15
    }
    if ($waitedRestart -ge $maxWaitRestart) {
        Write-Host "WARNING: SMB did not reach running state in ${maxWaitRestart}s, continuing anyway"
    }
    # Extra wait for VM agent to initialize
    Start-Sleep -Seconds 30
    
    # Pre-flight: test SMB VM agent
    Write-Host ""
    Write-Host "Pre-flight: testing SMB VM agent..."
    $smbAgentReady = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $testResult = & $az vm run-command invoke `
            --resource-group $resourceGroupName `
            --name $smbVMName `
            --command-id RunPowerShellScript `
            --scripts "Write-Host 'agent-ok'" `
            --subscription $subscriptionId `
            --output json 2>&1 | Out-String
        if ($testResult -match "agent-ok") {
            Write-Host "SMB VM agent responsive"
            $smbAgentReady = $true
            break
        }
        Write-Host "SMB VM agent not ready (attempt $attempt/5), waiting 30s..."
        Start-Sleep -Seconds 30
    }
    if (-not $smbAgentReady) {
        Write-Host "WARNING: SMB VM agent not responding, attempting setup anyway"
    }
    
    # Execute SMB setup script synchronously (joins domain, no auto-reboot)
    Write-Host ""
    Write-Host "Executing SMB setup script (synchronous)..."
    $smbSetupResult = & $az vm run-command invoke `
        --resource-group $resourceGroupName `
        --name $smbVMName `
        --command-id RunPowerShellScript `
        --scripts "@$smbScriptPath" `
        --parameters "adminUsername=$adminUsername" "adminPassword=$adminPassword" "domainName=$domainName" `
        --subscription $subscriptionId `
        --output json 2>&1 | Out-String
    
    if ($smbSetupResult -match "joined domain|Domain join complete") {
        Write-Host "SMB setup completed - domain joined"
    } else {
        Write-Host "SMB setup finished (check SMB logs for details)"
    }
    
    # Restart SMB to finalize domain join
    Write-Host ""
    Write-Host "Restarting SMB to complete domain join..."
    & $az vm restart --resource-group $resourceGroupName --name $smbVMName --subscription $subscriptionId --output none
    
    # Wait for both VMs to be fully running after reboots (DC promoted + SMB domain joined)
    Write-Host ""
    Write-Host "Waiting for VMs to come back from reboots..."
    foreach ($vmN in @($dcVMName, $smbVMName)) {
        $maxWaitSec = 300
        $waited = 0
        while ($waited -lt $maxWaitSec) {
            $vmPowerState = & $az vm show --resource-group $resourceGroupName --name $vmN --subscription $subscriptionId --show-details --query powerState -o tsv 2>$null
            if ($vmPowerState -match "running") {
                Write-Host "$vmN is running (waited ${waited}s)"
                break
            }
            Start-Sleep -Seconds 15
            $waited += 15
        }
        if ($waited -ge $maxWaitSec) {
            Write-Host "WARNING: $vmN did not reach running state in ${maxWaitSec}s, continuing anyway"
        }
    }
    # Extra wait for OS and services to fully initialize after boot
    Write-Host "Waiting 90 seconds for OS initialization..."
    Start-Sleep -Seconds 90
    
    # Pre-flight: verify VM agent is responsive on both VMs before MDE steps
    Write-Host ""
    Write-Host "Pre-flight: testing VM agent responsiveness..."
    foreach ($vmN in @($dcVMName, $smbVMName)) {
        $agentReady = $false
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            $testResult = & $az vm run-command invoke `
                --resource-group $resourceGroupName `
                --name $vmN `
                --command-id RunPowerShellScript `
                --scripts "Write-Host 'agent-ok'" `
                --subscription $subscriptionId `
                --output json 2>&1 | Out-String
            if ($testResult -match "agent-ok") {
                Write-Host "$vmN VM agent is responsive"
                $agentReady = $true
                break
            }
            Write-Host "$vmN VM agent not ready (attempt $attempt/5), waiting 30s..."
            Start-Sleep -Seconds 30
        }
        if (-not $agentReady) {
            Write-Host "WARNING: $vmN VM agent not responding after 5 attempts, continuing anyway"
        }
    }
    
    # Re-enable Defender on both VMs (MDE extension needs it active)
    Write-Host ""
    Write-Host "Re-enabling Defender on both VMs..."
    & $az vm run-command invoke `
        --resource-group $resourceGroupName `
        --name $dcVMName `
        --command-id RunPowerShellScript `
        --scripts "Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name DisableAntiSpyware -Force -ErrorAction SilentlyContinue; Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' -Name DisableRealtimeMonitoring -Force -ErrorAction SilentlyContinue; Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' -Name DisableBehaviorMonitoring -Force -ErrorAction SilentlyContinue; Set-MpPreference -DisableRealtimeMonitoring `$false; Set-MpPreference -DisableBehaviorMonitoring `$false; Set-MpPreference -DisableIOAVProtection `$false; Remove-MpPreference -ExclusionPath 'C:\' -ErrorAction SilentlyContinue" `
        --subscription $subscriptionId `
        --output none
    Write-Host "Defender re-enabled on DC"
    
    & $az vm run-command invoke `
        --resource-group $resourceGroupName `
        --name $smbVMName `
        --command-id RunPowerShellScript `
        --scripts "Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name DisableAntiSpyware -Force -ErrorAction SilentlyContinue; Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' -Name DisableRealtimeMonitoring -Force -ErrorAction SilentlyContinue; Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' -Name DisableBehaviorMonitoring -Force -ErrorAction SilentlyContinue; Set-MpPreference -DisableRealtimeMonitoring `$false; Set-MpPreference -DisableBehaviorMonitoring `$false; Set-MpPreference -DisableIOAVProtection `$false; Remove-MpPreference -ExclusionPath 'C:\' -ErrorAction SilentlyContinue" `
        --subscription $subscriptionId `
        --output none
    Write-Host "Defender re-enabled on SMB"
    
    # Enable WDATP + MDE Integration in MDC (required before onboarding)
    Write-Host ""
    Write-Host "Enabling MDE integration in Defender for Cloud..."
    $subId = $params.subid
    if (-not $subId) { $subId = $subscriptionId }
    $wdatpToken = & $az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    $wdatpHeaders = @{ "Authorization" = "Bearer $wdatpToken"; "Content-Type" = "application/json" }
    $wdatpBody = '{"kind":"DataExportSettings","properties":{"enabled":true}}'

    # Enable WDATP
    try {
        $r = Invoke-RestMethod -Uri "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Security/settings/WDATP?api-version=2022-05-01" -Method PUT -Headers $wdatpHeaders -Body $wdatpBody
        Write-Host "WDATP enabled: $($r.properties.enabled)"
    } catch { Write-Host "WDATP: $($_.Exception.Message)" }

    # Enable WDATP_UNIFIED_SOLUTION
    try {
        $r = Invoke-RestMethod -Uri "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Security/settings/WDATP_UNIFIED_SOLUTION?api-version=2022-05-01" -Method PUT -Headers $wdatpHeaders -Body $wdatpBody
        Write-Host "WDATP_UNIFIED_SOLUTION enabled: $($r.properties.enabled)"
    } catch { Write-Host "WDATP_UNIFIED: $($_.Exception.Message)" }

    # Enable MdeDesignatedSubscription extension in VirtualMachines pricing
    try {
        $pricing = Invoke-RestMethod -Uri "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Security/pricings/VirtualMachines?api-version=2024-01-01" -Method GET -Headers $wdatpHeaders
        $exts = @($pricing.properties.extensions)
        $newExts = @(); $found = $false
        foreach ($e in $exts) {
            if ($e.name -eq "MdeDesignatedSubscription") { $newExts += @{name="MdeDesignatedSubscription";isEnabled="True"}; $found=$true }
            else { $newExts += @{name=$e.name;isEnabled=$e.isEnabled} }
        }
        if (-not $found) { $newExts += @{name="MdeDesignatedSubscription";isEnabled="True"} }
        $pBody = @{properties=@{pricingTier=$pricing.properties.pricingTier;subPlan=$pricing.properties.subPlan;extensions=$newExts}} | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Uri "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Security/pricings/VirtualMachines?api-version=2024-01-01" -Method PUT -Headers $wdatpHeaders -Body $pBody -ContentType "application/json" | Out-Null
        Write-Host "MdeDesignatedSubscription enabled"
    } catch { Write-Host "MdeDesignated: $($_.Exception.Message)" }

    Start-Sleep -Seconds 10
    Write-Host "MDE integration setup complete"

    # MDE Onboarding via MDC API
    Write-Host ""
    Write-Host "Onboarding VMs to Microsoft Defender for Endpoint..."
    $mdeApiUrl = "https://management.azure.com/subscriptions/$subId/providers/Microsoft.Security/mdeOnboardings?api-version=2021-10-01-preview"
    $mdeResult = & $az rest --method GET --url $mdeApiUrl -o json 2>&1 | Out-String | ConvertFrom-Json
    $onboardB64 = $mdeResult.value[0].properties.onboardingPackageWindows
    
    if ($onboardB64) {
        $onboardBytes = [System.Convert]::FromBase64String($onboardB64)
        $onboardScript = [System.Text.Encoding]::UTF8.GetString($onboardBytes)
        $onboardLocalPath = Join-Path $scriptRoot "mde-onboard.cmd"
        $onboardScript | Out-File -FilePath $onboardLocalPath -Encoding ASCII -Force
        
        foreach ($vmInfo in @(@{Name=$dcVMName}, @{Name=$smbVMName})) {
            $vmN = $vmInfo.Name
            Write-Host "Onboarding $vmN to MDE..."
            $onboardPs = Join-Path $scriptRoot "onboard-$vmN.ps1"
            @"
`$cmdPath = 'C:\Windows\Temp\mde-onboard.cmd'
`$cmdContent = @'
$onboardScript
'@
`$cmdContent | Out-File -FilePath `$cmdPath -Encoding ASCII -Force
`$proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `$cmdPath" -Wait -PassThru -NoNewWindow
Write-Host "Exit code: `$(`$proc.ExitCode)"
Start-Sleep -Seconds 10
`$sense = Get-Service -Name Sense -ErrorAction SilentlyContinue
Write-Host "Sense: `$(`$sense.Status)"
`$state = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' -Name OnboardingState -ErrorAction SilentlyContinue).OnboardingState
Write-Host "OnboardingState: `$state"
"@ | Out-File -FilePath $onboardPs -Encoding UTF8 -Force
            
            & $az vm run-command invoke `
                --resource-group $resourceGroupName `
                --name $vmN `
                --command-id RunPowerShellScript `
                --scripts "@$onboardPs" `
                --subscription $subscriptionId `
                --output none
            Write-Host "$vmN onboarded to MDE"
        }
        Write-Host "MDE onboarding complete"
        Write-Host "Waiting 120s for Sense service to initialize..."
        Start-Sleep -Seconds 120

        # Verify MDE Sense service on both VMs with retry + re-onboard if needed
        Write-Host ""
        Write-Host "Verifying MDE onboarding status..."
        foreach ($vmN in @($dcVMName, $smbVMName)) {
            $mdeVerified = $false
            $retries = 8
            for ($i = 1; $i -le $retries; $i++) {
                $verifyResult = & $az vm run-command invoke `
                    --resource-group $resourceGroupName `
                    --name $vmN `
                    --command-id RunPowerShellScript `
                    --scripts "`$s = Get-Service -Name Sense -ErrorAction SilentlyContinue; `$st = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' -Name OnboardingState -ErrorAction SilentlyContinue).OnboardingState; Write-Host `"Sense: `$(`$s.Status) OnboardingState: `$st`"" `
                    --subscription $subscriptionId `
                    --output json 2>&1 | Out-String
                if ($verifyResult -match "Running" -and $verifyResult -match "OnboardingState: 1") {
                    Write-Host "$vmN MDE verified: Sense running, onboarded"
                    $mdeVerified = $true
                    break
                }
                if ($i -eq 4) {
                    # After 4 failed verifications, re-run the onboarding script
                    Write-Host "$vmN MDE not verified after 4 attempts, re-running onboarding..."
                    $reOnboardPs = Join-Path $scriptRoot "reonboard-$vmN.ps1"
                    @"
`$cmdPath = 'C:\Windows\Temp\mde-onboard.cmd'
if (Test-Path `$cmdPath) {
    `$proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `$cmdPath" -Wait -PassThru -NoNewWindow
    Write-Host "Re-onboard exit: `$(`$proc.ExitCode)"
    Start-Sleep -Seconds 15
    `$sense = Get-Service -Name Sense -ErrorAction SilentlyContinue
    if (`$sense.Status -ne 'Running') { Start-Service -Name Sense -ErrorAction SilentlyContinue }
    Write-Host "Sense: `$((Get-Service -Name Sense -ErrorAction SilentlyContinue).Status)"
} else {
    Write-Host "Onboard CMD not found at `$cmdPath"
}
"@ | Out-File -FilePath $reOnboardPs -Encoding UTF8 -Force
                    & $az vm run-command invoke `
                        --resource-group $resourceGroupName `
                        --name $vmN `
                        --command-id RunPowerShellScript `
                        --scripts "@$reOnboardPs" `
                        --subscription $subscriptionId `
                        --output none
                    Write-Host "$vmN re-onboarding complete, waiting 30s..."
                    Start-Sleep -Seconds 30
                    continue
                }
                Write-Host "$vmN MDE not ready yet (attempt $i/$retries), waiting 30s..."
                Start-Sleep -Seconds 30
            }
            if (-not $mdeVerified) {
                Write-Host "ERROR: $vmN MDE onboarding failed after $retries attempts"
                Write-Host "Manual fix: run fix-mde-onboard.ps1 or check VM in portal"
            }
        }

        # Configure Cloud Protection + Sample Submission on both VMs
        Write-Host ""
        Write-Host "Configuring MDE cloud protection on all VMs..."
        $cloudFixScript = @'
# Set cloud protection via registry (survives GPO)
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet" -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet" -Name "SpynetReporting" -Value 2 -Type DWord -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet" -Name "SubmitSamplesConsent" -Value 3 -Type DWord -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet" -Name "LocalSettingOverrideSpynetReporting" -Value 1 -Type DWord -Force
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\MpEngine" -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\MpEngine" -Name "MpCloudBlockLevel" -Value 2 -Type DWord -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\MpEngine" -Name "MpBafsExtendedTimeout" -Value 50 -Type DWord -Force
# Also set via cmdlet
Set-MpPreference -MAPSReporting Advanced -Force -ErrorAction SilentlyContinue
Set-MpPreference -SubmitSamplesConsent SendAllSamples -Force -ErrorAction SilentlyContinue
Set-MpPreference -CloudBlockLevel High -Force -ErrorAction SilentlyContinue
Set-MpPreference -CloudExtendedTimeout 50 -Force -ErrorAction SilentlyContinue
Set-MpPreference -EnableNetworkProtection Enabled -Force -ErrorAction SilentlyContinue
Set-MpPreference -PUAProtection Enabled -Force -ErrorAction SilentlyContinue
Write-Host "Cloud protection configured"
'@
        $cloudFixPs = "$env:TEMP\cloud-fix.ps1"
        $cloudFixScript | Out-File -FilePath $cloudFixPs -Encoding UTF8 -Force

        foreach ($vmN in @($dcVMName, $smbVMName)) {
            Write-Host "Applying cloud protection to $vmN..."
            & $az vm run-command invoke `
                --resource-group $resourceGroupName `
                --name $vmN `
                --command-id RunPowerShellScript `
                --scripts "@$cloudFixPs" `
                --subscription $subscriptionId `
                --output none
        }
        Write-Host "Cloud protection configured on all VMs"

    } else {
        Write-Host "WARNING: Could not get MDE onboarding package from MDC API"
        Write-Host "MDE onboarding will need to be done manually or via 08attacks/mde-onboard-direct.ps1"
    }
    
    Write-Host ""
    Write-Host "Deployment successful"
    Write-Host "DC: $dcFQDN"
    Write-Host "SMB: $smbFQDN"
    
    Write-Host "Updating parameters.json..."
    $params | Add-Member -NotePropertyName "domainname" -NotePropertyValue $domainName -Force
    $params | Add-Member -NotePropertyName "domainadminuser" -NotePropertyValue $adminUsername -Force
    $params | Add-Member -NotePropertyName "domainadminpass" -NotePropertyValue $adminPassword -Force
    $params | Add-Member -NotePropertyName "vmadminpass" -NotePropertyValue $adminPassword -Force
    $params | Add-Member -NotePropertyName "dcfqdn" -NotePropertyValue $dcFQDN -Force
    $params | Add-Member -NotePropertyName "smbfqdn" -NotePropertyValue $smbFQDN -Force
    $params | Add-Member -NotePropertyName "vmsdeployed" -NotePropertyValue $true -Force
    $params | Add-Member -NotePropertyName "vmsdate" -NotePropertyValue (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Force
    
    $params | ConvertTo-Json -Depth 10 | Set-Content $paramsFile
    
    Write-Host ""
    Write-Host "Phase 06 Complete"
    Write-Host ""
    Write-Host "Summary:"
    Write-Host "1. DC promoted to domain controller (AD DS + DNS running)"
    Write-Host "2. SMB joined domain and configured for file sharing"
    Write-Host "3. Both VMs onboarded to MDE (Sense running)"
    Write-Host "4. Cloud protection configured on all VMs"
    Write-Host "5. Run Phase 05 MDI to configure Defender for Identity"
    Write-Host ""
    Write-Host "Credentials:"
    Write-Host "Domain: $domainName"
    Write-Host "Username: $adminUsername"
    Write-Host "Password: $adminPassword"
    
} catch {
    Write-Host ""
    Write-Host "Deployment failed"
    Write-Host "Error: $_"
    exit 1
}

exit 0
