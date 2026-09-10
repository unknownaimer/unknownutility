function Test-UTSimpleCondition {
    <#
    .SYNOPSIS
        Whether one step of a Simple-mode plan applies to this PC, and the reason when it does not.
    .DESCRIPTION
        Conditions are named rather than scripted so a config edit can never run code. "legacy-gpu" is
        the one that matters: forcing the DX11 renderer helps older NVIDIA cards and hurts modern ones,
        so a one-click mode has to decide per machine instead of writing the same argument everywhere.
    #>
    param([string]$Name)
    $si = $sync.sysinfo
    switch ($Name) {
        'nvidia' {
            if ($si.GPUVendor -eq 'NVIDIA') { return @{ Ok = $true } }
            return @{ Ok = $false; Why = 'no NVIDIA GPU on this PC' }
        }
        'legacy-gpu' {
            if ($si.GPUVendor -ne 'NVIDIA') { return @{ Ok = $false; Why = 'the DX11 switch is an NVIDIA-era setting' } }
            if ($si.GPU -match 'GTX\s*(9|10|16)\d0' -or [double]$si.VramGB -le 4) { return @{ Ok = $true } }
            return @{ Ok = $false; Why = ('{0} does better on DX12 Performance Mode' -f $si.GPU) }
        }
        'modern-gpu' {
            $legacy = Test-UTSimpleCondition -Name 'legacy-gpu'
            if ($legacy.Ok) { return @{ Ok = $false; Why = 'this GPU takes the DX11 route instead' } }
            return @{ Ok = $true }
        }
        default { return @{ Ok = $true } }
    }
}

function Get-UTSimplePlan {
    <#
    .SYNOPSIS
        The steps a Simple-mode game would run here, each already resolved against this PC.
    #>
    param([Parameter(Mandatory = $true)][string]$Game)
    $cfg = $sync.configs.simple.Games.$Game
    if (-not $cfg) { throw "Unknown Simple-mode game $Game" }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($step in @($cfg.Steps)) {
        $c = Test-UTSimpleCondition -Name ([string]$step.When)
        $out.Add([pscustomobject]@{
            Kind = [string]$step.Kind; Value = [string]$step.Value
            Text = [string]$step.Text; Detail = [string]$step.Detail
            Applies = [bool]$c.Ok; Why = [string]$c.Why
        })
    }
    return $out.ToArray()
}

function Invoke-UTSimpleOptimize {
    <#
    .SYNOPSIS
        Runs one Simple-mode plan top to bottom.
    .DESCRIPTION
        Every step is independent: a game that is not installed, or is running, fails its own step and
        the rest still run, because a newbie pressing one button should not be left half done with no
        idea which half. Each step reports itself and the tally is logged at the end.
    #>
    param([Parameter(Mandatory = $true)][string]$Game)
    $plan = @(Get-UTSimplePlan -Game $Game | Where-Object { $_.Applies })
    $done = 0; $failed = 0
    Write-UTLog ("Simple mode: optimizing for {0} ({1} step(s))" -f $sync.configs.simple.Games.$Game.Content, $plan.Count)
    foreach ($step in $plan) {
        try {
            switch ($step.Kind) {
                'restorepoint'     { [void](New-UTRestorePoint) }
                'tweaks'           {
                    $ids = @($sync.configs.tweaks.PSObject.Properties |
                             Where-Object { $_.Value.Tier -eq 'safe' -and $_.Value.Recommended -and (Test-UTTweakEligible -Tweak $_.Value) } |
                             ForEach-Object { $_.Name })
                    Invoke-UTTweaks -Ids ([string[]]$ids)
                }
                'fortnite-profile' { Set-UTFortniteSettings -ProfileName $step.Value }
                'fortnite-args'    { Set-UTLaunchArgs -Arguments $step.Value }
                'valorant-profile' { Set-UTValorantSettings -ProfileName $step.Value }
                'nvprofile'        { Set-UTNvProfile -PresetName $step.Value }
                default            { Write-UTLog ("unknown Simple step {0}" -f $step.Kind) -Level Warn }
            }
            $done++
        } catch {
            $failed++
            Write-UTLog ('{0}: {1}' -f $step.Text, $_.Exception.Message) -Level Error
        }
    }
    if ($failed -eq 0) {
        Write-UTLog ("Simple mode finished: {0} step(s) done. Restart the game, and reboot when you get the chance." -f $done) -Level Ok
    } else {
        Write-UTLog ("Simple mode finished: {0} step(s) done, {1} could not run (each one is logged above). Everything that did run is still undoable." -f $done, $failed) -Level Warn
    }
}
