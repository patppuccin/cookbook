# Sync-FilesToRemote: Sync Files to Remote Server via Stored Credentials

# GLOBAL FLAGS & PARAMETERS
[CmdletBinding()]
param (
    [switch]$CredsFlush,
    [switch]$Quiet,
    [switch]$DryRun,
    [switch]$Help
)

# DO NOT EDIT ABOVE THIS LINE ====================
# Sync Location Configuration
$SyncServers = @(
    @{
        RemoteShare = "\\192.168.69.69\Some\Path"
        SyncItems   = @(
            @{ LocalPath = ".\Local\Path 1"; RemotePath = "Remote\Path 1"; SyncDirection = "pull" }
            @{ LocalPath = ".\Local\Path 2"; RemotePath = "Remote\Path 2"; SyncDirection = "push" }
        )
    }
)

# DO NOT EDIT BELOW THIS LINE ====================

# DEFINE GLOBALS AND CONSTANTS
Set-Variable -Name 'AppName' -Value 'wync' -Option Constant -Scope Script
Set-Variable -Name 'AppDescription' -Value 'Simple Windows Sync Utility' -Option Constant -Scope Script
Set-Variable -Name "AppVersion" -Value "0.1.0" -Option Constant -Scope Script
Set-Variable -Name "CredsDirPath" -Value "$($env:USERPROFILE)\wync\creds" -Option Constant -Scope Script
Set-Variable -Name 'LogsFilePath' -Value ('{0}\wync\logs\sync-logs-{1:yyyy-MM-dd}.log' -f $env:USERPROFILE, (Get-Date)) -Option Constant -Scope Script

# HANDLE HELP INVOCATION
if ($Help) {
    @"

# $($AppName.ToUpperInvariant()) - $($AppDescription) ================

Usage:
    .\$($AppName.ToLowerInvariant()).ps1 [flags]

Available Flags:
    -CredsFlush   Flush saved credentials for the target host and prompt again.
    -Quiet        Suppress console output. Logs still written to the logs directory.
    -DryRun       Only plans the sync; no changes are made.
    -Help         Display this help message.

Examples:
    .\wync.ps1 -CredsFlush
    .\wync.ps1 -Quiet

Notes:
    - Credentials are stored in encrypted XML under $($env:USERPROFILE)\wync\creds
    - Both local and domain credentials are supported
    - Logs are stored at $($env:USERPROFILE)\wync\logs

"@
    exit
}

# SETUP LOGGING
function Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INF", "DBG", "WRN", "ERR")][string]$Level = "INF"
    )

    $TS = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine = "$TS [$Level] $Message"
    Add-Content -Path $LogsFilePath -Value $LogLine -Encoding UTF8

    if (-not $Script:Quiet) {
        $LevelColor = @{ INF = 'Green'; DBG = 'Blue'; WRN = 'Yellow'; ERR = 'Red' }
        Write-Host $TS -ForegroundColor DarkGray -NoNewline
        Write-Host " [" -NoNewline
        Write-Host $Level -ForegroundColor $LevelColor[$Level] -NoNewline
        Write-Host "] " -NoNewline
        Write-Host $Message
    }
}

# DEFINE CLASSES
class SyncItem {
    [string]$Source
    [string]$Destination

    SyncItem([string]$source, [string]$destination) {
        $this.Source = $source
        $this.Destination = $destination
    }

    [string]Sync([string]$LogTag = "", [switch]$DryRun) {
        if (-not (Test-Path -Path $this.Source)) {
            return "Source not found: $($this.Source)"
        }

        $DestinationDir = Split-Path -Path $this.Destination -Parent
        if ($DestinationDir -and -not (Test-Path -Path $DestinationDir)) {
            New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
        }

        $LogsDir = Split-Path -Path $Script:LogsFilePath -Parent
        if (-not (Test-Path -Path $LogsDir)) {
            New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
        }

        $LogTag = if ([string]::IsNullOrWhiteSpace($LogTag)) { "sync" } else { $LogTag }
        $RobocopyLogsFilePath = Join-Path $LogsDir ("robocopy-{0}-{1:yyyyMMdd-HHmmss}.log" -f $LogTag, (Get-Date))

        # 4) run robocopy
        $RobocopyArguments = @(
            $this.Source,
            $this.Destination,
            "/MIR", "/Z", "/XA:SH", "/W:5", "/R:3",
            "/FFT", "/DST",         # tolerate NAS timestamp skews
            "/NFL", "/NDL", "/NP",
            "/LOG:$RobocopyLogsFilePath"
        )
        if ($DryRun) { $RobocopyArguments += "/L" }

        robocopy @RobocopyArguments | Out-Null
        $code = $LASTEXITCODE

        # 5) evaluate result (robocopy: 0,1,2,3,5,6,7 are success-ish; >=8 failures)
        if ($code -ge 8) {
            return "Robocopy failed (exit $code): $($this.Source) -> $($this.Destination)"
        }

        return $null
    }
}

class SyncServer {
    [string]$RemoteHost
    [string]$SharePath
    [string]$DriveLetter
    [pscredential]$Cred
    [SyncItem[]]$SyncItems

    SyncServer([string]$SharePath) {
        $this.SharePath = $SharePath
        $this.SyncItems = @()
    }
}

# ENTRYPOINT =====================================

# Setup Logging
$LogsDirPath = Split-Path -Path $LogsFilePath -Parent
if (-not (Test-Path $LogsDirPath)) {
    New-Item -ItemType Directory -Path $LogsDirPath | Out-Null
}

Log "Initializing $($AppName) v$($AppVersion)..." INF

$AlreadyAssignedLetters = @()
$FinalSyncServers = @()

foreach ($Server in $SyncServers) {
    if (-not $Server.RemoteShare) {
        Log "Skipping: RemoteShare is empty" WRN
        continue
    }
    Log "Processing server '$($Server.RemoteShare)'" INF

    # Instantiate
    $ThisServer = [SyncServer]::new($Server.RemoteShare)

    # Extract and ping host
    $ExtractedRemoteHost = ($ThisServer.SharePath -replace '^\\\\', '') -split '[\\\/]' | Select-Object -First 1
    if (-not (Test-Connection -ComputerName $ExtractedRemoteHost -Count 1 -Quiet)) {
        Log "Remote server '$ExtractedRemoteHost' is not available, skipping..." ERR
        continue
    }
    Log "Remote server '$ExtractedRemoteHost' is available" DBG
    $ThisServer.RemoteHost = $ExtractedRemoteHost

    # Credential handling (persisted file per host)
    $SanitizedHostName = ($ThisServer.RemoteHost -replace '[^a-zA-Z0-9]', '_')
    $CredPath = "$($CredsDirPath)\sync-creds-$SanitizedHostName.xml"
    $StoredCredsExist = Test-Path $CredPath
    $PromptForCreds = $false

    # CASES:
    # 1) Present && !Flush  -> load
    # 2) Present && Flush && Quiet     -> skip
    # 3) Present && Flush && !Quiet    -> prompt
    # 4) Missing && Quiet              -> skip
    # 5) Missing && !Quiet             -> prompt

    if ($StoredCredsExist) {
        Log "Credentials found for '$($ThisServer.RemoteHost)' at '$CredPath'" DBG

        if ($FlushCreds) {
            if ($Script:Quiet) {
                Log "Received -FlushCreds, but prompting unsupported in -Quiet mode; skipping '$($ThisServer.RemoteHost)'" ERR
                continue
            }
            else {
                $PromptForCreds = $true   # Case 3
            }
        }
        else {
            # Case 1: try load; if corrupt and not Quiet → prompt; if Quiet → skip
            try {
                Log "Loading credentials from '$CredPath'" DBG
                $ThisServer.Cred = Import-Clixml -LiteralPath $CredPath -ErrorAction Stop
            }
            catch {
                Log "Failed to load credentials from '$CredPath': $($_.Exception.Message)" ERR
                if ($Script:Quiet) {
                    Log "Quiet mode prevents recovery prompt; skipping '$($ThisServer.RemoteHost)'" WRN
                    continue
                }
                else {
                    $PromptForCreds = $true
                }
            }
        }
    }
    else {
        Log "Credentials missing for '$($ThisServer.RemoteHost)'" WRN
        if ($Script:Quiet) {
            Log "Prompting unsupported in -Quiet mode; skipping '$($ThisServer.RemoteHost)'" ERR   # Case 4
            continue
        }
        else {
            $PromptForCreds = $true  # Case 5
        }
    }

    if ($PromptForCreds) {
        Log "Prompting for credentials to store for future use." INF
        $NewCred = Get-Credential `
            -Message "Enter credentials for '$($ThisServer.RemoteHost)' to store them for future use."

        if (-not $NewCred) {
            Log "Credential entry cancelled; skipping '$($ThisServer.RemoteHost)'" WRN
            continue
        }

        try {
            $credDir = Split-Path -Path $CredPath -Parent
            if (-not (Test-Path -LiteralPath $credDir)) {
                New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            }
            $NewCred | Export-Clixml -LiteralPath $CredPath -Force -ErrorAction Stop
            $ThisServer.Cred = $NewCred
            Log ("{0} credentials at '{1}' for '{2}'" -f ($(if ($StoredCredsExist) { 'Refreshed' }else { 'Saved' }), $CredPath, $ThisServer.RemoteHost)) DBG
        }
        catch {
            Log "Failed to save credentials: $($_.Exception.Message)" ERR
            continue
        }
    }

    # Drive letter assignment (Z..P), exclude currently mapped and already assigned in this run
    $UsedDrives = (Get-PSDrive -PSProvider FileSystem).Name
    $DrivePool = [char[]]([char]'Z'..[char]'P')
    $Available = $DrivePool | Where-Object {
        $_ -notin $UsedDrives -and $_ -notin $AlreadyAssignedLetters
    }
    if (-not $Available) {
        Log "No available drive letters for $($ThisServer.RemoteHost)" ERR
        continue
    }
    $ThisServer.DriveLetter = $Available[0]
    $AlreadyAssignedLetters += $ThisServer.DriveLetter
    Log "Assigned drive letter '$($ThisServer.DriveLetter)' to $($ThisServer.RemoteHost)" DBG

    foreach ($Item in $Server.SyncItems) {
        $SyncDirection = $Item.SyncDirection.Trim().ToLowerInvariant()
        $RemoteParsedPath = $Item.RemotePath.TrimStart('\', '/')
        $RemoteMappedRoot = "$($ThisServer.DriveLetter):\"
        $RemotePath = [System.IO.Path]::Combine($RemoteMappedRoot, $RemoteParsedPath)

        switch ($SyncDirection) {
            'push' { $ThisServer.SyncItems += [SyncItem]::new($Item.LocalPath, $RemotePath) }
            'pull' { $ThisServer.SyncItems += [SyncItem]::new($RemotePath, $Item.LocalPath) }
            default {
                Log "Invalid sync direction '$SyncDirection'" ERR
                continue
            }
        }
    }

    if ($ThisServer.SyncItems.Count -eq 0) {
        Log "No valid sync items for '$($ThisServer.RemoteHost)'; skipping." WRN
        continue
    }

    $FinalSyncServers += $ThisServer
}

if ($FinalSyncServers.Count -eq 0) {
    Log "No valid sync servers found; exiting." WRN
    exit 1
}

Log "Initializing syncing tasks..." INF
foreach ($Server in $FinalSyncServers) {
    $hostTag = ($Server.RemoteHost -replace '[^a-zA-Z0-9]', '_')

    try {
        Log "Syncing with server '$($Server.RemoteHost)'" INF
        New-PSDrive -Name $Server.DriveLetter -PSProvider FileSystem -Root $Server.SharePath -Credential $Server.Cred -Persist -ErrorAction Stop | Out-Null

        foreach ($item in $Server.SyncItems) {
            $err = $item.Sync($hostTag, $DryRun)
            if ($err) { Log $err ERR }
            else { Log "SYNC COMPLETE: $($item.Source) -> $($item.Destination)" INF }
        }
    }
    catch {
        Log "Syncing with server '$($Server.RemoteHost)' failed: $($_.Exception.Message)" ERR
    }
    finally {
        Remove-PSDrive -Name $Server.DriveLetter -Force -ErrorAction SilentlyContinue
    }
}
