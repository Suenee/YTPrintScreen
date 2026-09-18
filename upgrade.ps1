[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath,

    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$TargetBranch,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryUrl,

    [string]$UpdaterRevision = "unknown"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:CurrentPhase = "SELF-UPDATE"
$script:LogPath = $null
$script:LockPath = $null
$script:LockOwned = $false
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:TemporaryBootstrapBackup = $null
$script:BootstrapStarted = $false
$script:BootstrapCompleted = $false
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
    [Console]::OutputEncoding = $script:Utf8NoBom
} catch {
    # Console encoding is diagnostic-only; upgrade may continue.
}

function Write-UpgradeLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host $Message -ForegroundColor $Color

    if ($script:LogPath) {
        $line = "{0:yyyy-MM-dd HH:mm:ss} | {1}{2}" -f (Get-Date), $Message, [Environment]::NewLine
        [System.IO.File]::AppendAllText($script:LogPath, $line, $script:Utf8NoBom)
    }
}

function Set-UpgradePhase {
    param([Parameter(Mandatory = $true)][string]$Name)
    $script:CurrentPhase = $Name
    Write-UpgradeLine ("PHASE: {0}" -f $Name)
}

function Add-UpgradeWarning {
    param([Parameter(Mandatory = $true)][string]$Message)
    [void]$script:Warnings.Add($Message)
    Write-UpgradeLine ("WARNING: {0}" -f $Message) ([ConsoleColor]::Yellow)
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$ArgumentList = @(),

        [switch]$AllowFailure,
        [switch]$QuietOutput
    )

    $displayArguments = ($ArgumentList | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' '
    Write-UpgradeLine ("COMMAND: {0} {1}" -f $FilePath, $displayArguments).TrimEnd()

    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $nativeOutput = @(& $FilePath @ArgumentList 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }

    $textOutput = @()
    foreach ($item in $nativeOutput) {
        $text = [string]$item
        $textOutput += $text
        if (-not $QuietOutput -and $text.Length -gt 0) {
            Write-UpgradeLine ("    {0}" -f $text)
        }
    }

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw ("Native command failed with exit code {0}: {1} {2}" -f $exitCode, $FilePath, $displayArguments)
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $textOutput
    }
}

function Normalize-GitRemote {
    param([Parameter(Mandatory = $true)][string]$Value)

    $normalized = $Value.Trim().Replace('\', '/')
    if ($normalized.EndsWith('/')) {
        $normalized = $normalized.Substring(0, $normalized.Length - 1)
    }
    if ($normalized.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(0, $normalized.Length - 4)
    }
    return $normalized.ToLowerInvariant()
}

function Initialize-UpgradeLog {
    $logsPath = Join-Path $RepositoryPath "logs"
    if (-not (Test-Path -LiteralPath $logsPath)) {
        New-Item -ItemType Directory -Path $logsPath -Force | Out-Null
    }

    $script:LogPath = Join-Path $logsPath "upgrade.log"
    [System.IO.File]::WriteAllText($script:LogPath, "", $script:Utf8NoBom)
}

function Acquire-UpgradeLock {
    $script:LockPath = Join-Path $RepositoryPath ".upgrade.lock"

    if (Test-Path -LiteralPath $script:LockPath) {
        $stale = $true
        try {
            $lockText = Get-Content -LiteralPath $script:LockPath -Raw -ErrorAction Stop
            $lockData = $lockText | ConvertFrom-Json -ErrorAction Stop
            if ($lockData.pid) {
                $ownerProcess = Get-Process -Id ([int]$lockData.pid) -ErrorAction SilentlyContinue
                if ($ownerProcess) {
                    $stale = $false
                }
            }
        } catch {
            $stale = $true
        }

        if (-not $stale) {
            throw "Jiný upgrade tohoto repozitáře právě běží."
        }

        Remove-Item -LiteralPath $script:LockPath -Force -ErrorAction SilentlyContinue
    }

    $payload = [pscustomobject]@{
        pid        = $PID
        startedAt  = (Get-Date).ToString('o')
        repository = $RepositoryPath
    } | ConvertTo-Json -Compress

    try {
        $stream = New-Object System.IO.FileStream(
            $script:LockPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        try {
            $writer = New-Object System.IO.StreamWriter($stream, $script:Utf8NoBom)
            $writer.Write($payload)
            $writer.Flush()
            $writer.Dispose()
        } finally {
            $stream.Dispose()
        }
        $script:LockOwned = $true
    } catch {
        throw "Nelze získat upgrade lock. Jiný upgrade mohl začít současně."
    }
}

function Release-UpgradeLock {
    if ($script:LockOwned -and $script:LockPath -and (Test-Path -LiteralPath $script:LockPath)) {
        Remove-Item -LiteralPath $script:LockPath -Force -ErrorAction SilentlyContinue
    }
    $script:LockOwned = $false
}

function Assert-SafeBootstrapDirectory {
    $allowedNames = @(
        'YTPrintScreen.ahk',
        'YTPrintScreen.ini',
        'YTPrintScreen.log',
        'YTPrintScreen.png',
        'YTPrintScreen.jpg',
        'YTPrintScreen.jpeg',
        'YTPrintScreen_CHANGELOG.md',
        'YTPrintScreen_SmartTrim.ini',
        'upgrade.cmd',
        'upgrade.ps1',
        'logs',
        'backup',
        '.upgrade.lock',
        'desktop.ini',
        'Thumbs.db'
    )

    $unexpected = @(
        Get-ChildItem -LiteralPath $RepositoryPath -Force | Where-Object {
            $allowedNames -notcontains $_.Name
        } | Select-Object -ExpandProperty Name
    )

    if ($unexpected.Count -gt 0) {
        $items = $unexpected -join ', '
        throw ("Adresář ještě není Git repozitář a obsahuje neočekávané položky: {0}. Z bezpečnostních důvodů bootstrap nic nepřepíše." -f $items)
    }
}

function Backup-PreGitFiles {
    $backupPath = Join-Path $env:TEMP ("YTPrintScreen-pre-git-{0}" -f ([Guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

    foreach ($entry in Get-ChildItem -LiteralPath $RepositoryPath -Force -File) {
        if ($entry.Name -eq '.upgrade.lock') {
            continue
        }
        Copy-Item -LiteralPath $entry.FullName -Destination (Join-Path $backupPath $entry.Name) -Force
    }

    $script:TemporaryBootstrapBackup = $backupPath
    Write-UpgradeLine ("BOOTSTRAP backup: {0}" -f $backupPath)
}

function Remove-AuthoritativeBootstrapFiles {
    $authoritativeFiles = @(
        'YTPrintScreen.ahk',
        'YTPrintScreen.ini',
        'YTPrintScreen_CHANGELOG.md',
        'upgrade.cmd',
        'upgrade.ps1',
        '.gitattributes',
        '.gitignore',
        'YTPrintScreen.example.ini'
    )

    foreach ($name in $authoritativeFiles) {
        $path = Join-Path $RepositoryPath $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

function Preserve-PreGitBackupInRepository {
    if (-not $script:TemporaryBootstrapBackup -or -not (Test-Path -LiteralPath $script:TemporaryBootstrapBackup)) {
        return
    }

    $backupRoot = Join-Path $RepositoryPath "backup"
    if (-not (Test-Path -LiteralPath $backupRoot)) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    }

    $destination = Join-Path $backupRoot ("pre-git-{0:yyyyMMdd-HHmmss}" -f (Get-Date))
    New-Item -ItemType Directory -Path $destination -Force | Out-Null

    foreach ($entry in Get-ChildItem -LiteralPath $script:TemporaryBootstrapBackup -Force -File) {
        Copy-Item -LiteralPath $entry.FullName -Destination (Join-Path $destination $entry.Name) -Force
    }

    Write-UpgradeLine ("Původní lokální soubory byly bezpečně zazálohovány do: {0}" -f $destination)
}

function Restore-LocalRuntimeFiles {
    if (-not $script:TemporaryBootstrapBackup -or -not (Test-Path -LiteralPath $script:TemporaryBootstrapBackup)) {
        return
    }

    $runtimeFiles = @(
        'YTPrintScreen.log',
        'YTPrintScreen_SmartTrim.ini',
        'YTPrintScreen.png',
        'YTPrintScreen.jpg',
        'YTPrintScreen.jpeg'
    )

    foreach ($name in $runtimeFiles) {
        $source = Join-Path $script:TemporaryBootstrapBackup $name
        $destination = Join-Path $RepositoryPath $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination $destination -Force
            Write-UpgradeLine ("Zachován lokální soubor: {0}" -f $name)
        }
    }
}

function Restore-PreGitSnapshotOnFailure {
    if (-not $script:BootstrapStarted -or $script:BootstrapCompleted) {
        return
    }
    if (-not $script:TemporaryBootstrapBackup -or -not (Test-Path -LiteralPath $script:TemporaryBootstrapBackup)) {
        return
    }

    Write-UpgradeLine "BOOTSTRAP rollback: obnovuji stav před převodem na Git repozitář." ([ConsoleColor]::Yellow)

    $gitPath = Join-Path $RepositoryPath '.git'
    if (Test-Path -LiteralPath $gitPath) {
        Remove-Item -LiteralPath $gitPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    $generatedFiles = @(
        'YTPrintScreen.ahk',
        'YTPrintScreen.ini',
        'YTPrintScreen_CHANGELOG.md',
        'upgrade.cmd',
        'upgrade.ps1',
        '.gitattributes',
        '.gitignore',
        'YTPrintScreen.example.ini'
    )
    foreach ($name in $generatedFiles) {
        $path = Join-Path $RepositoryPath $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($entry in Get-ChildItem -LiteralPath $script:TemporaryBootstrapBackup -Force -File) {
        Copy-Item -LiteralPath $entry.FullName -Destination (Join-Path $RepositoryPath $entry.Name) -Force
    }

    Write-UpgradeLine "BOOTSTRAP rollback dokončen; původní lokální soubory byly obnoveny." ([ConsoleColor]::Yellow)
}

function Get-TrackedLocalChanges {
    $changed = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    $workTree = Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'diff', '--name-only') -QuietOutput
    foreach ($line in $workTree.Output) {
        if ($line) { [void]$changed.Add($line.Trim()) }
    }

    $index = Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'diff', '--cached', '--name-only') -QuietOutput
    foreach ($line in $index.Output) {
        if ($line) { [void]$changed.Add($line.Trim()) }
    }

    return @($changed)
}

function Assert-OriginIdentity {
    $origin = Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'remote', 'get-url', 'origin') -QuietOutput
    if ($origin.ExitCode -ne 0 -or $origin.Output.Count -eq 0) {
        throw "Git remote 'origin' chybí."
    }

    $actual = Normalize-GitRemote $origin.Output[0]
    $expected = Normalize-GitRemote $RepositoryUrl
    if ($actual -ne $expected) {
        throw ("Neočekávaný Git origin: {0}. Očekáváno: {1}" -f $origin.Output[0], $RepositoryUrl)
    }
}

function Synchronize-Repository {
    Set-UpgradePhase "REPOSITORY"

    Assert-OriginIdentity

    $changes = @(Get-TrackedLocalChanges)
    $allowedUpdaterChanges = @('upgrade.cmd', 'upgrade.ps1')
    $blocking = @($changes | Where-Object { $allowedUpdaterChanges -notcontains $_ })
    if ($blocking.Count -gt 0) {
        throw ("Repozitář obsahuje lokální sledované změny, které upgrade nesmí zahodit: {0}" -f ($blocking -join ', '))
    }

    if ($changes.Count -gt 0) {
        Write-UpgradeLine ("Lokální rozdíly updateru budou nahrazeny autoritativní verzí: {0}" -f ($changes -join ', '))
    }

    Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'fetch', '--prune', 'origin', $TargetBranch) | Out-Null

    if ($changes.Count -gt 0) {
        Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'reset', '--hard', 'HEAD') | Out-Null
    }

    Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'checkout', '-B', $TargetBranch, ("origin/{0}" -f $TargetBranch)) | Out-Null
    Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'reset', '--hard', ("origin/{0}" -f $TargetBranch)) | Out-Null

    $branch = Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'rev-parse', '--abbrev-ref', 'HEAD') -QuietOutput
    if ($branch.Output.Count -eq 0 -or $branch.Output[0].Trim() -ne $TargetBranch) {
        throw ("Aktivní větev není {0}." -f $TargetBranch)
    }

    $localHead = Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'rev-parse', 'HEAD') -QuietOutput
    $remoteHead = Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'rev-parse', ("origin/{0}" -f $TargetBranch)) -QuietOutput
    if ($localHead.Output.Count -eq 0 -or $remoteHead.Output.Count -eq 0 -or $localHead.Output[0].Trim() -ne $remoteHead.Output[0].Trim()) {
        throw "HEAD neodpovídá autoritativní vzdálené větvi."
    }

    Write-UpgradeLine ("Synchronized commit: {0}" -f $localHead.Output[0].Trim())
}

function Bootstrap-Repository {
    Set-UpgradePhase "BOOTSTRAP"

    Assert-SafeBootstrapDirectory
    $script:BootstrapStarted = $true
    Backup-PreGitFiles
    Remove-AuthoritativeBootstrapFiles

    Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'init') | Out-Null
    Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'remote', 'add', 'origin', $RepositoryUrl) | Out-Null
    Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'fetch', '--prune', 'origin', $TargetBranch) | Out-Null
    Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'checkout', '-B', $TargetBranch, ("origin/{0}" -f $TargetBranch)) | Out-Null
    Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'reset', '--hard', ("origin/{0}" -f $TargetBranch)) | Out-Null

    Restore-LocalRuntimeFiles
    Preserve-PreGitBackupInRepository
    Assert-OriginIdentity

    $localHead = Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'rev-parse', 'HEAD') -QuietOutput
    $remoteHead = Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'rev-parse', ("origin/{0}" -f $TargetBranch)) -QuietOutput
    if ($localHead.Output.Count -eq 0 -or $remoteHead.Output.Count -eq 0 -or $localHead.Output[0].Trim() -ne $remoteHead.Output[0].Trim()) {
        throw "Bootstrap skončil na jiném commitu než origin cílové větve."
    }

    $script:BootstrapCompleted = $true
    Write-UpgradeLine ("Bootstrap commit: {0}" -f $localHead.Output[0].Trim())
}

function Ensure-Configuration {
    Set-UpgradePhase "CONFIGURATION"

    $configPath = Join-Path $RepositoryPath "YTPrintScreen.ini"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Chybí autoritativní sledovaný YTPrintScreen.ini."
    }

    Write-UpgradeLine "YTPrintScreen.ini je spravován repozitářem a odpovídá cílové větvi."
}

function Verify-Dependencies {
    Set-UpgradePhase "DEPENDENCIES"

    $gitVersion = Invoke-Native -FilePath $script:GitExe -ArgumentList @('--version') -QuietOutput
    if ($gitVersion.Output.Count -gt 0) {
        Write-UpgradeLine ("Git: {0}" -f $gitVersion.Output[0])
    }

    $autoHotkeyCandidates = @(
        (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'),
        (Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey.exe')
    )

    $ahkPath = $null
    $ahkCommand = Get-Command AutoHotkey.exe -ErrorAction SilentlyContinue
    if ($ahkCommand) {
        $ahkPath = $ahkCommand.Source
    }

    if (-not $ahkPath) {
        foreach ($candidate in $autoHotkeyCandidates) {
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $ahkPath = $candidate
                break
            }
        }
    }

    if ($ahkPath) {
        Write-UpgradeLine ("AutoHotkey v2 executable: {0}" -f $ahkPath)
    } else {
        Add-UpgradeWarning "AutoHotkey v2 nebyl nalezen v PATH ani ve standardní instalační cestě. Soubory jsou aktualizované, ale spuštění skriptu může vyžadovat instalaci AutoHotkey v2."
    }
}

function Verify-Installation {
    Set-UpgradePhase "VERIFY"

    $requiredFiles = @(
        'YTPrintScreen.ahk',
        'YTPrintScreen.ini',
        'YTPrintScreen.example.ini',
        'YTPrintScreen_CHANGELOG.md',
        'upgrade.cmd',
        'upgrade.ps1',
        '.gitignore',
        '.gitattributes'
    )

    foreach ($name in $requiredFiles) {
        $path = Join-Path $RepositoryPath $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw ("Po upgradu chybí povinný soubor: {0}" -f $name)
        }
    }

    $configPath = Join-Path $RepositoryPath 'YTPrintScreen.ini'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Po upgradu chybí sledovaný YTPrintScreen.ini."
    }

    $status = Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'status', '--porcelain', '--untracked-files=no') -QuietOutput
    $trackedDirty = @($status.Output | Where-Object { $_ -and ($_ -notmatch 'upgrade\.cmd$') -and ($_ -notmatch 'upgrade\.ps1$') })
    if ($trackedDirty.Count -gt 0) {
        throw ("Po synchronizaci zůstal sledovaný pracovní strom změněný: {0}" -f ($trackedDirty -join ' | '))
    }
}

$exitCode = 0
$bootstrapMode = $false

try {
    $RepositoryPath = [System.IO.Path]::GetFullPath($RepositoryPath)
    $SourcePath = [System.IO.Path]::GetFullPath($SourcePath)

    if (-not (Test-Path -LiteralPath $RepositoryPath -PathType Container)) {
        throw ("Repozitář neexistuje: {0}" -f $RepositoryPath)
    }

    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = 'safe.directory'
    $env:GIT_CONFIG_VALUE_0 = $RepositoryPath

    Acquire-UpgradeLock
    Initialize-UpgradeLog

    Write-UpgradeLine "============================================================"
    Write-UpgradeLine "YTPrintScreen upgrade"
    Write-UpgradeLine ("Updater revision: {0}" -f $UpdaterRevision)
    Write-UpgradeLine ("Repository source path: {0}" -f $SourcePath)
    Write-UpgradeLine ("Repository active path: {0}" -f $RepositoryPath)
    Write-UpgradeLine ("Target branch: {0}" -f $TargetBranch)
    Write-UpgradeLine ("Repository URL: {0}" -f $RepositoryUrl)
    Write-UpgradeLine "============================================================"

    $gitCommand = Get-Command git.exe -ErrorAction Stop
    $script:GitExe = $gitCommand.Source

    $bootstrapMode = -not (Test-Path -LiteralPath (Join-Path $RepositoryPath '.git') -PathType Container)

    Set-UpgradePhase "SELF-UPDATE"
    Write-UpgradeLine "Běží dočasná autoritativní kopie upgrade.ps1; pracovní strom lze bezpečně synchronizovat."

    if ($bootstrapMode) {
        Write-UpgradeLine "Lokální adresář zatím není Git repozitář; spouští se řízená adopce existující instalace."
        Bootstrap-Repository
    } else {
        $startingCommit = Invoke-Native -FilePath $script:GitExe -ArgumentList @('-C', $RepositoryPath, 'rev-parse', 'HEAD') -AllowFailure -QuietOutput
        if ($startingCommit.ExitCode -eq 0 -and $startingCommit.Output.Count -gt 0) {
            Write-UpgradeLine ("Starting commit: {0}" -f $startingCommit.Output[0].Trim())
        }
        Synchronize-Repository
    }

    Ensure-Configuration
    Verify-Dependencies

    Set-UpgradePhase "STOP-RUNTIME"
    Write-UpgradeLine "Není vyžadováno: YTPrintScreen je jednorázový AHK skript bez trvale běžícího projektového procesu."

    Verify-Installation

    Set-UpgradePhase "COMPLETE"
    if ($script:Warnings.Count -gt 0) {
        Write-UpgradeLine "STATUS: WARNING - phase=COMPLETE" ([ConsoleColor]::Yellow)
    } else {
        Write-UpgradeLine "STATUS: SUCCESS - phase=COMPLETE" ([ConsoleColor]::Green)
    }

    Write-UpgradeLine ("Upgrade log: {0}" -f $script:LogPath)
    $exitCode = 0
} catch {
    $message = $_.Exception.Message

    if ($script:BootstrapStarted -and -not $script:BootstrapCompleted) {
        try {
            Restore-PreGitSnapshotOnFailure
        } catch {
            $rollbackError = $_.Exception.Message
            if ($script:LogPath) {
                Write-UpgradeLine ("WARNING: Bootstrap rollback nebyl úplný: {0}" -f $rollbackError) ([ConsoleColor]::Yellow)
            } else {
                Write-Host ("WARNING: Bootstrap rollback nebyl úplný: {0}" -f $rollbackError) -ForegroundColor Yellow
            }
        }
    }

    if ($script:LogPath) {
        Write-UpgradeLine ("ERROR: {0}" -f $message) ([ConsoleColor]::Red)
        Write-UpgradeLine ("STATUS: FAILED - phase={0}" -f $script:CurrentPhase) ([ConsoleColor]::Red)
        Write-UpgradeLine ("Upgrade log: {0}" -f $script:LogPath)
    } else {
        Write-Host ("ERROR: {0}" -f $message) -ForegroundColor Red
        Write-Host ("STATUS: FAILED - phase={0}" -f $script:CurrentPhase) -ForegroundColor Red
    }
    $exitCode = 1
} finally {
    Release-UpgradeLock

    if ($script:TemporaryBootstrapBackup -and (Test-Path -LiteralPath $script:TemporaryBootstrapBackup)) {
        Remove-Item -LiteralPath $script:TemporaryBootstrapBackup -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode
