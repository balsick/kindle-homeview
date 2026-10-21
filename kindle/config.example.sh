# Configurazione locale del pannello: copiala in config.sh sul Kindle.
# Qui va solo quello che cambia rispetto a defaults.sh, che viene aggiornato
# via OTA: config.sh non viene mai toccato dagli aggiornamenti.

ARDUINO_HOST="192.168.1.60"   # IP dell'UNO R4 WiFi (riservalo nel router)
SHELLY_HOST="192.168.1.50"    # IP dello Shelly Plus RGBW PM

# Luci: canali Shelly e nomi, nello stesso ordine
# LIGHT_IDS="0 1 2"
# LIGHT_NAMES="Soggiorno|Cucina|Studio"

# Codici dei tasti, se keytest mostra valori diversi da quelli di defaults.sh
# INPUT_DEVICES="/dev/input/event0 /dev/input/event1"
# KEY_VOL_UP=104
# KEY_PLAY=158

# Per disattivare gli aggiornamenti automatici
# OTA_ENABLED=0
