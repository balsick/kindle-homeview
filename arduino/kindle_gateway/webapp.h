#pragma once

// Webapp served at http://ARDUINO_IP/ (LAN only), with its text in Italian.
// To edit it with a live preview in the browser: python3 tools/webapp_dev.py
static const char WEBAPP_HTML[] = R"html(<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#f4f3ef">
<title>Casa</title>
<style>
:root{--bg:#f4f3ef;--card:#fff;--text:#1c1c1a;--muted:#6b6a65;--line:#e4e2dc;--accent:#c97a12;--knob:#fff;--off:#d6d4cd}
@media (prefers-color-scheme:dark){:root{--bg:#141413;--card:#1f1f1d;--text:#f0efe9;--muted:#9a988f;--line:#2e2d2a;--accent:#f0a83a;--knob:#f0efe9;--off:#45433f}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.4 system-ui,-apple-system,"Segoe UI",sans-serif;-webkit-tap-highlight-color:transparent}
main{max-width:480px;margin:0 auto;padding:20px 16px 32px}
header{display:flex;justify-content:space-between;align-items:flex-end;gap:12px;margin-bottom:20px}
.time{font-size:40px;font-weight:700;line-height:1;font-variant-numeric:tabular-nums}
.date,.muted{color:var(--muted);font-size:14px}
.wx{text-align:right}
.wx b{font-size:22px}
h2{font-size:13px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:24px 4px 8px}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px 16px}
.light+.light{border-top:1px solid var(--line)}
.light{padding:12px 0}
.light:first-child{padding-top:2px}.light:last-child{padding-bottom:2px}
.row{display:flex;align-items:center;justify-content:space-between;gap:12px}
.name{font-weight:600;font-size:17px}
.pct{color:var(--muted);font-variant-numeric:tabular-nums;margin-left:auto}
.switch{appearance:none;width:52px;height:32px;border-radius:16px;background:var(--off);position:relative;border:0;cursor:pointer;flex:none;transition:background .2s}
.switch::after{content:"";position:absolute;top:3px;left:3px;width:26px;height:26px;border-radius:50%;background:var(--knob);box-shadow:0 1px 3px #0004;transition:transform .2s}
.switch[aria-checked=true]{background:var(--accent)}
.switch[aria-checked=true]::after{transform:translateX(20px)}
input[type=range]{width:100%;margin:12px 0 0;accent-color:var(--accent);height:28px}
.track{font-weight:600;font-size:18px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.artist{color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.progress{height:4px;background:var(--line);border-radius:2px;margin:14px 0 4px;overflow:hidden}
.progress div{height:100%;background:var(--accent);width:0}
.controls{display:flex;justify-content:center;gap:20px;margin-top:10px}
.controls button{width:56px;height:56px;border-radius:50%;border:1px solid var(--line);background:var(--bg);color:var(--text);font-size:20px;cursor:pointer}
.controls button.main{width:64px;height:64px;background:var(--accent);border-color:var(--accent);color:#fff}
button:disabled,.switch:disabled{opacity:.4}
.btn{border:1px solid var(--line);background:var(--bg);color:var(--text);border-radius:10px;padding:10px 14px;font:inherit;font-weight:600;cursor:pointer;flex:none}
.note{margin-top:10px}
#err{background:#b3261e;color:#fff;border-radius:12px;padding:10px 14px;margin-bottom:12px}
</style>
</head>
<body>
<main>
<div id="err" hidden>Gateway non raggiungibile</div>
<header>
<div><div class="time" id="time">--:--</div><div class="date" id="date"></div></div>
<div class="wx"><b id="temp"></b><div class="muted" id="desc"></div></div>
</header>

<h2>Luci</h2>
<div class="card" id="lights"></div>

<h2>Spotify</h2>
<div class="card">
<div class="track" id="track">—</div>
<div class="artist" id="artist"></div>
<div class="progress"><div id="bar"></div></div>
<div class="row muted"><span id="pos"></span><span id="dur"></span></div>
<div class="controls">
<button data-a="prev" aria-label="Brano precedente">&#9198;</button>
<button data-a="toggle" class="main" id="play" aria-label="Play/pausa">&#9654;</button>
<button data-a="next" aria-label="Brano successivo">&#9197;</button>
</div>
</div>

<h2>Kindle</h2>
<div class="card">
<div class="row">
<div><div id="kver">Versione: —</div><div class="muted" id="klatest"></div></div>
<button class="btn" id="ota">Aggiorna</button>
</div>
<div class="muted note" id="otamsg" hidden></div>
</div>
</main>
<script>
const $ = id => document.getElementById(id);
const touched = {};  // light -> last local change, so polling doesn't overwrite it
let rows = [];

const mmss = s => Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");

async function get(path) {
  const r = await fetch(path, {cache: "no-store"});
  if (!r.ok) throw new Error(r.status);
  return r;
}

function setLight(i, on, b) {
  touched[i] = Date.now();
  get(`/api/light?i=${i}&on=${on ? 1 : 0}&b=${b}`).catch(() => {}).finally(() => setTimeout(refresh, 300));
}

function buildLights(lights) {
  const box = $("lights");
  box.textContent = "";
  rows = lights.map((l, i) => {
    const el = document.createElement("div");
    el.className = "light";
    el.innerHTML = '<div class="row"><span class="name"></span><span class="pct"></span>' +
      '<button class="switch" role="switch"></button></div><input type="range" min="1" max="100" step="1">';
    el.querySelector(".name").textContent = l.name;
    const sw = el.querySelector(".switch"), range = el.querySelector("input"), pct = el.querySelector(".pct");
    sw.setAttribute("aria-label", l.name);
    sw.onclick = () => {
      const on = sw.getAttribute("aria-checked") !== "true";
      sw.setAttribute("aria-checked", on);
      pct.textContent = on ? range.value + "%" : "spenta";
      setLight(i, on, range.value);
    };
    range.oninput = () => { touched[i] = Date.now(); pct.textContent = range.value + "%"; sw.setAttribute("aria-checked", true); };
    range.onchange = () => setLight(i, true, range.value);
    box.appendChild(el);
    return {sw, range, pct};
  });
}

function render(s) {
  $("time").textContent = s.time;
  $("date").textContent = s.date;
  $("temp").textContent = s.w.ok ? s.w.temp + "°" : "";
  $("desc").textContent = s.w.ok ? s.w.desc : "";

  if (rows.length !== s.lights.length) buildLights(s.lights);
  s.lights.forEach((l, i) => {
    const r = rows[i];
    const ok = l.ok !== false;
    r.sw.disabled = r.range.disabled = !ok;
    if (!ok) { r.pct.textContent = "non raggiungibile"; return; }
    if (Date.now() - (touched[i] || 0) < 3000) return;
    r.sw.setAttribute("aria-checked", l.on);
    r.range.value = l.b;
    r.pct.textContent = l.on ? l.b + "%" : "spenta";
  });

  const sp = s.sp;
  $("track").textContent = !sp.ok ? "Spotify non raggiungibile" : sp.active ? sp.track : "Niente in riproduzione";
  $("artist").textContent = sp.active ? sp.artist : "";
  $("bar").style.width = sp.active && sp.duration ? (100 * sp.progress / sp.duration) + "%" : "0";
  $("pos").textContent = sp.active ? mmss(sp.progress) : "";
  $("dur").textContent = sp.active ? mmss(sp.duration) : "";
  $("play").innerHTML = sp.playing ? "&#9208;" : "&#9654;";
  document.querySelectorAll(".controls button").forEach(b => b.disabled = !sp.ok);

  const ota = s.ota;
  $("kver").textContent = "Versione: " + (ota.kindle || "sconosciuta");
  $("klatest").textContent = !ota.configured ? "Aggiornamenti non configurati sull'Arduino"
    : !ota.latest ? "" : ota.latest === ota.kindle ? "Aggiornato" : "Disponibile: " + ota.latest;
  $("ota").disabled = !ota.configured;
}

async function refresh() {
  try {
    render(await (await get("/api/state")).json());
    $("err").hidden = true;
  } catch (e) {
    $("err").hidden = false;
  }
}

document.querySelectorAll(".controls button").forEach(b => b.onclick = () => {
  get("/api/cmd?a=" + b.dataset.a).catch(() => {}).finally(() => setTimeout(refresh, 800));
});
$("ota").onclick = () => get("/api/ota").then(() => {
  $("otamsg").textContent = "Richiesta inviata: il Kindle controlla tra pochi secondi e, se c'è una versione nuova, si aggiorna e riparte.";
  $("otamsg").hidden = false;
}).catch(() => {});
setInterval(() => document.visibilityState === "visible" && refresh(), 3000);
document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && refresh());
refresh();
</script>
</body>
</html>
)html";
