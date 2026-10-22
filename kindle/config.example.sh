# Local panel configuration: copy it to config.sh on the Kindle.
# Only put here what differs from defaults.sh, which is updated over OTA:
# updates never touch config.sh.

ARDUINO_HOST="192.168.1.60"   # IP of the UNO R4 WiFi (reserve it in your router)
SHELLY_HOST="192.168.1.50"    # IP of the Shelly Plus RGBW PM

# Lights: Shelly channels and names, in the same order
# LIGHT_IDS="0 1 2"
# LIGHT_NAMES="Soggiorno|Cucina|Studio"

# Key codes, if keytest shows values different from those in defaults.sh
# INPUT_DEVICES="/dev/input/event0 /dev/input/event1"
# KEY_VOL_UP=104
# KEY_PLAY=158

# To turn off automatic updates
# OTA_ENABLED=0
