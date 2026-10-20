# Samples: hand-run checks for a generated drive

Commands to check, on a generated drive, the libraries that have historically been hard to get working on these
toolchains: GStreamer, FFmpeg and curl. Not an automated test suite: after generating a drive, or when you suspect
it has drifted, paste a command and see for yourself.

Step 1 copies this folder to `<drive>:\testing` (unless `environment.install_testing_material` is `false`) and never
overwrites files already there, so notes you add on the drive are kept.

## Run them from the toolchain's own launcher

- The launcher puts the vcpkg tool directories on `PATH` (`tools/<port>/`), so `gst-launch-1.0`, `ffprobe` and the
  rest are not reachable from any other shell.
- A shell with another environment on its `PATH` loads that environment's DLLs. The symptom is misleading: exit code
  `0xC0000139`, "entry point not found", which looks like a broken build rather than a mixed one.

The commands use `$DEVDRIVE_ROOT`, exported by the launcher, so they work on any drive letter.

## Contents

| Folder | What it checks |
| --- | --- |
| `gstreamer/` | element checks, pipelines, RTP send/receive launchers and a real 1080p60 video to demux. The RTP launchers read `GSTREAMER_TEST_HOST_IP`, `_PORT` and `_VIDEO` from the environment |
| `ffmpeg/` | probe and transcode |
| `curl/` | TLS and protocols |
| `vcpkg_overlays/` | two scripts rather than notes: `compare_overlay_vs_upstream.py` decides whether an overlay is still needed after a baseline bump, `verify_overlays.ps1` checks that each overlay did its job (a green build proves nothing about either) |

Each folder has a `<library>_tests.txt` with the commands and what each one proves. Where a command needs something
the drive may not have, the file says so.
