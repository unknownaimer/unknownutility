function Get-UTBackupPath {
    param([Parameter(Mandatory = $true)][string]$Id, [string]$Suffix = '.json')
    if (-not (Test-Path -LiteralPath $sync.backupDir)) { New-Item -ItemType Directory -Path $sync.backupDir -Force | Out-Null }
    return (Join-Path $sync.backupDir ($Id + $Suffix))
}

function Save-UTBackup {
    <#
    .SYNOPSIS
        Snapshots the current state of everything a tweak is about to change, so undo restores the real
        previous values instead of assumed Windows defaults. The first snapshot is never overwritten.
    #>
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)]$Tweak)
    # A one-shot action (clearing temp files) changes no state that can be restored, so it gets no
    # snapshot and is never labelled "applied".
    # @($null).Count is 1, not 0, so every list has to be filtered before it is counted.
    $hasState = ((@($Tweak.registry | Where-Object { $_ }).Count -gt 0) -or
                 (@($Tweak.service | Where-Object { $_ }).Count -gt 0) -or
                 (@($Tweak.ScheduledTask | Where-Object { $_ }).Count -gt 0) -or
                 (@($Tweak.UndoScript | Where-Object { $_ }).Count -gt 0))
    if (-not $hasState) { return }
    $file = Get-UTBackupPath -Id $Id
    if (Test-Path -LiteralPath $file) { Write-UTLog "Keeping the existing snapshot for $Id"; return }
    $snap = @{ Id = $Id; Date = (Get-Date -Format 's'); Registry = @(); Service = @(); Task = @() }
    foreach ($r in @($Tweak.registry)) {
        if (-not $r) { continue }
        $cur = Get-UTRegistryValue -Path $r.Path -Name $r.Name
        $snap.Registry += @{ Path = $r.Path; Name = $r.Name; Exists = $cur.Exists; Kind = $cur.Kind; Value = $cur.Value }
    }
    foreach ($s in @($Tweak.service)) {
        if (-not $s) { continue }
        $snap.Service += @{ Name = $s.Name; StartupType = (Get-UTServiceStartup -Name $s.Name) }
    }
    foreach ($t in @($Tweak.ScheduledTask)) {
        if (-not $t) { continue }
        $snap.Task += @{ Name = $t.Name; State = (Get-UTScheduledTaskState -FullName $t.Name) }
    }
    # No snapshot means no reliable undo, so this is fatal for the tweak rather than a warning.
    $snap | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file -Encoding UTF8 -Force -ErrorAction Stop
    Write-UTLog "Snapshot saved: $file"
}

function Get-UTBackup {
    param([Parameter(Mandatory = $true)][string]$Id)
    $file = Get-UTBackupPath -Id $Id
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try { return (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json) } catch { return $null }
}

function Remove-UTBackup {
    param([Parameter(Mandatory = $true)][string]$Id)
    foreach ($suffix in '.json', '.state.json') {
        $file = Get-UTBackupPath -Id $Id -Suffix $suffix
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
}

function Test-UTBackupExists {
    param([Parameter(Mandatory = $true)][string]$Id)
    return (Test-Path -LiteralPath (Get-UTBackupPath -Id $Id))
}

function Get-UTAppliedTweaks {
    <#
    .SYNOPSIS
        Ids of every tweak that has a snapshot on disk, i.e. everything unknowntweaks has applied and
        not yet undone, even from an earlier session.
    #>
    $ids = @()
    if (-not (Test-Path -LiteralPath $sync.backupDir)) { return $ids }
    foreach ($f in (Get-ChildItem -LiteralPath $sync.backupDir -Filter *.json -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -like '*.state.json') { continue }
        $id = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        if ($sync.configs.tweaks.PSObject.Properties.Name -contains $id) { $ids += $id }
    }
    return @($ids | Sort-Object)
}

function Get-UTScriptState {
    <#
    .SYNOPSIS
        Reads values a tweak's InvokeScript saved for its UndoScript. Returns the whole hashtable when -Key is omitted.
    #>
    param([Parameter(Mandatory = $true)][string]$Id, [string]$Key)
    $file = Get-UTBackupPath -Id $Id -Suffix '.state.json'
    $state = @{}
    if (Test-Path -LiteralPath $file) {
        try {
            $obj = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $state[$p.Name] = $p.Value }
        } catch { }
    }
    if ([string]::IsNullOrEmpty($Key)) { return $state }
    if ($state.ContainsKey($Key)) { return $state[$Key] }
    return $null
}

function Save-UTScriptState {
    <#
    .SYNOPSIS
        Records a value an InvokeScript needs to hand to its UndoScript.
    .NOTES
        A key is written once and then kept. Re-applying a tweak that is already applied must not
        overwrite the pre-tweak value with the post-tweak one, or undo would restore the tweak itself.
        Pass -Force for state that is genuinely meant to change on every apply.
    #>
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][string]$Key, $Value, [switch]$Force)
    $file = Get-UTBackupPath -Id $Id -Suffix '.state.json'
    $state = Get-UTScriptState -Id $Id
    if ($state.ContainsKey($Key) -and -not $Force) {
        Write-UTLog "Keeping the value recorded for $Id/$Key when it was first applied"
        return
    }
    if ($null -eq $Value) { $state[$Key] = $null } else { $state[$Key] = [string]$Value }
    try { $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $file -Encoding UTF8 -Force } catch { }
}
