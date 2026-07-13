#!/bin/bash
# 上海服务器部署：下载豆包版 index.html + 补齐 78 张塔罗图
# 用法： COMMIT=<commit> bash sh-deploy.sh   （不传则用 main）
COMMIT="${COMMIT:-main}"
ROOT=/www/wwwroot/wheel
MIRRORS=(
  "https://gcore.jsdelivr.net/gh/HaoCheng0126/Haoyunlai_web@$COMMIT"
  "https://testingcf.jsdelivr.net/gh/HaoCheng0126/Haoyunlai_web@$COMMIT"
  "https://fastly.jsdelivr.net/gh/HaoCheng0126/Haoyunlai_web@$COMMIT"
  "https://raw.gitmirror.com/HaoCheng0126/Haoyunlai_web/$COMMIT"
)
fetch(){ for b in "${MIRRORS[@]}"; do curl -fsSL --max-time 25 "$b/$1" -o "$2.tmp" 2>/dev/null && [ -s "$2.tmp" ] && { mv "$2.tmp" "$2"; return 0; }; done; rm -f "$2.tmp"; return 1; }
mkdir -p "$ROOT/cards"; cd "$ROOT" || exit 1
echo "== 1) index.html（$COMMIT）=="
fetch index.html index.html && echo "  index.html OK" || echo "  index.html FAIL（多跑一遍或发我）"
names=$(python3 -c "import re;s=open('index.html').read();m=re.search(r'TAROT_IMG\s*=\s*\[(.*?)\]',s,re.S);print(' '.join(re.findall(r'\"([a-z]+)\"',m.group(1))) if m else '')")
total=$(echo $names | wc -w)
echo "== 2) 补齐塔罗图（应 $total 张，已有的跳过）=="
fail=""
for n in $names; do
  [ -s "cards/$n.jpg" ] && continue
  fetch "cards/$n.jpg" "cards/$n.jpg" && echo "  +$n" || fail="$fail $n"
done
have=$(ls cards/*.jpg 2>/dev/null | wc -l)
echo "== cards/ 现有 $have / $total 张 =="
[ -n "$fail" ] && echo "!! 未下到:$fail （再跑一遍会自动补）" || echo "OK 全部就位"
