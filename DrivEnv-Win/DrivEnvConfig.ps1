# ====================================================================
# DRIVENV CONFIGURATION VALIDATION
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera
# Updated: 26/08/2026
# Version: 1.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# All five scripts read the same JSON, and until this file existed a key
# the scripts did not know about was simply never read. That is not a
# harmless no-op, because every reader falls back to a DEFAULT:
#
#   environment.install_testing_material    absent -> true, so a typo in
#       the plural copies the 26 MB testing tree you asked it to skip;
#   environment.verification.check_tools    absent -> empty list, so
#       "check_toolz" makes step 5 check no tools at all and then report
#       "tools 0 checked, 0 failed" as a success;
#   environment.verification.check_packages absent -> true.
#
# The second kind is the dangerous one. A verification step that quietly
# verifies less than it was asked to is worse than none, because it is
# believed. So an unknown key is an ERROR here, with the nearest known key
# suggested, and every value is type-checked before any script acts on it.
#
# Dot-source this from a script AFTER its own Write-Error and
# Abort-WithError helpers exist, then call Test-DrivEnvConfig. Nothing in
# this file prints or exits: it returns the problems it found and lets the
# caller report them in its own voice.
#
# Hand-rolled rather than JSON Schema on purpose: Test-Json -Schema needs
# PowerShell 6.1, and these scripts promise nothing newer than 5.1.

# --------------------------------------------------------------------
# SCHEMA
# --------------------------------------------------------------------

function Get-DrivEnvConfigSchema
{
    # @brief Every key the five scripts read, with its type and allowed values.
    #
    # Node shape: type = object | map | array | string | int | bool
    #   object   fields    = @{ name = node }   every present key must be listed; required ones must be present
    #   map      valueNode = node               arbitrary key names, values all validated against one node
    #   array    item      = node
    #   string   allowed   = @(...)             optional closed set, compared case-insensitively
    #            notEmpty  = $true              optional
    #            pattern   = regex              optional
    #   int      min       = n                  optional
    # 'required' is false when absent.
    #
    # The field names matter. They are NOT 'keys', 'values' or 'value', because a PowerShell hashtable already has
    # Keys, Values and Count properties, and $node.values falls through to the hashtable's OWN value collection
    # whenever the node has no entry by that name. The first version of this file used 'values' and every string
    # without an explicit enum was therefore compared against its own node contents -- 153 false positives on a
    # configuration that was perfectly good. Nodes are also read with $node['x'] rather than $node.x below, so the
    # same collision cannot come back through a name nobody thought about.

    $stringNode = @{ type = 'string' }
    $boolNode   = @{ type = 'bool' }
    $reqString  = @{ type = 'string'; required = $true; notEmpty = $true }

    $msys2Package = @{
        type   = 'object'
        fields = @{
            name    = $reqString
            mode    = @{ type = 'string'; required = $true; allowed = @('pinned', 'latest') }
            version = @{ type = 'string' }
            repo    = @{ type = 'string'; allowed = @('mingw', 'msys') }
        }
    }

    # triplet is OPTIONAL and overrides vcpkg.target.triplet for this package alone. Fast DDS is why it
    # exists: its MinGW DLL does not export what a publisher needs, so it must be built statically inside an
    # otherwise dynamic environment. No separate "default triplet" key: target.triplet already is the default.
    $vcpkgPackage = @{
        type   = 'object'
        fields = @{
            name     = $reqString
            features = @{ type = 'array'; item = $stringNode }
            triplet  = @{ type = 'string'; notEmpty = $true }
        }
    }

    # expect may be empty: "the command runs at all" is a legitimate expectation, and pkgconf is configured that way.
    $checkCommand = @{
        type   = 'object'
        fields = @{
            run    = $reqString
            expect = @{ type = 'string'; required = $true }
        }
    }

    $verification = @{
        type   = 'object'
        fields = @{
            check_packages           = $boolNode
            check_dll_load           = $boolNode
            check_tools              = @{ type = 'array'; item = $stringNode }
            check_commands           = @{ type = 'array'; item = $checkCommand }
            check_gstreamer_elements = @{ type = 'array'; item = $stringNode }
        }
    }

    $environment = @{
        type     = 'object'
        required = $true
        fields   = @{
            dev_drive_label               = $reqString
            dev_drive_letter              = @{ type = 'string'; required = $true; pattern = '^[A-Za-z]$' }
            dev_env_name                  = $reqString
            vhd_root                      = $reqString
            vhd_size_gb                   = @{ type = 'int'; required = $true; min = 1 }
            use_dev_drive                 = $boolNode
            force_diskpart                = $boolNode
            vhd_fixed                     = $boolNode
            custom_variables              = @{ type = 'map'; valueNode = $stringNode }
            custom_path_entries           = @{ type = 'array'; item = $stringNode }
            custom_folders                = @{ type = 'array'; item = $stringNode }
            install_testing_material      = $boolNode
            install_installation_material = $boolNode
            append_windows_system_path    = $boolNode
            proxy_url                     = $stringNode
            verification                  = $verification
        }
    }

    $msys2 = @{
        type     = 'object'
        required = $true
        fields   = @{
            source   = @{
                type     = 'object'
                required = $true
                fields   = @{ url = $reqString; sha256 = $stringNode }
            }
            target   = @{
                type     = 'object'
                required = $true
                fields   = @{ profile = $reqString; arch = $reqString; base_url = $stringNode }
            }
            packages = @{ type = 'array'; required = $true; item = $msys2Package }
        }
    }

    $vcpkg = @{
        type     = 'object'
        required = $true
        fields   = @{
            source   = @{
                type     = 'object'
                required = $true
                fields   = @{
                    repository_url  = $reqString
                    baseline_mode   = @{ type = 'string'; required = $true; allowed = @('fixed', 'latest') }
                    baseline_commit = $stringNode
                }
            }
            target   = @{
                type     = 'object'
                required = $true
                fields   = @{ triplet = $reqString }
            }
            packages = @{ type = 'array'; required = $true; item = $vcpkgPackage }
        }
    }

    # A repository to clone into the generated drive. Only the URL is required; everything else has a default that
    # lives in step 6, because this file validates shape and the reading script owns behaviour.
    #
    #   name     the directory to clone into. Default: the last path segment of the URL, minus any .git.
    #            Present so two forks of the same project can coexist, and so a repository can be given the name
    #            the project actually calls it rather than the one its URL happens to carry.
    #   folder   the destination root, relative to the drive. Default: workspace.default_folder.
    #   ref      a branch or a tag to check out. Default: the remote's own default branch. A commit id does NOT
    #            work here: git clone --branch takes a ref name, not a sha.
    #   depth    a shallow clone of that many commits. Omit for a full clone, which is the default and the right
    #            choice for anything somebody will commit to.
    #   optional when true, a failure to clone this one is a warning instead of a fault. For a private repository
    #            on a machine that may not have credentials, that is the difference between a usable step and one
    #            everybody learns to ignore.
    $workspaceRepo = @{
        type   = 'object'
        fields = @{
            url        = $reqString
            name       = @{ type = 'string'; notEmpty = $true }
            folder     = @{ type = 'string'; notEmpty = $true }
            ref        = @{ type = 'string'; notEmpty = $true }
            depth      = @{ type = 'int'; min = 1 }
            submodules = $boolNode
            optional   = $boolNode
        }
    }

    # OPTIONAL as a whole: a configuration with no 'workspace' key is valid and step 6 then has nothing to do.
    # default_folder is likewise optional, and step 6 defaults it to 'workspace', which is the folder step 1
    # already creates and the launcher already exports as DEVSYSTEM_WORKSPACE.
    $workspace = @{
        type   = 'object'
        fields = @{
            default_folder = @{ type = 'string'; notEmpty = $true }
            repositories   = @{ type = 'array'; item = $workspaceRepo }
        }
    }

    return @{
        type     = 'object'
        required = $true
        fields   = @{ environment = $environment; msys2 = $msys2; vcpkg = $vcpkg; workspace = $workspace }
    }
}

# --------------------------------------------------------------------
# HELPERS
# --------------------------------------------------------------------

function Get-DrivEnvNodeField
{
    # @brief Reads one schema field by index rather than by dot, which is what keeps a field name from colliding with
    # a real Hashtable property. Returns $null when the node does not carry it.
    param ($Node, [string]$Field)

    if ($Node -and $Node.ContainsKey($Field)) { return $Node[$Field] }
    return $null
}

function Get-DrivEnvTypeName
{
    # @brief Names the JSON type of a value, so an error can say what was actually written.
    param ($Value)

    if ($null -eq $Value)                                        { return 'null' }
    if ($Value -is [bool])                                       { return 'boolean' }
    if (($Value -is [int]) -or ($Value -is [long]))              { return 'integer' }
    if ($Value -is [double])                                     { return 'number' }
    if ($Value -is [string])                                     { return 'string' }
    if ($Value -is [array])                                      { return 'array' }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return 'object' }

    return $Value.GetType().Name
}

function Test-DrivEnvType
{
    # @brief True when the value matches the schema type.
    #
    # A boolean is deliberately NOT accepted where an int is wanted. PowerShell casts $true to 1 without complaint,
    # which is how "vhd_size_gb": true could have become a one-gigabyte drive.
    param ($Value, [string]$Type)

    switch ($Type)
    {
        'string' { return ($Value -is [string]) }
        'bool'   { return ($Value -is [bool]) }
        'int'    { return ((($Value -is [int]) -or ($Value -is [long])) -and -not ($Value -is [bool])) }
        'array'  { return ($Value -is [array]) }
        'object' { return ($Value -is [System.Management.Automation.PSCustomObject]) }
        'map'    { return ($Value -is [System.Management.Automation.PSCustomObject]) }
    }

    return $false
}

function Get-DrivEnvEditDistance
{
    # @brief Levenshtein distance, used only to turn "unknown key" into "did you mean". That is the difference between
    # a message that ends the problem and one that starts a search through the example file.
    param ([string]$A, [string]$B)

    $a = $A.ToLowerInvariant()
    $b = $B.ToLowerInvariant()
    $n = $a.Length
    $m = $b.Length
    if ($n -eq 0) { return $m }
    if ($m -eq 0) { return $n }

    $prev = New-Object 'int[]' ($m + 1)
    $curr = New-Object 'int[]' ($m + 1)
    for ($j = 0; $j -le $m; $j++) { $prev[$j] = $j }

    for ($i = 1; $i -le $n; $i++)
    {
        $curr[0] = $i
        for ($j = 1; $j -le $m; $j++)
        {
            $cost = 1
            if ($a[$i - 1] -eq $b[$j - 1]) { $cost = 0 }

            $del = $prev[$j] + 1
            $ins = $curr[$j - 1] + 1
            $sub = $prev[$j - 1] + $cost
            $curr[$j] = [Math]::Min([Math]::Min($del, $ins), $sub)
        }
        for ($j = 0; $j -le $m; $j++) { $prev[$j] = $curr[$j] }
    }

    return $prev[$m]
}

function Get-DrivEnvSuggestion
{
    # @brief The nearest known key, or $null when nothing is close enough to be worth guessing at.
    param ([string]$Name, [string[]]$Candidates)

    $best     = $null
    $bestDist = [int]::MaxValue
    foreach ($c in $Candidates)
    {
        $d = Get-DrivEnvEditDistance -A $Name -B $c
        if ($d -lt $bestDist) { $bestDist = $d; $best = $c }
    }

    # Up to a third of the name may differ, at least one character and at most three. Past that a suggestion is noise.
    $limit = [Math]::Max(1, [Math]::Min(3, [int][Math]::Floor($Name.Length / 3)))
    if ($bestDist -le $limit) { return $best }

    return $null
}

function Join-DrivEnvPath
{
    # @brief Dotted path for messages, without a leading dot at the root.
    param ([string]$Parent, [string]$Child)

    if ([string]::IsNullOrEmpty($Parent)) { return $Child }
    return "$Parent.$Child"
}

# --------------------------------------------------------------------
# WALK
# --------------------------------------------------------------------

function Test-DrivEnvNode
{
    # @brief Validates one value against one schema node, appending every problem to $Problems. Recurses.
    param ($Value, $Node, [string]$Path, $Problems)

    $type = Get-DrivEnvNodeField -Node $Node -Field 'type'

    if (-not (Test-DrivEnvType -Value $Value -Type $type))
    {
        $shown = $Path
        if ([string]::IsNullOrEmpty($shown)) { $shown = '(root)' }
        $Problems.Add(("{0}: expected {1}, found {2}" -f $shown, $type, (Get-DrivEnvTypeName $Value)))
        return
    }

    switch ($type)
    {
        'object'
        {
            $fields  = Get-DrivEnvNodeField -Node $Node -Field 'fields'

            # Piped rather than @($Value.PSObject.Properties.Name), which looks equivalent and is not. On an object
            # with NO properties -- a bare {} in the JSON -- the member access yields $null, and @($null) is an
            # array holding one null, not an empty array. The loop below then ran once with $k = $null and
            # $fields.ContainsKey($null) threw "Value cannot be null. (Parameter 'key')", so an empty section
            # crashed the validator instead of validating clean. Piping yields nothing for nothing.
            $present = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
            $known   = @($fields.Keys)

            foreach ($k in $present)
            {
                if (-not $fields.ContainsKey($k))
                {
                    $childPath = Join-DrivEnvPath $Path $k
                    $sug = Get-DrivEnvSuggestion -Name $k -Candidates $known
                    if ($sug) { $Problems.Add("${childPath}: unknown key. Did you mean '$sug'?") }
                    else      { $Problems.Add("${childPath}: unknown key") }
                    continue
                }

                Test-DrivEnvNode -Value $Value.$k -Node $fields[$k] -Path (Join-DrivEnvPath $Path $k) -Problems $Problems
            }

            foreach ($k in $known)
            {
                if ((Get-DrivEnvNodeField -Node $fields[$k] -Field 'required') -and ($present -notcontains $k))
                {
                    $Problems.Add(("{0}: required key is missing" -f (Join-DrivEnvPath $Path $k)))
                }
            }
        }

        'map'
        {
            $valueNode = Get-DrivEnvNodeField -Node $Node -Field 'valueNode'
            foreach ($p in $Value.PSObject.Properties)
            {
                Test-DrivEnvNode -Value $p.Value -Node $valueNode -Path (Join-DrivEnvPath $Path $p.Name) -Problems $Problems
            }
        }

        'array'
        {
            $item = Get-DrivEnvNodeField -Node $Node -Field 'item'
            for ($i = 0; $i -lt $Value.Count; $i++)
            {
                Test-DrivEnvNode -Value $Value[$i] -Node $item -Path ("{0}[{1}]" -f $Path, $i) -Problems $Problems
            }
        }

        'string'
        {
            $notEmpty = Get-DrivEnvNodeField -Node $Node -Field 'notEmpty'
            $allowed  = Get-DrivEnvNodeField -Node $Node -Field 'allowed'
            $pattern  = Get-DrivEnvNodeField -Node $Node -Field 'pattern'

            if ($notEmpty -and [string]::IsNullOrWhiteSpace($Value))
            {
                $Problems.Add("${Path}: must not be empty")
            }

            if ($allowed -and -not [string]::IsNullOrWhiteSpace($Value))
            {
                if (@($allowed) -notcontains $Value.Trim().ToLowerInvariant())
                {
                    $Problems.Add(("{0}: '{1}' is not one of: {2}" -f $Path, $Value, (@($allowed) -join ', ')))
                }
            }

            if ($pattern -and ($Value -notmatch $pattern))
            {
                $Problems.Add(("{0}: '{1}' does not match {2}" -f $Path, $Value, $pattern))
            }
        }

        'int'
        {
            $min = Get-DrivEnvNodeField -Node $Node -Field 'min'
            if (($null -ne $min) -and ($Value -lt $min))
            {
                $Problems.Add(("{0}: {1} is below the minimum of {2}" -f $Path, $Value, $min))
            }
        }
    }
}

# --------------------------------------------------------------------
# CROSS-FIELD RULES
# --------------------------------------------------------------------

function Test-DrivEnvRules
{
    # @brief The checks that need more than one key, or that a type cannot express.
    #
    # The ${REFERENCE} expansion inside custom_variables is deliberately NOT re-checked here. Steps 1 and 3 already
    # validate it and refuse to write a file that would produce an empty PATH component; a second copy of that logic
    # would only give the two something to disagree about.
    param ($Config, $Problems)

    $vcpkgSource = $Config.vcpkg.source
    if ($vcpkgSource -and ("$($vcpkgSource.baseline_mode)".Trim().ToLowerInvariant() -eq 'fixed'))
    {
        if ([string]::IsNullOrWhiteSpace($vcpkgSource.baseline_commit))
        {
            $Problems.Add("vcpkg.source.baseline_commit: required when baseline_mode is 'fixed'")
        }
    }

    $environment = $Config.environment
    if ($environment -and ($environment.PSObject.Properties.Name -contains 'custom_folders'))
    {
        $i = 0
        foreach ($f in @($environment.custom_folders))
        {
            $p = "environment.custom_folders[$i]"
            $i++

            if ($f -isnot [string]) { continue }   # the type walk has already reported this one

            if ([System.IO.Path]::IsPathRooted($f))
            {
                $Problems.Add("${p}: '$f' must be relative to the drive root, not absolute")
            }
            if ($f.Contains('..'))
            {
                $Problems.Add("${p}: '$f' must not contain '..'")
            }
        }
    }

    # A pinned package with no version is the one shape that makes pinning meaningless: step 2 would be looking for a
    # file it cannot name.
    if ($Config.msys2 -and $Config.msys2.packages)
    {
        $i = 0
        foreach ($p in @($Config.msys2.packages))
        {
            $path = "msys2.packages[$i]"
            $i++

            if (("$($p.mode)".Trim().ToLowerInvariant() -eq 'pinned') -and [string]::IsNullOrWhiteSpace($p.version))
            {
                $Problems.Add("${path}.version: required when mode is 'pinned' (package '$($p.name)')")
            }
        }
    }
}

# --------------------------------------------------------------------
# ENTRY POINT
# --------------------------------------------------------------------

function Test-DrivEnvConfig
{
    # @brief Validates a parsed configuration. Returns every problem found as an array of strings, empty when the
    # configuration is good.
    #
    # Every problem, not the first: a list is fixed in one pass, whereas one error per run is one run per error.
    param ($Config)

    $problems = New-Object 'System.Collections.Generic.List[string]'

    if ($null -eq $Config)
    {
        $problems.Add("the configuration file parsed to nothing")
        return $problems.ToArray()
    }

    Test-DrivEnvNode -Value $Config -Node (Get-DrivEnvConfigSchema) -Path '' -Problems $problems
    Test-DrivEnvRules -Config $Config -Problems $problems

    return $problems.ToArray()
}
