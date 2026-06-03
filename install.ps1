# ContextClerk installer
# Registers a Windows Task Scheduler task to run contextclerk.ps1 every 5 minutes.
# Run once after cloning the repo.

param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'contextclerk.ps1'),
    [int]$IntervalMinutes = 5,
    [string]$TaskName = 'ContextClerk'
)

if (-not (Test-Path $ScriptPath)) { Write-Error "Script not found: $ScriptPath"; exit 1 }

# Launch via conhost --headless to suppress the console flash that occurs even when
# PowerShell is launched with -WindowStyle Hidden. Built into Windows 10 1809+ / 11;
# replaces the earlier VBScript launcher (VBScript is deprecated as of Windows 11 24H2).
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" `
    -Argument "--headless powershell.exe -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""
$trigger  = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -Once -At (Get-Date)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Write-Output "ContextClerk installed. Task '$TaskName' runs every $IntervalMinutes minutes."
Write-Output "Script   : $ScriptPath"
Write-Output ""
Write-Output "To remove: Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
