# ContextClerk installer
# Registers a Windows Task Scheduler task to run contextclerk.ps1 every 5 minutes.
# Run once after cloning the repo.

param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'contextclerk.ps1'),
    [int]$IntervalMinutes = 5,
    [string]$TaskName = 'ContextClerk'
)

if (-not (Test-Path $ScriptPath)) { Write-Error "Script not found: $ScriptPath"; exit 1 }

# Write a VBScript launcher alongside the script.
# wscript.exe Run with window style 0 (vbHide) suppresses the console flash
# that occurs even when PowerShell is launched with -WindowStyle Hidden.
$vbsPath = Join-Path $PSScriptRoot 'contextclerk.vbs'
Set-Content $vbsPath @"
CreateObject("WScript.Shell").Run "powershell.exe -NonInteractive -ExecutionPolicy Bypass -File """ & "$ScriptPath" & """", 0, False
"@ -Encoding ASCII

$action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbsPath`""
$trigger  = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -Once -At (Get-Date)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Output "ContextClerk installed. Task '$TaskName' runs every $IntervalMinutes minutes."
Write-Output "Launcher : $vbsPath"
Write-Output "Script   : $ScriptPath"
Write-Output ""
Write-Output "To remove: Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
