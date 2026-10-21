# Teleport
## A Virtual KVM for macOS

[![Release](https://img.shields.io/badge/release-v1.4.2-blue)](https://github.com/Zomnus/teleport/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2012%2B-lightgrey)](#installation)

Use one keyboard and pointing device to control multiple Macs.

---

## 本次优化说明（v1.4 → v1.4.2）

本仓库基于 [abyssoft/teleport](https://github.com/abyssoft/teleport) 的公开源码，针对两台 Mac 之间切换键鼠时的「顺滑度」完成了一轮性能优化与稳定性修复，当前版本为 **v1.4.2**。

完整的技术分析、延迟拆解、风险与实施记录见：

**[Teleport 技术架构与「切换顺滑度」优化研究报告](docs/teleport-架构与切换顺滑度研究报告.md)**

### 已实施内容

#### 阶段一：线程模型与传输层

- 事件采集迁移到专用线程（自带 RunLoop），主线程仅负责启动/停止；失败时回退主 RunLoop 并使用 `kCFRunLoopCommonModes`，菜单、拖拽、模态窗口期间不再丢事件。
- TCP 发送改为有界异步写队列 + 专用写线程，`sendData:` 只入队不再阻塞调用方；新增 `SO_SNDTIMEO`、`SO_KEEPALIVE`。
- TLS 写入改为覆盖 `_writeData:`，`errSSLWouldBlock` 重试而非直接断线；delegate 挂载前收到的数据先缓存、挂载后回放。
- 虚拟光标改为纯增量积分并缓存屏幕几何，仅在显示器参数变化时重建。
- 每个事件附加 8 字节「事件年龄」，接收端据此恢复时间戳（`PROTOCOL_VERSION` 20）。

#### 阶段二：事件合并与边界体验

- 鼠标移动按 4ms 窗口合并、累积 delta 后一次发送（自检：200 个快速事件合并为 28 条消息）。
- 热区激活可取消，光标快速划过边缘不再遗留激活状态；默认抑制期 0.2s → 0.1s。

#### 阶段三：修饰键与协议

- `flagsChanged` 透传 keyCode，修复部分应用中修饰键识别异常（`PROTOCOL_VERSION` 21）。
- 版本号升级至 1.4。

#### v1.4.1 热修复：反复切换后失去控制

- event tap 改为进程级常驻，非控制期间原样放行事件，不再反复 enable/disable。
- 仅对 `kCGEventTapDisabledByTimeout` 重新启用；`kCGEventTapDisabledByUserInput` 保持系统状态。
- 新增会话代际号（`_sessionGeneration`），过期停止请求不会终止新会话。
- 热区 `activate` 不再轮询：光标仍在边缘时保持激活中，离开边缘时立即武装。

#### v1.4.2 修复：边缘切换偶发不灵敏

- 热区宽度 `BORDER_SIZE` 由 1pt 调整为 3pt，仍只覆盖屏幕最外缘。
- 激活期间进入不再丢弃：记录为 pending fire，武装后光标仍在边缘或已越界则补发，已退回本屏则丢弃。
- 停止控制时落点向屏幕内移动 `BORDER_SIZE + 2`，避免光标停在热区内导致无法武装。
- 服务端新增越界钳制检测，不再单纯依赖 AppKit 的 `mouseEntered`。

### 兼容性提示

- `PROTOCOL_VERSION = 21`：两台 Mac 必须同时升级到 v1.4.x，否则会提示协议版本不匹配（预期行为，避免新旧混用导致事件格式错乱）。
- 首次运行仍需在「系统设置 → 隐私与安全性 → 辅助功能」中授权。

---

### Key Features

* __Client__ - Control the keyboard and pointing device of another Mac.
* __Server__ - Allow another Mac to control the system's keyboard and pointing device.
* __Pasteboard Synchronization__ - Copy and paste across Macs.

### Installation

#### Manual

1. Download the [latest release](https://github.com/Zomnus/teleport/releases/latest).
2. Unzip the archive.
3. Drag `Teleport.app` to `/Applications`.

The release archive is a universal binary (`arm64` + `x86_64`), ad-hoc signed, and requires macOS 12 or later.

#### Homebrew

```bash
brew install --cask abyssoft-teleport
```

> Note: the Homebrew cask installs the upstream release, not this fork's build.

### Project status

Teleport is a legacy project that was once closed source. After the software was discontinued, the original author made the source available to the public and passionate users have been making things work on an ad-hoc basis.

As of [`v1.2.2`](https://github.com/abyssoft/teleport/releases/tag/v1.2.2) All of the key features are known to work on macOS Big Sur.

Teleport previously allowed for file drag and drop between Macs, encrypted network traffic, and status information displays. These features likely work right now, but are unsupported and subject to removal if they break.

Our top priority is to keep the key features working smoothly on the lastest macOS operating system. We are not planning to add any new features, but [contributions are welcome](CONTRIBUTING.md).

#### Current Maintainer

__John Britton__ (@johndbritton)
* [GitHub](https://github.com/johndbritton)
* [Twitter](https://twitter.com/johndbritton)

#### Original Author

__Julien Robert__ (@abyssoft)
* [GitHub](https://github.com/abyssoft)
