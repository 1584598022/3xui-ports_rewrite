# 3X-UI 端口分流与订阅重写自动化工具 (Nginx & Caddy 双引擎自适应版)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Language-Bash%20%2F%20Python3-green.svg)](https://www.python.org/)
[![Platform](https://img.shields.io/badge/Platform-Linux%20(Ubuntu%20%2F%20Debian)-orange.svg)]()

> 一键将 3X-UI 的 VLESS+WS+TLS 高位监听端口无缝伪装穿透至 443 / 8443 等标准 Web 端口，支持 Nginx 与 Caddy 双引擎自动识别，并深度重写 3X-UI 订阅导出端口。

---

## 💡 为什么需要这个脚本？

在使用 3X-UI 搭建代理节点时，常遇到以下痛点：
1. **端口冲突**：VPS 上已有现成网站或服务（如博客、Next.js、Sub-Store、Emby 等）独占了 **443** 端口，3X-UI 入站无法直接监听 443。
2. **订阅端口不匹配**：虽然通过反向代理将 443 转发到了 3X-UI 内部端口（如 60231），但 3X-UI 面板导出的订阅链接、节点二维码或 API 端口仍然是原始的 60231，发给客户端必须手动修改才能连接。
3. **Web 服务器多样性**：有些 VPS 跑 Nginx，有些 VPS 跑 Caddy，维护多套脚本极为繁琐。
4. **多节点同端口冲突**：同一域名同端口配置第二个节点时，容易因路径重叠（如都使用 `/vless-ws`）导致旧节点报 404 断连。

**本脚本为解决上述痛点而生，提供全自动化、零破坏的一键式解决方案。**

---

## ⚡ 核心功能与特性

* **🚀 Nginx & Caddy 双引擎智能自适应**
  * 自动探测服务器正在运行的 Web 引擎（Nginx 或 Caddy）。
  * 在 Nginx 环境下自动配置规范的反代 location 块与 SSL 证书。
  * 在 Caddy 环境下自动在现有 Caddyfile 站点顶部注入 WebSocket handle 规则，绝不破坏现有的 Sub-Store、Emby 等业务。
* **🔄 订阅与面板双重重写 (Hosts 表 + externalProxy)**
  * 自动更新 3X-UI 底层 SQLite 数据库的 `hosts` 映射表与 `inbounds.stream_settings.externalProxy`。
  * 无论是客户端拉取 `/sub/` 订阅链接，还是在 3X-UI 网页后台复制链接/二维码，**端口均自动输出为 443（或自定义的对外端口）**，开箱即用。
* **🛡️ 物理端口异构服务侦测与拦截**
  * 在输入端口后，底层静默扫描端口物理占用。
  * 若检测到端口被非 Nginx/Caddy 服务（如 Apache、Docker 等）独占，立即弹出红色高亮拦截面板，支持一键换端口（8443/2096）或一键停止闲置服务。
* **🧠 智能路径顺延与深度防冲突**
  * 跨 3X-UI 数据库、Nginx 配置与 Caddyfile 进行三方冲突检测。
  * 当同一域名端口已有旧节点时，按回车自动递增推荐可用路径（如 `/vless-ws` $\rightarrow$ `/vless-ws2`），防止误覆盖。

---

## 📥 一键运行

在任意已安装 3X-UI 的 Linux VPS 上以 `root` 用户运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/daocaoren/3x-ui-proxy/main/xui.sh)
```
*(注：请将链接中的用户名和仓库名替换为你自己的 GitHub 仓库地址)*

备用快速镜像链接：
```bash
bash <(curl -fsSL https://uk.daocaoren.pp.ua/xui.sh)
```

---

## 🖥️ 交互流程说明

脚本仅需输入几个基础参数，其余全部全自动推导与处理：

```text
====================================================
   3X-UI 自定义端口分流 & 订阅重写自动化脚本 (Nginx/Caddy)   
====================================================
[环境识别] 检测到当前服务器 Web 服务为: CADDY (或 NGINX)

--- [参数输入] ---
1. 节点绑定的域名 (例如 node.example.com): sg.example.com
2. 3X-UI 入站的内部监听端口 (例如 60231): 11945
3. 对外自定义映射端口 [默认: 443]: 443
4. WebSocket 分流路径 [默认: /vless-ws]:
5. SSL 证书路径 [默认: /root/cert/sg.example.com/fullchain.pem]:
6. SSL 私钥路径 [默认: /root/cert/sg.example.com/privkey.pem]:

[1/4] 正在配置 3X-UI 内部数据与双重映射 (Hosts + externalProxy)...
[OK] 已同步更新主机映射表 (Hosts ID: 1)
[2/4] 正在重启 3X-UI 使配置生效...
[3/4] 正在配置 Web 反向代理...
[OK] 已成功更新分流规则！
[4/4] 正在校验并重载 Web 服务...
Valid configuration / Syntax OK

====================================================
               全部自动化配置成功！                 
====================================================
```

---

## 🛠️ 技术原理

```mermaid
flowchart TD
    Client["客户端 / 订阅系统"] -->|HTTPS 443 / 8443 / 2096| WebProxy["Web 反向代理 (Nginx / Caddy)"]
    WebProxy -->|Path: /vless-ws*| Xray["3X-UI Xray (内部端口: 11945)"]
    WebProxy -->|Path: / (默认网站)| WebSite["原网站服务 (Sub-Store / Emby / Blog)"]
    
    subgraph "3X-UI SQLite 数据库"
        Hosts["hosts 表: address + port 映射"]
        ExtProxy["inbounds 表: externalProxy 配置"]
    end
    
    Xray -.-> Hosts
    Xray -.-> ExtProxy
```

1. **流量分流**：外部请求到达 443 端口，Nginx/Caddy 仅拦截匹配的 `/vless-ws` WebSocket 流量并将其反向代理至 3X-UI 内部高位端口；根目录及其他路径正常访问原网站。
2. **订阅生成**：3X-UI 生成订阅节点时，通过数据库注入的 `Hosts` 和 `externalProxy` 配置，强制将导出节点信息的 `port` 字段替换为对外公开端口（443）。

---

## 📄 开源许可证

本项目基于 [MIT 许可证](LICENSE) 开源。
