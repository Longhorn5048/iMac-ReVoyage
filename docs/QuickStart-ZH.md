> 历史／技术记录：当前 Alpha 状态、安装与连接方式以 [README](../README.md) 为准。
> Historical / technical record: consult the README for current Alpha status and setup.

# iMac ReVoyage 快速上手

将 Intel iMac 用作另一台 Mac 的显示器、扬声器，并试用独立的摄像头／麦克风共享。

## 1. 准备与下载

- iMac：Intel，macOS 10.15.7 Catalina 或更新系统。先以 2015 年 1080p iMac 为基准；其他机型状态见 [兼容性表](Compatibility.md)。
- Sender：Apple Silicon Mac，macOS 14 或更新系统。
- 连接：雷电网桥或千兆有线网络。选择 Sender 对应的有线接口；两台机器应在同一有线网络中。
- 使用完整 `iMac-ReVoyage-Alpha-20261009.zip`，解压后应有 `Receiver`、`Sender`、`docs` 和 `BuildManifest.json`。普通用户无需安装开发工具或编译。

目前是本地临时签名的预览包，尚未完成 Developer ID 签名及公证。如果系统提示无法验证开发者，仅对你确认来源的包使用系统“隐私与安全性”中的“仍要打开”；不要关闭系统安全保护。

## 2. 在 iMac 安装 Receiver

打开 `Receiver/install_receiver.command`。它会安装显示 Receiver、HDMI Rescue、存储监视器，并独立安装可选 Media Bridge；设置当前用户登录后启动。

本机安装还会尝试开启 macOS 远程登录（SSH），按系统窗口输入管理员密码。若提示缺少完整磁盘访问权限，可在共享设置中直接开启“远程登录”，或授权终端后用 `--enable-ssh` 单独重试。成功后在 Sender 的 Receiver 高级服务中填写 iMac 的有线地址和 iMac 账户名，即可打开 SSH；详见 [SSH 安装说明](ReceiverSSH-2026-10-08.md)。

当前开发版无需配对码或导入配对文件；升级保留接收器身份及设置。

没有鼠标时，可用 Command + 空格打开“终端”，执行 `/bin/zsh ~/Downloads/iMac-ReVoyage-Alpha-20261009/Receiver/install_receiver.command`（按实际解压路径调整）。本版首次安装后，后续可在 Mac mini 的 Sender 设置 →“远程更新 Receiver”，选择新版完整 ZIP 更新 iMac，结束后尝试恢复原串流。首次启用及仅用键盘的步骤见 [远程更新说明](ReceiverRemoteUpdate-2026-10-08.md)。

HDMI Rescue 另需接入采集卡及 HDMI 输入；没有采集卡也可使用有线显示。按系统提示允许救援应用使用摄像头。输入控制按需允许辅助功能和输入监控；仅观看画面不需要输入控制权限。

## 3. 打开 Sender

双击 `Sender/安装 Sender.command`，它会关闭旧 Sender、安装到自己的“应用程序”目录并打开该副本。两端都使用当前直连版，选择已发现的 iMac 即可连接，无需保存配对码。

需要 Sender 后台运行时，在“设置 → 界面”开启“隐藏 Dock 图标”，立即生效并记住选择。菜单栏图标会保持显示，可从其菜单打开主窗口或取消隐藏；隐藏图标不停止串流。

## 4. 连接与画质

返回会话，选择接收 iMac 和匹配的有线接口。新会话默认开启“自动推荐与性能降级”：根据接收端的面板资料和编解码能力，从 1080p60 或 1440p30 起步；持续处理吃力时逐步降到 1080p60、1080p30。稳定两分钟后最多尝试恢复一次。

已有保存的手动档位会继续保持。关闭自动模式后可固定画质；4K／5K 档仍需要实机验证。Sender 会按两端能力选择 HEVC 或 H.264。

点击连接，按系统提示允许 Sender 录屏；若系统要求重新打开应用，照提示完成后再连接。可选择镜像或扩展桌面。在 macOS“显示器”设置中排列扩展屏幕。iMac 换有线地址后，重新选择它并连接，显示身份会沿用。

扬声器需要安装独立输出设备：在 Sender 设置点击“安装 iMac 扬声器…”，重启 Mac mini 后在系统声音输出选择 **ReVoyage — iMac Speakers**，并开启“传输音频”。选择本机扬声器或耳机时 iMac 不发声。详见 [独立扬声器说明](IMacSpeakerDevice-2026-10-09.md)。摄像头／麦克风是独立服务，方向为 iMac → Sender；系统虚拟设备激活和常用通话应用兼容仍处于实验验证阶段，见兼容性表。

## 5. 遇到问题

Receiver 本地调试：在 iMac 的 Receiver／Rescue 窗口使用本地键盘，按 **D** 显示顶端串流信息栏，再按一次关闭；按 **R** 手动切换到 HDMI Rescue，再按一次返回网络画面。没有 HDMI 输入时也能按 R 返回。无串流、Sender 停止或断线时 Receiver 继续等待，重新开启 Sender 串流即可重连。

信息栏显示分辨率、编码、NV12 色彩格式、实际接收／提交帧率、面板刷新率、接收带宽、合帧比例及解码错误。“接收→提交”是接收端处理时间，不是双机端到端延迟；TCP 丢包率显示未测量。D／R 不转发给 Sender，带 Command／Option／Control 的组合键仍按原逻辑处理。

- 找不到 iMac：确认 Receiver 已启动、两端接入有线网络，刷新发现列表；也可手动填写 iMac 当前地址。
- 提示需要配对码：当前直连版不要求配对。使用安装入口关闭旧进程、安装并打开新版 Sender，再在“关于”核对版本。
- 黑屏或录屏失败：检查 Sender 录屏权限及所选捕获模式，重新打开应用后再连接。
- 画面吃力：开启自动模式，或手动选择 1080p30；“距最近提交时间”是接收端状态指标，不是端到端延迟。
- 暂停网页视频后无声／提示声音积压：安装本轮新版 Sender，确认“传输音频”已开启。新版在队列排空后自动恢复音频，保留手动静音选择；无需重装 Receiver。见 [修复说明](AudioResume-2026-10-08.md)。
- 换接口：重新选择匹配的有线接口及已发现 iMac，随后直接连接。

## 6. 完整卸载

Sender 使用应用内“完整卸载”，或 `Sender/uninstall_sender.command`；Receiver 使用完整卸载入口，或 `Receiver/uninstall_receiver.command`。

卸载本端应用、登录启动项、配对凭据、设置、缓存和日志；保留用户存储文件，不移除系统物理摄像头及麦克风。Receiver 日志位于 `~/Library/Logs/iMac ReVoyage/`。

SSH 是 macOS 系统设置，卸载会保留它；需要关闭时在系统“共享 → 远程登录”中关闭。

开发者构建及无硬件验证见 [测试文档](Testing.md)。
