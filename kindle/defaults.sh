# Valori predefiniti del pannello. NON modificarlo sul Kindle: viene
# sostituito dagli aggiornamenti OTA. Per cambiare un valore ridefiniscilo
# in config.sh, che resta solo sul Kindle (vedi config.example.sh).

ARDUINO_HOST="192.168.1.60"   # IP dell'UNO R4 WiFi (riservalo nel router)
SHELLY_HOST="192.168.1.50"    # IP dello Shelly Plus RGBW PM (profilo "light", 4 canali)

# Le luci, nello stesso ordine in tutte le righe sotto.
LIGHT_IDS="0 1 2"                                 # canale Shelly (0-3)
LIGHT_NAMES="Soggiorno|Cucina|Studio"
LIGHT_HINTS="◀ tasti sinistri|tasti destri ▶|joystick ▲▼"
STEP=10                                           # passo di luminosità in %

# Tasti. I codici vengono dalla keymap del Kindle 4 di KOReader (stesso
# hardware del Kindle 5): VERIFICALI con "dashboard.sh keytest".
INPUT_DEVICES="/dev/input/event0 /dev/input/event1"

# Per ogni luce "tasto_più:tasto_meno", nello stesso ordine di LIGHT_IDS.
LIGHT_KEYS="109:104 193:191 103:108"

KEY_PREV=105      # joystick sinistra: brano precedente
KEY_NEXT=106      # joystick destra:   brano successivo
KEY_PLAY=194      # joystick centro:   play/pausa
KEY_ALL=158       # Indietro: spegne tutte le luci / le riaccende
KEY_REFRESH=139   # Menu: refresh completo dello schermo
KEY_QR=102        # Home: QR del WiFi ospiti e della webapp

# Legenda nella fascia in basso (i tasti sotto lo schermo)
LEGEND="◀ ▶ brano  ·  ● play  ·  ↩ tutte le luci  ·  ⌂ WiFi ospiti"
QR_SECONDS=120    # dopo quanto la schermata dei QR si chiude da sola

POLL_SECONDS=5          # ogni quanto chiedere lo stato all'Arduino
SHELLY_SYNC_SECONDS=15  # ogni quanto rileggere le luci (cambiate da webapp o app Shelly)
FULL_REFRESH_MINUTES=30 # refresh completo periodico contro il ghosting

# Aggiornamenti OTA da GitHub, tramite l'Arduino (vedi ota.sh)
OTA_ENABLED=1
OTA_CHECK_HOURS=24      # controllo periodico; si può anche forzare dalla webapp
OTA_HEALTH_SECONDS=45   # entro quanto la nuova versione deve dimostrare di funzionare

# Percorsi locali, relativi alla cartella del pannello
FBINK="$DIR/bin/fbink"
FONT="$DIR/fonts/DejaVuSans.ttf"
FONT_BOLD="$DIR/fonts/DejaVuSans-Bold.ttf"
# ota:end
