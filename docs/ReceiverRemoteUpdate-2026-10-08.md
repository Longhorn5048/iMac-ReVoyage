> 历史／技术记录：当前 Alpha 状态、安装与连接方式以 [README](../README.md) 为准。
> Historical / technical record: consult the README for current Alpha status and setup.

# 从 Sender 远程更新 Receiver

Sender 设置新增“远程更新 Receiver”。选择发现的 iMac 或填写有线地址，再选择新版完整 `iMac-ReVoyage-Preview.zip`，即可上传、安装并查看结果。iMac 端不用鼠标确认更新，也不需要 SSH、密码或配对码。

## 首次启用：只用键盘

旧 Receiver 没有远程更新服务，必须先在 iMac 安装一次本次新版。把安装包放到 iMac 的“下载”目录，先在 Sender 停止串流，再用 iMac 本地键盘 **Command + 空格** 打开“终端”，依次执行：

```sh
ditto -x -k ~/Downloads/iMac-ReVoyage-Preview.zip ~/Downloads/iMac-ReVoyage-Preview
/bin/zsh ~/Downloads/iMac-ReVoyage-Preview/Receiver/install_receiver.command
```

如果安装包已解压，只需执行第二行，路径按实际位置调整。随后在 Mac mini 安装同一包中的新版 Sender。iMac 当前用户需保持登录；更新服务会随登录启动。

## 后续更新

1. 下载新版完整安装包到 Mac mini，无需再把文件复制到 iMac。
2. 打开 Sender 设置 →“远程更新 Receiver”，选择 iMac。
3. 点击“选择安装包并更新”，选择完整 ZIP。界面依次显示检查、上传、安装和结果。
4. 更新会短暂停止目标 iMac 的串流，替换 Receiver、HDMI Rescue、Storage Watcher 和包内 Media Bridge。安装完成后尝试恢复更新前正在运行的会话；设置、接收器身份和用户存储文件保留。

Sender 连接中断或被关闭后，已接收完成的更新仍在 iMac 上运行；重新打开 Sender 可点击“检查更新结果”。上传未完成时中断连接会放弃该包。若显示结果暂时未知，保持连接后再检查，不要将未知状态当作安装成功。

## 实现边界

- 独立用户 LaunchAgent `re.voyage.updater`，可执行文件位于 Receiver.app 内，监听有线 IPv4 TCP 54324；拒绝 Wi-Fi、回环和已知低于千兆的接口。千兆网卡及 Thunderbolt 网桥复用现有接口识别规则。
- 同一时间只处理一个更新。包大小上限 96 MiB，流式上传并核对 SHA-256；更新状态和请求 UUID 存入 Receiver 自有目录，旧请求的成功结果不能确认新请求。
- 解压前检查 ZIP 中央目录与本地文件名，拒绝路径越界、链接、重复文件和异常大小；仅解压 `Receiver/`。
- 检查预期应用身份、签名和全部 Mach-O 的 Intel / Catalina 兼容性，且新包必须保留更新服务。调用已安装的安装器，包内顶层脚本不会执行。
- 复用现有安装事务和失败回滚。远程模式在核心应用重启时保留更新进程；成功回执写入后，该进程退出，由 KeepAlive 启动新版。卸载入口同时清理更新服务、暂存包、回执及更新日志。
- 更新日志：`~/Library/Logs/iMac ReVoyage/updater-install.log`。更新工作目录：`~/Library/Application Support/TargetBridge Receiver/Updates`。

## 验证与待验收

Sender 测试覆盖包摘要、HTTP 分片／边界和请求匹配。原生服务使用临时根目录及回环替身，覆盖成功安装、错误摘要、异常 ZIP、包兼容性、断流、并发拒绝及重启回执。安装器服务替身验证更新进程在正常事务和回滚期间均不被停止；卸载替身验证更新文件清理。

本轮 168 项 Sender 测试及原有 Receiver／Rescue／媒体／安装卸载回归通过；远程服务 8 项回归包含完整发行 ZIP 的上传、应用替换及五个启动项验证，并验证单架构 FAT 格式的 Intel 卸载器可被接受。

验证不在真实 HOME 安装软件，不调用真实启动服务，不捕获或操作目标硬件。目标 Catalina iMac 的实际启动、跨机器上传、更新时画面中断和串流恢复仍待双机验收。
