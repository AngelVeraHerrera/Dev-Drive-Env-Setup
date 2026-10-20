# `ports.ucrt` — the UCRT/GCC-only overlay layer

This directory is **intentionally empty**, and there is currently nothing that needs to go in it.

It exists as the counterpart to `ports.clang`, so that a dual-toolchain configuration can name a layer for each
side symmetrically:

```json
"overlay_ports": [
  { "triplet": "x64-mingw-clang-dynamic-release", "layers": ["ports.clang", "ports"] },
  { "triplet": "x64-mingw-ucrt-dynamic-release",  "layers": ["ports.ucrt",  "ports"] },
  { "triplet": "*",                               "layers": ["ports"] }
]
```

`ports.clang/README.md` explains how layers resolve, why a layer is usually the wrong tool, and what did and did
not turn out to need compiler-specific treatment. Read that one; everything there applies here symmetrically.

The short version: every delta the UCRT/GCC environment has needed so far is either a triplet setting or a patch
that is correct for both compilers, so it lives in the shared `ports/` layer. A layer here would mean a second
copy of a portfile to keep in step through every baseline bump.

**A named layer that does not exist is a hard error in step 3, not an empty layer.** That is deliberate: treating
a missing layer as empty would mean a port the configuration expects to be overridden quietly comes from upstream
instead. So this README is also what keeps the directory in git — git does not track empty directories, and a
file at a layer's root is ignored by the installer, which only looks at subdirectories.
