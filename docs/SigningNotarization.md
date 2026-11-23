# 签名与公证（Developer ID）

状态：脚本已参数化，**尚未用真实开发者账号跑过**。默认行为不变：不设置任何变量时，本地与 CI 构建仍是 ad-hoc 签名。

## 为什么需要

ad-hoc 签名的 Sender 可以投屏，但 macOS 不会注册其中的虚拟摄像头（系统扩展）和虚拟麦克风／扬声器（HAL 驱动）。设置页里这三项会显示“需要用开发者账号签名的版本才能在本机注册”。

## 环境变量

| 变量 | 用途 |
| --- | --- |
| `REVOYAGE_TEAM_ID` | 10 位 Team ID。构建时写入应用和虚拟设备，签名时校验一致。 |
| `REVOYAGE_SIGN_IDENTITY` | `Developer ID Application: 姓名 (TEAMID)`。不设置或为 `-` 时为 ad-hoc。 |
| `REVOYAGE_PROVISIONING_PROFILE` | 可选。Developer ID 描述文件路径，签名前嵌入应用。 |
| `REVOYAGE_NOTARY_PROFILE` | `notarytool` 的钥匙串配置名，仅 `scripts/notarize.sh` 使用。 |

密码和 App 专用密码不经过这些脚本，只存放在钥匙串里。

## 步骤

1. 一次性保存公证凭据：

   ```sh
   xcrun notarytool store-credentials revoyage-notary \
     --apple-id "<Apple ID>" --team-id "<TEAMID>"
   ```

2. 构建并签名 Sender：

   ```sh
   export REVOYAGE_TEAM_ID=<TEAMID>
   export REVOYAGE_SIGN_IDENTITY="Developer ID Application: <姓名> (<TEAMID>)"
   TargetBridge-Sender/scripts/build_targetbridge_sender_app.sh
   ```

   `scripts/sign_sender_app.sh` 按由内到外的顺序签名（框架、两个 HAL 驱动、安装助手、摄像头扩展、主应用），启用 hardened runtime 和安全时间戳。

3. 公证并装订：

   ```sh
   ditto -c -k --keepParent build/TargetBridge.app build/Sender.zip
   REVOYAGE_NOTARY_PROFILE=revoyage-notary REVOYAGE_STAPLE=build/TargetBridge.app \
     scripts/notarize.sh build/Sender.zip
   ```

## 拿到账号后需要确认的事

- 主应用的 `com.apple.developer.system-extension.install` 是受限 entitlement，Developer ID 分发通常需要在开发者后台为 `com.targetbridge.sender` 开启 System Extension 能力并生成描述文件，通过 `REVOYAGE_PROVISIONING_PROFILE` 嵌入。
- `scripts/build_distribution.sh` 会重新签名 Receiver 和 Rescue（ad-hoc）。iMac 端应用的 Developer ID 签名尚未参数化。
- 公证后在 Sender 上验证：`spctl -a -vv build/TargetBridge.app`，然后在设置页安装三个虚拟设备，确认状态行从“未安装”变为“已就绪”。
