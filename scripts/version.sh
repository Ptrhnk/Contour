#!/bin/sh
# Versioning, driven by git tags and the conventional-commit prefixes this
# repo already uses.
#
#   version.sh current          version of the last vX.Y.Z tag (or Info.plist)
#   version.sh next [BUMP]      what `release` would cut
#   version.sh release [BUMP]   write Info.plist, commit, tag vX.Y.Z
#   version.sh stamp PLIST      write build number + git describe into a bundle
#
# BUMP is major, minor, patch, or an explicit X.Y.Z. Left out, it is read from
# the commits since the last tag: a `type!:` subject or a BREAKING CHANGE
# footer is major, any `feat` is minor, anything else is patch.
#
# Info.plist keeps CFBundleShortVersionString committed, so a source download
# without .git still builds with the right version. The build number is the
# commit count, stamped only into the assembled bundle — committing it would
# change on every commit.
set -eu

PLIST=Resources/Info.plist
BUDDY=/usr/libexec/PlistBuddy

last_tag() {
    git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true
}

current() {
    tag=$(last_tag)
    if [ -n "$tag" ]; then
        echo "${tag#v}"
    else
        "$BUDDY" -c 'Print :CFBundleShortVersionString' "$PLIST"
    fi
}

auto_bump() {
    tag=$(last_tag)
    range=${tag:+$tag..}HEAD
    if git log --format='%s%n%b' "$range" | grep -qE '^[a-z]+(\([^)]*\))?!:|^BREAKING[ -]CHANGE:'; then
        echo major
    elif git log --format='%s' "$range" | grep -qE '^feat(\([^)]*\))?:'; then
        echo minor
    else
        echo patch
    fi
}

next() {
    bump=${1:-$(auto_bump)}
    case $bump in
        [0-9]*.[0-9]*.[0-9]*) echo "$bump"; return ;;
    esac
    IFS=. read -r major minor patch <<EOF
$(current)
EOF
    case $bump in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "$major.$((minor + 1)).0" ;;
        patch) echo "$major.$minor.$((patch + 1))" ;;
        *) echo "unknown bump '$bump': use major, minor, patch or X.Y.Z" >&2; exit 1 ;;
    esac
}

release() {
    if [ -n "$(git status --porcelain)" ]; then
        echo "error: working tree is not clean; commit or stash first" >&2
        exit 1
    fi
    tag=$(last_tag)
    if [ -n "$tag" ] && [ "$(git rev-list --count "$tag..HEAD")" = 0 ]; then
        echo "error: nothing since $tag" >&2
        exit 1
    fi
    version=$(next "${1:-}")
    if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
        echo "error: tag v$version already exists" >&2
        exit 1
    fi
    "$BUDDY" -c "Set :CFBundleShortVersionString $version" "$PLIST"
    git commit -q -m "chore: version $version" -- "$PLIST"
    git tag -a "v$version" -m "Contour $version"
    echo "tagged v$version — push with: git push --follow-tags"
}

# Runs against the copy inside build/Contour.app, never the source plist.
stamp() {
    target=$1
    if git rev-parse --git-dir >/dev/null 2>&1; then
        build=$(git rev-list --count HEAD)
        describe=$(git describe --tags --always --dirty --match 'v[0-9]*.[0-9]*.[0-9]*')
        "$BUDDY" -c "Set :CFBundleVersion $build" "$target"
        "$BUDDY" -c "Delete :ContourGitDescribe" "$target" 2>/dev/null || true
        "$BUDDY" -c "Add :ContourGitDescribe string $describe" "$target"
    fi
}

cmd=${1:-current}
[ $# -gt 0 ] && shift
case $cmd in
    current) current ;;
    next)    next "${1:-}" ;;
    release) release "${1:-}" ;;
    stamp)   stamp "$1" ;;
    *) echo "usage: $0 current | next [BUMP] | release [BUMP] | stamp PLIST" >&2; exit 1 ;;
esac
