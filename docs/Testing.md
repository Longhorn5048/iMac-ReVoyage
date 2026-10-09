> 历史／技术记录：当前 Alpha 状态、安装与连接方式以 [README](../README.md) 为准。
> Historical / technical record: consult the README for current Alpha status and setup.

# Testing TargetBridge Without Hardware

2026-10-08 SSH 安装：`Lifecycle/tests/test_receiver_install.py` 新增 8 项隔离回归，检查首次授权、已开启时幂等、取消／权限拒绝、命令成功退出但服务未启用、加载与禁用状态、远程／干跑跳过授权、SSH 失败保留已安装核心。所有系统服务及授权工具均在临时脚本副本中替换，不开启实际 SSH；目标 Catalina 登录仍待验收。详见 [安装说明](ReceiverSSH-2026-10-08.md)。

2026-10-08 声音恢复：`TBBoundedAudioSendGateTests` 新增 6 项回归，验证空／无效 PCM 不关闭声音、超大采集批次保留最新完整 PCM、积压后等待全部写入完成与冷却再自动恢复、手动静音／睡眠／停止不被覆盖、连续突发仍保持队列／速率限额、后台定时器只报告一次恢复。与 `TBCaptureContinuityTests` 合计 22 项相关测试、全量 174 项 Sender 测试通过；不启动实际网页或音频设备。详见 [声音恢复说明](AudioResume-2026-10-08.md)。

2026-10-08 远程更新：`ReceiverUpdate/tests/run_tests.sh` 编译带 ASan/UBSan 的原生服务替身，在临时 HOME 上传合成签名 Intel 包，覆盖成功安装、校验失败、越界／链接／重复／本地头不匹配 ZIP、旧系统兼容性、断流／并发拒绝及重启回执，不调用真实服务。指定 `REVOYAGE_UPDATE_PACKAGE` 为构建后的完整 ZIP 可追加发行包上传验证。Sender 新增 4 项包摘要／有界 HTTP／分片／请求匹配回归；安装器 14 项回归包含独立更新启动项、正常事务和回滚期间保留更新服务，卸载覆盖更新残留。

2026-10-08 Receiver 本地调试：`make test` 包含 `test_receiver_debug`，验证快捷键重复／释放／修饰键、采样时间、帧率／带宽／合帧比例、接收端处理延迟及断连归零。`make test-session-gate` 验证 R 模式不会被新视频帧覆盖、切换保留连接、teardown 后保留监听并接受后续会话。`make test-display-profile` 用 SDL／显示替身验证真实按键路由、顶端信息栏、纹理缓存和文本适配；不创建窗口。`RescueReceiver/tests/run_power_tests.sh` 验证无 HDMI 画面时手动 Rescue 仍可显示、返回和重启复位；不发出实际电源操作。

Everything on this page runs on one Mac with **no Thunderbolt cable, no
second machine, and no Apple Silicon requirement** (except where noted).
CI runs the first two suites on every push/PR.

## 1. Sender unit tests (Swift)

Covers the wire protocol (framing, corrupt-length rejection, unknown-type
skipping, input-event encoder parity with `JSONDecoder`), the discovered-
receiver model (which IP is dialed per transport), connection diagnostics
(link-local interface scoping, failure-detail composition), and the
automation parsers behind `targetbridge://` URLs and `--connect` launch args.

```bash
cd TargetBridge-Sender
xcodegen generate     # only needed after changing project.yml or adding files
xcodebuild test -project TargetBridge.xcodeproj -scheme TBDisplaySender -destination 'platform=macOS'
```

Test sources live in `TargetBridge-Sender/TBDisplaySenderTests/`.

The October 1 development update adds headless tests for receiver-scoped
credential names, authenticated offline commands (including reflected/wrong/
replayed proofs), shared-link budget admission, video/test mutual exclusion,
bounded bytes and packets, IDR recovery after an omitted compressed frame,
congestion hysteresis and rejected encoder changes. These test the policy and
protocol state; they do not prove actual VideoToolbox limits, LAN throughput,
hardware decode or capture-to-display latency. See
`docs/FeatureCompletion-2026-10-01.md` for the remaining delivery gates.

Pairing now requires an explicit receiver address. Save the previous code again
in Settings to bind it to that receiver. A different address has a separate
Keychain entry; no global key is used as an automatic fallback. Video budget
capacity defaults to an estimate of 900 Mbps per interface and can be adjusted
in Settings; there is currently no system-level throttling of native SMB.

## 2. Receiver parser tests (C)

Unit tests for the streaming packet parser in `net.c` — fragmented and
contiguous feeds, the NUL-sentinel guarantee, corrupt/oversized length
rejection, and multi-megabyte payloads fed in socket-sized chunks.
Parser/audio tests need **no ffmpeg, SDL, or pkgconf**. The session-auth suite uses CommonCrypto on macOS.

```bash
cd TargetBridge-Receiver/TBReceiverC
make test
```

This also runs audio-ring bounds/backlog tests and session-authentication
tests (including wrong keys, changed nonces, reflected proofs and packet gates).
On macOS, the authentication tests use the system CommonCrypto library.
The POSIX parser tests remain directly buildable on other platforms.

With FFmpeg/SDL build dependencies available, two additional headless suites
exercise decoder allocation failures and the real parser-to-authentication path:

```bash
make test-decoder test-session-gate
```

Neither suite opens a window or captures/injects input.

Test sources live in `TargetBridge-Receiver/TBReceiverC/tests/`.

## 3. Mock sender (protocol-level fault injection)

`TargetBridge-Receiver/TBReceiverC/tests/mock_sender.py` (stdlib-only
Python 3) speaks the full wire protocol against a running receiver:

| Mode        | What it exercises                                              |
|-------------|----------------------------------------------------------------|
| `handshake` | HELLO / heartbeat / TEARDOWN lifecycle                          |
| `stream`    | PARAM_SETS + AVCC H.264 frames (generated via the ffmpeg CLI)   |
| `hang`      | idle watchdog: silent sender is reaped after ~10s               |
| `badlen`    | parser rejects a corrupt `0xFFFFFFFF` length and disconnects    |
| `drop`      | abrupt mid-packet disconnect returns receiver to waiting        |

```bash
# terminal 1
cd TargetBridge-Receiver/TBReceiverC && make && ./tbreceiver --windowed

# terminal 2
python3 TargetBridge-Receiver/TBReceiverC/tests/mock_sender.py --mode stream --duration 5
```

All mock modes now authenticate the main connection. By default the mock
reads `~/Library/Application Support/TargetBridge Receiver/pairing.key`;
use `--pairing-key-file <path>` when testing a receiver on another host.
Both production peers must be updated, and the Sender must have the matching
pairing code saved. Old peers are refused; no anonymous fallback is provided.

## 4. Loopback smoke test (one command)

Builds the receiver, launches it windowed, and drives all mock-sender
phases with pass/fail assertions on the receiver's log:

```bash
TargetBridge-Receiver/scripts/loopback_smoke.sh            # full run
TargetBridge-Receiver/scripts/loopback_smoke.sh --no-stream  # skip the H.264 phase
```

Needs a GUI session (an SDL window opens briefly) and the receiver build
deps (`brew install ffmpeg sdl2 pkgconf`), so it is a local dev tool rather
than a CI job.

## 5. Real sender ↔ receiver on one Mac (no cable)

The receiver binds `0.0.0.0:54321` and accepts any peer, so an Apple
Silicon Mac can stream to a receiver running on itself over the LAN
interface (the sender refuses `127.0.0.1`, so use the machine's own LAN IP
for both ends):

```bash
open build/TargetBridge.app   # sender: pick the LAN interface, enter the Mac's own LAN IP
./tbreceiver --windowed       # receiver on the same Mac
```

This exercises the true capture → encode → decode → render path minus the
Thunderbolt link itself.

## Debugging a live connection

The sender logs its connection lifecycle (dial target, interface, waiting/
failed states, timeouts) to unified logging:

```bash
log stream --predicate 'subsystem == "com.targetbridge.sender"'
```

The receiver logs to stderr; under the LaunchAgent that lands in
`~/Library/Logs/TargetBridgeReceiver.launchd.err.log`.

## Experimental 5K at 60 FPS

`native5k60Experimental` is an opt-in HEVC profile for testing recent Apple
Silicon encoders at 5120 x 2880 and 60 FPS. It does not alter the stable 5K
profile, which remains at 48 FPS and is the recommended choice for daily work.

Real-world M4 testing has reached 56-57 FPS but also showed temporary drops
under mixed workloads and added heat when Input Dockstation is active. Treat
this profile as a benchmark and feedback tool, not a guaranteed 60 FPS mode.

Use it only for a test session, either from the Sender's stream-profile picker
or with the automation alias:

```bash
targetbridge connect --receiver <receiver-ip> --mode extended --preset 5k60
```

After at least one minute of normal desktop use, note the Sender FPS shown in
the session card, whether input remains responsive, and any capture or decoder
errors. For a two-receiver experiment, start one session per receiver and
record the FPS for each session separately. Include the sender model, macOS
version, receiver model, cable type, and selected transport with the report.

## 角色独立卸载（2026-10-01）

共享卸载器：`Lifecycle/ReVoyageUninstaller.m`。默认只读预览，`--gui` 经本机窗口确认后执行；`--test-root` 限定文件操作，并禁用所有进程、launchd、SMB、Keychain、TCC 和管理员操作。

文件安全回归不需要设备或模拟器：先将卸载器编译到临时目录，再运行 `python3 Lifecycle/tests/test_uninstaller.py /tmp/ReVoyageUninstaller`。10 月 1 日当时 8 项通过，覆盖角色隔离、同名外部应用保留、存储文件保留、符号链接安全、越界应用拒绝、只读预览和重复卸载。

本轮 Sender `xcodebuild analyze test` 成功，109 项通过、0 失败；Receiver Intel/minOS 10.15 编译成功，卸载器 arm64 和 x86_64 编译成功，Intel 卸载器 minOS 10.15 已核验；五语言检查与修改脚本语法检查通过。未执行当前用户的实际卸载、共享撤销或权限/凭据清理。摄像头/麦克风共享与系统虚拟设备源码现已实现，签名激活与目标设备验收仍待完成。

## 6. Camera/microphone bridge and lifecycle fixtures

The October 2 source update adds media protocol XCTest cases (131 Sender tests total after the review fixes), 11 synthetic loopback service cases, 11 filesystem-only uninstall cases and 9 installer fixture cases. No physical capture, system extension activation, driver installation or real uninstall is involved. Native camera output, media queue and microphone ring/interface checks run with AddressSanitizer and UndefinedBehaviorSanitizer. The receiver media service is built for Intel / macOS 10.15; Sender virtual products build for arm64 and x86_64 / macOS 14. Signing is required before system registration can be tested. See [the source delivery record](MediaBridge-2026-10-02.md).

```bash
# Build and run the source-only native + service + lifecycle checks:
./scripts/tests/test_media_bridge.sh

# Or use already built native helpers:
python3 MediaBridge/tests/test_service.py /tmp/ReVoyageMediaBridge-final
python3 Lifecycle/tests/test_uninstaller.py /tmp/revoyage-final-products/Sender.app/Contents/MacOS/ReVoyageUninstaller
python3 Lifecycle/tests/test_receiver_install.py
```

`MediaBridge --fixture` binds loopback and publishes synthetic devices only. Installer `--test-root` requires preview mode and a confined temporary home, with no launchctl operation. Native camera image tests (`VirtualDevices/Camera/test_output.m`) use generated images and an in-memory sample queue; CoreVideo may need access to the macOS graphics service to allocate these buffers.

## 2026-10-02 审查缺陷回归

最新结果：Sender 131 项 XCTest；媒体服务 11 项合成回环；安装器 9 项临时目录/模拟服务测试；Receiver 62 项 parser、音频环、认证与控制发送队列检查；Rescue 23 项信号/声音/鼠标状态检查通过。媒体队列和控制发送队列已通过 ASan/UBSan。详见 [修复记录](AppReviewFixes-2026-10-02.md)。

安装器测试覆盖核心暂存失败、替换中途失败、可选媒体失败、模拟服务重启失败和包含 XML/引号字符的安装路径。测试仅在临时目录操作，模拟服务重启使用测试脚本副本和假 launchctl，不触碰实际服务。生产安装器的 `--test-root` 仍禁止实际服务操作，运行时不再依赖 Python。

## Rescue Lock power regression (October 2)

October 8 adds automatic Sender sleep/wake synchronization. The same headless
Receiver session-gate suite now checks sleep intent across socket loss, trailing
frames, combined manual/automatic requests and stale ACKs. All Receiver power
APIs in that suite are substitutes. Sender protocol/continuity tests cover new
packet types, capability fallback and recovery intent. See
[implementation and target acceptance](SenderSleepSync-2026-10-08.md).

```bash
RescueReceiver/tests/run_tests.sh
RescueReceiver/tests/run_power_tests.sh
```

The pure C suite covers startup/loss latching, HDMI inactivity/reconnection,
2-second recovery, interrupted recovery, stale/duplicate/future frame timestamps,
manual override, restart clearing, audio arbitration, cursor balance and power
command validation. The real Rescue controller suite replaces **all IOKit
assertion and pmset/spawn calls** and checks off/wake, failures, expiry, late
completion and restart races; it opens no window, captures no device and changes
no actual display power. The Receiver session-gate suite stubs local notification
transport and validates paired power commands, correlated ACKs, timeout rollback
and recovery notifications. Sender protocol tests cover power framing and
capability fallback.

Old no-signal sleep expectations in historical Test 3–7 notes do not apply to
the current rebuilt Test 8. Target acceptance must verify LCD awake under network
loss/HDMI negotiation, explicit off/wake with background services active, recovery
and restart behavior. No simulator or target-hardware test runs automatically.

## 2026-10-03 review fixes

Sender: 141 XCTest checks pass. Receiver adds `make test-display-profile` and
extends `make test-session-gate`: all SDL/screen/backlight/power operations in
these regressions use substitutes. Settings persistence uses a generated
`/tmp` root without changing HOME; system volume queries are stubbed. They
cover native modes, 1×/2×, malformed brightness, readback failures and save-only
settings for new Sender clients. `scripts/tests/test_media_bridge.sh` now also
checks camera-request validation and wire-byte rate buckets under sanitizers.
Rescue's 75 state checks and power controller regression continue passing.
See [delivery record](ProjectReviewFixes-2026-10-03.md) for full limits.

## 2026-10-05 unified distribution and regression

Use `scripts/build_distribution.sh` to rebuild all five current applications
and pinned Catalina dependencies without historical ZIPs, then run
`scripts/check_distribution.sh`. These are the same entries used by CI and
preview release drafts. They run macOS unit tests, stubbed display/power tests,
synthetic loopback media and installation fixtures; no physical capture or
system installation is requested. Build tools: Xcode CLI tools, cmake, nasm,
pkgconf, jq and xcodegen. The Receiver is x86_64/macOS 10.15; the Sender is
arm64/macOS 14. Run on an Apple Silicon development Mac for this distribution.

Identity regressions cover persistent UUID creation, invalid/symlink files,
C/Swift HMAC vectors, fresh sender nonce, replay/reflection, downgrade rejection,
pairing document validation and discovery identity across IP changes. Quality
regressions cover conservative initial choice, all-preset codec fallback,
sustained overload, cooldown, idle/stale counters and bounded recovery.
`package_manifest.py` checks every embedded Mach-O, including helpers, virtual
devices and dynamic libraries, and exports current source checksums (schema 2).

Sender: 151 tests pass. Receiver parser: 62 checks plus authentication, identity,
audio/control, decoder failure, session gate and panel suites. Rescue: 75 state
checks plus the power-controller substitutes. Media service: 11 cases; uninstaller:
11 cases; installer: 9 cases. Packaging rejection tests: 8 cases. These counts
refer to local verification, not a completed hosted CI run or hardware acceptance.
