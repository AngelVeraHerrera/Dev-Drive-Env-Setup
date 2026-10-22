# vcpkg overlays

Two different things live here:

| Folder | What it is | Used by |
| --- | --- | --- |
| `triplets/` | The generator's controlled triplets | every drive |
| `degoras/` | Overlay ports for one environment, the Degoras one | only a configuration that names it in `vcpkg.overlay_root` |

## Triplets

`triplets/` holds `x64-mingw-clang-dynamic-release` and `x64-mingw-ucrt-dynamic-release`, which the drives build
with, and their static counterparts `x64-mingw-clang-static-release` and `x64-mingw-ucrt-static-release`, kept as a
capability: everything is built **dynamic** by policy, and nothing uses them. Step 3 checks each against its
`.sha256` before installing it in `<drive>:\overlays\triplets`; after editing one, regenerate its hash with
`Utility-Hash_Generator.bat`. Git keeps them byte for byte (`.gitattributes`).

## Overlay port sets

An overlay port replaces the registry's port of the same name. vcpkg's ports are written for MSVC first, so on these
MinGW toolchains some need a fix; which ones depends on the baseline, the compilers and the packages. So overlay
ports come in **sets**, each made for one environment, and **none is required**: without `vcpkg.overlay_root`,
every package comes from the registry as published.

A configuration names a set and, per triplet, the layers (folders of the set) to search:

```json
"overlay_root": "vcpkg_overlays/degoras",
"overlay_ports": [
  { "triplet": "x64-mingw-clang-dynamic-release", "layers": ["ports.clang", "ports"] },
  { "triplet": "*",                               "layers": ["ports"] }
]
```

- `overlay_root`: relative to the generator, or absolute (a set can live beside its configuration, in another
  repository).
- `overlay_ports`: vcpkg takes the first layer holding a port. Absent: `["ports"]` for every triplet.

Step 3 copies the layers to `<drive>:\overlays\<layer>` and reconciles them: a port removed from the set disappears
from the drive too, since an overlay left behind would keep shadowing the registry.

| Set | Made for |
| --- | --- |
| [`degoras/`](degoras/README.md) | vcpkg baseline `3cd21e48`, Clang 23.1.3 and GCC 16.2.0, the Degoras packages |

To start a set of your own, copy one, keep only what your environment needs, and point `overlay_root` at it.

## Checking the overlays

`drive/samples/vcpkg_overlays/` (copied to `<drive>:\testing\vcpkg_overlays`) has two scripts:
`compare_overlay_vs_upstream.py` decides whether an overlay is still needed after a baseline bump, and
`verify_overlays.ps1` checks on a built drive that each overlay did its job.
