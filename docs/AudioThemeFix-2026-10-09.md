> 历史／技术记录：当前 Alpha 状态、安装与连接方式以 [README](../README.md) 为准。
> Historical / technical record: consult the README for current Alpha status and setup.

# 扬声器音频传输与设置页对比度修复

## 更新方法

1. 在 Mac mini 上退出旧 Sender，使用本包安装新版 Sender。
2. 运行同一包的 `Sender/安装 iMac 扬声器.command`，把系统扬声器驱动更新到 **1.2**，然后重启 Mac mini。应用和驱动都必须更新，只替换其中一个无法使用新的音频传输接口。
3. 重新连接 iMac，在系统声音输出中选择 `ReVoyage — iMac Speakers`，确认 Sender 的传输音频已开启。
4. 播放音乐，检查系统音量和静音是否影响 iMac。设置页保持深色背景及对应的浅色文字，系统浅色模式下也应可读。

Receiver 沿用已有版本，不需要更新。本包保留上轮 1080p 画质调整和睡眠恢复修复。

## 音频数据接口

此前驱动在自定义属性中返回原始 PCM 字节，却把数据类型声明为 `kAudioServerPlugInCustomPropertyDataTypeNone`。Apple 的 AudioServerPlugIn SDK 定义该值代表属性没有数据；自定义属性仅支持 CFString 或 CFPropertyList 在主机和客户端之间传输。直接调用驱动函数的合成 host 没有经过这层 marshalling，因此旧测试不能确认实际系统音频服务能够传回 PCM。

新版使用新的 `rvsd` 属性，声明 CFPropertyList 并返回 CFData，装载最多 480 帧 S16LE 双声道 PCM。设备实时混音仍写入有限缓冲，CFData 分配仅在非实时属性读取阶段进行。读取权限、音量／静音、过期数据清理和网络发送预算保留。

Sender 按 CF 对象接口读取并校验类型、指针大小、PCM 长度及立体声帧对齐，释放返回对象。不复用旧 `rvsp` 属性，避免新 Sender 把旧驱动的原始 PCM 字节误当成 CF 指针。清理属性 `rvsc` 没有数据，调用时传入零长度。若系统驱动不匹配或读取失败，会记录错误并显示安装新版驱动的提示。

接口定义参考 [Apple 自定义属性说明](https://developer.apple.com/documentation/coreaudio/audioserverplugincustompropertyinfo)。

## 设置页

独立设置窗口使用固定深色渐变背景，但未设置对应的 color scheme。在系统浅色模式下，语义主／次文字颜色会按浅色主题变成深色。设置页根视图现在指定深色模式，使标签、说明和原生控件与页面背景一致，不改变系统主题。

## 验证

- Sender 181 项测试通过，新增 CFData 经二进制 property list 编码／解码后的 PCM 一致性、空包、错误类型、旧接口隔离、越界和帧对齐检查。
- HAL 合成 host 的 ASan／UBSan 测试通过，要求属性 metadata 声明 CFPropertyList，且在每次读取中实际序列化／反序列化返回对象，再验证 PCM、音量／静音、权限、积压及时钟。仍不是系统 HAL 加载测试。
- 设置页修改编译通过；未启动目标设备播放测试或设置窗口视觉验收。实际发声及系统主题下的页面效果需要安装后确认。
