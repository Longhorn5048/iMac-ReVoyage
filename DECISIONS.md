> 历史／技术记录：当前 Alpha 状态、安装与连接方式以 [README](README.md) 为准。
> Historical / technical record: consult the README for current Alpha status and setup.

# 决策记录

记录已定方向与待验证假设；若变更，保留原决定和理由并注明日期。

## D-001：以 TargetBridge 3.3 为起点（2026-09-30）

上游基线 `1052e36`；保留 MIT 原许可与版权。先移植 Receiver，Sender 保持现代 Apple Silicon/macOS 14+，避免同时回移两端。

## D-002：千兆以太网为正常链路（2026-09-30）

按用户要求，不把 Thunderbolt Bridge 当作默认路径。上游 Network Link 已有 TCP 与发现基础，但仍为实验功能；以实测证据决定能否升为默认。网络异常不得阻塞应急链路。

## D-003：HDMI/UVC 为独立应急链路（2026-09-30）

MS2130S 作为采集设备输入到 iMac，由独立 Rescue 进程预览；不能只作为网络 Receiver 的第二输入分支，否则网络进程崩溃会同时丢失救援。实际 UVC/UAC 格式、延迟和 HDMI 音频待硬件枚举验证。现阶段不承诺 4K/5K 应急输出。

## D-004：先做 Catalina 可行性门槛（2026-09-30）

不立即下调部署目标或大改源码。先固定可在 10.15 加载的依赖、检查二进制，再做 iMac 实机解码/显示/音频验证。11.0 构建声明只是可见阻碍；第三方 dylib 和 GPU 才是主要不确定性。

## D-005：Sender 主控 + Receiver LKG（2026-09-30）

Receiver 只接受校验并成功应用的版本化设置，持久保存最后成功快照；离线时继续启动与应急显示。测试版 2 的 schema v1 同步语言、亮度和音量；分辨率、码率、音频路由、休眠等继续分批纳入。

## D-006：显示睡眠与系统睡眠分离（2026-09-30）

历史决定：双路无信号时允许 Display Sleep，但接收进程仍需持续侦测信号。活动期间保持显示点亮，恢复时主动请求点亮；选用 Catalina 可用的 IOKit 电源断言并在实机验证。

2026-10-02 更新：上述“双路无信号自动关屏”准则由 **D-020** 取代。Display Sleep 与 System Sleep 分离的约束继续有效；网络失败进入 Rescue Lock，禁止自动关屏，人工 Display Off 是明确例外。

## D-007：测试版 1 使用经典 SDL2 与固定 FFmpeg（2026-09-30）

采用 SDL2 2.32.10（zlib）与 FFmpeg 7.1.3（仅所需解码组件、LGPL 配置）交叉编译 x86_64/10.15，并随包提供相应源码归档。避免现行 Homebrew `sdl2-compat → SDL3` 运行时依赖链。若 Catalina 实机不兼容，先修依赖或 API，再考虑更换框架。

## D-008：首版救援用独立 AVFoundation App（2026-09-30）

Rescue 与网络 Receiver 分属不同进程，使用系统 AVFoundation 捕获 UVC/UAC。网络窗口仅在收到视频帧时盖在救援窗口之上，停帧后退出。此方案仍共享 macOS/屏幕，实际无 HDMI 信号判断待测。

## D-009：从显示器扩展为旧 iMac 再利用平台（2026-09-30）

长期理念为 **Give your old iMac another voyage.**，依次复用 Display、Speakers、Camera、Microphone、Storage、SDXC、Network 与 Compute。`ROADMAP.md` 按 Core / Near-term / Long-term / Experimental 记录优先级。新增模块必须独立于 HDMI Rescue 故障域，并以 Catalina 基本显示与救援稳定性为合入门槛；这不要求单个测试版一次实现所有能力。

## D-010：Receiver LTS、可选服务与依赖边界（2026-09-30）

Catalina 10.15.7 是 Receiver LTS 最低支持目标；核心不依赖 OCLP 或 Receiver Homebrew，必要 runtime 随包，第三方分发记录持续维护于 `THIRD_PARTY_NOTICES.md`。Sender 设置协议版本化并兼容旧 Receiver，远程配置不得关闭救援。按 2026-10-08 用户新要求，本机 Receiver 安装尝试通过系统管理员授权开启 SSH，失败可单独重试且不影响核心，远程更新保留已有 SSH 设置；Screen Sharing 等其他系统高级服务仍由用户显式启用。Storage/SDXC 首选 SMB 共享卷，旧硬盘不能作为唯一备份。Display Sleep 不等于主机睡眠，以便 Server Mode 继续运行。

## D-014：Storage Bridge 先使用私有 SMB 文件夹（2026-09-30）

首轮共享在当前 Receiver 账户主目录所在磁盘创建专用 `ReVoyage Storage` 文件夹，不直接暴露整块卷或主目录。Receiver 用户显式运行 setup 脚本并授权 `sharing` 修改；共享只使用 SMB、关闭 Guest、保持当前账户文件权限。Sender 直连固定共享名 `ReVoyageStorage`。停用只撤销该共享并保留数据。SDXC 卷通知/共享单独实现，不让可移动介质自动暴露；不模拟网络块设备。

## D-015：MS2130S 厂商扩展控制保持实验状态（2026-09-30）

评估过 hsdaoh 对 MS2130/S 系列的 USB HID 扩展单元访问。其源码标注 GPL-2.0-or-later，项目说明 macOS 构建尚未测试；当前实现读写芯片寄存器，但没有找到可直接复用且稳定承诺的通用 HDMI-lock API。暂不把其代码或 libusb/libuvc 依赖加入 Catalina 核心。后续可在确认目标采集卡型号、授权兼容方案与实际状态寄存器后，作为可选独立适配器重新评估。

## D-016：可移动卷只通知，不自动共享或挂载（2026-09-30）

Receiver 通过 macOS mounted-volume 元数据枚举 removable/ejectable 本地卷，只将 schema 版本、卷 UUID 和显示名称同步给已连接 Sender，不传本机挂载路径。快照只在 Sender 用配对密钥成功完成设置 HMAC 后发送。Sender 的卷名按钮打开对应 SMB 共享；用户须先在 Receiver 显式开启该卷的 File Sharing 并配置同名共享。这样插卡本身不会扩大 SMB 暴露面，也不需要打开 Guest。首版覆盖 SDXC 及其它 macOS 标记为 removable/ejectable 的卷；内置 SDXC reader 在 Catalina 上实际标记仍待验证。快照沿用未加密的 TCP 会话，认证不提供传输机密性。

## D-017：存储枚举使用独立服务与 TCP 端口（2026-09-30）

Test5 的卷扫描仍依赖 Network Receiver 的事件循环和视频会话。Test6 将枚举器移到独立 `Storage Watcher` 进程，通过 TCP 54322 接收独立的 nonce/HMAC 配对（消息域 `ReVoyageStorageMonitorV1`），每五秒检查一次并推送变化快照。它用自身 KeepAlive LaunchAgent 重启，不能依赖或控制 HDMI Rescue；不再占用显示 Receiver 的扫描周期，也允许 Sender 在没有视频会话时查看卷。采用只读快照，SMB share 仍由用户配置。首版只支持一个 Sender，明文传输仍无机密性；两项均记录为后续验证/改进点。

## D-018：Network Display 以最新帧年龄优先（2026-09-30）

第一代 Intel Receiver 的默认方向为 1080p60 H.264，Sender/Receiver 硬件编解码优先，关闭 B-frame/重排与 look-ahead，千兆以太网高质量档先测 40–80 Mbps。网络显示的目标端到端时延为稳定 25–35 ms，约 20–25 ms 是优秀下限；35–50 ms 可接受但继续优化，超过 80 ms 优先排查帧队列和旧帧积压。所有数字是工程目标/估算，未经 M4 Mac mini + Catalina iMac 实测，不构成性能承诺。

选择“宁可丢帧，不显示过期帧”：缩小每个流水线边界的缓冲，编码前跳过过时源帧，Receiver 只保留最新待呈现解码帧，并贴近显示刷新节奏提交。由于 H.264 帧有参考依赖，不能任意丢弃已进入解码器的压缩参考帧；过载时仍需维护解码链，必要时恢复到 IDR，而不是把 FIFO 旧帧显示完。Sender 120Hz 源捕获 + 60fps H.264 编码列为实验项，收益是更低源帧年龄，不增加 Receiver 解码帧率。颜色 metadata 与硬件解码实际状态必须显式传递/观测。

源码审计发现原 Sender 档位使用 queueDepth=2、最多 5 个编码中帧和 3 个待发送视频包；原平滑 H.264 档为 1440p / 52 Mbps。Test7 已加入单独的 1080p60 / 50 Mbps H.264 档，将采集队列、编码中帧与待发送包分别限制为 1，并在 ScreenCaptureKit 与编码队列之间以 latest-value slot 合并采集回调；旧档位行为保持不变。Test8 Receiver 仍顺序解码 H.264，但在一次 socket drain 中以 SDL 纹理覆盖中间帧，待 socket 读空后只呈现最新解码帧；没有引入独立播放队列，也没有开启 VSync。接下来先加阶段时延和帧年龄观测，再按目标机结果调整呈现与同步策略；不以平均 FPS 推断输入到显示延迟。目标 iMac 的实际时延、VideoToolbox 硬解、颜色与丢帧行为都需实机验证。

## 未决问题

- 精确 iMac 年款、GPU 和 macOS 版本、MS2130S 商品与固件、USB 端口带宽。
- 正常/应急目标分辨率、帧率、延迟、音频输出设备及音画同步验收值。
- Rescue Lock 已采用连续 2 秒恢复，启动／重启亮屏，人工状态不持久化且通过 Sender 显式唤回；这些电源行为待 Catalina 真机验收。本地物理控制、正常节能同步及更广设置字段的冲突处理仍待研究。HDMI 信号变化不解除锁存。
- 是否需要自动登录：登录自启只能在图形用户会话建立后运行；开机到登录前显示需要另行定义且可能受系统限制。

## D-011：设置同步使用每 Receiver 配对密钥（2026-09-30）

测试版 2 用每连接随机 nonce、单调发送 revision 与 HMAC-SHA256 验证 schema v1 设置包。安装时生成 256-bit 配对密钥；Receiver 以权限 0600 保存，Sender 存入 Keychain。配置仅含亮度、音量、语言，不包含 HDMI Rescue 开关。LKG 临时写入并 fsync 后原子替换；保存成功后才应用与 ACK。该设计只认证新配置包，当前 TCP 视频/音频未加密，且仍需双机端到端验证。

## D-012：以挑战扩展协商设置协议 v2（2026-09-30）

Receiver 挑战继续以 schema v1 为基础，并增加可选的 `supportedSchemaVersion`。未识别该字段的旧 Sender 仍会发 v1；新 Sender 与新 Receiver 协商到 v2 后同步 15–3600 秒无信号休眠策略。v1 的 HMAC 56-byte 布局不变；v2 附加 4-byte 大端整数。LKG v2 接受 v1 文件并在下一次成功写入后升级。该协议向后兼容行为由 Sender 单元测试固定；双机旧/新版组合仍须回归。

2026-10-02 适用范围更新：按 D-020，已有休眠秒数字段仅可用于健康 Network Mode 的正常节能，不得在 Rescue Lock 下关屏。人工 Display Off 是独立的明确意图，不能由旧字段推断；独立已配对命令与关联 ACK 已实现，旧字段当前不再驱动电源。

## D-013：由 Rescue 进程负责显示电源仲裁（2026-09-30）

历史实现：Network Receiver 每秒发送本机网络视频状态；独立 Rescue 对过期心跳和 UVC 帧做超时判断。活动期间两进程分别持有显示防空闲断言；无帧阈值到期后 Rescue 使用系统 `pmset displaysleepnow` 关闭显示，并使用 IOKit 活动声明唤醒。Rescue 还防止主机空闲睡眠。选择系统自带 CLI 与公开 IOKit API，避免 Catalyst 依赖私有 DisplayWrangler 接口。无 HDMI 输入但采集卡仍输出黑帧的情况下，通用 UVC 帧流无法识别信号锁定；此边界必须先用目标卡实测。

2026-10-02 更新：保留独立 Rescue 的本地仲裁与防主机睡眠职责；“无帧阈值到期自动关屏”由 D-020 的锁存规则取代。HDMI 有效性检测仅服务呈现／诊断，不参与 Rescue Mode 的关屏决策。实现时统一协调双方显示断言与人工关屏，不能让旧 LKG 超时破坏救援保活。

## D-019：以 Studio Display 体验为核心目标（2026-10-01）

用户明确本 App 的目标是把 iMac 变成一台 Studio Display。核心是稳定、低延迟的显示与扬声器，以及 iMac → Sender 的摄像头/麦克风共享。Receiver 登记本机物理设备，Sender 使用远端信号并向系统提供虚拟设备；附加服务不能挤占这些核心交付。

连接限定雷电或千兆网线，取消加密开发，保留配对认证。两端必须有完整卸载入口，清理所属应用、启动项、凭据、设置、缓存和日志；用户存储文件及系统物理设备保留。Catalina Receiver 与独立 HDMI Rescue 的兼容和故障隔离继续有效。

## D-020：网络失效锁存 Rescue Lock，救援可见性优先（2026-10-02）

用户更新电源原则：**正常链路负责聪明、舒服和节能；救援链路负责简单、顽强和永远有机会显示。HDMI Rescue 的目标优先级是可见性和可靠性，而不是自动节能。** 本决定取代 D-006／D-013 中“双路无信号 → Display Sleep”的电源准则；保留历史记录；锁存、连续 2 秒恢复和已配对关屏／唤回已实现于当前源码及重建 Test8，真机电源行为待验收。

1. `NORMAL`：网络主链路健康时，允许 Sender 控制亮度、明确请求 `Turn iMac Display Off`、同步 Mac mini display sleep 与正常自动节能。须区分受控节能状态与异常停帧，不能把未经确认的传输丢失当作空闲。
2. `NETWORK LOST → RESCUE MODE → RESCUE_LOCK`：网络视频异常、Sender 崩溃、网络断开或健康状态过期后，立即露出 MS2130S/UVC HDMI Rescue，唤醒 LCD 并强制保持 Awake。HDMI 无信号不等于 Mac mini 不需要显示；重启、更新、Firmware transition、FileVault、Recovery、GPU 初始化、HDMI handshake 和分辨率切换都可能暂时无画面。
3. Rescue 是锁存状态：HDMI 活动则显示，HDMI 不活动则亮屏等待，反复断开／恢复／重新协商均不改变锁存。只有已认证网络主链路持续稳定恢复才回 `NORMAL`，建议连续 1–2 秒新鲜可呈现视频；单帧、socket 或心跳不能单独解锁，恢复中再次异常重置计时。
4. 黑屏、NO SIGNAL、perceptual hash 或 HDMI-lock 元数据只可用于状态显示和诊断，**不得参与 Rescue Mode 的 Display Sleep 决策**。
5. `MANUAL_DISPLAY_OFF` 是用户明确要求关 LCD 的人工状态，可覆盖 Rescue Lock 的保活要求，但不停止救援或其它后台服务。正常模式增加 Sender 入口，继续要求配对认证；Rescue 本地控制方式后续研究，不依赖 Sender 可用。人工唤回使用 Sender 同一会话的显式按钮；人工状态只存内存，断线保持已完成关屏，Network 或 Rescue 重启即清除并亮屏等待。未确认、失败或过期请求恢复亮屏；显示帧及 HDMI 重连不能取消人工状态。系统本地输入可能自行唤醒 LCD，恢复常驻保活应显式点“唤回”。
6. `Display Sleep / Display Off ≠ iMac System Sleep`：ReVoyage 只主动控制 LCD；Receiver、Network listener、SSH、Storage Bridge、Server Mode 等已启用服务继续运行。不得将短按 iMac 实体 Power Button 只关闭 LCD 作为架构前提，它可能触发主机睡眠、关机界面或其它电源行为。

**No input during healthy operation may sleep the display. Loss of the primary transport enters Rescue Lock and must never automatically sleep the display.** 现有配置／LKG 休眠阈值仅可用于健康 `NORMAL`，不能覆盖锁存；人工关屏必须单独表达。本轮已修改状态机、断言仲裁和协议／UI，并通过无硬件回归；正常自动节能、Sender display-sleep 同步和本地物理控制仍待研究，下一步是经授权的 Catalina 真机验收。iMac 自身未运行图形会话、系统或供电失效仍是共享故障边界，不能由 Rescue Lock 保证可见。
