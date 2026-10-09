> 历史／技术记录：当前 Alpha 状态、安装与连接方式以 [README](../README.md) 为准。
> Historical / technical record: consult the README for current Alpha status and setup.

# Rescue Lock 实现记录 — 2026-10-02

已落实 D-020 的第一阶段：网络失效后亮屏等待，HDMI 无帧／黑屏／反复协商不触发休眠；连续 2 秒实际帧恢复后接管网络；已配对人工关屏与唤回；后台及主机空闲防护保留。

- 同一 `DisplaySignalState` 纯 C 状态机用于 Network 与独立 Rescue。启动锁存，网络实际帧 2 秒有效、通知 3.5 秒有效；恢复要求 2 秒新鲜进展、最长 1.5 秒间隔，Rescue 通知帧年龄最多 500 ms。重复／未来／倒退／缺少帧时间的通知不能解锁。HDMI 仅影响呈现及音频，不参与电源决策。
- Network 在 SDL 提交后更新时间；修正处理前时间与新帧相减导致无符号下溢的误报。appliance 窗口与网络扬声器在恢复中等待，HDMI 继续呈现；调试窗口不强制隐藏。
- `0x39` 为 9-byte `[displayOn, BE64 requestID]`，`0x3a` 为 10-byte `[displayOn, accepted, BE64 requestID]`。请求 ID 非零，命令仅在配对认证后接受；Receiver profile 显式声明 `supportsDisplayPower`。旧 Receiver 缺能力时 Sender 禁用按钮。
- Receiver 释放显示断言／SDL screensaver 抑制后，通过本机通知交给 Rescue 执行 `pmset displaysleepnow`；主机防空闲睡眠断言不释放。Rescue 执行结果由本机通知确认，Receiver 5 秒过期取消、Sender 6 秒未确认显示失败；TCP 和进程间请求均关联 ID，迟到结果不能确认新操作。取消／失败／过期优先恢复亮屏，异步旧关屏完成后再次按最新意图唤回。
- 人工关屏只存内存。完成后断线或 HDMI／网络恢复不撤销；显式唤回按网络健康返回 NORMAL／RESCUE_LOCK。任一显示服务重启清除人工状态并亮屏。离线物理关屏入口仍待研究；不使用电源键映射。macOS 本地输入可能自行唤醒 LCD，显式唤回按钮恢复 ReVoyage 常驻保活。
- 旧 LKG 与 settings v1/v2 休眠字段保留兼容，但 Rescue 不再读取或执行，Sender 撤下误导的无信号休眠设置。健康模式自动节能及 Sender display-sleep 同步尚未实现。

验证：75 项状态／协议检查、真实 Rescue 控制器电源替身回归、Receiver 真实认证门禁／关联 ACK／超时回滚／恢复通知、Sender 133 项与五语言检查通过；双端与 Rescue 编译通过，Test8 已重建并核验。没有执行真实 pmset、系统安装／卸载、采集、模拟器或目标机测试；Catalina 显示电源及画面切换仍需用户授权后的真机验收。
