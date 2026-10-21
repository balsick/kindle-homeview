#!/bin/sh
# Aggiornamento OTA del pannello dal ramo principale del repository GitHub.
# Il Kindle non parla HTTPS, quindi i file passano dall'Arduino:
#   GET /ota/version                    commit attuale del ramo
#   GET /ota/file?sha=SHA&path=kindle/F un file a quella revisione
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
#     commit non viene più riprovato (.ota_bad).
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
short() { printf '%.7s' "$1"; }
fail() { log "$*"; exit 1; }

# File elencati nel manifest (righe non vuote che non iniziano con #)
manifest_files() { grep -v '^#' "$1" | grep -v '^$'; }

# fetch SHA PERCORSO FILE: scarica un file del repository e lo verifica
fetch() {
  http_get "http://$ARDUINO_HOST/ota/file?sha=$1&path=$2" 60 "$3" || { log "$2: download fallito"; return 1; }
  [ "$(tail -n 1 "$3")" = "$MARKER" ] || { log "$2: file incompleto"; return 1; }
  case "$2" in
    *.sh) sh -n "$3" || { log "$2: errore di sintassi"; return 1; } ;;
  esac
}

# Il pannello è ripartito: processo vivo e ciclo principale che gira
healthy() {
  [ -f "$RUN/pid" ] && kill -0 "$(cat "$RUN/pid")" 2>/dev/null && [ -f "$RUN/alive" ]
}

rollback() { # SHA_SCARTATO
  log "la versione $1 non parte: ripristino la precedente"
  echo "$1" >> "$BAD"
  for f in "$PREV"/*; do
    [ -f "$f" ] && cp "$f" "$DIR/${f##*/}.ota_tmp" && mv "$DIR/${f##*/}.ota_tmp" "$DIR/${f##*/}"
  done
  [ -s "$DIR/VERSION" ] || rm -f "$DIR/VERSION"
  sh "$DIR/dashboard.sh" restart
}

update() {
  local sha f
  [ "$OTA_ENABLED" = 1 ] || { log "OTA disattivato in config.sh"; return 0; }
  mkdir -p "$WORK"
  mkdir "$WORK/lock" 2>/dev/null || fail "aggiornamento già in corso"
  trap 'rm -rf "$WORK/lock"' EXIT

  http_get "http://$ARDUINO_HOST/ota/version" 30 "$WORK/version" || fail "Arduino non raggiungibile"
  read -r sha < "$WORK/version"
  case "$sha" in "" | *[!0-9a-f]*) fail "risposta non valida: $sha" ;; esac
  [ ${#sha} -eq 40 ] || fail "risposta non valida: $sha"
  if [ "$sha" = "$VERSION" ]; then log "già aggiornato ($(short "$sha"))"; return 0; fi
  if grep -q "^$sha\$" "$BAD" 2>/dev/null; then log "la versione $sha era già stata scartata"; return 0; fi

  log "aggiorno ${VERSION:+$(short "$VERSION") }-> $(short "$sha")"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  fetch "$sha" kindle/ota-files "$STAGE/ota-files" || fail "aggiornamento annullato"
  for f in $(manifest_files "$STAGE/ota-files"); do
    case "$f" in */* | .* ) fail "nome di file non ammesso: $f" ;; esac
    [ "$f" = ota-files ] && continue
    fetch "$sha" "kindle/$f" "$STAGE/$f" || fail "aggiornamento annullato"
  done

  # Copia della versione in uso, poi sostituzione file per file
  rm -rf "$PREV"
  mkdir -p "$PREV"
  for f in $(manifest_files "$STAGE/ota-files"); do
    [ -f "$DIR/$f" ] && cp "$DIR/$f" "$PREV/$f"
  done
  echo "$VERSION" > "$PREV/VERSION"
  for f in $(manifest_files "$STAGE/ota-files"); do
    cp "$STAGE/$f" "$DIR/$f.ota_tmp" && mv "$DIR/$f.ota_tmp" "$DIR/$f" || { rollback "$sha"; fail "copia fallita"; }
  done
  echo "$sha" > "$DIR/VERSION.ota_tmp" && mv "$DIR/VERSION.ota_tmp" "$DIR/VERSION"

  log "riavvio il pannello"
  sh "$DIR/dashboard.sh" restart
  sleep "$OTA_HEALTH_SECONDS"
  if healthy; then
    log "aggiornato a $sha"
  else
    rollback "$sha"
    fail "aggiornamento annullato"
  fi
}

case "$1" in
  update) update ;;
  *) echo "Uso: sh $0 update"; exit 1 ;;
esac
# ota:end
