# Panel defaults. DON'T edit this on the Kindle: OTA updates replace it.
# To change a value, redefine it in config.sh, which stays on the Kindle
# only (see config.example.sh). Text shown on screen is in Italian.

ARDUINO_HOST="192.168.1.60"   # IP of the UNO R4 WiFi (reserve it in your router)
SHELLY_HOST="192.168.1.50"    # IP of the Shelly Plus RGBW PM ("light" profile, 4 channels)

# The lights, in the same order in all the lines below.
LIGHT_IDS="0 1 2"                                 # Shelly channel (0-3)
LIGHT_NAMES="Soggiorno|Cucina|Studio"
# Icons, from the I_ table in dashboard.sh: bulb sofa kitchen desk ceiling floor bed tv strip
LIGHT_ICONS="sofa kitchen desk"
STEP=10                                           # brightness step in %
VOLUME_STEP=10                                    # Spotify volume step in %

# Keys: codes measured on a Kindle 5 (firmware 4.1.4) with
# "dashboard.sh keytest". If your Kindle gives different codes, redefine
# them in config.sh.
INPUT_DEVICES="/dev/input/event0 /dev/input/event1"

# Joystick: the lights. ◀▶ picks the light, ▲▼ brightness, center on/off
KEY_UP=103
KEY_DOWN=108
KEY_LEFT=105
KEY_RIGHT=106
KEY_CENTER=194

# Page keys on the sides: the music playing at home
KEY_VOL_UP=104      # left, forward
KEY_VOL_DOWN=193    # left, back
KEY_TRACK_NEXT=191  # right, forward
KEY_TRACK_PREV=109  # right, back

KEY_PLAY=158      # Back: pause, or start music at home
KEY_ALL=29        # Keyboard: switches all lights off / back on
KEY_REFRESH=139   # Menu: full screen refresh
KEY_QR=102        # Home: QR codes for the guest WiFi and the webapp

# Legend in the bottom strip: changes depending on whether music plays at home.
# "icon label" pairs separated by ";", the icons from the I_ table in dashboard.sh.
LEGEND_KEYS_MUSIC="lr luce;ud intensità;center on/off;keyboard tutte;back pausa;home ospiti"
LEGEND_KEYS_IDLE="lr luce;ud intensità;center on/off;keyboard tutte;back musica;home ospiti"
LEGEND_PAUSE="premi un tasto"
QR_SECONDS=120    # after how long the QR screen closes by itself
BATTERY_LOW=20    # below this percentage the battery is shown in bold

# Power. WiFi is the biggest drain: the Arduino is asked for the state once a
# minute (when the minute ticks over), more often only with music or while charging.
POLL_SECONDS=10          # with music playing or while charging: how often to ask for the state
FULL_REFRESH_MINUTES=240 # periodic full refresh against ghosting
IDLE_MINUTES=10          # after this long without changes, pause: WiFi off (0 = never)
SLEEP_CHECK_MINUTES=15   # while paused: how often to turn WiFi back on to check
BATTERY_LOG_MINUTES=30   # how often to note the battery in battery.log (0 = never)

# OTA updates from GitHub, through the Arduino (see ota.sh)
OTA_ENABLED=1
OTA_CHECK_HOURS=24      # periodic check; it can also be forced from the webapp
OTA_HEALTH_SECONDS=45   # how long the new version has to prove it works

# Local paths, relative to the panel folder
FBINK="$DIR/bin/fbink"
FONT="$DIR/fonts/DejaVuSans.ttf"
FONT_BOLD="$DIR/fonts/DejaVuSans-Bold.ttf"
FONT_ICONS="$DIR/fonts/icons.ttf"   # made by tools/make_icons.py
# ota:end
