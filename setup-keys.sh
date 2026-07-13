#!/bin/bash
# 上海：给配置后端加 AI Key 管理 —— 提取现有 key 写成 nginx 片段、把 Authorization 改成 include、
#       装新后端、换配置密码、nginx 测试+热加载、重启后端。带备份，nginx -t 失败自动回滚。
# 用法： bash setup-keys.sh <新配置密码>   （新后端已随仓库 clone 到 /tmp/hyl/config-server.py）
NEWPW="${1:-}"
if [ -z "$NEWPW" ]; then echo "❌ 用法: bash setup-keys.sh <新密码>"; exit 1; fi
SRC=/tmp/hyl/config-server.py
if [ ! -f "$SRC" ]; then echo "❌ 没找到 $SRC（先把仓库 clone 到 /tmp/hyl）"; exit 1; fi

CONF=$(grep -rl 'location = /tarot-ai' /www/server/panel/vhost/nginx/ /etc/nginx/ 2>/dev/null | head -1)
if [ -z "$CONF" ]; then echo "❌ 没找到含 /tarot-ai 的 nginx 配置"; exit 1; fi
echo "站点配置: $CONF"
BAK="$CONF.bak.keys.$(date +%s)"; cp "$CONF" "$BAK"

# 提取现有两把 key
DS=$(grep -oE 'Bearer sk-[A-Za-z0-9._-]+' "$CONF" | head -1 | sed 's/Bearer //')
DB=$(grep -oE 'Bearer ark-[A-Za-z0-9._-]+' "$CONF" | head -1 | sed 's/Bearer //')
echo "提取现有 key: DeepSeek=${DS:+有} 豆包=${DB:+有}"

# 先把 key 写成 nginx 片段（include 目标必须先存在，否则 nginx -t 失败）
if [ -n "$DS" ]; then printf 'proxy_set_header Authorization "Bearer %s";\n' "$DS" > /etc/nginx/ai-deepseek.conf; chmod 600 /etc/nginx/ai-deepseek.conf; fi
if [ -n "$DB" ]; then printf 'proxy_set_header Authorization "Bearer %s";\n' "$DB" > /etc/nginx/ai-doubao.conf; chmod 600 /etc/nginx/ai-doubao.conf; fi

# 把两处 Authorization 行改成 include（按 key 前缀区分：sk-=deepseek, ark-=doubao）
python3 - "$CONF" <<'PYEOF'
import sys, re
f = sys.argv[1]; s = open(f, encoding="utf-8").read()
s = re.sub(r'proxy_set_header\s+Authorization\s+"Bearer\s+sk-[^"]*"\s*;', 'include /etc/nginx/ai-deepseek.conf;', s)
s = re.sub(r'proxy_set_header\s+Authorization\s+"Bearer\s+ark-[^"]*"\s*;', 'include /etc/nginx/ai-doubao.conf;', s)
open(f, "w", encoding="utf-8").write(s)
print("Authorization 行已改为 include")
PYEOF

# 装新后端
cp "$SRC" /www/config-server.py

# 换配置密码（改 systemd 单元的 MOODPICS_PW）
UNIT=$(grep -rl 'config-server.py' /etc/systemd/system/ 2>/dev/null | head -1)
if [ -n "$UNIT" ]; then
  if grep -q 'MOODPICS_PW=' "$UNIT"; then sed -i "s|MOODPICS_PW=.*|MOODPICS_PW=$NEWPW|" "$UNIT"
  else sed -i "/^\[Service\]/a Environment=MOODPICS_PW=$NEWPW" "$UNIT"; fi
  echo "systemd 单元: $UNIT（密码已更新）"
else echo "⚠️ 没找到 config-server 的 systemd 单元，密码未改（手动改）"; fi

# nginx 测试 + 热加载；后端重启
NGINX=$(command -v nginx || echo /www/server/nginx/sbin/nginx)
if "$NGINX" -t; then
  "$NGINX" -s reload && echo "✅ nginx 已重载"
  systemctl daemon-reload
  if [ -n "$UNIT" ]; then systemctl restart "$(basename "$UNIT")" && echo "✅ 配置后端已重启"; fi
  echo "== ✅ 全部完成（DeepSeek/豆包 key 已迁移到片段，配置中心可管理）=="
else
  echo "❌ nginx -t 失败，已自动还原站点配置"; cp "$BAK" "$CONF"
  echo "把上面 nginx -t 的报错发我"
fi
