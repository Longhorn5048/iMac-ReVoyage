# iMac ReVoyage

Give your old iMac another voyage.

**Alpha 开发预览 / Alpha preview · 2026-10-09**

让旧 Intel iMac 继续当显示器用，也把它的扬声器、摄像头和麦克风用起来。
Use an older Intel iMac as a monitor for another Mac, with access to its speakers, camera, and microphone.

[中文](#中文) · [English](#english)


## 中文

### 项目状态：Alpha

iMac ReVoyage 基于 [TargetBridge](https://github.com/swellweb/targetBridge)，目前还在 Alpha 阶段。显示串流、声音、睡眠联动和独立 HDMI 救援已经写好，摄像头和麦克风接入系统的部分还在实验中。目标双机的完整测试尚未做完，暂时不能保证日常使用或生产环境中的稳定性。

目标是让旧 iMac 用起来像一台 Studio Display。它仍然使用原有硬件，包括原来的屏幕分辨率；5K 画质、Apple 产品的硬件规格和兼容性都不在承诺范围内。本项目与 Apple 无隶属关系。

这一版使用 2026-10-09 的 AudioTheme 修复版：Sender build `20261009180257`，扬声器驱动 1.2。应用与该修复版相同，发布时只整理了文档和安装包内容。

### 现在能做什么

| 功能 | 已有实现 | 还需要确认 |
| --- | --- | --- |
| 显示 | 镜像／扩展桌面、设备发现、面板识别、1080p60、自动性能降级、有限队列 | 还需在目标机器上检查画质、持续帧率、色彩和端到端延迟 |
| 扬声器 | 独立 `ReVoyage — iMac Speakers` 系统输出，音量／静音控制，按默认输出切换转发 | 还需实际加载最新驱动，检查双机发声和长时间音画同步 |
| 亮度与睡眠 | Sender 控制内屏亮度及回读、睡眠联动、唤醒重连、人工关屏 | 还需检查 Catalina 背光及长时间睡眠后的恢复；暂不承诺接入系统原生亮度滑块 |
| HDMI Rescue | 独立救援进程、断网亮屏等待、实际网络画面稳定后恢复 | 需要 HDMI 采集卡，且 iMac 已登录、服务已运行；故障切换还要实测 |
| 摄像头／麦克风 | 独立 iMac → Sender 服务；720p20 JPEG 摄像头、48 kHz 单声道 PCM 麦克风及虚拟设备实现 | 还未完成正式签名、系统激活、真实采集和通话应用测试 |
| 安装维护 | 双端安装／卸载、登录自启、Receiver 远程更新及回滚机制 | 还需实测首次安装、跨机器更新、完整卸载和长时间运行 |

### 系统与连接

- Sender： Apple Silicon Mac，macOS 14 或更新版本。
- Receiver： Intel iMac，macOS 10.15.7 Catalina 或更新版本为目标；本包为 x86_64。
- 优先测试的机型： 21.5 英寸 Late 2015 非 Retina iMac，1920 × 1080。其他机型及高分辨率档位属于实验支持。
- 连接： 雷电网络或千兆有线网络；不提供 Wi-Fi 使用方案。当前版本直接连接，不需要配对码，也没有链路加密。
- HDMI 救援： 可选 HDMI/UVC 采集卡，例如 MS2130S；基础网络显示不要求采集卡。

### 下载与安装

请到[本仓库的 Alpha 发布页](https://github.com/Longhorn5048/iMac-ReVoyage/releases/tag/alpha-2026.10.09)下载 `iMac-ReVoyage-Alpha-20261009.zip` 和对应 `.sha256` 文件。要安装应用，请选完整 ZIP；GitHub 自动生成的 “Source code” 只含源码，上游 TargetBridge 的安装包也不适用于这一版 ReVoyage。

1. 解压完整包，在 iMac 上运行 `Receiver/install_receiver.command`。安装器会设置登录后运行的后台服务，并请求管理员授权来尝试开启 SSH。卸载应用时会保留 SSH 设置。
2. 在 Sender Mac 上运行 `Sender/安装 Sender.command`，按 macOS 提示允许屏幕录制。输入控制所需的辅助功能／输入监控权限由系统管理。
3. 在 Sender 中选择 iMac 和匹配的有线接口，选择镜像或扩展桌面。非 Retina 1080p iMac 可从“旧款 iMac 低延迟”档位开始。
4. 需要声音时，运行 `Sender/安装 iMac 扬声器.command`，装好 1.2 驱动后重启 Sender Mac。在系统声音输出中选择 **ReVoyage — iMac Speakers**，并打开 Sender 的“传输音频”。选择本机扬声器或耳机时不再转发到 iMac。

升级时，Sender 应用和扬声器驱动都要更新。AudioTheme 沿用上一版 Receiver；如果你还在用更早的版本，请用完整包更新两端。Receiver 首次装好支持远程更新的版本后，就可以在 Sender 设置里选择新版完整 ZIP 更新 iMac。

安装包目前只有临时签名，还没有 Developer ID 签名和公证，macOS 可能要求你在系统界面批准打开。摄像头和麦克风的虚拟设备虽然已编译成功，但还没有确认能在 FaceTime、Zoom 等应用中使用。

卸载使用应用内完整卸载入口，或 `Sender/uninstall_sender.command` / `Receiver/uninstall_receiver.command`。卸载器会尝试移除本项目的应用、启动项、设置、凭据、缓存和日志，保留你的文件以及系统物理摄像头和麦克风。移除扬声器驱动后，需要重启才能让它完全退出系统音频服务。

### 最新改进与已知限制

- 1080p60 低延迟档改用 80 Mbps H.264 High，硬件支持时限制最大量化参数；视频会话预算仍为 100 Mbps。
- 扬声器驱动 1.2 修正通过系统音频服务传递 PCM 的接口；Sender 增加不匹配驱动和读取失败提示。
- 修复设置页在浅色系统主题下的文字对比度，保留睡眠恢复和音频恢复修复。
- 视频路径仍为 4:2:0；彩色细线与源端缩放可能影响清晰度，不属于无损显示链路。
- 延迟目标是 25 至 35 ms，目前还没有实测结果；双机长期运行的稳定性也需要单独测试。
- HDMI Rescue 依赖 iMac 已登录且救援服务运行，不能覆盖 iMac 自身未登录、FileVault 解锁前或自身 Recovery 场景。

这次构建已有 181 项 Sender 测试通过，也做过合成音频驱动和编解码回归测试。新版能否实际发声、设置页显示是否正常、能否长时间运行，以及不同目标机上的表现，都还需要实测。详见 [最新修复](docs/AudioThemeFix-2026-10-09.md)、[画质调整](docs/ClarityVolumeFix-2026-10-09.md) 和 [兼容性](docs/Compatibility.md)。

### 构建与反馈

开发需要完整 Xcode、命令行工具，以及 `cmake`、`nasm`、`pkgconf`、`jq`、`xcodegen`。在 Git 工作副本根目录运行：

```sh
scripts/build_distribution.sh
scripts/check_distribution.sh
```

构建脚本会下载固定版本的依赖，并把安装包放在 `build/`。检查脚本在本机运行单元测试和合成服务，实际硬件仍需另行测试。带日期的文档保留了开发过程；如果其中的配对步骤、码率或待办状态与这里不同，请以本 README 和最新修复说明为准。

遇到问题可以在本仓库提 Issue，附上两台 Mac 的机型、系统版本、构建号、连接方式，以及怎样复现。上传日志前请去除个人信息。接下来会先测试目标机器上的显示、声音、睡眠和救援，再继续完善摄像头、麦克风和正式发布。


## English

### Project status: Alpha

iMac ReVoyage is based on [TargetBridge](https://github.com/swellweb/targetBridge) and is still in Alpha. Display streaming, audio, sleep coordination, and independent HDMI rescue are implemented. Camera and microphone integration is experimental. Testing on the target pair of Macs is incomplete, so reliability for daily or production use is not guaranteed.

The aim is to make an old iMac feel like a Studio Display in everyday use. It keeps its original hardware and screen resolution; 5K output, equivalent Apple hardware specifications, and compatibility are outside that promise. This project is not affiliated with Apple.

This version uses the October 9, 2026 AudioTheme fix: Sender build `20261009180257` and speaker driver 1.2. The applications are unchanged from that build. Only the documentation and package contents have been tidied up for release.

### What works so far

| Module | Implemented | Still to validate |
| --- | --- | --- |
| Display | Mirrored / extended desktop, discovery, panel detection, 1080p60, automatic quality fallback, bounded queues | Target hardware image quality, sustained frame rate, color, and end-to-end latency |
| Speakers | Dedicated `ReVoyage — iMac Speakers` system output, volume / mute controls, routing based on default output | Actual loading of the latest driver, playback across two Macs, and long-term A/V sync |
| Brightness and sleep | Sender-side internal-panel brightness control and readback, sleep coordination, wake reconnect, manual display off | Catalina backlight behavior and recovery after extended sleep; native system brightness controls are not promised |
| HDMI Rescue | Separate rescue process, display stays awake after network loss, takeover after stable real network frames | Requires a capture device and an active iMac login session; real fault recovery is unverified |
| Camera / microphone | Independent iMac → Sender service; 720p20 JPEG camera, 48 kHz mono PCM microphone, virtual-device implementations | Production signing, system activation, real capture, and calling-app compatibility |
| Installation | Install / uninstall on both ends, login services, remote Receiver updates and rollback | Clean installation, cross-machine updates, complete removal, and long sessions |

### Requirements

- Sender: Apple Silicon Mac running macOS 14 or later.
- Receiver: Intel iMac targeting macOS 10.15.7 Catalina or later; the package contains x86_64 binaries.
- First test target: non-Retina 21.5-inch Late 2015 iMac at 1920 × 1080. Other models and higher-resolution modes are experimental.
- Connection: Thunderbolt networking or Gigabit Ethernet. No Wi-Fi workflow is provided. The current version connects directly, without pairing codes or transport encryption.
- Optional HDMI rescue: an HDMI/UVC capture device such as MS2130S. Network display streaming does not require one.

### Download and installation

Download `iMac-ReVoyage-Alpha-20261009.zip` and its `.sha256` file from [this repository’s Alpha release](https://github.com/Longhorn5048/iMac-ReVoyage/releases/tag/alpha-2026.10.09). Choose the complete ZIP to install the apps. GitHub’s generated “Source code” archives contain source only, and upstream TargetBridge packages do not contain this ReVoyage build.

1. Extract the package and run `Receiver/install_receiver.command` on the iMac. The installer sets up services that run after login and requests administrator authorization to try to enable SSH. Uninstalling the apps leaves that SSH setting in place.
2. On the Sender Mac, run `Sender/安装 Sender.command` and grant Screen Recording access when macOS requests it. Accessibility / Input Monitoring permissions for input control remain managed by macOS.
3. Select the iMac and matching wired interface in Sender, then choose mirroring or an extended desktop. Start with the older-iMac low-latency preset for a non-Retina 1080p iMac.
4. For audio, run `Sender/安装 iMac 扬声器.command`, install driver 1.2, and restart the Sender Mac. Select **ReVoyage — iMac Speakers** in macOS sound output and enable audio transmission in Sender. Selecting local speakers or headphones stops forwarding audio to the iMac.

For an upgrade, update both the Sender app and speaker driver. AudioTheme uses the previous Receiver build. If you have an older version, update both Macs using the complete package. Once Receiver supports remote updates, you can select a new complete ZIP in Sender settings to update the iMac.

The package has an ad-hoc signature, but no Developer ID signature or notarization yet. macOS may ask you to approve it in system settings. The virtual camera and microphone compile, but their availability in FaceTime, Zoom, and other apps has not been confirmed.

Use the app’s complete-uninstall action or `Sender/uninstall_sender.command` / `Receiver/uninstall_receiver.command`. The uninstaller is intended to remove project applications, login services, settings, credentials, caches, and logs while preserving user files and physical camera / microphone devices. Restart after removing the speaker driver to fully unload it from the system audio service.

### Latest changes and limitations

- The low-latency 1080p60 preset now targets 80 Mbps H.264 High, with a maximum quantization parameter where supported, within the existing 100 Mbps video-session budget.
- Speaker driver 1.2 fixes PCM transfer through the system audio service; Sender reports incompatible drivers and read failures.
- Settings text contrast is fixed under a light system appearance; sleep and audio recovery fixes are retained.
- Video remains 4:2:0. Fine colored edges and source scaling can affect clarity; this is not lossless display transport.
- The latency target is 25 to 35 ms; it has not been measured yet. Reliability over long sessions with two Macs also needs separate testing.
- HDMI Rescue requires the iMac to be logged in with its rescue service running. It does not cover the iMac’s own pre-login, pre-FileVault-unlock, or Recovery environments.

This build has 181 passing Sender tests, along with synthetic audio-driver and codec regression tests. Playback with the latest fix, the settings window’s appearance, long sessions, and behavior across the target machines still need testing. See the [latest fix](docs/AudioThemeFix-2026-10-09.md), [image-quality notes](docs/ClarityVolumeFix-2026-10-09.md), and [compatibility matrix](docs/Compatibility.md) (Chinese).

### Building and feedback

Development requires full Xcode, its command-line tools, and `cmake`, `nasm`, `pkgconf`, `jq`, and `xcodegen`. Run from the root of a Git working copy:

```sh
scripts/build_distribution.sh
scripts/check_distribution.sh
```

The build script downloads pinned dependencies and puts the package in `build/`. The check script runs local unit tests and synthetic services; hardware testing is separate. Dated documents keep the development history. If their pairing instructions, bitrates, or task status differ from this README or the latest fix notes, follow the newer instructions.

If something goes wrong, open an issue in this repository with both Mac models, OS versions, build number, connection type, and steps to reproduce it. Remove personal information before uploading logs. Next comes testing display, audio, sleep, and rescue on the target machines, then further work on the camera, microphone, and production release.


## 致谢与许可 / Credits and license

基于 Marco Caciotti 的 [TargetBridge](https://github.com/swellweb/targetBridge)。保留原作者署名与 [MIT 许可证](LICENSE)。FFmpeg 与 SDL2 使用各自许可证，见 [第三方声明](THIRD_PARTY_NOTICES.md)；完整 Alpha 包附对应许可和固定版本源码归档。

Based on [TargetBridge](https://github.com/swellweb/targetBridge) by Marco Caciotti. Original attribution and the [MIT license](LICENSE) are retained. FFmpeg and SDL2 have separate licenses; see [third-party notices](THIRD_PARTY_NOTICES.md). The complete Alpha package includes their license texts and pinned source archives.
