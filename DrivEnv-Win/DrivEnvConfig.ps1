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

            # The architecture tag in the package FILE name, which is not always the target architecture: most
            # mingw packages are published as "any", and a handful of scripted msys ones are too. Step 2 has
            # read this key since it was written; the schema did not declare it, so any configuration that
            # actually used it was rejected as having an unknown key. Declaring it is the fix.
            file_arch = @{ type = 'string'; notEmpty = $true }
        }
    }

    # triplet is OPTIONAL and overrides vcpkg.target.triplet for this package alone. Fast DDS is why it
    # exists: its MinGW DLL does not export what a publisher needs, so it must be built statically inside an
    # otherwise dynamic environment. No separate "default triplet" key: target.triplet already is the default.
    # AN INSTALL SCHEDULE: one entry per attempt, in order, each saying what build concurrency that attempt
    # gets. The LENGTH of the list is the attempt count, so the two things a difficult machine needs tuning for
    # are one list rather than two keys that can disagree with each other.
    #
    # concurrency 0, or an entry with no fields at all, means "let vcpkg size the build from the hardware" --
    # nothing is exported and the behaviour is vcpkg's default. A value of N exports VCPKG_MAX_CONCURRENCY=N,
    # which vcpkg passes down to make and ninja, so it reaches the compiler processes and not just vcpkg's own
    # scheduling.
    #
    # Why this shape at all: the failures worth retrying are resource-shaped. A machine with 32 hardware threads
    # and 16 GB of RAM exhausts memory long before it exhausts cores, and the compiler then dies in ways that
    # look like compiler bugs -- a segfault at a different optimisation pass on every run. Retrying identically
    # just rolls the same dice; retrying with fewer parallel jobs changes the odds.
    $installAttempt = @{
        type   = 'object'
        fields = @{
            concurrency = @{ type = 'int'; min = 0 }
        }
    }

    $installSchedule = @{ type = 'array'; item = $installAttempt }

    # LAYERED OVERLAY PORTS, resolved per port from that port's triplet.
    #
    # Shaped as an ordered ARRAY rather than a map from triplet to layers, because the validator has no node
    # type for an object with arbitrary keys and inventing one to save a few characters of JSON would be the
    # wrong trade. The array reads well anyway: the specific entries first, the catch-all last.
    #
    #   "overlay_ports": [
    #     { "triplet": "x64-mingw-clang-dynamic-release", "layers": ["ports.clang", "ports"] },
    #     { "triplet": "*",                               "layers": ["ports"] }
    #   ]
    #
    # 'triplet' is matched EXACTLY; "*" matches any triplet no other entry names. 'layers' are directory names
    # under vcpkg_overlays/ in the repository, and under <drive>:/overlays/ once installed, searched IN ORDER --
    # vcpkg takes the first layer that contains the port, which is what makes a specific layer able to override
    # the shared one. Verified with a real vcpkg invocation: two repeated --overlay-ports flags, the first an
    # empty directory, still resolved a port out of the second.
    #
    # Absent entirely, every triplet gets ["ports"], which is exactly what this generator did before layers
    # existed.
    #
    # WHEN TO USE A LAYER AND WHEN NOT TO. A layer copies a whole portfile, so two copies then have to be kept
    # in step through every baseline bump -- and they will not be. Prefer a conditional INSIDE the shared port
    # for a delta of a line or two; the gstreamer overlay does exactly that, branching on VCPKG_C_COMPILER.
    # Reach for a layer only when a port needs wholesale different treatment. Note also that of the three
    # compiler-specific problems found while bringing up a clang environment, TWO were upstream bugs whose
    # fixes are correct for GCC as well, so they belong in the shared layer and need no separation at all.
    $overlayLayerSet = @{
        type   = 'object'
        fields = @{
            triplet = @{ type = 'string'; required = $true; notEmpty = $true }
            layers  = @{ type = 'array';  required = $true; item = @{ type = 'string'; notEmpty = $true } }
        }
    }

    $vcpkgPackage = @{
        type   = 'object'
        fields = @{
            name     = $reqString
            features = @{ type = 'array'; item = $stringNode }
            triplet  = @{ type = 'string'; notEmpty = $true }

            # Both OPTIONAL, and both mean for this one port what the same-named keys under vcpkg mean for all of
            # them. They exist because the ports that need throttling are not the ports that need retrying:
            # qtbase and opencv4 have translation units that take gigabytes on their own and want a low
            # concurrency from the FIRST attempt, while a small port that failed once is worth simply trying
            # again at full speed. A single global schedule cannot express both without penalising everything.
            install_schedule     = $installSchedule
            max_install_attempts = @{ type = 'int'; min = 1 }
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
            # THE THREE NAMES A SUBSYSTEM HAS, which this used to conflate into one "profile".
            #
            #   subsystem       the MSYSTEM value and the install directory   clang64 -> /clang64
            #   repo_subpath    where the packages live on repo.msys2.org     mingw/clang64
            #   package_prefix  what a package is actually called             mingw-w64-clang-x86_64-<name>
            #
            # Normally you write only 'subsystem' and step 2 derives the rest from a table verified against
            # repo.msys2.org. The other two are overrides, for a subsystem added after that table was written.
            #
            # 'profile' is the LEGACY spelling and still works: it means subsystem = "<profile>64", which is
            # what the old code assumed. It stays required=false rather than being removed so that a
            # configuration written before this change keeps validating; one of the two must be present, and
            # step 2 is where that is enforced because only it knows the table.
            #
            # 'arch' is optional now: every subsystem in the table carries its own default, and getting it
            # wrong is how you ask clangarm64 for x86_64 packages.
            target   = @{
                type     = 'object'
                required = $true
                fields   = @{
                    profile        = @{ type = 'string'; notEmpty = $true }
                    subsystem      = @{ type = 'string'; notEmpty = $true }
                    package_prefix = @{ type = 'string'; notEmpty = $true }
                    repo_subpath   = @{ type = 'string'; notEmpty = $true }
                    arch           = @{ type = 'string'; notEmpty = $true }

                    # The compiler family, 'gcc' or 'clang'. Only needed for a subsystem the script's table
                    # does not list, since for the known ones it comes from there. It exists because the
                    # family cannot be sniffed: clang64's gcc.exe and g++.exe are copies of clang.
                    family         = @{ type = 'string'; notEmpty = $true; allowed = @('gcc', 'clang') }

                    base_url       = $stringNode
                }
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

            # How many times step 4 will try a port before giving up. Optional; step 4 defaults it to 2, and the
            # retry runs with concurrency forced to 1.
            #
            # It is configurable because it is a property of the MACHINE, not of the configuration. One machine
            # here needed FIVE attempts to get qtshadertools through, with GCC segfaulting at a different
            # optimisation pass and inside a different function on each run -- a compiler bug is deterministic, so
            # crashing somewhere different every time is hardware. Raise it on a machine like that; leave it alone
            # on one that does not need it, because a high value on a healthy machine only turns a genuine build
            # error into a long wait.
            max_install_attempts = @{ type = 'int'; min = 1 }

            # The DEFAULT schedule for every port that does not declare its own. Optional: with neither this nor
            # max_install_attempts, step 4 behaves exactly as it always has -- first attempt at vcpkg's own
            # concurrency, every attempt after it serialised. max_install_attempts still works alongside this
            # and sets the LENGTH: it truncates a longer schedule, and extends a shorter one by repeating its
            # last entry, which is the conservative one.
            install_schedule = $installSchedule

            overlay_ports = @{ type = 'array'; item = $overlayLayerSet }

            # Where vcpkg unpacks and compiles. Optional; step 4 defaults it to <drive>:/bt.
            #
            # This is not a tidiness preference, it is a hard limit. vcpkg builds each port under
            # <root>/buildtrees/<port>/<triplet>-rel/, and with a triplet name like
            # x64-mingw-ucrt-dynamic-release that prefix alone is 69 characters. Qt's autogen filenames are
            # enormous, and the total reached 261 against the 260-character cap Windows applies to any program
            # that has not opted into long paths through its application manifest. MSYS2's GCC has not, so
            # LongPathsEnabled=1 in the registry does not rescue it, and qtdeclarative fails with
            # "error: opening dependency file ...: No such file or directory".
            #
            # <drive>:/bt spends 6 characters where the default spends 20, which put that same path at 247.
            # Nothing is lost by moving it: buildtrees is scratch, it is not part of any package ABI -- a
            # vcpkg_abi_info.txt has no entry for it -- and it is deleted after each port when
            # clean-buildtrees is in effect.
            #
            # A FOLDER, RELATIVE TO THE DEV DRIVE: "bt", or "scratch/bt" for a chain. Do not spell the drive
            # letter here -- environment.dev_drive_letter already says which drive this is, and repeating it
            # only creates a second place for the answer to come from. Resolve-DrivEnvBuildtreesRoot below is
            # the single thing that turns this into a path, so every step agrees by construction.
            buildtrees_root = @{ type = 'string'; notEmpty = $true }
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

function Set-DrivEnvFileValues
{
    # @brief Write KEY=VALUE entries into the generated .env, idempotently, leaving PATH last.
    #
    # WHY THIS EXISTS. Step 2 used to append its block with a StreamWriter opened for append and nothing else.
    # Run it twice -- which is exactly what happens when a step fails and is retried, and it happened -- and the
    # file ends up carrying every key twice. Observed on a real drive: DEVSYSTEM_TOOLCHAIN_ROOT, MSYS2_ROOT,
    # BASE_PATH and five others written once at line 7 and again at line 32.
    #
    # The duplicate was harmless only because both runs computed the same values. Had anything changed between
    # them -- a different subsystem, a moved drive -- the file would have held both answers, and which one won
    # would depend on how the reader happened to iterate.
    #
    # PATH LAST IS AN INVARIANT, not tidiness. The launcher bootstrap expands ${...} line by line, so a PATH
    # written before the variables it references resolves against whatever they were at that point, or to
    # nothing. The duplicate block above landed AFTER the PATH line and redefined BASE_PATH behind it. So this
    # lifts any PATH assignment out and re-appends it at the end, whichever step wrote it.
    #
    # SECTIONS EXIST TO MAKE REMOVAL POSSIBLE. Deduplicating by key can only ever replace a key the caller still
    # writes; a key a step STOPS writing has nothing to match it and survives forever in every .env already on
    # disk. MINGW_ROOT is the live example -- it is deprecated and about to go, and without a fenced block the
    # day it disappears from step 2 is the day it becomes immortal on every existing drive. A fence also keeps
    # the file readable, since it says which step owns which lines, and any prose put between the markers is
    # replaced with them rather than stacking. Without -Section the by-key behaviour is all you get.
    #
    # @param Path    The .env file. Created if absent.
    # @param Values  Hashtable of KEY = value, emitted in enumeration order. Use an ordered hashtable if order
    #                matters. Existing lines for these keys are dropped, not duplicated.
    # @param Lines   Literal lines -- comments, blanks and KEY=value alike -- emitted verbatim before $Values.
    #                Keys are parsed out of them, so they deduplicate exactly like $Values entries do.
    # @param Section Name of the block. When given, the written lines are fenced by markers and a previous
    #                block with the same name is removed entirely, comments included.
    param
    (
        [string]  $Path,
                  $Values  = $null,
        [string[]]$Lines   = $null,
        [string]  $Section = $null
    )

    # One ordered block of literal lines, whichever shape the caller used.
    $block = @()
    if ($Lines)  { $block += $Lines }
    if ($Values) { foreach ($key in $Values.Keys) { $block += ("{0}={1}" -f $key, $Values[$key]) } }

    # The keys this call owns are simply the ones it is about to write. Parsing them back out of $block rather
    # than tracking them separately means a KEY=value buried in $Lines is deduplicated too, not just the ones
    # that came in through $Values. The name pattern is what keeps a comment containing an "=" out of the set.
    $owned = @()
    foreach ($raw in $block)
    {
        $line = [string]$raw
        $idx  = $line.IndexOf("=")
        if ($idx -gt 0)
        {
            $key = $line.Substring(0, $idx).Trim()
            if ($key -match '^[A-Za-z_][A-Za-z0-9_]*$') { $owned += $key }
        }
    }

    $open  = "# >>> drivenv:{0}" -f $Section
    $close = "# <<< drivenv:{0}" -f $Section

    # A REWRITE MUST NOT MOVE THE BLOCK. Removing the old section and appending the new one at the end reorders
    # the file every time a step is retried, and order is load-bearing: the launcher bootstrap expands ${...}
    # line by line, so a block that references a name defined by a later block resolves to nothing. So the
    # removal leaves a marker behind and the new block goes back into that exact position. Only a section the
    # file has never seen is appended.
    $slot = " drivenv-slot-" + [guid]::NewGuid().ToString()

    $kept = @()
    if (Test-Path -LiteralPath $Path)
    {
        $inSection = $false
        foreach ($raw in (Get-Content -LiteralPath $Path))
        {
            $line = [string]$raw
            if ($Section)
            {
                if ($line.Trim() -eq $open)  { $inSection = $true;  $kept += $slot; continue }
                if ($line.Trim() -eq $close) { $inSection = $false; continue }
                if ($inSection) { continue }
            }
            $idx = $line.IndexOf("=")
            if ($idx -gt 0 -and ($owned -contains $line.Substring(0, $idx).Trim())) { continue }
            $kept += $line
        }
    }

    # Whatever was removed took its own blank lines with it and left the neighbours', which would otherwise
    # accumulate one per re-run -- at the head of the file, at the tail, and wherever two blocks used to meet.
    $norm = @()
    foreach ($raw in $kept)
    {
        $line = [string]$raw
        if ([string]::IsNullOrWhiteSpace($line))
        {
            if ($norm.Count -eq 0) { continue }
            if ([string]::IsNullOrWhiteSpace([string]$norm[-1])) { continue }
        }
        $norm += $line
    }
    $last = $norm.Count - 1
    while ($last -ge 0 -and [string]::IsNullOrWhiteSpace([string]$norm[$last])) { $last-- }
    $kept = if ($last -ge 0) { @($norm[0..$last]) } else { @() }

    $fenced = @()
    if ($Section) { $fenced += $open }
    $fenced += $block
    if ($Section) { $fenced += $close }

    $out = @()
    if ($kept -contains $slot)
    {
        foreach ($line in $kept)
        {
            if ($line -eq $slot) { $out += $fenced } else { $out += $line }
        }
    }
    else
    {
        $out += $kept
        if ($out.Count -gt 0 -and $Section) { $out += "" }
        $out += $fenced
    }

    # PATH to the very end, wherever it came from -- and deliberately AFTER the closing marker, so it belongs to
    # no block. Lifting it inside the fence would read better and would mean that re-running step 2, whose block
    # would then enclose a PATH line step 3 wrote, deletes PATH outright and leaves the environment unlaunchable.
    # Outside every fence it is protected by the key rule alone, and only the step that owns it can replace it.
    $pathLines = @($out | Where-Object { ([string]$_).TrimStart().StartsWith("PATH=") })
    if ($pathLines.Count -gt 0)
    {
        $out = @($out | Where-Object { -not ([string]$_).TrimStart().StartsWith("PATH=") }) + $pathLines
    }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, [string[]]$out, $utf8NoBom)
}

function Add-DrivEnvWindowsSystemPath
{
    # @brief Make sure THIS PROCESS can find powershell.exe, cmd.exe and where.exe, whatever PATH it inherited.
    #
    # WHAT THIS FIXES. vcpkg's bootstrap-vcpkg.bat downloads the vcpkg tool with powershell.exe, and a plain
    # .bat finds it the only way a .bat can: by searching PATH. Run one of these steps from a shell whose PATH
    # has been narrowed -- an environment launcher, a task scheduler, a stripped terminal -- and the bootstrap
    # dies with "powershell.exe no se reconoce como un comando interno o externo", which points at vcpkg and is
    # nothing to do with vcpkg.
    #
    # DERIVED FROM SystemRoot, NOT FROM PATH, because PATH is exactly what cannot be trusted here. And appended
    # at the TAIL, never prepended: System32 shadowing the toolchain is the failure this project has already
    # been bitten by once, with make.exe. Presence and precedence are different problems and this only fixes
    # the first.
    #
    # This is the HOST process, and it changes nothing about the generated environment: step 2 puts the same
    # four directories in the .env unconditionally, for the same reasons, and neither reads the other.
    #
    # @param Report Optional scriptblock taking one string, called once if anything was added.
    param ([scriptblock] $Report = $null)

    $root = [string]$env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = "C:\Windows" }

    $system32 = Join-Path $root "System32"
    $wanted = @(
        $system32,
        $root,
        (Join-Path $system32 "Wbem"),
        (Join-Path (Join-Path $system32 "WindowsPowerShell") "v1.0")
    )

    $present = @()
    foreach ($entry in (([string]$env:PATH) -split ';'))
    {
        $trimmed = $entry.Trim().TrimEnd('\')
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) { $present += $trimmed.ToLowerInvariant() }
    }

    $added = @()
    foreach ($dir in $wanted)
    {
        if (($present -notcontains $dir.TrimEnd('\').ToLowerInvariant()) -and (Test-Path -LiteralPath $dir))
        {
            $env:PATH = "{0};{1}" -f $env:PATH.TrimEnd(';'), $dir
            $added += $dir
        }
    }

    if ($added.Count -gt 0 -and $Report)
    {
        & $Report ("Appended {0} Windows system director(y/ies) to this process's PATH so a .bat can find " -f $added.Count)
        & $Report ("powershell.exe and cmd.exe: {0}" -f ($added -join '; '))
    }

    return $added
}

function Resolve-DrivEnvBuildtreesRoot
{
    # @brief Turn vcpkg.buildtrees_root into every form the steps need, from one definition.
    #
    # WHY THIS IS SHARED. Step 1 creates the directory and step 4 hands the path to vcpkg, and each used to
    # normalise the setting itself -- with different rules. Step 1 stripped any drive letter and created the
    # folder on the drive it had just mounted; step 4 kept the letter and passed it through. So a configuration
    # naming one drive while environment.dev_drive_letter named another did not fail: step 1 made <drive>:/bt
    # and step 4 told vcpkg to build somewhere else entirely, and the run half-filled two disks in silence.
    # Two consumers, one definition, and the disagreement cannot be written any more.
    #
    # THE SETTING IS A FOLDER, RELATIVE TO THE DEV DRIVE. An absolute form is still accepted, because existing
    # configurations spell one, but the drive part is DISCARDED and said so out loud: buildtrees belongs on the
    # dev drive by design -- the whole reason the setting exists is to keep the path short on that drive -- and
    # honouring a foreign letter here would resurrect exactly the split this function removes.
    #
    # @param Cfg         The parsed configuration.
    # @param DriveLetter The dev drive letter, with or without a colon.
    # @param Warn        Optional scriptblock taking one string, called for anything worth reporting.
    # @return A hashtable: Folder ("bt"), Windows ("N:/bt") and Posix ("/n/bt").
    param
    (
        [object]      $Cfg,
        [string]      $DriveLetter,
        [scriptblock] $Warn = $null
    )

    $letter = ([string]$DriveLetter).Trim().TrimEnd(@(':', '\', '/'))
    $folder = "bt"

    $given = ""
    if ($Cfg -and $Cfg.vcpkg -and ($Cfg.vcpkg.PSObject.Properties.Name -contains "buildtrees_root"))
        { $given = ([string]$Cfg.vcpkg.buildtrees_root).Trim().Replace('\', '/') }

    if (-not [string]::IsNullOrWhiteSpace($given))
    {
        $stripped = $given
        $had_drive = ""

        if     ($stripped -match '^([A-Za-z]):/?(.*)$') { $had_drive = $Matches[1]; $stripped = $Matches[2] }
        elseif ($stripped -match '^/([A-Za-z])/(.*)$')  { $had_drive = $Matches[1]; $stripped = $Matches[2] }

        $stripped = $stripped.Trim('/')

        # A colon surviving the patterns above means a shape neither of them recognised -- "S:" alone, or
        # something hand-edited into nonsense -- and a directory name cannot hold one.
        if ([string]::IsNullOrWhiteSpace($stripped) -or $stripped -match '\.\.' -or $stripped -match ':')
        {
            if ($Warn) { & $Warn ("vcpkg.buildtrees_root '{0}' is not a folder on the drive; using '{1}'." -f $given, $folder) }
        }
        else
        {
            $folder = $stripped

            if (-not [string]::IsNullOrWhiteSpace($had_drive) -and
                ($had_drive.ToUpperInvariant() -ne $letter.ToUpperInvariant()))
            {
                if ($Warn)
                {
                    & $Warn ("vcpkg.buildtrees_root names drive '{0}:' but the dev drive is '{1}:'. Buildtrees " -f $had_drive.ToUpperInvariant(), $letter.ToUpperInvariant())
                    & $Warn ("always go on the dev drive, so '{0}:/{1}' is what will be used. Drop the letter " -f $letter.ToUpperInvariant(), $folder)
                    & $Warn ("from the setting -- it is a folder relative to the drive, and naming one here is")
                    & $Warn ("how a run used to build on one disk while installing on another.")
                }
            }
        }
    }

    return @{
        Folder  = $folder
        Windows = "{0}:/{1}" -f $letter.ToUpperInvariant(), $folder
        Posix   = "/{0}/{1}" -f $letter.ToLowerInvariant(), $folder
    }
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
