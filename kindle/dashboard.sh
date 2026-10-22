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
FONT_ICONS=${PREVIEW_ICONS:-$FONT_ICONS}
SCREEN_W=600
SCREEN_H=800
MARGIN=30

# Screen zones: starting y and height (and x and width when narrower)
CLK_Y=0;   CLK_H=214; CLK_W=360          # time and date, top left
ST_Y=0;    ST_H=44;   ST_X=360           # battery and pause, top right
WX_Y=44;   WX_H=170;  WX_X=360           # weather now, under the battery
FC_Y=214;  FC_H=170                      # 3-day forecast, in columns
SP_Y=384;  SP_H=164                      # music
PR_Y=548;  PR_H=30                       # track progress
LT_Y=582;  LT_H=176                      # lights: one tile each, side by side
TILE_X=28; TILE_W=172; TILE_GAP=14
LG_Y=760;  LG_H=40                       # key legend

# Icons: one character each in fonts/icons.ttf, made by tools/make_icons.py
# from this table (I_name=character  # Material Design Icons name). If the
# font is missing the panel works the same, just without icons.
I_sun=a        # weather-sunny
I_moon=b       # weather-night
I_partly=c     # weather-partly-cloudy
I_partlyn=d    # weather-night-partly-cloudy
I_cloudy=e     # weather-cloudy
I_fog=f        # weather-fog
I_drizzle=g    # weather-rainy
I_rain=h       # weather-pouring
I_sleet=i      # weather-snowy-rainy
I_snow=j       # weather-snowy
I_snowheavy=k  # weather-snowy-heavy
I_storm=l      # weather-lightning-rainy
I_hail=m       # weather-hail
I_thermo=n     # thermometer
I_humidity=o   # water-percent
I_wind=p       # weather-windy
I_umbrella=q   # umbrella-outline
I_bulb=r       # lightbulb
I_sofa=s       # sofa
I_kitchen=t    # stove
I_desk=u       # desk-lamp
I_ceiling=v    # ceiling-light
I_floor=w      # floor-lamp
I_bed=x        # bed
I_tv=y         # television
I_strip=z      # led-strip-variant
I_note=A       # music-note
I_pause=B      # pause
I_play=C       # play
I_musicoff=D   # music-off
I_speaker=E    # speaker
I_volume=F     # volume-high
I_volminus=G   # volume-minus
I_volplus=H    # volume-plus
I_next=I       # skip-next
I_prev=J       # skip-previous
I_wifioff=K    # wifi-off
I_cloudoff=L   # cloud-off-outline
I_lr=M         # arrow-left-right
I_ud=N         # arrow-up-down
I_center=O     # radiobox-marked
I_keyboard=P   # keyboard
I_back=Q       # keyboard-return
I_home=R       # home
I_menu=S       # menu
I_qr=T         # qrcode
I_wifi=U       # wifi
I_bat0=0       # battery-outline
I_bat1=1       # battery-10
I_bat2=2       # battery-20
I_bat3=3       # battery-30
I_bat4=4       # battery-40
I_bat5=5       # battery-50
I_bat6=6       # battery-60
I_bat7=7       # battery-70
I_bat8=8       # battery-80
I_bat9=9       # battery-90
I_bat10=V      # battery
I_batc=W       # battery-charging

# The sender's debounce step
if have usleep; then
  tick() { usleep 250000; }
else
  tick() { sleep 1; }
fi

# ---------- helpers ----------

# Loads the light settings into ID_n, NAME_n and ICON_n (the icon's character)
load_lights() {
  local i=1 x old_ifs=$IFS
  for x in $LIGHT_IDS; do eval "ID_$i=\$x"; i=$((i + 1)); done
  NLIGHTS=$((i - 1))
  i=1; for x in $LIGHT_ICONS; do eval "ICON_$i=\${I_$x:-\$I_bulb}"; i=$((i + 1)); done
  while [ $i -le $NLIGHTS ]; do eval "ICON_$i=\$I_bulb"; i=$((i + 1)); done
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

mmss() { printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); }

# round_temp "17,4": sets TEMP to the rounded value ("17"; "-3,6" gives "-4")
round_temp() {
  local v=$1 sign="" i d
  case "$v" in -*) sign=-; v=${v#-} ;; esac
  i=${v%%,*}; d=${v#"$i"}; d=${d#,}
  case "$d" in [5-9]*) i=$((i + 1)) ;; esac
  [ "$i" = 0 ] && sign=""
  TEMP=$sign$i
}

# Night, for the icon of the weather now: from 20:00 to 7:00
is_night() {
  local h=${NOW_HM%%:*}
  h=${h#0}
  [ "${h:-12}" -lt 7 ] || [ "${h:-12}" -ge 20 ]
}

# weather_icon DESCRIPTION [night]: sets WICON from the gateway's description
# (weatherDesc() in the sketch)
weather_icon() {
  case "$1" in
    Sereno) WICON=$I_sun; [ "$2" = night ] && WICON=$I_moon ;;
    "Poco nuvoloso" | "Parz. nuvoloso") WICON=$I_partly; [ "$2" = night ] && WICON=$I_partlyn ;;
    Nebbia) WICON=$I_fog ;;
    Pioviggine | "Pioggia debole") WICON=$I_drizzle ;;
    *gelata | Nevischio) WICON=$I_sleet ;;
    "Neve forte") WICON=$I_snowheavy ;;
    *[Nn]eve*) WICON=$I_snow ;;
    Pioggia* | Rovesci*) WICON=$I_rain ;;
    *grandine) WICON=$I_hail ;;
    Temporale*) WICON=$I_storm ;;
    *) WICON=$I_cloudy ;;
  esac
}

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

# Zones are full width unless LEFT and WIDTH are given
zone_clear() { fb -b -k "top=$1,left=${3:-0},width=${4:-$SCREEN_W},height=$2"; }
zone_refresh() { fb -s "top=$1,left=${3:-0},width=${4:-$SCREEN_W},height=$2"; }

# Text is drawn without background (-O), so it can sit on gray boxes: every
# zone is cleared before being redrawn anyway. COLOR is BLACK, GRAY1 (dark)
# ... GRAYE (light) or WHITE.

# text TOP PX FONT LEFT RIGHT TEXT [COLOR]: one line, truncated if it doesn't fit
text() {
  fb -b -O -C "${7:-BLACK}" -t "regular=$3,px=$2,top=$1,bottom=$((SCREEN_H - $1 - $2 * 3 / 2)),left=$4,right=$5" "$6"
}

# text_c TOP PX FONT TEXT [COLOR]: one centered line
text_c() { text_m "$1" "$2" "$3" $MARGIN $((SCREEN_W - 2 * MARGIN)) "$4" "$5"; }

# text_m TOP PX FONT LEFT WIDTH TEXT [COLOR]: centered in a column
text_m() {
  fb -b -O -m -C "${7:-BLACK}" -t "regular=$3,px=$2,top=$1,bottom=$((SCREEN_H - $1 - $2 * 3 / 2)),left=$4,right=$((SCREEN_W - $4 - $5))" "$6"
}

# icon TOP PX LEFT CHARS [COLOR]: icons are square, PX wide
icon() {
  [ -n "$4" ] && [ -f "$FONT_ICONS" ] || return 0
  text "$1" "$2" "$FONT_ICONS" "$3" $((SCREEN_W - $3 - $2 * ${#4})) "$4" "$5"
}

# icon_m TOP PX LEFT WIDTH CHARS [COLOR]: centered in a column
icon_m() {
  [ -n "$5" ] && [ -f "$FONT_ICONS" ] || return 0
  text_m "$1" "$2" "$FONT_ICONS" "$3" "$4" "$5" "$6"
}

# Filled rectangle: box TOP LEFT WIDTH HEIGHT COLOR
box() { [ "$4" -gt 0 ] && fb -b -B "$5" -k "top=$1,left=$2,width=$3,height=$4"; }

# Thin gray line across the screen, between sections
hline() { box "$1" $MARGIN $((SCREEN_W - 2 * MARGIN)) 2 GRAYC; }

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

# Bottom strip with the legend for the keys below the screen: LEGEND_KEYS_*
# is a list of "icon label" separated by ";", spread over equal slots.
draw_legend() {
  local legend=$LEGEND_KEYS_IDLE at item name c n=0 x w old_ifs=$IFS
  [ "$(status_value sp_active)" = 1 ] && legend=$LEGEND_KEYS_MUSIC
  if paused; then
    read -r at < "$RUN/paused_at" 2>/dev/null
    legend="In pausa, dati delle $at  ·  $LEGEND_PAUSE"
  fi
  changed legend "$legend" || return 0
  zone_clear $LG_Y $LG_H
  hline $LG_Y
  if paused; then
    text_c $((LG_Y + 12)) 18 "$FONT" "$legend"
  else
    set -f; IFS=';'
    for item in $legend; do n=$((n + 1)); done
    [ $n -gt 0 ] || n=1
    w=$(((SCREEN_W - 2 * MARGIN) / n)); x=$MARGIN
    for item in $legend; do
      item=${item# }; name=${item%% *}
      eval "c=\${I_$name:-}"
      icon $((LG_Y + 10)) 22 $x "$c"
      text $((LG_Y + 13)) 15 "$FONT" $((x + 25)) $((SCREEN_W - x - w + 2)) "${item#* }"
      x=$((x + w))
    done
    IFS=$old_ifs; set +f
  fi
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

# A tile per light. The gray fills the tile from the bottom as far as the
# brightness; the selected light has a thick black frame.
draw_light_row() { # INDEX
  local i=$1 on b name ic x y=$LT_Y h=$LT_H bw=2 frame=GRAYA color=GRAY8 sel=0
  read -r on < "$RUN/l${i}_on"
  read -r b < "$RUN/l${i}_b"
  [ "$(selected)" = "$i" ] && sel=1
  changed "light_$i" "$on|$b|$sel" || return 0
  eval "name=\$NAME_$i; ic=\$ICON_$i"
  x=$((TILE_X + (i - 1) * (TILE_W + TILE_GAP)))
  [ $sel = 1 ] && bw=5 frame=BLACK
  [ "$on" = 1 ] && color=BLACK
  zone_clear $y $h $x $TILE_W
  box $y $x $TILE_W $h $frame
  box $((y + bw)) $((x + bw)) $((TILE_W - 2 * bw)) $((h - 2 * bw)) WHITE
  [ "$on" = 1 ] && box $((y + h - bw - (h - 2 * bw) * b / 100)) $((x + bw)) $((TILE_W - 2 * bw)) $(((h - 2 * bw) * b / 100)) GRAYD
  icon_m $((y + 16)) 64 $x $TILE_W "$ic" $color
  text_m $((y + 90)) 24 "$FONT_BOLD" $((x + bw)) $((TILE_W - 2 * bw)) "$name" $color
  if [ "$on" = 1 ]; then
    text_m $((y + 124)) 34 "$FONT_BOLD" $x $TILE_W "$b%"
  else
    text_m $((y + 130)) 24 "$FONT" $x $TILE_W "spenta" $color
  fi
  zone_refresh $y $h $x $TILE_W
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

select_light() { # DELTA (+1 right, -1 left), without wrapping around
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
  draw_clock "$1"
  draw_status "$1"
}

# Time and date, big, top left
draw_clock() { # OFFLINE
  local date=$S_date time=${NOW_HM:-$S_time}
  [ "$1" = 1 ] && date="Gateway non risponde"
  changed clock "$time|$date" || return 0
  zone_clear $CLK_Y $CLK_H 0 $CLK_W
  text $((CLK_Y + 22)) 112 "$FONT_BOLD" $MARGIN $((SCREEN_W - CLK_W)) "$time"
  text $((CLK_Y + 152)) 26 "$FONT" $MARGIN $((SCREEN_W - CLK_W)) "$date"
  zone_refresh $CLK_Y $CLK_H 0 $CLK_W
}

# Battery top right, in bold when it needs charging; before it, the
# pause and the unreachable gateway
draw_status() { # OFFLINE
  local batt=$BATT lvl font=$FONT ic x=$((SCREEN_W - MARGIN - 92)) p=0
  paused && p=1
  changed status "$batt|$1|$p" || return 0
  zone_clear $ST_Y $ST_H $ST_X $((SCREEN_W - ST_X))
  if [ -n "$batt" ]; then
    lvl=${batt#⚡}; lvl=${lvl%\%}
    if [ "$lvl" != "${batt%\%}" ]; then ic=$I_batc
    elif [ "$lvl" -ge 0 ] 2>/dev/null; then eval "ic=\${I_bat$(((lvl + 5) / 10)):-}"; fi
    [ "$lvl" -lt "$BATTERY_LOW" ] 2>/dev/null && font=$FONT_BOLD
    icon $((ST_Y + 10)) 28 $x "$ic"
    text $((ST_Y + 13)) 20 "$font" $((x + 30)) $MARGIN "$lvl%"
  fi
  [ $p = 1 ] && x=$((x - 34)) && icon $((ST_Y + 10)) 26 $x "$I_wifioff" GRAY6
  [ "$1" = 1 ] && x=$((x - 34)) && icon $((ST_Y + 10)) 26 $x "$I_cloudoff"
  zone_refresh $ST_Y $ST_H $ST_X $((SCREEN_W - ST_X))
}

# A forecast column: day, icon, min / max, chance of rain
forecast_col() { # X "Label|Description|min|max|rain%"
  local x=$1 w=$(((SCREEN_W - 2 * MARGIN) / 3)) cx IFS='|'
  set -f
  set -- $1 $2
  set +f
  cx=$((x + w / 2))
  weather_icon "$3"
  text_m $((FC_Y + 14)) 22 "$FONT_BOLD" $x $w "$2"
  icon_m $((FC_Y + 44)) 64 $x $w "$WICON"
  text_m $((FC_Y + 112)) 24 "$FONT" $x $w "$4°  /  $5°"
  icon $((FC_Y + 142)) 20 $((cx - 34)) "$I_umbrella" GRAY5
  text $((FC_Y + 142)) 20 "$FONT" $((cx - 10)) $((SCREEN_W - x - w)) "$6%" GRAY3
}

draw_weather() {
  local night="" w=$(((SCREEN_W - 2 * MARGIN) / 3)) x=$((WX_X + 6))
  is_night && night=night
  changed weather "$S_w_ok|$S_w_temp|$S_w_desc|$S_w_feels|$S_w_hum|$S_w_wind|$S_d0|$S_d1|$S_d2|$night" || return 0
  zone_clear $WX_Y $WX_H $WX_X $((SCREEN_W - WX_X))
  zone_clear $FC_Y $FC_H
  hline $((FC_Y + 2))
  if [ "$S_w_ok" = 1 ]; then
    weather_icon "$S_w_desc" $night
    round_temp "$S_w_temp"
    icon $((WX_Y + 4)) 88 $x "$WICON"
    text $((WX_Y + 12)) 64 "$FONT_BOLD" $((x + 96)) 0 "$TEMP°"
    text $((WX_Y + 98)) 22 "$FONT" $x $MARGIN "$S_w_desc"
    round_temp "$S_w_feels"
    icon $((WX_Y + 134)) 20 $x "$I_thermo" GRAY5
    text $((WX_Y + 134)) 20 "$FONT" $((x + 20)) 0 "$TEMP°"
    icon $((WX_Y + 134)) 20 $((x + 70)) "$I_humidity" GRAY5
    text $((WX_Y + 134)) 20 "$FONT" $((x + 92)) 0 "$S_w_hum%"
    icon $((WX_Y + 134)) 20 $((x + 152)) "$I_wind" GRAY5
    text $((WX_Y + 134)) 20 "$FONT" $((x + 176)) 0 "$S_w_wind"
    forecast_col $MARGIN "$S_d0"
    forecast_col $((MARGIN + w)) "$S_d1"
    forecast_col $((MARGIN + 2 * w)) "$S_d2"
    box $((FC_Y + 20)) $((MARGIN + w)) 2 136 GRAYD
    box $((FC_Y + 20)) $((MARGIN + 2 * w)) 2 136 GRAYD
  else
    icon $((WX_Y + 10)) 60 $x "$I_cloudoff" GRAY6
    text $((FC_Y + 60)) 30 "$FONT" $MARGIN $MARGIN "Meteo non disponibile"
  fi
  zone_refresh $WX_Y $WX_H $WX_X $((SCREEN_W - WX_X))
  zone_refresh $FC_Y $FC_H
}

# The music: a black "cover" with play/pause, track, artist, speaker and
# volume. The small icons on the edges are next to the page keys.
draw_spotify() {
  local state
  local vol=${S_sp_volume:--1} now until=0 x=162 art=116
  now=$(date +%s)
  [ -f "$RUN/vol_until" ] && read -r until < "$RUN/vol_until"
  [ "$now" -lt "$until" ] && read -r vol < "$RUN/vol_target"   # value just chosen with the keys
  if [ "$S_sp_ok" != 1 ]; then state=offline
  elif [ "$S_sp_active" != 1 ]; then state=idle
  elif [ "$S_sp_playing" = 1 ]; then state=play
  else state=pause; fi
  [ "$S_sp_active" = 1 ] || S_sp_track="" S_sp_artist=""
  [ "$vol" -ge 0 ] 2>/dev/null || vol=""

  if changed spotify "$state|$S_sp_track|$S_sp_artist|$S_sp_device|$vol"; then
    zone_clear $SP_Y $SP_H
    hline $((SP_Y + 2))
    case $state in
      offline | idle)
        if [ $state = offline ]; then
          icon $((SP_Y + 46)) 56 $MARGIN "$I_cloudoff" GRAY8
          text $((SP_Y + 58)) 26 "$FONT" $((MARGIN + 72)) $MARGIN "Spotify non raggiungibile"
        else
          icon $((SP_Y + 46)) 56 $MARGIN "$I_musicoff" GRAY8
          text $((SP_Y + 44)) 26 "$FONT" $((MARGIN + 72)) $MARGIN "A casa non suona niente"
          icon $((SP_Y + 82)) 22 $((MARGIN + 72)) "$I_back" GRAY6
          text $((SP_Y + 82)) 20 "$FONT" $((MARGIN + 100)) $MARGIN "fa partire la musica" GRAY4
        fi ;;
      *)
        box $((SP_Y + 18)) $MARGIN $art $art BLACK
        if [ $state = play ]; then
          icon_m $((SP_Y + 36)) 80 $MARGIN $art "$I_note" WHITE
        else
          icon_m $((SP_Y + 36)) 80 $MARGIN $art "$I_pause" WHITE
        fi
        text $((SP_Y + 16)) 30 "$FONT_BOLD" $x $MARGIN "$S_sp_track"
        text $((SP_Y + 58)) 24 "$FONT" $x $MARGIN "$S_sp_artist"
        icon $((SP_Y + 100)) 22 $x "$I_speaker" GRAY5
        text $((SP_Y + 100)) 20 "$FONT" $((x + 26)) 170 "$S_sp_device" GRAY3
        if [ -n "$vol" ]; then
          icon $((SP_Y + 100)) 22 446 "$I_volume" GRAY5
          text $((SP_Y + 100)) 20 "$FONT" 472 $MARGIN "$vol%" GRAY3
        fi
        # Page keys: back (upper) and forward (lower), left and right
        icon $((SP_Y + 26)) 22 4 "$I_volminus" GRAY6
        icon $((SP_Y + 96)) 22 4 "$I_volplus" GRAY6
        icon $((SP_Y + 26)) 22 $((SCREEN_W - 26)) "$I_prev" GRAY6
        icon $((SP_Y + 96)) 22 $((SCREEN_W - 26)) "$I_next" GRAY6 ;;
    esac
    zone_refresh $SP_Y $SP_H
  fi

  # The progress bar has a zone of its own: it's updated only when it advances
  # by one step (7 px), not on every read.
  local dur=${S_sp_duration:-0} bw=$((470 - x)) fill=0 line=""
  if [ $state = play ] || [ $state = pause ] && [ "$dur" -gt 0 ]; then
    fill=$((${S_sp_progress:-0} * (bw / 7) / dur * 7))
    [ $fill -gt $bw ] && fill=$bw
    line="$fill|$dur"
  fi
  if changed progress "$line"; then
    zone_clear $PR_Y $PR_H
    if [ -n "$line" ]; then
      box $((PR_Y + 10)) $x $bw 8 GRAYC
      box $((PR_Y + 10)) $x $fill 8 BLACK
      text $((PR_Y + 3)) 20 "$FONT" 484 $MARGIN "$(mmss "$dur")" GRAY3
    fi
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
  hline $LG_Y
  text_c $((LG_Y + 12)) 18 "$FONT" "Riconnessione…"
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
    "$KEY_DOWN") adjust_light "$(selected)" "-$STEP"; return ;;
    "$KEY_UP") adjust_light "$(selected)" "$STEP"; return ;;
    "$KEY_VOL_UP") music_at_home && volume_change "$VOLUME_STEP"; return ;;
    "$KEY_VOL_DOWN") music_at_home && volume_change "-$VOLUME_STEP"; return ;;
  esac
  [ "$2" = 1 ] || return
  case "$1" in
    "$KEY_LEFT") select_light -1 ;;
    "$KEY_RIGHT") select_light 1 ;;
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
  NOW_HM=$S_time
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
