# ss2anytls-autodeploy

通过 sing-box 内核，一键在公网服务器 B（中转）和服务器 C（出口）之间部署 ss-anytls 隧道。
Autodeploy ss-anytls tunnel between server B (relay) &amp; C (exit) with sing-box core.

## 一键脚本

```bash
curl -O https://raw.githubusercontent.com/Cyli00/ss2anytls-autodeploy/refs/heads/main/autodeploy.sh
chmod +x autodeploy.sh
bash autodeploy.sh
```

## 模式说明

- **[1] B (Relay)** — 中转服务器：运行 SS-2022 入站，通过 AnyTLS 出站连接到服务器 C
- **[2] C (Exit)** — 出口服务器：运行 AnyTLS 入站，需要公网 IP

## 建议流程

1. **在服务器 C** 运行脚本 → 选择 `[2] (Exit)`，按提示设置端口和 Tag
2. 复制显示的 IP、Port、Password（以及 AnyTLS URI）
3. **在服务器 B** 运行脚本 → 选择 `[1] (Relay)`
4. 粘贴 C 的信息，设置本地端口和节点名称
5. 获得 SS URI 链接，分享给用户直接导入客户端

## 输出说明

- **C 端（Exit）**：输出 AnyTLS URI（`anytls://`），可直接导入支持 sing-box URI 的客户端
- **B 端（Relay）**：输出 Shadowsocks URI（`ss://`），用户可直接导入客户端使用

## 功能特性

- 支持多次运行添加多个入站/路由
- 自签 TLS 证书，无需域名
- 可选 SNI Server Name 配置
- 自动检测端口和 Tag 冲突，支持覆盖
- URI 一键导入链接输出
