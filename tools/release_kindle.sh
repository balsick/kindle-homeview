#!/bin/sh
# Pubblica sul Kindle (via OTA) la cartella kindle/ del commit attuale:
# crea e pubblica il tag kindle-vN successivo. Il Kindle si aggiorna solo
# con questi tag, non a ogni push su main.
#
#   tools/release_kindle.sh          controlla, mostra le modifiche, chiede conferma
#   tools/release_kindle.sh --yes    senza conferma

set -e
cd "$(dirname "$0")/.."

fail() { echo "Errore: $*" >&2; exit 1; }

git fetch -q --tags origin
[ -z "$(git status --porcelain -- kindle/)" ] || fail "kindle/ ha modifiche non committate"
git branch -r --contains HEAD | grep -q . || fail "il commit attuale non è ancora su GitHub: fai prima push"

last=$(git tag -l 'kindle-v*' | sed 's/^kindle-v//' | grep -E '^[0-9]+$' | sort -n | tail -n 1)
next=$((${last:-0} + 1))
if [ -n "$last" ] && git diff --quiet "kindle-v$last" HEAD -- kindle/; then
  echo "Nessuna modifica in kindle/ da kindle-v$last: niente da pubblicare."
  exit 0
fi

# Gli stessi controlli che fa il Kindle prima di accettare un aggiornamento
for f in $(grep -v '^#' kindle/ota-files | grep -v '^$'); do
  [ -f "kindle/$f" ] || fail "kindle/$f è in ota-files ma non esiste"
  [ "$(tail -n 1 "kindle/$f")" = "# ota:end" ] || fail "kindle/$f non finisce con la riga \"# ota:end\""
  case "$f" in
    *.sh) sh -n "kindle/$f" || fail "kindle/$f ha errori di sintassi" ;;
  esac
done

if [ -n "$last" ]; then
  echo "Modifiche in kindle/ da kindle-v$last:"
  git diff --stat "kindle-v$last" HEAD -- kindle/
else
  echo "Primo rilascio per il Kindle."
fi

if [ "$1" != "--yes" ]; then
  printf 'Pubblico kindle-v%s? [s/N] ' "$next"
  read -r answer
  [ "$answer" = s ] || [ "$answer" = S ] || { echo "Annullato."; exit 0; }
fi
git tag -a "kindle-v$next" -m "Kindle v$next"
git push -q origin "kindle-v$next"
echo "Pubblicato kindle-v$next: il Kindle si aggiorna al prossimo controllo (o col pulsante Aggiorna della webapp)."
