# ---------------------------------------------------------------------------------------------------------------------
# LOCAL OVERLAY of the upstream gstreamer port, rebased on upstream 1.28.6.
#
# NINE FUNCTIONAL deltas from upstream, plus two metadata ones. Re-apply every one of them when bumping to the
# next version, and nothing else -- everything else here is upstream's and must be taken verbatim.
#
# The two metadata deltas, both harmless, listed because this head used to claim "exactly eight ... and nothing
# else" and a full recursive diff disproved it: vcpkg.json gains the "[MILETHOS] ..." suffix on its description,
# and it gains "port-version" where the baseline port has no port-version field at all.
#
# STATUS, re-verified against the 1.28.6 sources on 2026-08-27 (deltas 4 and 5 by running the build, the rest by
# reading the sources with the real MinGW toolchain):
#   still required : 2, 3 (d3d12 half), 4, 5, 6, 7, 8, 9
#   defect gone    : 1 -- see below; kept for now, costs nothing
#   half inert     : 3 (d3d11 half) -- see below; kept deliberately
#
#   9. gstd3d11config.h relocated out of lib/, and the stale -I dropped from gstreamer-d3d11-1.0.pc.
#      UPSTREAM'S OMISSION, not a MinGW issue and not specific to this environment: the baseline port does the same
#      relocation for gst/gl/gstglconfig.h and never learned about d3d11's, whose generated config header is
#      newer. The port installs it, deletes it, and leaves the installed gstd3d11.h including it. Verified in the
#      baseline portfile: zero mentions of gstd3d11config. Worth sending upstream -- it affects MSVC identically.
#
#   1. PATCHES gains gstfilesink_fix_gcc15-2-Rev11.patch.
#      gstfilesink.c redefines off_t to guint64 on Win32 but still maps ftruncate to _chsize, which takes a long.
#      Keep it LF-terminated: vcpkg applies patches with `git apply`, which refuses a CRLF patch against an LF
#      source, while plain `patch` tolerates it. That difference silently cost us an applied patch once already.
#
#      THE DEFECT NO LONGER FIRES, measured 2026-08-27, and this is the only one of the eight in that state. The
#      two #defines are still there (gstfilesink.c:65 and :67), but the file's ONLY ftruncate call is line 687,
#      `ftruncate (fileno (filesink->file), 0)`, and a literal 0 gives _chsize(int,long) nothing to narrow. The
#      PRISTINE 1.28.6 file compiles to a real object under GCC 16.2.0 with -Werror plus the project's own full
#      warning list, in three configurations. The patch was authored against GCC 15.2.0, so a compiler or header
#      change between those revisions is the likely explanation.
#
#      Kept for now because it applies cleanly and costs nothing, and dropping it means renumbering this list.
#      Two things to know if it is ever dropped or repaired. Its 64-bit branch is DEAD CODE: `#if defined(_chsize_s)`
#      is false, because _chsize_s is a function and not a macro, so the patch still calls _chsize(fd,(long)size)
#      and does not deliver the 64-bit safety its comment advertises. And upstream's `#define ftruncate _chsize` is
#      wrong here for an unrelated reason -- mingw-w64 DOES ship a real ftruncate (unistd.h:57, aliased to
#      ftruncate64), so the define discards a 64-bit-capable function for a deprecated 32-bit one. Latent only,
#      while the sole call site truncates to 0.
#
#   2. PATCHES gains d3d11-winrt-probe-mingw.diff.
#      gst-plugins-bad's d3d11 enables its winapi_app (UWP) sources from a probe that does not include
#      <windows.ui.xaml.media.dxinterop.h>, the one header those sources need and the one header mingw-w64 does not
#      ship. WINAPI_PARTITION_APP is true on desktop, so the probe passes and the build then fails on
#      gstd3d11window_corewindow.cpp. The patch adds that header to the probe, so d3d11 keeps its desktop features
#      and only the two UWP window backends are skipped. Preferred over -Dgst-plugins-bad:d3d11=disabled, which
#      would drop screen capture and the win32 window with it. New in 1.28.6: 1.26.5 pinned d3d11=enabled and did
#      not reach this code.
#
#   3. -Dgst-plugins-bad:d3d11-wgc=disabled and -Dgst-plugins-bad:d3d12-wgc=disabled.
#      The Windows Graphics Capture backends use WinRT template types (ABI::Windows::Foundation::TypedEventHandler
#      specialisations, spelled __FITypedEventHandler_2_*) that mingw-w64's generated headers do not provide the way
#      the MSVC Windows SDK does, so gstd3d12graphicscapture.cpp does not compile:
#
#        error: '__FITypedEventHandler_2_Windows__CGraphics__CCapture__C...' does not name a type
#
#      Upstream exposes these as their own feature options, so this is a supported configuration rather than a patch,
#      and the rest of d3d11/d3d12 -- video sink, decoders, converters -- stays enabled. Screen capture is what is
#      given up, which this project does not use: the camera path is appsrc plus encoders and file/network sinks.
#
#      ASYMMETRIC, re-checked 2026-08-27. Only the d3d12 half still has the defect above: gstd3d12graphicscapture.cpp
#      lines 69 and 72 do use those typedefs, mingw-w64 defines none of them, and compiling just those two lines
#      reproduces the quoted error verbatim. On the d3d11 side the only WGC source, gstd3d11winrtcapture.cpp, never
#      touches them and compiles clean, object code and all.
#
#      THE d3d11 HALF IS KEPT ANYWAY, deliberately, after proposing to drop it and being wrong. "No cost" was the
#      premise and it is false. Enabling WGC on d3d11 adds five public GObject properties to d3d11screencapturesrc
#      (window-handle, show-border, capture-api, adapter, window-capture-mode) and registers new GTypes -- a public
#      API change to a shipped element. Worse, it converts a LOUD failure into a SILENT one: today an unsupported
#      DXGI capture falls through to `unsupported:` and raises GST_ELEMENT_ERROR, whereas with WGC enabled that
#      path flips to the WinRT backend and continues, logging an INFO line, into code that resolves every entry
#      point at runtime via g_module_open against mingw-w64's community WinRT vtables. Build-passes /
#      degrades-at-runtime is the exact pattern that cost this project a day on fastfeat.
#
#      Proof the option is doing work rather than sitting inert: objdump on the installed libgstd3d11.dll shows no
#      dwmapi.dll import and none of the strings "Fallback to Windows Graphics Capture" or "RoGetActivationFactory",
#      while d3d11screencapturesrc itself is present. Dropping it changes the binary.
#
#      If it is ever revisited, the bar is a full meson build AND running d3d11screencapturesrc on this toolchain --
#      not a translation unit that compiles.
#
#   4. -Dgstreamer:gst_debug=true, where upstream sets false.
#      Not cosmetic, and not merely a preference. With gst_debug=false, gstinfo.h reaches its
#      `#else /* GST_DISABLE_GST_DEBUG */` branch and issues `#pragma GCC poison gst_debug_log` under
#      `defined(__GNUC__)`. gst-plugins-bad's Direct3D12 code calls gst_debug_log directly, so under MinGW the build
#      dies with "attempt to use poisoned 'gst_debug_log'" -- while MSVC ignores the pragma entirely, which is why
#      upstream CI never sees it: d3d12 is Windows-only and vcpkg's Windows CI is MSVC. The alternative fix is
#      -Dgst-plugins-bad:d3d12=disabled, rejected because it drops the plugin; leaving the debug log compiled in
#      costs binary size and buys pipeline diagnostics we want anyway.
#
#   5. vcpkg.json declares directxmath AND directx-headers under the plugins-bad feature, which upstream does not.
#      These are the two things the MSVC Windows SDK ships and mingw-w64 does NOT, and no port in this graph declares
#      either, so on mingw they are simply absent unless something else happened to install them. DirectXMath is what
#      gst-plugins-bad's d3d11 library needs; DirectX-Headers is what its d3d12 library needs.
#
#      What makes this worth a delta rather than a note is HOW it fails, twice over and never where the problem is.
#
#      Without DirectXMath: d3d11/meson.build probes for it and, not finding it, calls subdir_done() -- SILENTLY.
#      gstd3d11_dep then never exists, cuda/meson.build sees that and calls subdir_done() too, equally silently, and
#      the first consumer to say anything is sys/nvcodec, which is enabled explicitly and therefore errors:
#
#        sys/nvcodec/meson.build:69:4: ERROR: Problem encountered: The nvcodec was enabled explicitly, but required
#        gstcuda dependency is not found
#
#      So the visible symptom names nvcodec and CUDA and has nothing to do with either. No CUDA toolkit is needed to
#      build nvcodec at all: the CUDA entry points are dlopened at runtime through the bundled stub headers in
#      gst-libs/gst/cuda/stub.
#
#      Without DirectX-Headers: d3d12 is skipped the same silent way, and THAT surfaces as a compile error inside
#      nvcodec, because sys/nvcodec/gstnvdecoder.cpp guards its d3d11 include on G_OS_WIN32 (line 58) while nothing
#      before that line has included glib -- unless HAVE_GST_D3D12 is defined, in which case the d3d12 include two
#      lines earlier pulls glib in and G_OS_WIN32 is defined by the time it is tested. With d3d12 off, the include is
#      skipped and the file goes on to use GstD3D11Device and GST_CAPS_FEATURE_MEMORY_D3D11_MEMORY, which it never
#      declared:
#
#        gstnvdecoder.cpp:1665:35: error: 'GstD3D11Device' was not declared in this scope
#
#      That include order is an upstream latent bug and it is NOT fixed here: enabling d3d12 masks it, which is the
#      state that has always worked, and d3d12 is wanted anyway. Worth knowing that it is there, because disabling
#      d3d12 later would bring it straight back wearing an unrelated face.
#
#      Declaring both here means vcpkg installs and orders them, instead of the build depending on whether they are
#      coincidentally present: the environment where this worked had both installed, the one where it failed had
#      neither, and nothing in either configuration said so.
#
#   6. -Dgst-plugins-bad:d3d11=enabled, where upstream leaves it auto.
#      A safety net for exactly the failure delta 5 describes, and restored from a previous environment's overlay,
#      which had it. With d3d11 at "auto", a missing DirectXMath makes the subdirectory bail via subdir_done() and
#      SAY NOTHING; three layers later the build fails somewhere unrelated, wearing CUDA's name. With it "enabled",
#      d3d11/meson.build reaches
#
#        directxmath_dep = dependency('DirectXMath', 'directxmath', required: d3d11_opt)
#
#      with required=true, and meson stops there with a message that actually names DirectXMath.
#
#      A no-op while delta 5 holds -- d3d11 builds either way -- which is the point: it costs nothing now and turns
#      the next silent regression into an error at the line that caused it. This drive's whole video path (the
#      d3d11 decoders, d3d11videosink, d3d11screencapturesrc, and gstcuda behind nvcodec) depends on d3d11 existing,
#      so its silent absence is never acceptable here.
#
#   7. PATCHES gains mediafoundation-winrt-optional-mingw.diff.
#      The same disease delta 2 cures for d3d11, in the plugin next door, and it cost the whole Media Foundation
#      encoder family: no mfh264enc, no mfh265enc, no mfaacenc, no MF decoders. Symptom: they simply are not there.
#
#      On desktop Windows BOTH partition probes succeed -- WINAPI_PARTITION_DESKTOP and WINAPI_PARTITION_APP are true
#      at once -- so mediafoundation intends to build a desktop half and a WinRT half. The WinRT half needs the
#      GstWinRt library, and gst-libs/gst/winrt/meson.build refuses to build for any compiler but MSVC:
#
#        if cxx.get_id() != 'msvc'
#          subdir_done()
#
#      So on mingw that dependency can NEVER be satisfied, and the app branch then abandoned the entire subdirectory
#      -- desktop half included, which needs nothing from WinRT. At "auto" it did so in silence.
#
#      The patch declines only the half that cannot be built, which is what the next block already assumes: three
#      lines later `if winapi_desktop` adds the desktop sources on its own. What is given up is gstmfcapturewinrt.cpp
#      and mediacapturewrapper.cpp -- UWP camera capture, useless to a desktop build. Every encoder and decoder is in
#      the unconditional source list, which is why this costs nothing and returns everything.
#
#      Worth sending upstream rather than carrying forever: it is a real bug on any non-MSVC Windows toolchain, and
#      MSVC is unaffected because there gstwinrt builds and both halves are taken as before.
#
#   8. -Dgst-plugins-bad:svtav1=enabled, with svt-av1 declared as a dependency of plugins-bad.
#      AV1 encoding through SVT-AV1. Upstream leaves this to auto-detection -- dependency('SvtAv1Enc') with no
#      feature option in the vcpkg port -- and auto-detection is precisely what went wrong here: the plugin got
#      built against an svt-av1 that was present only as somebody else's transitive dependency, and dangled the
#      moment that dependency was removed. Declaring the package and demanding the plugin makes both explicit, so
#      a missing svt-av1 is an error naming svt-av1 rather than a plugin that quietly cannot load.
#
#      This depends on the LOCAL fastfeat overlay: without it libSvtAv1Enc.dll can never load, because the fastfeat
#      import library names a DLL that the port does not install. Read that overlay's header before touching either.
#      Enabling this without fastfeat fixed brings back a dangling plugin AND, through avcodec, a dead ffmpeg.
# ---------------------------------------------------------------------------------------------------------------------

vcpkg_from_gitlab(
    GITLAB_URL https://gitlab.freedesktop.org
    OUT_SOURCE_PATH SOURCE_PATH
    REPO gstreamer/gstreamer
    REF "${VERSION}"
    SHA512 b29aaf0d6eb6e28184f7cab904cdab06c2680a65b5353d0f0dd0880df530694a41c0b5b0881390bec95115187891b1895912724bedc401b23d766c99421fe790
    HEAD_REF main
    PATCHES
        fix-clang-cl.patch
        fix-bz2-windows-debug-dependency.patch
        fix-multiple-def.patch
        x264-api-imports.diff
        duplicate-unused.diff
        11894.diff  # https://gitlab.freedesktop.org/gstreamer/gstreamer/-/merge_requests/11894
        no-moltenvk-download.diff
        gstfilesink_fix_gcc15-2-Rev11.patch   # LOCAL, see header
        d3d11-winrt-probe-mingw.diff
        mediafoundation-winrt-optional-mingw.diff          # LOCAL, see header
)

# subprojects that do their own downloads
file(REMOVE_RECURSE "${SOURCE_PATH}/subprojects/moltenvk")

vcpkg_find_acquire_program(FLEX)
vcpkg_find_acquire_program(BISON)
vcpkg_find_acquire_program(NASM)

# gstreamer/meson tends to pick host modules (e.g. libdrm)
# or X11 etc. from brew, so control installation order by
# explicitly cleaning the search root unless set externally.
if((VCPKG_CROSSCOMPILING OR VCPKG_TARGET_IS_OSX) AND "$ENV{PKG_CONFIG}$ENV{PKG_CONFIG_LIBDIR}" STREQUAL "")
    set(ENV{PKG_CONFIG_LIBDIR} "${CURRENT_INSTALLED_DIR}/share/pkgconfig")
endif()

if(VCPKG_TARGET_IS_OSX)
    # In Darwin platform, there can be an old version of `bison`,
    # Which can't be used for `gst-build`. It requires 2.4+
    execute_process(
        COMMAND ${BISON} --version
        OUTPUT_VARIABLE BISON_OUTPUT
    )
    string(REGEX MATCH "([0-9]+)\\.([0-9]+)\\.([0-9]+)" BISON_VERSION "${BISON_OUTPUT}")
    set(BISON_MAJOR ${CMAKE_MATCH_1})
    set(BISON_MINOR ${CMAKE_MATCH_2})
    message(STATUS "Using bison: ${BISON_MAJOR}.${BISON_MINOR}.${CMAKE_MATCH_3}")
    if(NOT (BISON_MAJOR GREATER_EQUAL 2 AND BISON_MINOR GREATER_EQUAL 4))
        message(WARNING "'bison' upgrade is required. Please check the https://stackoverflow.com/a/35161881")
    endif()
endif()

# General features
vcpkg_check_features(OUT_FEATURE_OPTIONS FEATURE_OPTIONS
    FEATURES
        ges             ges
        gpl             gpl
        libav           libav
        nls             nls

        plugins-base    base
        alsa            gst-plugins-base:alsa
        gl              gst-plugins-base:gl
        gl-graphene     gst-plugins-base:gl-graphene
        ogg             gst-plugins-base:ogg
        opus-base       gst-plugins-base:opus
        pango           gst-plugins-base:pango
        vorbis          gst-plugins-base:vorbis
        x11             gst-plugins-base:x11
        x11             gst-plugins-base:xshm

        plugins-good    good
        bzip2           gst-plugins-good:bz2
        cairo           gst-plugins-good:cairo
        flac            gst-plugins-good:flac
        gdk-pixbuf      gst-plugins-good:gdk-pixbuf
        jpeg            gst-plugins-good:jpeg
        mpg123          gst-plugins-good:mpg123
        png             gst-plugins-good:png
        speex           gst-plugins-good:speex
        taglib          gst-plugins-good:taglib
        vpx             gst-plugins-good:vpx

        plugins-ugly    ugly
        x264            gst-plugins-ugly:x264

        plugins-bad     bad
        aes             gst-plugins-bad:aes
        aom             gst-plugins-bad:aom
        asio            gst-plugins-bad:asio
        assrender       gst-plugins-bad:assrender
        bzip2           gst-plugins-bad:bz2
        chromaprint     gst-plugins-bad:chromaprint
        closedcaption   gst-plugins-bad:closedcaption
        colormanagement gst-plugins-bad:colormanagement
        dash            gst-plugins-bad:dash
        dc1394          gst-plugins-bad:dc1394
        dtls            gst-plugins-bad:dtls
        faad            gst-plugins-bad:faad
        fdkaac          gst-plugins-bad:fdkaac
        fluidsynth      gst-plugins-bad:fluidsynth
        gl              gst-plugins-bad:gl
        hls             gst-plugins-bad:hls
        libde265        gst-plugins-bad:libde265
        microdns        gst-plugins-bad:microdns
        modplug         gst-plugins-bad:modplug
        nvcodec         gst-plugins-bad:nvcodec
        openal          gst-plugins-bad:openal
        openh264        gst-plugins-bad:openh264
        openjpeg        gst-plugins-bad:openjpeg
        openmpt         gst-plugins-bad:openmpt
        opus-bad        gst-plugins-bad:opus
        smoothstreaming gst-plugins-bad:smoothstreaming
        sndfile         gst-plugins-bad:sndfile
        soundtouch      gst-plugins-bad:soundtouch
        srt             gst-plugins-bad:srt
        srtp            gst-plugins-bad:srtp
        vulkan          gst-plugins-bad:vulkan
        wayland         gst-plugins-bad:wayland
        webp            gst-plugins-bad:webp
        webrtc          gst-plugins-bad:webrtc
        wildmidi        gst-plugins-bad:wildmidi
        x11             gst-plugins-bad:x11
        x265            gst-plugins-bad:x265
        amd-amf         gst-plugins-bad:amfcodec
)

string(REPLACE "OFF" "disabled" FEATURE_OPTIONS "${FEATURE_OPTIONS}")
string(REPLACE "ON" "enabled" FEATURE_OPTIONS "${FEATURE_OPTIONS}")

# Align with dependencies of feature gl.
if(NOT "gl" IN_LIST FEATURES)
    set(PLUGIN_BASE_GL_API "")
    set(PLUGIN_BASE_WINDOW_SYSTEM "")
    set(PLUGIN_BASE_GL_PLATFORM "")
elseif(VCPKG_TARGET_IS_ANDROID)
    set(PLUGIN_BASE_GL_API gles2)
    set(PLUGIN_BASE_WINDOW_SYSTEM android,egl)
    set(PLUGIN_BASE_GL_PLATFORM egl)
elseif(VCPKG_TARGET_IS_WINDOWS)
    set(PLUGIN_BASE_GL_API opengl)
    set(PLUGIN_BASE_WINDOW_SYSTEM win32)
    set(PLUGIN_BASE_GL_PLATFORM wgl)
else()
    set(PLUGIN_BASE_GL_API opengl)
    set(PLUGIN_BASE_WINDOW_SYSTEM auto)
    set(PLUGIN_BASE_GL_PLATFORM auto)
endif()

# Darwin platforms require MoltenVK for Vulkan support
if(VCPKG_TARGET_IS_APPLE AND "vulkan" IN_LIST FEATURES)
    message(WARNING "You will need to install MoltenVK dependencies to use feature vulkan\n")
endif()

#
# References
#   https://gitlab.freedesktop.org/gstreamer/gstreamer/-/blob/1.20.4/subprojects/gstreamer/meson_options.txt
#   https://gitlab.freedesktop.org/gstreamer/gstreamer/-/blob/1.20.4/subprojects/gst-plugins-base/meson_options.txt
#   https://gitlab.freedesktop.org/gstreamer/gstreamer/-/blob/1.20.4/subprojects/gst-plugins-good/meson_options.txt
#   https://gitlab.freedesktop.org/gstreamer/gstreamer/-/blob/1.20.4/subprojects/gst-plugins-ugly/meson_options.txt
#   https://gitlab.freedesktop.org/gstreamer/gstreamer/-/blob/1.20.4/subprojects/gst-plugins-bad/meson_options.txt
#
# Rationale for added options
#   Common options are added below systematically
#   Feature options are added below only if the feature needs an external dependency
#   Feature options that are dependent on the operating system type (like wasapi or osxaudio) are set to auto
#   Every other feature options are made available if the dependency is available on vcpkg and if the plugin has managed to build during tests
#

vcpkg_configure_meson(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        ${FEATURE_OPTIONS}

        # GStreamer subprojects
        -Ddevtools=disabled
        -Drtsp_server=disabled
        -Drs=disabled
        -Dgst-examples=disabled
        # Bindings
        -Dpython=disabled
        -Dsharp=disabled
        # External subprojects
        -Dtls=disabled
        -Dlibnice=disabled
        # Other options
        -Dbuild-tools-source=system
        -Dbenchmarks=disabled
        -Dorc=disabled # gstreamer requires a specific version of orc which is not available in vcpkg
        -Dqt5=disabled
        -Dqt6=disabled
        # Common options
        -Dtests=disabled
        -Dexamples=disabled
        -Dintrospection=disabled
        -Ddoc=disabled
        -Dgtk_doc=disabled

        # gstreamer
        -Dgstreamer:check=disabled
        -Dgstreamer:libunwind=disabled
        -Dgstreamer:libdw=disabled
        -Dgstreamer:dbghelp=disabled
        -Dgstreamer:bash-completion=disabled
        -Dgstreamer:coretracers=disabled
        -Dgstreamer:ptp-helper=disabled  # needs rustc toolchain setup
        # gst-plugins-base
        -Dgst-plugins-base:gl_api=${PLUGIN_BASE_GL_API}
        -Dgst-plugins-base:gl_winsys=${PLUGIN_BASE_WINDOW_SYSTEM}
        -Dgst-plugins-base:gl_platform=${PLUGIN_BASE_GL_PLATFORM}
        -Dgst-plugins-base:cdparanoia=disabled
        -Dgst-plugins-base:libvisual=disabled
        -Dgst-plugins-base:theora=disabled
        -Dgst-plugins-base:tremor=disabled
        -Dgst-plugins-base:xvideo=disabled
        # gst-plugins-good
        -Dgst-plugins-good:aalib=disabled
        -Dgst-plugins-good:directsound=auto
        -Dgst-plugins-good:dv=disabled
        -Dgst-plugins-good:dv1394=disabled
        -Dgst-plugins-good:gtk3=disabled # GTK version 3 only
        -Dgst-plugins-good:jack=disabled
        -Dgst-plugins-good:lame=disabled
        -Dgst-plugins-good:libcaca=disabled
        -Dgst-plugins-good:oss=disabled
        -Dgst-plugins-good:oss4=disabled
        -Dgst-plugins-good:osxaudio=auto
        -Dgst-plugins-good:osxvideo=auto
        -Dgst-plugins-good:pulse=disabled # Port pulseaudio depends on gstreamer
        -Dgst-plugins-good:qt5=disabled
        -Dgst-plugins-good:shout2=disabled
        #-Dgst-plugins-good:soup=disabled
        -Dgst-plugins-good:twolame=disabled
        -Dgst-plugins-good:waveform=auto
        -Dgst-plugins-good:wavpack=disabled # Error during plugin build
        # gst-plugins-ugly
        -Dgst-plugins-ugly:a52dec=disabled
        -Dgst-plugins-ugly:cdio=disabled
        -Dgst-plugins-ugly:dvdread=disabled
        -Dgst-plugins-ugly:mpeg2dec=disabled # libmpeg2 not found
        -Dgst-plugins-ugly:sidplay=disabled
        # gst-plugins-bad
        -Dgst-plugins-bad:avtp=disabled
        -Dgst-plugins-bad:androidmedia=auto
        -Dgst-plugins-bad:applemedia=auto
        -Dgst-plugins-bad:bluez=disabled
        -Dgst-plugins-bad:bs2b=disabled
        -Dgst-plugins-bad:curl=disabled # Error during plugin build
        -Dgst-plugins-bad:curl-ssh2=disabled
        -Dgst-plugins-bad:d3dvideosink=auto
        -Dgst-plugins-bad:d3d11=enabled       # LOCAL, see header
        -Dgst-plugins-bad:d3d11-wgc=disabled  # LOCAL, see header
        -Dgst-plugins-bad:d3d12-wgc=disabled  # LOCAL, see header
        -Dgst-plugins-bad:decklink=disabled
        -Dgst-plugins-bad:directfb=disabled
        -Dgst-plugins-bad:directsound=auto
        -Dgst-plugins-bad:dts=disabled
        -Dgst-plugins-bad:dvb=auto
        -Dgst-plugins-bad:faac=disabled
        -Dgst-plugins-bad:fbdev=auto
        -Dgst-plugins-bad:flite=disabled
        -Dgst-plugins-bad:gl=auto
        -Dgst-plugins-bad:gme=disabled
        -Dgst-plugins-bad:gs=disabled # Error during plugin configuration (abseil pkg-config file missing)
        -Dgst-plugins-bad:gsm=disabled
        -Dgst-plugins-bad:hls-crypto=openssl
        -Dgst-plugins-bad:ipcpipeline=auto
        -Dgst-plugins-bad:iqa=disabled
        -Dgst-plugins-bad:kms=disabled
        -Dgst-plugins-bad:ladspa=disabled
        -Dgst-plugins-bad:ldac=disabled
        -Dgst-plugins-bad:lv2=disabled # Error during plugin configuration (lilv pkg-config file missing)
        -Dgst-plugins-bad:mediafoundation=auto
        -Dgst-plugins-bad:mpeg2enc=disabled
        -Dgst-plugins-bad:mplex=disabled
        -Dgst-plugins-bad:msdk=disabled
        -Dgst-plugins-bad:musepack=disabled
        -Dgst-plugins-bad:neon=disabled
        -Dgst-plugins-bad:onnx=disabled # libonnxruntime not found
        -Dgst-plugins-bad:openaptx=disabled
        -Dgst-plugins-bad:opencv=disabled # opencv not found
        -Dgst-plugins-bad:openexr=disabled # OpenEXR::IlmImf target not found
        -Dgst-plugins-bad:openni2=disabled # libopenni2 not found
        -Dgst-plugins-bad:opensles=disabled
        -Dgst-plugins-bad:qroverlay=disabled
        -Dgst-plugins-bad:resindvd=disabled
        -Dgst-plugins-bad:rsvg=disabled # librsvg-2.0 not found
        -Dgst-plugins-bad:rtmp=disabled # librtmp not found
        -Dgst-plugins-bad:sbc=disabled
        -Dgst-plugins-bad:sctp=auto
        -Dgst-plugins-bad:shm=disabled
        -Dgst-plugins-bad:spandsp=disabled
        -Dgst-plugins-bad:svtav1=enabled      # LOCAL, see header
        -Dgst-plugins-bad:svthevcenc=disabled
        -Dgst-plugins-bad:teletext=disabled
        -Dgst-plugins-bad:tinyalsa=disabled
        -Dgst-plugins-bad:transcode=disabled
        -Dgst-plugins-bad:ttml=disabled
        -Dgst-plugins-bad:uvch264=disabled
        -Dgst-plugins-bad:va=disabled
        -Dgst-plugins-bad:voaacenc=disabled
        -Dgst-plugins-bad:voamrwbenc=disabled
        -Dgst-plugins-bad:wasapi=auto
        -Dgst-plugins-bad:wasapi2=auto
        -Dgst-plugins-bad:wayland=auto
        -Dgst-plugins-bad:winks=disabled
        -Dgst-plugins-bad:winscreencap=auto
        -Dgst-plugins-bad:zbar=disabled # Error during plugin build
        -Dgst-plugins-bad:zxing=disabled # Error during plugin build
        -Dgst-plugins-bad:wpe=disabled
        -Dgst-plugins-bad:magicleap=disabled
        -Dgst-plugins-bad:v4l2codecs=disabled
        -Dgst-plugins-bad:isac=disabled
    OPTIONS_RELEASE
        -Dglib_debug=disabled
        -Dglib_assert=false
        -Dglib_checks=false
        -Dgstreamer:gst_debug=true    # LOCAL, see header
        -Dgstreamer:extra-checks=disabled
    ADDITIONAL_BINARIES
        flex='${FLEX}'
        bison='${BISON}'
        nasm='${NASM}'
        glib-genmarshal='${CURRENT_HOST_INSTALLED_DIR}/tools/glib/glib-genmarshal'
        glib-mkenums='${CURRENT_HOST_INSTALLED_DIR}/tools/glib/glib-mkenums'
        glslc='${CURRENT_HOST_INSTALLED_DIR}/tools/shaderc/glslc${VCPKG_HOST_EXECUTABLE_SUFFIX}'
)

vcpkg_install_meson()

# Remove duplicated GL headers (we already have `opengl-registry`)
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/include/KHR"
                    "${CURRENT_PACKAGES_DIR}/include/GL"
)

if("gl" IN_LIST FEATURES)
    file(RENAME "${CURRENT_PACKAGES_DIR}/lib/gstreamer-1.0/include/gst/gl/gstglconfig.h"
                "${CURRENT_PACKAGES_DIR}/include/gstreamer-1.0/gst/gl/gstglconfig.h"
    )
endif()

# NINTH DELTA. The same relocation for d3d11's generated config header, which upstream's port does for gl (just
# above) and forgot for d3d11. Two generated headers declare install_dir = libdir/gstreamer-1.0/include:
# gst/gl/gstglconfig.h and gst/d3d11/gstd3d11config.h. The gl one is moved here and its -I is stripped from the .pc
# further down; the d3d11 one is left where it is, and then the file(REMOVE_RECURSE) below deletes that whole
# directory -- while the installed gst/d3d11/gstd3d11.h line 28 still does #include <gst/d3d11/gstd3d11config.h>.
#
# Nothing notices at build time. It breaks only a C++ consumer that includes the d3d11 helper API directly, which
# is exactly what a camera pipeline wants to do, and it breaks with a bare "No such file or directory" naming a
# header that the port did install and then removed.
#
# Guarded on EXISTS rather than on a feature, because d3d11 comes from plugins-bad and is Windows-only, so the
# feature test would have to duplicate the platform logic that produced the file in the first place.
# MAKE_DIRECTORY first, because file(RENAME) requires the destination's parent to exist and will hard-error if it
# does not. On this drive both overlay triplets are VCPKG_BUILD_TYPE release, so the debug branch never runs and the
# release parent always exists -- but the whole point of writing this to be upstreamable is that neither holds
# elsewhere. Creating an existing directory is a no-op.
if(EXISTS "${CURRENT_PACKAGES_DIR}/lib/gstreamer-1.0/include/gst/d3d11/gstd3d11config.h")
    file(MAKE_DIRECTORY "${CURRENT_PACKAGES_DIR}/include/gstreamer-1.0/gst/d3d11")
    file(RENAME "${CURRENT_PACKAGES_DIR}/lib/gstreamer-1.0/include/gst/d3d11/gstd3d11config.h"
                "${CURRENT_PACKAGES_DIR}/include/gstreamer-1.0/gst/d3d11/gstd3d11config.h"
    )
endif()
if(EXISTS "${CURRENT_PACKAGES_DIR}/debug/lib/gstreamer-1.0/include/gst/d3d11/gstd3d11config.h")
    file(MAKE_DIRECTORY "${CURRENT_PACKAGES_DIR}/debug/include/gstreamer-1.0/gst/d3d11")
    file(RENAME "${CURRENT_PACKAGES_DIR}/debug/lib/gstreamer-1.0/include/gst/d3d11/gstd3d11config.h"
                "${CURRENT_PACKAGES_DIR}/debug/include/gstreamer-1.0/gst/d3d11/gstd3d11config.h"
    )
endif()

if(NOT VCPKG_LIBRARY_LINKAGE STREQUAL "static") # AND tools
    list(APPEND GST_BIN_TOOLS
        gst-inspect-1.0
        gst-launch-1.0
        gst-stats-1.0
        gst-typefind-1.0
    )
    list(APPEND GST_LIBEXEC_TOOLS
        gst-completion-helper
        gst-plugin-scanner
    )
    if("ges" IN_LIST FEATURES)
        list(APPEND GST_BIN_TOOLS
            ges-launch-1.0
        )
    endif()
    if("plugins-base" IN_LIST FEATURES)
        list(APPEND GST_BIN_TOOLS
            gst-device-monitor-1.0
            gst-discoverer-1.0
            gst-play-1.0
        )
    endif()
    if("plugins-bad" IN_LIST FEATURES)
        list(APPEND GST_BIN_TOOLS
            gst-transcoder-1.0
        )
    endif()
endif()


if(GST_BIN_TOOLS)
    vcpkg_copy_tools(TOOL_NAMES ${GST_BIN_TOOLS} AUTO_CLEAN)
endif()

if(GST_LIBEXEC_TOOLS)
    vcpkg_copy_tools(TOOL_NAMES ${GST_LIBEXEC_TOOLS} SEARCH_DIR "${CURRENT_PACKAGES_DIR}/libexec/gstreamer-1.0" AUTO_CLEAN)
endif()

file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/share"
                    "${CURRENT_PACKAGES_DIR}/debug/libexec"
                    "${CURRENT_PACKAGES_DIR}/debug/lib/gstreamer-1.0/include"
                    "${CURRENT_PACKAGES_DIR}/libexec"
                    "${CURRENT_PACKAGES_DIR}/lib/gstreamer-1.0/include"
                    "${CURRENT_PACKAGES_DIR}/share/gdb"
)

if(VCPKG_LIBRARY_LINKAGE STREQUAL "static")
    # Move plugin pkg-config files
    file(GLOB pc_files "${CURRENT_PACKAGES_DIR}/lib/gstreamer-1.0/pkgconfig/*")
    file(COPY ${pc_files} DESTINATION "${CURRENT_PACKAGES_DIR}/lib/pkgconfig")
    file(GLOB pc_files_dbg "${CURRENT_PACKAGES_DIR}/debug/lib/gstreamer-1.0/pkgconfig/*")
    file(COPY ${pc_files_dbg} DESTINATION "${CURRENT_PACKAGES_DIR}/debug/lib/pkgconfig")
    file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/lib/gstreamer-1.0/pkgconfig/"
                        "${CURRENT_PACKAGES_DIR}/lib/gstreamer-1.0/pkgconfig/")

    file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/bin"
                        "${CURRENT_PACKAGES_DIR}/bin"
    )
    set(PREFIX "${CMAKE_SHARED_LIBRARY_PREFIX}")
    set(SUFFIX "${CMAKE_SHARED_LIBRARY_SUFFIX}")
    file(REMOVE "${CURRENT_PACKAGES_DIR}/debug/lib/${PREFIX}gstreamer-full-1.0${SUFFIX}"
                "${CURRENT_PACKAGES_DIR}/lib/${PREFIX}gstreamer-full-1.0${SUFFIX}"
    )
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/include/gstreamer-1.0/gst/gstconfig.h" "!defined(GST_STATIC_COMPILATION)" "0")
endif()

if(VCPKG_LIBRARY_LINKAGE STREQUAL "dynamic")
    # move plugins to ${prefix}/plugins/${PORT} instead of ${prefix}/lib/gstreamer-1.0
    if(NOT VCPKG_BUILD_TYPE)
        file(GLOB DBG_BINS "${CURRENT_PACKAGES_DIR}/debug/lib/gstreamer-1.0/${CMAKE_SHARED_LIBRARY_PREFIX}*${CMAKE_SHARED_LIBRARY_SUFFIX}"
                           "${CURRENT_PACKAGES_DIR}/debug/lib/gstreamer-1.0/*.pdb"
        )
        file(COPY ${DBG_BINS} DESTINATION "${CURRENT_PACKAGES_DIR}/debug/plugins/${PORT}")
    endif()
    file(GLOB REL_BINS "${CURRENT_PACKAGES_DIR}/lib/gstreamer-1.0/${CMAKE_SHARED_LIBRARY_PREFIX}*${CMAKE_SHARED_LIBRARY_SUFFIX}"
                       "${CURRENT_PACKAGES_DIR}/lib/gstreamer-1.0/*.pdb"
    )
    file(COPY ${REL_BINS} DESTINATION "${CURRENT_PACKAGES_DIR}/plugins/${PORT}")
    file(REMOVE ${DBG_BINS} ${REL_BINS})
    if(NOT VCPKG_TARGET_IS_WINDOWS)
        file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/lib/gstreamer-1.0" "${CURRENT_PACKAGES_DIR}/lib/gstreamer-1.0")
    endif()

    set(_file "${CURRENT_PACKAGES_DIR}/debug/lib/pkgconfig/gstreamer-1.0.pc")
    if(EXISTS "${_file}")
        file(READ "${_file}" _contents)
        string(REPLACE [[toolsdir=${exec_prefix}/bin]] "toolsdir=\${prefix}/../tools/${PORT}" _contents "${_contents}")
        string(REPLACE [[pluginscannerdir=${libexecdir}/gstreamer-1.0]] "pluginscannerdir=\${prefix}/../tools/${PORT}" _contents "${_contents}")
        string(REPLACE [[pluginsdir=${libdir}/gstreamer-1.0]] "pluginsdir=\${prefix}/plugins/${PORT}" _contents "${_contents}")
        file(WRITE "${_file}" "${_contents}")
    endif()

    set(_file "${CURRENT_PACKAGES_DIR}/lib/pkgconfig/gstreamer-1.0.pc")
    if(EXISTS "${_file}")
        file(READ "${_file}" _contents)
        string(REPLACE [[toolsdir=${exec_prefix}/bin]] "toolsdir=\${prefix}/tools/${PORT}" _contents "${_contents}")
        string(REPLACE [[pluginscannerdir=${libexecdir}/gstreamer-1.0]] "pluginscannerdir=\${prefix}/tools/${PORT}" _contents "${_contents}")
        string(REPLACE [[pluginsdir=${libdir}/gstreamer-1.0]] "pluginsdir=\${prefix}/plugins/${PORT}" _contents "${_contents}")
        file(WRITE "${_file}" "${_contents}")
    endif()
endif()

if(EXISTS "${CURRENT_PACKAGES_DIR}/lib/pkgconfig/gstreamer-gl-1.0.pc")
  vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/lib/pkgconfig/gstreamer-gl-1.0.pc" [[-I${libdir}/gstreamer-1.0/include]] "")
endif()
if(EXISTS "${CURRENT_PACKAGES_DIR}/debug/lib/pkgconfig/gstreamer-gl-1.0.pc")
  vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/debug/lib/pkgconfig/gstreamer-gl-1.0.pc" [[-I${libdir}/gstreamer-1.0/include]] "")
endif()

# NINTH DELTA, second half. gstreamer-d3d11-1.0.pc is the ONE remaining .pc that still asks for
# -I${libdir}/gstreamer-1.0/include, a directory this portfile deletes. Harmless as a missing include path, but it
# is also the reason the missing header went unnoticed: the .pc advertises where it used to be.
if(EXISTS "${CURRENT_PACKAGES_DIR}/lib/pkgconfig/gstreamer-d3d11-1.0.pc")
  vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/lib/pkgconfig/gstreamer-d3d11-1.0.pc" [[-I${libdir}/gstreamer-1.0/include]] "")
endif()
if(EXISTS "${CURRENT_PACKAGES_DIR}/debug/lib/pkgconfig/gstreamer-d3d11-1.0.pc")
  vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/debug/lib/pkgconfig/gstreamer-d3d11-1.0.pc" [[-I${libdir}/gstreamer-1.0/include]] "")
endif()

vcpkg_fixup_pkgconfig()

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE")
