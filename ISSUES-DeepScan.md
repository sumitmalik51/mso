# UniSecOps Lab – Deep Scan Issues Report

> **Purpose:** Comprehensive line-by-line review of all 24 scripts.  
> **Environment:** Lab/training only (security hardening out of scope).  
> **Date:** April 12, 2026  

---

## Issue Index

| # | Category | Issue | Severity | File(s) |
|---|----------|-------|----------|---------|
| **TIMING / FLOW** |||
| 1 | Timing | MDE onboarding package fetch – no retry | **Critical** | `phase11-06vms.ps1` |
| 2 | Timing | Attacks fire before Defender is ready | **Critical** | `phase11-06vms.ps1` |
| 3 | Timing | Domain join – single attempt, no retry | **High** | `setup-smb.ps1` |
| 4 | Timing | GitHub template downloads – no retry | **High** | `04b`, `04c`, `04d`, `04e`, `04f` |
| 5 | Timing | No wait between WDATP enable and MDE onboarding | **High** | `Bootstrapphase.ps1` → `phase11-06vms.ps1` |
| 6 | Timing | VNet DNS update – no propagation wait | **Medium** | `phase11-06vms.ps1` |
| 7 | Timing | DC AD verification budget may be insufficient | **Medium** | `phase11-06vms.ps1` |
| 8 | Logic | Duplicate attack code blocks (copy-paste) | **Medium** | `dcscript.ps1`, `smbscript.ps1` |
| 9 | Reliability | Ransomware cleanup not in try/finally | **Low** | `commonran.ps1` |
| 10 | Reliability | Sentinel scripts don't verify workspace exists | **Low** | `04b` through `05` |
| **LOGIC / FUNCTIONAL BUGS** ||||
| 11 | Bug | `psscriptspn.ps1` creates creds file BEFORE creating LabFiles dir | **High** | `psscriptspn.ps1` |
| 12 | Bug | `psscriptspn.ps1` cred file last 2 lines read from wrong source | **High** | `psscriptspn.ps1` |
| 13 | Bug | `psscriptspn.ps1` Phase 13 attacks never launched | **High** | `psscriptspn.ps1` |
| 14 | Bug | `smbscript.ps1` Phase 3 (PrivEsc) runs AFTER Phase 7 (end) | **Medium** | `smbscript.ps1` |
| 15 | Bug | `03mdc.ps1` enables plans without subPlan for VirtualMachines | **Medium** | `03mdc.ps1` |
| 16 | Bug | `dcscript.ps1` lines 1–7 run before ErrorActionPreference is set | **Medium** | `dcscript.ps1` |
| 17 | Bug | Token expiry during long Sentinel rule enablement loops | **Medium** | `04b`, `04c`, `04e`, `04f` |
| 18 | Bug | `setup-dc.ps1` post-reboot NTDS wait uses service check not status check | **Low** | `setup-dc.ps1` |
| **STRUCTURAL / DRIFT** ||||
| 19 | Drift | Two orchestrators are out of sync | **High** | `Bootstrapphase.ps1` vs `psscriptspn.ps1` |
| 20 | Drift | ARM template outputs expose secrets in plaintext | **Medium** | `unideploy1.json`, `agent1-01.json` |
| 21 | Missing | `07kali.ps1`, `launch-attacks.ps1`, `run-attacks-smb.ps1` referenced but not in repo | **High** | `Bootstrapphase.ps1`, `psscriptspn.ps1` |
| 22 | Missing | `sentinel-template.json` deployed nowhere – unused | **Low** | `sentinel-template.json` |
| **PARAMETER / CONFIG** ||||
| 23 | Config | `phase11-06vms.ps1` uses `odluserpass` as domain admin password | **Medium** | `phase11-06vms.ps1` |
| 24 | Config | `psscriptspn.ps1` hardcodes 20-minute blind wait for MI role | **Medium** | `psscriptspn.ps1` |
| 25 | Config | Sentinel sub-scripts take no parameters – rely on relative path | **Low** | `04b` through `05` |
| 26 | Config | `dc.json` OS disk is Premium_LRS but `smb.json` uses Standard_LRS | **Low** | `dc.json`, `smb.json` |
| 27 | Config | DCR XPath only captures 9 EventIDs – misses key events | **Low** | `04d-security-events.ps1` |
| 28 | Config | `04c-entraid.ps1` Invoke-WebRequest download has no `-UseBasicParsing` | **Low** | `04c-entraid.ps1` |

---

## Detailed Findings

---

### Issues 1–10 (Timing / Flow)

*Previously documented in `ISSUES-FlowAndTiming.md` – see that file for full details and suggested fixes.*

---

### Issue 11 – `psscriptspn.ps1` Downloads Creds Before Creating Directory

**File:** `psscriptspn.ps1`, lines ~60–75  
**Problem:**  
```powershell
Function CreateCredFile(...) {
    $WebClient.DownloadFile("...AzureCreds.txt", "C:\LabFiles\AzureCreds.txt")   # ← writes to C:\LabFiles
    $WebClient.DownloadFile("...AzureCreds.ps1", "C:\LabFiles\AzureCreds.ps1")
    
    New-Item -ItemType directory -Path C:\LabFiles -force   # ← creates C:\LabFiles AFTER the downloads
```
The `New-Item` that creates `C:\LabFiles` is placed **after** the two `DownloadFile` calls that write into that folder. If the folder doesn't exist yet, both downloads fail.

**Fix:** Move `New-Item` above the `DownloadFile` calls.

---

### Issue 12 – `psscriptspn.ps1` Last 2 Cred Lines Read from Wrong File

**File:** `psscriptspn.ps1`, lines ~84–85  
**Problem:**  
```powershell
# These lines are supposed to update AzureCreds.ps1 but read from AzureCreds.txt:
(Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -replace "clientIdValue", "$clientId" } | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"
(Get-Content -Path "C:\LabFiles\AzureCreds.txt") | ForEach-Object {$_ -replace "clientSecretValue", "$clientSecret" } | Set-Content -Path "C:\LabFiles\AzureCreds.ps1"
```
These two lines **read from `AzureCreds.txt`** but **write to `AzureCreds.ps1`**, overwriting the previously correct `.ps1` content with the `.txt` template content.

**Fix:** Change `Get-Content` source to `"C:\LabFiles\AzureCreds.ps1"`.

---

### Issue 13 – `psscriptspn.ps1` Missing Phase 13 (Attack Launch)

**File:** `psscriptspn.ps1`  
**Problem:**  
`Bootstrapphase.ps1` has:
```powershell
Invoke-Phase -PhaseName "13-attacks" -ScriptPath "$ScriptsPath\08attacks\launch-attacks.ps1" ...
```
But `psscriptspn.ps1` goes directly from Phase 12 (Kali) to the summary/end block. **Phase 13 is never invoked.** The attack scripts will never run for the no-SPN variant.

**Fix:** Add the Phase 13 attack invocation before the summary block.

---

### Issue 14 – `smbscript.ps1` Phase 3 (PrivEsc) Runs After "ALL SMB PHASES COMPLETE"

**File:** `smbscript.ps1`  
**Problem:**  
The phase execution order in the file is:
1. Phase 1 – Recon  
2. Phase 2 – Credential Access  
3. Phase 4 – Lateral Movement *(Phase 3 skipped)*  
4. Phase 5 – Persistence  
5. Phase 6 – Exfil & C2  
6. Phase 7 – Evasion & Impact  
7. **"ALL SMB PHASES COMPLETE"** output  
8. *Then* the duplicate Initial Access + Ransomware block  
9. **Then Phase 3 – Privilege Escalation** (at the very bottom)

Phase 3 (UAC bypass, Sticky Keys, Narrator, OSK backdoors) executes **after** Phase 7 and the duplicate ransomware block. This means:
- PrivEsc alerts arrive last when they should be early in the kill chain
- The "ALL SMB PHASES COMPLETE" message appears before the script is actually done

**Fix:** Move Phase 3 block between Phase 2 and Phase 4 (its logical position). Remove the duplicate Initial Access + Ransomware block.

---

### Issue 15 – `03mdc.ps1` Doesn't Specify SubPlan for VirtualMachines

**File:** `03mdc.ps1`, line ~125  
**Problem:**  
```powershell
az security pricing create --name $plan --tier Standard
```
For `VirtualMachines`, the WDATP/MDE onboarding requires **Defender for Servers P2** (`--subplan P2`). Without specifying a sub-plan, Azure defaults to P1, which may not include the full MDE integration needed by `phase11-06vms.ps1`.

Meanwhile, `Bootstrapphase.ps1` Phase 10.5 already does `Set-AzSecurityPricing -SubPlan "P2"`, creating a conflict: Phase 5 enables P1 (or default) and Phase 10.5 tries to upgrade to P2.

**Fix:** Add `--subplan P2` for VirtualMachines in `03mdc.ps1`.

---

### Issue 16 – `dcscript.ps1` Lines 1–7 Run Without Error Handling

**File:** `dcscript.ps1`, lines 1–7  
**Problem:**  
The file starts with 7 aggressive attack commands (reg save SAM, certutil, sethc backdoor, schtasks, password spray, event log clear, service creation) **before** `$ErrorActionPreference = "SilentlyContinue"` is set at Phase 1. These run with whatever the caller's error preference is (likely `Continue`), so errors from these lines will be loud and may confuse log analysis.

These 7 lines also partially duplicate Phase 2 (cred dump), Phase 3 (Sticky Keys), Phase 4 (password spray), Phase 5 (schtasks), and Phase 7 (event log clear).

**Fix:** Either move `$ErrorActionPreference = "SilentlyContinue"` to line 1, or remove these 7 lines since they duplicate the phased attacks below.

---

### Issue 17 – Token Expiry During Long Rule-Enablement Loops

**Files:** `04b-mdi.ps1`, `04c-entraid.ps1`, `04e-additional-solutions.ps1`, `04f-defender-solutions.ps1`  
**Problem:**  
Each script fetches a bearer token **once** at the start of the analytics rule enablement loop:
```powershell
$token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
```
Azure MI tokens are valid for ~60 minutes. If solution deployment + rule enablement takes longer (possible with 16 solutions × 70+ rules each), the token expires mid-loop. All subsequent API calls will fail with 401.

`04c-entraid.ps1` does refresh the token once before the rules loop, which is good, but the other scripts don't.

**Fix:** Add a token age check before each batch of ~20 rule creations, or refresh the token periodically within the loop.

---

### Issue 18 – `setup-dc.ps1` Post-Reboot AD Wait Logic

**File:** `setup-dc.ps1`, post-reboot script (embedded)  
**Problem:**  
```powershell
while (($waited -lt $maxWait) -and -not (Get-Service NTDS -ErrorAction SilentlyContinue)) {
```
`Get-Service NTDS` returns the service object even if the service exists but isn't Running yet (e.g., status = Starting). The check should verify `Status -eq 'Running'` to confirm AD is actually ready.

**Fix:**
```powershell
while (($waited -lt $maxWait) -and -not ((Get-Service NTDS -ErrorAction SilentlyContinue).Status -eq 'Running')) {
```

---

### Issue 19 – Two Orchestrators Are Out of Sync

**Files:** `Bootstrapphase.ps1` vs `psscriptspn.ps1`  
**Problem:**  
These two files are meant to be the same orchestrator with/without SPN parameters. However they have significant drift:

| Area | `Bootstrapphase.ps1` | `psscriptspn.ps1` |
|------|---------------------|-------------------|
| Phase 1.5 | SPN auth → automatic GA assignment | 20-minute blind wait for manual assignment |
| Phase 11.5 | Not present | Creates RDP files on desktop |
| Phase 11.6 | Not present | Creates LabCredentials file with Security Copilot capacity command |
| Phase 12 | Kali deploy | Kali deploy |
| Phase 13 | Attack launch invoked | **Missing – never invoked** |
| Credential file creation | Not present | `CreateCredFile` + `Enable-CloudLabsEmbeddedShadow` at top |
| TLS setup | Not present | `[Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls"` at top |

This means bug fixes applied to one file aren't in the other, and the no-SPN variant has different (sometimes better, sometimes broken) functionality.

**Fix:** Consider factoring shared logic into a common module, or at minimum synchronize the phase lists so both variants invoke the same phases.

---

### Issue 20 – ARM Template Outputs Expose Secrets in Plaintext

**Files:** `unideploy1.json`, `agent1-01.json` – outputs section  
**Problem:**  
```json
"LabVM Admin Password": { "type": "string", "value": "[parameters('adminPassword')]" },
"Azure Password": { "type": "string", "value": "[parameters('azurePassword')]" },
"Trainer Password": { "type": "string", "value": "[parameters('trainerUserPassword')]" }
```
ARM deployment outputs are stored in plaintext in the deployment history and are visible to anyone with Reader role on the resource group. This exposes 3 different passwords.

**Note:** User said don't worry about security for this lab, but these outputs also appear in the CloudLabs portal output tab and could confuse users or logging.

**Fix (optional):** Remove password outputs or mark as `"type": "securestring"` (though outputs can't truly be secure in ARM).

---

### Issue 21 – Referenced Scripts Missing from Repository

**Files:** `Bootstrapphase.ps1` + `psscriptspn.ps1` download list  
**Problem:**  
The download list references 3 scripts that are **not in the blob storage URL list** provided and not in `c:\mso`:
- `07kali.ps1` – Kali VM deployment (Phase 12)
- `launch-attacks.ps1` – Attack launcher (Phase 13)
- `run-attacks-smb.ps1` – SMB attack runner
- `soc-threat-hunter.yaml` – Security Copilot agent YAML

Phase 12 and Phase 13 will **always fail** with "Script not found" if these files don't exist in blob storage. The `Invoke-Phase` function catches this and marks the phase as failed but continues.

**Fix:** Either add these files to the blob storage / repo, or add explicit skip logic with a clear message if they're not yet ready.

---

### Issue 22 – `sentinel-template.json` is Unused

**File:** `sentinel-template.json`  
**Problem:**  
This file is downloaded to `$ScriptsPath\04sentinel\sentinel-template.json` by Phase 0.5, but **no script ever references it**. The workspace + Sentinel are deployed by the main ARM template (`unideploy1.json` / `agent1-01.json`), making this file redundant.

**Fix:** Remove from download list, or if it's intended as a backup/standalone deployment option, document that.

---

### Issue 23 – `phase11-06vms.ps1` Uses `odluserpass` as Domain Admin Password

**File:** `phase11-06vms.ps1`, line ~68  
**Problem:**  
```powershell
$adminPassword = $params.odluserpass
```
The ODL user password (Azure AD user password) is reused as the domain admin password for `corp.contoso.com`. This means:
- The Domain Controller DSRM password = the Azure user password
- The `DomainAdmin` account password = the Azure user password
- The VMs' local admin password = the Azure user password

If the Azure user password has special characters that conflict with `net user` or AD password policy, domain operations may fail silently.

**Fix:** Use `$params.vmadminpass` (which maps to the `adminPassword` ARM parameter) instead. This field already exists in parameters.json.

---

### Issue 24 – `psscriptspn.ps1` Hardcodes 20-Minute Blind Wait

**File:** `psscriptspn.ps1`, Phase 1.5 (lines ~710–720)  
**Problem:**  
```powershell
$waitMinutes = 20
for ($i = $waitMinutes; $i -gt 0; $i--) {
    Write-Host "Resuming in $i minute(s)..."
    Start-Sleep -Seconds 60
}
```
The no-SPN variant **always waits 20 minutes** for manual MI role assignment, even if the roles are already assigned. There's no early exit if verification passes.

**Fix:** Add periodic verification checks during the wait loop, breaking out early when GA + Owner are confirmed.

---

### Issue 25 – Sentinel Sub-Scripts Don't Accept Parameters

**Files:** `04b-mdi.ps1`, `04c-entraid.ps1`, `04d-security-events.ps1`, `04e-additional-solutions.ps1`, `04f-defender-solutions.ps1`, `05-enable-data-connectors.ps1`  
**Problem:**  
None of these scripts accept a `-ParametersFile` parameter. They all locate `parameters.json` via:
```powershell
$params = Get-Content (Join-Path $scriptPath "..\parameters.json") | ConvertFrom-Json
```
This relies on the script being at `deploy\04sentinel\04b-mdi.ps1` so `..` resolves to `deploy\`. But `Invoke-Phase` calls them with empty `-Parameters @{}`. If the scripts are ever run from a different location, they'll fail to find the parameters file.

**Fix:** Add a `$ParametersFile` parameter like `02a-secadmin.ps1` and `03mdc.ps1` already have, and pass it from the orchestrator.

---

### Issue 26 – Inconsistent Disk SKU Between DC and SMB

**Files:** `dc.json` line ~165, `smb.json` line ~185  
**Problem:**  
- DC: `"storageAccountType": "Premium_LRS"` (SSD)
- SMB: `"storageAccountType": "Standard_LRS"` (HDD)

The DC (more I/O intensive with AD + DNS + NTDS) gets SSD, which is correct. But the SMB file server gets HDD. For a lab environment this is fine for cost, but if file share performance matters for attack simulation, it could be slow.

**Impact:** Minor – mostly a consistency note.

---

### Issue 27 – DCR XPath Captures Only 9 Security Event IDs

**File:** `04d-security-events.ps1`, DCR section  
**Problem:**  
The Data Collection Rule XPath filter only captures 9 EventIDs:
```
Security!*[System[(EventID=4624 or EventID=4625 or EventID=4634 or EventID=4672 or EventID=4720 or EventID=4726 or EventID=4728 or EventID=4732 or EventID=4756)]]
```
But the legacy data source is set to `tier = "All"` (collect everything). This creates a mismatch: the AMA-based DCR only captures 9 event types while the legacy connector collects all. Depending on which ingestion path is active, Sentinel may miss important events like:
- 4688 (Process Creation) – needed for attack detection
- 4648 (Explicit Credential Logon)
- 4663 (Object Access)
- 4698/4699 (Scheduled Task Created/Deleted) – used by both attack scripts
- 1102 (Audit Log Cleared) – used by both attack scripts

**Fix:** Either set the DCR to collect `Security!*` (all events, matching the legacy tier), or expand the XPath to include the event IDs the attack scripts generate.

---

### Issue 28 – `04c-entraid.ps1` Invoke-WebRequest Missing `-UseBasicParsing`

**File:** `04c-entraid.ps1`, line ~37  
**Problem:**  
```powershell
Invoke-WebRequest -Uri $entraTemplateUrl -OutFile $entraTempFile
```
Missing `-UseBasicParsing`. On Windows Server (where IE First Run dialog hasn't been dismissed), `Invoke-WebRequest` without `-UseBasicParsing` may try to use the IE DOM parser and fail. Other scripts (`04e`, `04f`) correctly include this flag.

`04b-mdi.ps1` and `04d-security-events.ps1` have the same issue.

**Fix:** Add `-UseBasicParsing` to all `Invoke-WebRequest` calls.

---

## Recommended Fix Priority

### Immediate (prevent deployment failures)
1. **#11** – Fix directory creation order in `psscriptspn.ps1`
2. **#12** – Fix cred file source path in `psscriptspn.ps1`
3. **#21** – Add missing scripts or skip logic for `07kali.ps1`, `launch-attacks.ps1`, `run-attacks-smb.ps1`
4. **#1 + #5** – MDE onboarding retry + WDATP propagation wait
5. **#13** – Add Phase 13 to `psscriptspn.ps1`

### High (functionality/correctness)
6. **#2** – Attack timing buffer (wait for Defender)
7. **#3** – Domain join retry in `setup-smb.ps1`
8. **#15** – Add `--subplan P2` to `03mdc.ps1` VirtualMachines plan
9. **#14** – Fix Phase 3 ordering in `smbscript.ps1`
10. **#8** – Remove duplicate attack blocks from both scripts
11. **#19** – Synchronize the two orchestrators

### Medium (reliability/correctness)
12. **#4** – GitHub template download retry
13. **#6** – DNS propagation wait
14. **#16** – Fix early attack lines in `dcscript.ps1`
15. **#17** – Token refresh in long rule loops
16. **#23** – Use `vmadminpass` instead of `odluserpass`
17. **#24** – Early exit from 20-min wait
18. **#27** – Expand DCR XPath filter

### Low (cleanup/consistency)
19. **#7** – Increase AD verification attempts
20. **#9** – try/finally in `commonran.ps1`
21. **#10** – Workspace pre-check
22. **#18** – Fix NTDS service status check
23. **#22** – Remove unused `sentinel-template.json`
24. **#25** – Add ParametersFile param to Sentinel scripts
25. **#26** – Consistent disk SKU
26. **#28** – Add `-UseBasicParsing`
