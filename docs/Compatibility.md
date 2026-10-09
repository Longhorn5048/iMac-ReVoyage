> 历史／技术记录：当前 Alpha 状态、安装与连接方式以 [README](../README.md) 为准。
> Historical / technical record: consult the README for current Alpha status and setup.

# 兼容性与验收状态

“已编译”表示本地构建及自动检查通过，不等同于已在目标机器完成验收。

| 部分 | 构建目标 | 状态 | 仍需验收 |
|---|---|---|---|
| Receiver、HDMI Rescue、Storage Watcher、Media Bridge | Intel x86_64，macOS 10.15 | 当前源码可构建；所有内嵌 Mach-O 检查架构及最低系统版本 | macOS 10.15.7 实机启动、升级、长期运行 |
| Sender | Apple Silicon arm64，macOS 14 | 当前源码可构建，macOS 单元测试覆盖 | 录屏授权、有线连接、延迟及稳定性 |
| 2015 年 1080p iMac | 1080p60／1080p30 | 首要基准机型；尚未完成本轮实机验收 | 画面、扬声器、亮度、Rescue、电源及卸载 |
| 1440p／4K／5K iMac | 面板自动识别；高分辨率手动档 | 实验支持；自动模式保守选择到 1440p30 | 不同 Intel 代际、硬解／软解、持续负载 |
| 摄像头／麦克风共享 | iMac → Sender，服务独立 | 合成数据和接口回归覆盖；虚拟设备实验支持 | 正式签名、系统激活、常用通话应用 |
| 远程更新 Receiver | 有线 IPv4，Intel / macOS 10.15 更新服务 | 需在 iMac 首次安装支持版本；临时安装与回滚替身覆盖 | Catalina 服务启动、跨机器更新及串流恢复 |
| Intel Sender／Apple Silicon Receiver | 非当前发行包目标 | 未提供此发行组合 | 独立构建和支持决策 |
| 公开分发 | 临时签名预览包 | GitHub 只生成待审阅的预览草稿 | Developer ID 签名、公证及干净机器安装 |

本轮不启动目标机器或模拟器。25–35 ms 是待实测的目标，未标为测得性能。暂不承诺更多 iMac 机型已验证。
