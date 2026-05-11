
快捷键 vp

curl -sSL https://raw.githubusercontent.com/lje02/liang/main/vp/install.sh | bash


# sing-box 综合管理脚本 vp

`ssb` (sing-box stack bash) 是一个为 Linux 服务器打造的、全功能自动化管理工具。它通过模块化的 Bash 脚本，将复杂的 `sing-box` JSON 配置转化为直观的交互式菜单，旨在提供“原子化”的操作体验。

---

## 🚀 核心特性

*   **原子化配置管理**：所有配置更改均经过语法校验，校验失败自动回滚，确保服务 100% 可用。
*   **多协议支持**：一键部署 VLESS (Reality/WS)、TUIC v5、Hysteria2、Shadowsocks、Trojan 等主流协议。
*   **智能链路管理**：支持可视化配置**链式代理**与**中转/落地**逻辑，轻松实现流量转发。
*   **自动化 WARP 部署**：一键安装 Cloudflare 官方客户端，自动注册并作为 Socks5 出站挂载至 sing-box。
*   **分流路由系统**：支持按域名、GeoSite、IP/CIDR 设定分流规则，内置 URL-Test 自动优选策略。
*   **证书运维**：集成 acme.sh 自动化申请 SSL 证书，并实现证书与节点的自动关联。
*   **无依赖安装**：不依赖 Git，直接通过 Curl/Wget 在主流 Linux 架构上快速部署。

---

## 🛠 安装与使用

在 Root 用户下执行以下命令即可启动管理面板：

