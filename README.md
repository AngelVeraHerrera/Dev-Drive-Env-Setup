# DrivEnv-Win

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6)](#requirements)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](#requirements)
[![Toolchain](https://img.shields.io/badge/toolchain-MSYS2%20UCRT64-orange)](#what-you-get)
[![vcpkg](https://img.shields.io/badge/packages-vcpkg-brightgreen)](#configuration)

Builds a complete, reproducible C++ development drive on Windows from a single JSON file: VHDX, pinned MSYS2/UCRT64
toolchain, vcpkg with overlay ports, launchers, and a verification step that checks every library actually loads.

---

## About This Repository

A development environment is normally something that accumulates: a toolchain installed by hand, a package manager
cloned at whatever commit was current, a `PATH` that grew over years, and knowledge about why any of it works living
only in the head of whoever set it up. When the machine changes, or the person does, it has to be rediscovered.

**DrivEnv-Win** turns that into a description. One JSON file names the drive, the toolchain and its pinned package
versions, the vcpkg baseline commit, the packages and their features, the environment variables and the folders. Five
numbered PowerShell scripts turn the description into a working, self-contained drive — and the fifth one proves it
works rather than assuming it.

> ⚠️ **Why that last part matters.** A build system reporting success is a statement about compilation, not about the
> environment being usable. Every failure this tooling has actually hit was silent. A missing `DirectXMath` made
> GStreamer's `d3d11` library skip itself without a word, and `gstcuda` and `nvcodec` went with it — the first error
> anyone saw named CUDA, which had nothing to do with it. A library whose import table named a DLL that its own port
> installed under a *different* name killed `ffmpeg.exe` outright and took GStreamer's entire libav bridge with it,
> unnoticed in two separate environments, because nothing had ever tried to **load** what had been built
> successfully. Step 5 exists for that gap.

---

## What You Get

A drive that mounts under one letter and contains everything a build needs:

| Path | Contents |
| --- | --- |
| `msys64/` | MSYS2 with a UCRT64 toolchain, packages pinned to exact versions |
| `vcpkg/` | vcpkg at a pinned baseline commit, with overlay ports and overlay triplets |
| `env/` | The generated environment file, the launchers, and per-tool settings |
| `workspace/` | Your source trees |
| `buildtrees/` | Out-of-source build directories |
| `deploys/` | Installed artefacts of your own projects |
| `testing/` | Runnable checks for the libraries that are historically troublesome |
| `installation/` | What this environment IS: package inventory, baseline, overlay notes, manual installs |
| `logs/` | Environment and tool logs |

Plus launchers on the drive itself — a `.bat` for Windows and a bash bootstrap for the MSYS2 shell — so the
environment is entered the same way by a person, a script or a CI job.

Nothing is installed system-wide and the machine's global `PATH` is never touched. Step 1 does make exactly two
changes outside the drive, both by design and both worth knowing about:

- a **desktop shortcut** to the VHDX file, so the drive can be remounted with a double click;
- `HKCU\...\Explorer\AutoplayHandlers\DisableAutoplay` is set to `1` while the disk is attached and back to `0`
  afterwards, to stop Windows opening an AutoPlay dialog mid-run. Note that it is restored to `0` rather than to
  whatever it was before, so a deliberately disabled AutoPlay setting will come back enabled.

---

## Requirements

| Requirement | Notes |
| --- | --- |
| Windows 10 or 11 | A **Dev Drive** (`use_dev_drive`) needs Windows 11 23H2 or later; otherwise a plain VHDX is used |
| PowerShell | Developed and tested on PowerShell 7. The scripts use nothing newer than 5.1, which ships with Windows |
| Administrator | Required by step 1 only, to create and mount the virtual disk |
| Git | Used to clone vcpkg |
| Free space | At least `vhd_size_gb` on the volume holding `vhd_root` |

> ⚠️ Nothing else needs to be installed first. The toolchain, the package manager and every dependency are placed on
> the drive by the scripts.

---

## Quick Start

The repository root holds only `README.md`, `LICENSE` and the git files. Everything the generator itself needs lives
one level down, in `DrivEnv-Win/`, and that is the directory every command below is run from.

```powershell
git clone https://github.com/DegorasProjectTeam/DrivEnv-Win.git
cd DrivEnv-Win\DrivEnv-Win
copy drivenv-cfg_example.json drivenv-cfg.json
```

Edit `drivenv-cfg.json` — at minimum the drive letter, the label and the environment name — then run the steps in
order, from an **elevated** PowerShell for the first one:

```powershell
.\1-Setup_DevDrive.ps1     # create and mount the drive, lay out the folders, write the launchers
.\2-Setup_MSYS2.ps1           # install MSYS2 and the pinned toolchain packages
.\3-Clone_VCPKG.ps1           # clone vcpkg at the baseline, write the environment file
.\4-Deps_VCPKG.ps1            # install the configured packages, write the installation inventory
.\5-Verify_Env.ps1            # prove the result works
```

Every step takes the same `-ConfigFile` switch and **must be given the same file**: they hand state to each other
through the generated environment file on the drive.

```powershell
.\1-Setup_DevDrive.ps1 -ConfigFile my-other-drive.json
```

A bare name or a relative path resolves against the script's own directory, so a config sitting beside the scripts
needs no path at all.

Once step 3 has run, the environment is entered from the drive itself:

```
<drive>:\env\launcher\<envname>_env_launcher.bat
```

---

## Configuration

One file, four sections. `drivenv-cfg_example.json` is tracked and documents every key;
`drivenv-cfg.json` is the one you edit and is deliberately **not** tracked.

Every step validates this file before it acts on any value in it, and reports every problem at once rather than the
first. All five also take `-ValidateOnly`, which validates and stops without changing anything -- a second's check on
an edited file, and worth considerably more before a step that takes an hour than after it.

```powershell
.-Verify_Env.ps1 -ValidateOnly
```

> ⚠️ **An unknown key is an error, not a default.** Every reader in these scripts falls back to a default when
> a key is absent, so a typo used to be silent: `install_testing_materials` in the plural copied the testing tree you
> asked it to skip, and `check_toolz` left step 5 checking no tools at all and then reporting `tools 0 checked, 0
> failed` as a pass. A verification step that quietly verifies less than it was asked to is worse than none, because
> it is believed. So the validator refuses the file and suggests the nearest key it knows.

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
| `proxy_url` | Proxy for the downloads, or empty for none |
| `install_testing_material`, `install_installation_material` | Whether to copy `testing/` and `installation/` to the drive |
| `verification` | What step 5 checks — see below |

> ⚠️ A `${REFERENCE}` that nothing defines expands to the **empty string**, not to an error, because the launcher
> resolves the file line by line. An empty `PATH` component means "the current directory" to both `execvp` and bash,
> which is a real shadowing hazard — so steps 1 and 3 validate every reference and refuse to write a config that
> makes one. Order matters: a variable can only reference something defined before it.

### `msys2`

Where to fetch the installer from, which profile and architecture to target, and the package list. Each package may
be `pinned` to an exact version, which is what makes the toolchain reproducible rather than "whatever was current".

```json
{ "name": "gcc", "mode": "pinned", "version": "16.2.0-3" }
```

### `vcpkg`

The repository, the baseline mode and commit, the triplet, and the packages with their features.

```json
{ "name": "mongo-c-driver", "features": ["openssl"] }
```

> ⚠️ Prefer explicit feature lists over blanket ones such as ffmpeg's `all-gpl`. `all-gpl` enables everything,
> including codecs that cannot work on this toolchain — and one of them took `avcodec` down with it, and `ffmpeg.exe`
> and GStreamer's whole libav bridge after that. An explicit list is also a statement of intent that a reader can
> check.

### `environment.verification`

What "working" means for *this* drive, which is a question a generator cannot answer for you:

| Key | Checks |
| --- | --- |
| `check_packages` | Every configured port is installed |
| `check_dll_load` | Every installed library and plugin can actually be **loaded** |
| `check_tools` | Named tools resolve on the environment's `PATH` |
| `check_commands` | Named commands run and their output contains an expected string |
| `check_gstreamer_elements` | Named GStreamer elements are registered |

---

## Verification

```powershell
.\5-Verify_Env.ps1            # exits non-zero if anything is wrong
.\5-Verify_Env.ps1 -NoFail    # report only, for a run whose purpose is to look
```

Output is a summary by group, a list of anything that failed, and a report written to
`<drive>:\installation\verification.txt`.

```
 packages   27 checked, 0 failed
 load      477 checked, 0 failed
 tools       8 checked, 0 failed
 commands    4 checked, 0 failed
 elements   29 checked, 0 failed
```

Three result states, not two: **ok**, **failed**, and **not checked**. The last one matters — a check that could not
be carried out, because another vcpkg process held the lock for instance, is not a check that failed. A verification
tool that cries wolf gets switched off.

**The load check is the one that earns its keep.** A DLL that built is not a DLL that works: it can be missing a
dependency or importing a name nothing provides, and neither shows up until something tries to load it. Each library
is opened with `LOAD_WITH_ALTERED_SEARCH_PATH`, so its dependencies resolve exactly as they will for a real consumer.

---

## Testing Material

`DrivEnv-Win/testing/` is copied to the drive and holds hand-runnable checks for the libraries that have
historically been difficult on this toolchain:

- **`gstreamer/`** — element checks, pipelines, NVIDIA and Media Foundation encode paths, RTP send/receive launchers,
  low-latency patterns, and a real 1080p60 file to demux rather than a synthesised one.
- **`ffmpeg/`** — what was built in, probing, decode and transcode.
- **`curl/`** — TLS backend, protocols, and what the requested features actually produced.

> ⚠️ Run these **from the environment's own launcher**. The vcpkg tool directories are placed on `PATH` by the
> launcher, not by the environment file. And a binary run from a shell carrying *another* environment picks up that
> environment's DLLs — the failure is `0xC0000139`, "entry point not found", which reads like a broken build rather
> than a mixed one.

---

## Overlay Ports

`DrivEnv-Win/vcpkg_overlays/ports/` carries local ports for packages that do not build correctly on this
toolchain as published. Every one of them is a thing that must be re-applied when the port is bumped, so
**every one of them is documented** — what it changes, why, and how the failure presents itself — in
[`installation/vcpkg_overlays.txt`](DrivEnv-Win/installation/vcpkg_overlays.txt).

That file exists because the alternative was tried: a fix was made for an earlier environment, the reasoning lived
only in the diff, the diff did not survive a rebase, and the same problem was diagnosed from scratch months later —
presenting, that time, as an error message about CUDA.

Several of these are genuine upstream bugs on non-MSVC Windows toolchains and are worth reporting upstream rather
than carried forever. The notes say which.

---

## Installation Record

Step 4 writes an inventory to `<drive>:\installation\`, next to the hand-written notes:

| File | Contents |
| --- | --- |
| `vcpkg_packages.txt` / `.json` | Which ports, versions and features — the JSON for diffing two drives or two dates |
| `vcpkg_baseline.txt` | The baseline commit and what it was, so a version can be traced upstream |
| `msys2_packages.txt` | The MSYS2 side, which vcpkg knows nothing about |
| `environment.txt` | The generated variables, verbatim |
| `verification.txt` | The result of the last step 5 run |
| `vcpkg_overlays.txt` | Hand-written: what each overlay changes and why |
| `vcpkg_packages_notes.txt` | Hand-written: what was enabled, what was excluded on purpose, what was tried and failed |
| `manual_installs.txt` | Hand-written: what no script installs |

The generated files are generated because a hundred-package list maintained by hand is worse than none the moment it
drifts. The hand-written ones are hand-written because no tool knows *why* a decision was taken.

---

## License

MIT — see [LICENSE](LICENSE).
