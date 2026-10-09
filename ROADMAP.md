> 历史／技术记录：当前 Alpha 状态、安装与连接方式以 [README](README.md) 为准。
> Historical / technical record: consult the README for current Alpha status and setup.

2026-10-03 修复交付：真实面板／1×、背光校验与回读、双向应用带宽界面、包级限额、声音静音隔离及接收端指标已接入。141 项 Sender 测试和原生替身／媒体／电源／安装卸载回归通过。SMB 独立限速、自动亮度模式控制、健康节能和实机验收仍待完成。详见 [本轮修复](docs/ProjectReviewFixes-2026-10-03.md)。

# ReVoyage 路线图

更新：2026-10-02。长期理念：**Give your old iMac another voyage.** 逐步重新利用 Intel iMac 的屏幕、扬声器、摄像头、麦克风、存储、SDXC、网络与计算能力。测试版 3 加入双输入帧仲裁、旧 LCD 无信号休眠策略和设置协议 v2；测试版 4 加入显式 SMB 文件夹共享；测试版 5 加入可移动卷检测；测试版 6 把卷监视拆为独立服务，使 Sender 无需视频会话也能查看；测试版 7 增加 Sender 1080p60 H.264 低延迟预设与采集回调合并；测试版 8 增加 Receiver socket drain 内的最新解码纹理单次呈现。目标机实测和 VSync/端到端时延验证未完成。当前状态见 `HANDOFF.md`、`ARCHITECTURE.md`、`DECISIONS.md`、`docs/HardwareAcceptance.md`。

2026-10-02 电源设计更新（D-020）：**HDMI Rescue 的目标优先级是可见性和可靠性，而不是自动节能。** 正常网络允许智能节能；网络失效进入锁存 `RESCUE_LOCK`，即使 HDMI 无信号也保持 LCD Awake，网络稳定恢复 1–2 秒后才退出；明确人工 `MANUAL_DISPLAY_OFF` 可覆盖保活。锁存、连续 2 秒帧恢复、已配对人工关屏／唤回、重启亮屏与双进程断言协调已实现，并重建 Test8。健康模式自动节能／Sender display-sleep 同步、本地物理控制及真机验收待完成。

2026-10-01 完整功能开发进行中：已加入主连接双向认证、按接收器地址的配对密钥、认证短连接和按接口的视频预算/测速互斥/有界队列/IDR 恢复/码率调整。用户已取消加密开发；系统层固定预留和目标机验收仍未完成；完整交付与证据清单见 [FeatureCompletion-2026-10-01.md](docs/FeatureCompletion-2026-10-01.md)。

## 不可退让的门槛

1. Receiver LTS 以 Intel iMac / macOS 10.15.7 Catalina 为最低支持目标；核心不依赖 OCLP 或 Receiver 端 Homebrew。必要 runtime 随 App/安装包分发，持续维护根目录 `THIRD_PARTY_NOTICES.md`。
2. HDMI Rescue 是独立于 Network Receiver 的故障域，应从 Receiver 启动后尽早就绪、保持 warm standby。网络、音频及任何附加模块故障不得让救援进程失效。网络失败进入 Rescue Lock，LCD 必须 Awake；HDMI 无帧、黑屏、NO SIGNAL 或反复协商不得触发自动关屏。远程设置不得停止或破坏救援；明确人工关 LCD 只覆盖显示保活，不关闭救援服务。两路仍共享 iMac、macOS 图形会话、LCD 和电源；这些边界须如实标注。
3. 每项新功能先证明不会降低 Catalina 上的基本显示与 HDMI Rescue 稳定性。新增服务须能单独停用、重启或失败；不把它们放入救援进程。未经目标 iMac 实测的能力只能标为目标或实验。
4. Display Sleep / Display Off ≠ iMac System Sleep；ReVoyage 只主动控制 LCD，Receiver、网络监听及已启用的 SSH/Storage/Server Mode 继续工作。`NORMAL` 允许亮度、同步 Mac mini display sleep 与自动节能；`MANUAL_DISPLAY_OFF` 是独立人工意图。不能假定短按 iMac 电源键只关 LCD，本地关屏方式后续研究。具体电源行为必须在 Catalina 真机验证。

## Core — 基本显示与安全底线

2026-10-03 再次审查：先贯通真实 1080p／1× profile、尺寸匹配与可靠亮度命令，再接入统一双向带宽模型和界面。Sender 当前容量定义会再次保留 15%，须与预览统一；原生 SMB 尚未受控。随后补性能观测、声音故障隔离、健康模式电源同步及私有版本快照。具体发现、复现和验证见 [ProjectReview-2026-10-03.md](docs/ProjectReview-2026-10-03.md)。本次仅审查和文档更新。

2026-10-02 带宽分配 UI 已确认：采用用户当前查看的“紧凑列表”，包含双向带宽池、六通道配额、三种预设、闲时共享／固定上限和超额门禁。真实限流尚未接入，尤其 SMB 硬盘／SD 独立限速需验证执行机制；示例配额不等于生产默认值。详见 [带宽分配 UI 定稿](docs/BandwidthAllocationUI.md)。

2026-10-02 Studio Display 差距审查与亮度新需求：用户已确认目标为 iMac 21.5 Late 2015 非 Retina，原生 1920×1080，默认方向为 1080p60、1×。Sender 已有基本亮度滑块和系统虚拟显示登记，但背光结果／实际值回读、内屏定向、自动亮度状态尚未完成；Receiver 面板能力仍固定为 5K，须改为真实面板能力。先交付可靠 Sender 背光控制，Mac mini 系统显示设置的原生亮度控制另做可行性原型，未验证前不承诺。完整差距、源码依据及验收顺序见 [StudioDisplayGap-2026-10-02.md](docs/StudioDisplayGap-2026-10-02.md)。这些是待做事项，本次审查未改生产代码。

| 能力与验收方向 | 当前状态 |
| --- | --- |
| 现代 Apple Silicon Sender → 直连千兆以太网或雷电网络 → Catalina Receiver；低延迟、高画质、稳定音视频；镜像和扩展显示 | Test8 有专用 1080p60 H.264 / 50 Mbps 档、Sender 队列限制/最新捕获合并，以及 Receiver 每次 socket drain 只提交最新解码纹理；第一代目标仍是稳定 25–35 ms，优秀下限约 20–25 ms；双机端到端性能尚无实测 |
| MS2130S 等 UVC/UAC HDMI Rescue 独立进程、尽早待命，救援可见性和可靠性优先；断网、Sender/Mac mini 重启/更新、FileVault/Recovery 等场景亮屏等待 | 独立 AVFoundation Rescue、采集恢复与待命已有代码；Rescue Lock、连续 2 秒恢复和无信号亮屏等待已实现。HDMI 锁定及内容识别仅用于呈现／诊断，不作为救援关屏依据；故障场景仍待实测 |
| Receiver appliance：一键配置、自动登录选项、开机/登录自启、全屏、隐藏菜单栏/Dock/指针、watchdog 崩溃恢复、无键鼠运行 | 一键安装脚本、登录后自启、全屏、隐藏指针和 KeepAlive 拉起已有基础；自动登录由用户在 macOS 设置中单独配置，可靠性待实测 |
| Sender 主控的版本化、向后兼容配置协议；Receiver 本地 Last Known Good，离线可启动，Sender 新版不强制升级 Receiver LTS；救援参数受本地安全约束 | 测试版 3 支持 v1/v2 协商；配对 HMAC、ACK、原子 LKG 同步语言/亮度/音量/休眠时长。新旧组合和重启恢复待双机验证 |
| 电源状态机：`NORMAL → 网络失败 → RESCUE_LOCK`；HDMI 活动显示、无信号亮屏等待；网络稳定恢复才解锁；`MANUAL_DISPLAY_OFF` 可人工覆盖，主机不休眠 | 已实现锁存、连续 2 秒实际帧恢复、人工关屏／唤回与断言协调；旧 LKG 无信号时间不再控制电源。75 项状态检查和真实控制器的电源替身回归通过；健康模式节能同步与真机验收待完成 |
| Mac mini 系统音频经网络到 iMac 扬声器，保留 TargetBridge Audio Relay；音频故障不影响视频/救援 | 基础音频链路在测试版 2 中；隔离和音画同步待验证 |

**Core 下一道验收门槛：**当前 D-020 锁存、恢复门槛、人工状态和失败保护已落到代码并完成本地回归；用当前同步重建的预览包，经授权在 M4 Mac mini/macOS 27 与 iMac 21.5 Late 2015/macOS 10.15.7 上验证网络拔线／崩溃、HDMI 无信号／反复协商、连续 2 秒恢复、人工关屏／唤回、重启安全状态和后台服务保活，以及 `docs/HardwareAcceptance.md` 中的显示、音频、存储项目。旧测试说明中的“双路无信号睡眠”是历史预期，不适用于当前 Test8。静态构建不代表真机门槛已通过。

**Network Display 低延迟验收：**以用户已确认的 iMac 21.5 Late 2015 非 Retina／1920×1080 为第一代 Receiver（CPU／GPU 待核对；i5-5250U／HD Graphics 6000 为此前性能分析参考），按“宁可丢帧，不显示过期帧”验收。Test7 已把 Sender 侧采集队列、编码中帧与待发送包设为 1，并在捕获回调与编码队列间合并待处理帧；Test8 Receiver 在一批网络读取期间仍顺序解码参考帧，但只提交批次中最新纹理。下一步记录 Sender capture、encode、待发送包、网络接收、decode、待呈现帧与显示提交的耗时/深度，并在积压场景检查帧年龄。稳定目标为 25–35 ms；35–50 ms 可接受但要优化；超过 80 ms 先查整帧缓存。默认方向是 H.264 VideoToolbox 硬解、无 B-frame/重排和 look-ahead、短 GOP，千兆 LAN 40–80 Mbps。协议需明确 BT.709/其它 primaries、transfer、matrix、full/limited range；capability probe 需报告真实硬件解码状态。目标值未在目标机实测前不得作为性能承诺。H.264 参考帧具有依赖，丢帧必须保持解码正确性；不可解码地任意跳过参考帧。

## Near-term — 可独立关闭的硬件桥接

| 能力 | 首轮范围与约束 |
| --- | --- |
| Storage Bridge | iMac 内部 HDD/SSD 通过 macOS SMB 等成熟文件共享；Sender 提供 `Mount iMac Storage`。Test4 提供需显式启用的私有 `ReVoyageStorage` 文件夹共享；目标机 SMB 验证待做。测试机 1 TB 5400rpm HDD 只作辅助存储，并提示不能作为唯一备份；不做网络块设备模拟。 |
| SDXC Bridge | Test6 的独立 Storage Watcher 进程在 TCP 54322 通过独立挑战认证，每 5 秒枚举 removable/ejectable 本地卷并只发送有变化的版本化快照；Sender 即使未开视频会话也可查看。用户仍须先在 Receiver File Sharing 显式共享该卷并使用同名共享；Guest 不会自动开启。内置 SDXC 枚举与 Catalina 实机行为待验证；当前只支持一个 Sender 连接。 |
| Camera Bridge | 仅在 Sender 明确请求时启用 iMac FaceTime Camera，先实现采集、传输、授权与隐私状态；摄像头服务独立于显示与救援。2026-10-02 源码及本地验证完成：配对、授权、隐私菜单、720p20 JPEG、有限队列；真实设备和签名后系统激活待验收 |
| Microphone Bridge | iMac 内置麦克风反向传输，先验证采集与网络音频；麦克风服务独立于显示与救援。2026-10-02 源码及本地验证完成：48kHz 单声道 PCM、有限积压、输入 HAL 驱动；真实格式和长期时钟待验收 |
| Advanced / Hacker Mode | 按 2026-10-08 用户要求，本机 Receiver 安装尝试授权开启 macOS Remote Login/SSH，支持状态核实与单独重试；Sender 可打开/复制 SSH 命令、打开 Screen Sharing 和 SMB 位置。Screen Sharing、自动挂载与 SSH key 配对待做 |

## Long-term — 完整的第二次生命平台

| 能力 | 目标 |
| --- | --- |
| 系统级 Camera/Microphone Bridge | Sender 将远端设备提供给 FaceTime、Zoom、微信、OBS、浏览器等选择，设备名分别为 `ReVoyage — iMac Camera`、`ReVoyage — iMac Microphone`；CoreMediaIO 扩展与 HAL 驱动及安装卸载源码已完成，用户暂无开发者团队；签名、系统激活和应用兼容性待验收 |
| Server Mode | iMac 同时承担文件、Git、Web、下载等轻量服务；LCD 睡眠时后台仍运行；服务故障不能影响显示/救援 |
| Receiver LTS 生命周期 | 稳定的版本化协议、兼容性测试矩阵、依赖更新、安装/卸载与故障诊断；Catalina 用户达到“下载 → 安装 → Setup → 使用” |
| 其它 I/O | 逐步评估 USB 外设共享，但不得增加核心显示路径的单点故障 |

## Experimental — 可探索但不进入 Core 依赖链

- OCLP 安装新 macOS 的兼容性与开发者用法；OCLP 永不成为 ReVoyage Core 前置条件。
- USB 设备转发、虚拟化与更高分辨率/帧率传输，先验证许可、权限、稳定性和性能。
- Sender 120Hz 虚拟显示/捕获、在 Sender 侧选择新鲜源帧，再以 60fps 编码发送给 60Hz Receiver；此实验用于降低源帧等待，不能增加 Legacy Intel 的解码帧率或队列长度。先验证虚拟显示模式和整体输入到光子收益。
- “开放、可编程、可 SSH 的 Studio Display”高级工作流；按 2026-10-08 用户要求，本机 Receiver 安装尝试授权开启 SSH，其他系统远程服务由用户显式启用。

## 依赖与发布检查

- 随包 FFmpeg、SDL 等的版本、来源、许可、构建选项、源码提供方式及最低 macOS 版本持续写入 `THIRD_PARTY_NOTICES.md` 和 `CATALINA_BACKPORT.md`。
- 任何正式发布前，在目标 Catalina iMac 验证依赖加载、H.264 VideoToolbox 实际硬解、帧队列/帧年龄、同步呈现、网络音视频、MS2130S/UVC、断网与崩溃后的 Rescue Lock 保活、HDMI 无信号／重协商、网络稳定恢复，以及正常节能／明确人工关屏且主机不休眠；用端到端捕获到光子测量核对 25–35 ms 目标，并明确标注未验证场景。
