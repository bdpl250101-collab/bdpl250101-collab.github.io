# setup-daily-task.ps1 — register (or update) the daily 06:00 task for the BDPL dashboard.
#
# Run once, in PowerShell, from the repo folder:
#   powershell -ExecutionPolicy Bypass -File .\setup-daily-task.ps1
#
# If a task named BDPL-WeeklyDashboard exists, only its trigger and settings change and its
# action is kept. If it does not exist, it is created to run run-weekly.sh from THIS folder
# with Git Bash, as the current user.
#
# Only one machine should run this. Two PCs pushing the same dashboard will race each other.

$ErrorActionPreference = "Stop"
$TaskName = "BDPL-WeeklyDashboard"
$At       = "06:00"
$RepoDir  = $PSScriptRoot

$tz = (Get-TimeZone).Id
if ($tz -ne "Korea Standard Time") {
    Write-Host "WARNING: time zone is '$tz', not Korea Standard Time; the task fires at $At local time." -ForegroundColor Yellow
}

$trigger = New-ScheduledTaskTrigger -Daily -At $At
$task    = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if ($task) {
    Write-Host "Updating existing task '$TaskName' (action kept as is)." -ForegroundColor Cyan
    $settings = $task.Settings
    $settings.StartWhenAvailable = $true
    $settings.MultipleInstances  = "IgnoreNew"
    $settings.ExecutionTimeLimit = "PT4H"
    $settings.WakeToRun          = $true
    Set-ScheduledTask -TaskName $TaskName -Trigger $trigger -Settings $settings | Out-Null
}
else {
    # Find Git Bash. bash.exe under Git\bin is the login-shell wrapper that sets up PATH.
    $bash = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $bash) { throw "Git Bash (bash.exe) not found. Install Git for Windows, or edit `$bash in this script." }
    if (-not (Test-Path (Join-Path $RepoDir "run-weekly.sh"))) { throw "run-weekly.sh not found in $RepoDir — run this script from the repo folder." }

    # C:\Users\Hwang\repo -> /c/Users/Hwang/repo
    $posix = "/" + $RepoDir.Substring(0,1).ToLower() + $RepoDir.Substring(2).Replace("\","/")
    $action = New-ScheduledTaskAction -Execute $bash -Argument "-lc `"cd '$posix' && ./run-weekly.sh`"" -WorkingDirectory $RepoDir

    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    # Runs as you, while you are signed in: claude's login and git's push credentials are
    # stored per user and are not available to a task that runs signed-out.
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal `
        -Description "BDPL battery dashboard: daily 06:00 KST update (Mondays run in weekly mode). Repo: $RepoDir" | Out-Null
    Write-Host "Created task '$TaskName': $bash -lc `"cd '$posix' && ./run-weekly.sh`"" -ForegroundColor Green
}

(Get-ScheduledTask -TaskName $TaskName).Triggers | Format-List StartBoundary, DaysInterval
Get-ScheduledTaskInfo -TaskName $TaskName | Format-List NextRunTime, LastRunTime, LastTaskResult
Write-Host "Done. Runs every day at $At; if the PC was off or asleep, it runs as soon as it is back." -ForegroundColor Green
Write-Host "Test it now with:  Start-ScheduledTask -TaskName $TaskName   (then check .weekly-last-status)" -ForegroundColor Green
