# Catalina backport 审查（2026-09-30）

这是历史审查快照；当前构建入口为 `scripts/build_distribution.sh`，完整组件的本地验证状态见 [兼容性表](docs/Compatibility.md)，实机项目见 [硬件验收](docs/HardwareAcceptance.md)。

结论：**测试版 3 的 Receiver/Rescue x86_64/10.15 交叉编译通过，Catalina 实机尚未证明可运行。** 使用固定 FFmpeg 7.1.3、经典 SDL2 2.32.10；Receiver、Rescue 和 3 个动态库均声明 minOS 10.15。配置 HMAC、显示状态通知和 IOKit 电源断言使用系统 frameworks；新增显示睡眠命令调用 Catalina 已有的 `/usr/bin/pmset displaysleepnow`，但非管理员调用、屏幕唤醒及采集卡在显示关闭时继续送帧都须在 iMac 上验收。

## 上游与授权

- 上游仓库：[swellweb/targetBridge](https://github.com/swellweb/targetBridge)，本地固定提交 `1052e36fd1e51687d82f913550f6529d10dccb47`。
- 上游 [LICENSE](LICENSE) 为 MIT，Copyright (c) 2026 Marco Caciotti。保留许可文本和声明。上游 README 将品牌与源码许可分开说明，本项目使用“iMac ReVoyage”识别自己的工作，不代表上游官方版本。
- [FFmpeg 法律说明](https://www.ffmpeg.org/legal.html)：具体许可取决于构建选项，随包分发还要保存对应源码/构建配置和声明；不能仅凭上游 MIT 推定整个 App 包都是 MIT。[SDL 许可](https://www.libsdl.org/license.php)为 zlib。发布前生成逐个 dylib 的 SBOM/许可清单。

## 11+ 限制和依赖

| 位置 | 已见事实 | Catalina 工作 |
| --- | --- | --- |
| `TBReceiverC/Makefile` | `MACOSX_DEPLOYMENT_TARGET ?= 11.0`，编译链接 FFmpeg `libavcodec/libavutil`、SDL2 与 Apple frameworks。 | 10.15 构建配置单独实验；开启 availability 警告并检查链接结果。 |
| `build_tbreceiver_c_app.sh` | App `LSMinimumSystemVersion=11.0`；`dylibbundler` 复制 dylib；显式打包 SDL3，因为目前 Homebrew `sdl2` 是 `sdl2-compat`。 | 为 10.15 构建并核验**全部** x86_64 动态库、传递依赖和 `LC_BUILD_VERSION`；必要时用经典 SDL2 降低依赖层数。 |
| `.github/workflows/ci.yml` | 仅 macOS 15 的 Intel/Apple Silicon runner；无 Catalina 测试。 | 加 Catalina 硬件验收记录，CI 交叉编译不能替代真机。 |
| `TargetBridge-Sender/project.yml` / Xcode 工程 | Sender 部署目标 14.0，依赖 ScreenCaptureKit。 | Sender 不回移 Catalina，保持现代 Mac。 |
| `main.c` / `display.c` / `decoder.c` | C/ObjC、SDL2、CoreAudio、CoreGraphics、VideoToolbox；仅见 `kAudioObjectPropertyElementMain` 的旧 SDK 名称兼容宏。 | 逐 API 编译、实机加载和硬解能力测量。私有 `DisplayServicesSetBrightness` 需单独处理兼容与失效，不作为核心路径。 |

[Homebrew 官方安装说明](https://docs.brew.sh/Installation)明确 Catalina 10.15 无法运行当前 Homebrew。不能在 iMac 上照搬上游 `brew install ffmpeg sdl2 pkgconf`；应在受支持构建机上固定源码/工具链生成 10.15 x86_64 包，或评估其它可复现包管理方式。[sdl2-compat 上游](https://github.com/libsdl-org/sdl2-compat)确认运行时还需 SDL3；[SDL3 平台头文件](https://github.com/libsdl-org/SDL/blob/main/include/SDL3/SDL_platform_defines.h)允许早于 Catalina 的最低目标，但实际二进制版本仍须核查。

## 与产品目标的差距

- 网络：`net.c` 在 `INADDR_ANY:54321` 监听，并能报告 LAN IP；Sender 可选择 `Network Link`，但 [上游说明](https://github.com/swellweb/targetBridge#official-addons)仍标实验。Receiver 的首选显示 IP 和 Sender 默认传输均偏 Thunderbolt。千兆网卡、IP 绑定与断线恢复需验收。
- 应急：源码没有 UVC/UAC 采集实现。MS2130S 芯片[资料](https://doc.ultrasemi.com/en/ic/macrosilicon/ms2130s.html)说明支持 UVC/UAC，但实际采集设备受板卡固件影响，必须枚举格式。Apple 的 [AVFoundation 采集架构](https://developer.apple.com/documentation/avfoundation/capture-setup)可作实现基础，使用前要处理摄像头/麦克风授权。
- Appliance：现有脚本是 `RunAtLoad=true`、`KeepAlive=false` 的 LaunchAgent；可以登录启动，不能保证崩溃恢复。播放器仅连接后全屏并隐藏指针，等待界面窗口化；这些行为需要明确的 appliance 模式。
- Display Sleep：测试版 3 由独立 Rescue 进程结合 Network Receiver 心跳和最近 UVC 帧实现无帧计时，并调用系统 `pmset displaysleepnow`；主机空闲睡眠与显示睡眠的断言分开管理。系统命令在当前构建机存在，Catalina 上权限、显示器电源状态、恢复任一路时的唤醒行为仍须真机确认。MS2130S 若无 HDMI 仍输出黑帧，帧超时状态机无法识别 HDMI 丢失。
- 配置：测试版 3 实现 settings schema v1/v2 协商、32-byte 会话 nonce、HMAC-SHA256、ACK、原子 Receiver LKG；v2 增加无信号休眠时长，旧 Sender 继续使用 v1。Sender 用 Keychain 保存配对密钥；Receiver 文件权限为 0600。该协议需在 Catalina/M4 双机验证；目前 TCP 视频/音频仍未加密。

## 建议的最小验证顺序

1. 保持上游源码可对照；先做 10.15 x86_64 依赖打包实验，不在未验证前直接改发布目标。
2. 用 `otool -l` 检查 App 与所有 dylib 的 minos/构建版本，用 `otool -L` 检查依赖闭包；保存版本与构建参数。
3. 先用 H.264 档在 Catalina 实机验证解码、SDL、音频，再测 HEVC 与目标分辨率；对无 HEVC 硬解的 iMac 保留 H.264/低档配置。
4. 单独枚举 MS2130S 的 UVC/UAC、帧格式和拔插事件；不能从芯片理论规格推断成品采集卡的输出。

当前构建命令为 `scripts/build_distribution.sh`，依赖及基础应用构建见 `scripts/build_core_apps.sh`。旧测试版本包、脚本及说明已清理；有效验收要求合并到 `docs/HardwareAcceptance.md`。本轮未接入目标 Intel iMac、SD 卡或采集卡，不能给出 Catalina 实机通过结论。
