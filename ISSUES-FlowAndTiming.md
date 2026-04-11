# UniSecOps Lab – Flow & Timing Issues

> **Purpose:** Document reliability/timing issues found during script review.  
> **Environment:** Lab/training only (security hardening out of scope).  
> **Date:** April 12, 2026  

---

## Priority Summary

| # | Issue | Severity | File(s) | Impact |
|---|-------|----------|---------|--------|
| 1 | MDE Onboarding Package Fetch – No Retry | **Critical** | `phase11-06vms.ps1` | If the MDC API call to get the onboarding package fails once, MDE onboarding is skipped entirely for both VMs |
| 2 | Attack Scripts Fire Before Defender Is Ready | **Critical** | `phase11-06vms.ps1` | Attacks execute immediately after MDE onboard; Defender may not be fully initialized → alerts never generated |
| 3 | Domain Join – Single Attempt, No Retry | **High** | `setup-smb.ps1` | SMB VM tries `Add-Computer` once; if DC isn't fully ready, join fails and all downstream AD-based attacks fail |
| 4 | GitHub Template Downloads – No Retry | **High** | `04b-mdi.ps1`, `04c-entraid.ps1`, `04d-security-events.ps1`, `04e-additional-solutions.ps1`, `04f-defender-solutions.ps1` | Each Sentinel solution downloads its ARM template from `raw.githubusercontent.com` with zero retry; transient network failure kills the entire solution deployment |
| 5 | WDATP Plan Propagation – No Wait | **High** | `Bootstrapphase.ps1` → `phase11-06vms.ps1` | Phase 10.5 enables the WDATP plan, then Phase 11 immediately tries to fetch the onboarding package; MDC may not have provisioned WDATP yet |
| 6 | VNet DNS Update – No Propagation Wait | **Medium** | `phase11-06vms.ps1` | After switching VNet DNS to DC IP (10.0.1.4), SMB deployment starts immediately; DNS change may not have propagated |
| 7 | DC AD Verification – Timing Gap | **Medium** | `phase11-06vms.ps1` | Uses 8 attempts × 60 s to verify AD is up, but starts checking only 120 s after DC reboot; if DC promotion takes longer than ~10 min total, verification exhausts and errors out |
| 8 | Duplicate Attack Code Blocks | **Medium** | `dcscript.ps1`, `smbscript.ps1` | Both scripts contain duplicate "Initial Access + Ransomware" blocks appended at the end (copy-paste artifact); these re-run the same attacks and can cause confusing duplicate alerts |
| 9 | Ransomware Cleanup Not Guaranteed | **Low** | `commonran.ps1` | `bcdedit /set recoveryenabled No` and shadow copy deletion run outside `try/finally`; if script is interrupted, recovery stays disabled and bait files linger |
| 10 | Log Analytics Workspace – No Pre-Check | **Low** | `04b` through `05` scripts | Sentinel scripts assume the workspace already exists; no validation before attempting solution installs; if ARM deployment was slow, these fail silently |

---

## Detailed Findings

### Issue 1 – MDE Onboarding Package Fetch Has No Retry

**File:** `phase11-06vms.ps1`  
**Location:** MDE onboarding section (~line 400–430)  
**Current behavior:**  
```powershell
$onboardingPackage = Invoke-AzRestMethod -Uri "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Security/mdeOnboardings?api-version=2021-10-01-preview" -Method GET
```
Single call. If the MDC API returns an error or empty response, the script continues with a null/empty onboarding script and silently skips MDE onboarding for both VMs.

**Suggested fix:**  
Wrap in a retry loop (3–5 attempts, 30 s apart). Validate that the response contains a non-empty `onboardingPackageWindows` property before proceeding. Fail explicitly if retries are exhausted.

```powershell
$maxRetries = 5
$retryDelay = 30
$onboardingPackage = $null

for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        $response = Invoke-AzRestMethod -Uri "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Security/mdeOnboardings?api-version=2021-10-01-preview" -Method GET
        $content = $response.Content | ConvertFrom-Json
        if ($content.value -and $content.value[0].properties.onboardingPackageWindows) {
            $onboardingPackage = $content
            Write-Host "MDE onboarding package retrieved on attempt $i"
            break
        }
    } catch {
        Write-Warning "Attempt $i failed: $_"
    }
    if ($i -lt $maxRetries) {
        Write-Host "Waiting ${retryDelay}s before retry..."
        Start-Sleep -Seconds $retryDelay
    }
}

if (-not $onboardingPackage) {
    Write-Error "Failed to retrieve MDE onboarding package after $maxRetries attempts"
}
```

---

### Issue 2 – Attack Scripts Fire Before Defender Is Ready

**File:** `phase11-06vms.ps1`  
**Location:** Attack script invocation section (after MDE onboarding + cloud protection config)  
**Current behavior:**  
After MDE onboarding verification loop completes, the script immediately triggers `dcscript.ps1` and `smbscript.ps1` via `Invoke-AzVMRunCommand`. MDE/Defender services may still be initializing (loading definitions, connecting to cloud, enabling real-time protection).

**Suggested fix:**  
Add a 300-second (5 min) buffer after MDE verification succeeds and before triggering attack scripts. Optionally, verify that `MsSense.exe` (MDE sensor) and `MsMpEng.exe` (Defender AV) are running and cloud-connected.

```powershell
Write-Host "Waiting 300 seconds for Defender/MDE to fully initialize before running attack scripts..."
Start-Sleep -Seconds 300

# Optional: verify Defender readiness on each VM
foreach ($vmName in @($dcVmName, $smbVmName)) {
    $result = Invoke-AzVMRunCommand -ResourceGroupName $rgName -VMName $vmName -CommandId 'RunPowerShellScript' -ScriptString @'
        $sense = Get-Process MsSense -ErrorAction SilentlyContinue
        $mpEng = Get-Process MsMpEng -ErrorAction SilentlyContinue
        $status = Get-MpComputerStatus -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            MsSenseRunning  = [bool]$sense
            MsMpEngRunning  = [bool]$mpEng
            RealTimeEnabled = $status.RealTimeProtectionEnabled
            CloudEnabled    = $status.OnAccessProtectionEnabled
        } | Format-List
'@
    Write-Host "Defender status on ${vmName}:"
    $result.Value[0].Message
}
```

---

### Issue 3 – Domain Join Has No Retry Logic

**File:** `setup-smb.ps1`  
**Location:** Domain join section  
**Current behavior:**  
```powershell
# Waits up to 600s for DC to respond on port 389
# Then calls Add-Computer -DomainName corp.contoso.com ... once
Add-Computer -DomainName $domain -Credential $cred -Force -Restart
```
Single attempt. If the DC is reachable on port 389 but AD DS isn't fully ready to accept joins, it fails permanently.

**Suggested fix:**  
Wrap `Add-Computer` in a retry loop (3 attempts, 60 s apart). Also verify the domain is resolvable (not just TCP 389) before attempting the join.

```powershell
$maxJoinAttempts = 3
$joinSuccess = $false
for ($attempt = 1; $attempt -le $maxJoinAttempts; $attempt++) {
    try {
        Write-Host "Domain join attempt $attempt of $maxJoinAttempts..."
        Add-Computer -DomainName $domain -Credential $cred -Force -ErrorAction Stop
        $joinSuccess = $true
        Write-Host "Domain join succeeded."
        break
    } catch {
        Write-Warning "Domain join attempt $attempt failed: $_"
        if ($attempt -lt $maxJoinAttempts) {
            Start-Sleep -Seconds 60
        }
    }
}

if (-not $joinSuccess) {
    Write-Error "Failed to join domain after $maxJoinAttempts attempts"
    exit 1
}
Restart-Computer -Force
```

---

### Issue 4 – GitHub Template Downloads Have No Retry

**Files:** `04b-mdi.ps1`, `04c-entraid.ps1`, `04d-security-events.ps1`, `04e-additional-solutions.ps1`, `04f-defender-solutions.ps1`  
**Location:** Template download calls in each file  
**Current behavior:**  
```powershell
$templateUri = "https://raw.githubusercontent.com/Azure/Azure-Sentinel/master/Solutions/$solution/Package/mainTemplate.json"
# Used directly in New-AzResourceGroupDeployment -TemplateUri $templateUri
```
No pre-download, no retry. If GitHub returns a transient 5xx or rate-limit, the entire solution deployment fails.

**Suggested fix:**  
Create a shared helper function that downloads the template JSON to a temp file with retry, then pass `-TemplateFile` instead of `-TemplateUri`.

```powershell
function Get-TemplateWithRetry {
    param([string]$Uri, [int]$MaxRetries = 3, [int]$DelaySeconds = 15)
    $tempFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.json'
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $tempFile -UseBasicParsing -ErrorAction Stop
            if ((Get-Item $tempFile).Length -gt 100) { return $tempFile }
        } catch {
            Write-Warning "Download attempt $i for $Uri failed: $_"
        }
        if ($i -lt $MaxRetries) { Start-Sleep -Seconds $DelaySeconds }
    }
    throw "Failed to download template from $Uri after $MaxRetries attempts"
}

# Usage:
$localTemplate = Get-TemplateWithRetry -Uri $templateUri
New-AzResourceGroupDeployment -TemplateFile $localTemplate ...
```

---

### Issue 5 – No Wait Between WDATP Plan Enable and Onboarding

**File:** `Bootstrapphase.ps1` (Phase 10.5 → Phase 11)  
**Current behavior:**  
Phase 10.5 calls `Set-AzSecurityPricing -Name "VirtualMachines" -PricingTier "Standard" -SubPlan "P2"` to enable Microsoft Defender for Servers (WDATP). Phase 11 (`phase11-06vms.ps1`) immediately tries to fetch the MDE onboarding package from the MDC API. The WDATP plan may take 30–90 seconds to fully provision on the backend.

**Suggested fix:**  
Add a 60-second wait at the start of `phase11-06vms.ps1` (or at the end of Phase 10.5 in `Bootstrapphase.ps1`) before attempting the onboarding package fetch.

```powershell
# At the start of MDE onboarding section in phase11-06vms.ps1:
Write-Host "Waiting 60 seconds for WDATP plan to fully provision..."
Start-Sleep -Seconds 60
```

---

### Issue 6 – VNet DNS Change Has No Propagation Wait

**File:** `phase11-06vms.ps1`  
**Location:** After DC deployment, before SMB deployment  
**Current behavior:**  
```powershell
# Updates VNet DNS to DC IP
$vnet.DhcpOptions.DnsServers = @("10.0.1.4")
Set-AzVirtualNetwork -VirtualNetwork $vnet
# Immediately starts SMB VM deployment
```
The SMB VM may start before the new DNS setting takes effect, causing domain discovery to fail.

**Suggested fix:**  
Add a 30-second wait after the VNet DNS update.

```powershell
$vnet.DhcpOptions.DnsServers = @("10.0.1.4")
Set-AzVirtualNetwork -VirtualNetwork $vnet
Write-Host "Waiting 30 seconds for VNet DNS propagation..."
Start-Sleep -Seconds 30
```

---

### Issue 7 – DC Reboot Verification Timing May Be Insufficient

**File:** `phase11-06vms.ps1`  
**Location:** Post-DC-reboot verification loop  
**Current behavior:**  
- Waits 120 s after DC reboot  
- Then attempts 8 checks × 60 s interval = 8 min max wait  
- Total: ~10 min after reboot  

AD DS promotion + reboot on a Standard_D2s_v3 can sometimes take 10–15 minutes. If it exceeds 10 min, the verification loop exhausts all attempts.

**Suggested fix:**  
Increase to 12 attempts (12 min additional) or reduce initial wait and add more attempts. Total budget should be ~15 min.

```powershell
$maxAttempts = 12   # was 8
$waitSeconds = 60   # keep same
```

---

### Issue 8 – Duplicate Attack Code Blocks (Copy-Paste Artifact)

**Files:** `dcscript.ps1` (end of file), `smbscript.ps1` (end of file)  
**Current behavior:**  
Both scripts have their main 7-phase attack sequence, followed by a **duplicate** "Phase: Initial Access" and "Ransomware Simulation" block appended at the bottom. This causes:
- Same attacks to run twice
- Duplicate/confusing Sentinel alerts
- Longer execution time

**In `dcscript.ps1`** – The duplicate block starts approximately at the "Phase: Initial Access" heading near the end of the file (after the main Phase 7 Defense Evasion section) and runs through a second ransomware simulation.

**In `smbscript.ps1`** – Same pattern: duplicate "Phase: Initial Access" and ransomware block appended after the main attack sequence ends.

**Suggested fix:**  
Remove the duplicate blocks entirely from both files. The main 7-phase sequence already covers all attack techniques including ransomware (via `commonran.ps1`).

---

### Issue 9 – Ransomware Cleanup Not in try/finally

**File:** `commonran.ps1`  
**Current behavior:**  
```powershell
# Disables recovery
bcdedit /set {default} recoveryenabled No
vssadmin delete shadows /all /quiet

# Creates 600+ bait files and renames them
# ...

Start-Sleep -Seconds 120

# Cleanup
bcdedit /set {default} recoveryenabled Yes
# Restores files...
```
If the script is interrupted (timeout, error, manual kill) between disabling recovery and the cleanup phase, the VM is left with recovery disabled and hundreds of `.WNCRY`/`.DARKSIDE` files scattered across the filesystem.

**Suggested fix:**  
Wrap the entire operation in `try/finally` to guarantee cleanup runs.

```powershell
try {
    bcdedit /set {default} recoveryenabled No
    vssadmin delete shadows /all /quiet
    
    # ... create bait files, rename, etc. ...
    
    Start-Sleep -Seconds 120
}
finally {
    # Always restore
    bcdedit /set {default} recoveryenabled Yes
    # ... restore renamed files, remove bait files ...
    Write-Host "Cleanup completed (finally block)"
}
```

---

### Issue 10 – Sentinel Scripts Don't Verify Workspace Exists

**Files:** `04b-mdi.ps1`, `04c-entraid.ps1`, `04d-security-events.ps1`, `04e-additional-solutions.ps1`, `04f-defender-solutions.ps1`, `05-enable-data-connectors.ps1`  
**Current behavior:**  
Each script reads workspace name from `parameters.json` and immediately attempts to deploy solutions/connectors. No check that the Log Analytics workspace and Sentinel are actually provisioned and ready.

**Suggested fix:**  
Add a workspace existence check at the start of each script (or at least the first one in sequence, `04b`).

```powershell
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $rgName -Name $workspaceName -ErrorAction SilentlyContinue
if (-not $workspace) {
    Write-Error "Workspace '$workspaceName' not found in resource group '$rgName'. Ensure ARM deployment completed."
    exit 1
}

# Also verify Sentinel is enabled
$sentinel = Get-AzSentinelOnboardingState -ResourceGroupName $rgName -WorkspaceName $workspaceName -ErrorAction SilentlyContinue
if (-not $sentinel) {
    Write-Warning "Sentinel not yet onboarded on workspace. Waiting 30s..."
    Start-Sleep -Seconds 30
}
```

---

## Recommended Fix Order

1. **Issue 1** (MDE retry) + **Issue 5** (WDATP wait) – Fix together; biggest single point of failure  
2. **Issue 2** (attack timing buffer) – Ensures alerts are actually generated  
3. **Issue 3** (domain join retry) – Prevents cascading VM setup failures  
4. **Issue 8** (remove duplicates) – Quick cleanup, no risk  
5. **Issue 4** (GitHub download retry) – Prevents Sentinel solution deployment failures  
6. **Issue 6** (DNS propagation wait) – Small change, prevents SMB join race condition  
7. **Issue 7** (increase AD verification attempts) – Safety margin  
8. **Issue 9** (try/finally for ransomware) – Prevents dirty VM state  
9. **Issue 10** (workspace pre-check) – Defensive check  
