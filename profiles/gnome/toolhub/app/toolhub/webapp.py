from __future__ import annotations

import json
import secrets
import threading
import urllib.parse
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .service import ToolHubService


HTML = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Spectre ToolHub</title>
<style>
:root{color-scheme:dark;--bg:#0b0f14;--panel:#111822;--panel2:#151f2b;--line:#263445;--text:#eaf2ff;--muted:#93a4b8;--accent:#5bc0ff;--good:#55d187;--warn:#ffcc66;--bad:#ff6b72}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at top right,#132438 0,#0b0f14 40%);color:var(--text);font:14px/1.45 Inter,system-ui,-apple-system,Segoe UI,sans-serif;min-height:100vh}
header{position:sticky;top:0;z-index:4;display:flex;align-items:center;gap:18px;padding:18px 24px;background:rgba(11,15,20,.88);backdrop-filter:blur(16px);border-bottom:1px solid var(--line)}
.brand{font-size:20px;font-weight:800;letter-spacing:.2px}.brand small{display:block;font-size:11px;color:var(--muted);font-weight:500}.status{margin-left:auto;display:flex;gap:8px;align-items:center}.pill{padding:6px 10px;border:1px solid var(--line);border-radius:999px;color:var(--muted);background:#0e151d}.pill.good{color:#bff5d2;border-color:#2a6541}.pill.warn{color:#ffe0a3;border-color:#6c5727}
main{display:grid;grid-template-columns:230px 1fr;gap:20px;max-width:1500px;margin:auto;padding:24px}.side{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:16px;height:fit-content;position:sticky;top:92px}.side h3{margin:0 0 12px}.side button{display:block;width:100%;text-align:left;background:none;border:0;color:var(--muted);padding:9px 10px;border-radius:9px;cursor:pointer}.side button:hover,.side button.active{background:var(--panel2);color:var(--text)}
.toolbar{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:16px}.toolbar input{flex:1;min-width:250px;padding:12px 14px;border-radius:11px;border:1px solid var(--line);background:#0d141d;color:var(--text);outline:none}.btn{border:1px solid #2b5d78;background:#15334a;color:#dff4ff;padding:10px 13px;border-radius:10px;cursor:pointer;font-weight:650}.btn.secondary{background:#141d28;border-color:var(--line);color:var(--text)}.btn.danger{background:#3b1b20;border-color:#6d3039;color:#ffd9dc}.btn:disabled{opacity:.45;cursor:not-allowed}
.banner{padding:13px 15px;border:1px solid #574d25;background:#2a2512;color:#ffe8a8;border-radius:12px;margin-bottom:16px}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(285px,1fr));gap:14px}.card{background:linear-gradient(180deg,#121b26,#0f161f);border:1px solid var(--line);border-radius:15px;padding:16px;min-height:210px;display:flex;flex-direction:column;box-shadow:0 12px 28px rgba(0,0,0,.16)}.card h3{margin:7px 0 4px;font-size:17px}.pkg{font:12px ui-monospace,SFMono-Regular,Consolas,monospace;color:var(--accent);word-break:break-word}.desc{color:var(--muted);margin:8px 0}.meta{display:flex;gap:7px;flex-wrap:wrap;margin-top:auto;padding-top:14px}.tag{padding:4px 7px;border-radius:7px;background:#182432;border:1px solid #25374a;color:#a8bed6;font-size:11px}.warning{font-size:12px;color:#ffd27a;margin-top:8px}.actions{display:flex;gap:8px;margin-top:12px}.actions .btn{flex:1}.installed{border-color:#28593d}.installed::before{content:'Installed';float:right;color:var(--good);font-size:11px;font-weight:700}
#log{margin-top:18px;background:#070a0e;border:1px solid var(--line);border-radius:12px;padding:12px;height:180px;overflow:auto;white-space:pre-wrap;font:12px ui-monospace,SFMono-Regular,Consolas,monospace;color:#b8c8d8}.search-results{margin:12px 0 18px;border:1px solid var(--line);background:var(--panel);border-radius:12px;padding:10px;display:none}.search-row{display:grid;grid-template-columns:180px 1fr auto;gap:10px;align-items:center;padding:8px;border-bottom:1px solid #1f2b39}.search-row:last-child{border-bottom:0}
@media(max-width:800px){main{grid-template-columns:1fr}.side{position:static}.side .cats{display:flex;overflow:auto}.side button{width:auto;white-space:nowrap}.status{display:none}}
</style>
</head>
<body>
<header><div class="brand">Spectre ToolHub<small>Isolated Kali tool store for Debian/Ubuntu-family desktops</small></div><div class="status"><span id="runtime" class="pill">runtime</span><span id="container" class="pill warn">toolbox stopped</span><span class="pill good">Safe container mode</span></div></header>
<main>
<aside class="side"><h3>Categories</h3><div id="categories" class="cats"></div></aside>
<section>
<div class="banner"><b>Authorized-use tool store.</b> Kali packages are installed inside an isolated Kali container. ToolHub never adds the Kali Rolling repository to your Zorin/Spectre host.</div>
<div class="toolbar"><input id="search" placeholder="Filter groups or search Kali packages…"><button class="btn" onclick="searchPackages()">Search Kali</button><button class="btn secondary" onclick="initToolbox()">Initialize Toolbox</button><button class="btn secondary" onclick="openShell()">Open Kali Shell</button></div>
<div id="searchResults" class="search-results"></div>
<div id="grid" class="grid"></div>
<pre id="log">Ready.</pre>
</section></main>
<script>
let catalog=[],activeCategory='All'; const csrf='__CSRF__';
const log=(m)=>{const e=document.getElementById('log'); e.textContent+='\n'+m; e.scrollTop=e.scrollHeight};
async function api(path,opt={}){opt.headers={...(opt.headers||{}),'X-ToolHub-Token':csrf}; if(opt.body){opt.headers['Content-Type']='application/json'} const r=await fetch(path,opt); const t=await r.text(); let d; try{d=JSON.parse(t)}catch{d={error:t}} if(!r.ok) throw new Error(d.error||('HTTP '+r.status)); return d}
async function load(){const s=await api('/api/status');document.getElementById('runtime').textContent='Runtime: '+s.runtime;const c=document.getElementById('container');c.textContent=s.running?'Toolbox running':'Toolbox stopped';c.className='pill '+(s.running?'good':'warn');const d=await api('/api/catalog');catalog=d.groups;renderCats(d.categories);render()}
function renderCats(c){const root=document.getElementById('categories');root.innerHTML='';['All',...c].forEach(x=>{const b=document.createElement('button');b.textContent=x;b.className=x===activeCategory?'active':'';b.onclick=()=>{activeCategory=x;renderCats(c);render()};root.appendChild(b)})}
function render(){const q=document.getElementById('search').value.toLowerCase().trim();const root=document.getElementById('grid');root.innerHTML='';catalog.filter(x=>(activeCategory==='All'||x.category===activeCategory)&&(!q||(x.package+' '+x.title+' '+x.description).toLowerCase().includes(q))).forEach(x=>{const d=document.createElement('div');d.className='card '+(x.installed?'installed':'');d.innerHTML=`<div class="pkg">${esc(x.package)}</div><h3>${esc(x.title)}</h3><div class="desc">${esc(x.description)}</div>${x.warning?`<div class="warning">⚠ ${esc(x.warning)}</div>`:''}<div class="meta"><span class="tag">${esc(x.category)}</span><span class="tag">${esc(x.weight)}</span></div><div class="actions"><button class="btn" onclick="installPkg('${esc(x.package)}')">Install</button><button class="btn danger" onclick="removePkg('${esc(x.package)}')">Remove meta</button></div>`;root.appendChild(d)})}
function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
document.getElementById('search').addEventListener('input',render);
async function initToolbox(){log('Initializing Kali toolbox…');try{const d=await api('/api/init',{method:'POST',body:'{}'});log('Toolbox ready: '+JSON.stringify(d));await load()}catch(e){log('ERROR: '+e.message)}}
async function installPkg(p){if(!confirm('Install '+p+' inside the Kali toolbox?'))return;log('Installing '+p+'…');try{const d=await api('/api/install',{method:'POST',body:JSON.stringify({package:p})});log(d.output||'Installed.');await load()}catch(e){log('ERROR: '+e.message)}}
async function removePkg(p){if(!confirm('Remove metapackage '+p+' from the Kali toolbox? Dependencies shared with other groups are not forcibly removed.'))return;log('Removing '+p+'…');try{const d=await api('/api/remove',{method:'POST',body:JSON.stringify({package:p})});log(d.output||'Removed.');await load()}catch(e){log('ERROR: '+e.message)}}
async function searchPackages(){const q=document.getElementById('search').value.trim();if(!q){render();return}log('Searching Kali package index for '+q+'…');try{const d=await api('/api/search?q='+encodeURIComponent(q));const root=document.getElementById('searchResults');root.style.display='block';root.innerHTML='<b>Kali package search</b>';d.results.forEach(x=>{const row=document.createElement('div');row.className='search-row';row.innerHTML=`<span class="pkg">${esc(x.package)}</span><span>${esc(x.description)}</span><button class="btn" onclick="installPkg('${esc(x.package)}')">Install</button>`;root.appendChild(row)});if(!d.results.length)root.innerHTML+='<div class="desc">No matching packages.</div>'}catch(e){log('ERROR: '+e.message)}}
async function openShell(){try{const d=await api('/api/open-shell',{method:'POST',body:'{}'});log(d.opened?'Opened Kali shell.':'Shell command: '+d.command+(d.error?' — '+d.error:''))}catch(e){log('ERROR: '+e.message)}}
load().catch(e=>log('ERROR: '+e.message));
</script></body></html>'''


class ToolHubServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, handler_cls, service: ToolHubService, csrf: str):
        super().__init__(address, handler_cls)
        self.service = service
        self.csrf = csrf


class Handler(BaseHTTPRequestHandler):
    server: ToolHubServer

    def log_message(self, fmt: str, *args) -> None:
        return

    def _headers(self, status=200, content_type="application/json; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:")
        self.end_headers()

    def _json(self, payload, status=200):
        data = json.dumps(payload).encode()
        self._headers(status)
        self.wfile.write(data)

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        if length > 16384:
            raise ValueError("request too large")
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode() or "{}")

    def _authorized_post(self) -> bool:
        return secrets.compare_digest(self.headers.get("X-ToolHub-Token", ""), self.server.csrf)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/":
            page = HTML.replace("__CSRF__", self.server.csrf).encode()
            self._headers(200, "text/html; charset=utf-8")
            self.wfile.write(page)
            return
        try:
            if parsed.path == "/api/status":
                return self._json(self.server.service.status())
            if parsed.path == "/api/catalog":
                return self._json(self.server.service.catalog())
            if parsed.path == "/api/installed":
                return self._json(self.server.service.installed())
            if parsed.path == "/api/search":
                q = urllib.parse.parse_qs(parsed.query).get("q", [""])[0]
                return self._json(self.server.service.search(q))
            self._json({"error": "not found"}, 404)
        except Exception as exc:
            self._json({"error": str(exc)}, 400)

    def do_POST(self):
        if not self._authorized_post():
            return self._json({"error": "invalid local session token"}, 403)
        parsed = urllib.parse.urlparse(self.path)
        try:
            body = self._body()
            if parsed.path == "/api/init":
                return self._json(self.server.service.init())
            if parsed.path == "/api/install":
                return self._json(self.server.service.install(body.get("package", "")))
            if parsed.path == "/api/remove":
                return self._json(self.server.service.remove(body.get("package", "")))
            if parsed.path == "/api/open-shell":
                return self._json(self.server.service.open_shell())
            self._json({"error": "not found"}, 404)
        except Exception as exc:
            self._json({"error": str(exc)}, 400)


def serve(service: ToolHubService, host: str = "127.0.0.1", port: int = 8787, open_browser: bool = True):
    csrf = secrets.token_urlsafe(24)
    server = ToolHubServer((host, port), Handler, service, csrf)
    url = f"http://{host}:{server.server_address[1]}/"
    print(f"Spectre ToolHub: {url}")
    print("Press Ctrl+C to stop.")
    if open_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
