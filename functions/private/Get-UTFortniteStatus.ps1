function Get-UTFortniteStatus {
    <#
    .SYNOPSIS
        Epic's public status page, through its documented API: every Fortnite component, open incidents
        with their latest update, and scheduled maintenance. Nothing is sent but the request.
    #>
    $lines = New-Object System.Collections.Generic.List[string]
    try {
        $s = Invoke-RestMethod -Uri 'https://status.epicgames.com/api/v2/summary.json' -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
        $groups = @{}
        foreach ($c in $s.components) { if ($c.group) { $groups[[string]$c.id] = [string]$c.name } }
        $lines.Add(('Epic status page: {0}   (updated {1})' -f $s.status.description, ([datetime]$s.page.updated_at).ToLocalTime().ToString('HH:mm')))
        $lines.Add('')
        foreach ($c in ($s.components | Where-Object { -not $_.group -and $groups.ContainsKey([string]$_.group_id) -and $groups[[string]$_.group_id] -match 'Fortnite' })) {
            $mark = '  '
            if ($c.status -ne 'operational') { $mark = '! ' }
            $lines.Add(('{0}{1,-44} {2}' -f $mark, ($groups[[string]$c.group_id] + ' / ' + $c.name), ($c.status -replace '_', ' ')))
        }
        $open = @($s.incidents)
        $lines.Add('')
        if ($open.Count -eq 0) { $lines.Add('no open incidents') }
        foreach ($i in $open) {
            $lines.Add(('INCIDENT  {0}   [{1}, {2}]' -f $i.name, $i.status, $i.impact))
            $u = @($i.incident_updates) | Select-Object -First 1
            if ($u) { $lines.Add(('  ' + (([string]$u.body) -replace '\s+', ' ').Trim())) }
        }
        foreach ($m in @($s.scheduled_maintenances)) {
            $lines.Add(('MAINTENANCE  {0}   {1} -> {2}' -f $m.name, ([datetime]$m.scheduled_for).ToLocalTime().ToString('ddd dd MMM HH:mm'), ([datetime]$m.scheduled_until).ToLocalTime().ToString('HH:mm')))
        }
        $lines.Add('')
        $lines.Add('known gameplay bugs: https://www.epicgames.com/help/en-US/c-Category_Fortnite/c-Fortnite_Gameplay/fortnite-live-issues-and-bugs-a000084853')
    } catch {
        $lines.Add('status.epicgames.com could not be reached: ' + $_.Exception.Message)
    }
    $sync.fnLiveStatus = ($lines -join "`r`n")
    return $sync.fnLiveStatus
}
