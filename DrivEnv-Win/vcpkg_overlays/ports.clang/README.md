# `ports.clang` — the clang-only overlay layer

This directory is **intentionally empty**, and the goal is to keep it that way.

## What a layer is

`vcpkg.overlay_ports` in the configuration maps a triplet to an ordered list of layers. Step 4 passes them to
vcpkg as repeated `--overlay-ports=` arguments, and vcpkg takes the **first** layer that contains a port. So a
port placed here wins over the same port in `ports/` — but only for the triplets that list this layer.

```json
"overlay_ports": [
  { "triplet": "x64-mingw-clang-dynamic-release", "layers": ["ports.clang", "ports"] },
  { "triplet": "*",                               "layers": ["ports"] }
]
```

The resolution happens **per port**, not once per run, which is what allows one vcpkg tree to hold a GCC triplet
and a clang triplet with different overlays. The overlay path is an argument to each vcpkg invocation, and step 4
invokes vcpkg once per port.

## Why you probably should not put anything here

A layer holds a **whole portfile**. Two copies of a 500-line portfile then have to be kept in step through every
baseline bump, and they will not be — the copy nobody is currently debugging goes stale silently, and the failure
appears months later as "it works on the other triplet".

Prefer a **conditional inside the shared port** for anything short of wholesale different treatment. The
`gstreamer` overlay does exactly that:

```cmake
if(VCPKG_C_COMPILER MATCHES "clang" OR TARGET_TRIPLET MATCHES "clang")
```

Note `TARGET_TRIPLET`, not `VCPKG_TARGET_TRIPLET` — the latter does not exist in portfile scope, it is a
project-side variable, and a test against it silently reads empty and takes the `else` branch.

## What actually needed compiler-specific treatment

Bringing up a clang64 environment turned up eight incompatibilities. Five were settings, and live in the triplet:
`lt_cv_deplibs_check_method=pass_all`, `lt_cv_sys_max_cmd_len=32000`, `-lclang_rt.builtins-x86_64`,
`-D__USE_MINGW_ANSI_STDIO=1`, and the `gcc`/`g++` driver aliases.

Three were source-level. Of those, **two turned out to be upstream bugs whose fixes are correct for GCC as well**:

- `gstreamer`'s `GstMFDShowPinInfo::operator<` was not `const`, so `std::sort` could not use it through libc++'s
  default comparator. A comparison operator that does not modify its operand should be const on any standard
  library.
- `libpq`'s `sigsetjmp` macro passed an `intptr_t[5]` to `__builtin_setjmp`, whose clang signature is `void **`.
  The cast is harmless under GCC — verified by compiling and running the same probe with both compilers.

Both therefore live in the **shared** `ports/` layer, and there is nothing to keep in step.

Only one was genuinely clang-specific: `libffi` enables ELF symbol versioning and emits
`-Wl,--version-script`, which `ld.lld` rejects in COFF mode. Even that is expressed as a `--enable-symvers=no`
option in the shared overlay rather than a separate copy of the port.

**So: reach for this layer when a port needs wholesale different treatment, and read the two paragraphs above
first.** An empty layer costs nothing; a duplicated portfile costs attention every time the baseline moves.
