# update-logs.ps1
# Migrates old ContextClerk log files to ContextLog.md with a clean header.
# Searches C:\Git and %USERPROFILE% for SESSION_LOG.md and ContextClerk.md,
# renames each to ContextLog.md, and replaces the old header block.

param(
    [string[]]$SearchRoots = @("C:\Git", $env:USERPROFILE),
    [int]$Depth = 5,
    [switch]$DryRun
)

$OldNames   = @('SESSION_LOG.md', 'ContextClerk.md')
$NewName    = 'ContextLog.md'

function Get-NewHeader($path) {
    $dir = Split-Path $path
    return "## *ContextLog | $dir*`n`n[ContextClerk](https://github.com/MechRosey/ContextClerk) monitors Claude sessions and updates this file every five minutes when changes occur.`n"
}

function Strip-OldHeader($lines) {
    # Drop everything before the first ## session entry
    $start = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^## \d{4}-\d{2}-\d{2}') {
            $start = $i
            break
        }
    }
    return $lines[$start..($lines.Count - 1)]
}

$found = @()
foreach ($root in $SearchRoots) {
    foreach ($name in $OldNames) {
        Get-ChildItem -Path $root -Filter $name -Recurse -Depth $Depth -ErrorAction SilentlyContinue |
            ForEach-Object { $found += $_ }
    }
}

if ($found.Count -eq 0) {
    Write-Host "No old log files found."
    exit 0
}

foreach ($file in $found) {
    $dir     = $file.DirectoryName

    if ((Split-Path $dir -Leaf) -eq 'skills') {
        Write-Host "SKIP (skills dir): $($file.FullName)"
        continue
    }

    $newPath = Join-Path $dir $NewName

    if (Test-Path $newPath) {
        Write-Host "SKIP (target exists): $($file.FullName)"
        continue
    }

    Write-Host "$(if ($DryRun) { 'DRY-RUN' } else { 'Migrate' }): $($file.FullName) -> $newPath"
    if ($DryRun) { continue }

    Rename-Item -Path $file.FullName -NewName $NewName -ErrorAction Stop

    $lines      = Get-Content $newPath -Encoding UTF8
    $body       = Strip-OldHeader $lines
    $newHeader  = Get-NewHeader $newPath
    $content    = $newHeader + "`n" + ($body -join "`n")
    Set-Content $newPath $content -Encoding UTF8
}
