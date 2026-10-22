#!/bin/sh
# Publishes the kindle/ folder of the current commit to the Kindle (over OTA):
# creates and pushes the next kindle-vN tag. The Kindle only updates on these
# tags, not on every push to main.
#
#   tools/release_kindle.sh          checks, shows the changes, asks to confirm
#   tools/release_kindle.sh --yes    without confirmation

set -e
cd "$(dirname "$0")/.."

fail() { echo "Error: $*" >&2; exit 1; }

git fetch -q --tags origin
[ -z "$(git status --porcelain -- kindle/)" ] || fail "kindle/ has uncommitted changes"
git branch -r --contains HEAD | grep -q . || fail "the current commit isn't on GitHub yet: push first"

last=$(git tag -l 'kindle-v*' | sed 's/^kindle-v//' | grep -E '^[0-9]+$' | sort -n | tail -n 1)
next=$((${last:-0} + 1))
if [ -n "$last" ] && git diff --quiet "kindle-v$last" HEAD -- kindle/; then
  echo "No changes in kindle/ since kindle-v$last: nothing to publish."
  exit 0
fi

# The same checks the Kindle runs before accepting an update
for f in $(grep -v '^#' kindle/ota-files | grep -v '^$'); do
  [ -f "kindle/$f" ] || fail "kindle/$f is listed in ota-files but doesn't exist"
  [ "$(tail -n 1 "kindle/$f")" = "# ota:end" ] || fail "kindle/$f doesn't end with the line \"# ota:end\""
  case "$f" in
    *.sh) sh -n "kindle/$f" || fail "kindle/$f has syntax errors" ;;
  esac
done

if [ -n "$last" ]; then
  echo "Changes in kindle/ since kindle-v$last:"
  git diff --stat "kindle-v$last" HEAD -- kindle/
else
  echo "First release for the Kindle."
fi

if [ "$1" != "--yes" ]; then
  printf 'Publish kindle-v%s? [y/N] ' "$next"
  read -r answer
  [ "$answer" = y ] || [ "$answer" = Y ] || { echo "Cancelled."; exit 0; }
fi
git tag -a "kindle-v$next" -m "Kindle v$next"
git push -q origin "kindle-v$next"
echo "Published kindle-v$next: the Kindle updates at its next check (or with the webapp's Update button)."
