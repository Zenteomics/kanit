#!/usr/bin/env bash
# Publishes the tracked wiki/ files to the repository's GitHub wiki.
#
#   wiki_publish.sh
#
# Pages in wiki/ link to each other as Page.md, which works in the repository view; the wiki names
# a page without the extension, so each link to a tracked page is written as Page here, outside
# fenced code. A .md link to a page wiki/ does not track stops the run. Files the wiki has and
# wiki/ no longer tracks are removed one named file at a time. GitHub creates the wiki's repository
# with its first page, which is made once by hand; the first run replaces it.
#
# GITHUB_REPOSITORY and WIKI_TOKEN name the wiki and authorize the push. WIKI_URL, when set,
# replaces the wiki's URL, so the script also runs against a local repository. The work directory
# is made under RUNNER_TEMP, or /var/tmp, and left in place.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

source_sha=$(git rev-parse HEAD)
if [[ -n "${WIKI_URL:-}" ]]; then
    url=$WIKI_URL
else
    repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
    server_url=${GITHUB_SERVER_URL:-https://github.com}
    : "${WIKI_TOKEN:?WIKI_TOKEN is required}"
    url="${server_url%/}/${repository}.wiki.git"
    # The token travels in a header set through the environment, never in a URL or a config file.
    export GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0="http.${server_url%/}/.extraheader"
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$WIKI_TOKEN" | base64 | tr -d '\n')"
    export GIT_CONFIG_VALUE_0
fi
export GIT_TERMINAL_PROMPT=0

work=$(mktemp -d "${RUNNER_TEMP:-/var/tmp}/kanit-wiki.XXXXXX")
git ls-files -z -- wiki | sed -z 's,^wiki/,,' > "$work/files"
pages=$(tr '\0' '\n' < "$work/files" | sed -n 's,^\([^/]*\)\.md$,\1,p')

wiki="$work/wiki"
if ! git clone --quiet --depth 1 "$url" "$wiki"; then
    echo "cannot clone the wiki at $url: turn the wiki on and create its first page by hand" >&2
    exit 1
fi
branch=$(git -C "$wiki" symbolic-ref --quiet --short HEAD)

while IFS= read -r -d '' name; do
    grep -qzFx -- "$name" "$work/files" || git -C "$wiki" rm --quiet -- "$name"
done < <(git -C "$wiki" ls-files -z)

while IFS= read -r -d '' name; do
    mkdir -p "$wiki/$(dirname -- "$name")"
    if [[ "$name" != *.md ]]; then
        cp -- "wiki/$name" "$wiki/$name"
        continue
    fi
    PAGES="$pages" awk -v file="wiki/$name" '
        BEGIN {
            n = split(ENVIRON["PAGES"], list, "\n")
            for (i = 1; i <= n; i++) known[list[i]] = 1
        }
        /^[ \t]*(```|~~~)/ { fenced = !fenced; print; next }
        fenced { print; next }
        {
            rest = $0
            out = ""
            while (match(rest, /[]][(][^)#\/:]+[.]md(#[^)]*)?[)]/)) {
                target = substr(rest, RSTART + 2, RLENGTH - 3)
                page = target
                anchor = ""
                if ((h = index(target, "#")) > 0) {
                    page = substr(target, 1, h - 1)
                    anchor = substr(target, h)
                }
                sub(/[.]md$/, "", page)
                if (!(page in known)) {
                    printf "%s: %s.md is not a page wiki/ tracks\n", file, page > "/dev/stderr"
                    bad = 1
                }
                out = out substr(rest, 1, RSTART - 1) "](" page anchor ")"
                rest = substr(rest, RSTART + RLENGTH)
            }
            print out rest
        }
        END { exit bad }
    ' "wiki/$name" > "$wiki/$name"
done < "$work/files"

git -C "$wiki" add --all
if git -C "$wiki" diff --cached --quiet; then
    echo "the wiki already matches wiki/ at ${source_sha:0:12}"
    exit 0
fi
git -C "$wiki" diff --cached --name-status
git -C "$wiki" -c commit.gpgsign=false -c user.name='github-actions[bot]' \
    -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit --quiet -m "docs: sync wiki from ${source_sha:0:12}"
git -C "$wiki" push --quiet origin "HEAD:$branch"

local_head=$(git -C "$wiki" rev-parse HEAD)
remote_head=$(git -C "$wiki" ls-remote origin "refs/heads/$branch" | awk 'NR == 1 { print $1 }')
if [[ "$remote_head" != "$local_head" ]]; then
    echo "the push did not land: local $local_head, remote ${remote_head:-missing}" >&2
    exit 1
fi
echo "published the wiki at ${local_head:0:12} from wiki/ at ${source_sha:0:12}"
