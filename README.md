# ss-anytls-tunnel-autodeploy
autodeploy ss-anytls tunnel between server B &amp; C with sing-box core.

## 🎯 工作流程

```
curl -O https://raw.githubusercontent.com/Cyli00/ss2anytls-autodeploy/refs/heads/main/autodeploy.sh
chmod +x autodeploy.sh
bash autodeploy.sh
```

1. **在服务器 C** 运行脚本 → 选择 `[2] C (Exit)`
2. 复制显示的 IP、Port、Password
3. **在服务器 B** 运行脚本 → 选择 `[1] B (Relay)`
4. 粘贴 C 的信息，设置本地端口和节点名称
5. 获得 SS URI 链接，分享给用户直接导入！

用户现在可以一键复制链接到 Mihomo/Sing-box/V2ray 等客户端导入了！🚀
