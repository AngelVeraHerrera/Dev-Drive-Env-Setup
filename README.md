<a name="readme-top"></a>

<!-- PROJECT SHIELDS -->
[![MIT License][license-shield]][license-url]
[![Platform][platform-shield]][platform-url]
[![PowerShell][powershell-shield]][powershell-url]
[![Toolchain][toolchain-shield]][toolchain-url]
[![vcpkg][vcpkg-shield]][vcpkg-url]

<!-- PROJECT TITLE -->
<h1 align="center">DrivEnv-Win</h1>

<p align="center">
  Builds a self-contained C++ development drive on Windows from a single JSON file, and then checks that it works.
</p>

---

## About This Repository

A development environment usually accumulates rather than gets built: a toolchain installed by hand, a package
manager cloned at whatever commit was current that day, a `PATH` that grew over years, and the knowledge of why any
of it works living only in the head of whoever set it up. When the machine changes, or the person does, it has to be
rediscovered.

**On Linux this is largely a solved problem.** A container image pins the toolchain, the libraries and the
environment in one file, it is cheap to rebuild, and it is the normal way to work.

**On Windows there is no equivalent that is both simple and standard**, at least not for native desktop C++ with
GUI toolkits, hardware SDKs and vendor drivers in play. Windows containers are heavy, awkward for anything with a
window or a USB device, and not how anyone actually develops this kind of software. So the usual answer is a
document describing what to install, and the usual result is that no two machines end up alike.

**DrivEnv-Win takes a different route: the environment is a drive.** One JSON file names the toolchain and its
pinned package versions, the vcpkg baseline commit, the packages and their features, the variables and the folders.
Six PowerShell steps, driven by one command, turn that description into a virtual disk that carries everything a
build needs. It mounts under a letter, it is entered through its own launcher, and it can be handed to another
machine or rebuilt from the same JSON months later.

Nothing is installed system-wide, so several environments can exist side by side on one machine — a GCC one and a
clang one, or one per project — without any of them being "the" environment.

The last step is the point of the whole thing: it **verifies** the result rather than assuming it. A build system
reporting success says something about compilation, not about the environment being usable, and the failures this
tooling has actually hit were all silent ones — a library that built perfectly and could not be loaded, a plugin
that skipped itself without a word.

### Where this is used

DrivEnv-Win generates the development environments for the **Degoras Project** systems that operate the Satellite
Laser Ranging (SLR) station at the **Real Instituto y Observatorio de la Armada (ROA)** in San Fernando, Spain.
Those systems combine real-time control, hardware SDKs and a heavy C++ dependency stack, which is exactly the case
where "it works on my machine" stops being acceptable.

---

## What You Get

A drive that mounts under one letter and contains everything a build needs:

| Path | Contents |
| --- | --- |
| `msys64/` | MSYS2 with the toolchain, packages pinned to exact versions |
| `vcpkg/` | vcpkg at a pinned baseline commit, with overlay ports and triplets |
| `env/` | The generated environment file, the launchers, and per-tool settings |
| `workspace/` | Your source trees |
| `buildtrees/` | Out-of-source build directories |
| `deploys/` | Installed artefacts of your own projects |
| `testing/` | Runnable checks for the libraries that are historically troublesome |
| `installation/` | What this environment is: package inventory, baseline, overlay notes |
| `logs/` | Each setup step's log, and the logs of every port that failed |

Plus launchers on the drive itself — a `.bat` for Windows and a bash bootstrap for the MSYS2 shell — so the
environment is entered the same way by a person, a script or a CI job.

The machine's global `PATH` is never touched. Four marks are left outside the drive, and the first two are
switchable:

- **desktop shortcuts** to the VHDX and to the environment launcher (`create_desktop_shortcuts`);
- a **scheduled task** that mounts the drive at startup (`automount_at_startup`);
- `DisableAutoplay` is set while the disk is attached and restored afterwards, so Windows does not open an AutoPlay
  dialog mid-run;
- two **Microsoft Defender path exclusions**, for the VHDX directory and the drive letter.

---

## Requirements

| Requirement | Notes |
| --- | --- |
| Windows 10 or 11 | A **Dev Drive** (`use_dev_drive`) needs Windows 11 23H2 or later; otherwise a plain VHDX is used |
| PowerShell | Developed and tested on PowerShell 7. The scripts use nothing newer than 5.1, which ships with Windows |
| Script execution enabled | See below |
| Administrator | For step 1 only |
| Free space | At least `vhd_size_gb` on the volume holding `vhd_root` |

Windows blocks PowerShell scripts by default, so allow them for the current session before starting:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

That covers the whole run: the steps launched by `Generate-DrivEnv.ps1` are given their own bypass, so only the
first invocation needs it. `-Scope Process` lasts until you close the window and changes nothing permanently.

> ⚠️ Nothing else needs to be installed first, and that includes Git. The toolchain, the package manager and every
> dependency are placed on the drive by the scripts, so the result does not depend on what the machine happened to
> have.

---

## Quick Start

Everything the generator needs lives in `DrivEnv-Win/`, one level down from the repository root, and that is the
directory every command below is run from.

```powershell
git clone https://github.com/DegorasProjectTeam/DrivEnv-Win.git
cd DrivEnv-Win\DrivEnv-Win
copy config\drivenv-cfg_example.json config\drivenv-cfg.json
```

Edit `config\drivenv-cfg.json` — at minimum the drive letter, the label and the environment name — then run the
whole procedure:

```powershell
.\Generate-DrivEnv.ps1
```

> ⚠️ **Run it from an elevated PowerShell.** Administrator rights are needed by **step 1 alone**, and only to
> create and mount the virtual disk — `diskpart` and the storage cmdlets require it. Nothing else in the procedure
> does: installing the toolchain, building packages and verifying the result all run as a normal user. Resuming
> past step 1 therefore needs no elevation at all, and `-From 2` or later will start without asking.

It runs the six steps in order, stops at the first failure, and prints what each one cost.

| Switch | What it does |
| --- | --- |
| `-ConfigFile <name>` | Forwarded to every step. A bare name resolves against `config/` |
| `-From <n>` | Resume at step *n*, so a failure at step 4 does not cost you steps 1 to 3 again |
| `-To <n>`, `-Skip 5,6` | Stop early, or drop steps inside the range |
| `-ValidateOnly` | Check the configuration and change nothing |

Any step can be run on its own — that is all the runner does:

```powershell
.\scripts\1-Setup_DevDrive.ps1     # create and mount the drive, lay out the folders, write the launchers
.\scripts\2-Setup_MSYS2.ps1        # install MSYS2 and the pinned toolchain packages
.\scripts\3-Clone_VCPKG.ps1        # clone vcpkg at the baseline, write the environment file
.\scripts\4-Deps_VCPKG.ps1         # install the configured packages, write the installation inventory
.\scripts\5-Verify_Env.ps1         # prove the result works
.\scripts\6-Clone_Repos.ps1        # clone the configured projects into the drive (optional)
```

Every step takes the same `-ConfigFile` and **must be given the same file**: they hand state to each other through
the environment file on the drive. A bare name resolves against `config/`; an absolute path is taken as given, which
lets a configuration live outside the repository.

Step 1 refuses to start unless the ground is clear — the drive letter free, no VHDX already at `vhd_root`, enough
space — and checks all of that before anything is created or elevation is requested.

Once step 3 has run, the environment is entered from the drive itself:

```
<drive>:\env\launcher\<envname>_env_launcher.bat
```

### Layout

| Path | What lives there |
| --- | --- |
| `Generate-DrivEnv.ps1` | The entry point |
| `Manage-MountTasks.ps1` | Lists the startup mount tasks on this machine and removes orphaned ones |
| `config/` | The configuration you edit, and two documented copies |
| `scripts/` | The six steps and the shared modules |
| `scripts_env/` | Launchers and tool wrappers, copied onto the drive |
| `vcpkg_overlays/` | Overlay ports and triplets |
| `packages_msys2/` | Download cache for the MSYS2 installer and its packages |
| `testing/`, `installation/` | Material copied onto the drive |
| `install_logs/` | Every run's log, before it is copied to the drive |

---

## The Public Contract

The generated `<drive>:\env\<envname>_env_variables.env` holds two kinds of variable. These are the ones a
repository may depend on:

| Variable | Meaning |
| --- | --- |
| `DEVSYSTEM_TOOLCHAIN_ROOT` | The prefix holding the compiler drivers, `cmake`, `ninja` and `gdb` |
| `DEVSYSTEM_TOOLCHAIN` | The compiler family, exactly `gcc` or `clang` |
| `DEVSYSTEM_TOOLCHAIN_ID` | The namespace slug for paths: `ucrt64`, `clang64`, … |
| `DEVSYSTEM_BUILDTREES`, `DEVSYSTEM_DEPLOYS`, `DEVSYSTEM_WORKSPACE` | Where builds, installs and sources live |
| `VCPKG_ROOT`, `VCPKG_DEFAULT_TRIPLET` | The dependency prefix and its triplet |

Everything else in the file — `MSYS2_*`, `BASE_PATH`, `DEVDRIVE_*`, `VCPKG_OVERLAY_*`, `GST_*` — is the generator
talking to itself. A project reading those is coupling itself to MSYS2 rather than to the environment.

`DEVSYSTEM_TOOLCHAIN` exists because the compiler family cannot be guessed: MSYS2's CLANG64 ships `gcc.exe` and
`g++.exe` as copies of clang, so sniffing the prefix gives the wrong answer. The environment states it instead.

---

## Configuration

One file, four sections, in `config/`. `drivenv-cfg_example.json` is tracked and documents every key;
`drivenv-cfg.json` is the one you edit and is deliberately **not** tracked. Every step validates it before acting on
any value.

```powershell
.\scripts\5-Verify_Env.ps1 -ValidateOnly
```

> ⚠️ **An unknown key is an error, not a default.** Every reader falls back to a default when a key is absent, so a
> typo would otherwise be silent — `check_toolz` would leave step 5 checking no tools at all and reporting a pass.
> The validator refuses the file and suggests the nearest key it knows.

### `environment`

| Key | Meaning |
| --- | --- |
| `dev_drive_label`, `dev_drive_letter` | Volume label and mount letter |
| `dev_env_name` | Prefixes the generated files and launchers |
| `vhd_root`, `vhd_size_gb`, `vhd_fixed` | Where the virtual disk lives, how big, fixed or dynamic |
| `use_dev_drive` | Format as a Windows Dev Drive (ReFS) instead of NTFS |
| `force_diskpart` | Use `diskpart` rather than the storage cmdlets |
| `custom_variables` | Extra `KEY=VALUE` entries. `${REFERENCES}` to earlier variables are expanded |
| `custom_path_entries` | Extra `PATH` components, in order |
| `custom_folders` | Extra directories to create, relative to the drive root |
| `append_windows_system_path` | Append the Windows system directories to `BASE_PATH` |
| `create_desktop_shortcuts` | Put the VHDX and launcher shortcuts on the desktop. Default `true` |
| `automount_at_startup` | Register the scheduled task that mounts the drive at boot. Default `true` |
| `proxy_url` | Proxy for the downloads, or empty for none |
| `install_testing_material`, `install_installation_material` | Whether to copy `testing/` and `installation/` |
| `verification` | What step 5 checks — see below |

> ⚠️ A `${REFERENCE}` that nothing defines expands to the **empty string**, and an empty `PATH` component means
> "the current directory" to both `execvp` and bash. Steps 1 and 3 validate every reference and refuse to write a
> configuration that makes one. Order matters: a variable can only reference something defined before it.

### `msys2`

Names the installer, the subsystem and the packages, each either pinned to an exact version or tracking latest.
A pinned package that does not install is a hard error at step 2 rather than a mystery later.

A subsystem is known by three different names, and the configuration keeps them apart:

| | | |
| --- | --- | --- |
| `subsystem` | the `MSYSTEM` value and the install directory | `clang64` → `/clang64` |
| `repo_subpath` | where the packages live on repo.msys2.org | `mingw/clang64` |
| `package_prefix` | what a package is actually called | `mingw-w64-clang-x86_64-<name>` |

The common ones are built in and need no configuration:

| `subsystem` | `package_prefix` | `repo_subpath` | default `arch` |
| --- | --- | --- | --- |
| `ucrt64` | `mingw-w64-ucrt-x86_64` | `mingw/ucrt64` | `x86_64` |
| `clang64` | `mingw-w64-clang-x86_64` | `mingw/clang64` | `x86_64` |
| `mingw64` | `mingw-w64-x86_64` | `mingw/mingw64` | `x86_64` |
| `clangarm64` | `mingw-w64-clang-aarch64` | `mingw/clangarm64` | `aarch64` |
| `mingw32` | `mingw-w64-i686` | `mingw/mingw32` | `i686` |
| `clang32` | `mingw-w64-clang-i686` | `mingw/clang32` | `i686` |

### `vcpkg`

Names the repository, the baseline commit, the target triplet and the packages with their features. A package may
override the triplet for itself, which is how one library is built statically inside an otherwise dynamic
environment.

#### `install_schedule` — attempts and concurrency as one list

```json
"install_schedule": [ {}, { "concurrency": 8 }, { "concurrency": 1 } ]
```

One entry per attempt, in order; the length is the attempt count. `{}` or `concurrency: 0` lets vcpkg size the
build from the hardware. The failures worth retrying are resource-shaped — a machine with many cores and little
RAM exhausts memory long before it exhausts cores — so retrying identically just rolls the same dice, while
retrying with fewer parallel jobs changes the odds. Both keys also exist per package, since the ports that need
throttling are not the ports that need retrying.

#### `retry_delay_seconds`

Seconds to wait before a retry, multiplied by the attempt number: `30` gives gaps of 0, 30, 60, 90. Absent or `0`
retries immediately, which is the default. It is for the failures a lower concurrency cannot fix — a flaky proxy,
an unreachable mirror — and costs nothing on a healthy run.

#### `cleanup.buildtrees` — what step 4 throws away when it is done

`none` (the default), `logs`, or `all`. `buildtrees` is the largest thing on a finished drive by a wide margin and
is pure scratch. `logs` removes each port's source and build directories but keeps its build logs; `all` removes
the port directories whole. Only runs after a successful, uncancelled step 4.

> ⚠️ **`DEVSYSTEM_BUILDTREES` points at this same directory, so your own projects build here too.** Cleanup never
> touches them: a port is identified by the `vcpkg_abi_info.txt` vcpkg leaves in its directory, not by its name.

#### `buildtrees_root` — a hard limit, not a preference

A folder name relative to the drive, defaulting to `bt`. It is short on purpose: Windows applies a 260-character
path cap to programs without a long-path manifest, MSYS2's GCC is one of them, and Qt's generated filenames under
vcpkg's default `buildtrees/` reach it. Do not spell the drive letter here — `dev_drive_letter` already says which
drive this is.

> ⚠️ **A different triplet means a different installed tree**, so consumers need a second `CMAKE_PREFIX_PATH`, and
> a static library brings its own copies of shared dependencies. When the goal is just "this one library static",
> `set(VCPKG_LIBRARY_LINKAGE static)` in an overlay portfile is the lighter tool.

> ⚠️ Prefer explicit feature lists over blanket ones such as ffmpeg's `all-gpl`, which enables codecs that cannot
> work on this toolchain and can take the rest of the library down with them.

### `workspace`

Optional. Names git repositories for step 6 to clone onto the drive. Only the URL is required; a repository can
override its directory name, destination folder, branch or tag, clone depth, submodules, and whether a failure to
clone is fatal. A repository already present with the same origin is left alone — not fetched, not reset — and one
with a different origin is refused rather than touched.

### `environment.verification`

What step 5 checks: the packages that must be installed, whether every library loads, the tools that must be on
`PATH`, commands that must run, and the GStreamer elements that must be registered.

---

## Verification

Step 5 checks the environment that was built.

```powershell
.\scripts\5-Verify_Env.ps1            # exits non-zero if anything is wrong
.\scripts\5-Verify_Env.ps1 -NoFail    # report only
```

Output is a summary by group, a list of anything that failed, and a report written to
`<drive>:\installation\verification.txt`.

```
 packages   29 checked, 0 failed
 load      431 checked, 0 failed
 tools       6 checked, 0 failed
 commands    3 checked, 0 failed
 elements   29 checked, 0 failed
 patches     1 checked, 0 failed
```

Three result states, not two: **ok**, **failed**, and **not checked**. A check that could not be carried out is not
a check that failed, and a verification tool that cries wolf gets switched off.

**The load check is the one that earns its keep.** A DLL that built is not a DLL that works: it can be missing a
dependency or importing a name nothing provides, and neither shows up until something tries to load it. Each
library is opened the way a real consumer would open it.

---

## Testing Material

`DrivEnv-Win/testing/` is copied to the drive and holds hand-runnable checks for the libraries that have
historically been difficult on this toolchain: GStreamer (elements, pipelines, hardware encode paths, RTP), FFmpeg
(what was built in, decode and transcode) and curl (TLS backend and protocols).

> ⚠️ Run these **from the environment's own launcher**. A binary run from a shell carrying another environment
> picks up that environment's DLLs, and the failure reads like a broken build rather than a mixed one.

---

## Overlay Ports

`DrivEnv-Win/vcpkg_overlays/ports/` carries local ports for packages that do not build correctly on this toolchain
as published. Each one must be re-applied when the port is bumped, so each one is documented — what it changes, why,
and how the failure presents itself — in
[`installation/vcpkg_overlays.txt`](DrivEnv-Win/installation/vcpkg_overlays.txt). Several are genuine upstream bugs
worth reporting rather than carrying forever; the notes say which.

Overlay ports are **layered**, and each triplet says which layers it searches:

```json
"overlay_ports": [
  { "triplet": "x64-mingw-clang-dynamic-release", "layers": ["ports.clang", "ports"] },
  { "triplet": "*",                               "layers": ["ports"] }
]
```

Layers are searched in order and vcpkg takes the first that contains the port, so a specific layer overrides the
shared one. Omit the key and every triplet gets `["ports"]`.

> ⚠️ **A layer is usually the wrong tool.** It holds a whole portfile, so two copies then have to be kept in step
> through every baseline bump — and they will not be. For a delta of a line or two, put a conditional inside the
> shared port instead.

Step 3 also applies one patch to vcpkg itself, adding a known-transient OpenSSL failure to the list of build errors
vcpkg retries serially. It is idempotent, never fatal, and step 5 checks that it is still in place.

### Triplet integrity

Step 3 verifies every overlay triplet against a `.sha256` shipped beside it and refuses to install one that does
not match. The hash is over the file's content with line endings normalised, not its raw bytes, so a checkout that
converted line endings still verifies.

> ⚠️ **If the check fails, read the diff before regenerating the hash.** The comparison ignores line endings, so a
> mismatch means the content changed — which is the check doing its job.

---

## Logs

Every step logs into `install_logs\` beside the scripts and copies that log onto the drive at
`<drive>:\logs\setup\`, on the way out of a successful run and of a failed one. The scripts live in a working copy
that gets cloned, moved and cleaned; the drive does not, so a drive carries the record of how it was made.

Failed ports get their own copy, one directory per attempt:

```
<drive>:\logs\vcpkg\<port>\attempt1_20260903_093201\
<drive>:\logs\vcpkg\<port>\attempt2_20260903_094410\
```

vcpkg writes a port's logs under fixed names, so the next attempt overwrites them. Copying them out after each
failed attempt keeps the first failure, which is usually the informative one.

---

<!-- INSTALLATION RECORD -->
## Installation Record

Step 4 writes an inventory to `<drive>:\installation\`, next to the hand-written notes:

| File | Contents |
| --- | --- |
| `vcpkg_packages.txt` / `.json` | Which ports, versions and features — the JSON for diffing two drives or two dates |
| `vcpkg_baseline.txt` | The baseline commit, so a version can be traced upstream |
| `msys2_packages.txt` | The MSYS2 side, which vcpkg knows nothing about |
| `environment.txt` | The generated variables, verbatim |
| `verification.txt` | The result of the last step 5 run |
| `vcpkg_overlays.txt` | Hand-written: what each overlay changes and why |
| `vcpkg_packages_notes.txt` | Hand-written: what was enabled, excluded, or tried and failed |
| `manual_installs.txt` | Hand-written: what no script installs |

The generated files are generated because a hundred-package list maintained by hand is worse than none the moment
it drifts. The hand-written ones are hand-written because no tool knows *why* a decision was taken.

---

<!-- LICENSE -->
## License

Distributed under the MIT License. See [`LICENSE`](LICENSE) for details.

---

<!-- CONTACT -->
## Author / Contact

**Degoras Project Team**

Ángel Vera Herrera — Real Instituto y Observatorio de la Armada (ROA) — [avera@roa.es](mailto:avera@roa.es)

Project link: [https://github.com/DegorasProjectTeam/DrivEnv-Win][repo-url]

<!-- ACKNOWLEDGMENTS -->
## Acknowledgments

* [https://armada.defensa.gob.es/ArmadaPortal/page/Portal/ArmadaEspannola/cienciaobservatorio/prefLang-es/](https://armada.defensa.gob.es/ArmadaPortal/page/Portal/ArmadaEspannola/cienciaobservatorio/prefLang-es/)
* [https://www.msys2.org/](https://www.msys2.org/)
* [https://vcpkg.io/](https://vcpkg.io/)
* [https://www.qt.io/](https://www.qt.io/)
* [https://shields.io/](https://shields.io/)
* [https://github.com/othneildrew/Best-README-Template](https://github.com/othneildrew/Best-README-Template)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- MARKDOWN LINKS & IMAGES -->
[license-shield]: https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge
[license-url]: https://opensource.org/licenses/MIT
[platform-shield]: https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?style=for-the-badge
[platform-url]: #requirements
[powershell-shield]: https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=for-the-badge&logo=powershell&logoColor=white
[powershell-url]: #requirements
[toolchain-shield]: https://img.shields.io/badge/toolchain-MSYS2-orange?style=for-the-badge
[toolchain-url]: https://www.msys2.org/
[vcpkg-shield]: https://img.shields.io/badge/packages-vcpkg-brightgreen?style=for-the-badge
[vcpkg-url]: https://vcpkg.io/
[repo-url]: https://github.com/DegorasProjectTeam/DrivEnv-Win
