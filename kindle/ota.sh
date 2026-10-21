#!/bin/sh
# Aggiornamento OTA del pannello dai rilasci del repository GitHub: i tag
# kindle-vN (vedi tools/release_kindle.sh). Un push su main non basta: il
# Kindle si aggiorna solo quando esce un tag con N più alto di quello in uso.
# Il Kindle non parla HTTPS, quindi i file passano dall'Arduino:
#   GET /ota/version                       nome dell'ultimo tag kindle-vN
#   GET /ota/file?ref=TAG&path=kindle/F    un file a quel tag
#
# Uso: sh ota.sh update   (lo lancia dashboard.sh; a mano: dashboard.sh update)
#
# Sicurezza dell'aggiornamento:
#   - i file vengono scaricati in una cartella a parte e accettati solo se
#     completi (ultima riga "# ota:end") e, per gli script, sintatticamente validi;
#   - prima di sostituirli si salva la versione in uso in .ota_prev/;
#   - i nuovi file prendono il posto dei vecchi con mv, così gli script in
#     esecuzione continuano a leggere la versione vecchia;
#   - dopo il riavvio il pannello deve dimostrare di funzionare entro
#     OTA_HEALTH_SECONDS, altrimenti si torna alla versione precedente e quel
#     rilascio non viene più riprovato (.ota_bad).
# Questo processo è quello della versione VECCHIA, che resta in memoria: il
# ripristino quindi funziona anche se la versione nuova è difettosa.

DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"

MARKER="# ota:end"
WORK=/tmp/dashboard-ota
STAGE="$WORK/new"
PREV="$DIR/.ota_prev"
BAD="$DIR/.ota_bad"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') ota: $*"; }
fail() { log "$*"; exit 1; }

# release_num TAG: "kindle-v12" -> 12; niente se non è un tag di rilascio
release_num() {
  case "$1" in
    kindle-v | kindle-v*[!0-9]*) ;;
    kindle-v*) echo "${1#kindle-v}" ;;
  esac
}

# File elencati nel manifest (righe non vuote che non iniziano con #)
manifest_files() { grep -v '^#' "$1" | grep -v '^$'; }

# fetch TAG PERCORSO FILE: scarica un file del repository e lo verifica
fetch() {
  http_get "http://$ARDUINO_HOST/ota/file?ref=$1&path=$2" 60 "$3" || { log "$2: download fallito"; return 1; }
  [ "$(tail -n 1 "$3")" = "$MARKER" ] || { log "$2: file incompleto"; return 1; }
  case "$2" in
    *.sh) sh -n "$3" || { log "$2: errore di sintassi"; return 1; } ;;
  esac
}

# Il pannello è ripartito: processo vivo e ciclo principale che gira
healthy() {
  [ -f "$RUN/pid" ] && kill -0 "$(cat "$RUN/pid")" 2>/dev/null && [ -f "$RUN/alive" ]
}

rollback() { # TAG_SCARTATO
  log "la versione $1 non parte: ripristino la precedente"
  echo "$1" >> "$BAD"
  for f in "$PREV"/*; do
    [ -f "$f" ] && cp "$f" "$DIR/${f##*/}.ota_tmp" && mv "$DIR/${f##*/}.ota_tmp" "$DIR/${f##*/}"
  done
  [ -s "$DIR/VERSION" ] || rm -f "$DIR/VERSION"
  sh "$DIR/dashboard.sh" restart
}

update() {
  local tag num cur f
  [ "$OTA_ENABLED" = 1 ] || { log "OTA disattivato in config.sh"; return 0; }
  mkdir -p "$WORK"
  mkdir "$WORK/lock" 2>/dev/null || fail "aggiornamento già in corso"
  trap 'rm -rf "$WORK/lock"' EXIT

  http_get "http://$ARDUINO_HOST/ota/version" 30 "$WORK/version" || fail "Arduino non raggiungibile"
  read -r tag < "$WORK/version"
  num=$(release_num "$tag")
  [ -n "$num" ] || fail "risposta non valida: $tag"
  cur=$(release_num "$VERSION")
  # Mai all'indietro: se un tag sparisce, si resta sulla versione in uso
  if [ -n "$cur" ] && [ "$num" -le "$cur" ]; then log "già aggiornato ($VERSION)"; return 0; fi
  if grep -q "^$tag\$" "$BAD" 2>/dev/null; then log "la versione $tag era già stata scartata"; return 0; fi

  log "aggiorno ${VERSION:-(versione iniziale)} -> $tag"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  fetch "$tag" kindle/ota-files "$STAGE/ota-files" || fail "aggiornamento annullato"
  for f in $(manifest_files "$STAGE/ota-files"); do
    case "$f" in */* | .* ) fail "nome di file non ammesso: $f" ;; esac
    [ "$f" = ota-files ] && continue
    fetch "$tag" "kindle/$f" "$STAGE/$f" || fail "aggiornamento annullato"
  done

  # Copia della versione in uso, poi sostituzione file per file
  rm -rf "$PREV"
  mkdir -p "$PREV"
  for f in $(manifest_files "$STAGE/ota-files"); do
    [ -f "$DIR/$f" ] && cp "$DIR/$f" "$PREV/$f"
  done
  echo "$VERSION" > "$PREV/VERSION"
  for f in $(manifest_files "$STAGE/ota-files"); do
    cp "$STAGE/$f" "$DIR/$f.ota_tmp" && mv "$DIR/$f.ota_tmp" "$DIR/$f" || { rollback "$tag"; fail "copia fallita"; }
  done
  echo "$tag" > "$DIR/VERSION.ota_tmp" && mv "$DIR/VERSION.ota_tmp" "$DIR/VERSION"

  log "riavvio il pannello"
  sh "$DIR/dashboard.sh" restart
  sleep "$OTA_HEALTH_SECONDS"
  if healthy; then
    log "aggiornato a $tag"
  else
    rollback "$tag"
    fail "aggiornamento annullato"
  fi
}

case "$1" in
  update) update ;;
  *) echo "Uso: sh $0 update"; exit 1 ;;
esac
# ota:end
