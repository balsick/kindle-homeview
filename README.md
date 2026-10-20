# Pannello domestico su Kindle 5

Un Kindle 5 (2012, non touch) appeso al muro che mostra ora, meteo e Spotify, e
con i tasti fisici regola le 3 luci di uno Shelly Plus RGBW PM. Un Arduino UNO R4
WiFi fa da gateway HTTPS (il Kindle non supporta il TLS moderno) e, come device
Arduino Cloud, segnala quando va via la corrente.

<img src="docs/preview.png" width="300" alt="Anteprima della schermata">

```
Spotify, Open-Meteo ◄─HTTPS── UNO R4 WiFi ──► Arduino Cloud (notifica se offline)
                                   ▲
                                   │ HTTP /status, /cmd
                                   │
                              Kindle 5 ──HTTP──► Shelly Plus RGBW PM
```

| Cartella | Contenuto |
|---|---|
| `arduino/kindle_gateway/` | Sketch per l'UNO R4 WiFi |
| `kindle/` | Script del pannello, da copiare in `/mnt/us/dashboard/` sul Kindle |
| `tools/get_spotify_token.py` | Ottiene il refresh token di Spotify (una volta, sul PC) |
| `tools/preview.py` | Anteprima della schermata sul PC |

## Tasti

| Tasto | Azione |
|---|---|
| Pagina sinistri (avanti / indietro) | Luce 1 + / − |
| Pagina destri (avanti / indietro) | Luce 2 + / − |
| Joystick su / giù | Luce 3 + / − |
| Joystick sinistra / destra | Brano precedente / successivo |
| Joystick centro | Play / pausa |
| Indietro | Spegne tutte le luci (o le riaccende) |
| Menu | Refresh completo dello schermo |

Tenendo premuto un tasto luce la luminosità continua a cambiare. Allo Shelly viene
inviato solo l'ultimo valore, quando i tasti si fermano (debounce). Con "−" dal
minimo la luce si spegne, con "+" da spenta si riaccende al minimo.

## 1. Rete

- Riserva nel router un IP fisso per l'UNO R4 e uno per lo Shelly.
- Shelly: profilo **Light** (4 canali). Le 3 luci sono sui canali 0, 1 e 2
  (modificabili in `kindle/config.sh`). L'autenticazione dello Shelly deve
  essere disattivata, perché lo script chiama l'API senza password.

## 2. Spotify

1. Vai su <https://developer.spotify.com/dashboard> e crea un'app:
   - API: **Web API**
   - Redirect URI: `http://127.0.0.1:8888/callback`
2. Sul PC esegui `python3 tools/get_spotify_token.py`, inserisci Client ID e
   Client Secret e autorizza nel browser. Lo script stampa il refresh token.

Per play, pausa e cambio brano serve Spotify Premium e un dispositivo attivo
(telefono, PC, cassa…).

## 3. Arduino UNO R4 WiFi

1. Aggiorna il firmware del modulo WiFi (IDE → Strumenti → Firmware Updater).
2. In `arduino/kindle_gateway/arduino_secrets.h` inserisci Client ID, Client
   Secret e refresh token di Spotify. Il WiFi non va inserito: lo configura
   Arduino Cloud.
3. In `kindle_gateway.ino` imposta `LATITUDE` e `LONGITUDE`.
4. Librerie: **ArduinoIoTCloud** (con le dipendenze) e **ArduinoJson** 7.
5. Carica lo sketch dal Cloud Editor, oppure dall'IDE se la scheda è già
   associata al Thing. `thingProperties.h` è quello generato dal tuo Thing.
6. Dal Serial Monitor (9600 baud) leggi l'indirizzo e apri
   `http://IP_ARDUINO/status` nel browser: devi vedere righe `chiave=valore`.

Il trigger di Arduino Cloud sullo stato del device resta com'è. Lo sketch chiama
`ArduinoCloud.update()` a ogni giro e fa al massimo un'operazione HTTPS per
volta, così il device non risulta offline senza motivo.

## 4. Kindle

> **Attenzione ai nomi.** Su MobileRead "K5" indica i Kindle con firmware 5.x
> (i touch). Il Kindle 5 ha firmware 4.1.x, quindi gli servono i pacchetti per
> **K4 / legacy**.

1. **Jailbreak.** Usa il jailbreak per Kindle 4/5 non touch dal thread di NiLuJe
   su MobileRead (Kindle Developer's Corner) e segui il README del pacchetto.
2. **USBNetwork.** Installalo dallo stesso thread e abilita SSH via WiFi.
3. **FBInk.** Scarica la build per Kindle legacy/K4 e copia il binario in
   `/mnt/us/dashboard/bin/fbink`.
4. **Font.** Copia `DejaVuSans.ttf` e `DejaVuSans-Bold.ttf` in
   `/mnt/us/dashboard/fonts/`. Altri font vanno bene, basta aggiornare
   `config.sh`.
5. Copia `kindle/dashboard.sh` e `kindle/config.sh` in `/mnt/us/dashboard/`.
   Poi in `config.sh` imposta gli IP e i nomi delle luci.
6. **Verifica dei tasti.** Via SSH esegui:
   ```sh
   sh /mnt/us/dashboard/dashboard.sh keytest
   ```
   Premi ogni tasto e confronta i codici con quelli in `config.sh`. Quelli
   preimpostati vengono dalla keymap del Kindle 4 di KOReader e vanno
   confermati, così come i device in `INPUT_DEVICES`.
7. Avvio e arresto:
   ```sh
   sh /mnt/us/dashboard/dashboard.sh start   # ferma l'interfaccia Kindle e avvia il pannello
   sh /mnt/us/dashboard/dashboard.sh stop    # torna al Kindle normale
   ```
   Il log è in `/tmp/dashboard.log`.

### Da verificare sul dispositivo

Lo script è stato provato su PC con un FBInk finto, un server finto e
eventi tasto simulati. Sul Kindle vero ci sono alcune cose che non ho potuto
verificare:
- **Opzioni di FBInk** (`-k`, `-s`, `-t px=…`): controlla con `fbink -h` che la
  tua versione le supporti. Sono usate solo nelle funzioni `fb`, `zone_*` e
  `text*` di `dashboard.sh`.
- **`od -tu2`** nel BusyBox del Kindle: se `keytest` non stampa nulla, il
  problema è lì.
- **Wi-Fi a framework fermo**: dovrebbe restare connesso. Se non è così, va
  gestito con `lipc`.
- **Avvio automatico al boot**: da aggiungere quando tutto funziona.

## Anteprima della UI

```sh
pip install pillow
python3 tools/preview.py            # crea preview.png
python3 tools/preview.py --watch    # la rigenera a ogni modifica di dashboard.sh/config.sh
```

L'anteprima esegue il vero `dashboard.sh` e intercetta le chiamate a FBInk.
Il layout si modifica in `dashboard.sh`:
- coordinate delle zone (`HDR_Y`, `WX_Y`, …);
- funzioni `draw_*`.

I dati di esempio sono in `tools/sample_status.txt`. Con `--lights` cambi lo
stato delle luci, ad esempio `--lights "1:100 0:50 1:20"`.
