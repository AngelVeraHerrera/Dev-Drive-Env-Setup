# ====================================================================
# DRIVENV CONFIGURATION VALIDATION
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera
# Updated: 27/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Schema, validator and shared helpers for every step. An unknown key is an
# ERROR (with the nearest known key suggested), because every reader falls
# back to a default: "check_toolz" would make step 5 check nothing and pass.
# Every value is type-checked before a step acts on it.
#
# Dot-source after the caller's Write-Error/Abort-WithError exist, then call
# Test-DrivEnvConfig: nothing here prints or exits. Hand-rolled because
# Test-Json -Schema needs PowerShell 6.1 and the steps target 5.1.

# --------------------------------------------------------------------
# SCHEMA
# --------------------------------------------------------------------

function Get-DrivEnvConfigSchema
{
    # @brief Every key the steps read, with its type and allowed values.
    #
    # Node shape: type = object | map | array | string | int | bool
    #   object   fields    = @{ name = node }   every present key must be listed; required ones must be present
    #   map      valueNode = node               arbitrary key names, values all validated against one node
    #   array    item      = node
    #   string   allowed   = @(...)             optional closed set, compared case-insensitively
    #            notEmpty  = $true              optional
    #            pattern   = regex              optional
    #   int      min       = n                  optional
    # 'required' is false when absent. Field names avoid Keys/Values/Count (hashtable members), and nodes are read
    # as $node['x'], never $node.x.
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

            # The architecture tag in the package FILE name ("any" for most mingw packages), read by step 2.
            file_arch = @{ type = 'string'; notEmpty = $true }
        }
    }

    # triplet: optional per-package override of vcpkg.target.triplet (single-toolchain configurations only).
    # install_schedule: one entry per attempt (the length is the attempt count), each the build concurrency of that
    # attempt; 0 or {} lets vcpkg size the build, N exports VCPKG_MAX_CONCURRENCY=N (reaches make and ninja).
    # Retrying with fewer jobs is what helps the resource-shaped failures (memory exhaustion looking like compiler bugs).
    $installAttempt = @{
        type   = 'object'
        fields = @{
            concurrency = @{ type = 'int'; min = 0 }
        }
    }

    $installSchedule = @{ type = 'array'; item = $installAttempt }

    # Seconds before a retry, times the attempt number (30 -> 0, 30, 60, 90). Default 0. For failures concurrency cannot
    # fix, such as a proxy serving a cached 504 for minutes. Interruptible.
    $retryDelay = @{ type = 'int'; min = 0 }

    # Overlay port layers per triplet, an ordered array (specific entries first, "*" last):
    #   "overlay_ports": [
    #     { "triplet": "x64-mingw-clang-dynamic-release", "layers": ["ports.clang", "ports"] },
    #     { "triplet": "*",                               "layers": ["ports"] }
    #   ]
    # 'triplet' matches exactly; 'layers' are folders under vcpkg.overlay_root, searched in order (vcpkg takes the
    # first holding the port). Absent: ["ports"] for every triplet. Prefer a conditional inside the shared port to a
    # layer, which duplicates a whole portfile.
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

            # Per-port schedule and attempts (heavy ports want low concurrency from the first attempt).
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
            install_installation_material = $boolNode   # ignored since 3.0.0 (no installation/ tree); accepted for older files
            append_windows_system_path    = $boolNode

            # The only things put on the host rather than the drive, so they are switchable. Both default to TRUE:
            #   create_desktop_shortcuts  desktop .lnk to the VHDX (step 1) and the launchers (steps 2, 7); the
            #                             drive-root shortcuts are part of the drive and always written
            #   automount_at_startup      the scheduled task that mounts the VHDX at boot
            create_desktop_shortcuts      = $boolNode
            automount_at_startup          = $boolNode

            # Who owns the drive's files: "current" (default; the account that runs the generator, yours even from an
            # elevated terminal), "administrators", or an account name. An elevated run would otherwise leave them
            # to Administrators, and git refuses repositories another account owns. See Resolve-DrivEnvOwner.
            owner                         = @{ type = 'string'; notEmpty = $true }

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
            # A subsystem's three names: subsystem (MSYSTEM, /clang64), repo_subpath (mingw/clang64) and
            # package_prefix (mingw-w64-clang-x86_64). Write 'subsystem'; the others are overrides for subsystems the
            # table does not know. 'profile' is the legacy spelling (subsystem = "<profile>64"). 'arch' defaults per
            # subsystem. Not required here since 3.0.0: with 'toolchains' it lives in each profile, and
            # Test-DrivEnvRules checks the resolved configuration instead.
            target   = @{
                type     = 'object'
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
            # Not required either: with 'toolchains' the profiles may hold every package. Test-DrivEnvRules refuses a
            # resolved environment with none.
            packages = @{ type = 'array'; item = $msys2Package }
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
            # Not 'required' since 3.0.0: the triplet is the one value that MUST differ between two toolchains on
            # one drive, so with 'toolchains' present it lives in the profile. Same enforcement as msys2.target --
            # every resolved toolchain must end up with one.
            target   = @{
                type   = 'object'
                fields = @{ triplet = $reqString }
            }
            packages = @{ type = 'array'; required = $true; item = $vcpkgPackage }

            # Attempts per port (step 4 default 2; retries serialised). A property of the machine: one needed five
            # for qtshadertools, GCC crashing somewhere different each run (hardware, not a compiler bug).
            max_install_attempts = @{ type = 'int'; min = 1 }

            # Default schedule for ports without their own. max_install_attempts sets its length: truncates, or
            # extends by repeating the last (most conservative) entry.
            install_schedule = $installSchedule

            # Seconds to wait before a retry, growing with the attempt number. See where it is declared.
            retry_delay_seconds = $retryDelay

            # The overlay set the layers come from: a folder relative to the generator (vcpkg_overlays/degoras) or
            # absolute. Absent: no overlay ports, every package as the registry publishes it. Sets are specific to an
            # environment (baseline, compilers, packages); nothing requires one.
            overlay_root  = @{ type = 'string'; notEmpty = $true }
            overlay_ports = @{ type = 'array'; item = $overlayLayerSet }

            # Where vcpkg unpacks and compiles, relative to the drive (default "bt"). Short on purpose: Qt's autogen
            # paths under <root>/<port>/<triplet>-rel hit the 260-character limit of MSYS2's GCC (no long-path
            # manifest). Do not spell the drive letter; Resolve-DrivEnvBuildtreesRoot turns it into every path.
            buildtrees_root = @{ type = 'string'; notEmpty = $true }

            # What step 4 deletes from the build trees when it has finished (the largest thing on a drive: 12 GB of
            # 13.6 measured, all scratch):
            #   none   nothing (default)
            #   logs   each port's source and build trees, keeping its logs (~10.8 GB freed)
            #   all    each port's whole directory (~11.5 GB freed)
            # Only vcpkg's own port folders (recognised by their vcpkg_abi_info stamp), never the user's builds.
            # Cost: debuggers can no longer step into third-party sources.
            cleanup = @{
                type   = 'object'
                fields = @{
                    # notEmpty is MANDATORY next to allowed, not decoration: the validator skips the allowed
                    # check entirely for a whitespace value (:910), so without it "" would validate silently and
                    # then fall through every branch of the reader. Same shape as msys2.target.family.
                    buildtrees = @{ type = 'string'; notEmpty = $true; allowed = @('none', 'logs', 'all') }
                    # vcpkg\packages, vcpkg's staging folder: removed whole (its files are hardlinked into installed).
                    packages     = $boolNode
                    # Shared by every toolchain, so removed by the last generated one: vcpkg\downloads (re-downloaded
                    # on demand) and the binary cache (reinstalling then means building again).
                    downloads    = $boolNode
                    binary_cache = $boolNode
                }
            }
        }
    }

    # A repository for step 6. Only the URL is required; defaults live in step 6.
    #   name     clone folder (default: last URL segment without .git)
    #   folder   destination root, relative to the drive (default: workspace.default_folder)
    #   ref      branch or tag (default: the remote's default); not a commit sha
    #   depth    shallow clone depth (default: full)
    #   optional a clone failure is a warning, not a fault
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

    # One toolchain's overrides, layered onto the shared configuration (two separate files differed in 8 of 69
    # leaves). Only what is a property of the toolchain:
    #   msys2.target              the subsystem's names, arch and compiler family
    #   msys2.packages            the compiler packages and their pins
    #   vcpkg.target              the triplet
    #   environment.verification  per-toolchain checks
    # Key paths mirror the base, so one generic merge does it all. Not here: the drive's own keys, msys2.source (one
    # MSYS2 per drive) and vcpkg.packages (shared, so the environments stay comparable).
    $toolchainProfile = @{
        type   = 'object'
        fields = @{
            environment  = @{
                type   = 'object'
                fields = @{ verification = $verification }
            }
            msys2        = @{
                type   = 'object'
                fields = @{
                    # Indexed, not dotted: see the note at the top of this function.
                    target   = $msys2['fields']['target']
                    packages = @{ type = 'array'; item = $msys2Package }
                }
            }
            vcpkg        = @{
                type   = 'object'
                fields = @{ target = $vcpkg['fields']['target'] }
            }
        }
    }

    # A map, so the id is the key. Ids are checked in Test-DrivEnvRules (they travel as -Toolchain); files are named
    # after the subsystem (Get-DrivEnvToolchainKey), not the id.
    $toolchains = @{ type = 'map'; valueNode = $toolchainProfile }

    # WHICH OF THEM THIS RUN PRODUCES, in order. Separate from 'toolchains' on purpose: what is DEFINED and what is
    # BUILT are different questions, and keeping them apart is what makes "just the clang one today" a one-token
    # edit rather than a deletion. Absent means no dual environment at all, which is exactly a 2.x configuration.
    $generate = @{ type = 'array'; item = @{ type = 'string'; notEmpty = $true } }

    # Step 7's Qt Creator. Optional; per-source requirements are checked in Test-DrivEnvRules.
    $ideIntegration = @{
        type   = 'object'
        fields = @{
            qtcreator = @{
                type   = 'object'
                fields = @{
                    # notEmpty next to allowed, as everywhere: the allowed check skips a blank value.
                    source    = @{ type = 'string'; required = $true; notEmpty = $true; allowed = @('msys2', 'external', 'none') }
                    subsystem = @{ type = 'string'; notEmpty = $true }
                    path      = @{ type = 'string'; notEmpty = $true }
                    sdktool   = @{ type = 'string'; notEmpty = $true }
                    # Also add the kits, as manual ones, to the user's own Qt Creator; off when absent. Its settings
                    # directory -- the one holding QtCreator.ini and qtcreator\ -- is user_settings_path, %VARS%
                    # expanded, %APPDATA%/QtProject when absent.
                    register_in_user_settings = @{ type = 'bool' }
                    user_settings_path        = @{ type = 'string'; notEmpty = $true }
                }
            }
        }
    }

    # The drive's git identity, written by step 2 into msys64/etc/gitconfig: the default when neither ~/.gitconfig nor
    # a repository sets one, so git never invents a <user>@<host> identity (useConfigOnly).
    $git = @{
        type   = 'object'
        fields = @{
            user_name  = @{ type = 'string'; required = $true; notEmpty = $true }
            user_email = @{ type = 'string'; required = $true; notEmpty = $true; pattern = '^[^@\s]+@[^@\s]+\.[^@\s]+$' }
        }
    }

    # What this configuration is. Shown in every step's log and recorded on the drive (step 4).
    $metadata = @{
        type   = 'object'
        fields = @{
            name        = @{ type = 'string'; notEmpty = $true }
            version     = @{ type = 'string'; notEmpty = $true }
            date        = @{ type = 'string'; pattern = '^\d{4}-\d{2}-\d{2}$' }
            author      = @{ type = 'string'; notEmpty = $true }
            target_os   = $stringNode    # free text, informational
            description = $stringNode
            notes       = @{ type = 'array'; item = $stringNode }
        }
    }

    return @{
        type     = 'object'
        required = $true
        fields   = @{
            metadata        = $metadata
            git             = $git
            environment     = $environment
            msys2           = $msys2
            vcpkg           = $vcpkg
            workspace       = $workspace
            toolchains      = $toolchains
            generate        = $generate
            ide_integration = $ideIntegration
        }
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
    # @brief True when the value matches the schema type. A bool is not an int ($true would cast to 1).
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

# --------------------------------------------------------------------
# TOOLCHAIN RESOLUTION
# --------------------------------------------------------------------
# A step calls Resolve-DrivEnvToolchain right after Test-DrivEnvConfig; from then on it reads one subsystem and one
# triplet as plain scalars, so the steps need no loop around their reads.

function Resolve-DrivEnvConfigPath
{
    # @brief The path a -ConfigFile value names: absolute as given, relative against config/ (never the caller's cwd).
    # @param ConfigFile     A bare name, a relative path or an absolute one.
    # @param GeneratorRoot  The folder holding scripts/ and config/.
    param ([string]$ConfigFile, [string]$GeneratorRoot)

    if ([System.IO.Path]::IsPathRooted($ConfigFile)) { return $ConfigFile }
    return (Join-Path (Join-Path $GeneratorRoot "config") $ConfigFile)
}

function Test-DrivEnvIsObject
{
    # @brief True for a JSON object, false for arrays, strings, numbers and $null.
    # @note ConvertFrom-Json yields PSCustomObject for every JSON object in PowerShell 5.1. Checked by type and
    #       not by "has properties", because a string has properties too and would merge instead of replacing.
    param ($Value)
    return ($Value -is [System.Management.Automation.PSCustomObject])
}

function Merge-DrivEnvValue
{
    # @brief Layers one override value onto one base value. Recurses. Objects merge key by key, ARRAYS APPEND (every
    # array a profile reaches is a list of things to do), everything else replaces.
    # @param Base     the shared value; may be $null
    # @param Override the profile value; may be $null
    param ($Base, $Override)

    if ($null -eq $Override) { return $Base }
    if ($null -eq $Base)     { return $Override }

    if (($Base -is [System.Array]) -and ($Override -is [System.Array]))
    {
        # The comma keeps the array: PowerShell unrolls a returned collection ([1] + [] came back as an Int64).
        return ,@(@($Base) + @($Override))
    }

    if ((Test-DrivEnvIsObject $Base) -and (Test-DrivEnvIsObject $Override))
    {
        $merged = New-Object PSObject
        foreach ($p in $Base.PSObject.Properties)
        {
            Add-Member -InputObject $merged -MemberType NoteProperty -Name $p.Name -Value $p.Value
        }

        foreach ($p in $Override.PSObject.Properties)
        {
            $name = $p.Name
            if (@($merged.PSObject.Properties.Name) -contains $name)
            {
                $merged.$name = Merge-DrivEnvValue -Base $merged.$name -Override $p.Value
            }
            else
            {
                Add-Member -InputObject $merged -MemberType NoteProperty -Name $name -Value $p.Value
            }
        }
        return $merged
    }

    return $Override
}

function Get-DrivEnvGenerateList
{
    # @brief The toolchain ids this configuration asks to be produced, in order.
    # @return An array of ids, EMPTY for a configuration that declares no toolchains -- which is every 2.x file
    #         and is not an error: it means "one environment, described right here", exactly as before.
    param ($Cfg)

    # Comma-returned (see Merge-DrivEnvValue). DO NOT WRAP A CALL IN @(...): it would nest the array
    # (@(...) -> Count 1, [0] = Object[]). Assign or iterate it directly.
    if ($null -eq $Cfg) { return ,@() }
    if (@($Cfg.PSObject.Properties.Name) -notcontains 'generate') { return ,@() }

    return ,@($Cfg.generate | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-DrivEnvResumeArguments
{
    # @brief The runner arguments (after -ConfigFile) that resume a stopped run: one line, or two.
    #   drive step or step 2   everything from that step, for this run's toolchains
    #   step 3 to 5            the stopped toolchain from that step to its last toolchain step; then the toolchains
    #                          after it from the first vcpkg step (their step 2 already ran)
    # DO NOT WRAP A CALL TO THIS IN @(...): it comma-returns.
    # @param Number            The step that stopped.
    # @param Id                Its toolchain, "" for a drive step.
    # @param Toolchains        This run's toolchains, in order (empty for a 2.x configuration).
    # @param FirstVcpkgStep    The first toolchain step that is not step 2 (normally 3).
    # @param LastToolchainStep The last toolchain-scoped step (5).
    param ([int]$Number, [string]$Id, [string[]]$Toolchains = @(), [int]$FirstVcpkgStep = 3, [int]$LastToolchainStep = 5)

    $all = @($Toolchains | Where-Object { $_ })
    if ((-not $Id) -or ($Number -eq 2))
    {
        if ($all.Count -eq 0) { return ,@("-From $Number") }
        return ,@("-From $Number -Toolchain " + ($all -join ','))
    }

    $after = @()
    $i = [array]::IndexOf($all, $Id)
    if ($i -ge 0) { $after = @($all | Select-Object -Skip ($i + 1)) }
    if ($after.Count -eq 0) { return ,@("-From $Number -Toolchain $Id") }
    # Parenthesised: ',' binds tighter than '+', which would otherwise make three elements of two lines.
    return ,@("-From $Number -To $LastToolchainStep -Toolchain $Id", ("-From $FirstVcpkgStep -Toolchain " + ($after -join ',')))
}

function Resolve-DrivEnvToolchain
{
    # @brief Projects a multi-toolchain configuration onto one id: a deep copy (JSON round trip, certainly total) with
    # the profile merged in and 'toolchains'/'generate' removed, shaped like a 2.x configuration.
    # @param Cfg The parsed, validated configuration.
    # @param Id  The toolchain id. An unknown id returns the base unchanged (the validator already reported it).
    param ($Cfg, [string]$Id)

    $copy = $Cfg | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json

    $tcProfile = $null
    if (@($copy.PSObject.Properties.Name) -contains 'toolchains')
    {
        $tc = $copy.toolchains
        if ((Test-DrivEnvIsObject $tc) -and (@($tc.PSObject.Properties.Name) -contains $Id))
        {
            $tcProfile = $tc.$Id
        }
    }

    if (Test-DrivEnvIsObject $tcProfile)
    {
        foreach ($p in $tcProfile.PSObject.Properties)
        {
            $name = $p.Name
            if (@($copy.PSObject.Properties.Name) -contains $name)
            {
                $copy.$name = Merge-DrivEnvValue -Base $copy.$name -Override $p.Value
            }
            else
            {
                Add-Member -InputObject $copy -MemberType NoteProperty -Name $name -Value $p.Value
            }
        }
    }

    foreach ($k in @('toolchains', 'generate'))
    {
        if (@($copy.PSObject.Properties.Name) -contains $k) { $copy.PSObject.Properties.Remove($k) }
    }

    return $copy
}

function Get-DrivEnvToolchainRoot
{
    # @brief The compiler prefix from a parsed .env: DEVSYSTEM_TOOLCHAIN_ROOT, or as a last resort (interrupted step 2)
    # MSYS2_ROOT + MSYS2_ENV, with a warning.
    # @param EnvMap    Hashtable from Read-EnvFile.
    # @param Msys2Root Prefix root for the last resort. Omit to disable it.
    # @param Msys2Env  Subsystem folder for the last resort. Omit to disable it.
    # @param Warn      Optional scriptblock taking one string.
    # @return The prefix in POSIX-slash form, or "".
    param
    (
                      $EnvMap,
        [string]      $Msys2Root = "",
        [string]      $Msys2Env  = "",
        [scriptblock] $Warn      = $null
    )

    $value = [string]$EnvMap["DEVSYSTEM_TOOLCHAIN_ROOT"]
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }

    if (-not [string]::IsNullOrWhiteSpace($Msys2Root) -and -not [string]::IsNullOrWhiteSpace($Msys2Env))
    {
        $derived = "{0}/{1}" -f $Msys2Root.TrimEnd(@('/', '\')), $Msys2Env
        if ($Warn)
        {
            & $Warn ("DEVSYSTEM_TOOLCHAIN_ROOT is not in the environment file, assuming: {0}. Re-run step 2." -f $derived)
        }
        return $derived
    }

        # An empty answer is reported, never just returned (it once surfaced as 172 libraries failing to load).
    if ($Warn)
    {
        & $Warn "DEVSYSTEM_TOOLCHAIN_ROOT is not in the environment file and cannot be derived from it. Whatever needs the toolchain prefix is about to go without it. Re-run step 2."
    }

    return ""
}

function Set-DrivEnvFileValues
{
    # @brief Write KEY=VALUE entries into the generated .env idempotently (a retried step must not duplicate keys),
    # keeping PATH last: the launcher expands ${...} line by line. Sections group the file by owning step and let a
    # re-run replace its own block. A section cannot retire a key written before fences existed: use -Retire.
    # @param Path    The .env file. Created if absent.
    # @param Values  Hashtable of KEY = value, in enumeration order (use [ordered]). Existing lines for these keys are
    #                dropped, not duplicated.
    # @param Lines   Literal lines emitted verbatim before $Values; their keys deduplicate like $Values.
    # @param Section Block name: the lines are fenced, and a previous block of that name is replaced in place.
    # @param Retire  Names to delete wherever they are, without writing them back.
    # @param First   With -Section, for a block the file has never held: put it at the top (the drive header, which
    #                every later block references).
    param
    (
        [string]  $Path,
                  $Values  = $null,
        [string[]]$Lines   = $null,
        [string]  $Section = $null,
        [string[]]$Retire  = @(),
        [switch]  $First
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

    foreach ($key in $Retire) { if ($key) { $owned += ([string]$key).Trim() } }

    $open  = "# >>> drivenv:{0}" -f $Section
    $close = "# <<< drivenv:{0}" -f $Section

    # A rewritten block keeps its position (order matters for ${...} expansion); only a new section is placed anew.
    $slot = " drivenv-slot-" + [guid]::NewGuid().ToString()

    $kept = @()
    if (Test-Path -LiteralPath $Path)
    {
        $inSection = $false
        # READ AS UTF-8, which is how this writes it. Get-Content in Windows PowerShell 5.1 reads a file without a BOM as
        # the ANSI code page, so every rewrite double-encoded each non-ASCII character it had not written itself -- a
        # dev_drive_label "DEV_ÑANDÚ" came out of step 2 already mangled, and worse after step 3. Measured.
        foreach ($raw in [System.IO.File]::ReadAllLines($Path, (New-Object System.Text.UTF8Encoding($false))))
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
    elseif ($First -and $Section)
    {
        $out += $fenced
        if ($kept.Count -gt 0) { $out += "" }
        $out += $kept
    }
    else
    {
        $out += $kept
        if ($out.Count -gt 0 -and $Section) { $out += "" }
        $out += $fenced
    }

    # PATH goes last, outside every fence, so re-running another step's block can never delete it.
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
    # @brief Make sure THIS process finds powershell.exe, cmd.exe and where.exe (bootstrap-vcpkg.bat needs powershell),
    # whatever PATH it inherited. Derived from SystemRoot and appended at the tail, never prepended. The generated .env
    # gets the same directories separately (step 2).
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
    # @brief vcpkg.buildtrees_root in every form the steps need, from one definition (step 1 creates it, step 4 hands
    # it to vcpkg). A folder relative to the drive; a drive letter in it is discarded, with a warning. vcpkg's root
    # stays <drive>:/<folder>; the user's builds get <drive>:/<folder>/<triplet> (DEVSYSTEM_BUILDTREES).
    # @param Cfg         The parsed configuration.
    # @param DriveLetter The dev drive letter, with or without a colon.
    # @param Warn        Optional scriptblock taking one string.
    # @param Triplet     Optional. When given, ToolchainWindows is returned as well.
    # @return @{ Folder ("bt"); Windows ("N:/bt"); Posix ("/n/bt");
    #         EnvValue ('${DEVDRIVE_LETTER}/bt/${VCPKG_DEFAULT_TRIPLET}', literally);
    #         ToolchainWindows ("N:/bt/x64-mingw-clang-dynamic-release", with -Triplet) }
    param
    (
        [object]      $Cfg,
        [string]      $DriveLetter,
        [scriptblock] $Warn    = $null,
        [string]      $Triplet = ""
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

    $result = @{
        Folder  = $folder
        Windows = "{0}:/{1}" -f $letter.ToUpperInvariant(), $folder
        Posix   = "/{0}/{1}" -f $letter.ToLowerInvariant(), $folder

        # SINGLE QUOTES AND CONCATENATION, AND NEITHER IS STYLE. In double quotes PowerShell would expand
        # ${DEVDRIVE_LETTER} as one of its own variables, which does not exist, and write "/bt/". Through -f
        # the braces are format items, and '{DEVDRIVE_LETTER}' throws a FormatException.
        EnvValue = '${DEVDRIVE_LETTER}/' + $folder + '/${VCPKG_DEFAULT_TRIPLET}'
    }

    $tripletName = ([string]$Triplet).Trim()
    if (-not [string]::IsNullOrWhiteSpace($tripletName))
    {
        $result['ToolchainWindows'] = $result['Windows'] + '/' + $tripletName
    }

    return $result
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
# TOOLCHAIN IDENTITY AND NAMES
# --------------------------------------------------------------------
# Every per-toolchain file is named after the toolchain KEY, the MSYS2 subsystem (clang64, ucrt64), with one
# toolchain as with two; the profile id ('clang') only travels as -Toolchain. Every name is built here and nowhere
# else. Paths are joined as strings: Join-Path throws for a drive that is not mounted yet.

function Get-DrivEnvToolchainKey
{
    # @brief The toolchain key: msys2.target.subsystem trimmed and lowered, else the legacy profile + "64", else "".
    # Never throws (the validator calls it on configurations it is rejecting).
    # @param Cfg    A projected or 2.x configuration. Read only when -Target is not given.
    # @param Target The msys2.target object. Defaults to $Cfg.msys2.target.
    # @return The key, or "".
    param ($Cfg = $null, $Target = $null)

    if (($null -eq $Target) -and ($null -ne $Cfg) -and ($null -ne $Cfg.msys2)) { $Target = $Cfg.msys2.target }
    if ($null -eq $Target) { return "" }

    # Piped, for the reason the walker gives: on an object with no properties the member access yields $null, and
    # @($null) holds one null.
    $names = @($Target.PSObject.Properties | ForEach-Object { $_.Name })

    if ($names -contains 'subsystem')
    {
        $subsystem = ([string]$Target.subsystem).Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($subsystem)) { return $subsystem }
    }

    # Not $profile: that is an automatic variable, and assigning to it works, which is what makes it quiet.
    if ($names -contains 'profile')
    {
        $legacy = ([string]$Target.profile).Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($legacy)) { return ($legacy + '64') }
    }

    return ""
}

function Get-DrivEnvMsys2SubsystemTable
{
    # @brief The known subsystems with their repo.msys2.org names (a table: mingw64 has no infix, clangarm64's subpath is
    # not <infix>64) and compiler family (cannot be sniffed: clang64's gcc.exe is clang).
    # @return A hashtable keyed by subsystem; each value is @{ Prefix; Subpath; Arch; Family }.
    return @{
        'ucrt64'     = @{ Prefix = 'mingw-w64-ucrt-x86_64';   Subpath = 'mingw/ucrt64';     Arch = 'x86_64';  Family = 'gcc'   }
        'clang64'    = @{ Prefix = 'mingw-w64-clang-x86_64';  Subpath = 'mingw/clang64';    Arch = 'x86_64';  Family = 'clang' }
        'mingw64'    = @{ Prefix = 'mingw-w64-x86_64';        Subpath = 'mingw/mingw64';    Arch = 'x86_64';  Family = 'gcc'   }
        'clangarm64' = @{ Prefix = 'mingw-w64-clang-aarch64'; Subpath = 'mingw/clangarm64'; Arch = 'aarch64'; Family = 'clang' }
        'mingw32'    = @{ Prefix = 'mingw-w64-i686';          Subpath = 'mingw/mingw32';    Arch = 'i686';    Family = 'gcc'   }
        'clang32'    = @{ Prefix = 'mingw-w64-clang-i686';    Subpath = 'mingw/clang32';    Arch = 'i686';    Family = 'clang' }
    }
}

function Resolve-DrivEnvMsys2Target
{
    # @brief A subsystem's names out of msys2.target:
    #   Subsystem  MSYSTEM and install folder (the toolchain key)   clang64
    #   Prefix     package name prefix                            mingw-w64-clang-x86_64
    #   Subpath    repo.msys2.org path                            mingw/clang64
    #   Arch       target architecture                            x86_64
    #   Family     'gcc' or 'clang'                               clang
    # The table gives defaults; package_prefix, repo_subpath, arch and family override them. Unresolvable parts come
    # back "" without printing; the caller decides.
    # @param Target The msys2.target object.
    # @return @{ Subsystem; Prefix; Subpath; Arch; Family } (a hashtable, never unrolled).
    param ($Target)

    $names = @()
    if ($null -ne $Target) { $names = @($Target.PSObject.Properties | ForEach-Object { $_.Name }) }

    $subsystem = Get-DrivEnvToolchainKey -Target $Target
    $table     = Get-DrivEnvMsys2SubsystemTable

    $prefix  = ""
    $subpath = ""
    $arch    = ""
    $family  = ""

    if ((-not [string]::IsNullOrWhiteSpace($subsystem)) -and $table.ContainsKey($subsystem))
    {
        $prefix  = $table[$subsystem].Prefix
        $subpath = $table[$subsystem].Subpath
        $arch    = $table[$subsystem].Arch
        $family  = $table[$subsystem].Family
    }

    # Explicit overrides win over the table.
    if ($names -contains 'package_prefix')
    {
        $v = ([string]$Target.package_prefix).Trim()
        if (-not [string]::IsNullOrWhiteSpace($v)) { $prefix = $v }
    }
    if ($names -contains 'repo_subpath')
    {
        $v = ([string]$Target.repo_subpath).Trim().Trim('/')
        if (-not [string]::IsNullOrWhiteSpace($v)) { $subpath = $v }
    }
    if ($names -contains 'arch')
    {
        $v = ([string]$Target.arch).Trim()
        if (-not [string]::IsNullOrWhiteSpace($v)) { $arch = $v }
    }
    if ($names -contains 'family')
    {
        $v = ([string]$Target.family).Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($v)) { $family = $v }
    }

    return @{ Subsystem = $subsystem; Prefix = $prefix; Subpath = $subpath; Arch = $arch; Family = $family }
}

function Get-DrivEnvMsys2PackageName
{
    # @brief The pacman name of one msys2.packages entry: repo mingw (default) -> <Prefix>-<name>; repo msys -> <name>.
    # Shared by step 2 (installs it) and the IgnorePkg union (protects it).
    # @param Package One msys2.packages entry.
    # @param Prefix  The subsystem's package prefix.
    # @return The name, or "" (unknown repo, blank name, or a mingw package without a prefix).
    param ($Package, [string]$Prefix)

    if ($null -eq $Package) { return "" }

    $name = ([string]$Package.name).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { return "" }

    $repo = ([string]$Package.repo).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($repo)) { $repo = 'mingw' }

    if ($repo -eq 'msys') { return $name }

    if ($repo -eq 'mingw')
    {
        $p = ([string]$Prefix).Trim()
        if ([string]::IsNullOrWhiteSpace($p)) { return "" }
        return ($p + '-' + $name)
    }

    return ""
}

function Get-DrivEnvToolchainTargets
{
    # @brief One entry per generated toolchain, in 'generate' order, each projected (a 2.x configuration: one, Id "").
    # Call it with the configuration as read, before the step projects $Cfg onto its own toolchain.
    # DO NOT WRAP A CALL TO THIS IN @(...): it comma-returns.
    # @param Cfg The parsed, validated configuration.
    # @return [pscustomobject]@{ Id; Key; Triplet; Cfg } per toolchain.
    param ($Cfg)

    if ($null -eq $Cfg) { return ,@() }

    # Assigned, not wrapped: see the warning above.
    $ids = Get-DrivEnvGenerateList -Cfg $Cfg
    if ($ids.Count -eq 0) { $ids = @('') }

    $list = @()
    foreach ($id in $ids)
    {
        $resolved = Resolve-DrivEnvToolchain -Cfg $Cfg -Id $id
        $list += [pscustomobject]@{
            Id      = $id
            Key     = (Get-DrivEnvToolchainKey -Cfg $resolved)
            Triplet = ([string]$resolved.vcpkg.target.triplet).Trim()
            Cfg     = $resolved
        }
    }

    return ,@($list)
}

function Get-DrivEnvDeclaredTargets
{
    # @brief One entry per DECLARED toolchain (generated ones first), each projected: for what is the drive's (shared
    # baseline, shared build trees), since a toolchain not generated today may be on the drive. Unprojectable ones are
    # left out (the validator said why). DO NOT WRAP A CALL TO THIS IN @(...): it comma-returns.
    # @param Cfg The configuration as read: validated, NOT projected.
    # @return [pscustomobject]@{ Id; Key; Triplet; Cfg; Generated }.
    param ($Cfg)

    $list = @()
    foreach ($t in (Get-DrivEnvToolchainTargets -Cfg $Cfg))
    {
        $list += [pscustomobject]@{ Id = $t.Id; Key = $t.Key; Triplet = $t.Triplet; Cfg = $t.Cfg; Generated = $true }
    }

    if (($null -ne $Cfg) -and (Test-DrivEnvIsObject $Cfg.toolchains))
    {
        $generated = Get-DrivEnvGenerateList -Cfg $Cfg
        foreach ($id in @($Cfg.toolchains.PSObject.Properties | ForEach-Object { $_.Name }))
        {
            if ($generated -contains $id) { continue }
            $resolved = $null
            try { $resolved = Resolve-DrivEnvToolchain -Cfg $Cfg -Id $id } catch { continue }
            if ($null -eq $resolved) { continue }
            $list += [pscustomobject]@{
                Id        = $id
                Key       = (Get-DrivEnvToolchainKey -Cfg $resolved)
                Triplet   = ([string]$resolved.vcpkg.target.triplet).Trim()
                Cfg       = $resolved
                Generated = $false
            }
        }
    }

    return ,@($list)
}

function Get-DrivEnvBaselineDecision
{
    # @brief Which vcpkg commit step 3 puts the drive's one clone at. One clone, one baseline: moving it for one
    # toolchain would leave the others' ports built from another commit.
    #   'latest', another toolchain recorded one  -> reuse it (whatever the order or 'generate' narrowing)
    #   'latest', none recorded                   -> resolve the remote HEAD
    #   'fixed'                                   -> the configured commit, warning for each toolchain on another one
    # A configured commit may be abbreviated: "same" means the recorded id starts with it.
    # @param Mode     vcpkg.source.baseline_mode: 'latest' or 'fixed'.
    # @param Fixed    vcpkg.source.baseline_commit, for 'fixed'.
    # @param Siblings The OTHER toolchains: objects with Id and Baseline (their VCPKG_BASELINE; blank if none).
    # @return @{ Action = 'fixed' | 'reuse' | 'resolve'; Commit; From (the Id reused from); Warnings = [string[]] }.
    param ([string]$Mode, [string]$Fixed = "", $Siblings = @())

    $recorded = @($Siblings | Where-Object { ($null -ne $_) -and ([string]$_.Baseline).Trim() -match '^[0-9a-fA-F]{40}$' })
    $warnings = @()

    if (([string]$Mode).Trim().ToLowerInvariant() -eq 'fixed')
    {
        $want = ([string]$Fixed).Trim()
        foreach ($s in $recorded)
        {
            $have = ([string]$s.Baseline).Trim()
            if (-not $have.StartsWith($want, [StringComparison]::OrdinalIgnoreCase))
            {
                $warnings += ("Toolchain '{0}' recorded baseline {1}; this run moves the shared vcpkg clone to {2}. Its installed ports stay as built from {1} -- step 4 in classic mode does not rebuild what is installed -- so remove them from its own shell (vcpkg remove --recurse <port>:<its triplet>) and run steps 3 and 4 with -Toolchain {0}, or generate a new drive." -f $s.Id, $have, $want)
            }
        }
        return @{ Action = 'fixed'; Commit = $want; From = ''; Warnings = [string[]]$warnings }
    }

    if ($recorded.Count -gt 0)
    {
        $first = $recorded[0]
        $commit = ([string]$first.Baseline).Trim()
        foreach ($s in @($recorded | Select-Object -Skip 1))
        {
            if (([string]$s.Baseline).Trim() -ine $commit)
            {
                $warnings += ("Toolchain '{0}' recorded baseline {1}, not {2}: this drive already holds builds from two commits. To bring it to {2}, remove its ports from its own shell (vcpkg remove --recurse <port>:<its triplet>) and run steps 3 and 4 with -Toolchain {0}." -f $s.Id, ([string]$s.Baseline).Trim(), $commit)
            }
        }
        return @{ Action = 'reuse'; Commit = $commit; From = [string]$first.Id; Warnings = [string[]]$warnings }
    }

    return @{ Action = 'resolve'; Commit = ''; From = ''; Warnings = [string[]]@() }
}

function Get-DrivEnvMsys2EnvValues
{
    # @brief Step 2's 'msys2' block of a toolchain's env file, as an ordered table: the public contract
    # (DEVSYSTEM_TOOLCHAIN states the family, which cannot be sniffed) plus MSYS2_ENV/DEVSYSTEM_TOOLCHAIN_ID, the key
    # steps 3-5 check (Get-DrivEnvEnvFileProblem). No PATH: step 3 composes it, last.
    # @param Key       The toolchain key.
    # @param Family    The compiler family.
    # @param Msys2Root The msys64 folder, either slash.
    # @param BasePath  BASE_PATH as step 2 composed it.
    # @return An [ordered] hashtable.
    param ([string]$Key, [string]$Family, [string]$Msys2Root, [string]$BasePath)

    $root = ([string]$Msys2Root).Trim().Replace('\', '/').TrimEnd('/')
    $k    = ([string]$Key).Trim()

    return [ordered]@{
        DEVSYSTEM_TOOLCHAIN_ROOT = $root + '/' + $k
        DEVSYSTEM_TOOLCHAIN      = ([string]$Family).Trim()
        DEVSYSTEM_TOOLCHAIN_ID   = $k
        MSYS2_ROOT               = $root
        MSYS2_BASH               = $root + '/usr/bin/bash.exe'
        MSYS2_ENV                = $k
        BASE_PATH                = [string]$BasePath
    }
}

function Get-DrivEnvEnvFileCandidates
{
    # @brief Every generated toolchain's env file, in 'generate' order (step 6 takes the first that exists).
    # DO NOT WRAP A CALL TO THIS IN @(...): it comma-returns.
    param ($Cfg)

    $list = @()
    foreach ($t in (Get-DrivEnvToolchainTargets -Cfg $Cfg))
    {
        $n = Get-DrivEnvToolchainNames -Cfg $t.Cfg
        if ($null -ne $n) { $list += $n.EnvFile }
    }
    return ,@($list)
}

function Select-DrivEnvFirstExisting
{
    # @brief The first of Paths that exists, or "".
    #
    # @param Paths  Candidates, in order of preference.
    # @param Exists How to ask, for the tests; Test-Path -LiteralPath otherwise.
    param ([string[]]$Paths = @(), [scriptblock]$Exists = $null)

    foreach ($p in @($Paths))
    {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $there = if ($Exists) { & $Exists $p } else { Test-Path -LiteralPath $p }
        if ($there) { return $p }
    }
    return ""
}

function Get-DrivEnvToolchainNames
{
    # @brief Every per-toolchain file name, from one table.
    #
    #   Key                  clang64
    #   Prefix               degorasslr                          dev_env_name, trimmed and lowered
    #   Stem                 degorasslr_clang64                  <Prefix>_<Key>
    #   EnvFile              N:\env\degorasslr_clang64_env_variables.env
    #   LauncherDir          N:\env\launcher
    #   Launcher             N:\env\launcher\degorasslr_clang64_env_launcher.bat
    #   Bootstrap            N:\env\launcher\degorasslr_clang64_env_launcher_bootstrap.sh
    #   DriveShortcut        N:\degorasslr_clang64_env_launcher.lnk
    #   DesktopShortcutName  DegorasSLR clang64 Environment.lnk  a leaf; the desktop folder is the caller's
    #   QtLauncher           N:\env\launcher\degorasslr_clang64_qtcreator.bat          step 7's, Qt Creator in this
    #   QtLauncherTail       N:\env\launcher\degorasslr_clang64_qtcreator_launcher.sh  toolchain's environment
    #   QtShortcut           N:\degorasslr_clang64_qtcreator.lnk
    #   QtDesktopShortcutName  DegorasSLR clang64 Qt Creator.lnk
    #   PackagesExport       degorasslr_clang64_packages         a base name; step 2 adds the stamp and .txt
    #   VcpkgReference       N:\env\degorasslr_clang64_vcpkg_reference.json
    #   ManifestName         degorasslr-clang64                  the input to step 4's ConvertTo-ManifestName
    #   InventoryDir         N:\installation
    #
    # The launcher finds its .env by its own name: %~n0 minus '_env_launcher' is the Stem, + '_env_variables.env'.
    #
    # @param Cfg A projected or 2.x configuration.
    # @return A hashtable, or $null when the drive letter, dev_env_name or toolchain key is blank.
    param ($Cfg)

    if (($null -eq $Cfg) -or ($null -eq $Cfg.environment)) { return $null }

    $letter  = ([string]$Cfg.environment.dev_drive_letter).Trim().TrimEnd(@(':', '\', '/')).ToUpperInvariant()
    $envName = ([string]$Cfg.environment.dev_env_name).Trim()
    $prefix  = $envName.ToLowerInvariant()
    $key     = Get-DrivEnvToolchainKey -Cfg $Cfg

    if ([string]::IsNullOrWhiteSpace($letter) -or [string]::IsNullOrWhiteSpace($prefix) -or
        [string]::IsNullOrWhiteSpace($key))
    {
        return $null
    }

    $stem        = $prefix + '_' + $key
    $drive       = $letter + ':'
    $envDir      = $drive + '\env'
    $launcherDir = $envDir + '\launcher'

    return @{
        Key                 = $key
        Prefix              = $prefix
        Stem                = $stem
        EnvFile             = $envDir + '\' + $stem + '_env_variables.env'
        LauncherDir         = $launcherDir
        Launcher            = $launcherDir + '\' + $stem + '_env_launcher.bat'
        Bootstrap           = $launcherDir + '\' + $stem + '_env_launcher_bootstrap.sh'
        DriveShortcut       = $drive + '\' + $stem + '_env_launcher.lnk'
        DesktopShortcutName = $envName + ' ' + $key + ' Environment.lnk'
        QtLauncher            = $launcherDir + '\' + $stem + '_qtcreator.bat'
        QtLauncherTail        = $launcherDir + '\' + $stem + '_qtcreator_launcher.sh'
        QtShortcut            = $drive + '\' + $stem + '_qtcreator.lnk'
        QtDesktopShortcutName = $envName + ' ' + $key + ' Qt Creator.lnk'
        PackagesExport      = $stem + '_packages'
        VcpkgReference      = $envDir + '\' + $stem + '_vcpkg_reference.json'
        ManifestName        = $prefix + '-' + $key
        InventoryDir        = $drive + '\installation'
    }
}

function Get-DrivEnvEnvFileProblem
{
    # @brief Why an env file is not THIS toolchain's (DEVSYSTEM_TOOLCHAIN_ID and MSYS2_ENV disagree with the key), or "".
    # A file copied under another toolchain's name would otherwise make steps 3-5 work on the wrong compiler.
    # @param EnvMap The file read as KEY -> value.
    # @param Key    This toolchain's key.
    # @param Path   The file, for the message.
    # @return "" or one sentence saying what disagrees.
    param ([hashtable]$EnvMap, [string]$Key, [string]$Path)

    $want = ([string]$Key).Trim()
    if ($null -eq $EnvMap) { return ("{0} could not be read" -f $Path) }

    foreach ($name in @('DEVSYSTEM_TOOLCHAIN_ID', 'MSYS2_ENV'))
    {
        $have = ([string]$EnvMap[$name]).Trim()
        if ([string]::IsNullOrWhiteSpace($have))
        {
            return ("{0} defines no {1}; step 2 writes it, so run step 2 for toolchain '{2}' first" -f $Path, $name, $want)
        }
        if ($have -ine $want)
        {
            return ("{0} says {1}={2}, but this run is for toolchain '{3}'; the file belongs to another toolchain" -f $Path, $name, $have, $want)
        }
    }
    return ""
}

function Get-DrivEnvLegacyEnvFile
{
    # @brief The env file of a drive generated before 3.0.0 (<L>:\env\<prefix>_env_variables.env), only to explain why a
    # step cannot find its toolchain's file. Such drives are not migrated (owner decision, 2026-10-05).
    # @param Cfg The parsed configuration.
    # @return The path, or "" when the drive letter or dev_env_name is blank.
    param ($Cfg)

    if (($null -eq $Cfg) -or ($null -eq $Cfg.environment)) { return "" }
    $letter = ([string]$Cfg.environment.dev_drive_letter).Trim().TrimEnd(@(':', '\', '/')).ToUpperInvariant()
    $prefix = ([string]$Cfg.environment.dev_env_name).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($letter) -or [string]::IsNullOrWhiteSpace($prefix)) { return "" }
    return ($letter + ':\env\' + $prefix + '_env_variables.env')
}

function Get-DrivEnvLogName
{
    # @brief A step's log file name: '<timestamp>_<role>_<key>.log', or '<timestamp>_<role>.log' for drive steps.
    param ([string]$Timestamp, [string]$Role, [string]$Key = "")

    $k = ([string]$Key).Trim()
    if ([string]::IsNullOrWhiteSpace($k)) { return ("{0}_{1}.log" -f $Timestamp, $Role) }
    return ("{0}_{1}_{2}.log" -f $Timestamp, $Role, $k)
}

function ConvertTo-DrivEnvVcpkgInventory
{
    # @brief One toolchain's part of 'vcpkg list --x-json' for its records: the JSON narrowed to its triplets, and one
    # readable line per package (built from the JSON; the plain listing truncates).
    # @param Text     The JSON 'vcpkg list --x-json' wrote.
    # @param Triplets This toolchain's triplets; compared case-insensitively.
    # @return @{ Json = the narrowed JSON text; Lines = [string[]] 'name[features]:triplet  version', sorted }.
    # @throws As ConvertFrom-DrivEnvVcpkgListJson does.
    param ([string]$Text, [string[]]$Triplets = @())

    $table = ConvertFrom-DrivEnvVcpkgListJson -Text $Text
    $want  = @($Triplets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })

    $obj  = $Text | ConvertFrom-Json
    $kept = [ordered]@{}
    foreach ($property in @($obj.PSObject.Properties | ForEach-Object { $_ }))
    {
        $t = [string]$property.Value.triplet
        if ($want -contains $t) { $kept[$property.Name] = $property.Value }
    }

    $lines = @()
    foreach ($key in @($table.Keys | Sort-Object))
    {
        $e = $table[$key]
        if ($want -notcontains $e.Triplet) { continue }
        $feat = if ($e.Features.Count -gt 0) { '[' + ($e.Features -join ',') + ']' } else { '' }
        $lines += ("{0}{1}:{2}  {3}" -f $e.Name, $feat, $e.Triplet, $e.Version)
    }

    $json = if ($kept.Count -gt 0) { [pscustomobject]$kept | ConvertTo-Json -Depth 10 } else { '{}' }
    return @{ Json = $json; Lines = [string[]]$lines }
}

function Get-DrivEnvRecordName
{
    # @brief A record's file name with the toolchain key before its extension (vcpkg_packages_clang64.txt). Drive-level
    # records (vcpkg_baseline.txt) do not come through here.
    # @param Name A file name, extension included.
    # @param Key  The toolchain key.
    # @return The suffixed name, or Name unchanged when Key is blank.
    param ([string]$Name, [string]$Key)

    if ([string]::IsNullOrWhiteSpace($Key)) { return $Name }

    return ([System.IO.Path]::GetFileNameWithoutExtension($Name) + '_' + $Key + [System.IO.Path]::GetExtension($Name))
}

function Install-DrivEnvLauncherSet
{
    # @brief Deploys one toolchain's launcher set (the env_launcher* templates as <Stem>_<template>), on every step 2 so
    # a drive's launchers always match the generator. Not the qtcreator_* templates: step 7 fills and deploys those.
    # @param TemplateDir The generator's drive\launchers folder.
    # @param Names       The table from Get-DrivEnvToolchainNames (LauncherDir, created if missing, and Stem).
    # @param Report      Optional scriptblock taking one string, called once per file deployed.
    # @throws When there is no template, or a copy fails: half a launcher set is not a success.
    param
    (
        [string]      $TemplateDir,
                      $Names,
        [scriptblock] $Report = $null
    )

    if (($null -eq $Names) -or [string]::IsNullOrWhiteSpace([string]$Names['Stem']) -or
        [string]::IsNullOrWhiteSpace([string]$Names['LauncherDir']))
    {
        throw "Install-DrivEnvLauncherSet: no toolchain names were given to deploy under."
    }

    if ([string]::IsNullOrWhiteSpace($TemplateDir) -or -not (Test-Path -LiteralPath $TemplateDir -PathType Container))
    {
        throw ("Launcher template directory not found: '{0}'" -f $TemplateDir)
    }

    $templates = @(Get-ChildItem -LiteralPath $TemplateDir -File |
                   Where-Object { ($_.Name -like 'env_launcher*') -and (@('.bat', '.sh') -contains $_.Extension) } |
                   Sort-Object Name)
    if ($templates.Count -eq 0)
    {
        throw ("No launcher templates (env_launcher*.bat, env_launcher*.sh) in '{0}'." -f $TemplateDir)
    }

    $dir = [string]$Names['LauncherDir']
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }

    foreach ($t in $templates)
    {
        $dest = Join-Path $dir ([string]$Names['Stem'] + '_' + $t.Name)
        Copy-Item -LiteralPath $t.FullName -Destination $dest -Force -ErrorAction Stop
        if ($Report) { & $Report ("Deployed: {0}" -f $dest) }
    }
}

# --------------------------------------------------------------------
# DRIVE LAYOUT
# --------------------------------------------------------------------

function Resolve-DrivEnvWorkspaceFolder
{
    # @brief workspace.default_folder as a folder relative to the drive (default 'workspace'), one rule for steps 1, 2, 6.
    # @param Cfg The parsed configuration.
    # @return Forward slashes, none at either end; "" when it is not a folder on the drive (drive letter, '..', empty).
    param ($Cfg)

    $folder = 'workspace'
    if (($null -ne $Cfg) -and ($null -ne $Cfg.workspace))
    {
        $given = [string]$Cfg.workspace.default_folder
        if (-not [string]::IsNullOrWhiteSpace($given)) { $folder = $given }
    }

    $folder = $folder.Trim().Replace('\', '/').Trim('/')

    if ([string]::IsNullOrWhiteSpace($folder))   { return "" }
    if ($folder -match '^[A-Za-z]:')             { return "" }
    if (($folder -split '/') -contains '..')     { return "" }

    return $folder
}

function Get-DrivEnvDriveEnvValues
{
    # @brief The drive header opening every toolchain's .env: DEVDRIVE_NAME, DEVDRIVE_LETTER, DEVSYSTEM_NAME,
    # DEVSYSTEM_DEPLOYS, DEVSYSTEM_WORKSPACE (repeated per file, so each is complete). Not DEVSYSTEM_BUILDTREES: it
    # expands ${VCPKG_DEFAULT_TRIPLET} and must follow the vcpkg block, which owns it.
    # @param Cfg The parsed configuration.
    # @return An [ordered] hashtable, or $null when the drive letter is blank or the workspace folder is invalid.
    param ($Cfg)

    if (($null -eq $Cfg) -or ($null -eq $Cfg.environment)) { return $null }

    $letter = ([string]$Cfg.environment.dev_drive_letter).Trim().TrimEnd(@(':', '\', '/')).ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($letter)) { return $null }

    $workspace = Resolve-DrivEnvWorkspaceFolder -Cfg $Cfg
    if ([string]::IsNullOrWhiteSpace($workspace)) { return $null }

    $drive = $letter + ':'

    return [ordered]@{
        DEVDRIVE_NAME       = ([string]$Cfg.environment.dev_drive_label).Trim()
        DEVDRIVE_LETTER     = $drive
        DEVSYSTEM_NAME      = ([string]$Cfg.environment.dev_env_name).Trim()
        DEVSYSTEM_DEPLOYS   = $drive + '/deploys'
        DEVSYSTEM_WORKSPACE = $drive + '/' + $workspace
    }
}

function Get-DrivEnvCleanupSettings
{
    # @brief vcpkg.cleanup with its defaults: @{ Buildtrees = 'none'|'logs'|'all'; Packages; Downloads; BinaryCache }.
    param ($Cfg)

    $c = $null
    if ($Cfg -and $Cfg.vcpkg -and ($Cfg.vcpkg.PSObject.Properties.Name -contains 'cleanup')) { $c = $Cfg.vcpkg.cleanup }
    $bt = 'none'
    if ($c -and ($c.PSObject.Properties.Name -contains 'buildtrees')) { $bt = ([string]$c.buildtrees).Trim().ToLowerInvariant() }
    return @{ Buildtrees = $bt; Packages = [bool]($c -and $c.packages); Downloads = [bool]($c -and $c.downloads); BinaryCache = [bool]($c -and $c.binary_cache) }
}

function Get-DrivEnvGitSystemConfigLines
{
    # @brief The drive's msys64/etc/gitconfig: [http] proxy from environment.proxy_url and [user] from 'git'.
    # @return The file's lines, or an empty array when there is neither (the file is then left alone).
    param ([string]$Proxy = "", $Git = $null)

    $lines = @()
    if (-not [string]::IsNullOrWhiteSpace($Proxy)) { $lines += @('[http]', ("`tproxy = {0}" -f $Proxy.Trim())) }
    if ($Git -and -not [string]::IsNullOrWhiteSpace([string]$Git.user_name) -and -not [string]::IsNullOrWhiteSpace([string]$Git.user_email))
    {
        $lines += @('[user]', ("`tname = {0}" -f ([string]$Git.user_name).Trim()), ("`temail = {0}" -f ([string]$Git.user_email).Trim()), "`tuseConfigOnly = true")
    }
    if ($lines.Count -eq 0) { return @() }
    return @('# Git system configuration of this drive, written by step 2 from the JSON (environment.proxy_url, git).',
             '# Edit the JSON, not this file: regenerating the environment overwrites it.') + $lines
}

function Resolve-DrivEnvOwner
{
    # @brief The owner environment.owner names, as icacls takes it: "*<SID>", so a localized or space-carrying name
    # cannot be misread. "current" (or absent) is -Current when given -- the account that started an elevated child
    # -- else this process's own account; "administrators" is the built-in group; anything else an account name.
    # Throws when the account does not exist here.
    param ($Cfg, [string]$Current = "")

    $owner = "current"
    if ($Cfg -and $Cfg.environment -and ($Cfg.environment.PSObject.Properties.Name -contains 'owner')) { $owner = ([string]$Cfg.environment.owner).Trim() }

    switch ($owner.ToLowerInvariant())
    {
        'administrators' { return '*S-1-5-32-544' }
        'current'        { $account = if ($Current) { $Current } else { [Security.Principal.WindowsIdentity]::GetCurrent().Name } }
        default          { $account = $owner }
    }
    try   { $sid = (New-Object Security.Principal.NTAccount($account)).Translate([Security.Principal.SecurityIdentifier]).Value }
    catch { throw "environment.owner: account '$account' does not exist on this PC." }
    return "*$sid"
}

function Set-DrivEnvDriveOwner
{
    # @brief Hands Path and everything under it to Owner (Resolve-DrivEnvOwner's form). Needs an elevated process
    # (SeRestorePrivilege). A volume root's System Volume Information and $RECYCLE.BIN are left alone: only SYSTEM
    # may hold them, and icacls /T over the root failed on the first one. Returns how many items did NOT change
    # hands (0: all did); their errors go to Report.
    param ([string]$Path, [string]$Owner, [scriptblock]$Report = { param($m) })

    # A caller's 'Stop' would turn icacls's stderr ("Access denied") into an exception that ends the whole pass.
    $ErrorActionPreference = 'Continue'
    $windowsOwn = @('System Volume Information', '$RECYCLE.BIN')
    $items = @([pscustomobject]@{ FullName = $Path; PSIsContainer = $false }) +
             @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Where-Object { $windowsOwn -notcontains $_.Name })
    $failed = 0
    foreach ($item in $items)
    {
        $icaclsArgs = @($item.FullName, '/setowner', $Owner, '/C', '/Q')
        if ($item.PSIsContainer) { $icaclsArgs += '/T' }
        $out = @(& icacls.exe @icaclsArgs 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        # With /C icacls exits 0 whatever failed; only its closing summary counts them, "<done> files; <failed>
        # files" in any language -- so its second number. No summary at all is a failure too.
        $summary = @($out | Where-Object { $_ -match '^\D*\d+\D+\d+\D*$' } | Select-Object -Last 1)
        $n = if ($summary.Count -and ($summary[0] -match '^\D*\d+\D+(\d+)\D*$')) { [int]$Matches[1] } else { 1 }
        if ($n -gt 0)
        {
            $failed += $n
            foreach ($line in @($out | Where-Object { $summary -notcontains $_ } | Select-Object -First 3)) { & $Report ("  icacls: " + $line) }
        }
    }
    return $failed
}

function Enable-DrivEnvGitTrust
{
    # @brief Lets the git this run starts (directly, or through vcpkg and bash) use repositories another account owns:
    # git refuses them as "dubious ownership", e.g. on a drive imported from another PC. Process environment only
    # (GIT_CONFIG_COUNT is the command scope, which safe.directory honours): nothing is written, the user's git keeps
    # its own check. Appends to a count already set; idempotent.
    $n = 0
    [void][int]::TryParse([string]$env:GIT_CONFIG_COUNT, [ref]$n)
    for ($i = 0; $i -lt $n; $i++)
    {
        if (([Environment]::GetEnvironmentVariable("GIT_CONFIG_KEY_$i") -eq 'safe.directory') -and
            ([Environment]::GetEnvironmentVariable("GIT_CONFIG_VALUE_$i") -eq '*')) { return }
    }
    [Environment]::SetEnvironmentVariable("GIT_CONFIG_KEY_$n", 'safe.directory')
    [Environment]::SetEnvironmentVariable("GIT_CONFIG_VALUE_$n", '*')
    $env:GIT_CONFIG_COUNT = [string]($n + 1)
}

function Get-DrivEnvMetadataLines
{
    # @brief The configuration's 'metadata' as "key: value" lines (notes as "  - note"), for the drive's records.
    # @return The lines, or an empty array without metadata.
    param ($Cfg)

    $m = $Cfg.metadata
    if (-not $m) { return @() }
    $out = @()
    foreach ($k in 'name', 'version', 'date', 'author', 'target_os', 'description')
    {
        $v = ([string]$m.$k).Trim()
        if ($v) { $out += ('{0}: {1}' -f $k, $v) }
    }
    $notes = @($m.notes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($notes.Count -gt 0) { $out += 'notes:'; $out += @($notes | ForEach-Object { "  - $_" }) }
    return $out
}

function Get-DrivEnvMetadataSummary
{
    # @brief One log line naming the configuration: "Configuration: <name> <version> (<date>, <author>), target <os>", or "".
    param ($Cfg)

    $m = $Cfg.metadata
    if (-not $m) { return "" }
    $head = (@([string]$m.name, [string]$m.version) | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
    $tail = (@([string]$m.date, [string]$m.author) | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ', '
    $os   = ([string]$m.target_os).Trim()
    if (-not $head -and -not $tail -and -not $os) { return "" }
    return ("Configuration: {0}{1}{2}" -f $head, $(if ($tail) { " ($tail)" } else { "" }), $(if ($os) { ", target $os" } else { "" })).Replace(':  (', ': (')
}

function Get-DrivEnvCustomFolders
{
    # @brief environment.custom_folders, normalised (trimmed, '/', no end slashes, blanks skipped). Without -ToolchainKey:
    # the entries without ${DEVSYSTEM_TOOLCHAIN_ID} (drive-level); with it: the entries holding the token, replaced by
    # the key. DO NOT WRAP A CALL TO THIS IN @(...): it comma-returns.
    # @param Cfg          The parsed configuration.
    # @param ToolchainKey The toolchain key, or "" for the drive-level folders.
    # @return Folders relative to the drive.
    param ($Cfg, [string]$ToolchainKey = "")

    # Single quotes: in double quotes PowerShell would expand this as one of its own variables.
    $token = '${DEVSYSTEM_TOOLCHAIN_ID}'
    $key   = ([string]$ToolchainKey).Trim()

    $list = @()
    if (($null -ne $Cfg) -and ($null -ne $Cfg.environment))
    {
        foreach ($entry in @($Cfg.environment.custom_folders | Where-Object { $null -ne $_ }))
        {
            $rel = ([string]$entry).Trim().Replace('\', '/').Trim('/')
            if ([string]::IsNullOrWhiteSpace($rel)) { continue }

            $carriesToken = $rel.Contains($token)
            if ([string]::IsNullOrWhiteSpace($key))
            {
                if (-not $carriesToken) { $list += $rel }
            }
            elseif ($carriesToken)
            {
                $list += $rel.Replace($token, $key)
            }
        }
    }

    return ,@($list)
}

# --------------------------------------------------------------------
# PACKAGES AND TRIPLETS
# --------------------------------------------------------------------

function Get-DrivEnvIgnorePkgUnion
{
    # @brief Every pinned MSYS2 package of every DECLARED toolchain, by pacman name: one msys64 has one IgnorePkg, and
    # a run must protect the other toolchain's pins too (names carry the subsystem prefix, so no collisions). Step 2
    # writes Select-DrivEnvInstalledPins of this, not this. DO NOT WRAP A CALL TO THIS IN @(...): it comma-returns;
    # an empty union is an empty array, so the line can still be cleared.
    # @param Cfg The configuration as read: validated, NOT projected.
    # @return The package names, sorted and unique.
    # @throws When a GENERATED toolchain's subsystem has no package prefix.
    param ($Cfg)

    # The generated toolchains -- or the 2.x configuration itself -- then every other declared one.
    $targets = @()
    foreach ($t in (Get-DrivEnvToolchainTargets -Cfg $Cfg))
    {
        $targets += [pscustomobject]@{ Id = $t.Id; Cfg = $t.Cfg; Generated = $true }
    }
    if (($null -ne $Cfg) -and (Test-DrivEnvIsObject $Cfg.toolchains))
    {
        $generated = Get-DrivEnvGenerateList -Cfg $Cfg
        foreach ($id in @($Cfg.toolchains.PSObject.Properties | ForEach-Object { $_.Name }))
        {
            if ($generated -contains $id) { continue }
            $resolved = $null
            try { $resolved = Resolve-DrivEnvToolchain -Cfg $Cfg -Id $id } catch { continue }
            if ($null -ne $resolved) { $targets += [pscustomobject]@{ Id = $id; Cfg = $resolved; Generated = $false } }
        }
    }

    $names = @()
    foreach ($t in $targets)
    {
        $sub = Resolve-DrivEnvMsys2Target -Target $t.Cfg.msys2.target
        if ([string]::IsNullOrWhiteSpace($sub.Prefix))
        {
            if (-not $t.Generated) { continue }
            $label = if ([string]::IsNullOrWhiteSpace($t.Id)) { "msys2.target" } else { "toolchain '$($t.Id)'" }
            throw ("{0}: no package prefix, so its pinned packages cannot be named. Use a known msys2.target.subsystem or set msys2.target.package_prefix." -f $label)
        }

        foreach ($p in @($t.Cfg.msys2.packages | Where-Object { $null -ne $_ }))
        {
            if (([string]$p.mode).Trim().ToLowerInvariant() -ne 'pinned') { continue }

            $n = Get-DrivEnvMsys2PackageName -Package $p -Prefix $sub.Prefix
            if (-not [string]::IsNullOrWhiteSpace($n)) { $names += $n }
        }
    }

    return ,@($names | Sort-Object -Unique)
}

function Select-DrivEnvInstalledPins
{
    # @brief The pins of Pins that are installed. IgnorePkg also stops pacman resolving a dependency to a package not
    # installed yet (measured: git skipped, exit 0, under --noconfirm), so only installed pins are named.
    # DO NOT WRAP A CALL TO THIS IN @(...): it comma-returns.
    # @param Pins      Package names, e.g. Get-DrivEnvIgnorePkgUnion.
    # @param Installed Names of installed packages ('pacman -Qq'); blanks ignored.
    # @return The installed pins, sorted and unique; an empty array, never $null.
    param ([string[]]$Pins = @(), [string[]]$Installed = @())

    $have = @{}
    foreach ($n in @($Installed | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
    {
        # Keyed as pacman prints it. pacman names are lower case, so the hashtable's case-insensitivity costs nothing.
        $have[([string]$n).Trim()] = $true
    }

    $kept = @($Pins | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ([string]$_).Trim() } |
              Where-Object { $have.ContainsKey($_) } | Sort-Object -Unique)
    return ,@($kept)
}

function Update-DrivEnvIgnorePkgLines
{
    # @brief The pacman.conf edit behind step 2's IgnorePkg, as a pure function of the file's lines. The managed block
    # (marker + 'IgnorePkg = ' lines) is taken out and put back in its place; the first time it replaces the first
    # IgnorePkg line, or goes under [options]. Long lists span several lines (pacman cuts lines at 4096 bytes;
    # IgnorePkg accumulates). With no packages, pacman's commented default comes back. A file never touched is
    # returned unchanged.
    # @param Lines         The file's lines.
    # @param Packages      Package names; order, blanks and duplicates do not matter.
    # @param MaxLineLength The longest IgnorePkg line written, unless one name alone is longer.
    # @return @{ Lines = [string[]]; Status = 'set' | 'cleared' | 'unchanged' | 'no-options' }.
    param ([string[]]$Lines = @(), [string[]]$Packages = @(), [int]$MaxLineLength = 1024)

    $marker       = "# DrivEnv: pinned by the configuration, kept from being upgraded by pacman -Syu."
    $anyIgnorePkg = '^\s*#?\s*IgnorePkg\s*='
    $head         = 'IgnorePkg   = '
    # OURS BY THEIR EXACT HEAD, three spaces and all, which is how this has always written them: a hand-written
    # 'IgnorePkg = x' directly under the block is somebody's own line, and must not be swept up with ours.
    $ownLine      = '^' + [regex]::Escape($head)

    $in = @()
    if ($null -ne $Lines) { $in = @($Lines | ForEach-Object { [string]$_ }) }

    $wanted = @($Packages | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { ([string]$_).Trim() } | Sort-Object -Unique)

    # The file without any managed block, and where the first one stood.
    $rest = @()
    $at   = -1
    for ($i = 0; $i -lt $in.Count; $i++)
    {
        if ($in[$i] -ne $marker) { $rest += $in[$i]; continue }
        if ($at -lt 0) { $at = $rest.Count }
        while ((($i + 1) -lt $in.Count) -and ($in[$i + 1] -match $ownLine)) { $i++ }
    }

    if ($wanted.Count -eq 0)
    {
        if ($at -lt 0) { return @{ Lines = [string[]]$in; Status = 'unchanged' } }

        $out = @()
        if ($at -gt 0) { $out += $rest[0..($at - 1)] }
        $out += '#IgnorePkg   ='
        if ($at -lt $rest.Count) { $out += $rest[$at..($rest.Count - 1)] }
        return @{ Lines = [string[]]$out; Status = 'cleared' }
    }

    # The block: the marker, then the names packed greedily into lines no longer than MaxLineLength.
    $block   = @($marker)
    $current = ''
    foreach ($name in $wanted)
    {
        if (($current.Length -gt 0) -and (($head.Length + $current.Length + 1 + $name.Length) -gt $MaxLineLength))
        {
            $block  += ($head + $current)
            $current = ''
        }
        $current = if ($current.Length -gt 0) { $current + ' ' + $name } else { $name }
    }
    $block += ($head + $current)

    # Where it goes: where the old block stood, else in place of the first IgnorePkg line, else under [options].
    $replace = $false
    if ($at -lt 0)
    {
        for ($i = 0; $i -lt $rest.Count; $i++)
        {
            if ($rest[$i] -match $anyIgnorePkg) { $at = $i; $replace = $true; break }
        }
    }
    if ($at -lt 0)
    {
        for ($i = 0; $i -lt $rest.Count; $i++)
        {
            if ($rest[$i] -match '^\s*\[options\]\s*$') { $at = $i + 1; break }
        }
    }
    if ($at -lt 0) { return @{ Lines = [string[]]$in; Status = 'no-options' } }

    $after = if ($replace) { $at + 1 } else { $at }
    $out = @()
    if ($at -gt 0) { $out += $rest[0..($at - 1)] }
    $out += $block
    if ($after -lt $rest.Count) { $out += $rest[$after..($rest.Count - 1)] }
    return @{ Lines = [string[]]$out; Status = 'set' }
}

function Select-DrivEnvToolchainPackages
{
    # @brief The 'pacman -Q' lines of ONE toolchain: its own prefix and the shared msys base, not the other compiler's.
    # DO NOT WRAP A CALL TO THIS IN @(...): it comma-returns.
    # @param Lines  'pacman -Q' output, '<name> <version>' per line.
    # @param Prefix This toolchain's package prefix, e.g. mingw-w64-clang-x86_64.
    # @return The lines kept, in their original order.
    param ([string[]]$Lines = @(), [string]$Prefix)

    $own  = ([string]$Prefix).Trim()
    $kept = @()

    # WHAT IS DROPPED IS ANOTHER SUBSYSTEM'S, by its known prefix -- not every 'mingw-w64-' name. The msys repository
    # publishes packages named mingw-w64-cross-* that belong to no subsystem: they live in the shared /usr like the rest
    # of the msys base, and dropping every 'mingw-w64-' name left them out of every toolchain's record.
    $others = @()
    foreach ($e in (Get-DrivEnvMsys2SubsystemTable).Values)
    {
        $p = ([string]$e.Prefix).Trim()
        if ($p -and ($p -ine $own)) { $others += ($p + '-') }
    }

    foreach ($raw in @($Lines | Where-Object { $null -ne $_ }))
    {
        $line  = [string]$raw
        $first = ($line.Trim() -split '\s+')[0]
        if ([string]::IsNullOrWhiteSpace($first)) { continue }

        $isOwn   = (-not [string]::IsNullOrWhiteSpace($own)) -and
                   $first.StartsWith($own + '-', [StringComparison]::OrdinalIgnoreCase)
        $isOther = (-not $isOwn) -and (@($others | Where-Object { $first.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)

        if (-not $isOther) { $kept += $line }
    }

    return ,@($kept)
}

function Get-DrivEnvPackageTriplet
{
    # @brief The triplet one vcpkg.packages entry is built for: its own 'triplet', trimmed, else the toolchain's
    # (step 4's rule; step 5 must key by the same one).
    # @param Package One vcpkg.packages entry.
    # @param Default The toolchain's triplet.
    # @return The override when present and not blank, otherwise Default.
    param ($Package, [string]$Default)

    if ($null -ne $Package)
    {
        $names = @($Package.PSObject.Properties | ForEach-Object { $_.Name })
        if ($names -contains 'triplet')
        {
            $t = ([string]$Package.triplet).Trim()
            if (-not [string]::IsNullOrWhiteSpace($t)) { return $t }
        }
    }

    return $Default
}

function Get-DrivEnvToolchainTriplets
{
    # @brief Every triplet one toolchain builds for: vcpkg.target.triplet, then the per-package overrides (single-
    # toolchain only, so they are this toolchain's). DO NOT WRAP A CALL TO THIS IN @(...): it comma-returns.
    # @param Cfg A projected or 2.x configuration.
    # @return The triplets, de-duplicated case-insensitively, the first spelling kept.
    param ($Cfg)

    if (($null -eq $Cfg) -or ($null -eq $Cfg.vcpkg)) { return ,@() }

    $main = ""
    if ($null -ne $Cfg.vcpkg.target) { $main = ([string]$Cfg.vcpkg.target.triplet).Trim() }

    $candidates = @($main)
    foreach ($p in @($Cfg.vcpkg.packages | Where-Object { $null -ne $_ }))
    {
        $candidates += (Get-DrivEnvPackageTriplet -Package $p -Default $main)
    }

    # A Hashtable's keys are case-insensitive already, which is the comparison wanted here.
    $seen = @{}
    $list = @()
    foreach ($t in $candidates)
    {
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if ($seen.ContainsKey($t)) { continue }
        $seen[$t] = $true
        $list += $t
    }

    return ,@($list)
}

function ConvertFrom-DrivEnvVcpkgListJson
{
    # @brief 'vcpkg list --x-json' as a table keyed "name:triplet" (one tree holds every toolchain's triplets).
    # @param Text The JSON text vcpkg wrote.
    # @return A hashtable, EMPTY for '{}', never $null. Values @{ Name; Triplet; Version; Features }; Version gets
    #         '#<port_version>' when above 0, as vcpkg prints it.
    # @throws On blank text, text that is not JSON, and JSON that is not an object.
    param ([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { throw "'vcpkg list --x-json' produced no output." }

    try   { $obj = $Text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw ("'vcpkg list --x-json' output is not valid JSON: {0}" -f $_.Exception.Message) }

    if (-not (Test-DrivEnvIsObject $obj)) { throw "'vcpkg list --x-json' output is not a JSON object." }

    $table = @{}

    # Piped, so an empty object yields no property at all rather than one $null.
    foreach ($property in @($obj.PSObject.Properties | ForEach-Object { $_ }))
    {
        $entry = $property.Value
        if (-not (Test-DrivEnvIsObject $entry)) { continue }

        $name = [string]$entry.package_name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $triplet = [string]$entry.triplet
        $version = [string]$entry.version

        # port_version 0 is the common case, and vcpkg does not print "#0" anywhere, so neither does this.
        $fields = @($entry.PSObject.Properties | ForEach-Object { $_.Name })
        if ($fields -contains 'port_version')
        {
            $portVersion = [int]$entry.port_version
            if ($portVersion -gt 0) { $version = $version + '#' + $portVersion }
        }

        $features = @($entry.features | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })

        $table[$name + ':' + $triplet] = @{ Name = $name; Triplet = $triplet; Version = $version; Features = $features }
    }

    return $table
}

function Get-DrivEnvPackageCheck
{
    # @brief Step 5's verdict on one vcpkg.packages entry: installed for the triplet it is built for, or not (a port
    # installed only for another triplet is said so).
    # @param Listed         The table from ConvertFrom-DrivEnvVcpkgListJson; empty means nothing is installed.
    # @param Package        One vcpkg.packages entry.
    # @param DefaultTriplet The environment's VCPKG_DEFAULT_TRIPLET.
    # @return @{ Name; State = 'ok' | 'fail'; Detail }, or $null for an entry with no name.
    param ([hashtable]$Listed = @{}, $Package, [string]$DefaultTriplet)

    if ($null -eq $Package) { return $null }
    $name = ([string]$Package.name).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }

    $triplet = Get-DrivEnvPackageTriplet -Package $Package -Default $DefaultTriplet
    $shown   = if ($triplet -ieq $DefaultTriplet) { $name } else { $name + ':' + $triplet }
    $key     = $name + ':' + $triplet

    if (($null -ne $Listed) -and $Listed.ContainsKey($key))
    {
        return @{ Name = $shown; State = 'ok'; Detail = [string]$Listed[$key].Version }
    }

    $elsewhere = @()
    if ($null -ne $Listed)
    {
        $elsewhere = @($Listed.Values | Where-Object { $_.Name -ieq $name } | ForEach-Object { $_.Triplet } | Sort-Object -Unique)
    }
    $detail = "not installed for $triplet"
    if ($elsewhere.Count -gt 0) { $detail += " (installed for: " + ($elsewhere -join ", ") + ")" }

    return @{ Name = $shown; State = 'fail'; Detail = $detail }
}

function Get-DrivEnvPackageResults
{
    # @brief Step 5's verdicts for every configured package. No guard on an empty listing: '{}' means nothing is
    # installed. DO NOT WRAP A CALL TO THIS IN @(...): it comma-returns.
    # @return One @{ Name; State; Detail } per named package, in configuration order.
    param ([hashtable]$Listed, $Packages = @(), [string]$DefaultTriplet)

    $out = @()
    if ($null -eq $Listed) { return ,@($out) }

    foreach ($p in @($Packages | Where-Object { $null -ne $_ }))
    {
        $v = Get-DrivEnvPackageCheck -Listed $Listed -Package $p -DefaultTriplet $DefaultTriplet
        if ($null -ne $v) { $out += $v }
    }
    return ,@($out)
}

function Get-DrivEnvBuildtreeCleanupPlan
{
    # @brief What step 4's cleanup may remove from ONE folder under the buildtrees root, from names alone (pure).
    #   * No '<t>.vcpkg_abi_info.txt' stamp: never touched (the user's builds carry none).
    #   * Not the last generated toolchain: only ports with its own stamp, only its <t>, <t>-rel, <t>-dbg; src stays.
    #   * The last one (or a 2.x configuration): any stamped port; 'logs' removes every subfolder and 'all' the folder,
    #     unless another triplet's trees remain, which always survive.
    #   * A port every other toolchain has already stamped counts as last (build order may differ from 'generate').
    # Exact names, never prefixes (x64-mingw-dynamic is a prefix of x64-mingw-dynamic-release).
    # @param SubdirNames   The folder's immediate subfolder names.
    # @param FileNames     The folder's immediate file names.
    # @param OwnTriplets   This toolchain's triplets.
    # @param LastToolchain True for the last id in 'generate', and for a 2.x configuration.
    # @param Mode          'logs' or 'all'.
    # @param OtherTriplets The main triplets of every OTHER declared toolchain.
    # @return @{ Candidate = [bool]; RemoveWhole = [bool]; RemoveDirs = [string[]] }.
    param
    (
        [string[]] $SubdirNames   = @(),
        [string[]] $FileNames     = @(),
        [string[]] $OwnTriplets   = @(),
        [bool]     $LastToolchain = $false,
        [ValidateSet('logs', 'all')]
        [string]   $Mode          = 'logs',
        [string[]] $OtherTriplets = @()
    )

    $suffix = '.vcpkg_abi_info.txt'

    $dirs = @($SubdirNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $own  = @($OwnTriplets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    $others = @($OtherTriplets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })

    # The triplets that have stamped this directory.
    $stamped = @()
    foreach ($f in @($FileNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
    {
        if (($f.Length -gt $suffix.Length) -and $f.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase))
        {
            $stamped += $f.Substring(0, $f.Length - $suffix.Length)
        }
    }

    $untouched = @{ Candidate = $false; RemoveWhole = $false; RemoveDirs = [string[]]@() }
    if ($stamped.Count -eq 0) { return $untouched }

    # Every other toolchain has built this port already: no one needs its sources any more.
    if ((-not $LastToolchain) -and ($others.Count -gt 0) -and (@($others | Where-Object { $stamped -notcontains $_ }).Count -eq 0))
    {
        $LastToolchain = $true
    }

    $ownStamped = @($stamped | Where-Object { $own -contains $_ })
    if ((-not $LastToolchain) -and ($ownStamped.Count -eq 0)) { return $untouched }

    # -contains and -notcontains compare whole strings, case-insensitively, which is the rule above.
    $ownSet = @()
    foreach ($t in $own) { $ownSet += @($t, ($t + '-rel'), ($t + '-dbg')) }
    $ownDirs = @($dirs | Where-Object { $ownSet -contains $_ })

    if (-not $LastToolchain)
    {
        return @{ Candidate = $true; RemoveWhole = $false; RemoveDirs = [string[]]$ownDirs }
    }

    $otherSet = @()
    foreach ($o in @($stamped | Where-Object { $own -notcontains $_ })) { $otherSet += @($o, ($o + '-rel'), ($o + '-dbg')) }
    $othersRemain = @($dirs | Where-Object { $otherSet -contains $_ }).Count -gt 0

    if ($othersRemain)    { return @{ Candidate = $true; RemoveWhole = $false; RemoveDirs = [string[]]$ownDirs } }
    if ($Mode -eq 'all')  { return @{ Candidate = $true; RemoveWhole = $true;  RemoveDirs = [string[]]@() } }
    return @{ Candidate = $true; RemoveWhole = $false; RemoveDirs = [string[]]$dirs }
}

# --------------------------------------------------------------------
# TOOLCHAIN SCOPE
# --------------------------------------------------------------------

function Test-DrivEnvPathUnder
{
    # @brief True when Path lies strictly inside Root (full paths, case-insensitive, root with one trailing '\' so
    # N:\msys64\clang64x is not under N:\msys64\clang64). No disk access; blank or malformed paths are under nothing.
    param ([string]$Path, [string]$Root)

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }

    try
    {
        $full = [System.IO.Path]::GetFullPath($Path.Trim().Replace('/', '\'))
        $base = [System.IO.Path]::GetFullPath($Root.Trim().Replace('/', '\')).TrimEnd('\') + '\'
    }
    catch { return $false }

    return $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)
}

function Get-DrivEnvToolchainScopeViolation
{
    # @brief Why a resolved executable is not this toolchain's, or "". Allowed: under ToolchainRoot (<msys64>/<key>),
    # under one of InstalledRoots (vcpkg/installed/<t>), or directly in VcpkgRoot (vcpkg.exe; not its subfolders).
    # @return "" when allowed; otherwise the reason (off the drive, or on it but outside this toolchain).
    param
    (
        [string]   $Source,
        [string]   $ToolchainRoot,
        [string[]] $InstalledRoots = @(),
        [string]   $VcpkgRoot,
        [string]   $DriveLetter,
        [string]   $ToolchainKey
    )

    if ([string]::IsNullOrWhiteSpace($Source)) { return "no path was resolved" }

    if (Test-DrivEnvPathUnder -Path $Source -Root $ToolchainRoot) { return "" }

    foreach ($root in @($InstalledRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
    {
        if (Test-DrivEnvPathUnder -Path $Source -Root $root) { return "" }
    }

    if (-not [string]::IsNullOrWhiteSpace($VcpkgRoot))
    {
        try
        {
            $parent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Source.Trim().Replace('/', '\')))
            $vroot  = [System.IO.Path]::GetFullPath($VcpkgRoot.Trim().Replace('/', '\')).TrimEnd('\')
            if (($null -ne $parent) -and [string]::Equals($parent.TrimEnd('\'), $vroot, [StringComparison]::OrdinalIgnoreCase))
            {
                return ""
            }
        }
        catch { }
    }

    $letter = ([string]$DriveLetter).Trim().TrimEnd(@(':', '\', '/')).ToUpperInvariant()
    if (-not (Test-DrivEnvPathUnder -Path $Source -Root ($letter + ':\')))
    {
        return ("found at {0}, which is outside {1}:" -f $Source, $letter)
    }

    return ("found at {0}, which is on {1}: but outside toolchain {2}" -f $Source, $letter, $ToolchainKey)
}

# --------------------------------------------------------------------
# IDE INTEGRATION: QT CREATOR
# --------------------------------------------------------------------

function Get-DrivEnvQtCreatorSetup
{
    # @brief Everything step 7 needs, resolved in one place, or $null without a Qt Creator integration.
    # The drive owns one Qt Creator: user settings and installer settings under env\qtcreator, passed by every launcher
    # (one per toolchain) as -settingspath / -installsettingspath. sdktool writes the kits into --sdkpath, read from
    # <installsettingspath>\QtProject\qtcreator (SdkPath); QtProject\QtCreator.ini must exist there (InstallIni),
    # or Qt Creator shows an error at every start.
    # The user's own Qt Creator only with register_in_user_settings, through Merge-DrivEnvQtUserSettings (never
    # sdktool, which rewrites those files and whose SDK kits Qt Creator discards).
    #   msys2     <L>:\msys64\<subsystem>\bin\qtcreator.exe and sdktool.exe (that subsystem's qt-creator package)
    #   external  the configured path; sdktool beside it, in <Qt>\Tools\sdktool\bin, or 'sdktool'
    # One entry per DECLARED toolchain whose env file exists.
    # @return A hashtable: Source, Subsystem, QtCreator, Sdktool, Root, InstallSettings, InstallIni, UserSettings,
    #         SdkPath, Drive, Prefix, LauncherDir, CustomVariableNames, CustomPathEntries, Toolchains (array of @{ Id;
    #         Key; Names; Family; Arch; KitName; EnvFile }), Holder (msys2: the toolchain providing Qt Creator, else
    #         $null), RegisterInUserSettings, UserSettingsRoot, UserQtSettingsDir, UserIdPrefix.
    param ($Cfg)

    if (($null -eq $Cfg) -or ($null -eq $Cfg.ide_integration) -or ($null -eq $Cfg.ide_integration.qtcreator)) { return $null }
    $q = $Cfg.ide_integration.qtcreator

    $source = ([string]$q.source).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($source) -or ($source -eq 'none')) { return $null }

    $letter  = ([string]$Cfg.environment.dev_drive_letter).Trim().TrimEnd(@(':', '\', '/')).ToUpperInvariant()
    $envName = ([string]$Cfg.environment.dev_env_name).Trim()
    $prefix  = $envName.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($letter) -or [string]::IsNullOrWhiteSpace($prefix)) { return $null }

    $drive = $letter + ':'
    $root  = $drive + '\env\qtcreator'

    $subsystem = ""
    $exe = ""
    $sdktool = ""
    if ($source -eq 'msys2')
    {
        $subsystem = ([string]$q.subsystem).Trim().ToLowerInvariant()
        $exe       = $drive + '\msys64\' + $subsystem + '\bin\qtcreator.exe'
        $sdktool   = $drive + '\msys64\' + $subsystem + '\bin\sdktool.exe'
    }
    else
    {
        $exe = ([string]$q.path).Trim().Replace('/', '\')
        $given = ([string]$q.sdktool).Trim()
        if ($given) { $sdktool = $given.Replace('/', '\') }
        else
        {
            # Beside qtcreator.exe (MSYS2's package, a self-built one), or where the Qt online installer puts it: a
            # component of its own, <Qt>\Tools\sdktool\bin, next to <Qt>\Tools\QtCreator\bin (measured: Qt Creator 20.0.1).
            # The first that exists; beside, when neither does, for step 7's "not found" to name.
            $exeDir   = [System.IO.Path]::GetDirectoryName($exe)
            $beside   = Join-Path $exeDir 'sdktool.exe'
            $toolsDir = $null
            if ($exeDir) { $toolsDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($exeDir)) }
            $sdktool  = $beside
            if ((-not (Test-Path -LiteralPath $beside)) -and $toolsDir)
            {
                $component = Join-Path $toolsDir 'sdktool\bin\sdktool.exe'
                if (Test-Path -LiteralPath $component) { $sdktool = $component }
            }
        }
    }

    $customNames = @()
    if (($null -ne $Cfg.environment) -and (Test-DrivEnvIsObject $Cfg.environment.custom_variables))
    {
        $customNames = @($Cfg.environment.custom_variables.PSObject.Properties | ForEach-Object { $_.Name })
    }
    $customPath = @()
    if ($null -ne $Cfg.environment) { $customPath = @($Cfg.environment.custom_path_entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ([string]$_).Trim() }) }

    $toolchains = @()
    foreach ($t in (Get-DrivEnvDeclaredTargets -Cfg $Cfg))
    {
        $n = Get-DrivEnvToolchainNames -Cfg $t.Cfg
        if ($null -eq $n) { continue }
        $sub = Resolve-DrivEnvMsys2Target -Target $t.Cfg.msys2.target
        $toolchains += @{
            Id      = $(if ($t.Id) { $t.Id } else { $t.Key })
            Key     = $n.Key
            Names   = $n
            Family  = [string]$sub.Family
            Arch    = [string]$sub.Arch
            KitName = $envName + ' ' + $n.Key
            EnvFile = $n.EnvFile
        }
    }

    $holder = $null
    if ($source -eq 'msys2') { $holder = @($toolchains | Where-Object { $_.Key -ieq $subsystem }) | Select-Object -First 1 }

    # The user's own Qt Creator settings directory -- the one holding QtCreator.ini and qtcreator\ -- as the
    # configuration names it (owner, 2026-10-19: explicit rather than assumed), %VARS% expanded; where Qt Creator's
    # QSettings put it, %APPDATA%\QtProject, when not named. The kits' files are in its qtcreator\.
    $usp = ([string]$q.user_settings_path).Trim()
    if (-not $usp) { $usp = '%APPDATA%/QtProject' }
    $userRoot  = [Environment]::ExpandEnvironmentVariables($usp).Replace('/', '\').TrimEnd('\')
    $userQtDir = Join-Path $userRoot 'qtcreator'

    return @{
        Source              = $source
        Subsystem           = $subsystem
        QtCreator           = $exe
        Sdktool             = $sdktool
        Root                = $root
        InstallSettings     = $root + '\install'
        InstallIni          = $root + '\install\QtProject\QtCreator.ini'
        UserSettings        = $root + '\settings'
        SdkPath             = $root + '\install\QtProject\qtcreator'
        Drive               = $drive
        Prefix              = $prefix
        LauncherDir         = $drive + '\env\launcher'
        CustomVariableNames = [string[]]$customNames
        CustomPathEntries   = [string[]]$customPath
        Toolchains          = @($toolchains)
        Holder              = $holder
        RegisterInUserSettings = ($q.register_in_user_settings -eq $true)
        UserSettingsRoot       = $userRoot
        UserQtSettingsDir      = $userQtDir
        UserIdPrefix           = 'drivenv.' + $letter.ToLowerInvariant() + '.'
    }
}

function Resolve-DrivEnvEnvValues
{
    # @brief An env file's lines with ${NAME}/$NAME expanded as the launcher does: top to bottom, then the inherited
    # environment, undefined -> empty; quotes stripped; Windows paths kept (as Qt Creator wants).
    # @param Lines The file's lines.
    # @return An [ordered] hashtable, a later line for a key replacing the earlier.
    param ([string[]]$Lines = @())

    function Get-Defined { param($n) if ($map.Contains($n)) { return [string]$map[$n] } return [string][Environment]::GetEnvironmentVariable($n) }

    $map = [ordered]@{}
    foreach ($raw in @($Lines))
    {
        $line = ([string]$raw).TrimEnd("`r").Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        $i = $line.IndexOf('=')
        if ($i -le 0) { continue }
        $key = $line.Substring(0, $i).Trim()
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
        $val = $line.Substring($i + 1)
        if (($val.Length -ge 2) -and ((($val[0] -eq '"') -and ($val[-1] -eq '"')) -or (($val[0] -eq "'") -and ($val[-1] -eq "'")))) { $val = $val.Substring(1, $val.Length - 2) }

        for ($pass = 0; $pass -lt 10; $pass++)
        {
            $before = $val
            $val = [regex]::Replace($val, '\$\{([A-Za-z_][A-Za-z0-9_]*)\}', { param($m) Get-Defined $m.Groups[1].Value })
            $val = [regex]::Replace($val, '\$([A-Za-z_][A-Za-z0-9_]*)', { param($m) Get-Defined $m.Groups[1].Value })
            if ($val -ceq $before) { break }
        }
        $map[$key] = $val
    }
    return $map
}

function Get-DrivEnvQtKitSpec
{
    # @brief One toolchain's Qt Creator kit for sdktool, from its expanded env file: what its launcher gives a shell.
    #   compilers   <root>\bin clang/clang++ or gcc/g++, type ProjectExplorer.ToolChain.Mingw, ABI
    #               <arch>-windows-msys-pe-<bits> (as MSYS2's own qt-creator registers both families)
    #   debugger    gdb; CMake its cmake with Ninja
    #   CMake       vcpkg toolchain file and triplet; compilers as %{Compiler:Executable:...}
    #   environment the env file's public variables, VCPKG_*, custom_variables, MSYSTEM; PATH prefixed in the
    #               launcher's order (vcpkg bin first, toolchain bin last) so vcpkg's DLLs win over MSYS2's
    #   Qt          the toolchain's vcpkg Qt, when there is one, with CMAKE_PREFIX_PATH=%{Qt:QT_INSTALL_PREFIX};
    #               otherwise Qt Creator picks one from PATH, the same for every kit
    # Ids carry the stem (drivenv.degorasslr_clang64).
    # @param ToolDirs The vcpkg tool folders (Get-DrivEnvVcpkgToolDirs); passed in, so this stays pure.
    # @param QMake    The toolchain's vcpkg qmake6.exe, or "" without a Qt.
    # @param IdPrefix 'drivenv.' on the drive; 'drivenv.<letter>.' for the user's own Qt Creator.
    # @return Ids, names, paths, QtId/QtName/QMake ("" without a Qt), CMakeConfig [string[]] and Env [string[]].
    param ($Names, $EnvValues, [string]$Family, [string]$Arch = 'x86_64', [string]$KitName, [string[]]$CustomNames = @(), [string[]]$CustomPathEntries = @(),
           [string[]]$ToolDirs = @(), [string]$QMake = "", [string]$IdPrefix = 'drivenv.')

    function V { param($k) if (($null -ne $EnvValues) -and $EnvValues.Contains($k)) { return ([string]$EnvValues[$k]).Trim() } return '' }

    $root = (V 'DEVSYSTEM_TOOLCHAIN_ROOT').TrimEnd('/')
    if (-not $root) { $root = (V 'MSYS2_ROOT').TrimEnd('/') + '/' + $Names.Key }
    $bin  = $root + '/bin'

    $isClang = ([string]$Family).Trim() -ieq 'clang'
    $cc  = if ($isClang) { "$bin/clang.exe" }   else { "$bin/gcc.exe" }
    $cxx = if ($isClang) { "$bin/clang++.exe" } else { "$bin/g++.exe" }

    $abiArch = switch -Regex (([string]$Arch).Trim().ToLowerInvariant()) { '^aarch64$' { 'arm' } default { 'x86' } }
    $bits    = if (([string]$Arch).Trim() -ieq 'i686') { '32bit' } else { '64bit' }
    $abi     = "$abiArch-windows-msys-pe-$bits"

    $base = $IdPrefix + $Names.Stem

    $vcpkg   = (V 'VCPKG_ROOT').TrimEnd('/')
    $triplet = V 'VCPKG_DEFAULT_TRIPLET'
    $host_   = V 'VCPKG_DEFAULT_HOST_TRIPLET'; if (-not $host_) { $host_ = $triplet }
    $ovt     = V 'VCPKG_OVERLAY_TRIPLETS'

    $cmakeConfig = @(
        'CMAKE_C_COMPILER:FILEPATH=%{Compiler:Executable:C}',
        'CMAKE_CXX_COMPILER:FILEPATH=%{Compiler:Executable:Cxx}',
        "CMAKE_TOOLCHAIN_FILE:FILEPATH=$vcpkg/scripts/buildsystems/vcpkg.cmake",
        "VCPKG_TARGET_TRIPLET:STRING=$triplet",
        "VCPKG_HOST_TRIPLET:STRING=$host_"
    )
    if ($ovt) { $cmakeConfig += "VCPKG_OVERLAY_TRIPLETS:PATH=$ovt" }
    if ($QMake) { $cmakeConfig += 'CMAKE_PREFIX_PATH:PATH=%{Qt:QT_INSTALL_PREFIX}' }

    $contract = @('DEVSYSTEM_NAME', 'DEVDRIVE_LETTER', 'DEVSYSTEM_TOOLCHAIN_ROOT', 'DEVSYSTEM_TOOLCHAIN', 'DEVSYSTEM_TOOLCHAIN_ID',
                  'DEVSYSTEM_BUILDTREES', 'DEVSYSTEM_DEPLOYS', 'DEVSYSTEM_WORKSPACE', 'VCPKG_ROOT', 'VCPKG_DEFAULT_TRIPLET',
                  'VCPKG_DEFAULT_HOST_TRIPLET', 'VCPKG_OVERLAY_PORTS', 'VCPKG_OVERLAY_TRIPLETS', 'VCPKG_DEFAULT_BINARY_CACHE')
    $kitEnv = @()
    $seen = @{}
    foreach ($k in (@($contract) + @($CustomNames)))
    {
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $v = V $k
        if ($v) { $kitEnv += "$k=$v" }
    }
    # MSYSTEM, the one MSYS2 variable a kit carries: the drive's triplets hash it into every package's ABI
    # (VCPKG_ENV_PASSTHROUGH), and the shell and step 4 build with it set -- so a vcpkg run from a kit without it, a
    # manifest-mode configure, would rebuild what is already built rather than reuse it.
    $msysEnv = V 'MSYS2_ENV'
    if ($msysEnv) { $kitEnv += ('MSYSTEM=' + $msysEnv.ToUpperInvariant()) }

    $pathParts = @()
    $vbin = V 'VCPKG_BIN'; if ($vbin) { $pathParts += $vbin }
    if ($vcpkg) { $pathParts += $vcpkg }
    foreach ($p in @($CustomPathEntries))
    {
        $x = (Resolve-DrivEnvEnvValues -Lines @(@($EnvValues.Keys | ForEach-Object { "$_=$($EnvValues[$_])" }) + "DP_ENTRY=$p"))['DP_ENTRY']
        if ($x) { $pathParts += $x }
    }
    $pathParts += @($ToolDirs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $pathParts += $bin
    $kitEnv += ('PATH=+' + ($pathParts -join ';'))

    return @{
        KitId = $base; KitName = $KitName
        CId = "ProjectExplorer.ToolChain.Mingw:$base.c";   CName   = "$KitName (C)"
        CxxId = "ProjectExplorer.ToolChain.Mingw:$base.cxx"; CxxName = "$KitName (C++)"
        DebuggerId = "$base.gdb"; DebuggerName = "$KitName GDB"
        CMakeId = "$base.cmake"; CMakeName = "$KitName CMake"
        QtId = $(if ($QMake) { "$base.qt" } else { "" }); QtName = "Qt %{Qt:Version} (vcpkg $triplet)"; QMake = $QMake
        CCompiler = $cc; CxxCompiler = $cxx; Gdb = "$bin/gdb.exe"; CMake = "$bin/cmake.exe"
        Abi = $abi
        CMakeConfig = [string[]]$cmakeConfig
        Env = [string[]]$kitEnv
    }
}

function ConvertTo-DrivEnvSdktoolCalls
{
    # @brief The sdktool calls registering one kit spec under SdkPath: two compilers, debugger, CMake, Qt, kit. No
    # removal: the folder is rebuilt from nothing (sdktool's rm* drop what they do not know).
    # DO NOT WRAP A CALL TO THIS IN @(...): it comma-returns an array of argument arrays.
    param ($Spec, [string]$SdkPath)

    $sp = "--sdkpath=$SdkPath"
    $calls = @()
    $calls += ,@($sp, 'addTC', '--id', $Spec.CId, '--language', 'C', '--name', $Spec.CName, '--path', $Spec.CCompiler, '--abi', $Spec.Abi, '--supportedAbis', $Spec.Abi)
    $calls += ,@($sp, 'addTC', '--id', $Spec.CxxId, '--language', 'Cxx', '--name', $Spec.CxxName, '--path', $Spec.CxxCompiler, '--abi', $Spec.Abi, '--supportedAbis', $Spec.Abi)
    $calls += ,@($sp, 'addDebugger', '--id', $Spec.DebuggerId, '--name', $Spec.DebuggerName, '--engine', '1', '--binary', $Spec.Gdb, '--abis', $Spec.Abi)
    $calls += ,@($sp, 'addCMake', '--id', $Spec.CMakeId, '--name', $Spec.CMakeName, '--path', $Spec.CMake)
    if ($Spec.QtId) { $calls += ,@($sp, 'addQt', '--id', $Spec.QtId, '--name', $Spec.QtName, '--qmake', $Spec.QMake, '--type', 'Qt4ProjectManager.QtVersion.Desktop') }

    $kit = @($sp, 'addKit', '--id', $Spec.KitId, '--name', $Spec.KitName, '--devicetype', 'Desktop',
             '--Ctoolchain', $Spec.CId, '--Cxxtoolchain', $Spec.CxxId, '--debuggerid', $Spec.DebuggerId,
             '--cmake', $Spec.CMakeId, '--cmake-generator', 'Ninja')
    if ($Spec.QtId) { $kit += @('--qt', $Spec.QtId) }
    foreach ($c in @($Spec.CMakeConfig)) { $kit += @('--cmake-config', $c) }
    foreach ($e in @($Spec.Env))         { $kit += @('--env', $e) }
    $calls += ,$kit

    return ,@($calls)
}

function Merge-DrivEnvQtUserSettings
{
    # @brief Adds a drive's kits (and their toolchains, debuggers, CMakes, Qt versions) to the user's OWN Qt Creator
    # settings as MANUAL entries, touching nothing else. sdktool only generates them into GeneratedDir (on the user's
    # files it drops their default kit, and Qt Creator discards SDK entries). Grafted here:
    #   * installer flags cleared; a Qt's "SDK.<id>" source -> "<id>" and a new int Id the kit refers to; a kit with no
    #     imported Qt gets QtInformation -1 (otherwise Qt Creator picks one by ABI);
    #   * a toolchain equal to a MANUAL one of the user's (type, language, compiler, ABI, flags) is not imported: the
    #     kit uses the user's, since Qt Creator deletes equal duplicates at start (makeUniqueByEqual);
    #   * user entries kept, in NUMERIC order (Qt writes ToolChain.0, .1, .10...); other keys never touched;
    #   * this drive's earlier entries (OwnPrefix, e.g. "drivenv.d.") replaced, so a re-run is idempotent.
    # One transaction over the files that change (a file with nothing to change is not written or created): backups
    # (<file>.drivenv-<Stamp>.bak; an existing Stamp is a refusal), write, re-read and verify, restore all on failure.
    # The XML is re-serialized; formatting may differ, values do not.
    # @return @{ Ok; Message; Kits = names added; Backups = paths }.
    param ([string]$GeneratedDir, [string]$UserDir, [string]$OwnPrefix, [string]$Stamp)

    $files = @(
        @{ Name = 'qtversion.xml';  Doctype = 'QtCreatorQtVersions'; Prefix = 'QtVersion.';    HasCount = $false; IdKey = 'autodetectionSource' },
        @{ Name = 'toolchains.xml'; Doctype = 'QtCreatorToolChains'; Prefix = 'ToolChain.';    HasCount = $true;  IdKey = 'ProjectExplorer.ToolChain.Id' },
        @{ Name = 'debuggers.xml';  Doctype = 'QtCreatorDebuggers';  Prefix = 'DebuggerItem.'; HasCount = $true;  IdKey = 'Id' },
        @{ Name = 'cmaketools.xml'; Doctype = 'QtCreatorCmaketools'; Prefix = 'CMakeTools.';   HasCount = $true;  IdKey = 'Id' },
        @{ Name = 'profiles.xml';   Doctype = 'QtCreatorProfiles';   Prefix = 'Profile.';      HasCount = $true;  IdKey = 'PE.Profile.Id' }
    )
    $enc = New-Object System.Text.UTF8Encoding($false)

    function Read-Doc { param([string]$Path, [string]$Doctype)
        $d = New-Object System.Xml.XmlDocument
        $d.PreserveWhitespace = $true
        if (Test-Path -LiteralPath $Path) { $d.LoadXml([System.IO.File]::ReadAllText($Path, $enc)) }
        else { $d.LoadXml("<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n<!DOCTYPE $Doctype>`n<qtcreator>`n <data>`n  <variable>Version</variable>`n  <value type=`"int`">1</value>`n </data>`n</qtcreator>`n") }
        return ,$d
    }
    # Errors STOP here: a helper failing quietly once made the check below compare two equally empty lists and pass.
    $ErrorActionPreference = 'Stop'
    # Unrolled on purpose -- every caller wraps it in @() -- so a pipeline sees entries, not one array.
    function Get-Entries { param($Doc, [string]$Prefix)
        $rx = '^' + [regex]::Escape($Prefix) + '\d+$'
        return @($Doc.DocumentElement.SelectNodes('data') | Where-Object { $_.SelectSingleNode('variable').InnerText -match $rx })
    }
    function Get-Map { param($Data) return $Data.SelectSingleNode('valuemap') }
    function Get-Val { param($Map, [string]$Key) $n = @($Map.ChildNodes | Where-Object { ($_.NodeType -eq 'Element') -and ($_.GetAttribute('key') -ceq $Key) }) | Select-Object -First 1; if ($n) { return $n.InnerText } return $null }
    function Set-Val { param($Map, [string]$Key, [string]$Type, [string]$Text)
        $n = @($Map.ChildNodes | Where-Object { ($_.NodeType -eq 'Element') -and ($_.GetAttribute('key') -ceq $Key) }) | Select-Object -First 1
        if (-not $n) { $n = $Map.OwnerDocument.CreateElement('value'); $n.SetAttribute('type', $Type); $n.SetAttribute('key', $Key); [void]$Map.AppendChild($n) }   # Qt's attribute order
        $n.SetAttribute('type', $Type); $n.InnerText = $Text
    }
    function Test-Ours { param([string]$Id) return ($Id -and (($Id.StartsWith($OwnPrefix)) -or ($Id -like "*:$OwnPrefix*"))) }
    function Get-Keyed { param($Doc, [string]$Prefix)
        # The keys outside the numbered entries, by name, as their exact XML: what must survive untouched.
        $rx = '^' + [regex]::Escape($Prefix) + '(\d+|Count)$'; $h = @{}
        foreach ($d in $Doc.DocumentElement.SelectNodes('data')) { $v = $d.SelectSingleNode('variable').InnerText; if ($v -notmatch $rx) { $h[$v] = $d.OuterXml } }
        return $h
    }
    function Get-Index { param($Data, [string]$Prefix) return [int]$Data.SelectSingleNode('variable').InnerText.Substring($Prefix.Length) }
    # The user's entries -- everything not this drive's -- in the order Qt Creator reads them: by number.
    # ponytail: an entry Qt Creator ignores (past Count, after a gap) is kept and numbered like the rest.
    function Get-UserEntries { param($Doc, [string]$Prefix, [string]$IdKey)
        return @(@(Get-Entries -Doc $Doc -Prefix $Prefix) | Where-Object { -not (Test-Ours (Get-Val (Get-Map $_) $IdKey)) } | Sort-Object { Get-Index $_ $Prefix })
    }
    function Get-TcKey { param($Map)
        # What Qt Creator's GccToolchain::operator== compares: type, language, compiler, target ABI, the two flag lists.
        $lang = [string](Get-Val $Map 'ProjectExplorer.ToolChain.LanguageV2')
        if (-not $lang) { $lang = @{ '1' = 'C'; '2' = 'Cxx' }[[string](Get-Val $Map 'ProjectExplorer.ToolChain.Language')] }
        $flags = foreach ($k in 'PlatformCodeGenFlags', 'PlatformLinkerFlags') { $n = $Map.SelectSingleNode("valuelist[@key='ProjectExplorer.GccToolChain.$k']"); if ($n) { @($n.SelectNodes('value') | ForEach-Object { $_.InnerText }) -join "`t" } else { '' } }
        return (@(([string](Get-Val $Map 'ProjectExplorer.ToolChain.Id')).Split(':')[0], $lang,
                  ([string](Get-Val $Map 'ProjectExplorer.GccToolChain.Path')).Replace('\', '/').ToLowerInvariant(),
                  [string](Get-Val $Map 'ProjectExplorer.GccToolChain.TargetAbi')) + @($flags)) -join '|'
    }

    # Read everything first: a user file that does not parse is a refusal, before anything is written.
    $docs = @{}; $origUser = @{}; $origKeyed = @{}
    foreach ($f in $files)
    {
        $p = Join-Path $UserDir $f.Name
        try { $docs[$f.Name] = Read-Doc -Path $p -Doctype $f.Doctype }
        catch { return @{ Ok = $false; Message = "$p is not a Qt Creator settings file this can read ($($_.Exception.Message)); nothing was changed."; Kits = @(); Backups = @() } }
        $origUser[$f.Name]  = @(Get-UserEntries -Doc $docs[$f.Name] -Prefix $f.Prefix -IdKey $f.IdKey | ForEach-Object { (Get-Map $_).OuterXml })
        $origKeyed[$f.Name] = Get-Keyed -Doc $docs[$f.Name] -Prefix $f.Prefix
    }

    # The user's MANUAL toolchains by what makes two equal to Qt Creator: a twin of one is not imported (see above).
    $userTcs = @{}
    foreach ($e in @(Get-UserEntries -Doc $docs['toolchains.xml'] -Prefix 'ToolChain.' -IdKey 'ProjectExplorer.ToolChain.Id'))
    {
        $m = Get-Map $e
        if (([string](Get-Val $m 'ProjectExplorer.ToolChain.Autodetect') -ne 'true') -and (Get-Val $m 'ProjectExplorer.GccToolChain.Path')) { $k = Get-TcKey $m; if (-not $userTcs.ContainsKey($k)) { $userTcs[$k] = [string](Get-Val $m 'ProjectExplorer.ToolChain.Id') } }
    }
    $tcReuse = @{}

    # The new Qt version ids: above every id the user's file holds, so nothing of theirs is shadowed.
    $qtDoc = $docs['qtversion.xml']; $maxId = 0
    foreach ($e in @(Get-Entries -Doc $qtDoc -Prefix 'QtVersion.')) { $i = 0; if ([int]::TryParse([string](Get-Val (Get-Map $e) 'Id'), [ref]$i) -and ($i -gt $maxId)) { if (-not (Test-Ours (Get-Val (Get-Map $e) 'autodetectionSource'))) { $maxId = $i } } }
    $qtIdMap = @{}; $kitsAdded = @(); $changed = @()

    foreach ($f in $files)
    {
        $doc = $docs[$f.Name]; $imported = @(); $removed = 0
        foreach ($e in @(Get-Entries -Doc $doc -Prefix $f.Prefix)) { if (Test-Ours (Get-Val (Get-Map $e) $f.IdKey)) { [void]$doc.DocumentElement.RemoveChild($e); $removed++ } }

        $genPath = Join-Path $GeneratedDir $f.Name
        if (Test-Path -LiteralPath $genPath)
        {
            $gen = Read-Doc -Path $genPath -Doctype $f.Doctype
            foreach ($g in @(Get-Entries -Doc $gen -Prefix $f.Prefix))
            {
                $n = $doc.ImportNode($g, $true); $m = Get-Map $n
                switch ($f.Name)
                {
                    'qtversion.xml'  {
                        $src = [string](Get-Val $m 'autodetectionSource'); $maxId++; $qtIdMap[$src] = $maxId
                        Set-Val $m 'Id' 'int' "$maxId"; Set-Val $m 'isAutodetected' 'bool' 'false'
                        Set-Val $m 'autodetectionSource' 'QString' ($src -replace '^SDK\.', '')
                    }
                    'toolchains.xml' {
                        Set-Val $m 'ProjectExplorer.ToolChain.Autodetect' 'bool' 'false'
                        $twin = $userTcs[(Get-TcKey $m)]
                        if ($twin) { $tcReuse[[string](Get-Val $m 'ProjectExplorer.ToolChain.Id')] = $twin; $n = $null }
                    }
                    'debuggers.xml'  { Set-Val $m 'AutoDetected' 'bool' 'false' }
                    'cmaketools.xml' { Set-Val $m 'Autodetect' 'bool' 'false' }
                    'profiles.xml'   {
                        Set-Val $m 'PE.Profile.AutoDetected' 'bool' 'false'; Set-Val $m 'PE.Profile.SDK' 'bool' 'false'
                        $data = $m.SelectSingleNode("valuemap[@key='PE.Profile.Data']")
                        if ($data)
                        {
                            $q = [string](Get-Val $data 'QtSupport.QtInformation')
                            Set-Val $data 'QtSupport.QtInformation' 'int' $(if ($q -and $qtIdMap.ContainsKey($q)) { "$($qtIdMap[$q])" } else { '-1' })
                            $tcs = $data.SelectSingleNode("valuemap[@key='PE.Profile.ToolChainsV3']")
                            if ($tcs) { foreach ($v in @($tcs.SelectNodes('value'))) { if ($tcReuse.ContainsKey($v.InnerText)) { $v.InnerText = $tcReuse[$v.InnerText] } } }
                        }
                        $kitsAdded += [string](Get-Val $m 'PE.Profile.Name')
                    }
                }
                if ($n) { [void]$doc.DocumentElement.AppendChild($n); $imported += $n }
            }
        }
        if (($removed -eq 0) -and ($imported.Count -eq 0)) { continue }   # nothing of this drive's here: not written
        $changed += $f

        # Renumbered -- the user's first, in their numeric order, then this drive's -- and the Count set to match.
        $all = @(Get-UserEntries -Doc $doc -Prefix $f.Prefix -IdKey $f.IdKey) + $imported
        for ($i = 0; $i -lt $all.Count; $i++) { $all[$i].SelectSingleNode('variable').InnerText = "$($f.Prefix)$i" }
        if ($f.HasCount)
        {
            $cnt = @($doc.DocumentElement.SelectNodes('data') | Where-Object { $_.SelectSingleNode('variable').InnerText -ceq "$($f.Prefix)Count" }) | Select-Object -First 1
            if (-not $cnt) { $cnt = $doc.CreateElement('data'); $cnt.InnerXml = "<variable>$($f.Prefix)Count</variable><value type=`"int`">0</value>"; [void]$doc.DocumentElement.AppendChild($cnt) }
            $cnt.SelectSingleNode('value').InnerText = "$($all.Count)"
        }
    }

    if ($changed.Count -eq 0) { return @{ Ok = $true; Message = "Nothing to change."; Kits = @(); Backups = @() } }

    # Backup, write, re-read and check; restore everything on any failure. A backup is never overwritten: under an
    # already used Stamp it may be the only copy of the files as they were.
    $taken = @($changed | ForEach-Object { Join-Path $UserDir "$($_.Name).drivenv-$Stamp.bak" } | Where-Object { Test-Path -LiteralPath $_ })
    if ($taken.Count -gt 0) { return @{ Ok = $false; Message = "a backup with the stamp '$Stamp' exists already ($($taken -join ', ')); nothing was changed, run again."; Kits = @(); Backups = @() } }
    New-Item -ItemType Directory -Path $UserDir -Force | Out-Null
    $backups = @(); $created = @()
    foreach ($f in $changed)
    {
        $p = Join-Path $UserDir $f.Name
        if (Test-Path -LiteralPath $p) { $b = "$p.drivenv-$Stamp.bak"; Copy-Item -LiteralPath $p -Destination $b; $backups += $b } else { $created += $p }
    }
    $problem = ""
    try
    {
        foreach ($f in $changed) { [System.IO.File]::WriteAllText((Join-Path $UserDir $f.Name), $docs[$f.Name].OuterXml, $enc) }
        foreach ($f in $changed)
        {
            $chk = Read-Doc -Path (Join-Path $UserDir $f.Name) -Doctype $f.Doctype
            $now = @(Get-UserEntries -Doc $chk -Prefix $f.Prefix -IdKey $f.IdKey | ForEach-Object { (Get-Map $_).OuterXml })
            if (($now -join "`n") -cne ($origUser[$f.Name] -join "`n")) { $problem = "$($f.Name): the user's own entries did not survive unchanged and in order"; break }
            $keyed = Get-Keyed -Doc $chk -Prefix $f.Prefix
            foreach ($k in $origKeyed[$f.Name].Keys) { if ($keyed[$k] -cne $origKeyed[$f.Name][$k]) { $problem = "$($f.Name): '$k' changed"; break } }
            if ($problem) { break }
            $entries = @(Get-Entries -Doc $chk -Prefix $f.Prefix)
            $nums = @($entries | ForEach-Object { Get-Index $_ $f.Prefix } | Sort-Object)
            for ($i = 0; $i -lt $nums.Count; $i++) { if ($nums[$i] -ne $i) { $problem = "$($f.Name): numbering is not contiguous"; break } }
            if ($problem) { break }
            if ($f.HasCount -and ([string]@($chk.DocumentElement.SelectNodes('data') | Where-Object { $_.SelectSingleNode('variable').InnerText -ceq "$($f.Prefix)Count" })[0].SelectSingleNode('value').InnerText -ne "$($entries.Count)"))
            { $problem = "$($f.Name): the Count does not match the entries"; break }
        }
    }
    catch { $problem = $_.Exception.Message }

    if ($problem)
    {
        # Every file is tried, whatever fails: one locked file must not leave the others half-registered.
        $stuck = @()
        foreach ($f in $changed)
        {
            $p = Join-Path $UserDir $f.Name; $b = "$p.drivenv-$Stamp.bak"
            try { if (Test-Path -LiteralPath $b) { Copy-Item -LiteralPath $b -Destination $p -Force } elseif ($created -contains $p) { Remove-Item -LiteralPath $p -Force } }
            catch { $stuck += "$p (its backup: $b)" }
        }
        if ($stuck.Count -gt 0) { return @{ Ok = $false; Message = "Not registered: $problem. And NOT restored, copy the backup back by hand: $($stuck -join '; ')"; Kits = @(); Backups = $backups } }
        return @{ Ok = $false; Message = "Not registered, and every file restored: $problem"; Kits = @(); Backups = $backups }
    }
    return @{ Ok = $true; Message = "Registered."; Kits = $kitsAdded; Backups = $backups }
}

function Get-DrivEnvVcpkgToolDirs
{
    # @brief The vcpkg tool folders the launcher puts on PATH: installed/<triplet>/tools/<port>/ and one level below,
    # holding an .exe. Read at step 7, so a kit has what step 7 saw.
    # @return Forward-slashed paths; empty without VcpkgRoot, Triplet or a tools folder.
    param ([string]$VcpkgRoot, [string]$Triplet)

    if ([string]::IsNullOrWhiteSpace($VcpkgRoot) -or [string]::IsNullOrWhiteSpace($Triplet)) { return @() }
    $tools = Join-Path (Join-Path (Join-Path $VcpkgRoot.Trim() 'installed') $Triplet.Trim()) 'tools'
    if (-not (Test-Path -LiteralPath $tools -PathType Container)) { return @() }

    $level1 = @(Get-ChildItem -LiteralPath $tools -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    $level2 = @($level1 | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name })
    $dirs = @()
    foreach ($d in @($level1) + @($level2))
    {
        if (@(Get-ChildItem -LiteralPath $d.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue).Count -gt 0) { $dirs += ($d.FullName -replace '\\', '/') }
    }
    return $dirs
}

function Get-DrivEnvQtKitProblem
{
    # @brief Why a toolchain's env file cannot make a working kit yet, or "" when it can. Step 2 writes the env file
    # without any VCPKG_* -- step 3 adds them -- and a kit made from that would configure against
    # /scripts/buildsystems/vcpkg.cmake with an empty triplet: registered, and broken.
    param ($EnvValues)

    function V { param($k) if (($null -ne $EnvValues) -and $EnvValues.Contains($k)) { return ([string]$EnvValues[$k]).Trim() } return '' }

    $vcpkg = (V 'VCPKG_ROOT').TrimEnd('/', '\')
    if (-not $vcpkg) { return "its env file has no VCPKG_ROOT yet (step 3 adds it)" }
    if (-not (V 'VCPKG_DEFAULT_TRIPLET')) { return "its env file has no VCPKG_DEFAULT_TRIPLET yet (step 3 adds it)" }
    $tc = $vcpkg + '/scripts/buildsystems/vcpkg.cmake'
    if (-not (Test-Path -LiteralPath $tc)) { return "the vcpkg toolchain file is missing: $tc" }
    return ""
}

function ConvertTo-DrivEnvNativeArgument
{
    # @brief One argument quoted for a Windows command line, as CommandLineToArgvW parses it back. Needed because 5.1
    # does not double a trailing backslash inside quotes ('X=C:\My Tool\' swallowed the next arguments) and drops
    # embedded quotes.
    param ([string]$Argument)

    if (($Argument.Length -gt 0) -and ($Argument -notmatch '[\s"]')) { return $Argument }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append([char]'"')
    $slashes = 0
    foreach ($ch in $Argument.ToCharArray())
    {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') { [void]$sb.Append([char]'\', 2 * $slashes + 1); [void]$sb.Append([char]'"') }
        else             { if ($slashes -gt 0) { [void]$sb.Append([char]'\', $slashes) }; [void]$sb.Append($ch) }
        $slashes = 0
    }
    if ($slashes -gt 0) { [void]$sb.Append([char]'\', 2 * $slashes) }
    [void]$sb.Append([char]'"')
    return $sb.ToString()
}

function Invoke-DrivEnvNative
{
    # @brief Run a Windows program with these arguments, each quoted by ConvertTo-DrivEnvNativeArgument, and wait.
    # @return @{ ExitCode; Output } -- Output being stdout then stderr, as lines.
    param ([string]$FilePath, [string[]]$Arguments = @())

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = (@($Arguments | ForEach-Object { ConvertTo-DrivEnvNativeArgument -Argument $_ }) -join ' ')
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    # stderr read in the background while stdout is drained, so neither pipe can fill and stall the program.
    $err = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $lines = @(($out + "`n" + $err.Result) -split "`r?`n" | Where-Object { $_ -ne '' })
    return @{ ExitCode = $p.ExitCode; Output = $lines }
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

            # Piped: on {} the member access yields $null, and @($null) has one element.
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

function Test-DrivEnvRootedPath
{
    # @brief [IO.Path]::IsPathRooted, minus its exception. The .NET Framework method checks the characters first and
    # THROWS on '|', '<', '>', '"' or a control character, so a rule calling it on a hand-edited value crashed the
    # validator instead of reporting. Same answer otherwise: a leading '\' or '/', or a ':' in second place.
    param ([string]$Path)

    return ([string]$Path -match '(?s)^([\\/]|.:)')
}

function Test-DrivEnvRules
{
    # @brief The checks that need more than one key, or that a type cannot express. ${REFERENCE} expansion in
    # custom_variables is checked by steps 1 and 3, not here.
    param ($Config, $Problems)

    $vcpkgSource = $Config.vcpkg.source
    if ($vcpkgSource -and ("$($vcpkgSource.baseline_mode)".Trim().ToLowerInvariant() -eq 'fixed'))
    {
        if ([string]::IsNullOrWhiteSpace($vcpkgSource.baseline_commit))
        {
            $Problems.Add("vcpkg.source.baseline_commit: required when baseline_mode is 'fixed'")
        }
    }

    # Layers are folders of an overlay set: naming some without saying which set is a configuration that would
    # silently build every package from upstream.
    if ($Config.vcpkg -and (@($Config.vcpkg.PSObject.Properties.Name) -contains 'overlay_ports') -and
        @($Config.vcpkg.overlay_ports | Where-Object { $_ -and @($_.layers | Where-Object { "$_".Trim() }).Count }).Count -and
        [string]::IsNullOrWhiteSpace([string]$Config.vcpkg.overlay_root))
    {
        $Problems.Add("vcpkg.overlay_ports: names layers but vcpkg.overlay_root, the folder holding them, is not set")
    }

    $environment = $Config.environment
    if ($environment -and ($environment.PSObject.Properties.Name -contains 'custom_folders'))
    {
        # The one token a folder may carry: ${DEVSYSTEM_TOOLCHAIN_ID}, replaced per toolchain. Any other ${...} would
        # become a literal folder name. Single quotes, or PowerShell expands it.
        $token = '${DEVSYSTEM_TOOLCHAIN_ID}'

        $i = 0
        foreach ($f in @($environment.custom_folders))
        {
            $p = "environment.custom_folders[$i]"
            $i++

            if ($f -isnot [string]) { continue }   # the type walk has already reported this one

            # CHECKED AS IT WILL BE USED: trimmed, with forward slashes, which is what Get-DrivEnvCustomFolders hands
            # the steps -- and that helper does not re-check, because this is where the check lives. Tested raw,
            # ' C:/logs' slipped through as relative (its second character is 'C', not ':') and came out as 'C:/logs'.
            $norm = $f.Trim().Replace('\', '/')
            if (Test-DrivEnvRootedPath $norm)
            {
                $Problems.Add("${p}: '$f' must be relative to the drive root, not absolute")
            }
            if ($norm.Contains('..'))
            {
                $Problems.Add("${p}: '$f' must not contain '..'")
            }
            if ($f.Replace($token, '').Contains('${'))
            {
                # The token goes in as an argument, never into the format string: '{DEVSYSTEM_TOOLCHAIN_ID}' there
                # is a format item, and -f throws.
                $Problems.Add(("{0}: '{1}' may carry no variable but {2} -- nothing else is expanded in a folder name" -f $p, $f, $token))
            }
        }
    }

    # workspace.default_folder, by the same rule and for the same reason: step 1 creates it and step 6 clones into
    # it, so a hand-edited value must not be able to send either off the drive. Resolve-DrivEnvWorkspaceFolder
    # refuses it again at run time; this is what makes it fail before step 1 has formatted a disk.
    $workspace = $Config.workspace
    if ((Test-DrivEnvIsObject $workspace) -and
        (@($workspace.PSObject.Properties | ForEach-Object { $_.Name }) -contains 'default_folder'))
    {
        $wf = $workspace.default_folder
        if (($wf -is [string]) -and -not [string]::IsNullOrWhiteSpace($wf))
        {
            if (Test-DrivEnvRootedPath $wf.Trim())
            {
                $Problems.Add("workspace.default_folder: '$wf' must be relative to the drive root, not absolute")
            }
            if ($wf.Contains('..'))
            {
                $Problems.Add("workspace.default_folder: '$wf' must not contain '..'")
            }
        }
    }

    # No custom variable over a name step 2 writes: re-running step 2 would silently delete the override.
    if ($Config.environment -and (Test-DrivEnvIsObject $Config.environment.custom_variables))
    {
        $stepTwoNames = @('DEVDRIVE_NAME', 'DEVDRIVE_LETTER', 'DEVSYSTEM_NAME', 'DEVSYSTEM_DEPLOYS', 'DEVSYSTEM_WORKSPACE',
                          'DEVSYSTEM_TOOLCHAIN_ROOT', 'DEVSYSTEM_TOOLCHAIN', 'DEVSYSTEM_TOOLCHAIN_ID',
                          'MSYS2_ROOT', 'MSYS2_BASH', 'MSYS2_ENV', 'BASE_PATH', 'PATH')
        foreach ($cv in @($Config.environment.custom_variables.PSObject.Properties | ForEach-Object { $_.Name }))
        {
            # -contains is case-insensitive, and so are the names on the Windows side of the launcher.
            if ($stepTwoNames -contains $cv)
            {
                $hint = if ($cv -ieq 'PATH') { "use environment.custom_path_entries" } else { "step 2 writes it, and a re-run of step 2 would delete the override" }
                $Problems.Add("environment.custom_variables.${cv}: reserved -- $hint")
            }
        }
    }

    # A per-package triplet override names a tree of its own -- vcpkg/installed/<triplet> -- so it is held to the
    # rule vcpkg.target.triplet is held to below. Blank is the schema's to report.
    if ($Config.vcpkg -and $Config.vcpkg.packages)
    {
        $i = 0
        foreach ($p in @($Config.vcpkg.packages))
        {
            $path = "vcpkg.packages[$i]"
            $i++

            if (-not (Test-DrivEnvIsObject $p)) { continue }
            if (@($p.PSObject.Properties | ForEach-Object { $_.Name }) -notcontains 'triplet') { continue }

            $t = $p.triplet
            if (($t -is [string]) -and -not [string]::IsNullOrWhiteSpace($t) -and ($t.Trim() -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$'))
            {
                $Problems.Add("${path}.triplet: '$t' must start with a letter or digit and hold only letters, digits, '.', '_' or '-' -- it names a vcpkg/installed tree (package '$($p.name)')")
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

    # ----------------------------------------------------------------
    # TOOLCHAINS
    # ----------------------------------------------------------------
    # What a schema node cannot check: id names, profiles against each other, and the resolved configuration.

    $rootNames    = @($Config.PSObject.Properties.Name)
    $hasToolchains = $rootNames -contains 'toolchains'
    $hasGenerate   = $rootNames -contains 'generate'

    # THE TWO KEYS ARE A PAIR. One without the other is always a mistake, and a silent one: 'toolchains' alone
    # would build nothing from them and look like it worked, 'generate' alone names ids that do not exist.
    if ($hasToolchains -and -not $hasGenerate)
    {
        $Problems.Add("generate: required when 'toolchains' is present -- name which of them to produce")
    }
    if ($hasGenerate -and -not $hasToolchains)
    {
        $Problems.Add("toolchains: required when 'generate' is present")
    }

    if ($hasToolchains -and $hasGenerate -and (Test-DrivEnvIsObject $Config.toolchains))
    {
        # Piped, for the same reason as in the walker ({} would yield one $null id).
        $declared = @($Config.toolchains.PSObject.Properties | ForEach-Object { $_.Name })

        # An id travels as -Toolchain and is printed in plans: no separators (the runner splits on , ; space) or quotes.
        foreach ($id in $declared)
        {
            if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.\-]*$')
            {
                $Problems.Add("toolchains.${id}: id must start alphanumeric and hold only letters, digits, '_', '.' or '-' -- it travels on the command line as -Toolchain")
            }
        }

        $wanted = @($Config.generate)
        if ($wanted.Count -eq 0)
        {
            $Problems.Add("generate: must name at least one toolchain")
        }

        $seen = @{}
        $i = 0
        foreach ($id in $wanted)
        {
            $path = "generate[$i]"
            $i++

            if ($id -isnot [string]) { continue }   # the type walk has already reported this one

            if ($declared -notcontains $id)
            {
                $sug = Get-DrivEnvSuggestion -Name $id -Candidates $declared
                if ($sug) { $Problems.Add("${path}: '$id' is not a declared toolchain. Did you mean '$sug'?") }
                else      { $Problems.Add("${path}: '$id' is not a declared toolchain") }
                continue
            }

            if ($seen.ContainsKey($id)) { $Problems.Add("${path}: '$id' is named more than once") }
            $seen[$id] = $true
        }

        # A pinned package with no version, inside a profile. The base list is checked above; this is the same
        # check with the path the user would have to edit, rather than the path of the merged result.
        foreach ($id in $declared)
        {
            $pkgs = $Config.toolchains.$id.msys2.packages
            if ($null -eq $pkgs) { continue }

            $j = 0
            foreach ($p in @($pkgs))
            {
                $path = "toolchains.${id}.msys2.packages[$j]"
                $j++
                if (("$($p.mode)".Trim().ToLowerInvariant() -eq 'pinned') -and [string]::IsNullOrWhiteSpace($p.version))
                {
                    $Problems.Add("${path}.version: required when mode is 'pinned' (package '$($p.name)')")
                }
            }
        }
    }

    # What each generated toolchain becomes: the requirements the schema relaxed are checked on the RESOLVED
    # configuration, and two toolchains must differ in subsystem and triplet (their homes on the drive).
    # Distinct ids only: a duplicate in 'generate' is reported once, above.
    $ids  = @()
    $once = @{}
    foreach ($g in (Get-DrivEnvGenerateList -Cfg $Config))
    {
        if (-not $once.ContainsKey($g)) { $once[$g] = $true; $ids += $g }
    }
    if ($ids.Count -eq 0) { $ids = @($null) }        # a 2.x configuration: check it exactly as it stands

    $subsystems = @{}
    $triplets   = @{}

    foreach ($id in $ids)
    {
        $label = if ($null -eq $id) { "" } else { " (toolchain '$id')" }

        $resolved = $null
        try   { $resolved = if ($null -eq $id) { $Config } else { Resolve-DrivEnvToolchain -Cfg $Config -Id $id } }
        catch { continue }                           # malformed beyond projection; the type walk said so already
        if ($null -eq $resolved) { continue }

        $target = $resolved.msys2.target
        if ($null -eq $target)
        {
            $Problems.Add("msys2.target: required${label}")
        }
        elseif ([string]::IsNullOrWhiteSpace($target.subsystem) -and [string]::IsNullOrWhiteSpace($target.profile))
        {
            $Problems.Add("msys2.target: one of 'subsystem' or the legacy 'profile' is required${label}")
        }
        else
        {
            # Compare the key, not the spelling: 'subsystem: ucrt64' and legacy 'profile: ucrt' are the same toolchain.
            $key = Get-DrivEnvToolchainKey -Cfg $resolved

            # A blank key, or a field of the wrong type, is already reported by the type walk; do not add a second message.
            $keyTarget = $resolved.msys2.target
            $keyTyped  = $true
            foreach ($kf in @('subsystem', 'profile'))
            {
                $kv = $keyTarget.$kf
                if (($null -ne $kv) -and ($kv -isnot [string])) { $keyTyped = $false }
            }
            if ($keyTyped -and -not [string]::IsNullOrWhiteSpace($key))
            {
                # The key names files: a safe path segment, for every configuration shape.
                if ($key -cnotmatch '^[a-z0-9][a-z0-9_.\-]*$')
                {
                    $Problems.Add("msys2.target: the toolchain key '$key' must start with a letter or digit and hold only letters, digits, '_', '.' or '-' -- it names this toolchain's files${label}")
                }

                if ($null -ne $id)
                {
                    if ($subsystems.ContainsKey($key)) { $Problems.Add("toolchains.${id}.msys2.target: resolves to the same MSYS2 prefix '$key' as toolchain '$($subsystems[$key])' -- two toolchains cannot share one") }
                    else { $subsystems[$key] = $id }
                }
            }
        }

        # NULL AND EMPTY ARE DIFFERENT QUESTIONS AND @() ANSWERS NEITHER. @($null).Count is 1, not 0, so testing
        # the wrapped list alone reported an absent 'msys2.packages' as present-and-fine -- the exact shape of
        # silent under-doing this file exists to refuse, and a regression the moment 'required' left the schema.
        $pkgs = $resolved.msys2.packages
        if (($null -eq $pkgs) -or (@($pkgs | Where-Object { $null -ne $_ }).Count -eq 0))
        {
            $Problems.Add("msys2.packages: required and must not be empty${label}")
        }

        # Only the ABSENT target is reported here. When vcpkg.target exists the schema's own required+notEmpty on
        # 'triplet' has already spoken, and repeating it would give one mistake two messages in two voices.
        $vcpkgTarget = $resolved.vcpkg.target
        if ($null -eq $vcpkgTarget)
        {
            $Problems.Add("vcpkg.target: required${label}")
        }
        else
        {
            # A triplet of the wrong type has had its message from the type walk; stringified here it would earn a
            # second one, quoting 'a b' or '@{x=1}'.
            $triplet = if ($vcpkgTarget.triplet -is [string]) { $vcpkgTarget.triplet } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($triplet))
            {
                # A triplet is a path segment too, starting with a letter or digit ('..' would be the drive root).
                if ($triplet.Trim() -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$')
                {
                    $Problems.Add("vcpkg.target.triplet: '$triplet' must start with a letter or digit and hold only letters, digits, '.', '_' or '-' -- it names vcpkg/installed/<triplet> and the build trees${label}")
                }

                if ($null -ne $id)
                {
                    $key = $triplet.Trim().ToLowerInvariant()
                    if ($triplets.ContainsKey($key)) { $Problems.Add("toolchains.${id}.vcpkg.target.triplet: '$triplet' collides with toolchain '$($triplets[$key])' -- two toolchains cannot share one installed tree") }
                    else { $triplets[$key] = $id }
                }
            }
        }

        # One package, one pin: arrays append, so a profile re-stating a shared package would add a second entry.
        # Same name AND repo ('make' from mingw and from msys are two packages).
        $byKey = @{}
        $j = 0
        foreach ($p in @($resolved.msys2.packages))
        {
            $j++
            if ($null -eq $p) { continue }

            $repo = "$($p.repo)".Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($repo)) { $repo = 'mingw' }     # step 2's own default
            $key = "$("$($p.name)".Trim().ToLowerInvariant())|$repo"

            if ($byKey.ContainsKey($key)) { $Problems.Add("msys2.packages: '$($p.name)' from repo '$repo' appears twice${label} -- a profile ADDS to the shared list, it does not replace an entry in it") }
            else { $byKey[$key] = $j }
        }
    }

    # ----------------------------------------------------------------
    # WHAT TOOLCHAINS SHARE
    # ----------------------------------------------------------------
    # Shared whatever the configuration says: msys-repo packages (one /usr) and per-package triplet overrides (one
    # installed tree). Checked across DECLARED toolchains; silent with fewer than two.
    $declaredIds = @()
    if ($hasToolchains -and (Test-DrivEnvIsObject $Config.toolchains))
    {
        $declaredIds = @($Config.toolchains.PSObject.Properties | ForEach-Object { $_.Name })
    }

    if ($declaredIds.Count -gt 1)
    {
        # One msys package, one pin, across toolchains: otherwise it is whatever the last toolchain installed.
        $msysSpec = @{}
        foreach ($did in $declaredIds)
        {
            $resolved = $null
            try   { $resolved = Resolve-DrivEnvToolchain -Cfg $Config -Id $did }
            catch { continue }
            if ($null -eq $resolved) { continue }

            foreach ($p in @($resolved.msys2.packages | Where-Object { $null -ne $_ }))
            {
                if ("$($p.repo)".Trim().ToLowerInvariant() -ne 'msys') { continue }
                $n = "$($p.name)".Trim().ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace($n)) { continue }

                $mode = "$($p.mode)".Trim().ToLowerInvariant()
                $spec = if ($mode -eq 'pinned') { "pinned " + "$($p.version)".Trim() } else { $mode }

                if (-not $msysSpec.ContainsKey($n)) { $msysSpec[$n] = @{ Spec = $spec; Id = $did }; continue }
                if ($msysSpec[$n].Spec -ne $spec)
                {
                    $Problems.Add(("toolchains.{0}.msys2.packages: '{1}' from repo 'msys' is '{2}' here and '{3}' in toolchain '{4}' -- msys packages land in the one /usr every toolchain shares, so they must agree; a package every toolchain needs belongs in the shared msys2.packages" -f
                                   $did, $p.name, $spec, $msysSpec[$n].Spec, $msysSpec[$n].Id))
                }
            }
        }

        # No per-package triplet override with two toolchains: the shared tree would be built by the first toolchain's
        # compiler and passed for the second.
        if ($Config.vcpkg -and $Config.vcpkg.packages)
        {
            $i = 0
            foreach ($p in @($Config.vcpkg.packages))
            {
                $path = "vcpkg.packages[$i]"
                $i++
                if (-not (Test-DrivEnvIsObject $p)) { continue }
                if (@($p.PSObject.Properties | ForEach-Object { $_.Name }) -notcontains 'triplet') { continue }
                if (($p.triplet -isnot [string]) -or [string]::IsNullOrWhiteSpace($p.triplet)) { continue }

                $Problems.Add(("{0}.triplet: '{1}' is a per-package override, refused in a configuration declaring more than one toolchain -- vcpkg.packages is shared, so every toolchain would install '{2}' into the one installed/{1} tree, and the second would take the first one's build" -f
                               $path, $p.triplet.Trim(), $p.name))
            }
        }
    }

    # ----------------------------------------------------------------
    # THE DRIVE'S QT CREATOR (step 7)
    # ----------------------------------------------------------------
    # What each source needs, beyond the schema's types and closed set.
    $qt = $null
    if ((@($Config.PSObject.Properties.Name) -contains 'ide_integration') -and (Test-DrivEnvIsObject $Config.ide_integration) -and
        (Test-DrivEnvIsObject $Config.ide_integration.qtcreator))
    {
        $qt = $Config.ide_integration.qtcreator
    }
    if (($null -ne $qt) -and ($qt.source -is [string]))
    {
        $qsource = $qt.source.Trim().ToLowerInvariant()
        $qnames  = @($qt.PSObject.Properties | ForEach-Object { $_.Name })

        if ($qsource -eq 'msys2')
        {
            # THE PACKAGE COMES WITH A TOOLCHAIN (owner decision): the profile with this subsystem lists qt-creator in
            # its msys2.packages, so step 2 installs it, pins it and protects it like any other package. A subsystem no
            # declared toolchain has would leave step 7 looking for a Qt Creator nothing installs.
            $sub = if ($qt.subsystem -is [string]) { $qt.subsystem.Trim().ToLowerInvariant() } else { '' }
            if ([string]::IsNullOrWhiteSpace($sub))
            {
                $Problems.Add("ide_integration.qtcreator.subsystem: required when source is 'msys2' -- the subsystem whose qt-creator package to use")
            }
            else
            {
                $holder = $null
                foreach ($t in (Get-DrivEnvDeclaredTargets -Cfg $Config))
                {
                    if ($t.Key -ine $sub) { continue }
                    $holder = $t
                    $has = @($t.Cfg.msys2.packages | Where-Object { ($null -ne $_) -and ("$($_.name)".Trim() -ieq 'qt-creator') -and ("$($_.repo)".Trim() -ne 'msys') }).Count -gt 0
                    if (-not $has)
                    {
                        $where = if ($t.Id) { "toolchains.$($t.Id).msys2.packages" } else { "msys2.packages" }
                        $Problems.Add("ide_integration.qtcreator: source 'msys2' with subsystem '$sub' needs 'qt-creator' in $where -- step 2 installs the Qt Creator step 7 registers kits for")
                    }
                }
                if ($null -eq $holder)
                {
                    $Problems.Add("ide_integration.qtcreator.subsystem: '$sub' is not the subsystem of any declared toolchain -- its qt-creator package is installed by that toolchain's step 2")
                }
            }
            foreach ($k in @('path', 'sdktool'))
            {
                if ($qnames -contains $k) { $Problems.Add("ide_integration.qtcreator.${k}: only for source 'external'; with 'msys2' Qt Creator and sdktool are the package's") }
            }
        }
        elseif ($qsource -eq 'external')
        {
            if (($qnames -notcontains 'path') -or ($qt.path -isnot [string]) -or [string]::IsNullOrWhiteSpace($qt.path))
            {
                $Problems.Add("ide_integration.qtcreator.path: required when source is 'external' -- the installed qtcreator.exe")
            }
            elseif (-not [System.IO.Path]::IsPathRooted($qt.path.Trim()))
            {
                $Problems.Add("ide_integration.qtcreator.path: '$($qt.path)' must be an absolute path to qtcreator.exe")
            }
            if (($qnames -contains 'sdktool') -and ($qt.sdktool -is [string]) -and -not [System.IO.Path]::IsPathRooted($qt.sdktool.Trim()))
            {
                $Problems.Add("ide_integration.qtcreator.sdktool: '$($qt.sdktool)' must be an absolute path to sdktool.exe")
            }
            if ($qnames -contains 'subsystem') { $Problems.Add("ide_integration.qtcreator.subsystem: only for source 'msys2'") }
        }
        if (($qsource -eq 'none') -and ($qt.register_in_user_settings -eq $true))
        {
            $Problems.Add("ide_integration.qtcreator.register_in_user_settings: needs a Qt Creator integration -- step 7 makes the kits it registers, and with source 'none' it makes none")
        }
        if (($qnames -contains 'user_settings_path') -and ($qt.user_settings_path -is [string]))
        {
            if ($qt.register_in_user_settings -ne $true)
            {
                $Problems.Add("ide_integration.qtcreator.user_settings_path: only with register_in_user_settings: true -- it is where those kits go")
            }
            elseif (-not [System.IO.Path]::IsPathRooted([Environment]::ExpandEnvironmentVariables($qt.user_settings_path.Trim())))
            {
                $Problems.Add("ide_integration.qtcreator.user_settings_path: '$($qt.user_settings_path)' must be absolute once %VARIABLES% are expanded, e.g. %APPDATA%/QtProject")
            }
        }
    }
}

# --------------------------------------------------------------------
# ENTRY POINT
# --------------------------------------------------------------------

function Test-DrivEnvConfig
{
    # @brief Validates a parsed configuration. Returns every problem found (not just the first), empty when good.
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
