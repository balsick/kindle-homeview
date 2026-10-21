# Funzioni comuni a dashboard.sh e ota.sh. Chi lo include deve aver già
# impostato DIR (la cartella del pannello).

. "$DIR/defaults.sh"
[ -f "$DIR/config.sh" ] && . "$DIR/config.sh"
QR_DIR=${QR_DIR:-$DIR/qr}   # generata da tools/make_qr.py
[ -f "$QR_DIR/info.sh" ] && . "$QR_DIR/info.sh"

RUN=${RUN:-/tmp/dashboard}
VERSION=$(cat "$DIR/VERSION" 2>/dev/null)

# http_get URL TIMEOUT_S FILE: wget con timeout fatto a mano, perché il wget
# di BusyBox del Kindle potrebbe non supportare -T.
# Il timer chiude anche il suo sleep quando il download finisce prima, così
# non restano processi in giro (né pipe aperte, per chi legge l'output).
http_get() {
  rm -f "$3"
  wget -q -O "$3" "$1" 2>/dev/null &
  local pid=$!
  (
    sleep "$2" &
    s=$!
    trap 'kill $s 2>/dev/null; exit 0' TERM
    wait $s && kill "$pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  local timer=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill "$timer" 2>/dev/null
  return $rc
}

# ota:end
