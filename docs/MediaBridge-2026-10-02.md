> 历史／技术记录：当前 Alpha 状态、安装与连接方式以 [README](../README.md) 为准。
> Historical / technical record: consult the README for current Alpha status and setup.

# iMac 摄像头与麦克风共享：源码交付及本地验证

目标是把 iMac 变成 Studio Display。方向固定为 **iMac → Sender**：Receiver 登记本机物理设备；Sender 暴露系统虚拟摄像头和麦克风，供通话、录制应用选择。用户暂时没有 Apple Developer 团队，本阶段完成源码和本地验证，不安装或注册系统设备。

## 已实现

- `MediaBridge/main.m`：独立的 Catalina Intel 媒体服务，端口 54323，与显示、扬声器、HDMI Rescue 和存储监视分开运行。认证前不发布设备信息或接受采集请求；双向 HMAC 验证沿用当前 Receiver 配对码，域与主显示/设置/存储协议隔离。按要求不增加加密。
- 设备登记、显式选择和启停、macOS 授权、状态回应、心跳与超时、断线释放。先取得全部请求设备的权限，再启动采集；权限提示期间断线或本地停止不能随后启动采集。
- iMac 菜单栏显示摄像头/麦克风共享状态，提供本地停止入口。Sender 新增共享设置、虚拟设备安装入口和状态。Sender 设置与媒体状态菜单支持 en/zh/it/de/fr；原生安装确认提示目前为英中双语。
- 摄像头为 1280×720 JPEG，发送上限 20fps、单帧 256KiB，负载令牌桶上限 25Mbps。只保留一张待发送画面；发送过程中至多还有一张。全部待发送消息同时受 512KiB 和 64 条限制，音频待发送部分另限约 100ms。
- 麦克风为 48kHz、单声道、S16LE；每包最多 960 个采样，按采样位置检测连续性。格式不符、队列溢出或设备故障会结束共享，避免补播旧声音。Sender 转为 Float32 送入虚拟麦克风。
- `VirtualDevices/Camera/main.m`：现代 Sender 的 CoreMediaIO 摄像头扩展，含受签名校验保护的输入流及输出流。最多保留最新样本，超过 250ms 或停止共享输出黑画面；Sender 图像缓冲池最多分配 4 个画面缓冲。
- `VirtualDevices/Microphone/driver.c`：输入专用 HAL 驱动，无默认扬声器改动。实时读取路径无分配、无锁、无网络；有限原子环形缓冲、缺失采样输出静音、重启时钟种子、有限缓冲漂移调整。仅同开发团队签名的 Sender 可写入采样。
- Sender 安装前检查签名配置；未配置团队时明确报告需要签名。摄像头采用系统扩展激活/撤销请求；麦克风采用管理员确认后的签名复核、受保护暂存及安装，需重启生效。失败会清理暂存目录。
- 双端卸载器纳入媒体服务及虚拟设备：Sender 先停止共享、撤销摄像头扩展，再删除自有麦克风驱动和应用数据；需重启完成撤销时保留应用以供重试。Receiver 删除媒体 LaunchAgent、应用和日志。用户存储及系统物理设备保留，异名/异标识驱动不删除。
- 新构建脚本包含媒体服务及虚拟设备；Test7/8 构建同时更新双方，避免新认证协议搭配旧 Receiver。现有测试 ZIP 没有重建。

## 有线带宽方案

千兆网线先按已实现的每接口 900Mbps 可用容量估计，再保留 15% 余量；1080p60 主显示预留 100Mbps（当前低延迟档编码目标 50Mbps），每显示会话另留 5Mbps 辅助空间。接口容量可在 Sender 设置中按测量结果调整。

反向摄像头/麦克风建议规划 **40Mbps**：摄像头负载限 25Mbps，PCM 约 0.768Mbps，再给协议开销、控制和突发留余量。千兆及雷电网络通常为全双工，两个方向分别规划；不能把相反方向简单相加后声称带宽已经锁定。

当前代码提供应用内显示预算、有限队列、JPEG 负载限速及拥塞降码率；**尚无系统层流量整形或针对 SMB/其它进程的固定带宽保证**。40Mbps 是规划额度，不是已经安装的系统预留。实际链路、共同瓶颈及满负载场景仍需测量。

## 本地验证结果

- Xcode analyze/test 成功，Sender **122 项 XCTest** 全部通过，含 13 项媒体协议、认证和序列检查。结果：`/tmp/revoyage-development-derived/Logs/Test/Analyze-TBDisplaySender-2026.10.02_00-44-29-+0800.xcresult`。
- 合成设备回环服务测试 **10 项** 通过，覆盖双向认证、未认证请求、错误密钥、重复认证、非法长度/请求、停止与重连；服务使用 AddressSanitizer/UndefinedBehaviorSanitizer 构建。
- 临时目录卸载回归 **11 项**、安装器回归 **3 项** 通过。安装预览不会停止或启动真实服务；测试根目录只接受临时目录且强制预览模式。
- 三组原生 ASan/UBSan 检查通过：摄像头 JPEG 类型/尺寸、方向、BGRA、队列和清理；媒体有限队列、音频积压、关闭后的描述符复用及权限等待期间心跳后的断线识别；麦克风属性、边界、静音、时钟重启、多消费者及并发环形缓冲。
- 新媒体服务、摄像头、麦克风、设备安装器、卸载器均完成 clang 静态分析，无诊断；Xcode 未发现新的源码分析告警。
- Sender 虚拟设备/原生辅助程序 arm64 + x86_64 编译成功；Receiver 媒体服务 x86_64 / 最低 macOS 10.15 编译成功。现有 Receiver parser **62 项检查**、音频环和主连接认证测试通过。
- 五语言键/占位符检查、脚本语法及差异格式检查通过。

这些检查不采集实际摄像头/麦克风，不安装驱动、不修改 Keychain/TCC/SMB，不执行实际卸载，也未启动模拟器或目标机测试。系统扩展源码编译成功不等于已注册或已被 FaceTime 等客户端识别。

## 尚需完成的验收

1. 提供 Apple Developer 团队签名后验证系统扩展激活、麦克风安装与重启、双方升级以及完整卸载；正式分发还需对应签名、公证流程。
2. 在 Catalina iMac 与现代 Sender 验证权限、真实音频格式、画面方向、长时间 CPU/内存走势、睡眠/唤醒、拔线/崩溃、设备断开及通话应用兼容性。
3. 初版摄像头固定 720p20；更高帧率/清晰度、按需采集联动、失败后自动恢复、精确音画同步及设备列表热更新仍待开发或验证。当前故障后需手动重新连接/启用。
4. 摄像头与麦克风同用独立媒体 TCP，满负载时仍有队头阻塞风险；有限积压超过上限会断开，而不是持续播放旧媒体。需实测后决定是否拆分传输。
5. 显示延迟、颜色、刷新同步、系统固定带宽预留及其它路线图项目继续按 `FeatureCompletion-2026-10-01.md` 验收，不能据此宣布整个项目已足够稳定或完全无泄漏。

机制依据：[Apple Camera Extension 文档](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o)、[Apple Audio Server Plug-in 文档](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)。
