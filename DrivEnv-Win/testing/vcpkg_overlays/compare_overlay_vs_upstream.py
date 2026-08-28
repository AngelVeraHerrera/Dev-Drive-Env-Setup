# =====================================================================
# WHAT IS GENUINELY LOCAL IN EACH OVERLAY PORT
# =====================================================================
#
# Run this at every vcpkg baseline bump, BEFORE deciding whether an
# overlay is still needed.
#
# WHY IT EXISTS, because the obvious method gives the wrong answer.
# Diffing an overlay against TODAY's baseline port conflates two
# unrelated things: a change somebody made here on purpose, and mere
# version drift. An overlay pinning an older version differs from the
# current port in dozens of lines nobody here ever wrote, so the diff
# buries the one line that matters.
#
# This compares each overlay against the OFFICIAL port at the SAME
# version, recovered from vcpkg's own git history. Whatever survives
# that comparison is genuinely local, and that is the only thing worth
# reading.
#
# It earned its keep: it turned "glib carries libintl.patch for reasons
# unknown" and "pango is a stale fork, no reason recorded" into "each of
# them deletes one dependency and changes nothing else". Both were
# retired on the strength of that, having been documented as mysteries
# for months.
#
# WHAT IT DOES NOT DO: decide anything. A surviving delta still has to
# be checked against the CURRENT sources -- the defect it works around
# may have been fixed upstream while the delta still applies cleanly.
# See installation/vcpkg_overlays.txt for what that looked like in
# practice.
#
# Usage, from the environment's own launcher:
#
#     python compare_overlay_vs_upstream.py
#     python compare_overlay_vs_upstream.py --overlays D:/overlays/ports
#
# Defaults come from the environment: VCPKG_ROOT and VCPKG_OVERLAY_PORTS.
# =====================================================================

import argparse
import io
import json
import os
import subprocess
import sys


def find_git():
    """The drive's own git first, then MSYS2's, then PATH. Same order the generator uses."""
    mingw = os.environ.get('MINGW_ROOT', '')
    msys = os.environ.get('MSYS2_ROOT', '')
    for c in (os.path.join(mingw, 'bin', 'git.exe') if mingw else None,
              os.path.join(msys, 'usr', 'bin', 'git.exe') if msys else None):
        if c and os.path.isfile(c):
            return c
    return 'git'


def version_string(doc):
    v = (doc.get('version') or doc.get('version-semver') or doc.get('version-string')
         or doc.get('version-date') or '?')
    pv = doc.get('port-version', 0)
    return '%s%s' % (v, ('#%d' % pv) if pv else '')


def normalise(blob):
    """Line endings and surrounding blank lines are never the point here."""
    return blob.replace(b'\r\n', b'\n').strip() if blob is not None else None


def read_json(path):
    try:
        return json.load(io.open(path, encoding='utf-8-sig'))
    except Exception:
        return None


def files_under(root):
    out = {}
    for base, _dirs, names in os.walk(root):
        rel = os.path.relpath(base, root).replace('\\', '/')
        for n in names:
            key = n if rel == '.' else '%s/%s' % (rel, n)
            out[key] = normalise(io.open(os.path.join(base, n), 'rb').read())
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--vcpkg', default=os.environ.get('VCPKG_ROOT', ''),
                    help='vcpkg checkout (default: %%VCPKG_ROOT%%)')
    ap.add_argument('--overlays', default=os.environ.get('VCPKG_OVERLAY_PORTS', ''),
                    help='overlay ports directory (default: %%VCPKG_OVERLAY_PORTS%%)')
    ap.add_argument('--port', action='append', default=[],
                    help='only this port; repeatable. Default: every overlay found')
    args = ap.parse_args()

    if not args.vcpkg or not os.path.isdir(args.vcpkg):
        sys.exit('VCPKG_ROOT is not set or not a directory. Run this from the environment launcher.')
    if not args.overlays or not os.path.isdir(args.overlays):
        sys.exit('VCPKG_OVERLAY_PORTS is not set or not a directory.')

    git = find_git()
    ports_dir = os.path.join(args.vcpkg, 'ports')

    def git_out(*a):
        return subprocess.run([git, '-C', args.vcpkg] + list(a), capture_output=True).stdout

    head = git_out('rev-parse', '--short', 'HEAD').decode('ascii', 'replace').strip()
    print('vcpkg baseline: %s' % (head or '(unknown)'))
    print('overlays      : %s' % args.overlays)
    print('')

    wanted = args.port or sorted(d for d in os.listdir(args.overlays)
                                 if os.path.isfile(os.path.join(args.overlays, d, 'vcpkg.json')))

    for port in wanted:
        overlay_dir = os.path.join(args.overlays, port)
        overlay_json = read_json(os.path.join(overlay_dir, 'vcpkg.json'))
        if overlay_json is None:
            print('%s: no readable vcpkg.json, skipped' % port)
            continue

        want = version_string(overlay_json)
        upstream_dir = os.path.join(ports_dir, port)
        print('=' * 71)
        print('%s   overlay %s' % (port, want))

        if not os.path.isdir(upstream_dir):
            print('  NO UPSTREAM PORT of that name -- entirely local, nothing to compare')
            print('')
            continue

        # Walk the port's own history newest-first looking for that exact version, then for the same
        # version at any port-version. A homemade port-version is itself evidence of local work.
        commits = git_out('log', '--format=%H', '--', 'ports/%s/vcpkg.json' % port).decode().split()
        exact = None
        same_version = None
        for c in commits:
            raw = git_out('show', '%s:ports/%s/vcpkg.json' % (c, port))
            if not raw:
                continue
            try:
                doc = json.loads(raw.decode('utf-8-sig'))
            except Exception:
                continue
            got = version_string(doc)
            if got == want and exact is None:
                exact = c
            if got.split('#')[0] == want.split('#')[0] and same_version is None:
                same_version = (c, doc.get('port-version', 0))
            if exact:
                break

        if exact:
            base, note = exact, 'same version and port-version'
        elif same_version:
            base = same_version[0]
            note = 'forked from port-version %s; the overlay bumped it, which is itself a local change' % same_version[1]
        else:
            print('  this version never existed upstream -- treat the whole port as local')
            print('')
            continue

        print('  compared against upstream %s (%s)' % (base[:10], note))

        prefix = 'ports/%s/' % port
        upstream = {}
        for line in git_out('ls-tree', '-r', '--name-only', base, prefix).decode().split('\n'):
            line = line.strip()
            if line.startswith(prefix):
                upstream[line[len(prefix):]] = normalise(git_out('show', '%s:%s' % (base, line)))

        overlay = files_under(overlay_dir)

        added = sorted(set(overlay) - set(upstream))
        removed = sorted(set(upstream) - set(overlay))
        changed = sorted(k for k in (set(overlay) & set(upstream)) if overlay[k] != upstream[k])

        if not (added or removed or changed):
            print('  NOTHING IS LOCAL -- byte-identical to the official port. Delete this overlay.')
        for f in added:
            print('  + %s   (local file)' % f)
        for f in removed:
            print('  - %s   (upstream file deleted here)' % f)
        for f in changed:
            print('  ~ %s   (differs)' % f)
        print('')

    print('=' * 71)
    print('Anything listed with +, - or ~ is a genuine local change. Everything')
    print('else in those ports is upstream\'s and must be taken verbatim on the')
    print('next rebase. A surviving delta is NOT proof it is still needed: check')
    print('it against the current sources before keeping it.')


if __name__ == '__main__':
    main()
