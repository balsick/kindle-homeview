#!/bin/sh
# Home panel for the Kindle 5 (jailbroken firmware 4.1.x).
#
# Usage: sh /mnt/us/dashboard/dashboard.sh start|stop|restart|update|keytest|autostart on|off
#        (preview is used by tools/preview.py to render the screen on a computer)
#
# Processes:
#   - key readers: one per /dev/input/eventX, they write "code value" to a FIFO
#   - input (main): reads the FIFO, updates the state and redraws the light's row
#   - sender: sends the latest value to the Shelly once the keys stop (debounce)
#   - poller: reads /status from the Arduino and redraws time, weather, Spotify
#             and lights; it also starts the OTA update check (ota.sh) and,
#             when nothing changes, turns the WiFi off (pause)
# Each screen zone is redrawn only if its content changed.
# The Home key shows the QR codes (guest WiFi and webapp); any key goes back.
#
# Power: the Kindle never suspends, so every wake-up counts. Sender and
# poller block on a FIFO until there's something to do (kick_sender,
# poll_now) instead of spinning.

DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"   # configuration (defaults.sh + config.sh) and http_get

FBINK=${PREVIEW_FBINK:-$FBINK}
SCREEN_W=600
SCREEN_H=800
MARGIN=30

# Screen zones: starting y and height
HDR_Y=0;   HDR_H=150
WX_Y=150;  WX_H=215
SP_Y=365;  SP_H=132
PR_Y=497;  PR_H=40
LT_Y=540;  ROW_H=72
LG_Y=760;  LG_H=40

# The sender's debounce step
if have usleep; then
  tick() { usleep 250000; }
else
  tick() { sleep 1; }
fi

# ---------- helpers ----------

# Loads the light settings into ID_n and NAME_n
load_lights() {
  local i=1 x old_ifs=$IFS
  for x in $LIGHT_IDS; do eval "ID_$i=\$x"; i=$((i + 1)); done
  NLIGHTS=$((i - 1))
  IFS='|'
  i=1; for x in $LIGHT_NAMES; do eval "NAME_$i=\$x"; i=$((i + 1)); done
  IFS=$old_ifs
}

# Light picked with the joystick (1..NLIGHTS)
selected() {
  local sel=1
  [ -f "$RUN/sel" ] && read -r sel < "$RUN/sel"
  echo "$sel"
}

# Value of a key from the last /status, for callers that didn't run load_status
status_value() { sed -n "s/^$1=//p" "$RUN/status" 2>/dev/null; }

qr_mode() {
  local mode=""
  [ -f "$RUN/mode" ] && read -r mode < "$RUN/mode"
  [ "$mode" = qr ]
}

# changed ZONE SIGNATURE: true if the zone needs redrawing. While the QR codes
# are on screen nothing is drawn: everything is redrawn on exit.
changed() {
  local old=""
  qr_mode && return 1
  [ -f "$RUN/cache_$1" ] && read -r old < "$RUN/cache_$1"
  [ "$old" = "$2" ] && return 1
  printf '%s\n' "$2" > "$RUN/cache_$1"
  return 0
}

bar() { # FILLED TOTAL
  local i=0 s=""
  while [ $i -lt "$2" ]; do
    if [ $i -lt "$1" ]; then s="${s}■"; else s="${s}□"; fi
    i=$((i + 1))
  done
  printf '%s' "$s"
}

mmss() { printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); }

# "06:30" -> minutes since midnight (leading zeros dropped: "08" isn't octal)
hhmm_min() {
  local h=${1%:*} m=${1#*:}
  echo $((${h#0} * 60 + ${m#0}))
}

# Wake-ups between processes: the poller waits on descriptor 5, the sender on
# 6 (FIFOs opened by run). Outside run (preview) there's nobody to wake.
poll_now() { { echo >&5; } 2>/dev/null; }
kick_sender() { { echo >&6; } 2>/dev/null; }

# wait_poll SECONDS: waits for the timer or a poll_now, whichever comes first.
# As in http_get, the timer kills its sleep once it's no longer needed.
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

# ---------- drawing (FBInk) ----------
# Everything is drawn without refresh (-b), then the whole zone is updated
# with a single partial refresh, so there's no intermediate flicker.

fb() { "$FBINK" -q "$@" >/dev/null 2>&1; }

zone_clear() { fb -b -k "top=$1,left=0,width=$SCREEN_W,height=$2"; }
zone_refresh() { fb -s "top=$1,left=0,width=$SCREEN_W,height=$2"; }

# text TOP PX FONT LEFT RIGHT TEXT: one line, truncated if it doesn't fit
text() {
  fb -b -t "regular=$3,px=$2,top=$1,bottom=$((SCREEN_H - $1 - $2 * 3 / 2)),left=$4,right=$5" "$6"
}

# text_c TOP PX FONT TEXT: one centered line
text_c() {
  fb -b -m -t "regular=$3,px=$2,top=$1,bottom=$((SCREEN_H - $1 - $2 * 3 / 2)),left=$MARGIN,right=$MARGIN" "$4"
}

# Filled black rectangle (for lines): rect TOP LEFT WIDTH HEIGHT
rect() { fb -b -B BLACK -k "top=$1,left=$2,width=$3,height=$4"; }

# image FILE TOP: PNG centered horizontally. KOReader's FBInk has no image
# support: if the PNG has make_qr.py's .raw next to it (screen-wide rows, one
# byte per pixel) we copy that into the framebuffer.
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

# Bottom strip with the legend for the keys below the screen
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

# ---------- lights ----------

# The selected light has a black bar on the left and, under its name, the keys
draw_light_row() { # INDEX
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

# Every change bumps l_N_ver: the sender compares versions for the debounce.
set_light() { # INDEX ON BRIGHTNESS
  local v
  echo "$2" > "$RUN/l$1_on"
  echo "$3" > "$RUN/l$1_b"
  read -r v < "$RUN/l$1_ver"
  echo $((v + 1)) > "$RUN/l$1_ver"
  draw_light_row "$1"
  kick_sender
}

adjust_light() { # INDEX DELTA
  local on b
  read -r on < "$RUN/l$1_on"
  read -r b < "$RUN/l$1_b"
  if [ "$on" != 1 ]; then
    [ "$2" -lt 0 ] && return    # already off
    on=1; b=$STEP               # from off, start at the minimum
  else
    b=$((b + $2))
    if [ $b -le 0 ]; then on=0; b=$STEP; fi
    [ $b -gt 100 ] && b=100
  fi
  set_light "$1" $on $b
}

select_light() { # DELTA (+1 down, -1 up), without wrapping around
  local old new
  old=$(selected); new=$((old + $1))
  [ $new -lt 1 ] && new=1
  [ $new -gt "$NLIGHTS" ] && new=$NLIGHTS
  [ $new = "$old" ] && return
  echo $new > "$RUN/sel"
  draw_light_row "$old"
  draw_light_row "$new"
}

toggle_light() { # INDEX
  local on b
  read -r on < "$RUN/l$1_on"
  read -r b < "$RUN/l$1_b"
  set_light "$1" $((1 - on)) "$b"
}

# Keyboard key: if at least one light is on it switches them all off,
# otherwise it switches them all back on at their last brightness.
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

send_light() { # INDEX
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

# Lights changed from the app, the webapp or a wall switch. Changes not yet
# sent (the sender writes l_N_sent) and those made during the request are not
# overwritten: that's why the poller records the versions from before the
# request in pv_N (light_versions).
light_versions() {
  local i=1 v
  while [ $i -le "$NLIGHTS" ]; do
    read -r v < "$RUN/l${i}_ver"; eval "pv_$i=\$v"
    i=$((i + 1))
  done
}

light_untouched() { # INDEX
  local ver sent pv
  read -r ver < "$RUN/l$1_ver"
  read -r sent < "$RUN/l$1_sent"
  eval "pv=\$pv_$1"
  [ "$ver" = "$sent" ] && [ "$ver" = "$pv" ]
}

store_light() { # INDEX ON BRIGHTNESS (brightness 0: off)
  local on=$2 b=$3
  [ "$b" -gt 0 ] 2>/dev/null || { on=0; b=$STEP; }
  echo "$on" > "$RUN/l$1_on"
  echo "$b" > "$RUN/l$1_b"
}

# An up-to-date gateway reads the Shelly itself on every /status (lc_ok=1 and
# lcN=on|brightness, N = channel): one request from the Kindle instead of four.
lights_from_status() {
  local i=1 id st
  while [ $i -le "$NLIGHTS" ]; do
    eval "id=\$ID_$i"
    eval "st=\${S_lc$id:-}"
    unset "S_lc$id"   # if the next /status lacks it, this one isn't reused
    [ -n "$st" ] && light_untouched $i && store_light $i "${st%|*}" "${st#*|}"
    i=$((i + 1))
  done
  draw_lights
}

# With an older gateway we ask the Shelly, one light at a time
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

# Volume: the keys change vol_target and vol_ver; the sender sends only the
# final value to the Arduino, once the keys stop (as for the lights).
volume_change() { # DELTA
  local cur v now until=0
  now=$(date +%s)
  [ -f "$RUN/vol_until" ] && read -r until < "$RUN/vol_until"
  if [ "$now" -lt "$until" ]; then read -r cur < "$RUN/vol_target"; else cur=$(status_value sp_volume); fi
  [ "${cur:--1}" -ge 0 ] 2>/dev/null || return   # the device has no volume control
  cur=$((cur + $1))
  [ $cur -lt 0 ] && cur=0
  [ $cur -gt 100 ] && cur=100
  echo $cur > "$RUN/vol_target"
  echo $((now + 5)) > "$RUN/vol_until"   # for 5 s the screen shows the chosen value
  read -r v < "$RUN/vol_ver"; echo $((v + 1)) > "$RUN/vol_ver"
  load_status; draw_spotify
  kick_sender
}

send_volume() {
  local v
  read -r v < "$RUN/vol_target"
  http_get "http://$ARDUINO_HOST/cmd?a=vol&v=$v" 10 "$RUN/vol.out" && poll_now
}

# Sleeps on the FIFO until a key changes lights or volume (kick_sender), then
# runs tick by tick until everything is sent.
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
          # send only if the version hasn't changed since the last tick (debounce)
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

# ---------- state from the Arduino ----------

# Each "key=value" line becomes the variable S_key
load_status() {
  local line k
  while IFS= read -r line; do
    k=${line%%=*}
    case "$k" in "" | *[!a-z0-9_]*) continue ;; esac
    eval "S_$k=\${line#*=}"
  done < "$RUN/status"
}

# Kindle battery: "96%", with ⚡ when plugged in. Empty if it can't be read.
# The battery is read from sysfs with read: no processes. "⚡" means the cable
# is plugged in (USB connected): powerd's isCharging is 0 when the battery is
# nearly full even if plugged in.
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

# Internal clock: the Arduino's time (S_time) calibrated against the Kindle's
# clock on every /status, so time keeps going with WiFi off. Only the
# difference in minutes is kept, so the Kindle's time zone doesn't matter.
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

# The battery is read (two lipc-get-prop calls) only when the minute changes
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
  # Top right, in bold when it needs charging
  [ "${batt%\%}" -lt "$BATTERY_LOW" ] 2>/dev/null && font=$FONT_BOLD
  [ -n "$batt" ] && text $((HDR_Y + 12)) 20 "$font" $((SCREEN_W - MARGIN - 64)) $MARGIN "$batt"
  zone_refresh $HDR_Y $HDR_H
}

forecast_row() { # Y "Label|Description|min|max|rain%"
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
  [ "$now" -lt "$until" ] && read -r vol < "$RUN/vol_target"   # value just chosen with the keys
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

  # The progress bar has a zone of its own: it's updated only when it advances
  # by one segment, not on every read.
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
  draw_legend   # the legend depends on the music
}

# ---------- pause ----------
# If nothing changes for IDLE_MINUTES (no key, same lights, same music and no
# track playing), the panel pauses: WiFi off, the time keeps going on the
# internal clock, and every SLEEP_CHECK_MINUTES the WiFi comes back on for a
# /status. If something changed the panel stays awake, otherwise it pauses
# again. A key wakes it right away; while charging it never pauses.

paused() {
  local mode=""
  [ -f "$RUN/mode" ] && read -r mode < "$RUN/mode"
  [ "$mode" = pause ]
}

wifi() { # 0|1: turns WiFi off or on; when turning on, waits for the connection
  local i=0
  have lipc-set-prop || return 0
  lipc-set-prop com.lab126.cmd wirelessEnable "$1" 2>/dev/null
  [ "$1" = 1 ] || return 0
  while [ $i -lt 60 ] && [ "$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)" != CONNECTED ]; do
    sleep 1; i=$((i + 1))
  done
}

# Called by keys while paused: the first key only wakes, as with the QR codes
wake_up() {
  zone_clear $LG_Y $LG_H
  text_c $((LG_Y + 10)) 18 "$FONT" "Riconnessione…"
  zone_refresh $LG_Y $LG_H
  poll_now
}

# Signature of what matters for the pause: if it changes, the panel stays awake
activity() {
  local i=1 on b s="$S_sp_active|$S_sp_playing|$S_sp_track|$S_sp_device"
  while [ $i -le "$NLIGHTS" ]; do
    read -r on < "$RUN/l${i}_on"; read -r b < "$RUN/l${i}_b"
    s="$s|$on:$b"
    i=$((i + 1))
  done
  printf '%s' "$s"
}

# Stays paused until the next check, a key, the charging cable or midnight
# (the date must be re-read). WiFi is turned off here.
pause_wait() {
  local check_at sec
  if ! paused; then
    echo pause > "$RUN/mode"
    battery_log pause
    # So the gateway doesn't report the Kindle as offline (kindleOnline)
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
    [ "$(date +%s)" -ge $((check_at - 30)) ] && break   # wake-ups happen on the minute
    battery_update
    [ "$CHARGING" = 1 ] && break
    draw_header 0
  done
  wifi 1
}

pause_end() {
  paused || return 0
  echo dash > "$RUN/mode"
  battery_log awake
  draw_legend
}

# ---------- battery log ----------
# battery.log: "epoch_seconds time battery current [event]", to measure consumption.

battery_log() { # [EVENT]
  [ "${BATTERY_LOG_MINUTES:-0}" -gt 0 ] && [ -z "$PREVIEW_FBINK" ] || return 0
  echo "$(date +%s) $(clock_now) $(battery_text) $(battery_current) $1" >> "$DIR/battery.log"
}

battery_log_trim() {
  local f="$DIR/battery.log"
  [ -f "$f" ] && [ "$(wc -l < "$f")" -gt 3000 ] && tail -n 2000 "$f" > "$f.new" && mv "$f.new" "$f"
}

# ---------- poller ----------

# How long to wait before the next /status: with music or while charging
# POLL_SECONDS, otherwise until the minute ticks over (plus a couple of
# seconds of margin: the Kindle's clock isn't the Arduino's).
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
  ota_at=$((now + 120))   # first check shortly after startup
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
    if [ -e "$RUN/key_seen" ]; then   # created by handle_key on every key
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
    : > "$RUN/alive"   # for ota.sh: the main loop is running

    if [ "${BATTERY_LOG_MINUTES:-0}" -gt 0 ] && [ $now -ge $log_at ]; then
      battery_log
      log_at=$((now + BATTERY_LOG_MINUTES * 60))
    fi

    # Updates: periodic, or requested from the webapp (ota_req changes)
    if [ -n "$ota_req" ] && [ "${S_ota_req:-}" != "$ota_req" ]; then ota_at=$now; fi
    ota_req=${S_ota_req:-0}
    if [ "$OTA_ENABLED" = 1 ] && [ "$now" -ge "$ota_at" ]; then
      ota_at=$((now + OTA_CHECK_HOURS * 3600))
      ota_start
    fi

    if [ $pause = 1 ]; then
      pause_wait
    else
      # Interruptible wait: after a Spotify command we re-read right away (poll_now)
      wait_poll "$(next_poll)"
    fi
  done
}

# ---------- input ----------

# Reads events from a device. struct input_event on 32-bit ARM, 16 bytes:
# sec(4) usec(4) type(2) code(2) value(4). The file stays open on descriptor 3,
# so no events are lost between reads.
# The Kindle 5 has no od: hexdump with this format prints the same 8 words.
u16dump() {
  if have od; then od -An -tu2 -v; else hexdump -v -e '8/2 "%u " "\n"'; fi
}

key_reader() { # DEVICE
  exec 3< "$1" || return
  while true; do
    set -- $(dd bs=16 count=1 <&3 2>/dev/null | u16dump)
    [ $# -ge 7 ] || { sleep 1; continue; }
    [ "$5" = 1 ] && echo "$6 $7"   # EV_KEY only: code, value (1 press, 2 repeat, 0 release)
  done
}

spotify_cmd() {
  ( http_get "http://$ARDUINO_HOST/cmd?a=$1" 10 "$RUN/cmd.out"; poll_now ) &
}

# Is music playing at home? (for the side keys)
music_at_home() { [ "$(status_value sp_active)" = 1 ]; }

handle_key() { # CODE VALUE (1 pressed, 2 held down)
  [ "$2" = 0 ] && return
  : > "$RUN/key_seen"        # for the pause: someone is using the panel
  if paused; then            # while paused a key only wakes the panel
    [ "$2" = 1 ] && wake_up
    return
  fi
  if qr_mode; then           # with the QR codes on screen any key goes back
    [ "$2" = 1 ] && hide_qr
    return
  fi
  # Holding a key repeats brightness and volume
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

# ---------- commands ----------

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
  wifi 1   # if the panel was stopped while paused, WiFi is still off
  sleep 2
  full_refresh

  # FIFOs opened read-write here, before the children: writers never block,
  # even if the reader hasn't started yet
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

# Starts ota.sh detached from the panel, which gets restarted during the update
ota_start() {
  ( trap '' HUP; exec sh "$DIR/ota.sh" update ) >> /tmp/dashboard-ota.log 2>&1 &
}

start() {
  if [ -f "$RUN/pid" ] && kill -0 "$(cat "$RUN/pid")" 2>/dev/null; then
    echo "The panel is already running"
    return 1
  fi
  ( trap '' HUP; exec sh "$DIR/dashboard.sh" run ) > /tmp/dashboard.log 2>&1 &
  echo "Panel started (log in /tmp/dashboard.log)"
}

# Kills the main process and then every other "dashboard.sh run" process:
# killing only the main pid left the old key readers alive at every restart.
# The Kindle's ps comes from procps, so -ef works.
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
  lipc-set-prop com.lab126.cmd wirelessEnable 1   # stopped while paused: WiFi was off
  lipc-set-prop com.lab126.powerd preventScreenSaver 0
  /etc/init.d/framework start >/dev/null 2>&1 &
  echo "Panel stopped, Kindle UI restarted"
}

keytest() {
  local dev
  echo "Input devices:"
  grep '^[NH]:' /proc/bus/input/devices
  echo
  echo "Press the keys (Ctrl+C to quit). Format: device code value"
  for dev in /dev/input/event*; do
    ( key_reader "$dev" | while read -r c v; do echo "$dev $c $v"; done ) &
  done
  wait
}

# preview STATUS_FILE "on:bri on:bri ..." [qr]: draws a single screen
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

# ---------- start at boot ----------
# Installs (on) or removes (off) /etc/init.d/dashboard, run at boot as
# S99dashboard after the Kindle UI. The script doesn't block the boot: in the
# background it waits for WiFi, then starts the panel. To skip one start
# without removing it, create $DIR/NO_AUTOSTART.
INIT_SCRIPT=/etc/init.d/dashboard
INIT_LINK=/etc/rc5.d/S99dashboard

autostart() { # on|off
  mount -o rw,remount / || return 1
  rm -f "$INIT_LINK" "$INIT_SCRIPT"
  if [ "$1" = on ]; then
    cat > "$INIT_SCRIPT" <<INIT
#!/bin/sh
# Home panel (kindle-homeview): created by dashboard.sh autostart on
[ "\$1" = start ] || exit 0
[ -f "$DIR/NO_AUTOSTART" ] && exit 0
[ -f "$DIR/dashboard.sh" ] || exit 0
(
  i=0
  while [ \$i -lt 180 ]; do
    [ "\$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)" = CONNECTED ] && break
    sleep 2; i=\$((i + 2))
  done
  sleep 15   # let the Kindle UI finish starting
  sh "$DIR/dashboard.sh" start
) > /tmp/dashboard-boot.log 2>&1 &
exit 0
INIT
    chmod 755 "$INIT_SCRIPT"
    ln -s ../init.d/dashboard "$INIT_LINK"
  fi
  sync
  mount -o ro,remount /
  if [ "$1" = on ]; then echo "Start at boot enabled"; else echo "Start at boot disabled"; fi
}

case "$1" in
  start) start ;;
  stop) stop ;;
  restart) kill_panel; start ;;            # without bringing back the Kindle UI
  update) sh "$DIR/ota.sh" update ;;       # manual OTA check, with output on the terminal
  run) run ;;
  keytest) keytest ;;
  autostart) autostart "$2" ;;
  preview) preview "$2" "$3" "$4" ;;
  *) echo "Usage: sh $0 start|stop|restart|update|keytest|autostart on|off"; exit 1 ;;
esac
# ota:end
