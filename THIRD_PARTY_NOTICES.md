# 第三方依赖与分发记录

更新：2026-10-05。本文件记录当前预览包随附的第三方组件；每次更新依赖或发布包时同步核对。ReVoyage/TargetBridge 自有源码按根目录 `LICENSE`（MIT）分发，不代表第三方库也适用 MIT。

| 组件 | 用途与随包文件 | 版本、来源与校验 | 许可与随包材料 |
| --- | --- | --- | --- |
| FFmpeg | Receiver 的 `libavcodec.61.dylib`、`libavutil.59.dylib` | 7.1.3；[官方源码归档](https://www.ffmpeg.org/releases/ffmpeg-7.1.3.tar.xz)；SHA-256 `f0bf043299db9e3caacb435a712fc541fbb07df613c4b893e8b77e67baf3adbe` | 构建配置见 `scripts/build_core_apps.sh`：共享库、仅 H.264/HEVC 解码及 VideoToolbox，未启用 GPL/nonfree；测试 ZIP 含 `Receiver/FFmpeg-LGPL-2.1.txt` 与 `Sources/ffmpeg-7.1.3.tar.xz`。实际二进制的完整许可义务在正式发布前继续核查 |
| SDL2 | Receiver 的 `libSDL2-2.0.0.dylib` | 经典 SDL2 2.32.10；[官方发布归档](https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz)；SHA-256 `5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165` | zlib；测试 ZIP 含 `Receiver/SDL2-zlib-LICENSE.txt` 与 `Sources/SDL2-2.32.10.tar.gz` |

两者在开发 Mac 上交叉编译为 x86_64、目标 macOS 10.15；Receiver 端不依赖 Homebrew。`CATALINA_BACKPORT.md` 记录兼容性审查，`docs/HardwareAcceptance.md` 记录尚未完成的真机验收。新模块若引入第三方代码、虚拟设备或可选服务，须先在此补版本、来源、许可、构建选项与随包声明，再进入可分发构建。
