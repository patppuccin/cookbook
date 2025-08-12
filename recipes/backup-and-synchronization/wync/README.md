# WYNC - Windows Synchronization Utility

Sync files to a remote Windows share using stored credentials. Quiet when needed. Loud when it matters.

> **Recommended:** PowerShell 7+ (Windows PowerShell 5.1 supported)


## What It Does

* Maps a UNC share with saved credentials
* Runs reliable syncs via `robocopy` (push or pull)
* Writes colorized console logs and detailed file logs
* Supports dry runs for safe previews

## Features

* Per-host credential storage via `Export-Clixml`
* Automatic drive letter assignment (Z → P)
* Idempotent syncs with `/MIR`, retry/backoff, NAS-friendly flags
* Separate robocopy logs per run and host
* Skips unavailable hosts in `-Quiet` mode without prompting

## Requirements

* Windows
* PowerShell 7+ (preferred) or 5.1
* Network access to the target UNC path

## Paths

* **Credentials:** `%USERPROFILE%\wync\creds\sync-creds-<HOST>.xml`
* **Logs directory:** `%USERPROFILE%\wync\logs\`
* **App log:** `sync-logs-YYYY-MM-DD.log`
* **Robocopy logs:** `robocopy-<hostTag>-YYYYMMDD-HHmmss.log`

## Flags

| Flag          | Description                                          |
| ------------- | ---------------------------------------------------- |
| `-CredsFlush` | Re-prompt and refresh saved credentials for the host |
| `-Quiet`      | Suppress console output; logs still written          |
| `-DryRun`     | Preview changes only (`/L` flag to robocopy)         |
| `-Help`       | Show help and exit                                   |

## Configuring Syncs

Edit only the top config block:

```powershell
$SyncServers = @(
    @{
        RemoteShare = "\\192.168.69.69\Some\Path"
        SyncItems   = @(
            @{ LocalPath = ".\Local\Path 1"; RemotePath = "Remote\Path 1"; SyncDirection = "pull" }
            @{ LocalPath = ".\Local\Path 2"; RemotePath = "Remote\Path 2"; SyncDirection = "push" }
        )
    }
)
```

**Fields:**

* `RemoteShare`: UNC root path
* `LocalPath`: Local folder path
* `RemotePath`: Path under the mapped share
* `SyncDirection`: `push` (local → remote) or `pull` (remote → local)

## Notes

* Remote paths are cleaned of leading slashes.
* Missing destination directories are created automatically.
* `/MIR` mirrors source to destination, removing deleted files.

## Usage

```powershell
# First run: prompts for creds and saves them
.\wync.ps1

# Preview changes only
.\wync.ps1 -DryRun

# Refresh saved creds
.\wync.ps1 -CredsFlush

# Log-only mode; skips hosts without creds
.\wync.ps1 -Quiet
```

### Quiet Mode

* Missing/invalid creds → host skipped
* No prompts displayed
* All activity logged

## Logging

**Levels:** INF, DBG, WRN, ERR
**App log:** daily rolling file
**Robocopy log:** detailed per run and host

**Robocopy Return Codes:**

* **Success-ish:** 0, 1, 2, 3, 5, 6, 7
* **Failure:** ≥ 8 (logged as error, continues with other hosts)

## Credential Handling

* Stored per host using `Export-Clixml`
* Decryptable only by same user on same machine (DPAPI)
* Use `-CredsFlush` to overwrite existing creds

**Security Tip:** XML files are user-scoped but sensitive. Restrict folder access.

## Drive Letter Allocation

* Picks first available letter from Z down to P
* Skips currently mapped letters
* Unmaps when done

## Exit Codes

* **1**: No valid sync servers after validation
* **0**: Completed (errors may still be logged)

## Robocopy Defaults

`/MIR /Z /XA:SH /W:5 /R:3 /FFT /DST /NFL /NDL /NP`

**Key Flags:**

* `/MIR`: Mirror source to destination
* `/Z`: Restartable mode
* `/XA:SH`: Skip system+hidden files
* `/FFT /DST`: Handle NAS timestamp quirks
* `/NFL /NDL /NP`: Cleaner logs

## Troubleshooting

* **Source not found:** Check `LocalPath` or `RemotePath`
* **Remote server not available:** Verify network/ping/firewall
* **Failed to load credentials:** Possibly corrupt XML; use `-CredsFlush`
* **No available drive letters:** Free up mapped drives or adjust letter pool

## Roadmap

* File/folder exclusion patterns
* Per-item robocopy flags
* Summary report of changes
* Webhook notifications for progress/failures
