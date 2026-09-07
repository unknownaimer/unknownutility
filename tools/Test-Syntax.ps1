<#
.SYNOPSIS
    Static checks for unknowntweaks. Runs anywhere PowerShell 7 runs (macOS/Linux/Windows).
.DESCRIPTION
    - Parses every .ps1 with the PowerShell AST and reports parse errors.
    - Flags PowerShell 7-only syntax that breaks on Windows PowerShell 5.1 (the real target).
    - Validates every config/*.json (strict, and checks for keys that differ only by case,
      which 5.1's ConvertFrom-Json rejects).
    - Validates xaml/*.xaml as XML and flags constructs XamlReader.Load refuses.
    Exit code 1 if anything fails.
#>
[CmdletBinding()]
param(
    [string]$Root
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 leaves $PSScriptRoot empty inside a param() default on an advanced script,
# so the repository root is resolved here rather than in the parameter block.
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')
# System.Text.Json ships with .NET Core only. On 5.1 the fallback is ConvertFrom-Json, which is the
# parser the compiled tool itself uses at runtime, so the check stays honest either way.
$hasSystemTextJson = $null -ne ('System.Text.Json.JsonDocument' -as [type])
$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Add-Failure([string]$msg) { $script:failures.Add($msg); Write-Host "FAIL  $msg" -ForegroundColor Red }
function Add-Warning([string]$msg) { $script:warnings.Add($msg); Write-Host "WARN  $msg" -ForegroundColor Yellow }

# ---------- PowerShell files ----------
$psFiles = Get-ChildItem -Path $Root -Recurse -Include *.ps1 -File |
    Where-Object { $_.FullName -notmatch '[\\/](tools|dist|\.git)[\\/]' }

foreach ($f in $psFiles) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/')
    if ($errors.Count) {
        foreach ($e in $errors) {
            Add-Failure ("{0}:{1}:{2} {3}" -f $rel, $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message)
        }
        continue
    }

    # 5.1-incompatible AST nodes. Matched by type *name*, because the types that describe 7-only
    # syntax (TernaryExpressionAst, PipelineChainAst) do not exist in 5.1's own assembly, and a
    # `-is [MissingType]` there is a terminating error rather than $false.
    $bad = $ast.FindAll({
        param($n)
        $tn = $n.GetType().Name
        if ($tn -eq 'TernaryExpressionAst' -or $tn -eq 'PipelineChainAst') { return $true }
        if (($tn -eq 'BinaryExpressionAst' -or $tn -eq 'AssignmentStatementAst') -and
            $n.Operator.ToString() -in 'QuestionQuestion', 'QuestionQuestionEquals') { return $true }
        if ($tn -in 'MemberExpressionAst', 'InvokeMemberExpressionAst', 'IndexExpressionAst') {
            $p = $n.PSObject.Properties['NullConditional']
            if ($p -and $p.Value) { return $true }
        }
        return $false
    }, $true)
    foreach ($b in $bad) {
        Add-Failure ("{0}:{1} PowerShell 7-only syntax: {2}" -f $rel, $b.Extent.StartLineNumber, $b.Extent.Text)
    }

    # A local that differs from a parameter only by case IS that parameter: PowerShell variable names
    # are case-insensitive, so `$title = New-Object ...TextBlock` inside a function that declares
    # [string]$Title coerces the control straight back into a string, and every property assignment
    # after it fails at runtime with "the property X cannot be found on this object". Only object
    # construction is flagged, so a deliberate `$Type = 'String'` default for [string]$Type stays quiet.
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if (-not $fn.Body.ParamBlock) { continue }
        $typedParams = @{}
        foreach ($p in $fn.Body.ParamBlock.Parameters) {
            if ($p.StaticType -and $p.StaticType -ne [object]) { $typedParams[$p.Name.VariablePath.UserPath] = $p.StaticType }
        }
        if ($typedParams.Count -eq 0) { continue }
        foreach ($a in $fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            if (-not ($a.Left -is [System.Management.Automation.Language.VariableExpressionAst])) { continue }
            $local = $a.Left.VariablePath.UserPath
            $param = @($typedParams.Keys | Where-Object { $_ -ieq $local })[0]
            if (-not $param) { continue }
            $rhs = $a.Right.Extent.Text
            if ($rhs -notmatch '^\s*(New-Object\s+(?:-TypeName\s+)?''?([\w\.\[\]`,]+)|\[([\w\.]+)\]::new\()') { continue }
            # Constructing the parameter's own type back into it is not the bug this looks for.
            $built = $Matches[2]; if (-not $built) { $built = $Matches[3] }
            $builtType = $built -as [type]
            if ($builtType -and $typedParams[$param].IsAssignableFrom($builtType)) { continue }
            Add-Failure ("{0}:{1} `${2} is the same variable as the [{3}]`${4} parameter (names are case-insensitive), so the object assigned here is coerced to [{3}]. Rename the local." -f
                $rel, $a.Extent.StartLineNumber, $local, $typedParams[$param].Name, $param)
        }
    }

    # 5.1-incompatible cmdlets / parameters (text-level, conservative)
    $text = Get-Content -Raw -LiteralPath $f.FullName
    if ($text -match '[^\x00-\x7F]') { Add-Failure ("{0}: contains non-ASCII characters (5.1 reads BOM-less files as ANSI)" -f $rel) }
    $checks = @(
        @{ Pattern = 'ForEach-Object\s+-Parallel';                   Msg = 'ForEach-Object -Parallel is PowerShell 7+' },
        @{ Pattern = 'ConvertFrom-Json[^\r\n]*-AsHashtable';          Msg = 'ConvertFrom-Json -AsHashtable is 6+' },
        @{ Pattern = '\bJoin-String\b';                               Msg = 'Join-String is 6.2+' },
        @{ Pattern = '\bGet-Error\b';                                 Msg = 'Get-Error is 7+' },
        @{ Pattern = '\bTest-Json\b';                                 Msg = 'Test-Json is 6.1+' },
        @{ Pattern = '-SkipCertificateCheck';                         Msg = '-SkipCertificateCheck is 6+' },
        @{ Pattern = 'Set-Service[^\r\n]*-StartupType\s+AutomaticDelayedStart'; Msg = 'Set-Service -StartupType AutomaticDelayedStart is 6.2+ (use sc.exe / registry DelayedAutostart)' },
        @{ Pattern = '\[[^\]\r\n]*\[[^\]\r\n]*\]\]::new\(';            Msg = '::new() on a generic type does not parse on 5.1 in some forms; prefer New-Object' },
        @{ Pattern = '\$IsWindows\b|\$IsLinux\b|\$IsMacOS\b';         Msg = '$IsWindows/$IsLinux/$IsMacOS are undefined ($null) on 5.1; guard accordingly' },
        @{ Pattern = '\bTest-Connection\b[^\r\n]*-TimeoutSeconds';    Msg = 'Test-Connection -TimeoutSeconds is 7+' },
        @{ Pattern = 'Split-Path[^\r\n]*-LeafBase';                   Msg = 'Split-Path -LeafBase is 6+' },
        @{ Pattern = 'Get-ChildItem[^\r\n]*-FollowSymlink';           Msg = '-FollowSymlink is 6+' },
        @{ Pattern = '\bInvoke-RestMethod\b[^\r\n]*-Form\b';          Msg = 'Invoke-RestMethod -Form is 6.1+' }
    )
    $lineNo = 0
    foreach ($line in ($text -split "`r?`n")) {
        $lineNo++
        if ($line -match '^\s*#') { continue }
        foreach ($c in $checks) {
            if ($line -match $c.Pattern) {
                if ($c.Msg -like '*generic*' -or $c.Msg -like '*IsWindows*') { Add-Warning ("{0}:{1} {2}" -f $rel, $lineNo, $c.Msg) }
                else { Add-Failure ("{0}:{1} {2}" -f $rel, $lineNo, $c.Msg) }
            }
        }
    }
}

# ---------- JSON configs ----------
$jsonFiles = Get-ChildItem -Path (Join-Path $Root 'config') -Filter *.json -File -ErrorAction SilentlyContinue
foreach ($j in $jsonFiles) {
    $raw = Get-Content -Raw -LiteralPath $j.FullName
    if ($hasSystemTextJson) {
        try {
            $null = [System.Text.Json.JsonDocument]::Parse($raw, [System.Text.Json.JsonDocumentOptions]@{ AllowTrailingCommas = $false; CommentHandling = 'Disallow' })
        } catch {
            Add-Failure ("config/{0}: invalid JSON: {1}" -f $j.Name, $_.Exception.Message)
            continue
        }
        # 5.1 ConvertFrom-Json dies on keys that differ only by case within one object
        try {
            $doc = [System.Text.Json.JsonDocument]::Parse($raw)
            $stack = [System.Collections.Generic.Stack[object]]::new()
            $stack.Push(@{ El = $doc.RootElement; Path = '$' })
            while ($stack.Count) {
                $cur = $stack.Pop()
                $el = $cur.El
                if ($el.ValueKind -eq 'Object') {
                    $seen = @{}
                    foreach ($p in $el.EnumerateObject()) {
                        $k = $p.Name.ToLowerInvariant()
                        if ($seen.ContainsKey($k)) { Add-Failure ("config/{0}: keys '{1}' and '{2}' at {3} differ only by case (5.1 ConvertFrom-Json rejects this)" -f $j.Name, $seen[$k], $p.Name, $cur.Path) }
                        $seen[$k] = $p.Name
                        $stack.Push(@{ El = $p.Value; Path = "$($cur.Path).$($p.Name)" })
                    }
                } elseif ($el.ValueKind -eq 'Array') {
                    $i = 0
                    foreach ($item in $el.EnumerateArray()) { $stack.Push(@{ El = $item; Path = "$($cur.Path)[$i]" }); $i++ }
                }
            }
        } catch { Add-Warning ("config/{0}: case-duplicate check skipped: {1}" -f $j.Name, $_.Exception.Message) }
    } else {
        # On 5.1 the real runtime parser is the check: ConvertFrom-Json there rejects malformed JSON
        # *and* keys within one object that differ only by case, which is the pair of failures above.
        try { $null = $raw | ConvertFrom-Json }
        catch { Add-Failure ("config/{0}: 5.1 ConvertFrom-Json rejects it: {1}" -f $j.Name, $_.Exception.Message); continue }
    }
    # a line that starts with '@ would terminate the single-quoted here-string used at compile time
    if ($raw -match "(?m)^'@") { Add-Failure ("config/{0}: a line starts with '@ which would end the compile here-string" -f $j.Name) }
    if ($raw -match '[^\x00-\x7F]') { Add-Failure ("config/{0}: contains non-ASCII characters (5.1 reads BOM-less files as ANSI)" -f $j.Name) }
}

# ---------- XAML ----------
$xamlFiles = Get-ChildItem -Path (Join-Path $Root 'xaml') -Filter *.xaml -File -ErrorAction SilentlyContinue
foreach ($x in $xamlFiles) {
    $raw = Get-Content -Raw -LiteralPath $x.FullName
    try { $null = [xml]$raw } catch { Add-Failure ("xaml/{0}: not well-formed XML: {1}" -f $x.Name, $_.Exception.Message); continue }
    if ($raw -match 'x:Class=') { Add-Failure ("xaml/{0}: x:Class is not allowed with XamlReader.Load" -f $x.Name) }
    if ($raw -match 'mc:Ignorable') { Add-Warning ("xaml/{0}: mc:Ignorable / design-time namespaces should be removed" -f $x.Name) }
    $evt = [regex]::Matches($raw, '\s(Click|Checked|Unchecked|Loaded|SelectionChanged|TextChanged|MouseDown|KeyDown|Closing|Initialized|PreviewMouseDown|PreviewKeyDown)="')
    foreach ($m in $evt) { Add-Failure ("xaml/{0}: event attribute {1}= is not allowed with XamlReader.Load (wire events from PowerShell)" -f $x.Name, $m.Groups[1].Value) }
    if ($raw -match "(?m)^'@") { Add-Failure ("xaml/{0}: a line starts with '@ which would end the compile here-string" -f $x.Name) }
    if ($raw -match '[^\x00-\x7F]') { Add-Failure ("xaml/{0}: contains non-ASCII characters; use &#xNNNN; entities" -f $x.Name) }
    # every Name= (not x:Name=, which template parts reuse) must be unique in the window namescope
    $names = [regex]::Matches($raw, '(?<![:\w])Name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
    $dups = $names | Group-Object | Where-Object Count -gt 1
    foreach ($d in $dups) { Add-Failure ("xaml/{0}: duplicate Name '{1}'" -f $x.Name, $d.Name) }
}

# ---------- XAML <-> code cross-check ----------
if ($xamlFiles.Count -eq 1) {
    $raw = Get-Content -Raw -LiteralPath $xamlFiles[0].FullName
    $xamlNames = [System.Collections.Generic.HashSet[string]]::new([string[]]([regex]::Matches($raw, '(?<![:\w])Name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }))
    # $sync keys assigned outside the XAML binding loop (data, not controls)
    $dataKeys = [System.Collections.Generic.HashSet[string]]::new([string[]]@())
    foreach ($f in $psFiles) {
        foreach ($m in [regex]::Matches((Get-Content -Raw -LiteralPath $f.FullName), '\$sync\.([A-Za-z_][A-Za-z0-9_]*)\s*=')) { [void]$dataKeys.Add($m.Groups[1].Value) }
    }
    foreach ($f in $psFiles) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/')
        $lineNo = 0
        foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
            $lineNo++
            foreach ($m in [regex]::Matches($line, '\$sync\.([A-Z][A-Za-z0-9_]*)')) {
                $name = $m.Groups[1].Value
                if ($xamlNames.Contains($name) -or $dataKeys.Contains($name)) { continue }
                # Hashtable / collection members reached through $sync itself, not XAML controls
                if ($name -in 'Keys', 'Values', 'Count', 'Item', 'ContainsKey', 'Contains', 'Add', 'Remove', 'Clear', 'GetEnumerator', 'ContainsValue') { continue }
                Add-Failure ("{0}:{1} `$sync.{2} is neither a Name= in the XAML nor ever assigned" -f $rel, $lineNo, $name)
            }
        }
    }
}

Write-Host ""
Write-Host ("Checked {0} scripts, {1} json, {2} xaml. {3} failure(s), {4} warning(s)." -f $psFiles.Count, $jsonFiles.Count, $xamlFiles.Count, $failures.Count, $warnings.Count)
if ($failures.Count) { exit 1 } else { exit 0 }
