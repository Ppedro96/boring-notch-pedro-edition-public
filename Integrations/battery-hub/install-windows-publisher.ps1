$ErrorActionPreference = 'Stop'
$folder = Join-Path $env:USERPROFILE '.local\share\insight-batteries'
$python = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe'
$pythonw = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\pythonw.exe'
$script = Join-Path $folder 'windows-publisher.py'
$config = Join-Path $folder 'client.json'
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $folder '/inheritance:r' '/grant:r' ($user + ':(OI)(CI)F') 'SYSTEM:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not protect publisher configuration' }
& $python $script '--config' $config '--once'
if ($LASTEXITCODE -ne 0) { throw 'Initial battery publication failed' }
$action = New-ScheduledTaskAction -Execute $pythonw -Argument ('"' + $script + '" --config "' + $config + '"') -WorkingDirectory $folder
$triggers = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn -User $user))
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'InsightBatteriesPublisher' -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description 'Send only Alienware battery level and charging status to the private battery hub' -Force | Out-Null
Start-ScheduledTask -TaskName 'InsightBatteriesPublisher'
Get-ScheduledTask -TaskName 'InsightBatteriesPublisher' | Select-Object TaskName,State | ConvertTo-Json -Compress
