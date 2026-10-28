#!/bin/bash
# ==============================================================================
# 3X-UI + Nginx / Caddy 端口分流与订阅重写自动化脚本 (全环境智能自适应版)
# 支持自定义对外映射端口 (443 / 8443 / 2053 / 2083 / 2087 / 2096 等任意端口)
# 特性：
# 1. 双引擎自适应：自动检测并适配 Nginx 或 Caddy，多服务器通用无缝运行
# 2. 物理端口前置侦测：若 443 被 Apache、Docker 等异构服务独占，提供换端口或停用服务引导
# 3. 智能默认路径：同一端口已被占用时，按回车自动顺延分配可用路径 (如 /vless-ws2)
# 4. 深度冲突拦截：防止误覆盖导致已有节点断连 (同时检测 3X-UI、Nginx、Caddy)
# 5. 订阅双重重写：Hosts 表 + externalProxy 双重生效，API/面板/订阅均输出自定义端口
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

echo -e "${CYAN}====================================================${PLAIN}"
echo -e "${CYAN}   3X-UI 自定义端口分流 & 订阅重写自动化脚本 (Nginx/Caddy)   ${PLAIN}"
echo -e "${CYAN}====================================================${PLAIN}"

# 1. 检查权限与依赖
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[错误] 请以 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

which python3 >/dev/null 2>&1 || { echo -e "${RED}[错误] 未检测到 Python3，请先安装 Python3！${PLAIN}"; exit 1; }

# 自动探测活跃的 Web 服务器 (Caddy 或 Nginx)
WEB_SERVER=""
if systemctl is-active --quiet caddy 2>/dev/null || (which caddy >/dev/null 2>&1 && [ -f /etc/caddy/Caddyfile ]); then
    if ss -tlpn 2>/dev/null | grep -E ':(80|443)\b' | grep -q 'caddy' || systemctl is-active --quiet caddy 2>/dev/null; then
        WEB_SERVER="caddy"
    fi
fi

if [ -z "$WEB_SERVER" ]; then
    if systemctl is-active --quiet nginx 2>/dev/null || (which nginx >/dev/null 2>&1 && [ -d /etc/nginx ]); then
        WEB_SERVER="nginx"
    elif which caddy >/dev/null 2>&1; then
        WEB_SERVER="caddy"
    else
        echo -e "${RED}[错误] 未检测到活跃的 Nginx 或 Caddy！请先安装 Nginx 或 Caddy 后再运行。${PLAIN}"
        exit 1
    fi
fi

echo -e "${GREEN}[环境识别] 检测到当前服务器 Web 服务为: ${CYAN}${WEB_SERVER^^}${PLAIN}"

XUI_DB="/etc/x-ui/x-ui.db"
if [ ! -f "$XUI_DB" ]; then
    echo -e "${RED}[错误] 未找到 3X-UI 数据库: $XUI_DB，请确认已安装 3X-UI！${PLAIN}"
    exit 1
fi

# 2. 交互式输入基础参数
echo -e "\n${YELLOW}--- [参数输入] ---${PLAIN}"

read -p "1. 节点绑定的域名 (例如 node.example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}[错误] 域名不能为空！${PLAIN}"
    exit 1
fi

read -p "2. 3X-UI 入站端口 (例如 60231): " XUI_PORT
if [ -z "$XUI_PORT" ]; then
    echo -e "${RED}[错误] 3X-UI 入站端口不能为空！${PLAIN}"
    exit 1
fi

# 确认该入站是否存在
INBOUND_EXISTS=$(python3 -c "
import sqlite3
conn = sqlite3.connect('$XUI_DB')
c = conn.cursor()
c.execute('SELECT id FROM inbounds WHERE port = ?', ($XUI_PORT,))
print('1' if c.fetchone() else '0')
conn.close()
")

if [ "$INBOUND_EXISTS" != "1" ]; then
    echo -e "${RED}[错误] 3X-UI 数据库中未找到监听端口为 ${XUI_PORT} 的入站，请先去 3X-UI 面板创建该入站！${PLAIN}"
    exit 1
fi

read -p "3. 对外自定义映射端口 [默认: 443]: " EXTERNAL_PORT
EXTERNAL_PORT=${EXTERNAL_PORT:-443}

# 2.5 端口物理占用前置检测 (检查 443/指定对外端口 是否被非 Nginx/Caddy 的异构服务如 Apache/Docker 占用)
while true; do
    PORT_CHECK_RESULT=$(python3 - << PYEOF
import subprocess, re, os, json

port = int("$EXTERNAL_PORT")
web_server = "$WEB_SERVER"

def check_p(p):
    cmd = ["ss", "-tlpn", f"sport = :{p}"]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    lines = res.stdout.strip().splitlines()
    if len(lines) <= 1:
        return []
    occupiers = []
    seen = set()
    for line in lines[1:]:
        m = re.findall(r'"([^"]+)",pid=(\d+)', line)
        for proc_name, pid_str in m:
            pid = int(pid_str)
            if pid not in seen:
                seen.add(pid)
                svc = ""
                try:
                    with open(f"/proc/{pid}/cgroup") as f:
                        for cl in f:
                            if ".service" in cl:
                                svc = cl.strip().split("/")[-1]
                                break
                except:
                    pass
                occupiers.append({"name": proc_name, "pid": pid, "service": svc, "port": p})
    return occupiers

ports_to_check = [port]
if port == 443 and web_server == "nginx":
    ports_to_check.append(80)

all_foreign = []
for p in ports_to_check:
    occ = check_p(p)
    foreign = [o for o in occ if web_server not in o["name"].lower()]
    all_foreign.extend(foreign)

if all_foreign:
    print(json.dumps({"status": "CONFLICT", "foreign": all_foreign}))
else:
    print(json.dumps({"status": "OK"}))
PYEOF
    )

    STATUS=$(python3 -c "import json; print(json.loads('''$PORT_CHECK_RESULT''')['status'])")
    if [ "$STATUS" = "CONFLICT" ]; then
        CONF_PORT=$(python3 -c "import json; print(json.loads('''$PORT_CHECK_RESULT''')['foreign'][0]['port'])")
        PROC_NAME=$(python3 -c "import json; print(json.loads('''$PORT_CHECK_RESULT''')['foreign'][0]['name'])")
        PROC_PID=$(python3 -c "import json; print(json.loads('''$PORT_CHECK_RESULT''')['foreign'][0]['pid'])")
        PROC_SVC=$(python3 -c "import json; print(json.loads('''$PORT_CHECK_RESULT''')['foreign'][0].get('service') or '')")

        echo -e "\n${RED}====================================================${PLAIN}"
        echo -e "${RED}             [ 端口占用冲突拦截警告 ]                 ${PLAIN}"
        echo -e "${RED}====================================================${PLAIN}"
        echo -e "冲突端口:   ${CYAN}${CONF_PORT}${PLAIN}"
        echo -e "占用进程:   ${RED}${PROC_NAME}${PLAIN} (PID: ${PROC_PID})"
        [ -n "$PROC_SVC" ] && echo -e "占用服务:   ${YELLOW}${PROC_SVC}${PLAIN}"
        echo -e "目标反代:   ${GREEN}${WEB_SERVER^^}${PLAIN}"
        echo -e "${RED}【风险说明】端口 ${CONF_PORT} 正被非 ${WEB_SERVER^^} 的其他服务独占！${PLAIN}"
        echo -e "${RED}如果不处理，后续 ${WEB_SERVER^^} 启动时必定报错崩溃 (Address already in use)。${PLAIN}"
        echo -e "${RED}====================================================${PLAIN}"

        echo -e "请选择处理方式："
        echo -e "  ${GREEN}1) 更换对外映射端口 (例如 8443, 2053, 2083, 2087, 2096 等, 推荐)${PLAIN}"
        if [ -n "$PROC_SVC" ]; then
            echo -e "  ${YELLOW}2) 自动停止并禁用占用服务 (${PROC_SVC})${PLAIN}"
        else
            echo -e "  ${YELLOW}2) 强制终止占用进程 (${PROC_NAME}, PID: ${PROC_PID})${PLAIN}"
        fi
        echo -e "  ${RED}3) 放弃并退出${PLAIN}"

        read -p "请输入选项 [默认 1]: " PORT_CHOICE
        PORT_CHOICE=${PORT_CHOICE:-1}

        case "$PORT_CHOICE" in
            1)
                read -p "请输入新的对外映射端口 [例如 8443]: " EXTERNAL_PORT
                EXTERNAL_PORT=${EXTERNAL_PORT:-8443}
                continue
                ;;
            2)
                if [ -n "$PROC_SVC" ]; then
                    echo -e "${YELLOW}正在停止并禁用服务 ${PROC_SVC}...${PLAIN}"
                    systemctl stop "$PROC_SVC" 2>/dev/null || true
                    systemctl disable "$PROC_SVC" 2>/dev/null || true
                fi
                kill -9 "$PROC_PID" 2>/dev/null || true
                sleep 1
                echo -e "${GREEN}[OK] 已停止占用服务，正在重新检测端口状态...${PLAIN}"
                continue
                ;;
            *)
                echo -e "${RED}[操作取消] 已安全退出，未做任何修改。${PLAIN}"
                exit 0
                ;;
        esac
    else
        break
    fi
done

# 3. 智能计算推荐路径（若 /vless-ws 已被占，自动递增为 /vless-ws2, /vless-ws3...）
SUGGESTED_PATH=$(python3 - << PYEOF
import sqlite3, json, os, re

domain = "$DOMAIN"
xui_port = int("$XUI_PORT")
ext_port = int("$EXTERNAL_PORT")
web_server = "$WEB_SERVER"

used_paths = set()

# 1. 扫描 3X-UI 数据库
db_path = "$XUI_DB"
if os.path.exists(db_path):
    conn = sqlite3.connect(db_path)
    c = conn.cursor()
    try:
        c.execute("SELECT inbound_id, path FROM hosts WHERE address = ? AND port = ?", (domain, ext_port))
        for r in c.fetchall():
            in_id, path = r[0], r[1]
            c.execute("SELECT port FROM inbounds WHERE id = ?", (in_id,))
            in_row = c.fetchone()
            if in_row and in_row[0] != xui_port and path:
                used_paths.add(path.strip())
    except Exception:
        pass

    try:
        c.execute("SELECT port, stream_settings FROM inbounds WHERE port != ?", (xui_port,))
        for r in c.fetchall():
            in_port, ss_raw = r[0], r[1]
            if not ss_raw: continue
            ss = json.loads(ss_raw)
            path = ss.get("wsSettings", {}).get("path", "")
            for ep in ss.get("externalProxy", []):
                if ep.get("dest") == domain and int(ep.get("port", 0)) == ext_port and path:
                    used_paths.add(path.strip())
    except Exception:
        pass
    conn.close()

# 2. 扫描 Web 服务器现有配置
if web_server == "caddy":
    caddy_file = "/etc/caddy/Caddyfile"
    if os.path.exists(caddy_file):
        try:
            with open(caddy_file) as fp:
                caddy_text = fp.read()
            if ext_port == 443:
                pat = re.compile(r"(?:^|\n)\s*(" + re.escape(domain) + r"(?::443)?)\s*\{")
            else:
                pat = re.compile(r"(?:^|\n)\s*(" + re.escape(domain) + r":" + str(ext_port) + r")\s*\{")
            m = pat.search(caddy_text)
            if m:
                start_brace = caddy_text.find("{", m.start())
                depth = 0
                end_brace = -1
                for i in range(start_brace, len(caddy_text)):
                    if caddy_text[i] == '{': depth += 1
                    elif caddy_text[i] == '}':
                        depth -= 1
                        if depth == 0:
                            end_brace = i
                            break
                if end_brace != -1:
                    body = caddy_text[start_brace:end_brace]
                    for hm in re.finditer(r"handle\s+([/\w-]+)\*?\s*\{[\s\S]*?reverse_proxy\s+(?:https?://)?127\.0\.0\.1:(\d+)", body):
                        p_path = hm.group(1).strip()
                        p_port = int(hm.group(2))
                        if p_port != xui_port:
                            used_paths.add(p_path)
        except Exception:
            pass
else:
    nginx_dir = "/etc/nginx"
    for root, dirs, files in os.walk(nginx_dir):
        for f in files:
            if not f.endswith(".conf") and "sites-available" not in root and "sites-enabled" not in root:
                continue
            if f.endswith(".bak") or "backup" in f: continue
            p = os.path.join(root, f)
            try:
                with open(p) as fp:
                    content = fp.read()
                if domain in content and str(ext_port) in content:
                    for m in re.finditer(r"location\s+([/\w-]+)[\s\S]*?proxy_pass\s+https?://127\.0\.0\.1:(\d+)", content):
                        p_path = m.group(1).strip()
                        p_port = int(m.group(2))
                        if p_port != xui_port:
                            used_paths.add(p_path)
            except Exception:
                pass

# 计算首个空闲路径
candidate = "/vless-ws"
if candidate in used_paths:
    idx = 2
    while f"/vless-ws{idx}" in used_paths:
        idx += 1
    candidate = f"/vless-ws{idx}"

print(candidate)
PYEOF
)

# 4. 路径输入与二次防冲突校验循环
while true; do
    read -p "4. WebSocket 分流路径 [默认: $SUGGESTED_PATH]: " WS_PATH
    WS_PATH=${WS_PATH:-$SUGGESTED_PATH}
    [[ "$WS_PATH" != /* ]] && WS_PATH="/$WS_PATH"

    # 执行底层冲突检测 (同时检查 3X-UI 数据库和 Web 服务器现有配置)
    CONFLICT_INFO=$(python3 - << PYEOF
import sqlite3, json, os, re, sys

domain = "$DOMAIN"
xui_port = int("$XUI_PORT")
ext_port = int("$EXTERNAL_PORT")
ws_path = "$WS_PATH"
web_server = "$WEB_SERVER"

conflict_port = None
conflict_source = ""

# 1. 检查 3X-UI 数据库中的映射与外部代理
db_path = "$XUI_DB"
if os.path.exists(db_path):
    conn = sqlite3.connect(db_path)
    c = conn.cursor()
    
    # 检查 hosts 表
    try:
        c.execute("SELECT inbound_id, address, port, path FROM hosts WHERE address = ? AND port = ? AND path = ?", (domain, ext_port, ws_path))
        for row in c.fetchall():
            inbound_id = row[0]
            c.execute("SELECT port FROM inbounds WHERE id = ?", (inbound_id,))
            in_row = c.fetchone()
            if in_row and in_row[0] != xui_port:
                conflict_port = in_row[0]
                conflict_source = f"3X-UI 主机映射表 (占用入站端口: {conflict_port})"
                break
    except Exception:
        pass

    # 检查 inbounds 表中的 externalProxy
    if not conflict_port:
        try:
            c.execute("SELECT id, port, stream_settings FROM inbounds WHERE port != ?", (xui_port,))
            for row in c.fetchall():
                in_port, ss_raw = row[1], row[2]
                if not ss_raw: continue
                ss = json.loads(ss_raw)
                path = ss.get("wsSettings", {}).get("path", "")
                for ep in ss.get("externalProxy", []):
                    if ep.get("dest") == domain and int(ep.get("port", 0)) == ext_port and path == ws_path:
                        conflict_port = in_port
                        conflict_source = f"3X-UI 外部代理配置 (占用入站端口: {conflict_port})"
                        break
                if conflict_port: break
        except Exception:
            pass
    conn.close()

# 2. 检查 Web 服务器配置
if not conflict_port:
    if web_server == "caddy":
        caddy_file = "/etc/caddy/Caddyfile"
        if os.path.exists(caddy_file):
            try:
                with open(caddy_file) as fp:
                    caddy_text = fp.read()
                if ext_port == 443:
                    pat = re.compile(r"(?:^|\n)\s*(" + re.escape(domain) + r"(?::443)?)\s*\{")
                else:
                    pat = re.compile(r"(?:^|\n)\s*(" + re.escape(domain) + r":" + str(ext_port) + r")\s*\{")
                m = pat.search(caddy_text)
                if m:
                    start_brace = caddy_text.find("{", m.start())
                    depth = 0
                    end_brace = -1
                    for i in range(start_brace, len(caddy_text)):
                        if caddy_text[i] == '{': depth += 1
                        elif caddy_text[i] == '}':
                            depth -= 1
                            if depth == 0:
                                end_brace = i
                                break
                    if end_brace != -1:
                        body = caddy_text[start_brace:end_brace]
                        for hm in re.finditer(r"handle\s+([/\w-]+)\*?\s*\{[\s\S]*?reverse_proxy\s+(?:https?://)?127\.0\.0\.1:(\d+)", body):
                            p_path = hm.group(1).strip()
                            p_port = int(hm.group(2))
                            if p_path == ws_path and p_port != xui_port:
                                conflict_port = p_port
                                conflict_source = f"Caddy 配置 ({caddy_file}, 已转发至端口: {conflict_port})"
                                break
            except Exception:
                pass
    else:
        nginx_dir = "/etc/nginx"
        for root, dirs, files in os.walk(nginx_dir):
            for f in files:
                if not f.endswith(".conf") and "sites-available" not in root and "sites-enabled" not in root:
                    continue
                if f.endswith(".bak") or "backup" in f: continue
                p = os.path.join(root, f)
                try:
                    with open(p) as fp:
                        content = fp.read()
                    if domain in content and str(ext_port) in content and ws_path in content:
                        m = re.search(r"location\s+" + re.escape(ws_path) + r"[\s\S]*?proxy_pass\s+https?://127\.0\.0\.1:(\d+)", content)
                        if m:
                            p_port = int(m.group(1))
                            if p_port != xui_port:
                                conflict_port = p_port
                                conflict_source = f"Nginx 配置 ({p}, 已转发至端口: {conflict_port})"
                                break
                except:
                    pass
            if conflict_port: break

if conflict_port:
    print(f"CONFLICT:{conflict_port}:{conflict_source}")
else:
    print("OK")
PYEOF
    )

    if [[ "$CONFLICT_INFO" == CONFLICT* ]]; then
        CONFLICT_PORT=$(echo "$CONFLICT_INFO" | cut -d':' -f2)
        CONFLICT_DESC=$(echo "$CONFLICT_INFO" | cut -d':' -f3-)

        echo -e "\n${RED}====================================================${PLAIN}"
        echo -e "${RED}             [ 严重冲突警告 / 拦截提醒 ]              ${PLAIN}"
        echo -e "${RED}====================================================${PLAIN}"
        echo -e "目标域名:   ${CYAN}${DOMAIN}${PLAIN}"
        echo -e "对外端口:   ${CYAN}${EXTERNAL_PORT}${PLAIN}"
        echo -e "冲突路径:   ${RED}${WS_PATH}${PLAIN}"
        echo -e "冲突源头:   ${YELLOW}${CONFLICT_DESC}${PLAIN}"
        echo -e "${RED}【风险说明】该域名 + 端口 + 路径已被端口为 ${CONFLICT_PORT} 的旧入站占用！${PLAIN}"
        echo -e "${RED}如果强行使用，旧入站的转发规则将被破坏，导致旧节点立即报 404 断连！${PLAIN}"
        echo -e "${RED}====================================================${PLAIN}"
        
        echo -e "请选择处理方式："
        echo -e "  ${GREEN}1) 更换一个新的分流路径 (推荐)${PLAIN}"
        echo -e "  ${YELLOW}2) 强行覆盖 (破坏旧入站的转发规则，强制绑定给新入站)${PLAIN}"
        echo -e "  ${RED}3) 放弃并退出${PLAIN}"
        read -p "请输入选项 [默认 1]: " CONFLICT_CHOICE
        CONFLICT_CHOICE=${CONFLICT_CHOICE:-1}

        case "$CONFLICT_CHOICE" in
            1)
                SUGGESTED_PATH="${WS_PATH}2"
                continue
                ;;
            2)
                echo -e "${YELLOW}[警告] 用户已确认强制覆盖旧配置！${PLAIN}"
                break
                ;;
            *)
                echo -e "${RED}[操作取消] 已安全退出，未做任何修改。${PLAIN}"
                exit 0
                ;;
        esac
    else
        break
    fi
done

# 5. 自动猜测证书路径
DEFAULT_CERT="/root/cert/${DOMAIN}/fullchain.pem"
DEFAULT_KEY="/root/cert/${DOMAIN}/privkey.pem"
[ ! -f "$DEFAULT_CERT" ] && DEFAULT_CERT="/root/cert-CF/${DOMAIN}/fullchain.pem"
[ ! -f "$DEFAULT_KEY" ] && DEFAULT_KEY="/root/cert-CF/${DOMAIN}/privkey.pem"
[ ! -f "$DEFAULT_CERT" ] && DEFAULT_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
[ ! -f "$DEFAULT_KEY" ] && DEFAULT_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
[ ! -f "$DEFAULT_CERT" ] && DEFAULT_CERT="/etc/nginx/${DOMAIN}.pem"
[ ! -f "$DEFAULT_KEY" ] && DEFAULT_KEY="/etc/nginx/${DOMAIN}.key"

if [ "$WEB_SERVER" = "caddy" ]; then
    echo -e "\n${CYAN}[SSL 证书说明] 当前检测到 Caddy。Caddy 支持全自动管理/签发证书。${PLAIN}"
    echo -e "${CYAN}若已有现成证书直接回车即可；若希望由 Caddy 自动托管证书亦可直接留空。${PLAIN}"
    read -p "5. SSL 证书路径 [默认: ${DEFAULT_CERT:-无} (可直接按回车)]: " CERT_FILE
    CERT_FILE=${CERT_FILE:-$DEFAULT_CERT}
    read -p "6. SSL 私钥路径 [默认: ${DEFAULT_KEY:-无} (可直接按回车)]: " KEY_FILE
    KEY_FILE=${KEY_FILE:-$DEFAULT_KEY}
else
    read -p "5. SSL 证书路径 [默认: $DEFAULT_CERT]: " CERT_FILE
    CERT_FILE=${CERT_FILE:-$DEFAULT_CERT}

    read -p "6. SSL 私钥路径 [默认: $DEFAULT_KEY]: " KEY_FILE
    KEY_FILE=${KEY_FILE:-$DEFAULT_KEY}

    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        echo -e "${RED}[错误] 证书或私钥文件不存在，请检查路径！${PLAIN}"
        echo "证书路径: $CERT_FILE"
        echo "私钥路径: $KEY_FILE"
        exit 1
    fi
fi

echo -e "\n${YELLOW}[1/4] 正在配置 3X-UI 内部数据与双重映射 (Hosts + externalProxy)...${PLAIN}"

# 备份数据库
cp "$XUI_DB" "${XUI_DB}.bak.$(date +%Y%m%d%H%M%S)"

# 执行 Python 处理数据库
python3 - << PYEOF
import sqlite3, json, uuid, time, sys

conn = sqlite3.connect("$XUI_DB")
c = conn.cursor()

c.execute("SELECT id, protocol, stream_settings FROM inbounds WHERE port = ?", ($XUI_PORT,))
row = c.fetchone()
inbound_id, protocol, stream_settings_raw = row[0], row[1], row[2]
stream_settings = json.loads(stream_settings_raw) if stream_settings_raw else {}

security = stream_settings.get("security", "none")
scheme = "https" if security == "tls" else "http"
with open("/tmp/xui_scheme.txt", "w") as f:
    f.write(scheme)

# 1. 确保入站内部的 ws path 与设定的分流路径一致
if "wsSettings" in stream_settings:
    stream_settings["wsSettings"]["path"] = "$WS_PATH"

# 2. 写入 externalProxy (保证网页控制面板“复制链接/二维码/API”导出端口正确)
stream_settings["externalProxy"] = [
    {
        "dest": "$DOMAIN",
        "port": int("$EXTERNAL_PORT"),
        "forceTls": "same",
        "remark": ""
    }
]
c.execute("UPDATE inbounds SET stream_settings = ? WHERE id = ?", (json.dumps(stream_settings), inbound_id))

# 3. 检查/添加主机映射表 (Hosts)，保证订阅接口 (/sub/) 导出端口正确
now = int(time.time() * 1000)
c.execute("SELECT id FROM hosts WHERE inbound_id = ?", (inbound_id,))
host_row = c.fetchone()

if host_row:
    c.execute("""
        UPDATE hosts SET
            address = ?, port = ?, path = ?, sni = ?, host_header = ?,
            security = 'same', updated_at = ?
        WHERE inbound_id = ?
    """, ("$DOMAIN", int("$EXTERNAL_PORT"), "$WS_PATH", "$DOMAIN", "$DOMAIN", now, inbound_id))
    print(f"\033[0;32m[OK] 已同步更新主机映射表 (Hosts ID: {host_row[0]})\033[0m")
else:
    gid = str(uuid.uuid4())
    c.execute("""
        INSERT INTO hosts (
            group_id, inbound_id, sort_order, remark, is_disabled, is_hidden,
            address, port, security, sni, host_header, path, created_at, updated_at
        ) VALUES (
            ?, ?, 0, ?, 0, 0,
            ?, ?, 'same', ?, ?, ?, ?, ?
        )
    """, (gid, inbound_id, f"Auto_{inbound_id}", "$DOMAIN", int("$EXTERNAL_PORT"), "$DOMAIN", "$DOMAIN", "$WS_PATH", now, now))
    print(f"\033[0;32m[OK] 已新建主机映射记录 (Hosts)\033[0m")

conn.commit()
conn.close()
PYEOF

UPSTREAM_SCHEME=$(cat /tmp/xui_scheme.txt 2>/dev/null || echo "https")
rm -f /tmp/xui_scheme.txt

echo -e "${YELLOW}[2/4] 正在重启 3X-UI 使配置生效...${PLAIN}"
systemctl restart x-ui
sleep 2

if [ "$WEB_SERVER" = "caddy" ]; then
    echo -e "${YELLOW}[3/4] 正在配置 Caddy 反向代理...${PLAIN}"
    CADDYFILE="/etc/caddy/Caddyfile"
    if [ ! -f "$CADDYFILE" ]; then
        mkdir -p /etc/caddy
        touch "$CADDYFILE"
    fi
    cp "$CADDYFILE" "${CADDYFILE}.bak.$(date +%Y%m%d%H%M%S)"

    python3 - << PYEOF
import re, sys, os

caddy_file = "$CADDYFILE"
domain = "$DOMAIN"
ws_path = "$WS_PATH"
xui_port = int("$XUI_PORT")
ext_port = int("$EXTERNAL_PORT")
upstream_scheme = "$UPSTREAM_SCHEME"
cert_file = "$CERT_FILE"
key_file = "$KEY_FILE"

with open(caddy_file, "r") as f:
    caddy_content = f.read()

# 构造 Caddy 代理块
if upstream_scheme == "https":
    tls_transport = f"""            transport http {{
                tls
                tls_server_name {domain}
                tls_insecure_skip_verify
            }}"""
    proxy_block = f"""        reverse_proxy https://127.0.0.1:{xui_port} {{
{tls_transport}
        }}"""
else:
    proxy_block = f"""        reverse_proxy http://127.0.0.1:{xui_port}"""

handle_block = f"""    # 3X-UI WebSocket 反向代理 ({ws_path})
    handle {ws_path}* {{
{proxy_block}
    }}"""

# 查找匹配的域名站点块
if ext_port == 443:
    pat = re.compile(r"(?:^|\n)\s*(" + re.escape(domain) + r"(?::443)?)\s*\{")
else:
    pat = re.compile(r"(?:^|\n)\s*(" + re.escape(domain) + r":" + str(ext_port) + r")\s*\{")

m = pat.search(caddy_content)

if m:
    start_brace = caddy_content.find("{", m.start())
    depth = 0
    end_brace = -1
    for i in range(start_brace, len(caddy_content)):
        if caddy_content[i] == '{':
            depth += 1
        elif caddy_content[i] == '}':
            depth -= 1
            if depth == 0:
                end_brace = i
                break
    if end_brace == -1:
        print("[错误] Caddyfile 大括号未闭合！", file=sys.stderr)
        sys.exit(1)

    body = caddy_content[start_brace + 1:end_brace]

    # 移除已有的相同路径 handle 块
    h_pattern = re.compile(r"(\s*#[^\n]*\n)?\s*handle\s+" + re.escape(ws_path) + r"\*?\s*\{")
    while True:
        hm = h_pattern.search(body)
        if not hm: break
        h_start = hm.start()
        h_open = body.find("{", hm.start())
        h_depth = 0
        h_end = -1
        for j in range(h_open, len(body)):
            if body[j] == '{': h_depth += 1
            elif body[j] == '}':
                h_depth -= 1
                if h_depth == 0:
                    h_end = j + 1
                    break
        if h_end != -1:
            body = body[:h_start] + body[h_end:]
        else:
            break

    # 插入到最顶部以优先匹配 WebSocket
    body = "\n" + handle_block + "\n" + body.lstrip("\n")
    new_content = caddy_content[:start_brace + 1] + body + caddy_content[end_brace:]
    print("\033[0;32m[OK] 已成功更新 Caddyfile 中已有站点的分流规则！\033[0m")
else:
    site_label = domain if ext_port == 443 else f"{domain}:{ext_port}"
    tls_line = ""
    if cert_file and key_file and os.path.exists(cert_file) and os.path.exists(key_file):
        tls_line = f"    tls {cert_file} {key_file}\n"
    new_site = f"""
{site_label} {{
{tls_line}{handle_block}
}}
"""
    new_content = caddy_content.rstrip() + "\n" + new_site
    print(f"\033[0;32m[OK] 已在 Caddyfile 中新建站点规则 ({site_label})！\033[0m")

with open(caddy_file, "w") as f:
    f.write(new_content)
PYEOF
    TARGET_CONF="$CADDYFILE"

    echo -e "${YELLOW}[4/4] 正在校验并重载 Caddy...${PLAIN}"
    caddy validate --config /etc/caddy/Caddyfile
    if systemctl is-active --quiet caddy; then
        systemctl reload caddy
    else
        systemctl restart caddy
    fi
    systemctl enable caddy >/dev/null 2>&1 || true

else
    echo -e "${YELLOW}[3/4] 正在配置 Nginx 反向代理...${PLAIN}"

    # 构造 location 配置块
    SSL_UPSTREAM_DIRECTIVE=""
    if [ "$UPSTREAM_SCHEME" = "https" ]; then
        SSL_UPSTREAM_DIRECTIVE="        proxy_ssl_server_name on;
        proxy_ssl_name ${DOMAIN};"
    fi

    LOCATION_BLOCK="    # 3X-UI WebSocket 反向代理 (${WS_PATH})
    location ${WS_PATH} {
        if (\$http_upgrade != \"websocket\") {
            return 404;
        }
        proxy_redirect off;
        proxy_pass ${UPSTREAM_SCHEME}://127.0.0.1:${XUI_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
${SSL_UPSTREAM_DIRECTIVE}
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }"

    TARGET_CONF=$(python3 - << PYEOF
import os, sys

domain = "$DOMAIN"
port = "$EXTERNAL_PORT"
nginx_dir = "/etc/nginx"
matched = []

for root, dirs, files in os.walk(nginx_dir):
    for f in files:
        if not f.endswith(".conf") and "sites-available" not in root and "sites-enabled" not in root:
            continue
        if f.endswith(".bak") or "backup" in f:
            continue
        p = os.path.join(root, f)
        try:
            with open(p) as fp:
                c = fp.read()
            if domain in c and port in c:
                matched.append(p)
        except:
            pass

res = ""
for m in matched:
    if "sites-available" in m or "conf.d" in m:
        res = m
        break
if not res and matched:
    res = matched[0]
print(res)
PYEOF
)

    SELF_CONF="/etc/nginx/conf.d/xui_${DOMAIN}_${EXTERNAL_PORT}.conf"

    if [ -n "$TARGET_CONF" ] && [ -f "$TARGET_CONF" ] && [ "$TARGET_CONF" != "$SELF_CONF" ]; then
        echo -e "${CYAN}[提示] 检测到现有网站配置文件: ${TARGET_CONF}，正在更新/追加分流规则...${PLAIN}"
        python3 - << PYEOF
import re

with open("$TARGET_CONF", "r") as f:
    content = f.read()

loc_block = """$LOCATION_BLOCK"""
ws_path = "$WS_PATH"

# 移除已有同路径 location 块
pattern = re.compile(r"(\s*#\s*[^\n]*\n)?\s*location\s+" + re.escape(ws_path) + r"\s*\{")
while True:
    m = pattern.search(content)
    if not m: break
    start_pos = m.start()
    open_brace = content.find("{", m.start())
    brace_depth = 0
    end_pos = -1
    for i in range(open_brace, len(content)):
        if content[i] == "{": brace_depth += 1
        elif content[i] == "}":
            brace_depth -= 1
            if brace_depth == 0:
                end_pos = i + 1
                break
    if end_pos != -1:
        content = content[:start_pos] + content[end_pos:]
    else:
        break

idx = content.rfind("}")
if idx != -1:
    content = content[:idx] + "\n" + loc_block + "\n" + content[idx:]

with open("$TARGET_CONF", "w") as f:
    f.write(content)
print("\033[0;32m[OK] 已成功更新已有配置中的分流规则！\033[0m")
PYEOF
    else
        TARGET_CONF="$SELF_CONF"
        mkdir -p /etc/nginx/conf.d/
        mkdir -p /var/www/html

        HTTP_REDIRECT_BLOCK=""
        if [ "$EXTERNAL_PORT" = "443" ]; then
            HTTP_REDIRECT_BLOCK="# 80 跳转 HTTPS
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}"
        fi

        cat << NGINX_NEW_EOF > "$TARGET_CONF"
$HTTP_REDIRECT_BLOCK

# $EXTERNAL_PORT SSL 核心配置
server {
    listen $EXTERNAL_PORT ssl http2;
    server_name $DOMAIN;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;

    location / {
        root /var/www/html;
        index index.html index.nginx-debian.html;
    }

$LOCATION_BLOCK
}
NGINX_NEW_EOF
        echo -e "${GREEN}[OK] 已生成完整独立的 Nginx 配置文件: ${TARGET_CONF}${PLAIN}"
    fi

    echo -e "${YELLOW}[4/4] 正在校验并启动/重载 Nginx...${PLAIN}"
    nginx -t
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        systemctl restart nginx
    fi
    systemctl enable nginx >/dev/null 2>&1 || true
fi

echo -e "\n${GREEN}====================================================${PLAIN}"
echo -e "${GREEN}               全部自动化配置成功！                 ${PLAIN}"
echo -e "${GREEN}====================================================${PLAIN}"
echo -e "Web 服务器类型:       ${CYAN}${WEB_SERVER^^}${PLAIN}"
echo -e "节点域名 (Address):   ${CYAN}${DOMAIN}${PLAIN}"
echo -e "对外端口 (Port):      ${CYAN}${EXTERNAL_PORT}${PLAIN}"
echo -e "分流路径 (Path):      ${CYAN}${WS_PATH}${PLAIN}"
echo -e "3X-UI 入站端口:       ${CYAN}${XUI_PORT}${PLAIN}"
echo -e "订阅与面板状态:       ${GREEN}已自动双重映射为 ${EXTERNAL_PORT} 端口${PLAIN}"
echo -e "Web 配置文件:         ${CYAN}${TARGET_CONF}${PLAIN}"
echo -e "${GREEN}====================================================${PLAIN}"
echo -e "现在你的另一个网站/订阅系统拉取节点，端口直接就是 ${CYAN}${EXTERNAL_PORT}${PLAIN}，开箱即用！"
