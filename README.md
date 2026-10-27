<a name="readme-top"></a>

[![MIT License][license-shield]][license-url]
[![Platform][platform-shield]][platform-url]
[![PowerShell][powershell-shield]][powershell-url]
[![Toolchain][toolchain-shield]][toolchain-url]
[![vcpkg][vcpkg-shield]][vcpkg-url]

<h1 align="center">Windows Dev Drive Environment Setup</h1>

<p align="center">
  <b>Reproducible C++ development environments on a Windows 11 Dev Drive, from one JSON file.</b><br>
  Pinned MSYS2 clang/GCC toolchains, vcpkg with overlay ports, IDE integration and a verification step that proves
  the result works. Windows 10 is supported too, on a regular VHDX.
  <br><br>
  <a href="#quick-start"><strong>Quick start »</strong></a>
  ·
  <a href="#quick-guide">Quick guide</a>
  ·
  <a href="#roadmap">Roadmap</a>
</p>

<details>
  <summary>Table of contents</summary>
  <ol>
    <li><a href="#about">About</a></li>
    <li><a href="#quick-start">Quick start</a></li>
    <li><a href="#quick-guide">Quick guide</a></li>
    <li><a href="#running-the-generator">Running the generator</a></li>
    <li><a href="#repository-layout">Repository layout</a></li>
    <li><a href="#the-public-contract">The public contract</a></li>
    <li><a href="#several-toolchains-on-one-drive">Several toolchains on one drive</a></li>
    <li><a href="#qt-creator">Qt Creator</a></li>
    <li><a href="#configuration">Configuration</a></li>
    <li><a href="#verification">Verification</a></li>
    <li><a href="#overlay-ports">Overlay ports</a></li>
    <li><a href="#logs-and-records">Logs and records</a></li>
    <li><a href="#drive-maintenance">Drive maintenance</a></li>
    <li><a href="#moving-a-drive-to-another-pc">Moving a drive to another PC</a></li>
    <li><a href="#not-installed-by-the-generator">Not installed by the generator</a></li>
    <li><a href="#roadmap">Roadmap</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
    <li><a href="#acknowledgments">Acknowledgments</a></li>
  </ol>
</details>

---

## About

On Linux, a container image pins a toolchain, its libraries and the environment in one file. On Windows there is no
simple, standard equivalent for native desktop C++ with GUI toolkits, hardware SDKs and vendor drivers: the usual
answer is a document of what to install, and no two machines end up alike.

**This project makes the environment a drive.** One JSON file names the toolchains and their pinned package versions, the
vcpkg baseline commit, the packages and their features, the variables and the folders. Seven PowerShell steps turn
it into a virtual disk — a Windows 11 **Dev Drive** (ReFS) where available, or a regular VHDX on Windows 10 — that carries
everything a build needs. It mounts under a letter, is entered through its own launcher, and can be rebuilt from the
same JSON months later.

- **Nothing system-wide.** The machine's `PATH` is never touched; several drives can live side by side.
- **Several toolchains per drive.** A clang and a GCC toolchain share one MSYS2, one vcpkg clone and one workspace;
  the same checkout builds with either by opening the other launcher.
- **Verified, not assumed.** The last core step loads every library, runs every tool and checks every GStreamer
  element, because the failures that matter are silent: a DLL that built and cannot load, a plugin that skipped
  itself.
- **Qt Creator ready.** One kit per toolchain, optionally added to your own Qt Creator as well.

What a generated drive holds:

| Path | Contents |
| --- | --- |
| `msys64/` | MSYS2 with each toolchain, packages pinned to exact versions |
| `vcpkg/` | vcpkg at a pinned baseline, with overlay ports and triplets |
| `env/` | One environment file and launcher set per toolchain, and the drive's Qt Creator settings |
| `workspace/`, `deploys/` | Your sources and installed artefacts |
| `bt/` | vcpkg build trees, and `bt/<triplet>/` for your own builds |
| `testing/` | Hand-run checks for the troublesome libraries ([samples](drive/samples/README.md)) |
| `installation/` | What this drive is: package inventories, baseline, verification reports |
| `logs/` | Every setup step's log, and the logs of every port that failed |

Outside the drive it leaves only: desktop shortcuts (`create_desktop_shortcuts`), a startup task that mounts the
drive (`automount_at_startup`), Microsoft Defender exclusions (the VHDX folder, and the drive letter on NTFS; a Dev
Drive is trusted instead) and, if you ask, kits in your own Qt Creator.
[`tools/Remove-DevDrive.ps1`](#drive-maintenance) removes all of them.

### Where this is used

It generates the development environments of the **Degoras Project** systems that operate the Satellite Laser
Ranging station at the **Real Instituto y Observatorio de la Armada (ROA)**, San Fernando, Spain: real-time control,
hardware SDKs and a heavy C++ dependency stack.

### Built with

[PowerShell](https://learn.microsoft.com/powershell/) · [MSYS2](https://www.msys2.org/) ·
[vcpkg](https://vcpkg.io/) · [Qt Creator](https://www.qt.io/product/development-tools)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Quick start

**Requirements:** Windows 10 or 11 (a Dev Drive needs Windows 11 22H2, build 22621.2338, or later), PowerShell 5.1+,
administrator rights for step 1 only (it asks for them), and `vhd_size_gb` free on the volume holding `vhd_root`.
Nothing else, not even Git: everything is put on the drive by the scripts.

1. Clone and create your configuration from the example:

   ```powershell
   git clone https://github.com/DegorasProjectTeam/DrivEnv-Win.git
   cd DrivEnv-Win
   copy config\drivenv-cfg_example.json config\drivenv-cfg.json
   ```

2. Edit `config\drivenv-cfg.json`: at least `dev_drive_letter`, `dev_drive_label` and `dev_env_name`, and the
   packages you need.

3. From an **ordinary** PowerShell (step 1 asks for administrator rights itself), allow scripts for this window and
   generate:

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\Generate-DrivEnv.ps1 -ValidateOnly     # check the configuration, change nothing
   .\Generate-DrivEnv.ps1                   # the whole procedure
   ```

   It runs the seven steps in order, stops at the first failure and prints the command that resumes it.

4. Open the environment from the desktop shortcut `<envname> <subsystem> Environment`, or from
   `<drive>:\env\launcher\<envname>_<subsystem>_env_launcher.bat`.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Quick guide

| I want to… | Do this |
| --- | --- |
| Work in a toolchain | Open its launcher; the window title and prompt say which toolchain it is |
| Build with the other toolchain | Open the other launcher; builds land in `bt/<triplet>/`, one tree per toolchain |
| Use Qt Creator | Open `<envname> <subsystem> Qt Creator` and pick the kit of that toolchain |
| Resume after a failure | `.\Generate-DrivEnv.ps1 -From <step>` — the failure message prints the exact line |
| Rebuild one toolchain only | `.\Generate-DrivEnv.ps1 -From 3 -To 5 -Toolchain ucrt` |
| Check a drive | `.\Generate-DrivEnv.ps1 -From 5 -To 5` |
| Refresh the Qt Creator kits | `.\Generate-DrivEnv.ps1 -From 7` |
| See the plan without running it | `.\Generate-DrivEnv.ps1 -DryRun` |
| Take a drive's kits out of my Qt Creator | `.\tools\Restore-QtCreatorSettings.ps1 -RemoveDrive D` |
| Clean orphaned startup mount tasks | `.\tools\Manage-MountTasks.ps1` |
| Delete a drive and everything it left | `.\tools\Remove-DevDrive.ps1 -ConfigFile drivenv-cfg.json -WhatIf`, then without `-WhatIf` |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Running the generator

| Switch | What it does |
| --- | --- |
| `-ConfigFile <name>` | Forwarded to every step. A bare name resolves against `config/`; default `drivenv-cfg.json` |
| `-From <n>`, `-To <n>`, `-Skip 5,6` | Run part of the procedure |
| `-Toolchain <id>` | With several toolchains, run steps 2 to 5 for these only |
| `-DryRun` | Print the plan — every step and every toolchain — and launch nothing |
| `-ValidateOnly` | Check the configuration and change nothing |

Start it from an **ordinary** PowerShell. Only step 1 (creating and mounting the disk) needs administrator rights,
and it asks for them itself, with a UAC prompt and a window of its own; the other steps run as you, so the drive's
files are yours. From an elevated terminal everything runs elevated, and at the end the drive is handed to
`environment.owner` (a minute or two for a full drive). Any step can also run on its own, with the same
`-ConfigFile` (steps 2 to 5 also take `-Toolchain <id>` when the configuration has a `generate` list):

| Step | |
| --- | --- |
| `1-Setup_DevDrive.ps1` | Create and mount the drive, lay out the folders, startup task, Defender (an exclusion on NTFS, trust on a Dev Drive) |
| `2-Setup_MSYS2.ps1` | MSYS2 and the toolchain; the toolchain's env file, launchers and shortcuts |
| `3-Clone_VCPKG.ps1` | vcpkg at the baseline, overlay triplets checked, env file completed |
| `4-Deps_VCPKG.ps1` | The configured packages, with retries; the installation inventory |
| `5-Verify_Env.ps1` | Prove the result works |
| `6-Clone_Repos.ps1` | Clone the configured projects into the workspace (optional) |
| `7-Setup_IDE.ps1` | One Qt Creator, a kit and a launcher per toolchain (optional) |

Step 1 refuses to start unless the ground is clear — letter free, no VHDX already at `vhd_root`, enough space — and
checks it all before creating anything.

## Repository layout

| Path | What lives there |
| --- | --- |
| `Generate-DrivEnv.ps1` | The entry point |
| `config/` | Your configuration (`drivenv-cfg.json`, not tracked) and documented copies (example, full reference, Degoras) |
| `scripts/` | The seven steps and the shared modules |
| `drive/launchers/` | Launcher templates copied onto the drive |
| `drive/samples/` | Hand-run checks, copied to `<drive>:\testing` |
| `vcpkg_overlays/` | The generator's triplets, and overlay port sets a configuration may pick (`degoras/`) ([README](vcpkg_overlays/README.md)) |
| `tools/` | `Export-DevDrive.ps1`, `Import-DevDrive.ps1`, `Manage-MountTasks.ps1`, `Remove-DevDrive.ps1`, `Restore-QtCreatorSettings.ps1` |
| `tests/` | The generator's own test suite (`tests\Test-DrivEnvConfig.ps1`); `tests\Sandbox-Portability.ps1` (elevated) exports and imports a throwaway drive |
| `cache/`, `logs/` | MSYS2 download cache and run logs (not tracked) |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## The public contract

Each toolchain's `<drive>:\env\<envname>_<subsystem>_env_variables.env` holds the variables a project may depend
on:

| Variable | Meaning |
| --- | --- |
| `DEVSYSTEM_TOOLCHAIN_ROOT` | The prefix holding the compilers, `cmake`, `ninja` and `gdb` |
| `DEVSYSTEM_TOOLCHAIN` | The compiler family: exactly `gcc` or `clang` (CLANG64 ships `gcc.exe` as a copy of clang, so it cannot be guessed) |
| `DEVSYSTEM_TOOLCHAIN_ID` | The subsystem slug for paths: `ucrt64`, `clang64`, … |
| `DEVSYSTEM_BUILDTREES` | Where your builds go: `<drive>/<buildtrees_root>/<triplet>` |
| `DEVSYSTEM_DEPLOYS`, `DEVSYSTEM_WORKSPACE` | Installs and sources, shared by every toolchain |
| `VCPKG_ROOT`, `VCPKG_DEFAULT_TRIPLET` | The dependency prefix and its triplet |

Everything else in the file (`MSYS2_*`, `BASE_PATH`, `DEVDRIVE_*`, `VCPKG_OVERLAY_*`, `GST_*`) is internal.

## Several toolchains on one drive

```json
"toolchains": {
  "clang": { "msys2": { "target": { "subsystem": "clang64" }, "packages": [ ... ] },
             "vcpkg": { "target": { "triplet": "x64-mingw-clang-dynamic-release" } } },
  "ucrt":  { "msys2": { "target": { "subsystem": "ucrt64" },  "packages": [ ... ] },
             "vcpkg": { "target": { "triplet": "x64-mingw-ucrt-dynamic-release" } } }
},
"generate": ["clang", "ucrt"]
```

Each profile is layered onto the shared configuration (objects merge, arrays append). The runner does step 1, then
step 2 for every toolchain, then steps 3 to 5 toolchain by toolchain, then steps 6 and 7. A configuration without
`toolchains` is a single toolchain.

**Per toolchain**, always named after its subsystem: the environment file, the launchers and shortcuts, the build
trees (`<buildtrees_root>\<triplet>\`), the records (`*_<subsystem>.txt`) and the logs.

**Shared**, with the rules that keep it safe:

- **One MSYS2.** Every toolchain's installed pins go into `pacman.conf`'s `IgnorePkg` before step 2 upgrades, so
  building one toolchain never upgrades the other's compiler. A package from the `msys` repo must be pinned the same
  way in every profile.
- **One vcpkg clone and baseline.** With `baseline_mode: latest`, the first toolchain built fixes the commit for the
  drive. To move a drive to a newer vcpkg, generate a new drive (or set `fixed`, remove the ports per toolchain and
  re-run steps 3 and 4).
- **One build-trees root.** Step 4's cleanup removes only its own triplet's trees.
- **No per-package triplet override** with more than one toolchain: `vcpkg.packages` is shared.

> ⚠️ **A drive generated before 3.0.0 is not migrated**; step 2 refuses it. Generate a new one.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Qt Creator

Step 7 gives the drive **one** Qt Creator with one settings folder and **one kit per toolchain**, so a project keeps
a single `.user` file and builds each kit into its own directory.

```json
"ide_integration": { "qtcreator": { "source": "msys2", "subsystem": "ucrt64" } }
```

| `source` | Where Qt Creator comes from |
| --- | --- |
| `msys2` | The `qt-creator` package of `subsystem`, listed in that toolchain's `msys2.packages` |
| `external` | An installed Qt Creator: `path` to `qtcreator.exe`, and `sdktool` if it is not beside it or in `<Qt>\Tools\sdktool\bin` |
| `none` | No integration (the same as leaving `ide_integration` out) |

Each kit is what its toolchain's launcher gives a shell: the compilers, `gdb`, `cmake` and Ninja; the vcpkg toolchain
file, triplet and overlay triplets; the toolchain's own vcpkg Qt (with `CMAKE_PREFIX_PATH`); and the environment
file's variables, with `PATH` in the launcher's order so programs load vcpkg's DLLs before MSYS2's.

**Open Qt Creator from the drive's launchers** (`<envname>_<subsystem>_qtcreator`, one per toolchain). They load the
toolchain's environment exactly as its shell does and pass the drive's settings to Qt Creator. Build and run each
kit from its own toolchain's launcher: a kit prefixes `PATH`, it does not replace it.

**Your own Qt Creator too, if you ask** — `"register_in_user_settings": true`, and optionally `"user_settings_path"`
(default `%APPDATA%/QtProject`). Step 7 adds the drive's kits there as manual kits named `<kit> (<drive>:)`, and
leaves everything else as it was. It is one transaction with backups (`<file>.drivenv-<timestamp>.bak`), skipped
while that Qt Creator runs or if it has never run. Those kits carry **no Qt version** (the vcpkg `qmake` cannot run
outside the drive's environment; projects still find Qt through the vcpkg toolchain file), and reuse a compiler you
already registered by hand rather than adding a duplicate that Qt Creator would delete.

To undo it, with your Qt Creator closed:

```powershell
.\tools\Restore-QtCreatorSettings.ps1                  # list backups and the drives with kits there
.\tools\Restore-QtCreatorSettings.ps1 -RemoveDrive D   # take drive D:'s kits out, keep everything else
.\tools\Restore-QtCreatorSettings.ps1 -Restore latest  # put the newest backup set back exactly
```

Re-run step 7 after adding a toolchain or installing ports with tools: a kit is a copy of the environment file as it
was when step 7 ran.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Configuration

`config/drivenv-cfg_example.json` is a drive with a clang and a GCC toolchain; `config/drivenv-cfg_full-reference.json`
spells out the optional keys. Every step validates the file before using it.

> ⚠️ **An unknown key is an error, not a default.** A typo such as `check_toolz` would otherwise silently check
> nothing; the validator refuses the file and suggests the nearest key.

### `metadata`

Optional: what this configuration is. Every step prints it in its log, and step 4 records it on the drive
(`<drive>:\installation\configuration_<subsystem>.txt`), so a drive tells which configuration built it.

```json
"metadata": {
    "name": "Degoras dual", "version": "1.0.0", "date": "2026-10-20", "author": "Your Name",
    "target_os": "Windows 10 / 11", "description": "clang64 + ucrt64 drive",
    "notes": ["vcpkg baseline 3cd21e48", "LLVM 23.1.3"]
}
```

`date` is `YYYY-MM-DD`; every key is optional. `target_os` is free text, for people: the Windows this configuration
is meant for. It is shown in the logs and by the import; nothing is checked against it.

### `git`

Optional: the identity of the drive's git, written by step 2 into `<drive>:\msys64\etc\gitconfig` together with
`useConfigOnly`, so a commit made on a machine with no git identity never gets an invented `<user>@<host>` one. Your
`~/.gitconfig` and each repository's own configuration still take precedence.

```json
"git": { "user_name": "Your Name", "user_email": "you@example.com" }
```

### `environment`

| Key | Meaning |
| --- | --- |
| `dev_drive_label`, `dev_drive_letter` | Volume label and mount letter |
| `dev_env_name` | Prefix of the generated files and launchers |
| `vhd_root`, `vhd_size_gb`, `vhd_fixed` | Where the virtual disk lives, its size, fixed or dynamic |
| `use_dev_drive` | Format as a Windows Dev Drive (ReFS) instead of NTFS |
| `force_diskpart` | Use `diskpart` rather than the storage cmdlets |
| `custom_variables` | Extra `KEY=VALUE` entries; `${REFERENCES}` to earlier variables are expanded |
| `custom_path_entries` | Extra `PATH` components, in order |
| `custom_folders` | Extra folders; one containing `${DEVSYSTEM_TOOLCHAIN_ID}` is created per toolchain |
| `append_windows_system_path` | Also append the generating shell's `PATH`. Default `false` |
| `create_desktop_shortcuts`, `automount_at_startup` | Default `true` |
| `owner` | Who owns the drive's files: `current` (default: whoever runs the generator, you even from an elevated terminal), `administrators`, or an account name |
| `proxy_url` | Proxy for the downloads, or empty |
| `install_testing_material` | Copy `drive/samples` to `<drive>:\testing`. Default `true` |
| `verification` | What step 5 checks: packages, library loads, tools, commands, GStreamer elements |

> ⚠️ A `${REFERENCE}` that nothing defines expands to empty, and an empty `PATH` component means "the current
> directory". Step 3 refuses such a configuration. A variable can only reference one defined before it.

### `msys2`

The installer, the subsystem and the packages, each pinned to an exact version or tracking latest. A pinned package
that does not install is an error at step 2. Built-in subsystems: `ucrt64`, `clang64`, `mingw64`, `clangarm64`,
`mingw32`, `clang32` (others need `repo_subpath` and `package_prefix`).

### `vcpkg`

The repository, the baseline commit, the target triplet, the overlay layers and the packages with their features.

| Key | Meaning |
| --- | --- |
| `install_schedule` | One entry per attempt, e.g. `[ {}, { "concurrency": 8 }, { "concurrency": 1 } ]`: retries with fewer parallel jobs, since the failures worth retrying are resource-shaped. Also per package |
| `retry_delay_seconds` | Wait before a retry, times the attempt number. Default `0` |
| `cleanup.buildtrees` | `none` (default), `logs` or `all`: what step 4 removes after a successful run. Your own builds in `<triplet>/` are never touched |
| `cleanup.packages` | `true` removes `vcpkg\packages`, vcpkg's staging folder (recreated when a port is built). Its files are hardlinked into `installed`, so it frees names rather than space. Default `false` |
| `cleanup.downloads`, `cleanup.binary_cache` | `true` empties `vcpkg\downloads` (re-downloaded when needed) or the binary cache (reinstalling then means building again). Shared, so done by the last generated toolchain. Default `false` |
| `buildtrees_root` | Folder for build trees, default `bt`: short on purpose, because of the 260-character path limit |
| `overlay_root` | The overlay port set, e.g. `vcpkg_overlays/degoras`; absent, no overlay ports — see [Overlay ports](#overlay-ports) |
| `overlay_ports` | Overlay layers per triplet, folders of that set |

> ⚠️ Prefer explicit feature lists to blanket ones such as ffmpeg's `all-gpl`, which enables codecs that cannot work
> on these toolchains.

### `workspace`

Git repositories for step 6 to clone. Only the URL is required; a repository already present with the same origin is
left alone, one with a different origin is refused.

### `ide_integration`

Qt Creator only, for now: one kit per toolchain (compilers, debugger, CMake, Qt, the vcpkg toolchain file and the
environment), written with Qt Creator's `sdktool` — see [Qt Creator](#qt-creator). Other IDEs are not integrated;
open your projects in them from the environment launcher.

| Key under `qtcreator` | Meaning |
| --- | --- |
| `source` | `msys2`, `external` or `none`. Required |
| `subsystem` | With `msys2`: whose `qt-creator` package |
| `path`, `sdktool` | With `external`: absolute paths to `qtcreator.exe` and, if needed, `sdktool.exe` |
| `register_in_user_settings` | Also add the kits to your own Qt Creator. Default `false` |
| `user_settings_path` | Your Qt Creator's settings folder (holding `QtCreator.ini`). Default `%APPDATA%/QtProject` |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Verification

```powershell
.\scripts\5-Verify_Env.ps1 -Toolchain clang            # exits non-zero if anything is wrong
.\scripts\5-Verify_Env.ps1 -Toolchain clang -NoFail    # report only
```

Each package is checked under its triplet, and every tool and command must resolve inside this toolchain. The report
goes to `<drive>:\installation\verification_<subsystem>.txt`:

```
 packages   29 checked, 0 failed
 load      431 checked, 0 failed
 tools       6 checked, 0 failed
 commands    3 checked, 0 failed
 elements   29 checked, 0 failed
 patches     1 checked, 0 failed
```

Three states: **ok**, **failed** and **not checked** — a check that could not run is not a failure. The **load**
check earns its keep: each library is opened the way a consumer would, which catches missing dependencies that no
build reports. The **defender** check says how Microsoft Defender treats the drive (performance mode on a trusted
Dev Drive, the exclusion on NTFS); it costs speed, never correctness, so it is never a failure, and reading the
exclusion list or the Dev Drive trust needs an elevated run.

## Overlay ports

Some vcpkg ports do not build correctly on these toolchains as published. The fixes come in **sets**, each made for
one environment, and a configuration picks one with `vcpkg.overlay_root`; **none is required**, and without it every
package comes from the registry as published ([`vcpkg_overlays/README.md`](vcpkg_overlays/README.md)).

> **The one set here, `vcpkg_overlays/degoras/`,** is made for one environment: vcpkg baseline `3cd21e48`, the two
> MinGW dynamic-release triplets, Clang 23.1.3 (clang64) and GCC 16.2.0 (ucrt64), and the Degoras package set.
> Elsewhere it is untested and may be obsolete. Each port, why, and when to retire it:
> [Degoras overlay ports](vcpkg_overlays/degoras/README.md#where-they-apply).

Layers, folders of the set, are chosen per triplet:

```json
"overlay_root": "vcpkg_overlays/degoras",
"overlay_ports": [
  { "triplet": "x64-mingw-clang-dynamic-release", "layers": ["ports.clang", "ports"] },
  { "triplet": "*",                               "layers": ["ports"] }
]
```

The triplets in `vcpkg_overlays/triplets/` are the generator's own and every drive gets them (the static ones are
kept as a capability; nothing uses them). Step 3 verifies each against the `.sha256` beside it (line endings
normalised) and refuses a mismatch. If it fails, read the diff before regenerating the hash.

## Logs and records

Every step logs into `logs\` and copies the log to `<drive>:\logs\setup\`, so a drive carries the record of how it was
made. Failed ports keep one folder per attempt (`<drive>:\logs\vcpkg\<port>\attempt<n>_<subsystem>_<timestamp>\`),
because the first failure is usually the informative one.

Step 4 writes the inventory to `<drive>:\installation\`, one set per toolchain: `vcpkg_packages_<subsystem>.txt` and
`.json`, `msys2_packages_<subsystem>.txt`, `environment_<subsystem>.txt`, `configuration_<subsystem>.txt`,
`verification_<subsystem>.txt`, and the drive's `vcpkg_baseline.txt`. Step 4's log ends with a cleanup summary: what
each `vcpkg.cleanup` key removed, how much it freed, and what was kept and why.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Drive maintenance

The tools cover the common cases:

```powershell
.\tools\Manage-MountTasks.ps1                                       # list startup mount tasks; -Remove drops orphans
.\tools\Remove-DevDrive.ps1 -ConfigFile drivenv-cfg.json -WhatIf    # what deleting the drive would remove
.\tools\Remove-DevDrive.ps1 -ConfigFile drivenv-cfg.json            # elevates, asks twice, removes everything
```

By hand, from an elevated PowerShell (close everything using the drive first):

```powershell
Mount-DiskImage    -ImagePath "C:\DevDrives\DEV_EXAMPLE.vhdx"       # mount
Dismount-DiskImage -ImagePath "C:\DevDrives\DEV_EXAMPLE.vhdx"       # dismount
Remove-Item "C:\DevDrives\DEV_EXAMPLE.vhdx"                         # delete (after dismounting)
Get-DiskImage -ImagePath "C:\DevDrives\DEV_EXAMPLE.vhdx"            # attached? which disk number?
Get-VHD -Path "C:\DevDrives\DEV_EXAMPLE.vhdx" | Select Path, FileSize, Size
```

**Grow the disk.** `Resize-VHD` grows the disk, not the volume; then extend the partition to its supported maximum
(asking for the disk's full size fails with "not enough available capacity"):

```powershell
Resize-VHD -Path "C:\DevDrives\DEV_EXAMPLE.vhdx" -SizeBytes 120GB
$disk = (Get-DiskImage -ImagePath "C:\DevDrives\DEV_EXAMPLE.vhdx").Number
$part = (Get-Partition -DiskNumber $disk | Where-Object DriveLetter).PartitionNumber
Resize-Partition -DiskNumber $disk -PartitionNumber $part -Size (Get-PartitionSupportedSize -DiskNumber $disk -PartitionNumber $part).SizeMax
```

**Shrink a dynamic VHDX** after deleting data (a dynamic file only grows as data is written), or **convert** it:

```powershell
Optimize-Volume -DriveLetter X -ReTrim                               # inside the drive first
Optimize-VHD -Path "C:\DevDrives\DEV_EXAMPLE.vhdx" -Mode Full        # dismounted or read-only
Convert-VHD -Path "C:\DevDrives\DEV_EXAMPLE.vhdx" -DestinationPath "C:\DevDrives\DEV_EXAMPLE_fixed.vhdx" -VHDType Fixed
```

`Resize-VHD`, `Optimize-VHD` and `Convert-VHD` come with the Hyper-V PowerShell module.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Moving a drive to another PC

`tools\Export-DevDrive.ps1` packs a drive for another PC, and the package carries its own importer: the other PC
needs nothing installed. Both run elevated (they relaunch themselves): Windows lets only administrators create and
attach virtual disks.

**Export.** The drive is only read. It is copied into a new dynamic VHDX inside the package, leaving out what vcpkg
regenerates:

```powershell
.\tools\Export-DevDrive.ps1 -ConfigFile drivenv-cfg.json -Diagnose                    # sizes per category; writes nothing
.\tools\Export-DevDrive.ps1 -ConfigFile drivenv-cfg.json -Destination E:\exports -Full -Archive
```

| Option | Effect |
| --- | --- |
| (always) | Left out: `vcpkg\packages` (hardlinks of `installed`), port build trees, `detect_compiler`, `tmp` |
| `-Full` | Also left out: vcpkg downloads, your build trees (`bt\<triplet>`), logs of failed ports, the binary cache. `-Exclude` picks some |
| `-Compress` | The VHDX compressed with zstd (measured: 10.4 GB to 3.1 GB in 14 s) |
| `-Archive` | The package as one `.zip`, stored, not deflated; implies `-Compress` |
| `-RemoveProxy` | The copy without `environment.proxy_url`, for a PC on another network |

Without options it asks. The package holds the VHDX, `manifest.json` (hashes, toolchains, what was left out), the logs
and `Import-DevDrive.cmd`; the drive carries the generator and its configuration in `<drive>:\env\generator`.

**Import.** On the other PC, extract the `.zip` and double-click `Import-DevDrive.cmd`
(or `Import-DevDrive.ps1 -Destination <folder> -Mode Image|DevDrive -Force`). It checks the SHA-256, then:

- **Dev Drive** (Windows 11 22H2, build 22621.2338, or later; offered there): a new Dev Drive VHDX with the files
  copied into it, trusted, so Defender scans it in performance mode.
- **Image** (Windows 10, or by choice): the exported VHDX as it is (NTFS), with a Defender exclusion as step 1 adds.

Then it registers the startup mount task (it asks), hands the git repositories to the importing user (git refuses
repositories owned by another account), points the embedded configuration at the new VHDX, and validates with step
5; step 7 (Qt Creator kits for this user) on request. The record goes to `<drive>:\installation\import_<stamp>.log`;
exit code 2 means imported, but step 5 reported problems.

**The drive letter must be free.** Paths inside the drive name it, including paths compiled into some DLLs (OpenSSL,
gettext), so a drive is never moved to another letter. If the letter is taken, the import says what holds it and
stops before writing anything: free it (Disk Management > Change Drive Letter and Paths) and run it again.

## Not installed by the generator

The generator builds what lives on the drive: the MSYS2 toolchains, the vcpkg packages and the Qt Creator kits.
Anything that belongs to Windows or installs into it is yours to install, on every PC (it does not travel with an
exported drive either). For example:

- **Codecs and OS components**: the Microsoft HEVC Video Extension (Microsoft Store), where Media Foundation's H.265
  encoder and decoder (`mfh265enc` and friends) come from.
- **Drivers**: the NVIDIA display driver for `nvcodec` (it needs `nvcuda.dll`, not the CUDA toolkit).
- **Other compilers and SDKs**: MSVC and Visual Studio, the Windows SDK, the CUDA toolkit.
- **Other IDEs and editors**: Visual Studio, VS Code, CLion and the like.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Roadmap

- [x] Several toolchains per drive (clang64 + ucrt64)
- [x] Qt Creator kits per toolchain, optionally in your own Qt Creator
- [x] Tools to restore Qt Creator settings and remove a drive
- [x] Export a drive to another PC and import it there, as a Dev Drive on Windows 11
- [ ] Rebuild mode for another PC: the package carries the recipe and the caches (vcpkg binary cache, MSYS2
      packages, source archives) and the drive is generated there, at any letter and fully offline, as the image mode is
- [ ] Benchmark script: the drive against `C:` for small-file I/O and a real vcpkg/CMake build
- [x] Defender check in step 5: Dev Drive trust and performance mode, or the NTFS exclusion, in the report
- [ ] vcpkg asset caching (`X_VCPKG_ASSET_SOURCES`) on a network share, so a drive rebuilds when upstream URLs
      disappear, and offline
- [ ] MSVC toolchain
- [ ] CUDA

See the [open issues][issues-url] for proposals and known problems.

## License

Distributed under the MIT License. See [`LICENSE`](LICENSE).

## Contact

Ángel Vera Herrera ([@AngelVeraHerrera](https://github.com/AngelVeraHerrera)) — [avera@roa.es](mailto:avera@roa.es)

Project link: [https://github.com/DegorasProjectTeam/DrivEnv-Win][repo-url]

### Collaborators

**Degoras Project Team** — Real Instituto y Observatorio de la Armada (ROA)

- Jesús Relinque Madroñal ([@jrelinquem](https://github.com/jrelinquem))
- David Abuín Sánchez ([@davidabuinESI](https://github.com/davidabuinESI))

## Acknowledgments

- [Real Instituto y Observatorio de la Armada (ROA)](https://armada.defensa.gob.es/ArmadaPortal/page/Portal/ArmadaEspannola/cienciaobservatorio/prefLang-es/)
- [MSYS2](https://www.msys2.org/) · [vcpkg](https://vcpkg.io/) · [Qt](https://www.qt.io/) · [Shields.io](https://shields.io/)
- [Best-README-Template](https://github.com/othneildrew/Best-README-Template)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

[license-shield]: https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge
[license-url]: https://opensource.org/licenses/MIT
[platform-shield]: https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?style=for-the-badge
[platform-url]: #quick-start
[powershell-shield]: https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=for-the-badge&logo=powershell&logoColor=white
[powershell-url]: #quick-start
[toolchain-shield]: https://img.shields.io/badge/toolchain-MSYS2%20clang%20%7C%20gcc-orange?style=for-the-badge
[toolchain-url]: https://www.msys2.org/
[vcpkg-shield]: https://img.shields.io/badge/packages-vcpkg-brightgreen?style=for-the-badge
[vcpkg-url]: https://vcpkg.io/
[repo-url]: https://github.com/DegorasProjectTeam/DrivEnv-Win
[issues-url]: https://github.com/DegorasProjectTeam/DrivEnv-Win/issues
