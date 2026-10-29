# teleport-pro
## A Virtual KVM for macOS

[![Release](https://img.shields.io/badge/release-v1.4.10-blue)](https://github.com/Zomnus/teleport-pro/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2012%2B-lightgrey)](#installation)

Use one keyboard and pointing device to control multiple Macs.

> Forked from [johndbritton/teleport](https://github.com/johndbritton/teleport).
> This repository is maintained independently; the upstream is no longer updated and this project does not sync with it.

---

## 本次优化说明（v1.4 → v1.4.10）

本仓库 fork 自 [johndbritton/teleport](https://github.com/johndbritton/teleport)（原始作者 [abyssoft](https://github.com/abyssoft)）。上游已停止维护，本项目独立维护、不再与上游同步，仅保留来源记录。针对两台 Mac 之间切换键鼠时的「顺滑度」完成了一轮性能优化与稳定性修复，当前版本为 **v1.4.10**。

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

#### v1.4.3 修复：长时间运行 / 锁屏后的可靠性与手感

- 控制请求增加 2 秒超时：连接僵死时自动断开并用新连接重试一次，不再卡在「连接中」导致后续切换全部失效。
- 服务端只响应当前控制连接的断开事件，旧连接被系统回收时不再误杀正在使用的会话。
- 服务端补上已接受连接的释放逻辑，修复每次重连都会滞留一个连接对象的问题。
- 重复控制请求直接确认，不再重复创建热区窗口和事件源。
- TCP 连接改为后台异步建立，对端睡眠或不可达时主线程不再阻塞；同时用 5 秒看门狗兜底。
- keepalive 调为 60 秒空闲 + 10 秒 × 3 次探测，死连接可被发现且不易误断健康的空闲连接。
- 控制期间每秒检查 event tap 状态，被系统禁用时自动恢复（安全输入和锁屏期间不强行恢复）。
- 申请 `NSActivityUserInitiatedAllowingIdleSystemSleep`，避免 App Nap 降低事件转发线程的优先级。
- 显示参数变化时同时刷新实际使用的 Direct 事件控制器，避免会话中途光标位置漂移。
- 保持 1.4.2 的宽事件掩码：触控板手势等私有事件类型必须继续被捕获，否则手势会落在本机执行。
- Settings 选项卡底部显示当前版本号。

#### v1.4.4：服务端注入移出主线程

- 接收端的事件解码、虚拟光标积分与 `CGEventPost` 从 CFSocket 回调所在的主 RunLoop 移到专用串行队列（`QOS_CLASS_USER_INTERACTIVE`），主线程忙于 UI 或显示重配时不再推迟注入。
- 屏幕几何只在主线程查询，注入队列读取不可变快照；越界回切检测涉及 AppKit，仍交回主线程执行。
- `startPostingEvents` / `stopPostingEvents` 与光标 warp 用同步派发，保证与事件严格同序。

#### v1.4.5：切换过渡期补发 + 可选 UDP 指针通道

- 越过边缘发出控制请求时即开始缓存移动（上限 80ms / 48 条），控制确认后按原时间戳顺序补发；失败、超时或被拒绝则丢弃。只补发移动，点击和按键不补发，不会重复输入。
- 新增可选 UDP 指针通道（`COMMAND_PORT + 2`）：键、点击、滚轮仍走 TCP 保证有序，**悬停移动**可走 UDP，单个丢包不再阻塞后续输入。
  - 协商方式：服务端在原有的控制成功消息里附带每次会话随机的 token，旧客户端会忽略这段附加数据。
  - 自愈回落：客户端发 HELLO 等待 ACK（最多约 400ms），收不到就整场继续走 TCP；防火墙拦截或对端版本不支持时行为与之前完全一致。
  - 接收端按序号丢弃过期/乱序包，并在应用任何 TCP 事件之前排空已到达的移动，保证点击落在用户看到的位置。
- `PROTOCOL_VERSION` 仍为 21，1.4.2 ~ 1.4.6 可互通。

#### v1.4.6 修复

- 按住鼠标的拖拽重新走 TCP：UDP 增量包无法还原原始按键标志与严格顺序，1.4.5 会导致窗口拖不动。悬停移动仍走 UDP。
- 控制期间每秒检查一次光标可见性：被全屏应用或 Space 切换重新显示时再次隐藏；隐藏次数计入恢复计数，结束控制时按次数还原，不会出现控制结束后光标消失的问题。

#### v1.4.7：项目更名为 teleport-pro

- 应用名、可执行文件、偏好设置窗口与关于窗口中的名称统一改为 **teleport-pro**，图标沿用原设计。
- 发布产物更名为 `teleport-pro-<version>-macos.zip`。
- 仓库已退出上游 fork 网络并重命名为 `teleport-pro`，仅在 About 与 README 中保留 "Forked from johndbritton/teleport" 的来源记录。
- 本次仅改名，未改动事件转发与网络协议，`PROTOCOL_VERSION` 仍为 21，与 v1.4.2 ~ v1.4.6 可互通。

#### v1.4.8 修复：菜单栏与弹出菜单点击无响应

- 现象：远程控制时，菜单栏状态下拉菜单、弹出菜单中的条目可以悬停高亮，但点击无反应（例如点击 Teleport 状态栏菜单的 `Configure…` 打不开偏好设置）。
- 根因：直通路径把源 Mac 的完整 CGEvent 归档原样传输，其中私有字段 107（WindowServer 连接标识）保留了发送端的值。该值在受控 Mac 上不属于任何本地连接，WindowServer 仍按坐标跟踪悬停并分发普通窗口点击，但 NSMenu 会丢弃连接标识不匹配的点击。macOS 27.2 收紧了该校验后问题暴露。
- 修复：接收端在 `CGEventCreateFromData` 之后、注入之前将该字段清零，由本机 WindowServer 重新盖章，行为与旧的手写序列化路径一致；普通窗口、拖拽、键盘与滚动不受影响。
- 协议未变，`PROTOCOL_VERSION` 仍为 21，可与 v1.4.2 ~ v1.4.7 互通。

#### v1.4.9 修复：Shift + 受控 Mac 本机触摸板无法连选

- 现象：用 MacBook Air 的键盘按住 Shift、同时用 Mac mini 的触摸板点击时，访达无法 Shift 连选，文档内无法 Shift 选字；键盘与触摸板都使用 Air 时正常。
- 根因：修饰键状态分 HID 与 session 两层。注入的 `flagsChanged` 只投到 session tap，只更新 session 状态；受控 Mac 的**本机硬件点击**的修饰标志由 HID 状态生成，因此看不到远程按下的 Shift。
- 修复：接收端把 `flagsChanged` 改投到 HID event tap（其他事件仍走 session tap），直通与手写序列化两条路径同时生效；协议未变，`PROTOCOL_VERSION` 仍为 21。

#### v1.4.10 修复：远程修饰键未作用于受控 Mac 的本机硬件点击

- v1.4.9 把 `flagsChanged` 改投 HID tap 只能短时间改变 HID 状态，受控 Mac 的触摸板/键盘一旦产生真实 HID 事件，系统会用本机硬件键盘状态重新盖章，远程按下的 Shift 仍然丢失。
- 修复：接收端在会话期间安装一个本地事件 tap，记录发送端当前按住的修饰键（Shift/Control/Option/Command），并仅对**本机真实硬件输入**的鼠标按下/抬起/拖拽事件补上这些标志；注入事件与普通输入不受影响。
- 现在「Air 键盘 Shift + mini 触摸板」也能正常连选文件与选字；Air 触摸板 + Air 键盘的组合行为不变。协议未变，`PROTOCOL_VERSION` 仍为 21。

### 兼容性提示

- `PROTOCOL_VERSION = 21`：两台 Mac 必须同时升级到 v1.4.x，否则会提示协议版本不匹配（预期行为，避免新旧混用导致事件格式错乱）。
- v1.4.4 ~ v1.4.10 均未改动协议，与 v1.4.2 / v1.4.3 可互通。
- UDP 指针通道是可选项：两端都升级时自动启用，任一条件不满足（旧版本、防火墙、端口占用）都会自动回落到纯 TCP，不需要手动配置。
- 首次运行仍需在「系统设置 → 隐私与安全性 → 辅助功能」中授权。

---

### Key Features

* __Client__ - Control the keyboard and pointing device of another Mac.
* __Server__ - Allow another Mac to control the system's keyboard and pointing device.
* __Pasteboard Synchronization__ - Copy and paste across Macs.

### Installation

1. Download the [latest release](https://github.com/Zomnus/teleport-pro/releases/latest).
2. Unzip the archive.
3. Drag `teleport-pro.app` to `/Applications`.

The release archive is a universal binary (`arm64` + `x86_64`), ad-hoc signed, and requires macOS 12 or later.

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
