/*
  Gateway for the Kindle panel — Arduino UNO R4 WiFi

  The Kindle 5 can't do modern HTTPS: this sketch talks HTTPS to Spotify and
  Open-Meteo and gives the Kindle two plain-HTTP endpoints:

    GET /status           state as "key=value", one line per key, lights included;
                          ?sleep=S: the Kindle pauses its WiFi for S seconds
    GET /cmd?a=ACTION     Spotify command: toggle | play | pause | next | prev

  It also serves the phone webapp (LAN only, no password):

    GET /                          the page (webapp.h)
    GET /api/state                 state as JSON, lights included
    GET /api/light?i=N&on=1&b=50   switches/dims light N (index into LIGHTS)
    GET /api/cmd?a=ACTION          same as /cmd
    GET /api/ota                   asks the Kindle to check for updates

  And it relays the Kindle's OTA updates from GitHub (OTA_GITHUB_REPO in
  home_config.h; token in arduino_secrets.h, needed only for a private repo):

    GET /ota/version                      latest kindle-vN release tag
    GET /ota/file?ref=TAG&path=kindle/F   a file of the kindle/ folder at that tag

  It is also an Arduino Cloud device: on a power cut the device goes offline
  and the trigger set up in the Cloud sends a notification. WiFi is handled by
  the Cloud library (credentials from the Network Configurator), so this
  sketch only uses the network while connected and calls ArduinoCloud.update()
  between slow operations.

  Libraries: ArduinoIoTCloud (with its dependencies) and ArduinoJson 7.
*/

#include "thingProperties.h"
#include <WiFiS3.h>
#include "Modem.h"         // modem and AT commands, for ChunkedSSLClient
#include "WiFiCommands.h"
#include <WDT.h>
#include "FspTimer.h"
#include <malloc.h>
#include <ArduinoJson.h>
#include "arduino_secrets.h"
#ifndef SECRET_GITHUB_TOKEN  // arduino_secrets.h from before OTA existed: no token
#define SECRET_GITHUB_TOKEN ""
#endif
#include "https_response.h"
#include "webapp.h"

// ---- Configuration ----
// Location, Shelly and lights live in home_config.h (a copy of
// home_config.h.example), kept out of git like arduino_secrets.h.
struct Light {
  const char* name;
  int id;  // Shelly channel (0-3)
};
#include "home_config.h"
const int NUM_LIGHTS = sizeof(LIGHTS) / sizeof(LIGHTS[0]);

// Repository the Kindle takes its updates from: the kindle-vN tags.
// Forks set OTA_GITHUB_REPO in home_config.h; "" turns OTA off.
#ifndef OTA_GITHUB_REPO
#define OTA_GITHUB_REPO "balsick/kindle-homeview"
#endif
const char* const GITHUB_REPO = OTA_GITHUB_REPO;
const char* const OTA_TAG_PREFIX = "kindle-v";

const unsigned long SPOTIFY_POLL_PLAYING_MS = 5000;
const unsigned long SPOTIFY_POLL_IDLE_MS = 20000;
const unsigned long WEATHER_POLL_MS = 15UL * 60 * 1000;
const unsigned long WEATHER_RETRY_MS = 60UL * 1000;
const unsigned long NTP_SYNC_MS = 60UL * 60 * 1000;
const unsigned long NTP_RETRY_MS = 10UL * 1000;

// Text shown on the Kindle and in the webapp is in Italian
const char* const WEEKDAYS[] = {"domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato"};
const char* const WEEKDAYS_SHORT[] = {"Dom", "Lun", "Mar", "Mer", "Gio", "Ven", "Sab"};
const char* const MONTHS[] = {"gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno",
                              "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre"};

WiFiServer server(80);
const unsigned long ACCEPT_INTERVAL_MS = 50;

// The sketch's own stack (see runOnAppStack). Right below appStack in memory
// sits accessToken: with 2 KB the stack overflowed into the token String and
// Spotify requests went out garbled (400).
const size_t APP_STACK_BYTES = 2560;  // measured peak ~1.7 KB
// TLS client that reads at most SSL_CHUNK bytes at a time from the WiFi module.
// WiFiSSLClient asks for up to 1023 and receives them in a std::string that
// grows one byte at a time: the reallocations need a ~3 KB contiguous block.
// With a fragmented heap that block is sometimes missing, and abort() hangs
// the board. Here the space is reserved up front (assign and clear don't
// release it) and a single SSL_CHUNK-byte block is needed, once.
const size_t SSL_CHUNK = 512;

class ChunkedSSLClient : public WiFiSSLClient {
 public:
  int read() override {
    uint8_t b;
    return read(&b, 1) == 1 ? b : -1;
  }

  int read(uint8_t* buf, size_t size) override {
    if (_sock < 0 || !rx_buffer) return 0;
    if ((size_t)rx_buffer->available() < size) fill();
    int n = 0;
    for (size_t i = 0; i < size; i++) {
      bool ok = false;
      uint8_t v = rx_buffer->read(&ok);
      if (!ok) break;
      buf[n++] = v;
    }
    return n;
  }

 private:
  void fill() {
    size_t size = rx_buffer->freePositions() - 1;
    if (size > SSL_CHUNK) size = SSL_CHUNK;
    if (size == 0) return;
    std::string res;
    res.reserve(size + 16);
    modem.begin();
    modem.avoid_trim_results();  // as in WiFiSSLClient::_read(): they apply once
    modem.read_using_size();
    if (modem.write(std::string(PROMPT(_SSLCLIENTRECEIVE)), res, "%s%d,%d\r\n",
                    CMD_WRITE(_SSLCLIENTRECEIVE), _sock, size)) {
      for (size_t i = 0; i < res.size() && i < size; i++) rx_buffer->store((uint8_t)res[i]);
    }
  }
};

ChunkedSSLClient tls;
// No global WiFiClient for the Shelly: in WiFiS3 every WiFiClient allocates a
// 1 KB buffer as soon as it's constructed, and RAM is short. We create one
// only when needed.

// ---- State ----
struct {
  bool configured = false;
  bool ok = false;        // last call succeeded
  bool active = false;    // something is loaded in the player
  bool playing = false;
  String track, artist;
  String device;          // where it plays (home devices only)
  int volume = -1;        // -1: the device has no volume control
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
String kindleVersion, latestVersion;  // shown in the webapp
unsigned long kindleSeenAt = 0;  // last /status request from the Kindle
unsigned long kindleAwayMs = 0;  // the Kindle said it pauses (WiFi off) for this long
unsigned otaRequests = 0;         // the Kindle checks for updates when this changes

bool due(unsigned long at) { return (long)(millis() - at) >= 0; }

// Latest errors, with seconds since boot, for GET /log (static buffer)
const int LOG_LINES = 6;
const int LOG_WIDTH = 80;
char errLog[LOG_LINES][LOG_WIDTH];
int errLogNext = 0;

// Writes the error to serial, to the Thing's lastError variable and to errLog
void logError(const String& msg) {
  Serial.println(msg);
  lastError = msg;
  snprintf(errLog[errLogNext], LOG_WIDTH, "%lu %s", millis() / 1000, msg.c_str());
  errLogNext = (errLogNext + 1) % LOG_LINES;
}

// ---- HTTP/HTTPS client ----

// Requests are written in pieces, without String: with a fragmented heap,
// String concatenations fail silently and the request went out malformed
// (Google's front end answers "400 Bad Request"). The pieces go through
// writeBuf and are sent in WRITE_CHUNK-byte blocks: a single ~600-byte burst
// sometimes reached the WiFi module garbled.
const size_t WRITE_CHUNK = 128;
char writeBuf[WRITE_CHUNK];
char pathBuf[160];

// printf-style path, in the static pathBuf (valid until the next call)
const char* fmtPath(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(pathBuf, sizeof(pathBuf), fmt, ap);
  va_end(ap);
  return pathBuf;
}

// Sends a request and leaves `c` positioned at the start of the body.
// headers and body are lists of pieces to concatenate, terminated by nullptr
// (header lines end with "\r\n"). code = -1 on failure.
Response httpRequest(Client& c, const char* host, uint16_t port, unsigned long timeoutMs,
                     const char* method, const char* path, const char* const* headers,
                     const char* const* body) {
  Response r;
  c.stop();
  if (!c.connect(host, port)) return r;
  c.setTimeout(timeoutMs);

  size_t n = 0, bodyLen = 0;
  auto put = [&](const char* s) {
    while (*s) {
      writeBuf[n++] = *s++;
      if (n == WRITE_CHUNK) { c.write((const uint8_t*)writeBuf, n); n = 0; }
    }
  };
  for (const char* const* b = body; b && *b; b++) bodyLen += strlen(*b);
  put(method); put(" "); put(path); put(" HTTP/1.1\r\nHost: "); put(host);
  put("\r\nConnection: close\r\n");
  for (const char* const* h = headers; h && *h; h++) put(*h);
  if (strcmp(method, "GET") != 0) {
    char len[32];
    snprintf(len, sizeof(len), "Content-Length: %u\r\n", (unsigned)bodyLen);
    put(len);
  }
  put("\r\n");
  for (const char* const* b = body; b && *b; b++) put(*b);
  if (n) c.write((const uint8_t*)writeBuf, n);

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

Response httpsRequest(const char* host, const char* method, const char* path,
                      const char* const* headers = nullptr, const char* const* body = nullptr) {
  return httpRequest(tls, host, 443, 5000, method, path, headers, body);
}

const size_t WEATHER_MAX_BYTES = 4096;
const size_t TOKEN_MAX_BYTES = 2048;
const size_t DEVICES_MAX_BYTES = 3072;

class BodyStream;
String readBody(Client& c, const Response& r, size_t maxBytes);

// Reads the response body, decoding "chunked" on the fly, so ArduinoJson can
// parse it as a stream without loading it all into RAM.
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
    if (left_ == 0) {  // Content-Length used up
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
    if (started_) c_.readStringUntil('\n');  // CRLF after the previous chunk
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
  long left_;  // bytes left in the chunk or body; -1 = until the connection closes
  bool started_ = false, done_ = false;
  int peeked_ = -1;
};

// Reads the whole body (at most maxBytes) into a String
String readBody(Client& c, const Response& r, size_t maxBytes) {
  BodyStream body(c, r);
  String out;
  out.reserve(r.length > 0 && (size_t)r.length < maxBytes ? r.length : 1024);
  int ch;
  while (out.length() < maxBytes && (ch = body.read()) >= 0) out += (char)ch;
  return out;
}

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
  const char* headers[] = {"Authorization: Basic ", basicAuth.c_str(),
                           "\r\nContent-Type: application/x-www-form-urlencoded\r\n", nullptr};
  const char* body[] = {"grant_type=refresh_token&refresh_token=", refreshToken.c_str(), nullptr};
  Response r = httpsRequest("accounts.spotify.com", "POST", "/api/token", headers, body);
  // Small response: read it all before parsing, as for the weather
  String json = r.code > 0 ? readBody(tls, r, TOKEN_MAX_BYTES) : String();
  tls.stop();
  bool ok = false;
  if (r.code == 200) {
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, json);
    if (err) {
      logError(String("Spotify: unreadable token response (") + err.c_str() + ")");
    } else {
      accessToken = doc["access_token"] | "";
      tokenAt = millis();
      tokenValidMs = ((doc["expires_in"] | 3600) - 60) * 1000UL;
      // Spotify usually doesn't rotate the refresh token, but if it does we keep
      // it (in RAM only: after a reboot we start again from arduino_secrets.h).
      if (doc["refresh_token"].is<const char*>()) refreshToken = doc["refresh_token"].as<const char*>();
      ok = accessToken.length() > 0;
      if (!ok) logError("Spotify: token response without access_token");
    }
  } else {
    logError("Spotify: token refresh failed, HTTP " + String(r.code) + " " + json.substring(0, 80));
  }
  return ok;
}

// Calls the Web API. Afterwards the body is to be read from `tls`.
// path may live in pathBuf (fmtPath): refreshing the token doesn't touch it
Response spotifyApi(const char* method, const char* path, const char* const* body = nullptr) {
  if (accessToken.length() == 0 || millis() - tokenAt > tokenValidMs) {
    if (!refreshSpotifyToken()) return Response();
  }
  const char* headers[] = {"Authorization: Bearer ", accessToken.c_str(), "\r\n",
                           body ? "Content-Type: application/json\r\n" : "", nullptr};
  Response r = httpsRequest("api.spotify.com", method, path, headers, body);
  if (r.code == 401) accessToken = "";  // token expired: refreshed on the next call
  return r;
}

void updateNowPlaying() {
  // /v1/me/player also says which device is playing: only home devices count
  // (Echos, type "Speaker"), not the phone at the office.
  Response r = spotifyApi("GET", "/v1/me/player?market=from_token&additional_types=episode");
  unsigned long next = SPOTIFY_POLL_IDLE_MS;

  if (r.code == 204) {  // nothing playing
    sp.ok = true;
    sp.active = sp.playing = false;
    sp.device = "";
    sp.volume = -1;
  } else if (r.code == 200) {
    JsonDocument filter;
    filter["is_playing"] = true;
    filter["progress_ms"] = true;
    filter["item"]["name"] = true;
    filter["item"]["duration_ms"] = true;
    filter["item"]["artists"][0]["name"] = true;
    filter["item"]["show"]["name"] = true;
    filter["device"]["name"] = true;
    filter["device"]["type"] = true;
    filter["device"]["volume_percent"] = true;
    filter["device"]["supports_volume"] = true;

    BodyStream body(tls, r);
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, body, DeserializationOption::Filter(filter));
    sp.ok = !err;
    if (!err) {
      JsonObject item = doc["item"];
      JsonObject dev = doc["device"];
      bool home = strcmp(dev["type"] | "", SPOTIFY_HOME_TYPE) == 0;
      sp.device = home ? String(dev["name"] | "") : String();
      sp.volume = home && (dev["supports_volume"] | false) ? (dev["volume_percent"] | -1) : -1;
      sp.active = home && !item.isNull();
      sp.playing = sp.active && (doc["is_playing"] | false);
      sp.progressMs = doc["progress_ms"] | 0;
      sp.durationMs = item["duration_ms"] | 0;
      sp.track = item["name"] | "";
      // Tracks: list of artists. Podcast episodes: name of the show.
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
    logError("Spotify: now playing failed, HTTP " + String(r.code));
    if (r.code == 429) next = 60000;  // rate limit
  }
  tls.stop();
  nextSpotifyAt = millis() + next;
}

// Id of the home device to start music on (SPOTIFY_HOME_DEVICE)
String spotifyHomeDeviceId() {
  Response r = spotifyApi("GET", "/v1/me/player/devices");
  String json = r.code == 200 ? readBody(tls, r, DEVICES_MAX_BYTES) : String();
  tls.stop();
  JsonDocument doc;
  if (deserializeJson(doc, json)) return "";
  for (JsonObject d : doc["devices"].as<JsonArray>())
    if (strcmp(d["name"] | "", SPOTIFY_HOME_DEVICE) == 0) return d["id"] | "";
  return "";
}

// Starts music at home: resumes where it left off on the home device (moving
// it there if it's playing elsewhere). If there's nothing to resume and a
// fallback playlist is set, that one starts.
int spotifyStartAtHome() {
  String id = spotifyHomeDeviceId();
  if (id.length() == 0) {
    logError(String("Spotify: ") + SPOTIFY_HOME_DEVICE + " not found among the devices");
    return 404;
  }
  Response r = spotifyApi("PUT", fmtPath("/v1/me/player/play?device_id=%s", id.c_str()));
  tls.stop();
  if ((r.code < 200 || r.code >= 300) && strlen(SPOTIFY_FALLBACK_CONTEXT) > 0) {
    const char* body[] = {"{\"context_uri\":\"", SPOTIFY_FALLBACK_CONTEXT, "\"}", nullptr};
    r = spotifyApi("PUT", fmtPath("/v1/me/player/play?device_id=%s", id.c_str()), body);
    tls.stop();
  }
  if (r.code < 200 || r.code >= 300) logError("Spotify: start at home failed, HTTP " + String(r.code));
  return r.code;
}

// Actions: toggle (pause, or start at home if nothing plays at home), play,
// pause, next, prev, vol (with value = 0-100). Everything but starting only
// applies to music playing at home.
int spotifyCommand(String action, const String& value) {
  if (!sp.configured) return 503;
  if (action == "toggle") action = sp.playing ? "pause" : "play";

  Response r;
  if (action == "play") {
    if (!sp.active) {
      int code = spotifyStartAtHome();
      nextSpotifyAt = millis() + 1500;
      return code;
    }
    r = spotifyApi("PUT", "/v1/me/player/play");
  } else if (!sp.active) {
    return 409;  // nothing playing at home
  } else if (action == "pause") {
    r = spotifyApi("PUT", "/v1/me/player/pause");
  } else if (action == "next") {
    r = spotifyApi("POST", "/v1/me/player/next");
  } else if (action == "prev") {
    r = spotifyApi("POST", "/v1/me/player/previous");
  } else if (action == "vol") {
    if (sp.volume < 0) return 409;  // this device has no volume control
    int v = constrain(value.toInt(), 0, 100);
    r = spotifyApi("PUT", fmtPath("/v1/me/player/volume?volume_percent=%d", v));
    if (r.code >= 200 && r.code < 300) sp.volume = v;
  } else {
    return 400;
  }
  if (r.code < 200 || r.code >= 300) {
    // Spotify's message says why (device, Premium, request…)
    String msg = r.code > 0 ? readBody(tls, r, 512) : String();
    logError("Spotify: " + action + " failed, HTTP " + String(r.code) + " " + msg.substring(0, 120));
  }
  tls.stop();

  if (r.code >= 200 && r.code < 300) {
    if (action == "play") sp.playing = true;
    if (action == "pause") sp.playing = false;
  }
  nextSpotifyAt = millis() + 600;  // Spotify takes a moment to update its state
  return r.code;
}

// ---- Shelly (for the webapp) ----

bool shellyRpc(const char* path, JsonDocument& doc) {
  WiFiClient plain;  // plain HTTP to the Shelly
  Response r = httpRequest(plain, SHELLY_HOST, 80, 2000, "GET", path, nullptr, nullptr);
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
  if (!shellyRpc(fmtPath("/rpc/Light.GetStatus?id=%d", id), doc)) return false;
  on = doc["output"] | false;
  brightness = doc["brightness"] | 0;
  return true;
}

bool shellySetLight(int id, bool on, int brightness) {
  const char* path = on ? fmtPath("/rpc/Light.Set?id=%d&on=true&brightness=%d", id, constrain(brightness, 1, 100))
                        : fmtPath("/rpc/Light.Set?id=%d&on=false", id);
  JsonDocument doc;
  return shellyRpc(path, doc);
}

// ---- Weather (Open-Meteo, no API key) ----

// WMO weather codes
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

// The weather path never changes: it's built once at startup
char weatherPath[280];  // ~256 characters with typical coordinates

void buildWeatherPath() {
  char lat[16], lon[16];
  dtostrf(LATITUDE, 1, 4, lat);
  dtostrf(LONGITUDE, 1, 4, lon);
  snprintf(weatherPath, sizeof(weatherPath),
           "/v1/forecast?latitude=%s&longitude=%s"
           "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"
           "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
           "&timezone=auto&forecast_days=3", lat, lon);
}

void updateWeather() {

  Serial.println("Weather: updating");
  Response r = httpsRequest("api.open-meteo.com", "GET", weatherPath);
  bool ok = false;
  if (r.code == 200) {
    // The response is small (~1 KB): read it all and close the connection
    // before parsing. That way the parser doesn't read from the network while
    // recursing (less stack) and a slow connection can't stall it.
    String json = readBody(tls, r, WEATHER_MAX_BYTES);
    tls.stop();
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, json);
    JsonObject cur = doc["current"];
    JsonObject daily = doc["daily"];
    // Only complete responses are accepted: otherwise we keep the previous data
    if (err || doc.overflowed() || cur["temperature_2m"].isNull() || daily["weather_code"].size() < 3 ||
        daily["temperature_2m_min"].size() < 3 || daily["temperature_2m_max"].size() < 3) {
      logError(String("Weather: incomplete response (") + err.c_str() + ", forecast days " +
               daily["weather_code"].size() + ")");
    } else {
      wx.temp = cur["temperature_2m"];
      wx.feels = cur["apparent_temperature"];
      wx.hum = cur["relative_humidity_2m"];
      wx.wind = lroundf(cur["wind_speed_10m"].as<float>());
      wx.code = cur["weather_code"];
      for (int i = 0; i < 3; i++) {
        wx.dCode[i] = daily["weather_code"][i];
        wx.dMin[i] = lroundf(daily["temperature_2m_min"][i].as<float>());
        wx.dMax[i] = lroundf(daily["temperature_2m_max"][i].as<float>());
        wx.dPop[i] = daily["precipitation_probability_max"][i] | 0;
      }
      wx.utcOffset = doc["utc_offset_seconds"];  // includes daylight saving time
      ok = true;
    }
  } else {
    logError("Weather: request failed, HTTP " + String(r.code));
  }
  tls.stop();
  wx.ok = wx.ok || ok;  // on error we keep the last valid data
  weatherOk = ok;
  if (ok) Serial.println("Weather: ok");
  nextWeatherAt = millis() + (ok ? WEATHER_POLL_MS : WEATHER_RETRY_MS);
}

// ---- Time ----

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

// Days since 1970-01-01 -> month and day (Howard Hinnant's algorithm).
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

// Local time and date. false until we have both NTP and the time zone, which
// comes with the weather.
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

// ---- HTTP server for the Kindle and the webapp ----

// One "key=value" line; values must not contain newlines.
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
  // Lights from the Shelly, so the Kindle doesn't have to ask it itself.
  // Read before building the response, so the 1 KB WiFiClient and the
  // response buffer aren't allocated at the same time. If the Shelly doesn't
  // answer we stop there: lc_ok=0 and no lcN keys.
  bool on[NUM_LIGHTS];
  int bright[NUM_LIGHTS];
  bool lightsOk = true;
  for (int i = 0; i < NUM_LIGHTS && lightsOk; i++) lightsOk = shellyGetLight(LIGHTS[i].id, on[i], bright[i]);

  String s;
  s.reserve(800);
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
  kv(s, "sp_device", sp.device);
  kv(s, "sp_volume", String(sp.volume));
  kv(s, "ota_req", String(otaRequests));

  // lcN=on|brightness, N is the Shelly channel (LIGHT_IDS on the Kindle)
  kv(s, "lc_ok", lightsOk ? "1" : "0");
  if (lightsOk) {
    for (int i = 0; i < NUM_LIGHTS; i++) {
      char key[6];
      snprintf(key, sizeof(key), "lc%d", LIGHTS[i].id);
      kv(s, key, String(on[i] ? "1|" : "0|") + bright[i]);
    }
  }
  return s;
}

// State for the webapp. Lights are read from the Shelly on every request, so
// changes made from the Kindle or the Shelly app show up too.
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
  s["device"] = sp.device;
  s["volume"] = sp.volume;

  JsonObject ota = doc["ota"].to<JsonObject>();
  ota["configured"] = strlen(GITHUB_REPO) > 0;
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

// Value of a query string parameter ("" if missing)
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
  sendText(c, ok ? 200 : 502, ok ? "ok\n" : "error " + String(code) + "\n");
}

// ---- GitHub (OTA updates for the Kindle) ----

// "kindle-v12" -> 12; -1 if it isn't a Kindle release tag
long releaseNumber(const String& tag) {
  unsigned n = strlen(OTA_TAG_PREFIX);
  if (!tag.startsWith(OTA_TAG_PREFIX) || tag.length() == n || tag.length() > n + 6) return -1;
  for (unsigned i = n; i < tag.length(); i++) {
    if (!isDigit(tag[i])) return -1;
  }
  return tag.substring(n).toInt();
}

// Without a token (public repository) the request is anonymous: GitHub allows
// 60 per hour, and a check takes one plus one per updated file.
Response githubApi(const char* path, const char* accept) {
  bool token = strlen(SECRET_GITHUB_TOKEN) > 0;
  const char* headers[] = {token ? "Authorization: Bearer " : "", SECRET_GITHUB_TOKEN, token ? "\r\n" : "",
                           "Accept: ", accept,
                           "\r\nUser-Agent: kindle-homeview\r\nX-GitHub-Api-Version: 2022-11-28\r\n",
                           nullptr};
  return httpsRequest("api.github.com", "GET", path, headers);
}

void sendLatestVersion(WiFiClient& c) {
  if (strlen(GITHUB_REPO) == 0) {
    sendText(c, 503, "OTA not configured: OTA_GITHUB_REPO is empty\n");
    return;
  }
  Response r = githubApi(fmtPath("/repos/%s/git/matching-refs/tags/%s", GITHUB_REPO, OTA_TAG_PREFIX),
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
        long n = releaseNumber(tag);  // numeric comparison: kindle-v10 comes after kindle-v9
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
             r.code == 200 ? String("no ") + OTA_TAG_PREFIX + "N tag\n" : "GitHub: HTTP " + String(r.code) + "\n");
    return;
  }
  latestVersion = latest;
  sendText(c, 200, latest + "\n");
}

// Relays a file of the repository. Only the kindle/ folder and only at a
// release tag, so the Arduino doesn't become an open door to the repository.
void sendRepoFile(WiFiClient& c, const String& tag, const String& path) {
  if (strlen(GITHUB_REPO) == 0 || releaseNumber(tag) < 0 || !path.startsWith("kindle/") ||
      path.indexOf("..") >= 0) {
    sendText(c, 400, "invalid request\n");
    return;
  }
  Response r = githubApi(fmtPath("/repos/%s/contents/%s?ref=%s", GITHUB_REPO, path.c_str(), tag.c_str()),
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
  // accept() constructs a WiFiClient, i.e. allocates and frees 1 KB of heap,
  // even when nobody is there: calling it on every loop fragments the heap.
  // 50 ms is plenty.
  static unsigned long acceptAt = 0;
  if (millis() - acceptAt < ACCEPT_INTERVAL_MS) return;
  acceptAt = millis();
  // accept() returns every new connection, including those that send nothing
  // (browsers open some ahead of time): this way we close them after the
  // timeout instead of letting them hold the WiFi module's few sockets.
  WiFiClient c = server.accept();
  if (!c) return;
  c.setTimeout(1000);
  String request = c.readStringUntil('\n');  // e.g. "GET /cmd?a=next HTTP/1.1"
  while (c.connected()) {                    // skip the headers
    String h = c.readStringUntil('\n');
    if (h.length() <= 1) break;
  }
  int a = request.indexOf(' '), b = request.indexOf(' ', a + 1);
  String path = request.substring(a + 1, b);

  if (path == "/status" || path.startsWith("/status?")) {
    String v = queryParam(path, "v");  // version running on the Kindle
    if (releaseNumber(v) >= 0) kindleVersion = v;
    kindleSeenAt = millis();
    // sleep=SECONDS: the Kindle is about to turn its WiFi off for that long
    // (idle pause), so it isn't reported offline in the meantime
    kindleAwayMs = constrain(queryParam(path, "sleep").toInt(), 0L, 24L * 3600) * 1000UL;
    sendText(c, 200, buildStatus());
  } else if (path == "/ota/version") {
    sendLatestVersion(c);
  } else if (path.startsWith("/ota/file?")) {
    sendRepoFile(c, queryParam(path, "ref"), queryParam(path, "path"));
  } else if (path == "/api/ota") {
    otaRequests++;
    sendText(c, 200, "ok\n");
  } else if (path.startsWith("/cmd?") || path.startsWith("/api/cmd?")) {
    sendCommandResult(c, spotifyCommand(queryParam(path, "a"), queryParam(path, "v")));
  } else if (path == "/" || path.startsWith("/?")) {
    sendWebapp(c);
  } else if (path == "/log") {
    struct mallinfo mi = mallinfo();
    size_t lo = 0, hi = 16384;  // largest contiguous block (binary search)
    while (lo < hi) {
      size_t mid = (lo + hi + 1) / 2;
      void* q = malloc(mid);
      if (q) { free(q); lo = mid; } else hi = mid - 1;
    }
    String s = "seconds since boot: " + String(millis() / 1000) + "\nfree stack (minimum): " +
               String(stackFreeBytes()) + " B of " + String(APP_STACK_BYTES) + "\nfree heap: " +
               String(mi.fordblks) + " B in the arena, largest block " + String(lo) + " B\n";
    for (int i = 0; i < LOG_LINES; i++) {
      const char* line = errLog[(errLogNext + i) % LOG_LINES];
      if (line[0]) { s += line; s += "\n"; }
    }
    sendText(c, 200, s);
  } else if (path == "/api/state") {
    sendText(c, 200, buildApiState(), "application/json");
  } else if (path.startsWith("/api/light?")) {
    int i = queryParam(path, "i").toInt();
    bool valid = queryParam(path, "i").length() > 0 && i >= 0 && i < NUM_LIGHTS;
    bool ok = valid && shellySetLight(LIGHTS[i].id, queryParam(path, "on") == "1", queryParam(path, "b").toInt());
    sendCommandResult(c, valid ? (ok ? 200 : 502) : 400);
  } else {
    sendText(c, 404, "not found\n");
  }
  delay(1);
  c.stop();
}

// ---- Watchdog and diagnostics ----
// The R4's hardware WDT tops out at ~5.6 s, too short for a slow HTTPS
// request. A 4 Hz timer refreshes it, but only while loop() is running: if
// loop() stays stuck for LOOP_STUCK_MS the timer stops and the WDT resets the
// board. If instead loop() runs but the Cloud stays disconnected for
// CLOUD_STUCK_MS, the board resets itself: on reboot WiFiS3 also resets the
// WiFi module. The check doesn't look at WiFi.status(), because with the WiFi
// module stuck that also answers "not connected".
// During a Cloud OTA, loop() can stall for a long time while the WiFi module
// downloads the firmware: in that case up to OTA_STUCK_MS is tolerated.
// For OTA_PAUSE_MS after the OTA is announced the sketch doesn't use the
// network (neither server nor HTTPS): commands to the WiFi module during the
// download make it hang.
const unsigned long LOOP_STUCK_MS = 60UL * 1000;
const unsigned long OTA_STUCK_MS = 5UL * 60 * 1000;
const unsigned long OTA_WINDOW_MS = 10UL * 60 * 1000;
const unsigned long OTA_PAUSE_MS = 3UL * 60 * 1000;
const unsigned long CLOUD_STUCK_MS = 10UL * 60 * 1000;
const unsigned long KINDLE_TIMEOUT_MS = 2UL * 60 * 1000;
const unsigned long NET_SETTLE_MS = 5000;  // right after WiFi connects, DNS and Internet aren't ready yet

FspTimer wdtTimer;

volatile unsigned long loopAliveAt = 0;
volatile unsigned long otaRequestAt = 0;  // 0 = no OTA in progress
unsigned long cloudOkAt = 0;

void wdtTick(timer_callback_args_t*) {
  unsigned long now = millis();
  bool ota = otaRequestAt != 0 && now - otaRequestAt < OTA_WINDOW_MS;
  if (now - loopAliveAt < (ota ? OTA_STUCK_MS : LOOP_STUCK_MS)) WDT.refresh();
}

// The Cloud calls this when an OTA arrives: we always accept it, but the
// watchdog becomes more tolerant meanwhile
bool onOtaRequest() {
  otaRequestAt = millis() | 1;
  return true;
}

bool otaPaused() { return otaRequestAt != 0 && millis() - otaRequestAt < OTA_PAUSE_MS; }

void startWatchdog() {
  uint8_t type;
  int8_t ch = FspTimer::get_available_timer(type);
  if (ch < 0 || !wdtTimer.begin(TIMER_MODE_PERIODIC, type, ch, 4.0f, 0.0f, wdtTick) ||
      !wdtTimer.setup_overflow_irq() || !wdtTimer.open() || !wdtTimer.start()) {
    logError("Watchdog: no timer available, watchdog disabled");
    return;
  }
  WDT.begin(5000);
}

// Why the board restarted (RA4M1 reset register), into lastReset
void reportResetCause() {
  if (R_SYSTEM->RSTSR1_b.WDTRF)
    lastReset = "watchdog (loop stuck)";
  else if (R_SYSTEM->RSTSR1_b.SWRF) lastReset = "software (update, Cloud disconnected or stack overflow)";
  else lastReset = "power on or reset button";
  R_SYSTEM->RSTSR1 = 0;
  Serial.println("Restart: " + lastReset);
}

void updateDiagnostics() {
  static unsigned long memLogAt = 0;
  uptimeMin = millis() / 60000;
  // If the stack hit the bottom it has already clobbered the variables below:
  // better to restart clean than carry on with corrupted data.
  if (stackFreeBytes() == 0) {
    Serial.println("Stack overflow: restarting");
    delay(100);
    NVIC_SystemReset();
  }
  if (millis() - memLogAt > 5UL * 60 * 1000) {
    memLogAt = millis();
    struct mallinfo mi = mallinfo();
    Serial.println("Memory: free stack " + String(stackFreeBytes()) + " B, heap " + String(mi.uordblks) +
                   " B used, " + String(mi.fordblks) + " B free in the arena");
  }
  spotifyOk = sp.configured && sp.ok;
  kindleOnline = kindleSeenAt != 0 && millis() - kindleSeenAt < KINDLE_TIMEOUT_MS + kindleAwayMs;
}

// ---- Stack ----
// The UNO R4 core reserves only 1 KB of stack. JSON parsing reads from the
// network while recursing (and reads go through vsnprintf in the modem): it
// exceeds 1 KB and ends up on top of the heap, i.e. right on the JSON document
// just allocated. Result: zeroed forecasts or a HardFault. That's why setup()
// and loop() run on a larger stack of our own; interrupts use it too.
// APP_STACK_BYTES is at the top, with the other settings
const uint32_t STACK_PAINT = 0xA5A5A5A5;
alignas(8) uint32_t appStack[APP_STACK_BYTES / 4];

// Calls fn() with the stack pointer at the top of appStack, then switches back
void runOnAppStack(void (*fn)()) {
  register void (*f)() asm("r4") = fn;
  register uint32_t* top asm("r5") = appStack + APP_STACK_BYTES / 4;
  asm volatile(
      "mov r6, sp     \n"
      "mov sp, r5     \n"
      "sub sp, #8     \n"
      "str r6, [sp]   \n"
      "blx r4         \n"
      "ldr r6, [sp]   \n"
      "mov sp, r6     \n"
      : "+r"(f), "+r"(top)
      :
      : "r0", "r1", "r2", "r3", "r6", "r12", "lr", "memory", "cc",
        "d0", "d1", "d2", "d3", "d4", "d5", "d6", "d7");
}

// Bytes of appStack never used since boot (the stack grows downwards)
int stackFreeBytes() {
  int n = 0;
  while (n < (int)APP_STACK_BYTES && appStack[n / 4] == STACK_PAINT) n += 4;
  return n;
}

bool serverStarted = false;
unsigned long wifiUpAt = 0;  // 0 = WiFi not connected

void appSetup();
void appLoop();

void setup() {
  for (size_t i = 0; i < APP_STACK_BYTES / 4; i++) appStack[i] = STACK_PAINT;
  runOnAppStack(appSetup);
}

void loop() { runOnAppStack(appLoop); }

void appSetup() {
  Serial.begin(9600);
  delay(1500);  // time to open the Serial Monitor

  refreshToken = SECRET_SPOTIFY_REFRESH_TOKEN;
  basicAuth = base64(String(SECRET_SPOTIFY_CLIENT_ID) + ":" + SECRET_SPOTIFY_CLIENT_SECRET);
  sp.configured = refreshToken.length() > 0;
  buildWeatherPath();

  initProperties();  // in thingProperties.h
  reportResetCause();
  ArduinoCloud.begin(ArduinoIoTPreferredConnection);
  ArduinoCloud.onOTARequestCb(onOtaRequest);
  setDebugMessageLevel(2);
  ArduinoCloud.printDebugInfo();

  loopAliveAt = cloudOkAt = millis();
  startWatchdog();
}

void appLoop() {
  loopAliveAt = millis();
  ArduinoCloud.update();
  updateDiagnostics();
  if (ArduinoCloud.connected()) cloudOkAt = millis();
  if (millis() - cloudOkAt > CLOUD_STUCK_MS && !otaPaused()) {
    Serial.println("Cloud disconnected for too long: restarting");
    delay(100);
    NVIC_SystemReset();
  }
  if (WiFi.status() != WL_CONNECTED) {
    wifiUpAt = 0;
    return;
  }
  if (wifiUpAt == 0) wifiUpAt = millis();
  if (otaPaused()) return;
  if (!serverStarted && WiFi.localIP() != IPAddress(0, 0, 0, 0)) {
    server.begin();
    serverStarted = true;
    Serial.print("Gateway ready: http://");
    Serial.print(WiFi.localIP());
    Serial.println("/");
  }

  handleClient();
  if (millis() - wifiUpAt < NET_SETTLE_MS) return;
  // At most one slow operation per loop, so the Cloud gets serviced often
  if (due(nextNtpAt)) syncTime();
  else if (due(nextWeatherAt)) updateWeather();
  else if (sp.configured && due(nextSpotifyAt)) updateNowPlaying();
}
