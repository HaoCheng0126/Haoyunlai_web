#!/usr/bin/env python3
# 好运来 · 配置中心后端（纯标准库）+ AI Key 管理（只写不读）
# GET  /config -> 已存配置 + keys:{deepseek:bool,doubao:bool}（永不返回 key 明文）
# POST /config  body {"config":{...,"keys":{"deepseek":"sk-..","doubao":"ark-.."}},"pw":".."}
#   校验密码 -> 清洗普通配置存盘（keys 不入库）-> 合法 key 写入 nginx 片段 + reload
import json, os, re, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STORE = "/www/haoyunlai-config.json"
PORT = 8787
PW = os.environ.get("MOODPICS_PW", "")
MAX_BODY = 4 * 1024 * 1024

# key 写进 nginx 的 include 片段（location 内 include，nginx 用它设 Authorization 头）
KEY_CONF = {
    "deepseek": {"path": "/etc/nginx/ai-deepseek.conf", "prefix": "sk-"},
    "doubao":   {"path": "/etc/nginx/ai-doubao.conf",   "prefix": "ark-"},
}
KEY_RE = re.compile(r"^[A-Za-z0-9._-]{10,256}$")   # 严格字符集：杜绝 " ; 换行等注入 nginx 指令

def clip(s, n):
    return s[:n] if isinstance(s, str) else ""

def sanitize(cfg):
    if not isinstance(cfg, dict):
        return {}
    out = {}
    moods = []
    for m in (cfg.get("moods") or [])[:30]:
        if isinstance(m, dict) and isinstance(m.get("id"), str):
            moods.append({"id": clip(m["id"], 40), "label": clip(m.get("label", ""), 16)})
    out["moods"] = moods
    pics = {}
    for k, v in list((cfg.get("pics") or {}).items())[:30]:
        if isinstance(k, str) and isinstance(v, str) and v.startswith("data:image/") and len(v) < 400000:
            pics[clip(k, 40)] = v
    out["pics"] = pics
    a = cfg.get("agent") if isinstance(cfg.get("agent"), dict) else {}
    agent = {
        "workStart": clip(a.get("workStart", ""), 5),
        "workEnd": clip(a.get("workEnd", ""), 5),
        "weatherCity": clip(a.get("weatherCity", ""), 20),
        "activePet": clip(a.get("activePet", ""), 40),
    }
    pets = {}
    for pid, p in list((a.get("pets") or {}).items())[:10]:
        if isinstance(pid, str) and isinstance(p, dict):
            pets[clip(pid, 40)] = {
                "name": clip(p.get("name", ""), 20),
                "char": clip(p.get("char", ""), 1200),
                "hello": clip(p.get("hello", ""), 120),
                "kicker": clip(p.get("kicker", ""), 40),
            }
    agent["pets"] = pets
    out["agent"] = agent
    return out
    # 注意：keys 不在白名单 -> 永远不会写进 STORE，GET 也就永远不吐明文

def has_key(which):
    try:
        with open(KEY_CONF[which]["path"], encoding="utf-8") as f:
            return "Bearer " in f.read()
    except Exception:
        return False

def key_state():
    return {"deepseek": has_key("deepseek"), "doubao": has_key("doubao")}

def reload_nginx():
    for cmd in (["/www/server/nginx/sbin/nginx", "-s", "reload"],
                ["nginx", "-s", "reload"],
                ["systemctl", "reload", "nginx"]):
        try:
            if subprocess.run(cmd, capture_output=True, timeout=15).returncode == 0:
                return True
        except Exception:
            continue
    return False

def set_key(which, key):
    c = KEY_CONF.get(which)
    if not c:
        return False
    key = (key or "").strip()
    if not key.startswith(c["prefix"]) or not KEY_RE.match(key):
        return False   # 前缀/字符集不对 -> 拒绝（防注入）
    try:
        with open(c["path"], "w", encoding="utf-8") as f:
            f.write('proxy_set_header Authorization "Bearer %s";\n' % key)
        os.chmod(c["path"], 0o600)
    except Exception:
        return False
    return True

class H(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        try:
            with open(STORE, encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            data = {}
        if not isinstance(data, dict):
            data = {}
        data["keys"] = key_state()          # 只回"设没设"，永不回明文
        self._json(200, data)

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
        except Exception:
            n = 0
        if n <= 0 or n > MAX_BODY:
            return self._json(413, {"error": "too_large"})
        try:
            body = json.loads(self.rfile.read(n))
        except Exception:
            return self._json(400, {"error": "bad_json"})
        if not PW or body.get("pw") != PW:
            return self._json(403, {"error": "forbidden"})
        raw = body.get("config") if isinstance(body.get("config"), dict) else {}
        # 1) 处理 key（合法才写；只要有任一成功就 reload）
        keys_in = raw.get("keys") if isinstance(raw.get("keys"), dict) else {}
        changed = False
        for which in ("deepseek", "doubao"):
            v = keys_in.get(which)
            if isinstance(v, str) and v.strip():
                if set_key(which, v):
                    changed = True
        if changed:
            reload_nginx()
        # 2) 普通配置清洗存盘（keys 已被 sanitize 白名单挡在外面）
        cfg = sanitize(raw)
        try:
            with open(STORE, "w", encoding="utf-8") as f:
                json.dump(cfg, f, ensure_ascii=False)
        except Exception:
            return self._json(500, {"error": "write_fail"})
        self._json(200, {"ok": True, "moods": len(cfg["moods"]), "pics": len(cfg["pics"]),
                         "pets": len(cfg["agent"]["pets"]), "keys": key_state()})

    def log_message(self, *a):
        pass

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
