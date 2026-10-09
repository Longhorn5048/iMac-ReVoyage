> 历史／技术记录：当前 Alpha 状态、安装与连接方式以 [README](../README.md) 为准。
> Historical / technical record: consult the README for current Alpha status and setup.

# 独立 iMac 扬声器输出设备

## 用户行为

Sender 安装在 Mac mini 上；Mac mini 内建扬声器、耳机和 iMac 扬声器是独立输出设备。本次替代此前“选中内建扬声器就向 iMac 转发”的错误策略。

- 选择 **ReVoyage — iMac Speakers**：声音从这个设备发送给已连接的 iMac，Mac mini 内建扬声器不播放这个设备的声音。
- 选择 Mac mini 内建扬声器、耳机、USB、HDMI 或其它输出：不会把这些设备的声音发给 iMac。
- 保留 Sender 的“传输音频”开关；手动关闭或睡眠时不发送。选择 iMac 输出而未连接 Receiver 时，这个虚拟输出没有实际播放端，不会自动转到本机扬声器。
- 仅安装驱动不会修改默认输出；用户在系统声音输出中明确选择。驱动是单个默认 iMac 输出设备，与当前显示串流会话配合；多个 iMac 分别选择独立输出不属于本轮实现。

## 首次安装

1. 在 Mac mini 上安装本轮新版 Sender。
2. 运行包内 `Sender/安装 iMac 扬声器.command`，或在 Sender 设置的媒体设备区域点击“安装 iMac 扬声器…”。macOS 会请求管理员授权以安装音频驱动。
3. 重启 Mac mini，然后启动 Sender 并连接 iMac。
4. 在系统设置 → 声音 → 输出（或控制中心的声音输出）选择 **ReVoyage — iMac Speakers**，并开启 Sender“传输音频”。

不需要关闭 SIP，也不要求先启用摄像头或麦克风扩展。该设备走用户空间 HAL plug-in，沿用 Sender 最低 macOS 14 的支持范围。实际加载和双机出声仍需上述安装后复测。

## 实现

- `VirtualDevices/Speaker/driver.c` 发布输出专用 HAL 设备，UID 为 `re.voyage.imac.speaker`，48kHz、Float32、双声道。HAL 的 `WriteMix` 回调接收这个设备自己的混音，不在 Mac mini 上播放，也不读取其它输出设备。
- 实时回调无锁、无分配、无网络，只写有限原子缓冲。Sender 在非实时线程每 10ms 读取最多 480 帧并转换为现有 Receiver 使用的 S16LE 立体声格式。没有任何 ScreenCaptureKit 全系统音频转发；视频采集保持原实现。
- Sender 监听系统默认输出 UID，只有精确选中该设备才读取并发送。切换、重新连接或采集重建时清除旧缓冲；滞留超过预算的音频跳过，继续沿用网络队列积压限制及自动恢复。
- 输出设备支持音量和静音属性，增益应用在自己的混音上。首次安装不更改系统输出选择，也不修改物理设备或独立虚拟麦克风。
- 后续 1.1 驱动补齐系统声音菜单需要的主音量／静音控制对象。安装旧版驱动的用户需要重新运行扬声器安装入口并重启；详见 [1080p 桌面细节与系统音量修复](ClarityVolumeFix-2026-10-09.md)。
- 后续 1.2 驱动修正自定义 PCM 属性在系统音频服务中的数据传输格式，Sender 与驱动需要一起更新。详见 [声音与设置页修复](AudioThemeFix-2026-10-09.md)。
- 输出读取只接受已签名且标识为 Sender 的进程。开发预览支持现有本地签名；配置开发团队时读取进一步约束到同一团队。HAL 安装入口验证应用、驱动和既有目标身份，管理员操作只替换自有 `ReVoyageSpeaker.driver`。
- 完整卸载器删除自有扬声器驱动并保留其它音频设备；重启 macOS 后卸载的 HAL 设备才完全退出系统音频服务。

机制参考：[Apple Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)、[AudioServerPlugIn IO operations](https://developer.apple.com/documentation/coreaudio/audioserverpluginiooperation)。

## 验证与复测边界

- Sender 全量 179 项 XCTest 通过，覆盖仅精确 iMac UID 放行、Mac mini 内建输出及其它输出不放行、切换后的积压恢复不能覆盖静音。
- HAL 模拟 host 的测试通过，覆盖输出专用属性、立体声混音及 PCM、音量／静音、读者身份、越界、过期音频、缓冲清理、时钟重启和并发。ASan／UBSan 通过，未加载 HAL，也未操作实际音频设备。
- 安装入口的 4 项验证测试和完整卸载器的 15 项测试通过；仅验证签名／临时文件，没有进行系统安装或管理员操作。
- Sender 及输出驱动编译、安装包签名与可移植性检查通过。包内继续包含上一轮 Sender 睡眠／Receiver 唤醒修复。
- 未进行目标 Mac mini 的 HAL 实际加载、系统声音列表、耳机切换或双机发声测试。请按首次安装步骤依次验证 iMac → Mac mini 内建扬声器 → 耳机 → iMac 的切换，并确认每次只有选中的设备出声。
