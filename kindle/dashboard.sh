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
#   - poller: legge /status dall'Arduino e ridisegna ora, meteo, Spotify e luci;
#             lancia anche il controllo degli aggiornamenti OTA (ota.sh) e,
#             quando non cambia niente, spegne il WiFi (pausa)
# Ogni zona dello schermo viene ridisegnata solo se il suo contenuto è cambiato.
# Il tasto Home mostra i QR (WiFi ospiti e webapp); un tasto qualsiasi torna indietro.
#
# Consumi: il Kindle non va mai in sospensione, quindi conta ogni risveglio.
# Sender e poller restano fermi su una FIFO finché non c'è qualcosa da fare
# (kick_sender, poll_now) invece di girare a vuoto.

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

# Passo del debounce del sender
if have usleep; then
  tick() { usleep 250000; }
else
  tick() { sleep 1; }
fi

# ---------- utilità ----------

# Carica le impostazioni delle luci in ID_n e NAME_n
load_lights() {
  local i=1 x old_ifs=$IFS
  for x in $LIGHT_IDS; do eval "ID_$i=\$x"; i=$((i + 1)); done
  NLIGHTS=$((i - 1))
  IFS='|'
  i=1; for x in $LIGHT_NAMES; do eval "NAME_$i=\$x"; i=$((i + 1)); done
  IFS=$old_ifs
}

# Luce scelta col joystick (1..NLIGHTS)
selected() {
  local sel=1
  [ -f "$RUN/sel" ] && read -r sel < "$RUN/sel"
  echo "$sel"
}

# Valore di una chiave dell'ultimo /status, per chi non ha fatto load_status
status_value() { sed -n "s/^$1=//p" "$RUN/status" 2>/dev/null; }

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

# "06:30" -> minuti dalla mezzanotte (senza zeri iniziali: "08" non è ottale)
hhmm_min() {
  local h=${1%:*} m=${1#*:}
  echo $((${h#0} * 60 + ${m#0}))
}

# Risvegli tra processi: il poller aspetta sul descrittore 5, il sender sul 6
# (FIFO aperte da run). Fuori da run (preview) non c'è nessuno da svegliare.
poll_now() { { echo >&5; } 2>/dev/null; }
kick_sender() { { echo >&6; } 2>/dev/null; }

# wait_poll SECONDI: aspetta il timer o un poll_now, quello che arriva prima.
# Come in http_get, il timer chiude il suo sleep quando non serve più.
wait_poll() {
  local x t
  (
    sleep "$1" &
    s=$!
    trap 'kill $s 2>/dev/null; exit 0' TERM
    wait $s && echo >&5
  ) >/dev/null 2>&1 &
  t=$!
  read -r x <&5
  kill $t 2>/dev/null
}

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
  local legend=$LEGEND_IDLE at
  [ "$(status_value sp_active)" = 1 ] && legend=$LEGEND_MUSIC
  if paused; then
    read -r at < "$RUN/paused_at" 2>/dev/null
    legend="In pausa, dati delle $at  ·  $LEGEND_PAUSE"
  fi
  changed legend "$legend" || return 0
  zone_clear $LG_Y $LG_H
  rect $LG_Y $MARGIN $((SCREEN_W - 2 * MARGIN)) 2
  text_c $((LG_Y + 10)) 18 "$FONT" "$legend"
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
  poll_now
}

# ---------- luci ----------

# La luce scelta ha una barretta nera a sinistra e, sotto il nome, i tasti
draw_light_row() { # INDICE
  local i=$1 on b name pct segs y sel=0
  read -r on < "$RUN/l${i}_on"
  read -r b < "$RUN/l${i}_b"
  [ "$(selected)" = "$i" ] && sel=1
  changed "light_$i" "$on|$b|$sel" || return 0
  eval "name=\$NAME_$i"
  if [ "$on" = 1 ]; then pct="$b%"; segs=$(((b + 5) / 10)); else pct="spenta"; segs=0; fi
  y=$((LT_Y + (i - 1) * ROW_H))
  zone_clear $y $ROW_H
  text $((y + 6)) 30 "$FONT_BOLD" $MARGIN 370 "$name"
  if [ $sel = 1 ]; then
    rect $((y + 8)) 8 8 $((ROW_H - 16))
    text $((y + 44)) 18 "$FONT" $MARGIN 370 "◀ ▶ regola  ·  ● on/off"
  fi
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
  kick_sender
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

select_light() { # DELTA (+1 giù, -1 su), senza fare il giro
  local old new
  old=$(selected); new=$((old + $1))
  [ $new -lt 1 ] && new=1
  [ $new -gt "$NLIGHTS" ] && new=$NLIGHTS
  [ $new = "$old" ] && return
  echo $new > "$RUN/sel"
  draw_light_row "$old"
  draw_light_row "$new"
}

toggle_light() { # INDICE
  local on b
  read -r on < "$RUN/l$1_on"
  read -r b < "$RUN/l$1_b"
  set_light "$1" $((1 - on)) "$b"
}

# Tastiera: se c'è almeno una luce accesa le spegne tutte, altrimenti le
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

# Le luci cambiate dall'app, dalla webapp o da un interruttore. Non si
# sovrascrivono le modifiche non ancora inviate (l_N_sent lo scrive il sender)
# né quelle fatte durante la richiesta: per questo il poller annota le
# versioni di prima della richiesta in pv_N (light_versions).
light_versions() {
  local i=1 v
  while [ $i -le "$NLIGHTS" ]; do
    read -r v < "$RUN/l${i}_ver"; eval "pv_$i=\$v"
    i=$((i + 1))
  done
}

light_untouched() { # INDICE
  local ver sent pv
  read -r ver < "$RUN/l$1_ver"
  read -r sent < "$RUN/l$1_sent"
  eval "pv=\$pv_$1"
  [ "$ver" = "$sent" ] && [ "$ver" = "$pv" ]
}

store_light() { # INDICE ACCESA LUMINOSITÀ (luminosità 0: spenta)
  local on=$2 b=$3
  [ "$b" -gt 0 ] 2>/dev/null || { on=0; b=$STEP; }
  echo "$on" > "$RUN/l$1_on"
  echo "$b" > "$RUN/l$1_b"
}

# Un gateway aggiornato legge lui lo Shelly a ogni /status (lc_ok=1 e
# lcN=acceso|luminosità, N canale): una richiesta del Kindle invece di quattro.
lights_from_status() {
  local i=1 id st
  while [ $i -le "$NLIGHTS" ]; do
    eval "id=\$ID_$i"
    eval "st=\${S_lc$id:-}"
    unset "S_lc$id"   # se manca nel prossimo /status non si riusa questo
    [ -n "$st" ] && light_untouched $i && store_light $i "${st%|*}" "${st#*|}"
    i=$((i + 1))
  done
  draw_lights
}

# Con un gateway vecchio si chiede allo Shelly, una luce per volta
sync_lights() {
  local i=1 id on b f="$RUN/sync.json"
  while [ $i -le "$NLIGHTS" ]; do
    eval "id=\$ID_$i"
    if light_untouched $i && http_get "http://$SHELLY_HOST/rpc/Light.GetStatus?id=$id" 3 "$f"; then
      on=$(sed -n 's/.*"output":\([a-z]*\).*/\1/p' "$f")
      b=$(sed -n 's/.*"brightness":\([0-9]*\).*/\1/p' "$f")
      if [ -n "$b" ] && light_untouched $i; then
        if [ "$on" = true ]; then on=1; else on=0; fi
        store_light $i $on "$b"
      fi
    fi
    i=$((i + 1))
  done
  draw_lights
}

# Volume: i tasti cambiano vol_target e vol_ver; il sender manda all'Arduino
# solo il valore finale, quando i tasti si fermano (come per le luci).
volume_change() { # DELTA
  local cur v now until=0
  now=$(date +%s)
  [ -f "$RUN/vol_until" ] && read -r until < "$RUN/vol_until"
  if [ "$now" -lt "$until" ]; then read -r cur < "$RUN/vol_target"; else cur=$(status_value sp_volume); fi
  [ "${cur:--1}" -ge 0 ] 2>/dev/null || return   # il dispositivo non regola il volume
  cur=$((cur + $1))
  [ $cur -lt 0 ] && cur=0
  [ $cur -gt 100 ] && cur=100
  echo $cur > "$RUN/vol_target"
  echo $((now + 5)) > "$RUN/vol_until"   # per 5 s lo schermo mostra il valore scelto
  read -r v < "$RUN/vol_ver"; echo $((v + 1)) > "$RUN/vol_ver"
  load_status; draw_spotify
  kick_sender
}

send_volume() {
  local v
  read -r v < "$RUN/vol_target"
  http_get "http://$ARDUINO_HOST/cmd?a=vol&v=$v" 10 "$RUN/vol.out" && poll_now
}

# Dorme sulla FIFO finché un tasto non cambia luci o volume (kick_sender), poi
# gira a tick finché non ha inviato tutto.
sender() {
  local i ver sent prev pending x vol_sent=0 vol_prev=0
  i=1; while [ $i -le "$NLIGHTS" ]; do eval "prev_$i=0"; i=$((i + 1)); done
  while read -r x <&6; do
    pending=1
    while [ $pending = 1 ]; do
      tick
      pending=0
      i=1
      while [ $i -le "$NLIGHTS" ]; do
        read -r ver < "$RUN/l${i}_ver"
        read -r sent < "$RUN/l${i}_sent"
        eval "prev=\$prev_$i"
        if [ "$ver" != "$sent" ]; then
          pending=1
          # invia solo se la versione non è cambiata dall'ultimo tick (debounce)
          if [ "$ver" = "$prev" ]; then
            if send_light $i; then echo "$ver" > "$RUN/l${i}_sent"; else sleep 2; fi
          fi
        fi
        eval "prev_$i=\$ver"
        i=$((i + 1))
      done
      read -r ver < "$RUN/vol_ver"
      if [ "$ver" != "$vol_sent" ]; then
        pending=1
        if [ "$ver" = "$vol_prev" ]; then
          send_volume
          vol_sent=$ver
        fi
      fi
      vol_prev=$ver
    done
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

# Batteria del Kindle: "96%", con ⚡ col cavo collegato. Vuota se non si legge.
# La batteria si legge da sysfs con read, senza processi. "⚡" vuol dire cavo
# collegato (USB connesso): isCharging di powerd vale 0 quando la batteria è
# quasi piena anche col cavo attaccato.
BATT_SYS=/sys/devices/system/yoshi_battery/yoshi_battery0
USB_SYS=/sys/devices/platform/fsl-usb2-udc
battery_text() {
  local level="" plugged=""
  if [ -r "$BATT_SYS/battery_capacity" ]; then
    read -r level < "$BATT_SYS/battery_capacity"; level=${level%\%}
    [ -r "$USB_SYS/connected" ] && read -r plugged < "$USB_SYS/connected"
  elif have lipc-get-prop; then
    level=$(lipc-get-prop com.lab126.powerd battLevel 2>/dev/null)
    plugged=$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null)
  else
    level=$PREVIEW_BATTERY
  fi
  [ -n "$level" ] || return 0
  [ "$plugged" = 1 ] && printf '⚡'
  printf '%s%%' "$level"
}

# Battery current in mA (positive while charging), empty if unavailable
battery_current() {
  local ma=""
  [ -r "$BATT_SYS/battery_current" ] && read -r ma < "$BATT_SYS/battery_current"
  [ -n "$ma" ] && printf '%smA' "$ma"
}

# Orologio interno: l'ora dell'Arduino (S_time) tarata sull'orologio del
# Kindle a ogni /status, così l'ora va avanti anche col WiFi spento. Si tiene
# solo la differenza in minuti, quindi il fuso del Kindle non conta.
clock_sync() {
  case "$S_time" in [0-9][0-9]:[0-9][0-9]) ;; *) return ;; esac
  CLOCK_OFF=$((($(hhmm_min "$S_time") - $(date +%s) / 60 % 1440 + 1440) % 1440))
}

clock_now() { # HH:MM
  local m
  [ -n "${CLOCK_OFF:-}" ] || { printf '%s' "$S_time"; return; }
  m=$((($(date +%s) / 60 + CLOCK_OFF) % 1440))
  printf '%02d:%02d' $((m / 60)) $((m % 60))
}

# La batteria si legge (due lipc-get-prop) solo quando cambia il minuto
battery_update() {
  [ "$NOW_HM" = "${BATT_TIME:-}" ] && return
  BATT=$(battery_text)
  BATT_TIME=$NOW_HM
  case "$BATT" in ⚡*) CHARGING=1 ;; *) CHARGING=0 ;; esac
}

draw_header() { # OFFLINE
  local date=$S_date batt=$BATT font=$FONT time=${NOW_HM:-$S_time}
  [ "$1" = 1 ] && date="Gateway non raggiungibile"
  changed header "$time|$date|$batt" || return 0
  zone_clear $HDR_Y $HDR_H
  text_c $((HDR_Y + 8)) 90 "$FONT_BOLD" "$time"
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
  local vol=${S_sp_volume:--1} now until=0
  now=$(date +%s)
  [ -f "$RUN/vol_until" ] && read -r until < "$RUN/vol_until"
  [ "$now" -lt "$until" ] && read -r vol < "$RUN/vol_target"   # valore appena scelto coi tasti
  if [ "$S_sp_ok" != 1 ]; then state="Spotify non raggiungibile"
  elif [ "$S_sp_active" != 1 ]; then state="Spotify: a casa non suona niente"
  elif [ "$S_sp_playing" = 1 ]; then state="▶  $S_sp_device"
  else state="‖  $S_sp_device, in pausa"; fi
  [ "$S_sp_active" = 1 ] && [ "$vol" -ge 0 ] 2>/dev/null && state="$state  ·  volume $vol%"
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
  draw_legend   # la legenda dipende dalla musica
}

# ---------- pausa ----------
# Se per IDLE_MINUTES non cambia niente (nessun tasto, stesse luci, stessa
# musica e nessun brano che suona), il pannello va in pausa: WiFi spento,
# l'ora va avanti con l'orologio interno e ogni SLEEP_CHECK_MINUTES si
# riaccende il WiFi per un /status. Se è cambiato qualcosa si resta svegli,
# altrimenti si torna in pausa. Un tasto sveglia subito, in carica mai pausa.

paused() {
  local mode=""
  [ -f "$RUN/mode" ] && read -r mode < "$RUN/mode"
  [ "$mode" = pause ]
}

wifi() { # 0|1: spegne o accende il WiFi; all'accensione aspetta la connessione
  local i=0
  have lipc-set-prop || return 0
  lipc-set-prop com.lab126.cmd wirelessEnable "$1" 2>/dev/null
  [ "$1" = 1 ] || return 0
  while [ $i -lt 60 ] && [ "$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)" != CONNECTED ]; do
    sleep 1; i=$((i + 1))
  done
}

# Chiamata dai tasti in pausa: il primo tasto sveglia soltanto, come coi QR
wake_up() {
  zone_clear $LG_Y $LG_H
  text_c $((LG_Y + 10)) 18 "$FONT" "Riconnessione…"
  zone_refresh $LG_Y $LG_H
  poll_now
}

# Firma di quello che conta per la pausa: se cambia, il pannello resta sveglio
activity() {
  local i=1 on b s="$S_sp_active|$S_sp_playing|$S_sp_track|$S_sp_device"
  while [ $i -le "$NLIGHTS" ]; do
    read -r on < "$RUN/l${i}_on"; read -r b < "$RUN/l${i}_b"
    s="$s|$on:$b"
    i=$((i + 1))
  done
  printf '%s' "$s"
}

# Si resta in pausa fino al prossimo controllo, a un tasto, al cavo di
# ricarica o alla mezzanotte (la data va riletta). Il WiFi si spegne qui.
pause_wait() {
  local check_at sec
  if ! paused; then
    echo pause > "$RUN/mode"
    battery_log pausa
    # Così il gateway non segnala il Kindle come spento (kindleOnline)
    http_get "http://$ARDUINO_HOST/status?v=$VERSION&sleep=$((SLEEP_CHECK_MINUTES * 60 + 180))" 8 "$RUN/status.pause"
  fi
  clock_now > "$RUN/paused_at"
  draw_legend
  wifi 0
  check_at=$(($(date +%s) + SLEEP_CHECK_MINUTES * 60))
  while true; do
    sec=$(date +%S | sed 's/^0//')
    wait_poll $((62 - sec))
    [ -e "$RUN/key_seen" ] && break
    NOW_HM=$(clock_now)
    [ "$NOW_HM" = 00:00 ] && break
    [ "$(date +%s)" -ge $((check_at - 30)) ] && break   # i risvegli sono al minuto
    battery_update
    [ "$CHARGING" = 1 ] && break
    draw_header 0
  done
  wifi 1
}

pause_end() {
  paused || return 0
  echo dash > "$RUN/mode"
  battery_log sveglio
  draw_legend
}

# ---------- registro della batteria ----------
# battery.log: "secondi_epoch ora batteria corrente [evento]", per misurare i consumi.

battery_log() { # [EVENTO]
  [ "${BATTERY_LOG_MINUTES:-0}" -gt 0 ] && [ -z "$PREVIEW_FBINK" ] || return 0
  echo "$(date +%s) $(clock_now) $(battery_text) $(battery_current) $1" >> "$DIR/battery.log"
}

battery_log_trim() {
  local f="$DIR/battery.log"
  [ -f "$f" ] && [ "$(wc -l < "$f")" -gt 3000 ] && tail -n 2000 "$f" > "$f.new" && mv "$f.new" "$f"
}

# ---------- poller ----------

# Quanto aspettare prima del prossimo /status: con la musica o in carica
# POLL_SECONDS, altrimenti fino allo scatto del minuto (più un paio di
# secondi di margine, l'orologio del Kindle non è quello dell'Arduino).
next_poll() {
  local s since left
  if [ "$S_sp_playing" = 1 ] || [ "$CHARGING" = 1 ]; then s=$POLL_SECONDS
  else s=$((62 - $(date +%S | sed 's/^0//'))); fi
  if qr_mode; then
    read -r since < "$RUN/qr_since"
    left=$((since + QR_SECONDS - $(date +%s) + 1))
    [ $left -lt $s ] && s=$left
  fi
  [ $s -lt 1 ] && s=1
  echo $s
}

poller() {
  local fails=0 since now ota_req="" act="" sig idle_since pause
  local ota_at full_at log_at
  now=$(date +%s)
  ota_at=$((now + 120))   # primo controllo poco dopo l'avvio
  full_at=$((now + FULL_REFRESH_MINUTES * 60))
  log_at=$now
  idle_since=$now
  battery_log_trim
  while true; do
    light_versions
    if http_get "http://$ARDUINO_HOST/status?v=$VERSION" 8 "$RUN/status.new"; then
      mv "$RUN/status.new" "$RUN/status"
      fails=0
    else
      fails=$((fails + 1))
    fi

    now=$(date +%s)
    if qr_mode; then
      read -r since < "$RUN/qr_since"
      [ $((now - since)) -ge "$QR_SECONDS" ] && hide_qr
    elif [ $now -ge $full_at ] && ! paused; then
      full_refresh
      full_at=$((now + FULL_REFRESH_MINUTES * 60))
    fi

    if [ -f "$RUN/status" ]; then
      load_status
      [ $fails = 0 ] && clock_sync
      NOW_HM=$(clock_now)
      battery_update
      if [ $fails = 0 ]; then
        if [ -n "$S_lc_ok" ]; then lights_from_status; else sync_lights; fi
      fi
      sig=$(activity)
      [ "$sig" != "$act" ] && act=$sig && idle_since=$now
    fi
    if [ -e "$RUN/key_seen" ]; then   # lo crea handle_key a ogni tasto
      rm -f "$RUN/key_seen"
      idle_since=$now
    fi

    if [ "${IDLE_MINUTES:-0}" -gt 0 ] && [ "$CHARGING" != 1 ] && [ "$S_sp_playing" != 1 ] &&
      ! qr_mode && [ $((now - idle_since)) -ge $((IDLE_MINUTES * 60 - 30)) ]; then
      pause=1
    else
      pause=0
      pause_end
    fi
    if [ -f "$RUN/status" ]; then
      draw_header $([ $fails -ge 3 ] && echo 1 || echo 0)
      draw_weather
      draw_spotify
    fi
    : > "$RUN/alive"   # per ota.sh: il ciclo principale gira

    if [ "${BATTERY_LOG_MINUTES:-0}" -gt 0 ] && [ $now -ge $log_at ]; then
      battery_log
      log_at=$((now + BATTERY_LOG_MINUTES * 60))
    fi

    # Aggiornamenti: periodici, o chiesti dalla webapp (ota_req cambia)
    if [ -n "$ota_req" ] && [ "${S_ota_req:-}" != "$ota_req" ]; then ota_at=$now; fi
    ota_req=${S_ota_req:-0}
    if [ "$OTA_ENABLED" = 1 ] && [ "$now" -ge "$ota_at" ]; then
      ota_at=$((now + OTA_CHECK_HOURS * 3600))
      ota_start
    fi

    if [ $pause = 1 ]; then
      pause_wait
    else
      # Attesa interrompibile: dopo un comando Spotify si rilegge subito (poll_now)
      wait_poll "$(next_poll)"
    fi
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
  ( http_get "http://$ARDUINO_HOST/cmd?a=$1" 10 "$RUN/cmd.out"; poll_now ) &
}

# La musica suona a casa? (per i tasti ai lati)
music_at_home() { [ "$(status_value sp_active)" = 1 ]; }

handle_key() { # CODICE VALORE (1 premuto, 2 tenuto premuto)
  [ "$2" = 0 ] && return
  : > "$RUN/key_seen"        # per la pausa: qualcuno usa il pannello
  if paused; then            # in pausa un tasto sveglia soltanto
    [ "$2" = 1 ] && wake_up
    return
  fi
  if qr_mode; then           # con i QR a schermo un tasto qualsiasi torna indietro
    [ "$2" = 1 ] && hide_qr
    return
  fi
  # Tenendo premuto si ripetono luminosità e volume
  case "$1" in
    "$KEY_LEFT") adjust_light "$(selected)" "-$STEP"; return ;;
    "$KEY_RIGHT") adjust_light "$(selected)" "$STEP"; return ;;
    "$KEY_VOL_UP") music_at_home && volume_change "$VOLUME_STEP"; return ;;
    "$KEY_VOL_DOWN") music_at_home && volume_change "-$VOLUME_STEP"; return ;;
  esac
  [ "$2" = 1 ] || return
  case "$1" in
    "$KEY_UP") select_light -1 ;;
    "$KEY_DOWN") select_light 1 ;;
    "$KEY_CENTER") toggle_light "$(selected)" ;;
    "$KEY_TRACK_NEXT") music_at_home && spotify_cmd next ;;
    "$KEY_TRACK_PREV") music_at_home && spotify_cmd prev ;;
    "$KEY_PLAY") spotify_cmd toggle ;;
    "$KEY_ALL") toggle_all ;;
    "$KEY_REFRESH") full_refresh; poll_now ;;
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
    echo 0 > "$RUN/l${i}_on"; echo 50 > "$RUN/l${i}_b"
    echo 0 > "$RUN/l${i}_ver"; echo 0 > "$RUN/l${i}_sent"
    i=$((i + 1))
  done
  echo 1 > "$RUN/sel"; echo 0 > "$RUN/vol_ver"

  /etc/init.d/framework stop >/dev/null 2>&1
  lipc-set-prop com.lab126.powerd preventScreenSaver 1
  wifi 1   # se il pannello è stato fermato in pausa, il WiFi è ancora spento
  sleep 2
  full_refresh

  # FIFO aperte in lettura e scrittura qui, prima dei figli: chi scrive non
  # si blocca mai, anche se il lettore non è ancora partito
  mkfifo "$RUN/keys" "$RUN/poll" "$RUN/send"
  exec 4<> "$RUN/keys" 5<> "$RUN/poll" 6<> "$RUN/send"
  poller & pids="$pids $!"
  sender & pids="$pids $!"
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

# Uccide il processo principale e poi tutti gli altri "dashboard.sh run":
# uccidendo solo il principale, a ogni riavvio restavano vivi i vecchi
# lettori dei tasti. Il ps del Kindle è quello di procps, quindi -ef funziona.
kill_panel() {
  local p
  [ -f "$RUN/pid" ] && kill "$(cat "$RUN/pid")" 2>/dev/null
  for p in $(ps -ef | sed -n 's/^[^ ]* *\([0-9]*\) .*dashboard\.sh run$/\1/p'); do
    kill "$p" 2>/dev/null
  done
  rm -f "$RUN/pid"
  sleep 1
}

stop() {
  kill_panel
  lipc-set-prop com.lab126.cmd wirelessEnable 1   # fermato in pausa: il WiFi era spento
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
  BATT=$(battery_text)
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
