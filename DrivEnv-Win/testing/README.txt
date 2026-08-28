=======================================================================
TESTING MATERIAL FOR A GENERATED ENVIRONMENT
=======================================================================

What this is
-----------------------------------------------------------------------
Small, hand-runnable checks for the libraries that have historically
been the troublesome ones to get working on this toolchain: gstreamer,
ffmpeg, curl. Not a test suite and not automated -- the point is that
somebody who has just generated an environment, or who suspects it has
drifted, can paste a command and see for themselves.

vcpkg_overlays/ is the exception to "paste a command": two scripts, one
that decides whether an overlay port is still needed after a baseline
bump, and one that checks the overlays actually did their job. They are
scripts rather than notes because every defect they cover is invisible
to the build -- a green compile proves nothing about any of them.

This whole tree is copied to <drive>:/testing when the environment is
created, so it travels with the drive rather than living only here.


How to run any of it
-----------------------------------------------------------------------
FROM THE ENVIRONMENT'S OWN LAUNCHER, and this matters more than it
looks. Two reasons:

  * The vcpkg tool directories are put on PATH by the launcher, not by
    the .env file: vcpkg gives every port its own tools/<port>/
    directory, so gst-launch-1.0, ffprobe and the rest are not reachable
    otherwise.

  * Running these binaries from a shell that has ANOTHER environment on
    its PATH picks up that environment's DLLs. The failure is not subtle
    but it is misleading: exit code 0xC0000139, "entry point not found",
    which reads like a broken build rather than a mixed one.

$DEVDRIVE_ROOT is exported by the launcher, so the commands below use it
instead of a hard-coded drive letter and work on any generated drive.


Layout
-----------------------------------------------------------------------
  gstreamer/    element checks, pipelines, RTP send/receive launchers,
                and a real 1080p60 video to demux rather than synthesise
                (the launchers read GSTREAMER_TEST_HOST_IP, _PORT and
                _VIDEO from the environment, so the destination is set
                once in the configuration rather than per script)
  ffmpeg/       probe and transcode checks
  curl/         TLS and protocol checks

Each folder has one <library>_tests.txt of commands with a note on what
each one proves. Where a command needs something this environment may
not have, the file says so rather than leaving you to find out.
