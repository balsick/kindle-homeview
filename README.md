# Pannello domestico su Kindle 5

Un Kindle 5 (2012, non touch) appeso al muro che mostra ora, meteo e Spotify, e
con i tasti fisici regola le 3 luci di uno Shelly Plus RGBW PM. Col tasto Home
mostra i QR per il WiFi ospiti e per una webapp che fa le stesse cose dal telefono.
Un Arduino UNO R4 WiFi fa da gateway HTTPS (il Kindle non supporta il TLS moderno),
serve la webapp e, come device Arduino Cloud, segnala quando va via la corrente.

<img src="docs/preview.png" width="260" alt="Schermata principale"> <img src="docs/preview-qr.png" width="260" alt="Schermata dei QR"> <img src="docs/webapp.png" width="260" alt="Webapp sul telefono">

```
Spotify, Open-Meteo ◄─HTTPS── UNO R4 WiFi ──► Arduino Cloud (notifica se offline)
                               ▲    ▲    │
             HTTP /status, /cmd│    │    │ HTTP (luci dalla webapp)
                               │    │    ▼
                        Kindle 5    │   Shelly Plus RGBW PM
                               │    │    ▲
                               │  telefono (webapp, http://IP_ARDUINO/)
                               └─────────┘ HTTP (luci dai tasti)
```

| Cartella | Contenuto |
|---|---|
| `arduino/kindle_gateway/` | Sketch per l'UNO R4 WiFi |
| `kindle/` | Script del pannello, da copiare in `/mnt/us/dashboard/` sul Kindle |
| `tools/get_spotify_token.py` | Ottiene il refresh token di Spotify (una volta, sul PC) |
| `tools/make_qr.py` | Genera i QR del WiFi ospiti e della webapp |
| `tools/release_kindle.sh` | Pubblica un aggiornamento OTA per il Kindle (tag `kindle-vN`) |
| `tools/preview.py` | Anteprima della schermata del Kindle sul PC |
| `tools/webapp_dev.py` | Anteprima della webapp nel browser, con API finte |

## Tasti

Il joystick comanda le luci, i tasti pagina ai lati la musica che suona a casa.

| Tasto | Azione |
|---|---|
| Joystick su / giù | Sceglie la luce (barretta nera a sinistra della riga) |
| Joystick sinistra / destra | Luminosità della luce scelta − / + |
| Joystick centro | Accende / spegne la luce scelta |
| Pagina sinistri (avanti / indietro) | Volume + / − |
| Pagina destri (avanti / indietro) | Brano successivo / precedente |
| Indietro | Pausa; se a casa non suona niente, fa partire la musica |
| Tastiera | Spegne tutte le luci (o le riaccende) |
| Menu | Refresh completo dello schermo |
| Home | Mostra i QR (WiFi ospiti e webapp) |

**Musica "a casa".** Conta solo quella che suona su un dispositivo Spotify di
tipo `Speaker` (gli Echo; `SPOTIFY_HOME_TYPE` in `home_config.h`): se ascolti
dal telefono fuori casa il pannello la ignora e i tasti non la toccano. Col
tasto Indietro la musica riparte sul dispositivo `SPOTIFY_HOME_DEVICE` (anche
un gruppo, es. "Ovunque") da dove era rimasta, spostandola lì se suona altrove;
se non c'è niente da riprendere parte `SPOTIFY_FALLBACK_CONTEXT`, se impostata.

Con i QR a schermo un tasto qualsiasi torna al pannello senza fare altro. La
schermata si chiude comunque da sola dopo 2 minuti (`QR_SECONDS`). La fascia
in basso riassume i tasti e cambia se la musica suona o no (`LEGEND_MUSIC`,
`LEGEND_IDLE` in `defaults.sh`, ridefinibili in `config.sh`).

Tenendo premuto luminosità o volume il valore continua a cambiare. Allo Shelly
e a Spotify viene inviato solo l'ultimo valore, quando i tasti si fermano
(debounce). Con "−" dal minimo la luce si spegne, con "+" da spenta si
riaccende al minimo.

## 1. Rete

- Riserva nel router un IP fisso per l'UNO R4 e uno per lo Shelly.
- Shelly: profilo **Light** (4 canali). Le 3 luci sono sui canali 0, 1 e 2
  (modificabili in `config.sh` sul Kindle). L'autenticazione dello Shelly deve
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
2. Copia `arduino_secrets.h.example` in `arduino_secrets.h` e inserisci Client
   ID, Client Secret e refresh token di Spotify, più il token GitHub per l'OTA
   del Kindle (vedi [Aggiornamenti OTA](#aggiornamenti-ota-del-kindle)). Il WiFi
   non va inserito: lo configura Arduino Cloud. Un `arduino_secrets.h` creato
   prima dell'OTA, senza `SECRET_GITHUB_TOKEN`, va ancora bene: l'OTA resta
   solo disattivato.
3. Copia `home_config.h.example` in `home_config.h` e imposta `LATITUDE` e
   `LONGITUDE`, poi `SHELLY_HOST` e `LIGHTS` (nomi e canali delle luci per la
   webapp, uguali a quelli del Kindle). Come `arduino_secrets.h`, è escluso da
   git. Nel Cloud Editor aggiungilo come nuova scheda dello sketch.
4. Librerie: **ArduinoIoTCloud** (con le dipendenze) e **ArduinoJson** 7.
5. Carica lo sketch dal Cloud Editor, oppure dall'IDE se la scheda è già
   associata al Thing. `thingProperties.h` è quello generato dal tuo Thing.
6. Dal Serial Monitor (9600 baud) leggi l'indirizzo e aprilo nel browser:
   - `http://IP_ARDUINO/` è la webapp;
   - `http://IP_ARDUINO/status` deve mostrare righe `chiave=valore`.

Il trigger di Arduino Cloud sullo stato del device resta com'è. Lo sketch chiama
`ArduinoCloud.update()` a ogni giro e fa al massimo un'operazione HTTPS per
volta, così il device non risulta offline senza motivo.

**Variabili del Thing.** Il Thing ha sei variabili di diagnostica, tutte in
sola lettura (sono in `thingProperties.h`, che va tenuto uguale al Thing):

| Variabile | Tipo | Significato |
|---|---|---|
| `uptimeMin` | INT | minuti dall'avvio: se torna a 0 la scheda è ripartita |
| `lastError` | CHARSTRING | ultimo errore (meteo, Spotify, watchdog) |
| `lastReset` | CHARSTRING | motivo dell'ultimo riavvio: accensione, watchdog, software |
| `weatherOk` | STATUS | l'ultimo aggiornamento del meteo è andato a buon fine |
| `spotifyOk` | STATUS | Spotify risponde |
| `kindleOnline` | STATUS | il Kindle ha chiesto `/status` negli ultimi 2 minuti |

Su `kindleOnline` puoi mettere un trigger, come per lo stato del device, per
sapere quando il pannello si spegne.

**Watchdog.** Se `loop()` resta bloccata per un minuto, il watchdog hardware
resetta la scheda. Se il Cloud resta scollegato per 10 minuti, anche
col WiFi giù, la scheda si riavvia da sola e così resetta anche il modulo WiFi.
Dopo il riavvio `lastReset` ne riporta il motivo.

**Memoria.** L'UNO R4 ha 32 KB di RAM e lo sketch è al limite. Sono scelte
fatte apposta, misurate sulla scheda:
- `setup()` e `loop()` girano su uno stack di 2 KB dello sketch (il core ne dà
  1 KB, ma il parsing JSON arriva a ~1,7 KB e sconfinava nell'heap);
- le richieste HTTPS usano `ChunkedSSLClient`, che legge dal modulo WiFi 512
  byte per volta: con i 1023 di `WiFiSSLClient`, quando l'heap è frammentato
  l'allocazione fallisce e la scheda si blocca;
- le risposte piccole (meteo, token di Spotify) si leggono tutte prima del
  parsing;
- niente agente Bluetooth nel Network Configurator: costava ~1,6 KB. Per
  cambiare rete WiFi collega la scheda via USB e configurala dal Cloud.

Se cambi lo sketch, guarda la riga `Memoria:` che stampa ogni 5 minuti sulla
seriale (stack e heap liberi).

## 4. Kindle

> **Attenzione ai nomi.** Su MobileRead "K5" indica i Kindle con firmware 5.x
> (i touch). Il Kindle 5 ha firmware 4.1.x, quindi gli servono i pacchetti per
> **K4 / legacy**.

1. **Jailbreak.** Usa il jailbreak per Kindle 4/5 non touch dal thread di NiLuJe
   su MobileRead (Kindle Developer's Corner) e segui il README del pacchetto.
2. **USBNetwork.** Installalo dallo stesso thread e abilita SSH via WiFi.
3. **FBInk.** Va bene quello della build `kindle-legacy` di KOReader (release
   su GitHub, file `koreader/fbink`): copialo in `/mnt/us/dashboard/bin/fbink`.
   Quella build non sa disegnare immagini, per questo i QR si copiano nel
   framebuffer dai file `.raw` di `make_qr.py`.
4. **Font.** Copia `DejaVuSans.ttf` e `DejaVuSans-Bold.ttf` in
   `/mnt/us/dashboard/fonts/`. Altri font vanno bene, basta indicarli in
   `config.sh` (`FONT`, `FONT_BOLD`).
5. Copia in `/mnt/us/dashboard/` i file elencati in `kindle/ota-files`:
   `lib.sh`, `defaults.sh`, `dashboard.sh`, `ota.sh` e `ota-files`. Poi copia
   `kindle/config.example.sh` come `config.sh` e impostaci IP e nomi delle luci.
   - `defaults.sh` contiene tutti i valori predefiniti e viene sostituito
     dagli aggiornamenti OTA: non modificarlo.
   - `config.sh` contiene solo quello che cambi tu e non viene mai toccato.

   Se hai già un `config.sh` completo copiato da una versione precedente,
   funziona ancora: viene letto dopo `defaults.sh` e ne sovrascrive i valori.
   Puoi poi ridurlo alle sole righe che hai personalizzato.
6. **QR.** Sul PC esegui `pip install segno` e poi `python3 tools/make_qr.py`.
   Ti chiede rete e password del WiFi ospiti e crea `kindle/qr/`. Copia la
   cartella in `/mnt/us/dashboard/qr/`. Contiene la password in chiaro, per
   questo è esclusa dal repository.
7. **Verifica dei tasti.** Via SSH esegui:
   ```sh
   sh /mnt/us/dashboard/dashboard.sh keytest
   ```
   Premi ogni tasto e confronta i codici con quelli in `defaults.sh`; se
   sono diversi, ridefiniscili in `config.sh`. Quelli
   preimpostati vengono dalla keymap del Kindle 4 di KOReader e vanno
   confermati, così come i device in `INPUT_DEVICES`.
8. Avvio e arresto:
   ```sh
   sh /mnt/us/dashboard/dashboard.sh start   # ferma l'interfaccia Kindle e avvia il pannello
   sh /mnt/us/dashboard/dashboard.sh stop    # torna al Kindle normale
   ```
   Il log è in `/tmp/dashboard.log`.
9. **Avvio al boot.**
   ```sh
   sh /mnt/us/dashboard/dashboard.sh autostart on    # off per toglierlo
   ```
   Installa `/etc/init.d/dashboard` (avviato come `S99dashboard`): al boot
   aspetta il WiFi e avvia il pannello, in background, senza bloccare l'avvio.
   Per saltare un avvio crea `/mnt/us/dashboard/NO_AUTOSTART`. Perché SSH resti
   raggiungibile dopo un riavvio, in `usbnet/` rinomina `DISABLED_auto` in
   `auto` e metti `K3_WIFI_SSHD_ONLY="true"` in `usbnet/etc/config`: parte
   solo SSH e il Kindle resta visibile come disco USB.

## Aggiornamenti OTA del Kindle

Il Kindle si aggiorna da solo, ma solo quando pubblichi un **rilascio**, cioè un
tag `kindle-vN`. Un push su `main` da solo non lo aggiorna: puoi modificare
README, sketch o anche `kindle/` senza che il Kindle si riavvii, e decidere tu
quando una versione è pronta. Il Kindle non parla HTTPS, quindi i file passano
dall'Arduino, che li legge da GitHub col token:

```
Kindle ──HTTP /ota/version, /ota/file──► UNO R4 ──HTTPS + token──► GitHub
```

**Pubblicare un aggiornamento.** Fai push su `main`, poi esegui:

```sh
tools/release_kindle.sh
```

Lo script:
1. controlla che `kindle/` non abbia modifiche non committate e che il commit
   sia già su GitHub;
2. trova l'ultimo `kindle-vN`. Se da allora `kindle/` non è cambiata, non fa
   nulla;
3. fa gli stessi controlli del Kindle, cioè riga finale `# ota:end` e `sh -n`
   sugli script;
4. mostra le modifiche, chiede conferma e pubblica `kindle-vN+1`.

Il Kindle passa sempre al tag col numero più alto, confrontato come numero:
`kindle-v10` viene dopo `kindle-v9`. Non torna mai a un numero più basso,
nemmeno se cancelli un tag. Per annullare un rilascio sbagliato, pubblica una
versione corretta con un numero più alto.

**Token.** Su GitHub vai in *Settings → Developer settings → Fine-grained
tokens* e crea un token con:
- accesso solo al repository `kindle-homeview`;
- permesso *Contents: Read-only*.

Mettilo in `SECRET_GITHUB_TOKEN` in `arduino_secrets.h`. L'Arduino inoltra solo
i file della cartella `kindle/` ai tag `kindle-vN`, non il resto del
repository.

**Quando controlla.** Due minuti dopo l'avvio, poi ogni 24 ore
(`OTA_CHECK_HOURS`). Puoi forzare un controllo in due modi:
- dal pulsante *Aggiorna* della webapp, che mostra anche la versione in uso
  sul Kindle e l'ultima disponibile;
- via SSH, con l'output a schermo: `sh /mnt/us/dashboard/dashboard.sh update`.

La versione in uso compare anche in fondo alla schermata dei QR. Il log è in
`/tmp/dashboard-ota.log`.

**Cosa viene aggiornato.** Solo i file elencati in `kindle/ota-files`. Non
vengono mai toccati:
- `config.sh`;
- i QR;
- FBInk;
- i font.

Ogni file aggiornabile deve finire con la riga `# ota:end`. Se aggiungi un file,
mettilo anche in `ota-files`.

**Protezioni.**
1. I file vengono scaricati a parte e accettati solo se completi (c'è la riga
   finale `# ota:end`). Gli script devono anche superare il controllo di
   sintassi (`sh -n`). Se un solo file non va, l'aggiornamento viene annullato
   senza toccare nulla.
2. La versione in uso viene salvata in `.ota_prev/` prima di essere sostituita.
3. Dopo il riavvio il pannello deve dimostrare di funzionare entro 45 secondi
   (`OTA_HEALTH_SECONDS`). Se non ci riesce, si torna alla versione precedente.
   Il rilascio difettoso viene scritto in `.ota_bad` e non viene più riprovato.

Il controllo e il ripristino li fa il processo della versione vecchia, quindi
funzionano anche se la versione nuova è difettosa. Resta un caso scoperto: una
versione nuova che parte ma ha l'OTA rotto non può aggiornarsi da sola. In quel
caso si corregge via SSH.

Per disattivare l'OTA metti `OTA_ENABLED=0` in `config.sh`.

### Da verificare sul dispositivo

Provato su un Kindle 5 (firmware 4.1.4) col FBInk di KOReader. Cose da sapere:
- il BusyBox del Kindle è il 1.7.2: niente `od`, niente `command -v`, `grep`
  senza `-E`. Gli script usano `hexdump`, `which` e `grep` semplice;
- i codici dei tasti in `defaults.sh` sono quelli misurati su questo Kindle
  (diversi dalla keymap di KOReader per i tasti pagina): se il tuo dà altro,
  `keytest` li mostra e li ridefinisci in `config.sh`;
- USBNetwork: con SSH via WiFi (`K3_WIFI="true"`) il dropbear del pacchetto
  accetta solo chiavi RSA, non ed25519;
- da macOS, i file `._*` che il Finder lascia sul disco del Kindle fanno
  fallire gli aggiornamenti `.bin` (errore U007): cancellali prima;
- da verificare ancora: Wi-Fi a framework fermo per molte ore.

## Webapp

La serve l'UNO R4 su `http://IP_ARDUINO/`, solo in LAN. Si apre anche dal
secondo QR del Kindle. Mostra ora e meteo, regola le luci (interruttore e
slider) e comanda Spotify.

Le luci passano dall'Arduino allo Shelly. Il Kindle rilegge lo Shelly ogni 15 s
(`SHELLY_SYNC_SECONDS`), quindi una modifica dal telefono compare sullo schermo
entro quel tempo.

**Sicurezza.** La webapp non ha password: chiunque sia sulla tua rete può
accendere le luci. Per gli ospiti conviene una **rete ospiti isolata**: col
primo QR navigano, ma non raggiungono la webapp.

Per modificarla: `python3 tools/webapp_dev.py`, apri `http://localhost:8000/`,
modifica `arduino/kindle_gateway/webapp.h` e ricarica la pagina.

## Anteprima della UI

```sh
pip install pillow
python3 tools/preview.py            # crea preview.png
python3 tools/preview.py --watch    # la rigenera a ogni modifica di dashboard.sh/defaults.sh/config.sh
python3 tools/preview.py --screen qr   # schermata dei QR (preview-qr.png)
```

L'anteprima esegue il vero `dashboard.sh` e intercetta le chiamate a FBInk.
Il layout si modifica in `dashboard.sh`:
- coordinate delle zone (`HDR_Y`, `WX_Y`, …);
- funzioni `draw_*`.

I dati di esempio sono in `tools/sample_status.txt`. Con `--lights` cambi lo
stato delle luci, ad esempio `--lights "1:100 0:50 1:20"`.
