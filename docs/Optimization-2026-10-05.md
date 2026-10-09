> 历史／技术记录：当前 Alpha 状态、安装与连接方式以 [README](../README.md) 为准。
> Historical / technical record: consult the README for current Alpha status and setup.

# 2026-10-05 优化实现

本轮落实“检查项目并提出优化建议”中的发布路径、首次配对、稳定身份与核心自动检查，并加入保守的自动画质调整。

## 发布与自动检查

- `scripts/build_distribution.sh` 从当前源码构建 Sender、Receiver、Rescue、Storage Watcher、Media Bridge，不解压历史测试包补组件。
- CI 和标签发布共用该入口；CI 覆盖 `imac-revoyage/**`、`codex/**`、所有 PR，发布仍为临时签名预览草稿。
- 固定 FFmpeg／SDL 源码与校验值；依赖缓存缺少头文件或 pkg-config 元数据时重建。
- `BuildManifest.json` schema 2 记录源码及所有 Mach-O 的校验值；拒绝错误架构、过高最低系统版本、Homebrew 绝对依赖或缺失库。Sender 的系统 Swift runtime 沿用 macOS 14。
- `scripts/check_distribution.sh` 纳入 Sender、Receiver、身份、解码、会话门禁、面板、Rescue／电源替身、安装卸载、合成媒体专项及打包验证。

## 配对与身份

- Receiver 在用户设置目录保存 UUID；损坏或符号链接身份文件拒绝启动，避免无声改变显示身份。
- 安装器导出权限 0600 的 JSON 配对文件；Sender 提供发现设备选择及有界文件导入，保持 64 位配对码。
- Bonjour UUID 只用于查找候选凭据。独立域 HMAC 将 UUID 与本次会话 nonce 绑定；新版认证还加入 Sender 的独立随机 nonce，避免伪接收器重放已截获的应答；Sender 验证身份证明及双向认证后才将新地址关联到 Keychain 中的设备凭据。
- 旧地址凭据保持兼容；已经认证的 UUID 不可退回无身份的旧协议。新地址的显示身份使用 UUID，旧地址排列在认证后首次迁移。
- 用户显式保存新配对码会解除该地址的旧身份关联，支持卸载后重装；其他设备凭据不受影响。导入文件本身不建立可信身份。
- 完整卸载使用既有设置树及 Keychain service 清理路径，覆盖 UUID、配对文件及设备凭据。

## 画质与性能

- 新会话默认自动；已有手动设置按原档恢复。根据面板及双方 HEVC 硬件能力选择 1080p60／1440p30。
- 接收端计数差值连续表现吃力十秒且距上次调整至少三十秒才降级，最低 1080p30。静态桌面、过期样本及计数重置不触发降级。
- 两分钟稳定后最多恢复一次，防止反复跳档。复用已有捕获软重启，保留连接及虚拟显示器；手动固定模式不受反馈调整。
- 所有高分辨率档均按两端能力回退 H.264；继续保留手动实验档。

## 验证与限制

本地统一验证入口通过：151 项 Sender 单元测试、62 项 Receiver 解析检查，以及身份／双 nonce 认证、音频、控制队列、真实会话门禁替身、解码失败及面板替身回归；75 项 Rescue 状态检查和电源控制替身；11 项合成媒体服务、11 项卸载器、9 项安装器、8 项打包检查。完整包的五个应用、15 个 Mach-O 均通过签名完整性及架构／最低系统版本／动态库查找检查。托管 CI 尚未实际触发。没有进行系统安装、系统虚拟设备激活、屏幕／摄像头采集或电源实机操作。签名公证、通话应用验收、端到端延迟与完整 Catalina 实机验收仍需后续处理。CI 配置使用的 Apple Silicon macOS 标签依据 [GitHub 官方运行器表](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。

亮度／音量快捷键、正常状态息屏同步、更细的帧时序测量属于下一阶段工作，不在此轮最小改动中实现。
