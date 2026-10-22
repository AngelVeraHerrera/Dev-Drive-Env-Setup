# vcpkg overlays

Overlay ports and triplets used by every drive. Each overlay exists because the official port fails or misbehaves
on the MinGW toolchains (clang64 / ucrt64); each is the official port at the drive's baseline plus the smallest delta,
documented in its portfile head or patch header. Update this file in the same commit as the port.

**Policy:** everything is built **dynamic**. The static triplet stays available, but nothing uses it.

## Where they apply

These overlays are made for one environment: the one the Degoras configuration builds
([`config/drivenv-cfg_degoras.json`](../config/drivenv-cfg_degoras.json)). They stay in the repository because every
drive of that kind needs them; outside it they are untested.

| | Validated with |
| --- | --- |
| vcpkg baseline | `3cd21e48a75f67acfef289da52893ce79144aaa1`; each overlay is the official port at this commit plus a delta |
| Triplets | `x64-mingw-clang-dynamic-release`, `x64-mingw-ucrt-dynamic-release` (dynamic, release only) |
| Toolchains | MSYS2 clang64: Clang 23.1.3 with libc++. MSYS2 ucrt64: GCC 16.2.0 with libstdc++. mingw-w64 14.0.0 (r426) |
| Packages | the 29 of the Degoras configuration with its features: Qt 6.11.2, GStreamer 1.28.7, OpenCV 4.14.0, FFmpeg, gRPC, ZeroMQ, the MongoDB drivers... |
| Host | Windows 10 Pro 22H2 (build 19045), NTFS drive. Not yet built on Windows 11 |

Not covered: MSVC triplets (`x64-windows*`), static or debug builds, other baselines or compiler versions, Linux
and macOS. A newer baseline can make an overlay obsolete, or turn it into a downgrade: after every baseline bump run
`compare_overlay_vs_upstream.py` ([Checking the overlays](#checking-the-overlays)) and retire what it reports. To reuse
one overlay elsewhere, take it only if your baseline ships the version in the table below, and read its retire
condition first.

## Active overlays

| Port | Version | Delta | Why | Retire when |
| --- | --- | --- | --- | --- |
| `gstreamer` | 1.28.7 #1 | 12 deltas (portfile head) | MinGW/clang build fixes, `d3d11` forced on, Media Foundation enabled on MinGW, libc++ 23 `<cstdlib>` fix | each delta says its own condition |
| `zeromq` | 4.3.5 #4 | `fix-missing-new-include.patch` | libc++ 23 no longer includes `<new>` transitively (upstream zeromq/libzmq#4911) | vcpkg ships a zeromq newer than 4.3.5 |
| `qtmultimedia` | 6.11.2 #1 | `resonance-audio-missing-istream.patch` | libc++ 23: missing `<istream>` in the bundled resonance-audio | vcpkg ships 6.11.3 or later |
| `opencv4` | 4.14.0 #1 | `0031-missing-iterator-atomic-includes.patch` | libc++ 23: missing `<iterator>` / `<atomic>` (upstream opencv@538e7bf) | vcpkg ships an opencv4 past 4.14.0 |
| `libpq` | 18.4 #1 | `clang-sigsetjmp-cast.diff` | clang's `__builtin_setjmp` takes `void **` | upstream casts the `sigjmp_buf` |
| `libffi` | 3.8.0 #1 | `--enable-symvers=no`, `dll-bindir.diff` | `ld.lld` rejects `--version-script` in COFF mode | the official port builds under clang |
| `fastfeat` | 391d5e9 #5 | one delta, MinGW only | its `.def` names `fastfeat.dll`, CMake builds `libfastfeat.dll` | upstream drops the `lib` prefix on MinGW |
| `vcpkg-qmake` | 2025-05-19 #1 | one delta, MinGW targets | selects GNU make instead of jom/nmake | upstream picks make for MinGW |
| `qt-advanced-docking-system` | 5.1.1 (official: 4.5.0) | version bump; both official patches dropped (5.x reads its version from `project()`), `share/ads` removed | the 5.x line is wanted before vcpkg ships it | vcpkg ships 5.1.1 or later |

The libc++ 23 fixes are upstream commits applied unchanged. Before adding one, the whole module was swept with
`-fsyntax-only` over its `compile_commands.json`, so each overlay fixes every unit of its port, not the first error.

## Layers

`vcpkg.overlay_ports` maps each triplet to an ordered list of layers, and vcpkg takes the first layer holding a
port. `ports/` is shared; `ports.clang/` and `ports.ucrt/` are per-toolchain layers, **empty by design**: a
conditional inside the shared port is preferred to a second copy of a portfile (see their README).

## Triplets

`triplets/` holds the controlled triplets: `x64-mingw-clang-dynamic-release`, `x64-mingw-ucrt-dynamic-release` and
`x64-mingw-ucrt-static-release`. Step 3 checks each against its `.sha256` before installing it on the drive; after
editing one, regenerate its hash with `Utility-Hash_Generator.bat`. Git keeps them byte for byte (`.gitattributes`).

## Retired and deferred

| Ports | Status | Reason |
| --- | --- | --- |
| `glib`, `graphene`, `pango` | retired 2026-08-27 | defect fixed upstream |
| `libbson`, `mongo-c-driver`, `mongo-cxx-driver`, `utf8proc` | retired 2026-08-27 | they forced static linkage, a workaround for older baselines; the baseline versions build dynamic |
| `fastdds`, `fastcdr` | deferred 2026-08-27 | defects still real upstream, but DDS is not in use. Recover the ports from git (`git log --diff-filter=D -- '*ports/fastdds'`) |

The `utf8proc` deprecation warning printed when configuring a mongoc consumer is vcpkg warning about its own shim.
It needs no overlay.

## GStreamer features

| | Features |
| --- | --- |
| Enabled | `nvcodec`, `d3d11` (forced, so a missing dependency is an error), `mediafoundation`, `srt` (without `srtp`), `libde265`, `openh264`, `x264`, `x265` (gpl), `hls`, `openjpeg`, `opus`, `webp`, `libav` |
| Off on purpose | `amfcodec`, `va`, `msdk` (no such hardware); `vulkan`; the Linux-only sinks; the WebRTC stack (`webrtc`, `dtls`, `srtp`); gst `opencv` elements (the opencv library itself is installed); `onnx`; captions; barcodes |
| Not requested | `gl`, `gl-graphene` (no `glimagesink`); add them if the OpenGL samples matter |
| Did not work, retry before believing | `nls` (needs a full gettext), `soup` (libsoup → gnutls → nettle), `aom`, `fluidsynth`, `faad`, `dc1394` |

The authoritative list of what a build enabled is the meson `Build Options:` line in the port's configure log.

## Open problems

- `libgstlibav.dll` does not load ("the specified module could not be found"), although `avcodec-63.dll` and
  `avformat-63.dll` are present and every direct import resolves. Cause not yet known.
- `libgstsvtav1.dll` does not load because `svt-av1` is not in the package list. Harmless.

## Checking the overlays

`drive/samples/vcpkg_overlays/` (copied to `<drive>:\testing\vcpkg_overlays`) has two scripts:
`compare_overlay_vs_upstream.py` decides whether an overlay is still needed after a baseline bump, and
`verify_overlays.ps1` checks on a built drive that each overlay did its job.
