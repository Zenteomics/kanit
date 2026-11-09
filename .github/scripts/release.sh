#!/usr/bin/env bash
# Release checks and the release package of kanit, the same on a workstation and in CI.
#
#   release.sh version          print the version build.zig.zon declares, after checking that
#                               src/root.zig declares the same
#   release.sh notes TAG        print the CHANGELOG.md section of TAG's version, which must be dated:
#                               the release notes, unchanged
#   release.sh package OUT_DIR  build the ReleaseSafe binary for generic x86-64 Linux, write
#                               kanit-VERSION-x86_64-linux.tar.gz to OUT_DIR, then unpack it and run
#                               the unpacked binary on a two-rule workflow without Zig on PATH
#
# Work directories are made under RUNNER_TEMP, or /var/tmp, and left in place.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

version=$(sed -n 's/^    \.version = "\([^"]*\)",$/\1/p' build.zig.zon)
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    die "build.zig.zon must declare one MAJOR.MINOR.PATCH version"
source_version=$(sed -n 's/^pub const version = "\([^"]*\)";$/\1/p' src/root.zig)
[[ "$source_version" == "$version" ]] ||
    die "src/root.zig declares version '$source_version', build.zig.zon '$version'"

notes() {
    local tag="$1"
    [[ "$tag" == "v$version" ]] || die "tag $tag does not name version $version"
    awk -v version="$version" '
        /^## / {
            if (found) exit
            if (index($0, "## [" version "] - ") == 1) {
                found = 1
                dated = (substr($0, length("## [" version "] - ") + 1) ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/)
            }
            next
        }
        found {
            if ($0 ~ /[^[:space:]]/) { for (; blank > 0; blank--) if (printed) print ""; print; printed = 1 }
            else blank++
        }
        END { if (!found || !dated || !printed) exit 1 }
    ' CHANGELOG.md || die "CHANGELOG.md needs a dated, nonempty '## [$version] - YYYY-MM-DD' section"
}

package() {
    local output="$1" work name stage binary info
    work=$(mktemp -d "${RUNNER_TEMP:-/var/tmp}/kanit-release.XXXXXX")
    name="kanit-$version-x86_64-linux"
    zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux --prefix "$work/install"

    stage="$work/$name"
    mkdir "$stage"
    cp "$work/install/bin/kanit" "$work/install/share/doc/kanit/LICENSE" "$work/install/share/doc/kanit/THIRD_PARTY.md" "$stage/"
    cmp LICENSE "$stage/LICENSE"
    cmp THIRD_PARTY.md "$stage/THIRD_PARTY.md"
    info=$(file -b "$stage/kanit")
    [[ "$info" == *x86-64*"statically linked"*", stripped" ]] ||
        die "the release binary is not a static, stripped x86-64 executable: $info"
    tar -czf "$work/$name.tar.gz" --owner=0 --group=0 --numeric-owner -C "$work" "$name"

    mkdir "$work/unpacked" "$work/smoke"
    tar -xzf "$work/$name.tar.gz" -C "$work/unpacked"
    binary="$work/unpacked/$name/kanit"
    (
        cd "$work/smoke"
        export PATH=/usr/bin:/bin
        ! command -v zig > /dev/null || die "zig is still on PATH"
        [[ "$("$binary" version)" == "kanit $version" ]] || die "'kanit version' does not print 'kanit $version'"
        cat > workflow.toml <<'TOML'
[workflow]
name = "smoke"
version = "1"

[[rules]]
name = "first"
output = ["first.txt"]
shell = "echo first > first.txt"
[rules.resources]
threads = 1
memory = "64M"

[[rules]]
name = "second"
input = ["first.txt"]
output = ["second.txt"]
shell = "cat first.txt > second.txt"
[rules.resources]
threads = 1
memory = "64M"
TOML
        "$binary" validate workflow.toml > /dev/null
        "$binary" plan workflow.toml > /dev/null
        "$binary" run workflow.toml --no-isolation --max-threads 1 --max-memory 256M -q > /dev/null
        [[ "$(cat second.txt)" == first ]] || die "the smoke workflow did not produce second.txt"
        "$binary" status > /dev/null
    )
    mkdir -p "$output"
    cp "$work/$name.tar.gz" "$output/"
    printf 'tested %s\n' "$output/$name.tar.gz"
}

case "${1:-}" in
    version)
        [[ $# -eq 1 ]] || die "usage: release.sh version"
        printf '%s\n' "$version"
        ;;
    notes)
        [[ $# -eq 2 ]] || die "usage: release.sh notes TAG"
        notes "$2"
        ;;
    package)
        [[ $# -eq 2 ]] || die "usage: release.sh package OUT_DIR"
        package "$2"
        ;;
    *)
        printf 'usage: release.sh version | notes TAG | package OUT_DIR\n' >&2
        exit 2
        ;;
esac
