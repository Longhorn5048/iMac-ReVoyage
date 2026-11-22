# DisplayShell：全屏独占与无信号页（2026-11-22）

## 问题

Sender 长时间无操作自动睡眠后，iMac 没有熄屏，并露出 iMac 自己的 macOS。源码层面有两个原因：

1. 网络串流没有画面时，Network Receiver 的窗口会隐藏；Rescue 窗口只在 HDMI 有帧时才全屏置顶。两路都没有画面时，没有任何窗口盖住桌面。
2. Sender 把后台唤醒（Power Nap／维护唤醒）当作真正唤醒，向 iMac 发送“已唤醒”。iMac 亮屏后等不到画面；Sender 再次睡下时，“已睡眠”不一定送得出去。

## 现在的行为

| 状态 | iMac 屏幕 |
|---|---|
| 网络串流有画面 | Network Receiver 全屏 |
| 只有 HDMI 有画面，或按 R 进入手动 Rescue | Rescue 外壳全屏显示 HDMI |
| 两路都没有画面 | Rescue 外壳全屏显示“无信号”页 |
| Sender 通知睡眠，或手动关屏 | 熄屏；外壳仍盖住屏幕，意外唤醒也只会看到“无信号” |
| 连按两次 Esc | 回到 iMac 桌面，直到网络画面恢复或从菜单栏返回 |

- 外壳窗口位于 Dock 和菜单栏之上，隐藏指针；网络画面恢复时延迟 0.8 秒再让出，避免切换瞬间露出桌面。
- “无信号”页显示 Receiver 地址、缺少的权限和快捷键。按 P 处理第一项缺少的权限：尚未询问过的直接弹出系统询问，已拒绝的打开对应的系统偏好设置页，并在权限补齐后自动回到全屏。
- 系统权限询问框的层级低于外壳，询问期间外壳会让出屏幕。
- R 切换 Rescue／网络串流时显示当前模式。
- 界面文字跟随 Receiver 的语言；目前只有中文和英文。
- Sender 只有在至少一台显示器真正点亮时才通知 iMac 唤醒。

## 无信号熄屏（可选，默认关闭）

默认仍按 D-020 保持亮屏。在菜单栏 ReVoyage 菜单里勾选“无信号 60 秒后熄屏”，或执行：

```sh
defaults write re.voyage.rescue NoSignalDisplayOffSeconds -int 60
```

之后无信号且 iMac 键鼠空闲满 60 秒时只关闭面板，主机继续运行。HDMI／网络画面或 iMac 键鼠会重新点亮。

## 验证情况

- 已在 Linux 上通过：`RescueReceiver/tests/run_tests.sh`（状态机和外壳呈现规则）。
- 需要 macOS：`RescueReceiver/tests/run_power_tests.sh`、Receiver `make test-session-gate`、Sender XCTest。
- 需要真机：Sender 自动睡眠与后台唤醒、全屏切换有无闪现桌面、权限询问、无信号熄屏后的唤醒。
