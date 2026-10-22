#!/bin/sh
# OTA update of the panel from the GitHub repository's releases: the
# kindle-vN tags (see tools/release_kindle.sh). A push to main isn't enough:
# the Kindle only updates when a tag with a higher N than the running one
# appears. The Kindle doesn't speak HTTPS, so the files go through the Arduino:
#   GET /ota/version                       name of the latest kindle-vN tag
#   GET /ota/file?ref=TAG&path=kindle/F    a file at that tag
#
# Usage: sh ota.sh update   (started by dashboard.sh; by hand: dashboard.sh update)
#
# Update safety:
#   - files are downloaded into a separate folder and accepted only if
#     complete (last line "# ota:end") and, for scripts, syntactically valid;
#   - the running version is saved in .ota_prev/ before being replaced;
#   - new files replace the old ones with mv, so running scripts keep
#     reading the old version;
#   - after the restart the panel must prove it works within
#     OTA_HEALTH_SECONDS, otherwise the previous version is restored and that
#     release is never retried (.ota_bad).
# This process belongs to the OLD version, which stays in memory: so the
# rollback works even if the new version is broken.

DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"

MARKER="# ota:end"
WORK=/tmp/dashboard-ota
STAGE="$WORK/new"
PREV="$DIR/.ota_prev"
BAD="$DIR/.ota_bad"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') ota: $*"; }
fail() { log "$*"; exit 1; }

# release_num TAG: "kindle-v12" -> 12; nothing if it isn't a release tag
release_num() {
  case "$1" in
    kindle-v | kindle-v*[!0-9]*) ;;
    kindle-v*) echo "${1#kindle-v}" ;;
  esac
}

# Files listed in the manifest (non-empty lines not starting with #)
manifest_files() { grep -v '^#' "$1" | grep -v '^$'; }

# fetch TAG PATH FILE: downloads a file of the repository and checks it
fetch() {
  http_get "http://$ARDUINO_HOST/ota/file?ref=$1&path=$2" 60 "$3" || { log "$2: download failed"; return 1; }
  [ "$(tail -n 1 "$3")" = "$MARKER" ] || { log "$2: incomplete file"; return 1; }
  case "$2" in
    *.sh) sh -n "$3" || { log "$2: syntax error"; return 1; } ;;
  esac
}

# The panel restarted: process alive and main loop running
healthy() {
  [ -f "$RUN/pid" ] && kill -0 "$(cat "$RUN/pid")" 2>/dev/null && [ -f "$RUN/alive" ]
}

rollback() { # REJECTED_TAG
  log "version $1 doesn't start: restoring the previous one"
  echo "$1" >> "$BAD"
  for f in "$PREV"/*; do
    [ -f "$f" ] && cp "$f" "$DIR/${f##*/}.ota_tmp" && mv "$DIR/${f##*/}.ota_tmp" "$DIR/${f##*/}"
  done
  [ -s "$DIR/VERSION" ] || rm -f "$DIR/VERSION"
  sh "$DIR/dashboard.sh" restart
}

update() {
  local tag num cur f
  [ "$OTA_ENABLED" = 1 ] || { log "OTA disabled in config.sh"; return 0; }
  mkdir -p "$WORK"
  mkdir "$WORK/lock" 2>/dev/null || fail "update already in progress"
  trap 'rm -rf "$WORK/lock"' EXIT

  http_get "http://$ARDUINO_HOST/ota/version" 30 "$WORK/version" || fail "Arduino unreachable"
  read -r tag < "$WORK/version"
  num=$(release_num "$tag")
  [ -n "$num" ] || fail "invalid response: $tag"
  cur=$(release_num "$VERSION")
  # Never backwards: if a tag disappears, we stay on the running version
  if [ -n "$cur" ] && [ "$num" -le "$cur" ]; then log "already up to date ($VERSION)"; return 0; fi
  if grep -q "^$tag\$" "$BAD" 2>/dev/null; then log "version $tag was already rejected"; return 0; fi

  log "updating ${VERSION:-(initial version)} -> $tag"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  fetch "$tag" kindle/ota-files "$STAGE/ota-files" || fail "update cancelled"
  for f in $(manifest_files "$STAGE/ota-files"); do
    case "$f" in */* | .* ) fail "file name not allowed: $f" ;; esac
    [ "$f" = ota-files ] && continue
    fetch "$tag" "kindle/$f" "$STAGE/$f" || fail "update cancelled"
  done

  # Copy of the running version, then replacement file by file
  rm -rf "$PREV"
  mkdir -p "$PREV"
  for f in $(manifest_files "$STAGE/ota-files"); do
    [ -f "$DIR/$f" ] && cp "$DIR/$f" "$PREV/$f"
  done
  echo "$VERSION" > "$PREV/VERSION"
  for f in $(manifest_files "$STAGE/ota-files"); do
    cp "$STAGE/$f" "$DIR/$f.ota_tmp" && mv "$DIR/$f.ota_tmp" "$DIR/$f" || { rollback "$tag"; fail "copy failed"; }
  done
  echo "$tag" > "$DIR/VERSION.ota_tmp" && mv "$DIR/VERSION.ota_tmp" "$DIR/VERSION"

  log "restarting the panel"
  sh "$DIR/dashboard.sh" restart
  sleep "$OTA_HEALTH_SECONDS"
  if healthy; then
    log "updated to $tag"
  else
    rollback "$tag"
    fail "update cancelled"
  fi
}

case "$1" in
  update) update ;;
  *) echo "Usage: sh $0 update"; exit 1 ;;
esac
# ota:end
