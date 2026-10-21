#!/bin/sh
# Pannello domestico per Kindle 5 (firmware 4.1.x con jailbreak).
#
# Uso:  sh /mnt/us/dashboard/dashboard.sh start|stop|restart|update|keytest|autostart on|off
#       (preview è usato da tools/preview.py per l'anteprima sul PC)
#
# Processi:
#   - lettori tasti: uno per /dev/input/eventX, scrivono "codice valore" in una FIFO
#   - input (principale): legge la FIFO, aggiorna lo stato e ridisegna la riga della luce
#   - sender: invia allo Shelly l'ultimo valore quando i tasti si fermano (debounce)
#             e rilegge periodicamente lo stato delle luci
#   - poller: legge /status dall'Arduino e ridisegna ora, meteo e Spotify;
#             lancia anche il controllo degli aggiornamenti OTA (ota.sh)
# Ogni zona dello schermo viene ridisegnata solo se il suo contenuto è cambiato.
# Il tasto Home mostra i QR (WiFi ospiti e webapp); un tasto qualsiasi torna indietro.

DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"   # configurazione (defaults.sh + config.sh) e http_get

FBINK=${PREVIEW_FBINK:-$FBINK}
SCREEN_W=600
SCREEN_H=800
MARGIN=30

# Zone dello schermo: y di partenza e altezza
HDR_Y=0;   HDR_H=150
WX_Y=150;  WX_H=215
SP_Y=365;  SP_H=132
PR_Y=497;  PR_H=40
LT_Y=540;  ROW_H=72
LG_Y=760;  LG_H=40

if have usleep; then
  tick() { usleep 250000; }
  TICKS_PER_SEC=4
else
  tick() { sleep 1; }
  TICKS_PER_SEC=1
fi

# ---------- utilità ----------

# Carica le impostazioni delle luci in ID_n, NAME_n, HINT_n, PLUS_n, MINUS_n
load_lights() {
  local i=1 x pair old_ifs=$IFS
  for x in $LIGHT_IDS; do eval "ID_$i=\$x"; i=$((i + 1)); done
  NLIGHTS=$((i - 1))
  i=1; for pair in $LIGHT_KEYS; do eval "PLUS_$i=\${pair%:*} MINUS_$i=\${pair#*:}"; i=$((i + 1)); done
  IFS='|'
  i=1; for x in $LIGHT_NAMES; do eval "NAME_$i=\$x"; i=$((i + 1)); done
  i=1; for x in $LIGHT_HINTS; do eval "HINT_$i=\$x"; i=$((i + 1)); done
  IFS=$old_ifs
}

qr_mode() {
  local mode=""
  [ -f "$RUN/mode" ] && read -r mode < "$RUN/mode"
  [ "$mode" = qr ]
}

# changed ZONA FIRMA: vero se la zona va ridisegnata. Con i QR a schermo non
# si disegna nulla: all'uscita si ridisegna tutto.
changed() {
  local old=""
  qr_mode && return 1
  [ -f "$RUN/cache_$1" ] && read -r old < "$RUN/cache_$1"
  [ "$old" = "$2" ] && return 1
  printf '%s\n' "$2" > "$RUN/cache_$1"
  return 0
}

bar() { # PIENI TOTALE
  local i=0 s=""
  while [ $i -lt "$2" ]; do
    if [ $i -lt "$1" ]; then s="${s}■"; else s="${s}□"; fi
    i=$((i + 1))
  done
  printf '%s' "$s"
}

mmss() { printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); }

# ---------- disegno (FBInk) ----------
# Si disegna sempre senza refresh (-b) e poi si aggiorna la zona intera con
# un unico refresh parziale, così non ci sono sfarfallii intermedi.

fb() { "$FBINK" -q "$@" >/dev/null 2>&1; }

zone_clear() { fb -b -k "top=$1,left=0,width=$SCREEN_W,height=$2"; }
zone_refresh() { fb -s "top=$1,left=0,width=$SCREEN_W,height=$2"; }

# text TOP PX FONT LEFT RIGHT TESTO: una riga, troncata se non ci sta
text() {
  fb -b -t "regular=$3,px=$2,top=$1,bottom=$((SCREEN_H - $1 - $2 * 3 / 2)),left=$4,right=$5" "$6"
}

# text_c TOP PX FONT TESTO: una riga centrata
text_c() {
  fb -b -m -t "regular=$3,px=$2,top=$1,bottom=$((SCREEN_H - $1 - $2 * 3 / 2)),left=$MARGIN,right=$MARGIN" "$4"
}

# Rettangolo pieno nero (per le linee): rect TOP LEFT WIDTH HEIGHT
rect() { fb -b -B BLACK -k "top=$1,left=$2,width=$3,height=$4"; }

# image FILE TOP: PNG centrato orizzontalmente. L'FBInk di KOReader non ha il
# supporto per le immagini: se accanto al PNG c'è il .raw di make_qr.py (righe
# larghe quanto lo schermo, un byte per pixel) lo copiamo nel framebuffer.
image() {
  local raw="${1%.png}.raw"
  if [ -z "$PREVIEW_FBINK" ] && [ -f "$raw" ] && [ -w /dev/fb0 ]; then
    dd if="$raw" of=/dev/fb0 bs=$SCREEN_W seek="$2" 2>/dev/null
  else
    fb -b -g "file=$1,y=$2,halign=CENTER"
  fi
}

full_refresh() {
  rm -f "$RUN"/cache_*
  fb -c -f
  draw_legend
  draw_lights
}

# Fascia in basso con la legenda dei tasti sotto lo schermo
draw_legend() {
  zone_clear $LG_Y $LG_H
  rect $LG_Y $MARGIN $((SCREEN_W - 2 * MARGIN)) 2
  text_c $((LG_Y + 10)) 18 "$FONT" "$LEGEND"
  zone_refresh $LG_Y $LG_H
}

# ---------- QR ----------

show_qr() {
  echo qr > "$RUN/mode"
  date +%s > "$RUN/qr_since"
  fb -b -c
  if [ -f "$QR_DIR/wifi.png" ]; then
    text_c 18 34 "$FONT_BOLD" "WiFi ospiti"
    image "$QR_DIR/wifi.png" 68
    text_c 378 24 "$FONT" "Rete: $QR_WIFI_SSID"
    [ -n "$QR_WIFI_PASS" ] && text_c 410 24 "$FONT" "Password: $QR_WIFI_PASS"
    text_c 468 30 "$FONT_BOLD" "Controlla la casa"
    image "$QR_DIR/app.png" 512
    text_c 718 20 "$FONT" "$QR_APP_URL"
  else
    text_c 300 28 "$FONT" "QR non configurati:"
    text_c 345 22 "$FONT" "esegui tools/make_qr.py sul PC"
  fi
  text_c 762 18 "$FONT" "Premi un tasto per tornare  ·  versione ${VERSION:-dev}"
  fb -f -s "top=0,left=0,width=$SCREEN_W,height=$SCREEN_H"
}

hide_qr() {
  echo dash > "$RUN/mode"
  full_refresh
  touch "$RUN/poll_now"
}

# ---------- luci ----------

draw_light_row() { # INDICE
  local i=$1 on b name hint pct segs y
  read -r on < "$RUN/l${i}_on"
  read -r b < "$RUN/l${i}_b"
  changed "light_$i" "$on|$b" || return 0
  eval "name=\$NAME_$i hint=\$HINT_$i"
  if [ "$on" = 1 ]; then pct="$b%"; segs=$(((b + 5) / 10)); else pct="spenta"; segs=0; fi
  y=$((LT_Y + (i - 1) * ROW_H))
  zone_clear $y $ROW_H
  text $((y + 6)) 30 "$FONT_BOLD" $MARGIN 370 "$name"
  text $((y + 44)) 18 "$FONT" $MARGIN 370 "$hint"
  text $((y + 22)) 22 "$FONT" 250 130 "$(bar $segs 10)"
  text $((y + 16)) 30 "$FONT" 480 10 "$pct"
  zone_refresh $y $ROW_H
}

draw_lights() {
  local i=1
  while [ $i -le "$NLIGHTS" ]; do draw_light_row $i; i=$((i + 1)); done
}

# Ogni modifica incrementa l_N_ver: il sender confronta le versioni per il debounce.
set_light() { # INDICE ACCESA LUMINOSITÀ
  local v
  echo "$2" > "$RUN/l$1_on"
  echo "$3" > "$RUN/l$1_b"
  read -r v < "$RUN/l$1_ver"
  echo $((v + 1)) > "$RUN/l$1_ver"
  draw_light_row "$1"
}

adjust_light() { # INDICE DELTA
  local on b
  read -r on < "$RUN/l$1_on"
  read -r b < "$RUN/l$1_b"
  if [ "$on" != 1 ]; then
    [ "$2" -lt 0 ] && return    # già spenta
    on=1; b=$STEP               # da spenta si parte dal minimo
  else
    b=$((b + $2))
    if [ $b -le 0 ]; then on=0; b=$STEP; fi
    [ $b -gt 100 ] && b=100
  fi
  set_light "$1" $on $b
}

# Indietro: se c'è almeno una luce accesa le spegne tutte, altrimenti le
# riaccende tutte all'ultima luminosità.
toggle_all() {
  local i=1 on any=0 b
  while [ $i -le "$NLIGHTS" ]; do
    read -r on < "$RUN/l${i}_on"; [ "$on" = 1 ] && any=1
    i=$((i + 1))
  done
  i=1
  while [ $i -le "$NLIGHTS" ]; do
    read -r b < "$RUN/l${i}_b"
    set_light $i $((1 - any)) "$b"
    i=$((i + 1))
  done
}

send_light() { # INDICE
  local id on b
  eval "id=\$ID_$1"
  read -r on < "$RUN/l$1_on"
  read -r b < "$RUN/l$1_b"
  if [ "$on" = 1 ]; then
    http_get "http://$SHELLY_HOST/rpc/Light.Set?id=$id&on=true&brightness=$b" 3 "$RUN/shelly_$1.out"
  else
    http_get "http://$SHELLY_HOST/rpc/Light.Set?id=$id&on=false" 3 "$RUN/shelly_$1.out"
  fi
}

# Rilegge lo stato dallo Shelly (se le luci sono state cambiate dall'app o
# da un interruttore), senza sovrascrivere modifiche fatte nel frattempo.
sync_lights() {
  local i=1 id on b ver ver2 f="$RUN/sync.json"
  while [ $i -le "$NLIGHTS" ]; do
    eval "id=\$ID_$i"
    read -r ver < "$RUN/l${i}_ver"
    if http_get "http://$SHELLY_HOST/rpc/Light.GetStatus?id=$id" 3 "$f"; then
      on=$(sed -n 's/.*"output":\([a-z]*\).*/\1/p' "$f")
      b=$(sed -n 's/.*"brightness":\([0-9]*\).*/\1/p' "$f")
      read -r ver2 < "$RUN/l${i}_ver"
      if [ -n "$b" ] && [ "$ver" = "$ver2" ]; then
        if [ "$on" = true ] && [ "$b" -gt 0 ]; then on=1; else on=0; fi
        [ "$b" -gt 0 ] || b=$STEP
        echo "$on" > "$RUN/l${i}_on"
        echo "$b" > "$RUN/l${i}_b"
      fi
    fi
    i=$((i + 1))
  done
  draw_lights
}

sender() {
  local i ver sent prev pending sync_left=$((SHELLY_SYNC_SECONDS * TICKS_PER_SEC))
  i=1; while [ $i -le "$NLIGHTS" ]; do eval "sent_$i=0 prev_$i=0"; i=$((i + 1)); done
  while true; do
    pending=0
    i=1
    while [ $i -le "$NLIGHTS" ]; do
      read -r ver < "$RUN/l${i}_ver"
      eval "sent=\$sent_$i prev=\$prev_$i"
      if [ "$ver" != "$sent" ]; then
        pending=1
        # invia solo se la versione non è cambiata dall'ultimo tick (debounce)
        if [ "$ver" = "$prev" ] && send_light $i; then eval "sent_$i=\$ver"; fi
      fi
      eval "prev_$i=\$ver"
      i=$((i + 1))
    done
    sync_left=$((sync_left - 1))
    if [ $sync_left -le 0 ] && [ $pending = 0 ]; then
      sync_lights
      sync_left=$((SHELLY_SYNC_SECONDS * TICKS_PER_SEC))
    fi
    tick
  done
}

# ---------- stato dall'Arduino ----------

# Ogni riga "chiave=valore" diventa la variabile S_chiave
load_status() {
  local line k
  while IFS= read -r line; do
    k=${line%%=*}
    case "$k" in "" | *[!a-z0-9_]*) continue ;; esac
    eval "S_$k=\${line#*=}"
  done < "$RUN/status"
}

# Batteria del Kindle: "96%", con ⚡ in carica. Vuota se non si legge.
battery_text() {
  local level charging
  if have lipc-get-prop; then
    level=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null)
    charging=$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null)
  else
    level=$PREVIEW_BATTERY
  fi
  [ -n "$level" ] || return 0
  [ "$charging" = 1 ] && printf '⚡'
  printf '%s%%' "$level"
}

draw_header() { # OFFLINE
  local date=$S_date batt font=$FONT
  batt=$(battery_text)
  [ "$1" = 1 ] && date="Gateway non raggiungibile"
  changed header "$S_time|$date|$batt" || return 0
  zone_clear $HDR_Y $HDR_H
  text_c $((HDR_Y + 8)) 90 "$FONT_BOLD" "$S_time"
  text_c $((HDR_Y + 105)) 28 "$FONT" "$date"
  # In alto a destra, in grassetto quando va ricaricata
  [ "${batt%\%}" -lt "$BATTERY_LOW" ] 2>/dev/null && font=$FONT_BOLD
  [ -n "$batt" ] && text $((HDR_Y + 12)) 20 "$font" $((SCREEN_W - MARGIN - 64)) $MARGIN "$batt"
  zone_refresh $HDR_Y $HDR_H
}

forecast_row() { # Y "Etichetta|Descrizione|min|max|pioggia%"
  local y=$1 IFS='|'
  set -f
  set -- $2
  set +f
  text $y 24 "$FONT_BOLD" $MARGIN 460 "$1"
  text $y 24 "$FONT" 155 210 "$2"
  text $y 24 "$FONT" 390 90 "$3° / $4°"
  text $y 24 "$FONT" 520 10 "$5%"
}

draw_weather() {
  changed weather "$S_w_ok|$S_w_temp|$S_w_desc|$S_w_feels|$S_w_hum|$S_w_wind|$S_d0|$S_d1|$S_d2" || return 0
  zone_clear $WX_Y $WX_H
  if [ "$S_w_ok" = 1 ]; then
    text $((WX_Y + 10)) 50 "$FONT_BOLD" $MARGIN $MARGIN "${S_w_temp}°  $S_w_desc"
    text $((WX_Y + 76)) 22 "$FONT" $MARGIN $MARGIN "Percepita ${S_w_feels}° · Umidità $S_w_hum% · Vento $S_w_wind km/h"
    forecast_row $((WX_Y + 116)) "$S_d0"
    forecast_row $((WX_Y + 147)) "$S_d1"
    forecast_row $((WX_Y + 178)) "$S_d2"
  else
    text $((WX_Y + 10)) 30 "$FONT" $MARGIN $MARGIN "Meteo non disponibile"
  fi
  zone_refresh $WX_Y $WX_H
}

draw_spotify() {
  local state
  if [ "$S_sp_ok" != 1 ]; then state="Spotify non raggiungibile"
  elif [ "$S_sp_active" != 1 ]; then state="Spotify: niente in riproduzione"
  elif [ "$S_sp_playing" = 1 ]; then state="▶  In riproduzione"
  else state="‖  In pausa"; fi
  [ "$S_sp_active" = 1 ] || S_sp_track="" S_sp_artist=""

  if changed spotify "$state|$S_sp_track|$S_sp_artist"; then
    zone_clear $SP_Y $SP_H
    text $((SP_Y + 8)) 22 "$FONT" $MARGIN $MARGIN "$state"
    text $((SP_Y + 38)) 36 "$FONT_BOLD" $MARGIN $MARGIN "$S_sp_track"
    text $((SP_Y + 90)) 26 "$FONT" $MARGIN $MARGIN "$S_sp_artist"
    zone_refresh $SP_Y $SP_H
  fi

  # La barra di avanzamento ha una zona sua: si aggiorna solo quando avanza
  # di un segmento, non a ogni lettura.
  local dur=${S_sp_duration:-0} segs=0 line=""
  if [ "$S_sp_active" = 1 ] && [ "$dur" -gt 0 ]; then
    segs=$((${S_sp_progress:-0} * 20 / dur))
    line="$(bar $segs 20)  $(mmss "$dur")"
  fi
  if changed progress "$line"; then
    zone_clear $PR_Y $PR_H
    [ -n "$line" ] && text $((PR_Y + 6)) 22 "$FONT" $MARGIN $MARGIN "$line"
    zone_refresh $PR_Y $PR_H
  fi
}

poller() {
  local fails=0 n polls=0 since now ota_req=""
  local polls_per_full=$((FULL_REFRESH_MINUTES * 60 / POLL_SECONDS))
  local ota_at=$(($(date +%s) + 120))   # primo controllo poco dopo l'avvio
  while true; do
    if http_get "http://$ARDUINO_HOST/status?v=$VERSION" 8 "$RUN/status.new"; then
      mv "$RUN/status.new" "$RUN/status"
      fails=0
    else
      fails=$((fails + 1))
    fi

    if qr_mode; then
      read -r since < "$RUN/qr_since"
      [ $(($(date +%s) - since)) -ge "$QR_SECONDS" ] && hide_qr
    else
      polls=$((polls + 1))
      if [ $polls -ge $polls_per_full ]; then
        polls=0
        full_refresh
      fi
    fi

    if [ -f "$RUN/status" ]; then
      load_status
      draw_header $([ $fails -ge 3 ] && echo 1 || echo 0)
      draw_weather
      draw_spotify
    fi
    : > "$RUN/alive"   # per ota.sh: il ciclo principale gira

    # Aggiornamenti: periodici, o chiesti dalla webapp (ota_req cambia)
    now=$(date +%s)
    if [ -n "$ota_req" ] && [ "${S_ota_req:-}" != "$ota_req" ]; then ota_at=$now; fi
    ota_req=${S_ota_req:-0}
    if [ "$OTA_ENABLED" = 1 ] && [ "$now" -ge "$ota_at" ]; then
      ota_at=$((now + OTA_CHECK_HOURS * 3600))
      ota_start
    fi

    # Attesa interrompibile: dopo un comando Spotify si rilegge subito
    n=0
    while [ $n -lt $((POLL_SECONDS * TICKS_PER_SEC)) ] && [ ! -e "$RUN/poll_now" ]; do
      tick; n=$((n + 1))
    done
    rm -f "$RUN/poll_now"
  done
}

# ---------- input ----------

# Legge gli eventi da un device. struct input_event su ARM a 32 bit, 16 byte:
# sec(4) usec(4) type(2) code(2) value(4). Il file resta aperto sul descrittore 3,
# quindi tra una lettura e l'altra non si perdono eventi.
# Il Kindle 5 non ha od: hexdump con questo formato stampa le stesse 8 parole.
u16dump() {
  if have od; then od -An -tu2 -v; else hexdump -v -e '8/2 "%u " "\n"'; fi
}

key_reader() { # DEVICE
  exec 3< "$1" || return
  while true; do
    set -- $(dd bs=16 count=1 <&3 2>/dev/null | u16dump)
    [ $# -ge 7 ] || { sleep 1; continue; }
    [ "$5" = 1 ] && echo "$6 $7"   # solo EV_KEY: codice, valore (1 premuto, 2 ripetizione, 0 rilascio)
  done
}

spotify_cmd() {
  ( http_get "http://$ARDUINO_HOST/cmd?a=$1" 10 "$RUN/cmd.out"; touch "$RUN/poll_now" ) &
}

handle_key() { # CODICE VALORE
  local i=1 plus minus
  [ "$2" = 0 ] && return
  if qr_mode; then           # con i QR a schermo un tasto qualsiasi torna indietro
    [ "$2" = 1 ] && hide_qr
    return
  fi
  while [ $i -le "$NLIGHTS" ]; do
    eval "plus=\$PLUS_$i minus=\$MINUS_$i"
    [ "$1" = "$plus" ] && { adjust_light $i "$STEP"; return; }
    [ "$1" = "$minus" ] && { adjust_light $i "-$STEP"; return; }
    i=$((i + 1))
  done
  [ "$2" = 1 ] || return   # tenendo premuto, si ripetono solo i tasti delle luci
  case "$1" in
    "$KEY_PREV") spotify_cmd prev ;;
    "$KEY_NEXT") spotify_cmd next ;;
    "$KEY_PLAY") spotify_cmd toggle ;;
    "$KEY_ALL") toggle_all ;;
    "$KEY_REFRESH") full_refresh; touch "$RUN/poll_now" ;;
    "$KEY_QR") show_qr ;;
  esac
}

# ---------- comandi ----------

run() {
  local i=1 pids="" dev
  load_lights
  mkdir -p "$RUN"
  rm -f "$RUN"/*
  echo $$ > "$RUN/pid"
  while [ $i -le "$NLIGHTS" ]; do
    echo 0 > "$RUN/l${i}_on"; echo 50 > "$RUN/l${i}_b"; echo 0 > "$RUN/l${i}_ver"
    i=$((i + 1))
  done

  /etc/init.d/framework stop >/dev/null 2>&1
  lipc-set-prop com.lab126.powerd preventScreenSaver 1
  sleep 2
  full_refresh
  sync_lights

  poller & pids="$pids $!"
  sender & pids="$pids $!"
  mkfifo "$RUN/keys"
  exec 4<> "$RUN/keys"
  for dev in $INPUT_DEVICES; do
    key_reader "$dev" >&4 & pids="$pids $!"
  done
  trap 'kill $pids 2>/dev/null; exit 0' TERM INT

  while read -r code value <&4; do
    handle_key "$code" "$value"
  done
}

# Lancia ota.sh staccato dal pannello, che durante l'aggiornamento viene riavviato
ota_start() {
  ( trap '' HUP; exec sh "$DIR/ota.sh" update ) >> /tmp/dashboard-ota.log 2>&1 &
}

start() {
  if [ -f "$RUN/pid" ] && kill -0 "$(cat "$RUN/pid")" 2>/dev/null; then
    echo "Il pannello è già in esecuzione"
    return 1
  fi
  ( trap '' HUP; exec sh "$DIR/dashboard.sh" run ) > /tmp/dashboard.log 2>&1 &
  echo "Pannello avviato (log in /tmp/dashboard.log)"
}

kill_panel() {
  [ -f "$RUN/pid" ] && kill "$(cat "$RUN/pid")" 2>/dev/null
  rm -f "$RUN/pid"
  sleep 1
}

stop() {
  kill_panel
  lipc-set-prop com.lab126.powerd preventScreenSaver 0
  /etc/init.d/framework start >/dev/null 2>&1 &
  echo "Pannello fermato, interfaccia Kindle riavviata"
}

keytest() {
  local dev
  echo "Device di input:"
  grep '^[NH]:' /proc/bus/input/devices
  echo
  echo "Premi i tasti (Ctrl+C per uscire). Formato: device codice valore"
  for dev in /dev/input/event*; do
    ( key_reader "$dev" | while read -r c v; do echo "$dev $c $v"; done ) &
  done
  wait
}

# preview FILE_STATO "acc:lum acc:lum ..." [qr]: disegna una sola schermata
preview() {
  local i=1 l
  PREVIEW_BATTERY=${PREVIEW_BATTERY:-87}
  load_lights
  mkdir -p "$RUN"
  rm -f "$RUN"/*
  for l in $2; do
    echo "${l%:*}" > "$RUN/l${i}_on"; echo "${l#*:}" > "$RUN/l${i}_b"
    i=$((i + 1))
  done
  cp "$1" "$RUN/status"
  if [ "$3" = qr ]; then
    show_qr
    return
  fi
  full_refresh
  load_status
  draw_header 0
  draw_weather
  draw_spotify
}

# ---------- avvio al boot ----------
# Installa (on) o toglie (off) /etc/init.d/dashboard, lanciato al boot come
# S99dashboard dopo l'interfaccia Kindle. Lo script non blocca il boot: in
# background aspetta il WiFi, poi avvia il pannello. Per saltare un avvio
# senza toglierlo basta creare $DIR/NO_AUTOSTART.
INIT_SCRIPT=/etc/init.d/dashboard
INIT_LINK=/etc/rc5.d/S99dashboard

autostart() { # on|off
  mount -o rw,remount / || return 1
  rm -f "$INIT_LINK" "$INIT_SCRIPT"
  if [ "$1" = on ]; then
    cat > "$INIT_SCRIPT" <<INIT
#!/bin/sh
# Pannello domestico (kindle-homeview): creato da dashboard.sh autostart on
[ "\$1" = start ] || exit 0
[ -f "$DIR/NO_AUTOSTART" ] && exit 0
[ -f "$DIR/dashboard.sh" ] || exit 0
(
  i=0
  while [ \$i -lt 180 ]; do
    [ "\$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)" = CONNECTED ] && break
    sleep 2; i=\$((i + 2))
  done
  sleep 15   # lasciamo finire l'avvio dell'interfaccia Kindle
  sh "$DIR/dashboard.sh" start
) > /tmp/dashboard-boot.log 2>&1 &
exit 0
INIT
    chmod 755 "$INIT_SCRIPT"
    ln -s ../init.d/dashboard "$INIT_LINK"
  fi
  sync
  mount -o ro,remount /
  if [ "$1" = on ]; then echo "Avvio al boot attivato"; else echo "Avvio al boot disattivato"; fi
}

case "$1" in
  start) start ;;
  stop) stop ;;
  restart) kill_panel; start ;;            # senza riaccendere l'interfaccia Kindle
  update) sh "$DIR/ota.sh" update ;;       # controllo OTA a mano, con l'output a schermo
  run) run ;;
  keytest) keytest ;;
  autostart) autostart "$2" ;;
  preview) preview "$2" "$3" "$4" ;;
  *) echo "Uso: sh $0 start|stop|restart|update|keytest|autostart on|off"; exit 1 ;;
esac
# ota:end
