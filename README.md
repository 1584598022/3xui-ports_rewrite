# 3xui-ports_rewrite

3X-UI 端口复用与订阅重写脚本。自动识别 Nginx / Caddy 环境，将 3X-UI 的 VLESS / VMess / Trojan 等 WebSocket 入站端口反代到 443 或自定义对外端口，并同步更新 3X-UI 内部数据库的订阅导出端口。

## 功能

- **多协议与多节点共存**：支持 VLESS、VMess、Trojan 等任意基于 WebSocket (WS) 的协议，可在同一 443 端口下按不同路径分流共存。
- **自动识别 Web 环境**：支持 Nginx 与 Caddy，自动检测并写入对应规则，不影响服务器现有站点运行。
- **订阅端口重写**：自动修改 3X-UI 数据库（Hosts 表与 externalProxy），使面板导出的节点链接与订阅端口直接变为 443（或自定义端口）。
- **端口占用检测**：前置检测目标端口（如 443），若被其他服务（如 Apache、Docker 等）占用，提供换端口或停用服务引导。
- **防路径冲突**：同端口添加新节点时，自动检测路径重叠并智能递增（如 `/vless-ws` -> `/vless-ws2`）。
- **智能继承分享地址**：若入站已配置“自定义分享地址”（如 Cloudflare 优选 IP / 域名），自动保留为客户端连接地址，同时保持 SNI 与 Host 标头为反代域名。
- **域名与 IP 通用**：支持域名证书、公网 IP 签发证书，以及无证书纯 HTTP 明文节点。

## 使用方法

在已安装 3X-UI 的 VPS 上以 root 用户运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/1584598022/3xui-ports_rewrite/main/xui.sh)
```

按照提示输入域名或公网 IP、3X-UI 入站端口、对外端口及分流路径即可。

## 原理

```text
客户端 (HTTPS 443/8443) ---> Web 反代 (Nginx / Caddy)
                                  |-- /vless-ws*   --->  VLESS 入站 (内部端口)
                                  |-- /vmess-ws*   --->  VMess 入站 (内部端口)
                                  |-- /trojan-ws*  --->  Trojan 入站 (内部端口)
                                  \-- 其它路径     --->  本地现有网站/服务
```

1. **分流反代**：外部流量进入 Web 服务器（443 等端口），匹配特定路径（如 `/vless-ws`、`/vmess-ws`）的 WebSocket 流量转发至对应的 3X-UI 入站，其余流量正常访问原有站点。
2. **订阅重写**：在 3X-UI SQLite 数据库中写入 `hosts` 映射与 `externalProxy`，确保订阅链接和节点配置导出正确的对外端口。

## 开源协议

MIT License
