#!/usr/bin/env bash
# newest.sh — portable "newest file matching a glob" helper.
#
#   scripts/testing/newest.sh 'state/spool/pcaps/*.pcap'
#
# Prints the path of the most-recently-modified file matching the shell glob,
# relative to the repo root. Uses find -printf (GNU coreutils) so it is
# identical under a real `ls` and under eza (which aliases `ls` in some dev
# shells and breaks `ls -t | head` formatting with icons/ANSI). No `ls`
# dependency — safe to paste into LIVE_DEMO.md / TESTING_REFERENCE.md.
#
#   exit 0  -> one path printed
#   exit 1  -> no match (nothing printed)

set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

glob="${1:-}"
if [[ -z "$glob" ]]; then
  echo "usage: scripts/testing/newest.sh 'path/glob'   (quote the glob)" >&2
  exit 2
fi

# Split glob into dir + name. Default dir to "." if the glob has no slash.
if [[ "$glob" == */* ]]; then
  dir="${glob%/*}"
  name="${glob##*/}"
else
  dir="."
  name="$glob"
fi

match="$(find "$dir" -maxdepth 1 -name "$name" \
  -printf '%T@\t%p\n' 2>/dev/null | sort -n | tail -1 | cut -f2-)"

if [[ -z "$match" ]]; then
  echo "newest.sh: no match for '$glob'" >&2
  exit 1
fi
printf '%s\n' "$match"