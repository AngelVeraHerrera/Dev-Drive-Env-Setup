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
  Builds a complete, reproducible C++ development drive on Windows from a single JSON file: VHDX, pinned
  MSYS2/UCRT64 toolchain, vcpkg with overlay ports, launchers, and a verification step that checks every
  library actually loads.
</p>

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
| Free space | At least `vhd_size_gb` on the volume holding `vhd_root` |

> ⚠️ Nothing else needs to be installed first, and that includes Git. The toolchain, the package manager and
> every dependency are placed on the drive by the scripts, and the git that clones vcpkg is the one step 2 installed
> on the drive -- located there explicitly rather than found on `PATH`, so the result does not depend on what the
> machine happened to have.

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
.\6-Clone_Repos.ps1           # clone the configured projects into the drive (optional)
```

Step 6 is optional in the real sense: a configuration with no `workspace` section is valid, and the step then says so
and exits 0. It is last because it is the only one that puts *your* code on the drive rather than the environment's.

Step 1 is the only one needing administrator rights. Started without them it asks for elevation, does the work in
the elevated window, and waits for it -- so the window you started from stays open until that finishes, and then
exits with the same code. Started already elevated it runs straight through and nothing waits.

It also refuses to start unless the ground is clear. It checks that the drive letter is free, that no VHDX already
sits at `vhd_root`, and that the volume there has at least `vhd_size_gb` available. All three run before anything is
created and before elevation is even requested, so a configuration naming an occupied letter costs a second rather
than a 50 GB file, a UAC prompt and a failure at the end.

> ⚠️ **A letter can be taken by something `Get-Volume` cannot see** -- a mapped network drive, a `subst`, or a
> disk attached with no mounted filesystem. The check consults the logical drive list as well, and says which kind of
> thing holds the letter, because "in use by a network drive" and "in use by a mounted volume" call for different
> fixes.

> **Step 4 retries a failed port once, on its own, and the retry runs with concurrency forced to 1.** Not a plain
> repeat of the same command: the failures this absorbs are concurrency- and resource-shaped, so serialising is
> what changes the odds rather than just rolling the dice again. It is safe because vcpkg is per-package -- an
> attempt costs only the port that failed, never the tree behind it.
>
> Three failures seen on one machine, none of them a build error, all gone on a re-run:
>
> | Port | What it said |
> | --- | --- |
> | `openssl` | `Trying to rename Makefile-179 -> Makefile: Permission denied` |
> | `mongo-c-driver` | `internal compiler error: Segmentation fault`, during the GIMPLE `fre` pass |
> | `glib` | `Access violation`, out of the meson configure |
>
> **Every retry is reported, and the summary names each port that needed one.** That is deliberate. Three unrelated
> programs -- perl, GCC and meson -- crashing on one machine and none of them on another is a statement about the
> machine, not about vcpkg, and a retry that quietly succeeded would erase the only evidence of it. One retry is
> bad luck; several across unrelated ports is worth investigating, and the usual causes are an on-access virus
> scanner holding files open and memory pressure crashing the compiler.
>
> If a port fails every attempt the step stops, and every attempt after the first having run serialised means a
> race between parallel jobs is already ruled out.
>
> **`vcpkg.max_install_attempts` raises the count**, and it is configurable because it is a property of the machine
> rather than of the configuration. One machine here needed *five* attempts to get `qtshadertools` through, with
> GCC segfaulting at a different optimisation pass and inside a different function on each run -- `dep_fusion` in
> one, `threadfull` in the next. A compiler bug is deterministic, so crashing somewhere different every time is
> hardware, and the honest fix is a memory test rather than a build flag. Raise this to keep working in the
> meantime; leave it alone on a machine that does not need it, since a high value on a healthy one only turns a
> genuine build error into a long wait.

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
.\5-Verify_Env.ps1 -ValidateOnly
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

`vcpkg.target.triplet` is the default for every package. A package may override it with an optional `triplet` of its
own, for the case where one library has to be built differently from the rest:

```json
{ "name": "fastdds", "triplet": "x64-mingw-ucrt-static-release" }
```

Every triplet in `DrivEnv-Win/vcpkg_overlays/triplets/` is installed to the drive, each verified against its
`.sha256`, so an override only needs the triplet to exist there. The configured triplet still aborts the run if its
hash is missing; an additional one declines to travel with a warning instead.

> ⚠️ **A different triplet means a different installed tree.** Everything built under it, dependencies included,
> lands in `vcpkg/installed/<that-triplet>/`, so consumers need a second `CMAKE_PREFIX_PATH` — and a library built
> there brings its own static copies of shared dependencies. An application linking a package from a static tree
> alongside Qt or curl from the dynamic one can end up with two OpenSSL instances in a single process. When the goal
> is just "this one library static", `set(VCPKG_LIBRARY_LINKAGE static)` in an overlay portfile is the lighter tool:
> the package stays in the same tree and its dependencies stay shared. That is how Fast DDS and the mongo family are
> built here.

> ⚠️ Prefer explicit feature lists over blanket ones such as ffmpeg's `all-gpl`. `all-gpl` enables everything,
> including codecs that cannot work on this toolchain — and one of them took `avcodec` down with it, and `ffmpeg.exe`
> and GStreamer's whole libav bridge after that. An explicit list is also a statement of intent that a reader can
> check.

### `workspace`

Optional, and the only section about your projects rather than the environment. Omit it and step 6 has nothing to do.

```json
"workspace": {
    "default_folder": "workspace",
    "repositories": [
        { "url": "https://github.com/DegorasProjectTeam/DegorasHelloWorlds.git" },
        { "url": "https://github.com/DegorasProjectTeam/LibZMQUtils.git",
          "folder": "workspace/degoras", "ref": "main", "optional": true }
    ]
}
```

Only `url` is required. `default_folder` names the directory **step 1 creates** and the one `DEVSYSTEM_WORKSPACE`
points at, so there is one name in one place rather than a fixed `workspace` folder sitting empty beside whatever
the configuration actually uses. Omit it and it is `workspace`, which is what every environment generated before
this used. It must be relative to the drive root, with no drive letter and no `..`.

| Key | Default | What it does |
| --- | --- | --- |
| `url` | — | Anything `git clone` accepts: https, ssh, or a local path |
| `name` | last path segment of the URL, minus `.git` | The directory to clone into, so two forks can coexist |
| `folder` | `workspace.default_folder` | Destination root, relative to the drive. No drive letter, no `..` |
| `ref` | the remote's default branch | A branch or a tag. Not a commit id — `clone --branch` takes a name |
| `depth` | full clone | A shallow clone of N commits |
| `submodules` | `false` | Clone submodules too |
| `optional` | `false` | A failure here is a warning instead of a fault |

**What the step does when re-run**, which is the part that decides whether it is safe to leave in a pipeline:

| On disk | What happens |
| --- | --- |
| Nothing | Cloned |
| The same repository, same origin | **Left completely alone.** Not fetched, not reset, not rebased |
| A git repository with a *different* origin | Refused, and the step fails |
| Something that is not a git repository | Refused, and the step fails |

It never fetches and never touches a working tree it did not just create. This step puts projects on a drive; it is
not a synchroniser, and pulling under somebody's uncommitted work is not a thing a setup script should do.

> ⚠️ **Private repositories over HTTPS will not clone here.** The step runs non-interactively with
> `GIT_TERMINAL_PROMPT=0`, deliberately — otherwise an unattended run hangs forever waiting for a username nobody is
> there to type. The drive's git has no credential helper of its own. Use a public URL, or an `ssh://` remote with a
> key the machine already has, or mark that repository `optional` and clone it by hand. The step says exactly this
> when an HTTPS clone fails, rather than leaving you to work it out.

**What step 6 deliberately does not do: build anything.** A configuration that both names remote repositories and
names a script to run after fetching them is a way to execute arbitrary code on whoever generates the drive, and
step 1 self-elevates. Separately, and more mundanely: a project that fails to build is not a broken drive, and a
step that conflates the two teaches people to ignore its failures. Build from the launcher, where a red build means
what it says.

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

This section is step 5, which checks the environment that was built. The configuration file itself is checked
separately and much earlier: every step validates it before acting on any value in it, and an unknown key is an
error rather than a silent default -- see [Configuration](#configuration).

```powershell
.\5-Verify_Env.ps1            # exits non-zero if anything is wrong
.\5-Verify_Env.ps1 -NoFail    # report only, for a run whose purpose is to look
```

Output is a summary by group, a list of anything that failed, and a report written to
`<drive>:\installation\verification.txt`.

```
 packages   27 checked, 0 failed
 load       445 checked, 0 failed
 tools      8 checked, 0 failed
 commands   4 checked, 0 failed
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

### Triplet integrity

Step 3 verifies every overlay triplet against a `.sha256` shipped beside it before installing it on the drive, and
refuses to install one that does not match.

The hash is over the file's **content with line endings normalised**, not over its raw bytes, and that distinction
is load-bearing. These are text files in a git repository used with `core.autocrlf=true`, so the same committed
bytes arrive as LF on one machine and CRLF on another. A byte hash measures the developer's git configuration
rather than the file: measured, `x64-mingw-ucrt-static-release.cmake` hashes `910B5E89...` as LF and `8BAE34F2...`
as CRLF, and a hash generated on one machine failed on the other. Regenerating it there fixed it there and broke it
back here.

Two guards, because either alone is fragile. `.gitattributes` marks these files `-text` so git stops rewriting
them, and the check normalises anyway, so a clone predating that rule still verifies.

> ⚠️ **If the check ever fails, read the diff before regenerating the hash.** The comparison ignores line
> endings, so a mismatch means the *content* differs, which is the check doing its job. Regenerate with
> `Utility-Hash_Generator.bat` in the triplets directory only once you know why it changed.

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

<!-- LICENSE -->
## License

Distributed under the MIT License. See [LICENSE](LICENSE) for more information.

<!-- CONTACT -->
## Author / Contact

**Degoras Project Team**

Ángel Vera Herrera — Real Instituto y Observatorio de la Armada (ROA) — [avera@roa.es](mailto:avera@roa.es)

Project link: [https://github.com/DegorasProjectTeam/DrivEnv-Win][repo-url]

<!-- ACKNOWLEDGMENTS -->
## Acknowledgments

* Real Instituto y Observatorio de la Armada (ROA)
* [MSYS2][toolchain-url], whose pinned packages this pins in turn
* [vcpkg][vcpkg-url], and the port maintainers whose work the overlays here only patch
* The [Qt Project](https://www.qt.io/)
* [Shields.io](https://shields.io/)
* [Best-README-Template](https://github.com/othneildrew/Best-README-Template)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- MARKDOWN LINKS & IMAGES -->
[license-shield]: https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge
[license-url]: https://opensource.org/licenses/MIT
[platform-shield]: https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?style=for-the-badge
[platform-url]: #requirements
[powershell-shield]: https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=for-the-badge&logo=powershell&logoColor=white
[powershell-url]: #requirements
[toolchain-shield]: https://img.shields.io/badge/toolchain-MSYS2%20UCRT64-orange?style=for-the-badge
[toolchain-url]: https://www.msys2.org/
[vcpkg-shield]: https://img.shields.io/badge/packages-vcpkg-brightgreen?style=for-the-badge
[vcpkg-url]: https://vcpkg.io/
[repo-url]: https://github.com/DegorasProjectTeam/DrivEnv-Win
