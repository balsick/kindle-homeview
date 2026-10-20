# Configurazione del pannello: modifica qui, non in dashboard.sh.

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

POLL_SECONDS=5          # ogni quanto chiedere lo stato all'Arduino
SHELLY_SYNC_SECONDS=60  # ogni quanto rileggere le luci (se cambiate dall'app)
FULL_REFRESH_MINUTES=30 # refresh completo periodico contro il ghosting

DIR_BASE=/mnt/us/dashboard
FBINK="$DIR_BASE/bin/fbink"
FONT="$DIR_BASE/fonts/DejaVuSans.ttf"
FONT_BOLD="$DIR_BASE/fonts/DejaVuSans-Bold.ttf"
