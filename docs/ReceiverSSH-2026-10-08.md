> 历史／技术记录：当前 Alpha 状态、安装与连接方式以 [README](../README.md) 为准。
> Historical / technical record: consult the README for current Alpha status and setup.

# Receiver 安装与 SSH

2026-10-08：在 iMac 本机运行 `Receiver/install_receiver.command` 完成核心安装后，安装器会检查 macOS 远程登录（SSH）。尚未开启时，请求系统管理员授权并执行 `systemsetup -setremotelogin on`，再核实服务已启用且已加载。已开启时直接沿用，不重复授权、不修改允许登录的用户列表。

## 首次安装

1. 解压完整发行 ZIP，在 iMac 打开 `Receiver/install_receiver.command`。没有鼠标时，可按 Command + 空格打开终端，然后运行：

   ```sh
   /bin/zsh ~/Downloads/iMac-ReVoyage-Preview/Receiver/install_receiver.command
   ```

2. 若安装器请求开启 SSH，在 macOS 授权窗口输入管理员密码。取消授权不会撤回已经安装的显示、Rescue 或远程更新服务。
3. 安装器只有确认服务开启后才显示“SSH 已开启”，并输出 iMac 账户名及连接命令。在 Mac mini 的 Sender 设置 → Receiver 高级服务中填写 iMac 的有线 IP 地址及 **iMac 的账户名**，点击“打开 SSH”。登录使用该 iMac 账户的密码。若 macOS 远程登录限制为指定用户，需在共享设置中允许这个账户。

路径按实际下载目录调整。SSH 是 macOS 自带服务，其监听范围和登录权限沿用系统设置；安装器不修改账户密码、登录允许列表或 SSH 密钥。应用的显示、媒体及远程更新服务仍按原有线网络规则工作。

## 系统权限与单独重试

Catalina 10.15 及更新版本要求执行 `systemsetup -setremotelogin` 的父进程拥有“完整磁盘访问权限”；管理员密码不能代替这项权限。[Apple 官方说明](https://support.apple.com/en-us/101653)。

如果系统拒绝开启，安装器会显示“SSH 尚未开启”并打开“共享”设置。可以直接在“系统偏好设置 → 共享 → 远程登录”开启；新版系统位于“系统设置 → 通用 → 共享”。也可以在“系统偏好设置 → 安全性与隐私 → 隐私 → 完整磁盘访问权限”允许终端，重新打开终端后仅重试 SSH：

```sh
/bin/zsh ~/Downloads/iMac-ReVoyage-Preview/Receiver/install_receiver.command --enable-ssh
```

这个选项无需重新安装应用。若解压文件已经删除，可调用已安装 Receiver 自带的安装器：

```sh
/bin/zsh "$HOME/Applications/iMac ReVoyage/iMac ReVoyage Receiver.app/Contents/Resources/install_receiver.command" --enable-ssh
```

## 更新与卸载

Sender 的“远程更新 Receiver”沿用独立有线更新服务，**不依赖 SSH**。远程安装使用 `--remote-update`，保留现有 SSH 设置，不在 iMac 弹出管理员窗口，也不因 SSH 未开启而中断更新。

SSH 属于共享的 macOS 系统设置；完整卸载清理 ReVoyage 自身文件、设置及启动项，保留远程登录设置，避免中断其他 SSH 用途。需要关闭时，可在 macOS“共享 → 远程登录”关闭。

## 验证范围

安装器新增 8 项隔离回归，覆盖首次授权、已开启时幂等、取消授权、权限错误返回零、已加载但被禁用、已启用但未加载、远程／干跑跳过授权，以及 SSH 失败保留已完成的核心安装。22 项安装器测试、174 项 Sender 测试及 Receiver／Rescue／媒体／卸载回归通过。测试重定向到临时系统工具替身，不操作本机 SSH 服务。Catalina 目标 iMac 的实际授权和 Sender 登录仍需安装后确认。
