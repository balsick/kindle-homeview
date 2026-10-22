# Valori predefiniti del pannello. NON modificarlo sul Kindle: viene
# sostituito dagli aggiornamenti OTA. Per cambiare un valore ridefiniscilo
# in config.sh, che resta solo sul Kindle (vedi config.example.sh).

ARDUINO_HOST="192.168.1.60"   # IP dell'UNO R4 WiFi (riservalo nel router)
SHELLY_HOST="192.168.1.50"    # IP dello Shelly Plus RGBW PM (profilo "light", 4 canali)

# Le luci, nello stesso ordine in tutte le righe sotto.
LIGHT_IDS="0 1 2"                                 # canale Shelly (0-3)
LIGHT_NAMES="Soggiorno|Cucina|Studio"
STEP=10                                           # passo di luminosità in %
VOLUME_STEP=10                                    # passo del volume di Spotify in %

# Tasti: codici misurati su un Kindle 5 (firmware 4.1.4) con
# "dashboard.sh keytest". Se il tuo Kindle dà codici diversi, ridefiniscili
# in config.sh.
INPUT_DEVICES="/dev/input/event0 /dev/input/event1"

# Joystick: le luci. ▲▼ sceglie la luce, ◀▶ la luminosità, centro on/off
KEY_UP=103
KEY_DOWN=108
KEY_LEFT=105
KEY_RIGHT=106
KEY_CENTER=194

# Tasti pagina ai lati: la musica che suona a casa
KEY_VOL_UP=104      # sinistra, avanti
KEY_VOL_DOWN=193    # sinistra, indietro
KEY_TRACK_NEXT=191  # destra, avanti
KEY_TRACK_PREV=109  # destra, indietro

KEY_PLAY=158      # Indietro: pausa, o fa partire la musica a casa
KEY_ALL=29        # Tastiera: spegne tutte le luci / le riaccende
KEY_REFRESH=139   # Menu: refresh completo dello schermo
KEY_QR=102        # Home: QR del WiFi ospiti e della webapp

# Legenda nella fascia in basso: cambia se la musica suona a casa o no
LEGEND_MUSIC="lati: volume · brani  ·  ↩ pausa  ·  ⌨ luci  ·  ⌂ QR"
LEGEND_IDLE="↩ musica a casa  ·  ⌨ tutte le luci  ·  ⌂ WiFi ospiti"
LEGEND_PAUSE="premi un tasto"
QR_SECONDS=120    # dopo quanto la schermata dei QR si chiude da sola
BATTERY_LOW=20    # sotto questa percentuale la batteria è in grassetto

# Consumi. Il WiFi è la voce più pesante: si chiede lo stato all'Arduino una
# volta al minuto (allo scatto dell'ora), più spesso solo con la musica o in carica.
POLL_SECONDS=10          # con la musica che suona o in carica: ogni quanto chiedere lo stato
FULL_REFRESH_MINUTES=240 # refresh completo periodico contro il ghosting
IDLE_MINUTES=10          # senza cambiamenti per tanto, pausa: WiFi spento (0 = mai)
SLEEP_CHECK_MINUTES=15   # in pausa: ogni quanto riaccendere il WiFi per controllare
BATTERY_LOG_MINUTES=30   # ogni quanto annotare la batteria in battery.log (0 = mai)

# Aggiornamenti OTA da GitHub, tramite l'Arduino (vedi ota.sh)
OTA_ENABLED=1
OTA_CHECK_HOURS=24      # controllo periodico; si può anche forzare dalla webapp
OTA_HEALTH_SECONDS=45   # entro quanto la nuova versione deve dimostrare di funzionare

# Percorsi locali, relativi alla cartella del pannello
FBINK="$DIR/bin/fbink"
FONT="$DIR/fonts/DejaVuSans.ttf"
FONT_BOLD="$DIR/fonts/DejaVuSans-Bold.ttf"
# ota:end
