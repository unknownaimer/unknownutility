function Export-UTSelection {
    <#
    .SYNOPSIS
        Writes the current selection (ticked tweaks, Fortnite and VALORANT profiles, launch arguments) to a
        JSON file that another PC can import. Only ids and names; no machine facts, no snapshots.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $sel = [ordered]@{
        Tool = 'unknowntweaks'; Version = $sync.version; Exported = (Get-Date).ToString('s')
        Tweaks = @($sync.tweakBoxes.Keys | Where-Object { $sync.tweakBoxes[$_].IsChecked } | Sort-Object)
        FortniteProfile = ''; FortniteHiddenKeys = @($sync.fnHiddenBoxes.Keys | Where-Object { $sync.fnHiddenBoxes[$_].IsChecked })
        LaunchArgs = (Get-UTArgsString); ValorantProfile = ''
    }
    if ($sync.FnProfileList.SelectedItem) { $sel.FortniteProfile = [string]$sync.FnProfileList.SelectedItem.Tag }
    if ($sync.VaProfileList.SelectedItem) { $sel.ValorantProfile = [string]$sync.VaProfileList.SelectedItem.Tag }
    ([pscustomobject]$sel) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
    Write-UTLog ("selection exported to {0} ({1} tweak(s))" -f $Path, $sel.Tweaks.Count) -Level Ok
}

function Import-UTSelection {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sel = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($sel.Tool -ne 'unknowntweaks') { throw 'Not an unknowntweaks selection file' }
    $n = 0; $unknown = @()
    foreach ($cb in $sync.tweakBoxes.Values) { $cb.IsChecked = $false }
    foreach ($id in @($sel.Tweaks)) {
        if ($sync.tweakBoxes.ContainsKey($id)) { $sync.tweakBoxes[$id].IsChecked = $true; $n++ } else { $unknown += $id }
    }
    foreach ($cb in $sync.fnHiddenBoxes.Values) { $cb.IsChecked = $false }
    foreach ($id in @($sel.FortniteHiddenKeys)) { if ($sync.fnHiddenBoxes.ContainsKey($id)) { $sync.fnHiddenBoxes[$id].IsChecked = $true } }
    Select-UTListItem -List $sync.FnProfileList -Tag ([string]$sel.FortniteProfile)
    Select-UTListItem -List $sync.VaProfileList -Tag ([string]$sel.ValorantProfile)
    if ($null -ne $sel.LaunchArgs) {
        $wanted = @(([string]$sel.LaunchArgs) -split '\s+' | Where-Object { $_ })
        $known = @()
        foreach ($id in @($sync.fnArgOrder)) {
            $cb = $sync.fnArgBoxes[$id]; $arg = [string]$cb.Tag
            $parts = @($arg -split '\s+')
            $on = $true
            foreach ($p in $parts) { if ($wanted -notcontains $p) { $on = $false } }
            $cb.IsChecked = $on
            if ($on) { $known += $parts }
        }
        $sync.FnArgsExtra.Text = (@($wanted | Where-Object { $known -notcontains $_ }) -join ' ')
    }
    $msg = "selection imported from {0}: {1} tweak(s) ticked" -f $Path, $n
    if ($unknown.Count -gt 0) { $msg += ("; not in this build: " + ($unknown -join ', ')) }
    Write-UTLog $msg -Level Ok
}

function Select-UTListItem {
    param($List, [string]$Tag)
    if (-not $List -or -not $Tag) { return }
    foreach ($item in $List.Items) { if ([string]$item.Tag -eq $Tag) { $List.SelectedItem = $item; return } }
}
