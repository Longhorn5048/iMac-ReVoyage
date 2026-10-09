2026-10-03 修复交付：真实面板／1×、背光校验与回读、双向应用带宽界面、包级限额、声音静音隔离及接收端指标已接入。141 项 Sender 测试和原生替身／媒体／电源／安装卸载回归通过。SMB 独立限速、自动亮度模式控制、健康节能和实机验收仍待完成。详见 [本轮修复](docs/ProjectReviewFixes-2026-10-03.md)。

# 目标架构

产品目标（2026-10-01 用户确认）：**把 iMac 变成一台 Studio Display**。屏幕、扬声器、iMac → Sender 摄像头/麦克风、稳定日用与完整卸载属于核心；仅使用雷电/千兆有线连接，取消加密开发，保留配对认证。SSH、Server Mode、USB 等附加能力排在核心之后。

电源原则更新（2026-10-02，见 D-020）：**正常链路负责聪明、舒服和节能；救援链路负责简单、顽强和永远有机会显示。HDMI Rescue 的目标优先级是可见性和可靠性，而不是自动节能。** Rescue Lock、连续 2 秒恢复门槛、人工关屏／唤回和双进程显示断言协调已落地，并纳入重建 Test8；正常模式的 Sender display-sleep 同步与本地物理控制仍待实现。Catalina 电源效果未实测。

状态：Test8 已构建，含 Test7 Sender 低延迟路径及 Catalina x86_64 Receiver 的网络读取批次呈现合并；Rescue/Storage Watcher 沿用 Test6。Sender 90 项测试通过，Receiver 已按最低 macOS 10.15 交叉构建；目标硬件性能仍未验证。网络显示、独立 Rescue、配对设置同步/LKG、双输入帧状态仲裁、LCD 睡眠/唤醒、显式 SMB 文件夹共享及独立可移动卷监视已实现并交叉构建。Storage Watcher 是独立登录进程，Sender 无需视频连接即可接收卷状态。UVC 帧流不能证明 HDMI 电气锁定，采集卡持续输出黑帧时仍会误判为活动输入。长期方向是 **Give your old iMac another voyage.**，但附加模块不得降低 Catalina Receiver 和 HDMI Rescue 的稳定性。

## 长期模块边界

| 模块 | 目标与故障边界 | 当前状态 |
| --- | --- | --- |
| DisplayShell：HDMI Rescue、Network Display、Input Switcher、Sleep/Wake | HDMI Rescue 独立进程、尽早待命；网络失败锁存 `RESCUE_LOCK`，LCD 保持 Awake，HDMI 无信号也持续等待；人工关屏可覆盖锁存，主机继续运行 | 已实现启动／失效锁存、无 HDMI 亮屏等待、连续 2 秒新鲜帧恢复与人工关屏／唤回；旧无信号超时不再驱动关屏。Catalina 电源行为待实测 |
| Audio Bridge | Sender 系统音频到 iMac 扬声器；音频故障不影响视频与 Rescue | 沿用 TargetBridge 音频基础，隔离待验证 |
| Camera / Microphone Bridge | iMac 采集后反向传到 Sender，由 Sender 提供系统虚拟摄像头/麦克风；仅明确请求时开摄像头，遵守系统授权 | 独立 MediaBridge 进程，TCP 54323 双向配对；Sender CoreMediaIO 摄像头扩展与 HAL 麦克风源码已完成，签名激活及目标机验收待做 |
| Storage / SDXC Bridge | 通过 SMB 等共享卷和 Sender 一键挂载；SD 卡插入通知；旧硬盘不得作为唯一备份 | Test4 有独立显式 setup/disable 脚本，创建 Guest 关闭的 ReVoyageStorage 文件夹共享。Test6 将 ObjC 卷枚举放在独立 Storage Watcher 进程，每 5 秒查 removable/ejectable 卷，TCP 54322 使用独立配对挑战；Sender 无需视频会话即可查看 schema 1 快照。卷的 SMB 发布仍由 Receiver 用户显式配置；SDXC 读卡器及 Catalina 行为未实测，不模拟网络块设备 |
| Advanced Services / Server Mode | 按 2026-10-08 用户要求，本机 Receiver 安装尝试授权开启 SSH；Screen Sharing 由用户启用；LCD 睡眠时主机服务继续运行 | Sender 已有连接/复制 SSH、打开 vnc:// 与 smb:// 的入口；安装器核实 SSH 状态并支持单独重试，远程更新保留系统设置；SDXC、SSH key 和 Server Mode 管理待实现 |

## 可移动卷快照

Storage Watcher 作为独立的 `re.voyage.storage` 登录服务运行，与 Network Receiver 不共享进程或事件循环，Rescue 则由自己的 LaunchAgent 更早启动。Watcher 使用 `tb_storage_bridge.m` 读取 macOS mounted-volume resource keys，筛选 removable/ejectable 卷并生成有界、排序的 schema 1 快照（最多 32 项，只含卷 UUID 和名称）。它只在独立 TCP 54322 会话中每 5 秒检查一次，连接后先发送首份快照，随后只在列表变化时发送 type `0x43`；type `0x41` 下发 32-byte 随机挑战，Sender 以每 Receiver 配对密钥和独立域 `ReVoyageStorageMonitorV1` 计算 HMAC-SHA256，再以 type `0x42` 响应。旧 Test5 Sender 会话里的 `0x38` 快照接收仍保留在 Sender 以兼容已有 Test5 Receiver；Test6 Receiver 不再在显示链路中扫描或发送该包。

Sender 校验 schema、UUID 唯一性、名称长度与控制字符，显示列表；用户点按时按共享名打开 `smb://<Receiver>/<volume name>`。Receiver 不自动发布 SMB share、不给 Guest 权限，也不传递本地文件路径。快照使用明文 TCP，HMAC 只认证客户端，不加密连接；SD 卡卷仍需用户在 macOS File Sharing 中显式共享。Watcher 一次接受一个 Sender，只有用户图形会话登录后启动；这不是 FileVault 预登录或 Recovery 下的服务。

OCLP 只是高级用户可选择的兼容路径，核心不依赖。USB 外设共享属于后续探索；摄像头/麦克风的系统级虚拟设备属于核心待交付项，具体优先级见 `ROADMAP.md`。各附加服务应能独立停用和恢复；即使服务失败，也不能通过共享进程、配置写入或启动依赖拖死救援。所有路径仍共享同一 iMac/macOS/LCD/供电，这一物理边界无法由进程隔离消除。

## 边界

| 组件 | 运行位置 | 职责 |
| --- | --- | --- |
| Sender | 现代 Apple Silicon Mac | 捕获桌面与系统音频、编码、通过有线千兆以太网发送；作为设置主控并向 Receiver 推送版本化配置。另以 HDMI 输出应急画面/声音。设置同步配对凭据存入 Sender Keychain。 |
| Network Receiver | Intel iMac / Catalina 10.15.7+ | 复用并移植 TargetBridge Receiver：网络收包、硬解码、全屏呈现、音频播放和健康状态。 |
| Rescue Receiver | 同一 iMac，**独立进程与采集链路** | 从 MS2130S 的 UVC/UAC 设备采集 HDMI 图像和声音；无需 Sender 网络协议、Network Receiver 进程或网络配置即可工作。 |
| Storage Watcher | 同一 iMac，独立 LaunchAgent / TCP 54322 | 配对认证后监视 removable/ejectable 卷；不依赖视频流。故障由自身 KeepAlive 恢复，不参与显示或 Rescue。 |
| Appliance Supervisor | 同一 iMac，登录图形会话 | 一键配置启动项、崩溃拉起、前台源仲裁、显示电源策略、状态提示。它不能成为 Rescue 的单点依赖：Rescue 应能自行检测网络失效并保持/恢复呈现。 |
| Local config | 同一 iMac | 原子保存经校验的 Last Known Good（LKG）设置；Sender 离线、重启或新配置无效时继续使用。 |

## 视频与故障域

正常路径：Sender 捕获/编码 → 独立千兆网口 → TCP → Network Receiver → iMac 屏幕与扬声器。

应急路径：Sender HDMI 输出 → MS2130S → USB UVC/UAC → Rescue Receiver → 同一屏幕与扬声器。应急路径不读取网络画面，不要求 TCP/Bonjour、Sender App 或 Network Receiver 存活。独立 AVFoundation App 实现采集；会话运行错误、中断及设备拔出时停止旧会话并尝试恢复。两条路径共享 iMac、屏幕、macOS 图形会话和电源，不能声称对这些共同故障完全独立。

输入检测与恢复：Network Receiver 只在认证会话的新纹理完成 SDL 提交后更新帧时间，并每秒发布本机 `network-recovering`／`network-active`／`network-inactive` 通知及实际 `frameMs`。同一纯 C 状态机由 Network 与独立 Rescue 使用，启动默认锁存；停帧 2 秒或断开锁存并让出画面。恢复至少连续 2 秒，帧进展间隔不得超过 1.5 秒；Rescue 接收的帧必须不旧于 500 ms，重复／倒退／未来帧不能解锁。正常心跳、单帧和旧通知不能累计恢复。恢复中的网络窗口在 appliance 模式保持隐藏，网络扬声器静音；HDMI 继续显示及出声，稳定后接管。Rescue 的通知超时为 3.5 秒，实际网络帧有效期为 2 秒，UVC 帧有效期为 2 秒。窗口与采集独立于 LCD 开关。

### Rescue Mode 电源状态机（2026-10-02 新设计，待实现）

**No input during healthy operation may sleep the display. Loss of the primary transport enters Rescue Lock and must never automatically sleep the display.** HDMI 无信号不等于 Mac mini 已经不需要显示。

| 状态 | LCD 与控制规则 | 状态变化 |
| --- | --- | --- |
| `NORMAL` / Network Mode | 网络主链路健康时允许 Sender 调亮度、明确关屏、同步 Mac mini display sleep 和正常自动节能；只控制 LCD | 网络视频异常、Sender 崩溃、连接断开或健康通知过期 → `RESCUE_LOCK`；用户明确关屏 → `MANUAL_DISPLAY_OFF` |
| `RESCUE_LOCK` / Rescue Latched | 立即露出 MS2130S/UVC Rescue，唤醒 LCD 并保持 Awake；HDMI 有画面则显示，无画面则保持亮屏等待；HDMI 断开、恢复和重新协商不解除锁存 | 只有网络稳定恢复后回到 `NORMAL`，连续稳定窗口建议 1–2 秒；用户明确关屏可覆盖锁存 |
| `MANUAL_DISPLAY_OFF` | 用户主动关闭 LCD，覆盖 Rescue 保活；Receiver、监听器及已启用的后台服务继续运行；不停止 Rescue 采集与恢复能力 | Sender 显式唤回后按网络健康状态回到 `NORMAL` 或 `RESCUE_LOCK`；人工状态只在内存中保留，任一显示服务重启清除并亮屏 |

- Rescue Lock 是锁存状态。系统重启、macOS 更新、Firmware transition、FileVault、Recovery、GPU 初始化、HDMI handshake 或分辨率切换导致的暂时无画面，都不得触发自动 Display Sleep；HDMI 可反复断开／恢复，Receiver 持续等待。
- 稳定恢复须证明已认证的网络主链路持续正常输出新鲜可呈现视频；单个帧、socket 已连接或仅有心跳不足以解锁。恢复窗口中再次异常应重新计时，具体阈值待实现及验收。
- 正常节能与传输故障须有明确不同的状态依据：健康会话中的受控 display sleep 不应被误判为故障；未经确认的停帧／断链不得沿用“双路无信号超时”自动关屏。
- 黑屏、NO SIGNAL 识别、perceptual hash 和 HDMI-lock 元数据可用于状态显示及诊断，**不得参与 Rescue Mode 的 Display Sleep 决策**，也不能解除 Rescue Lock。
- 人工关屏必须来自明确用户操作；正常模式 Sender 入口为 `Turn iMac Display Off`，保留配对认证门禁。Rescue 模式不能依赖 Sender 才能关屏，本地控制方式后续研究；第一版不依赖 iMac 电源键。实体 Power Button 可能触发主机睡眠、关机界面或其它电源行为，不等于显示器开关键。
- **Display Sleep / Display Off ≠ iMac System Sleep。** ReVoyage 只主动控制 LCD；所有模式均需保持主机运行，让 Receiver、Network listener、SSH、Storage Bridge、Server Mode 等已启用服务继续工作。人工关屏只覆盖 LCD 保活要求，不关闭救援服务。
- 只有显式人工关屏调用 `/usr/bin/pmset displaysleepnow`，由 Rescue 执行；Network 同时释放自己的显示断言并允许 SDL screensaver，避免相互抵消。Rescue 的防主机空闲睡眠断言始终保留。人工状态不写 LKG；两进程启动／重启握手选择亮屏，完成或取消前的请求不跨连接复用。关屏执行失败、5 秒过期或迟到的旧操作按当前意图恢复亮屏。

边界仍是同一 iMac/macOS 图形会话/LCD/供电：上述重启、更新、FileVault、Recovery 首先指 Sender/Mac mini 的过渡画面；若 iMac 自身未进入可运行 Rescue 的图形会话，进程保活无法提供画面。Catalina 下电源行为与 UVC 恢复仍待实机验证。

## 配置协议和 LKG

Sender 是配置权威端，Receiver 存储最后成功应用的快照。协议 packet type `0x14..0x16` 的挑战保持基础 schema v1，并可声明支持 schema v2；老 Sender 忽略新增字段并继续发送 v1，新 Sender 只在 Receiver 声明支持时发送 v2。v1 保留原来的 56-byte HMAC 布局；v2 在后面增加经认证的无信号休眠秒数，布局为 60 bytes。当前同步语言、亮度、音量和休眠时间。Receiver 为每个 TCP 会话生成 32-byte nonce；Sender 使用配对密钥对 nonce、schema、revision 和设置值做 HMAC-SHA256。Sender 凭据存在 Keychain，Receiver 配对密钥位于 `~/Library/Application Support/TargetBridge Receiver/pairing.key`（0600）。Receiver 只接受当前会话 nonce 下经认证、revision 更新且字段在范围内的配置，先用临时文件、`fsync` 和原子 `rename` 保存 schema v2 LKG，再应用并 ACK。启动顺序是安全默认值 → 本地 LKG → 新的已认证 Sender 配置；Sender 离线时使用 LKG。

Receiver 端的本地 LKG 位于 `~/Library/Application Support/TargetBridge Receiver/settings.json`。可读取 schema v1（休眠时间回落到默认 30 秒）和 v2；无效 schema/数值、重复 revision、错误 HMAC 或落盘失败不会替换 LKG。远程设置协议没有 HDMI Rescue 开关。旧休眠字段保留用于协议／LKG 兼容，但当前 Rescue 不读取或执行它；Sender 已撤下无信号休眠设置。后续健康 `NORMAL` 节能策略须单独区分受控空闲与故障，**不得在 Rescue Lock 下执行或解除锁存**。人工 Display Off 须使用显式、经认证的命令／状态，不得把旧超时或亮度值当成人工关屏指令；对应 `0x39` 已配对关屏／唤回命令、`0x3a` 关联 ACK 与 Sender 每会话亮度区域的两个按钮已实现。请求 ID 防止迟到 ACK 确认新操作；无 Rescue 确认时显示失败，不伪称关屏成功。远程 Sender 不能禁用救援采集或关闭救援进程。TCP 视频/音频/旧控制包仍未加密，HMAC 只认证新设置包的完整性与配对来源，不提供传输机密性。

## Appliance 验收目标

一键安装/撤销登录自启；登录后全屏、隐藏指针，退出后恢复；进程异常退出后可重新拉起且避免无限崩溃循环；两路信号切换不依赖设置界面。电源验收按新状态机：网络失败即进入 Rescue Lock，HDMI 无信号、黑屏及反复协商期间 LCD 仍 Awake；网络稳定恢复 1–2 秒后才退出；明确人工关屏可覆盖锁存但主机与救援继续运行；健康 Network Mode 可正常节能。锁存、恢复防抖和人工状态的纯逻辑回归已通过；仍须经授权验证 Catalina 真机行为。测试版 1 的 LaunchAgent 有 10 秒重启限流，但崩溃循环处理尚未实机验证。首次相机、麦克风及辅助功能授权需用户在 macOS 中操作，安装器不得伪称能绕过权限提示。

## LAN Network Display：低延迟与帧年龄

本节定义第一代 Intel iMac Receiver 的实时显示目标。所有延迟数字是设计目标或工程估算，不是当前版本的实测结果。参考组合为 M4 Apple Silicon Sender 与 iMac 21.5 Late 2015 非 Retina / 原生 1920×1080 / Catalina 10.15.7 / 千兆以太网；用户已确认面板款式。默认方向为 1080p60、1×显示，捕获预设与真实面板能力分开，不伪报 5K／Retina。CPU／GPU 仍须核对；i5-5250U／HD Graphics 6000 只是此前性能分析的参考配置。

| 指标 | 目标 | 判读 |
| --- | --- | --- |
| 典型端到端输入到显示 | 稳定 25–35 ms | 第一代网络显示工程目标，需在目标双机实测 |
| 优秀下限 | 约 20–25 ms | 理想条件下的目标区间，不作承诺 |
| 可接受但需继续优化 | 35–50 ms | 检查各阶段时延与帧年龄 |
| 明显偏高 | 50–70 ms | 优先排查排队和同步策略 |
| 异常排查阈值 | >80 ms | 先检查额外整帧缓存与旧帧积压，再判断解码性能 |

账本估算：120Hz 源帧平均等待约 4 ms；M4 H.264 硬件编码约 1–3 ms；千兆以太网通常低于 1 ms；Broadwell VideoToolbox 解码约 1–5 ms；最新帧槽约 0–1 ms；60Hz VSync 平均等待约 8 ms；LCD 扫描和响应另需数毫秒。各项会受调度、帧相位和显示器特性影响，不能简单视为每台机器的保证值。

### 帧年龄优先

- 核心语义是“宁可丢帧，也不显示过期帧”。每个异步边界都要有明确且很小的上限；消费者取最新可显示帧，超过时效的待显示帧应淘汰。
- H.264 参考帧有依赖关系，不能任意删除已经发送的压缩帧而继续假定画面可解码。优先在编码前跳过过时采集帧；Receiver 即使必须顺序解码参考帧，也应只覆盖单个待呈现帧槽。解码已落后到无法追上时，应跳到可解码的 IDR/重置恢复，而不是播放不断变旧的 FIFO。
- TCP 有序传输无法撤回已排队字节，因此 Sender 的编码中帧和待发送包必须有界；拥塞时跳过后续采集帧，避免在网络恢复后补播旧画面。未来若测得 TCP 队头阻塞破坏时效，再评估独立、向后兼容的低延迟传输，不把协议更换当作未经测量的前提。
- 渲染目标为 Decode → Latest Frame Slot → Receiver VSync → Display。优先使用 Catalina 可用的低开销同步呈现路径（例如 CVDisplayLink 或经实测的 SDL swap interval），不引入媒体播放器式多级播放队列。

### 编码、捕获与码率

- 第一代 Legacy Intel 默认目标为 1080p60 H.264 4:2:0，优先 VideoToolbox 硬解兼容性与实时性。Sender 应要求实时硬件编码、关闭 B-frame/重排、禁用 look-ahead、使用短 GOP；不为压缩效率增加等待。
- 千兆 LAN 的首选质量档为 40–80 Mbps，可从约 50 Mbps 起测；100 Mbps 以上属于 Experimental。HEVC 不作为 2014–2015 Intel Receiver 首选。
- 120Hz Sender 虚拟显示/捕获是有价值的实验路径：采样 120Hz 源以降低帧年龄，再丢弃不需要的采样帧并编码 60fps H.264，Receiver 仍以 60fps 解码和显示。它不是让 Legacy Receiver 解码 120fps；相比 60Hz 源，捕获等待的理论平均收益约 4 ms，极端接近 8 ms。必须先验证现代 macOS 虚拟显示可提供 120Hz，以及降采样没有增加排队。
- Receiver capability probe 应报告设备/系统、显示尺寸与刷新率、编解码器支持、硬件解码是否实际启用、推荐流配置。应区分“框架枚举支持”与“此会话确实输出 VideoToolbox 硬件帧”。

### 颜色和可观测性

视频协议需显式携带颜色 primaries、transfer function、matrix、full/limited range 等字段，并能向旧 Receiver 安全回退；Receiver 还需正确映射 Gamma 与目标 ColorSpace/ICC。现有 Renderer 固定选择 BT.709 YUV 转换，尚未找到视频包携带这些字段的实现，不能视为颜色管理已经完成。

每阶段分别记录单调时钟耗时、队列长度、丢帧数、编码中帧、硬解帧比例和渲染帧年龄。不同 Mac 的主机时钟不能直接当作同步的一向延迟测量；端到端捕获到光子应在目标机器上用高速相机/光电方式验证，或先校正时钟偏差。不要用平均 FPS 代替延迟测量。

### 当前源码审计（目标机未实测）

- Sender 已设置 RealTime、AllowFrameReordering=false；平滑 60fps 预设设置 MaxFrameDelayCount=0，并在编码前对积压进行丢帧。Test7 新增专用 1920×1080 @ 60 H.264 / 50 Mbps 低延迟档，ScreenCaptureKit/CGDisplayStream queueDepth、编码中帧上限和待发送包上限均为 1；ScreenCaptureKit 回调先进入 coalescing latest-value slot，避免在串行编码队列前排成旧帧 FIFO。原有档位仍使用 queueDepth=2、最多 5 个编码中帧和 3 个待发送包。低延迟档每个采集帧可能被丢弃以保持帧新鲜，实机流畅度仍待测。
- 当前虚拟显示预设最高刷新率为 60Hz，捕获帧间隔跟随预设帧率；尚无 120Hz 捕获、60fps 编码的档位，也没有可见的无 look-ahead 验证或按 Receiver 能力推荐配置流程。
- Receiver FFmpeg 在可用时配置 VideoToolbox，并对 VideoToolbox CVPixelBuffer 有直接读取路径；但日志中的硬件像素格式可用不等于每会话已确认硬解，需加入实际硬件帧计数/状态。Receiver 对 H.264 的硬解能力也需单独 probe。
- 网络接收回调仍按顺序把压缩帧交给解码器以保留 H.264 参考链。Test8 在一次非阻塞 socket drain 内让每个解码帧覆盖同一 SDL NV12 纹理，读到 EAGAIN 后只提交一次最新纹理，避免在积压时逐帧提交过期画面。它只合并同一读取批次，不限制批次间的帧年龄；没有 VSync/CVDisplayLink 节奏。SDL Renderer 仍显式无 VSync，后续应先量测呈现与帧年龄，再选择同步路径，不给旧 Intel 增加媒体播放式缓冲。

### 验收顺序

Sender 侧已完成首轮低延迟档与采集回调合并；Receiver 已在 socket drain 内只提交最新已解码纹理。下一步加各阶段耗时、硬解状态、队列深度和渲染帧年龄观测，并在目标机验证这次呈现合并是否降低积压场景的画面年龄；之后评估适合 Catalina 的刷新同步路径和 120Hz 捕获 / 60fps 输出。每个改动都回归 HDMI Rescue 与稳定性，只有目标硬件实测满足时才将延迟目标升级为支持承诺。

## 上游现状与扩展点

`TBReceiverC/src/main.c` 是单进程事件循环，`net.c` 在 `INADDR_ANY:54321` 监听，`decoder.c` 通过 FFmpeg/VideoToolbox 解码，`display.c` 用 SDL 画面/声音。现有 `TB_PKT_UI_LANGUAGE`、亮度和音量属于局部远控，不是可靠配置同步；现有 `settings.json` 只保存语言。新增配置应定义独立协议和验证层，避免把整个上游事件循环一次性重写。

## 2026-10-02 媒体桥接源码交付

独立 MediaBridge 保持 Catalina Intel 支持，Receiver 只登记并按请求采集物理设备；现代 Sender 暴露系统虚拟设备。初版 720p20 JPEG / 25Mbps 负载上限与 48kHz 单声道 PCM 走独立认证 TCP；有限队列、音频积压上限和故障释放避免共享服务无限排队。摄像头过期输出黑画面，麦克风缺失输出静音，故障后显式重连。媒体隐私菜单可以本地停止共享。双端安装卸载纳入该服务和虚拟设备。用户暂无 Apple Developer 团队，完成源码和本地验证，未注册真实系统设备。带宽规划、验证证据和剩余验收见 [MediaBridge-2026-10-02.md](docs/MediaBridge-2026-10-02.md)。
