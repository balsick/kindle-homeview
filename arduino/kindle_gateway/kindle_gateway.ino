/*
  Gateway per il pannello Kindle — Arduino UNO R4 WiFi

  Il Kindle 5 non supporta l'HTTPS moderno: questo sketch parla con Spotify e
  Open-Meteo in HTTPS e offre al Kindle due endpoint HTTP in chiaro:

    GET /status          stato in formato "chiave=valore", una riga per chiave
    GET /cmd?a=AZIONE    comando Spotify: toggle | play | pause | next | prev

  Serve anche la webapp per il telefono (solo LAN, senza password):

    GET /                          la pagina (webapp.h)
    GET /api/state                 stato in JSON, luci comprese
    GET /api/light?i=N&on=1&b=50   accende/spegne/regola la luce N (indice in LIGHTS)
    GET /api/cmd?a=AZIONE          come /cmd
    GET /api/ota                   chiede al Kindle di cercare aggiornamenti

  E fa da tramite per gli aggiornamenti OTA del Kindle (repository privato,
  token in arduino_secrets.h):

    GET /ota/version                      ultimo tag di rilascio kindle-vN
    GET /ota/file?ref=TAG&path=kindle/F   un file della cartella kindle/ a quel tag

  È anche un device Arduino Cloud: quando va via la corrente il device risulta
  offline e il trigger configurato sul Cloud manda la notifica. Il WiFi lo
  gestisce la libreria Cloud (credenziali dal Network Configurator), quindi
  questo sketch usa la rete solo quando è connessa e chiama ArduinoCloud.update()
  tra un'operazione lenta e l'altra.

  Librerie: ArduinoIoTCloud (con le sue dipendenze) e ArduinoJson 7.
*/

#include "thingProperties.h"
#include <WiFiS3.h>
#include <ArduinoJson.h>
#include "arduino_secrets.h"
#ifndef SECRET_GITHUB_TOKEN  // arduino_secrets.h creato prima dell'OTA: OTA disattivato
#define SECRET_GITHUB_TOKEN ""
#endif
#include "https_response.h"
#include "webapp.h"

// ---- Configurazione ----
// Posizione, Shelly e luci di casa stanno in home_config.h (copia di
// home_config.h.example), escluso da git come arduino_secrets.h.
struct Light {
  const char* name;
  int id;  // canale Shelly (0-3)
};
#include "home_config.h"
const int NUM_LIGHTS = sizeof(LIGHTS) / sizeof(LIGHTS[0]);

// Repository da cui il Kindle prende gli aggiornamenti: i tag kindle-vN
const char* const GITHUB_REPO = "balsick/kindle-homeview";
const char* const OTA_TAG_PREFIX = "kindle-v";

const unsigned long SPOTIFY_POLL_PLAYING_MS = 5000;
const unsigned long SPOTIFY_POLL_IDLE_MS = 20000;
const unsigned long WEATHER_POLL_MS = 15UL * 60 * 1000;
const unsigned long WEATHER_RETRY_MS = 60UL * 1000;
const unsigned long NTP_SYNC_MS = 60UL * 60 * 1000;
const unsigned long NTP_RETRY_MS = 10UL * 1000;

const char* const WEEKDAYS[] = {"domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato"};
const char* const WEEKDAYS_SHORT[] = {"Dom", "Lun", "Mar", "Mer", "Gio", "Ven", "Sab"};
const char* const MONTHS[] = {"gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno",
                              "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre"};

WiFiServer server(80);
WiFiSSLClient tls;
WiFiClient plain;  // HTTP in chiaro verso lo Shelly

// ---- Stato ----
struct {
  bool configured = false;
  bool ok = false;        // ultima chiamata andata a buon fine
  bool active = false;    // c'è qualcosa caricato nel player
  bool playing = false;
  String track, artist;
  long progressMs = 0, durationMs = 0;
  unsigned long fetchedAt = 0;
} sp;

struct {
  bool ok = false;
  float temp = 0, feels = 0;
  int hum = 0, wind = 0, code = 0;
  int dCode[3], dMin[3], dMax[3], dPop[3];
  long utcOffset = 0;
} wx;

String accessToken, refreshToken, basicAuth;
unsigned long tokenAt = 0, tokenValidMs = 0;
unsigned long epochAtSync = 0, millisAtSync = 0;
unsigned long nextSpotifyAt = 0, nextWeatherAt = 0, nextNtpAt = 0;
String kindleVersion, latestVersion;  // per mostrarli nella webapp
unsigned otaRequests = 0;         // il Kindle controlla quando il valore cambia

bool due(unsigned long at) { return (long)(millis() - at) >= 0; }

// ---- Client HTTP/HTTPS ----

// Esegue una richiesta e lascia `c` posizionato all'inizio del corpo.
// code = -1 se la connessione fallisce.
Response httpRequest(Client& c, const char* host, uint16_t port, unsigned long timeoutMs,
                     const char* method, const String& path, const String& headers, const String& body) {
  Response r;
  c.stop();
  if (!c.connect(host, port)) return r;
  c.setTimeout(timeoutMs);

  String req = String(method) + " " + path + " HTTP/1.1\r\n";
  req += "Host: "; req += host; req += "\r\n";
  req += "Connection: close\r\n";
  req += headers;
  if (strcmp(method, "GET") != 0) req += "Content-Length: " + String(body.length()) + "\r\n";
  req += "\r\n";
  req += body;
  c.print(req);

  String status = c.readStringUntil('\n');
  if (!status.startsWith("HTTP/")) return r;
  r.code = status.substring(status.indexOf(' ') + 1).toInt();
  while (true) {
    String line = c.readStringUntil('\n');
    line.trim();
    if (line.length() == 0) break;
    line.toLowerCase();
    if (line.startsWith("transfer-encoding:") && line.indexOf("chunked") > 0) r.chunked = true;
    else if (line.startsWith("content-length:")) r.length = line.substring(15).toInt();
  }
  return r;
}

Response httpsRequest(const char* host, const char* method, const String& path,
                      const String& headers, const String& body) {
  return httpRequest(tls, host, 443, 5000, method, path, headers, body);
}

// Legge il corpo della risposta decodificando al volo il "chunked", così
// ArduinoJson fa il parsing in streaming senza caricare tutto in RAM.
class BodyStream : public Stream {
 public:
  BodyStream(Client& c, const Response& r)
      : c_(c), chunked_(r.chunked), left_(r.chunked ? 0 : r.length) { setTimeout(50); }

  int read() override {
    int ch = peek();
    if (ch >= 0) {
      peeked_ = -1;
      if (left_ > 0) left_--;
    }
    return ch;
  }

  int peek() override {
    if (peeked_ >= 0) return peeked_;
    if (done_) return -1;
    if (chunked_ && left_ == 0 && !nextChunk()) return -1;
    if (left_ == 0) {  // Content-Length esaurito
      done_ = true;
      return -1;
    }
    uint8_t b;
    if (c_.readBytes(&b, 1) != 1) {
      done_ = true;
      return -1;
    }
    peeked_ = b;
    return b;
  }

  int available() override { return done_ ? 0 : 1; }
  size_t write(uint8_t) override { return 0; }

 private:
  bool nextChunk() {
    if (started_) c_.readStringUntil('\n');  // CRLF dopo il chunk precedente
    started_ = true;
    String size = c_.readStringUntil('\n');
    left_ = strtol(size.c_str(), nullptr, 16);
    if (left_ <= 0) {
      done_ = true;
      return false;
    }
    return true;
  }

  Client& c_;
  bool chunked_;
  long left_;  // byte rimasti nel chunk o nel corpo; -1 = fino alla chiusura
  bool started_ = false, done_ = false;
  int peeked_ = -1;
};

String base64(const String& in) {
  static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  String out;
  for (unsigned i = 0; i < in.length(); i += 3) {
    uint32_t n = (uint32_t)(uint8_t)in[i] << 16;
    if (i + 1 < in.length()) n |= (uint32_t)(uint8_t)in[i + 1] << 8;
    if (i + 2 < in.length()) n |= (uint8_t)in[i + 2];
    out += tbl[(n >> 18) & 63];
    out += tbl[(n >> 12) & 63];
    out += i + 1 < in.length() ? tbl[(n >> 6) & 63] : '=';
    out += i + 2 < in.length() ? tbl[n & 63] : '=';
  }
  return out;
}

// ---- Spotify ----

bool refreshSpotifyToken() {
  String headers = "Authorization: Basic " + basicAuth + "\r\n"
                   "Content-Type: application/x-www-form-urlencoded\r\n";
  Response r = httpsRequest("accounts.spotify.com", "POST", "/api/token", headers,
                            "grant_type=refresh_token&refresh_token=" + refreshToken);
  bool ok = false;
  if (r.code == 200) {
    BodyStream body(tls, r);
    JsonDocument doc;
    if (!deserializeJson(doc, body)) {
      accessToken = doc["access_token"] | "";
      tokenAt = millis();
      tokenValidMs = ((doc["expires_in"] | 3600) - 60) * 1000UL;
      // Spotify di solito non ruota il refresh token, ma se lo fa lo teniamo
      // (solo in RAM: dopo un riavvio si riparte da quello in arduino_secrets.h).
      if (doc["refresh_token"].is<const char*>()) refreshToken = doc["refresh_token"].as<const char*>();
      ok = accessToken.length() > 0;
    }
  } else {
    Serial.print("Spotify: rinnovo token fallito, HTTP ");
    Serial.println(r.code);
  }
  tls.stop();
  return ok;
}

// Chiama la Web API. Dopo la chiamata il corpo è da leggere da `tls`.
Response spotifyApi(const char* method, const String& path) {
  if (accessToken.length() == 0 || millis() - tokenAt > tokenValidMs) {
    if (!refreshSpotifyToken()) return Response();
  }
  Response r = httpsRequest("api.spotify.com", method, path,
                            "Authorization: Bearer " + accessToken + "\r\n", "");
  if (r.code == 401) accessToken = "";  // token scaduto: si rinnova alla prossima chiamata
  return r;
}

void updateNowPlaying() {
  Response r = spotifyApi("GET", "/v1/me/player/currently-playing?market=from_token&additional_types=episode");
  unsigned long next = SPOTIFY_POLL_IDLE_MS;

  if (r.code == 204) {  // niente in riproduzione
    sp.ok = true;
    sp.active = sp.playing = false;
  } else if (r.code == 200) {
    JsonDocument filter;
    filter["is_playing"] = true;
    filter["progress_ms"] = true;
    filter["item"]["name"] = true;
    filter["item"]["duration_ms"] = true;
    filter["item"]["artists"][0]["name"] = true;
    filter["item"]["show"]["name"] = true;

    BodyStream body(tls, r);
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, body, DeserializationOption::Filter(filter));
    sp.ok = !err;
    if (!err) {
      JsonObject item = doc["item"];
      sp.active = !item.isNull();
      sp.playing = doc["is_playing"] | false;
      sp.progressMs = doc["progress_ms"] | 0;
      sp.durationMs = item["duration_ms"] | 0;
      sp.track = item["name"] | "";
      // Brani: elenco artisti. Episodi di podcast: nome del podcast.
      sp.artist = "";
      for (JsonObject a : item["artists"].as<JsonArray>()) {
        if (sp.artist.length()) sp.artist += ", ";
        sp.artist += a["name"] | "";
      }
      if (sp.artist.length() == 0) sp.artist = item["show"]["name"] | "";
      sp.fetchedAt = millis();
      if (sp.playing) next = SPOTIFY_POLL_PLAYING_MS;
    }
  } else {
    sp.ok = false;
    Serial.print("Spotify: now playing fallito, HTTP ");
    Serial.println(r.code);
    if (r.code == 429) next = 60000;  // rate limit
  }
  tls.stop();
  nextSpotifyAt = millis() + next;
}

int spotifyCommand(String action) {
  if (!sp.configured) return 503;
  if (action == "toggle") action = sp.playing ? "pause" : "play";

  Response r;
  if (action == "play") r = spotifyApi("PUT", "/v1/me/player/play");
  else if (action == "pause") r = spotifyApi("PUT", "/v1/me/player/pause");
  else if (action == "next") r = spotifyApi("POST", "/v1/me/player/next");
  else if (action == "prev") r = spotifyApi("POST", "/v1/me/player/previous");
  else return 400;
  tls.stop();

  if (r.code >= 200 && r.code < 300) {
    if (action == "play") sp.playing = true;
    if (action == "pause") sp.playing = false;
  }
  nextSpotifyAt = millis() + 600;  // Spotify ci mette un attimo ad aggiornare lo stato
  return r.code;
}

// ---- Shelly (per la webapp) ----

bool shellyRpc(const String& path, JsonDocument& doc) {
  Response r = httpRequest(plain, SHELLY_HOST, 80, 2000, "GET", path, "", "");
  bool ok = r.code == 200;
  if (ok) {
    BodyStream body(plain, r);
    ok = !deserializeJson(doc, body);
  }
  plain.stop();
  return ok;
}

bool shellyGetLight(int id, bool& on, int& brightness) {
  JsonDocument doc;
  if (!shellyRpc("/rpc/Light.GetStatus?id=" + String(id), doc)) return false;
  on = doc["output"] | false;
  brightness = doc["brightness"] | 0;
  return true;
}

bool shellySetLight(int id, bool on, int brightness) {
  String path = "/rpc/Light.Set?id=" + String(id) + "&on=" + (on ? "true" : "false");
  if (on) path += "&brightness=" + String(constrain(brightness, 1, 100));
  JsonDocument doc;
  return shellyRpc(path, doc);
}

// ---- Meteo (Open-Meteo, senza chiave API) ----

const char* weatherDesc(int c) {
  switch (c) {
    case 0: return "Sereno";
    case 1: return "Poco nuvoloso";
    case 2: return "Parz. nuvoloso";
    case 3: return "Coperto";
    case 45: case 48: return "Nebbia";
    case 51: case 53: case 55: return "Pioviggine";
    case 56: case 57: return "Pioviggine gelata";
    case 61: return "Pioggia debole";
    case 63: return "Pioggia";
    case 65: return "Pioggia forte";
    case 66: case 67: return "Pioggia gelata";
    case 71: return "Neve debole";
    case 73: return "Neve";
    case 75: return "Neve forte";
    case 77: return "Nevischio";
    case 80: case 81: return "Rovesci";
    case 82: return "Rovesci forti";
    case 85: case 86: return "Rovesci di neve";
    case 95: return "Temporale";
    case 96: case 99: return "Temporale e grandine";
    default: return "?";
  }
}

void updateWeather() {
  String path = "/v1/forecast?latitude=";
  path += String(LATITUDE, 4);
  path += "&longitude=";
  path += String(LONGITUDE, 4);
  path += "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"
          "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
          "&timezone=auto&forecast_days=3";

  Response r = httpsRequest("api.open-meteo.com", "GET", path, "", "");
  bool ok = false;
  if (r.code == 200) {
    BodyStream body(tls, r);
    JsonDocument doc;
    if (!deserializeJson(doc, body)) {
      JsonObject cur = doc["current"];
      wx.temp = cur["temperature_2m"];
      wx.feels = cur["apparent_temperature"];
      wx.hum = cur["relative_humidity_2m"];
      wx.wind = lroundf(cur["wind_speed_10m"].as<float>());
      wx.code = cur["weather_code"];
      JsonObject daily = doc["daily"];
      for (int i = 0; i < 3; i++) {
        wx.dCode[i] = daily["weather_code"][i];
        wx.dMin[i] = lroundf(daily["temperature_2m_min"][i].as<float>());
        wx.dMax[i] = lroundf(daily["temperature_2m_max"][i].as<float>());
        wx.dPop[i] = daily["precipitation_probability_max"][i] | 0;
      }
      wx.utcOffset = doc["utc_offset_seconds"];  // include l'ora legale
      ok = true;
    }
  } else {
    Serial.print("Meteo: richiesta fallita, HTTP ");
    Serial.println(r.code);
  }
  tls.stop();
  wx.ok = wx.ok || ok;  // in caso di errore teniamo gli ultimi dati validi
  nextWeatherAt = millis() + (ok ? WEATHER_POLL_MS : WEATHER_RETRY_MS);
}

// ---- Ora ----

void syncTime() {
  unsigned long epoch = WiFi.getTime();
  if (epoch > 1700000000UL) {
    epochAtSync = epoch;
    millisAtSync = millis();
    nextNtpAt = millis() + NTP_SYNC_MS;
  } else {
    nextNtpAt = millis() + NTP_RETRY_MS;
  }
}

// Giorni dal 1970-01-01 -> mese e giorno (algoritmo di Howard Hinnant).
void civilFromDays(long z, int& m, int& d) {
  z += 719468;
  long era = z / 146097;
  unsigned long doe = z - era * 146097;
  unsigned long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  unsigned long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  unsigned long mp = (5 * doy + 2) / 153;
  d = doy - (153 * mp + 2) / 5 + 1;
  m = mp < 10 ? mp + 3 : mp - 9;
}

// Ora e data locali. false finché non ci sono sia l'NTP sia il fuso orario,
// che arriva insieme al meteo.
bool localClock(long& today, String& time, String& date) {
  if (epochAtSync == 0 || !wx.ok) return false;
  unsigned long local = epochAtSync + (millis() - millisAtSync) / 1000 + wx.utcOffset;
  today = local / 86400;
  unsigned long sec = local % 86400;
  char hhmm[6];
  snprintf(hhmm, sizeof hhmm, "%02lu:%02lu", sec / 3600, sec / 60 % 60);
  int m, d;
  civilFromDays(today, m, d);
  time = hhmm;
  date = String(WEEKDAYS[(today + 4) % 7]) + " " + d + " " + MONTHS[m - 1];
  return true;
}

long spotifyProgressMs() {
  long progress = sp.progressMs;
  if (sp.playing) progress += millis() - sp.fetchedAt;
  return min(progress, sp.durationMs);
}

// ---- Server HTTP per Kindle e webapp ----

// Una riga "chiave=valore"; i valori non devono contenere a capo.
void kv(String& s, const char* key, String value) {
  value.replace('\n', ' ');
  value.replace('\r', ' ');
  s += key;
  s += '=';
  s += value;
  s += '\n';
}

String decimalComma(float v) {
  String s(v, 1);
  s.replace('.', ',');
  return s;
}

String buildStatus() {
  String s;
  s.reserve(700);
  long today = -1;
  String time = "--:--", date;
  localClock(today, time, date);
  kv(s, "time", time);
  kv(s, "date", date);

  kv(s, "w_ok", wx.ok ? "1" : "0");
  if (wx.ok) {
    kv(s, "w_temp", decimalComma(wx.temp));
    kv(s, "w_feels", decimalComma(wx.feels));
    kv(s, "w_hum", String(wx.hum));
    kv(s, "w_wind", String(wx.wind));
    kv(s, "w_desc", weatherDesc(wx.code));
    for (int i = 0; i < 3; i++) {
      String label = i == 0 ? "Oggi" : i == 1 ? "Domani" : today >= 0 ? WEEKDAYS_SHORT[(today + 2 + 4) % 7] : "Dopodomani";
      char key[3] = {'d', char('0' + i), 0};
      kv(s, key, label + "|" + weatherDesc(wx.dCode[i]) + "|" + wx.dMin[i] + "|" + wx.dMax[i] + "|" + wx.dPop[i]);
    }
  }

  kv(s, "sp_ok", sp.configured && sp.ok ? "1" : "0");
  kv(s, "sp_active", sp.active ? "1" : "0");
  kv(s, "sp_playing", sp.playing ? "1" : "0");
  kv(s, "sp_track", sp.track);
  kv(s, "sp_artist", sp.artist);
  kv(s, "sp_progress", String(spotifyProgressMs() / 1000));
  kv(s, "sp_duration", String(sp.durationMs / 1000));
  kv(s, "ota_req", String(otaRequests));
  return s;
}

// Stato per la webapp. Le luci si leggono dallo Shelly a ogni richiesta, così
// si vedono anche le modifiche fatte dal Kindle o dall'app Shelly.
String buildApiState() {
  JsonDocument doc;
  long today;
  String time = "--:--", date;
  localClock(today, time, date);
  doc["time"] = time;
  doc["date"] = date;

  JsonObject w = doc["w"].to<JsonObject>();
  w["ok"] = wx.ok;
  if (wx.ok) {
    w["temp"] = decimalComma(wx.temp);
    w["desc"] = weatherDesc(wx.code);
  }

  JsonArray lights = doc["lights"].to<JsonArray>();
  for (int i = 0; i < NUM_LIGHTS; i++) {
    JsonObject l = lights.add<JsonObject>();
    l["name"] = LIGHTS[i].name;
    bool on;
    int b;
    if (shellyGetLight(LIGHTS[i].id, on, b)) {
      l["on"] = on;
      l["b"] = b;
    } else {
      l["ok"] = false;
    }
  }

  JsonObject s = doc["sp"].to<JsonObject>();
  s["ok"] = sp.configured && sp.ok;
  s["active"] = sp.active;
  s["playing"] = sp.playing;
  s["track"] = sp.track;
  s["artist"] = sp.artist;
  s["progress"] = spotifyProgressMs() / 1000;
  s["duration"] = sp.durationMs / 1000;

  JsonObject ota = doc["ota"].to<JsonObject>();
  ota["configured"] = strlen(SECRET_GITHUB_TOKEN) > 0;
  ota["kindle"] = kindleVersion;
  ota["latest"] = latestVersion;

  String out;
  serializeJson(doc, out);
  return out;
}

void sendText(WiFiClient& c, int code, const String& body,
              const char* type = "text/plain; charset=utf-8") {
  c.print("HTTP/1.1 " + String(code) + (code == 200 ? " OK" : " Error") + "\r\n"
          "Content-Type: " + type + "\r\n"
          "Cache-Control: no-store\r\n"
          "Connection: close\r\n"
          "Content-Length: " + String(body.length()) + "\r\n\r\n" + body);
}

void sendWebapp(WiFiClient& c) {
  size_t len = strlen(WEBAPP_HTML);
  c.print("HTTP/1.1 200 OK\r\n"
          "Content-Type: text/html; charset=utf-8\r\n"
          "Connection: close\r\n"
          "Content-Length: " + String(len) + "\r\n\r\n");
  for (size_t off = 0; off < len; off += 1024) {
    c.write((const uint8_t*)WEBAPP_HTML + off, len - off < 1024 ? len - off : 1024);
  }
}

// Valore di un parametro della query string ("" se assente)
String queryParam(const String& path, const char* name) {
  String key = String(name) + "=";
  int start = path.indexOf('?') + 1;
  while (start > 0) {
    int end = path.indexOf('&', start);
    if (path.startsWith(key, start)) return path.substring(start + key.length(), end < 0 ? path.length() : end);
    start = end + 1;
  }
  return "";
}

void sendCommandResult(WiFiClient& c, int code) {
  bool ok = code >= 200 && code < 300;
  sendText(c, ok ? 200 : 502, ok ? "ok\n" : "errore " + String(code) + "\n");
}

// ---- GitHub (aggiornamenti OTA del Kindle) ----

// "kindle-v12" -> 12; -1 se non è un tag di rilascio del Kindle
long releaseNumber(const String& tag) {
  unsigned n = strlen(OTA_TAG_PREFIX);
  if (!tag.startsWith(OTA_TAG_PREFIX) || tag.length() == n || tag.length() > n + 6) return -1;
  for (unsigned i = n; i < tag.length(); i++) {
    if (!isDigit(tag[i])) return -1;
  }
  return tag.substring(n).toInt();
}

Response githubApi(const String& path, const char* accept) {
  return httpsRequest("api.github.com", "GET", path,
                      String("Authorization: Bearer ") + SECRET_GITHUB_TOKEN + "\r\n"
                      "Accept: " + accept + "\r\n"
                      "User-Agent: kindle-homeview\r\n"
                      "X-GitHub-Api-Version: 2022-11-28\r\n", "");
}

void sendLatestVersion(WiFiClient& c) {
  if (strlen(SECRET_GITHUB_TOKEN) == 0) {
    sendText(c, 503, "OTA non configurato: manca SECRET_GITHUB_TOKEN\n");
    return;
  }
  Response r = githubApi(String("/repos/") + GITHUB_REPO + "/git/matching-refs/tags/" + OTA_TAG_PREFIX,
                         "application/vnd.github+json");
  String latest;
  long best = -1;
  if (r.code == 200) {
    JsonDocument filter;
    filter[0]["ref"] = true;
    BodyStream body(tls, r);
    JsonDocument doc;
    if (!deserializeJson(doc, body, DeserializationOption::Filter(filter))) {
      for (JsonObject ref : doc.as<JsonArray>()) {
        String tag = String(ref["ref"] | "").substring(strlen("refs/tags/"));
        long n = releaseNumber(tag);  // confronto numerico: kindle-v10 viene dopo kindle-v9
        if (n > best) {
          best = n;
          latest = tag;
        }
      }
    }
  }
  tls.stop();
  if (best < 0) {
    sendText(c, r.code == 200 ? 404 : 502,
             r.code == 200 ? String("nessun tag ") + OTA_TAG_PREFIX + "N\n" : "GitHub: HTTP " + String(r.code) + "\n");
    return;
  }
  latestVersion = latest;
  sendText(c, 200, latest + "\n");
}

// Inoltra un file del repository. Solo la cartella kindle/ e solo a un tag di
// rilascio, così l'Arduino non diventa un accesso libero al repository.
void sendRepoFile(WiFiClient& c, const String& tag, const String& path) {
  if (releaseNumber(tag) < 0 || !path.startsWith("kindle/") || path.indexOf("..") >= 0) {
    sendText(c, 400, "richiesta non valida\n");
    return;
  }
  Response r = githubApi(String("/repos/") + GITHUB_REPO + "/contents/" + path + "?ref=" + tag,
                         "application/vnd.github.raw");
  if (r.code != 200) {
    tls.stop();
    sendText(c, 502, "GitHub: HTTP " + String(r.code) + "\n");
    return;
  }
  c.print("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n");
  if (!r.chunked && r.length >= 0) c.print("Content-Length: " + String(r.length) + "\r\n");
  c.print("\r\n");
  BodyStream body(tls, r);
  uint8_t buf[256];
  size_t n;
  while ((n = body.readBytes(buf, sizeof buf)) > 0) c.write(buf, n);
  tls.stop();
}

void handleClient() {
  WiFiClient c = server.available();
  if (!c) return;
  c.setTimeout(2000);
  String request = c.readStringUntil('\n');  // es. "GET /cmd?a=next HTTP/1.1"
  while (c.connected()) {                    // salta gli header
    String h = c.readStringUntil('\n');
    if (h.length() <= 1) break;
  }
  int a = request.indexOf(' '), b = request.indexOf(' ', a + 1);
  String path = request.substring(a + 1, b);

  if (path == "/status" || path.startsWith("/status?")) {
    String v = queryParam(path, "v");  // versione in uso sul Kindle
    if (releaseNumber(v) >= 0) kindleVersion = v;
    sendText(c, 200, buildStatus());
  } else if (path == "/ota/version") {
    sendLatestVersion(c);
  } else if (path.startsWith("/ota/file?")) {
    sendRepoFile(c, queryParam(path, "ref"), queryParam(path, "path"));
  } else if (path == "/api/ota") {
    otaRequests++;
    sendText(c, 200, "ok\n");
  } else if (path.startsWith("/cmd?") || path.startsWith("/api/cmd?")) {
    sendCommandResult(c, spotifyCommand(queryParam(path, "a")));
  } else if (path == "/" || path.startsWith("/?")) {
    sendWebapp(c);
  } else if (path == "/api/state") {
    sendText(c, 200, buildApiState(), "application/json");
  } else if (path.startsWith("/api/light?")) {
    int i = queryParam(path, "i").toInt();
    bool valid = queryParam(path, "i").length() > 0 && i >= 0 && i < NUM_LIGHTS;
    bool ok = valid && shellySetLight(LIGHTS[i].id, queryParam(path, "on") == "1", queryParam(path, "b").toInt());
    sendCommandResult(c, valid ? (ok ? 200 : 502) : 400);
  } else {
    sendText(c, 404, "non trovato\n");
  }
  delay(1);
  c.stop();
}

bool serverStarted = false;

void setup() {
  Serial.begin(9600);
  delay(1500);  // dà tempo di aprire il Serial Monitor

  refreshToken = SECRET_SPOTIFY_REFRESH_TOKEN;
  basicAuth = base64(String(SECRET_SPOTIFY_CLIENT_ID) + ":" + SECRET_SPOTIFY_CLIENT_SECRET);
  sp.configured = refreshToken.length() > 0;

  initProperties();  // in thingProperties.h
  ArduinoCloud.begin(ArduinoIoTPreferredConnection);
  setDebugMessageLevel(2);
  ArduinoCloud.printDebugInfo();
}

void loop() {
  ArduinoCloud.update();
  if (WiFi.status() != WL_CONNECTED) return;
  if (!serverStarted && WiFi.localIP() != IPAddress(0, 0, 0, 0)) {
    server.begin();
    serverStarted = true;
    Serial.print("Gateway pronto: http://");
    Serial.print(WiFi.localIP());
    Serial.println("/");
  }

  handleClient();
  // Al massimo un'operazione lenta per giro, così il Cloud viene servito spesso
  if (due(nextNtpAt)) syncTime();
  else if (due(nextWeatherAt)) updateWeather();
  else if (sp.configured && due(nextSpotifyAt)) updateNowPlaying();
}
