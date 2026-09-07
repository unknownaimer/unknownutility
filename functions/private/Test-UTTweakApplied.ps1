function Update-UTTweakStates {
    <#
    .SYNOPSIS
        Recomputes the applied/set state of every tweak into $sync.tweakStates.
    .NOTES
        This is dozens of registry reads and file checks, so it runs in a worker runspace; the UI only
        reads the finished hashtable.
    #>
    $states = @{}
    foreach ($p in $sync.configs.tweaks.PSObject.Properties) {
        try { $states[$p.Name] = Test-UTTweakApplied -Id $p.Name -Tweak $p.Value } catch { $states[$p.Name] = '' }
    }
    $sync.tweakStates = $states
}

function Test-UTTweakApplied {
    <#
    .SYNOPSIS
        'applied' when unknowntweaks applied it (snapshot exists), 'set' when the registry already holds the tweak
        values (set manually or by another tool), '' otherwise. Script-only tweaks report only 'applied'.
    #>
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)]$Tweak)
    if (Test-UTBackupExists -Id $Id) { return 'applied' }
    $entries = @($Tweak.registry | Where-Object { $_ })
    if ($entries.Count -eq 0) { return '' }
    foreach ($r in $entries) {
        $cur = Get-UTRegistryValue -Path $r.Path -Name $r.Name
        if ([string]$r.Value -eq '<RemoveEntry>') { if ($cur.Exists) { return '' }; continue }
        if (-not $cur.Exists) { return '' }
        # A DWord 0 and a REG_SZ "0" both serialise to "0" but are not the same setting, so the kind
        # has to match too before claiming the tweak is already in place.
        $wantKind = [string]$r.Type
        if ($wantKind -and $cur.Kind -and $cur.Kind -ne $wantKind) { return '' }
        $want = [string]$r.Value
        if ($r.Type -eq 'Binary') { $want = (($want -split ',' | ForEach-Object { '{0:X2}' -f [Convert]::ToByte($_.Trim(), 16) }) -join ',') }
        if ($cur.Value -ne $want) { return '' }
    }
    return 'set'
}
