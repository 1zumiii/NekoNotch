<h1 align="center">Boring Notch · Izumi Edition</h1>

<p align="center">简体中文 · <a href="README.en.md">English</a></p>

<p align="center">
  基于 <a href="https://github.com/TheBoredTeam/boring.notch">Boring Notch</a> 的个人定制版本，在刘海中加入通知、仪表盘和应用混音器。<br>
  上游原版的说明保留在 <a href="README.upstream.md">README.upstream.md</a>。
</p>

---

## 项目说明

本 fork 基于 [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) 的 `v2.8-rc.2`，增加了日常使用所需的功能，并修复了在 macOS 26 和 27 上遇到的问题。

- 默认分支为 `custom-main`，只从上游合并更新，不向上游推送或提交 PR。
- 已关闭应用内更新（Sparkle），防止官方版本覆盖自定义改动。“关于”页显示 `Izumi Edition ✨ 1.1.0`。跟进上游更新时，需要将上游改动合并到 `custom-main`，再重新编译。
- 日常使用和测试主要在 macOS 27 上完成。系统要求沿用上游的 macOS 14+，其中混音器依赖的 Core Audio 进程 tap 需要 macOS 14.2 及以上。

## 新增功能

### 通知接管

通知可以直接显示在刘海里。也可以关闭应用的系统横幅，只保留刘海中的通知。

- 横幅读取：通过辅助功能读取系统通知横幅，将横幅移到屏幕外，再在刘海中显示。
- 自动展开：收到通知时自动展开刘海，无需移入鼠标。停留时间可设为 2～30 秒，结束后自动收起。
- 应用过滤：显示所有应用的通知，或只显示选中的应用。
- 排除应用：列表中的应用不在刘海中显示，系统横幅也不会被隐藏。最近发过通知的应用会列在设置页中，方便直接加入。macOS 的后台代理（如“后台项目”）统一使用一个名称和图标。
- 仅显示图标：指定的应用收到通知时，只在收起的刘海左侧显示应用图标。播放音乐时，图标暂时替换专辑封面。图标右下角带有小圆点，用于标识通知。
- 点击跳转：点击通过横幅读取的通知时，会触发对应系统横幅的点击操作，由应用打开对应的会话或位置。
- 数据库读取：直接读取通知中心数据库，需要完全磁盘访问权限。开启后，即使在系统设置中关闭了某个应用的横幅，它的通知仍会显示在刘海中，也能避免系统横幅短暂闪现。
- 来源应用预览：关闭横幅的应用收到通知时，先显示应用图标。约 5 秒后，系统将正文写入数据库，再在原位置补上文字。提前显示图标所用的信号，来自系统日志中 `usernoted` 的“通知已入库”记录。
- 时间敏感通知：数据库中标记为“时间敏感”或“紧急”的通知，会在两侧和底部显示旋转彩虹描边，停留时间翻倍。普通通知会排队，等这条通知收起后再显示。判定依据是数据库记录中的 `intrp` 字段：“被动”级别已用实测验证，“时间敏感”和“紧急”级别按系统的等级定义推断，尚未用真实通知验证。
- 服务状态：通知设置页顶部列出后台助手、横幅读取、数据库读取和早期信号的运行状态，以及最近一次事件的时间。通知没有出现时，可以在这里检查状态或点击“重启服务”。
- 测试通知：在下拉框中选择真实系统通知、普通通知或时间敏感通知，然后发送。

应用图标查找也覆盖了 `/System/Applications/Utilities`。应用名与 Bundle ID 的映射改为在后台建立索引，避免查找时卡顿 1～2 秒。

### 通知历史与专注模式

- 通知标签页：刘海中新增“通知”标签页，按时间倒序列出最近 50 条通知，显示应用、时间、标题和正文。点击通知会打开对应的应用；悬停时可删除单条通知，左侧按钮可清除全部通知。有未查看的通知时，标签页图标右上角显示红点。
- 隐私：历史只保存在内存中，不写入磁盘，退出应用后清空。在通知设置中关闭“保留通知历史”后，标签页随之隐藏。
- 专注模式联动：开启专注模式后，系统会隐藏部分通知横幅，但通知仍会写入数据库。默认的“跟随专注模式”只在刘海中显示系统允许提醒的通知，包括仍有横幅的通知和时间敏感通知。其余通知仅记入历史，并带有月亮标记。也可以改为“显示全部通知”或“全部不显示”。
- 专注模式状态读取自 `~/Library/DoNotDisturb/DB`，需要完全磁盘访问权限。手动开启的专注模式可以识别，按计划自动开启的专注模式无法识别。

### 仪表盘（Dashboard）

仪表盘采用 12 × 4 的网格布局，可以在设置中调整每张卡片的位置和尺寸，例如 4 × 4 或 6 × 2。旧版本保存的布局会自动转换为新的网格尺寸。

- Claude 和 Codex 用量：读取 RunCat 集成脚本生成的快照，路径分别为 `~/Library/Application Support/RunCatIntegrations/claude-usage.json` 和 `~/.codex/runcat-usage.json`。标题下方显示数据的更新时间，右侧的圆点表示数据新旧。
- Claude Code：读取同一目录下的 `claude-code-stats.json`，显示累计 Token 数和最近几周的每日用量热力图。
- 存储空间：用环形图和文字显示磁盘用量，图表与文字均匀排列。
- 电池用量：按耗电量列出排名靠前的应用，统计范围为各进程启动以来的能耗。沙盒不允许读取其他进程的信息，因此由 XPC 助手读取，且仅在卡片显示时读取。
- 系统：显示 CPU 占用、已使用内存（与活动监视器的口径相同）和网络上下行速度，只在卡片显示时每 2 秒采样一次。网速只统计 Wi-Fi 和以太网接口，避免 VPN 流量被重复计算。

各张卡片共用同一套卡片和仪表组件。卡片内容超出所在格子时会被裁剪，不会覆盖相邻的卡片。

### 混音器（Mixer）

混音器提供类似 SoundSource 的应用音量控制，基于 Core Audio 进程 tap 实现。

- 单独调整每个正在播放音频的应用的音量，支持静音和独奏。
- 调整左右声道平衡，或切换为单声道。
- 为每个应用选择输出设备。
- 显示实时电平，仅在页面可见时计算。混音器已启用但页面不可见时，CPU 占用约为单核的 0.2%～0.3%。

没有应用播放音频时，页面中央会显示一行提示。首次使用需要按提示授予“系统音频录制”类权限。

### 剪贴板临时区

暂存区（Shelf）中加入了剪贴板区域。内容按列表纵向排列，每条显示一行，超出部分用省略号截断。支持一键清空，也可以在设置中关闭剪贴板区域。

### 电池与充电提醒

- 低电量提醒支持多个阈值，默认提供 20%、10% 和 5%，可在设置中勾选。提醒不会反复弹出。
- 充电提示改为居中的圆角面板，断开电源时只提示一次，状态文字支持中文。
- 电池线：可以在收起的刘海下方显示一条细的电量线。电量线位于刘海轮廓外侧，不会被硬件刘海遮挡。充电时有一道光沿电量线从左向右扫过；电量在 20% 及以下时显示红色光晕；线的外侧有一圈深色描边，在浅色窗口上也清晰可见。设置中提供预览低电量和充电效果的按钮。

### 音乐波形

新增“炫彩波形”选项，使用 Core Animation 播放循环动画，CPU 占用很低。颜色变化速度可通过滑块调整，设为 0 时颜色保持静止。

音频电平按像素量化后再发布，没有组件使用音频数据时停止 FFT 计算。

## 修复与优化

- macOS 27 通知接管：新系统将所有横幅放在一个全屏窗口中，原先按窗口高度过滤的逻辑会忽略这些横幅。现在改为识别横幅元素，并区分侧边通知栏条目与实时横幅。打开通知栏时，不再错误移动窗口或反复弹出通知。
- 通知正文补全：连续收到两条通知时，前一条的图标占位可能被后一条替换，随后到达的正文又会被当作重复通知丢弃。已修复这一问题。
- 刘海底部缝隙：macOS 27 的菜单栏比刘海高 1～2 pt，现在刘海高度会跟随菜单栏调整。
- OSD 设置页：补上页面标题，避免沿用上一页的标题。
- 日历：刘海展开动画期间显示骨架屏，待尺寸稳定后再显示日程列表，避免列表反复换行和滚动。
- 通知收起：修复自动展开后误判鼠标悬停、导致通知一直停留的问题。刘海自动关闭时，通知视图也不会提前消失。
- 助手启动：清理上次强制终止后残留的 `log stream` 孤儿进程。
- 助手服务：睡眠唤醒、连接中断或横幅监听失效后，自动重启后台助手的通知服务。早期信号忽略只带角标、没有文字的通知请求。
- 刘海收起：用户关闭通知时，即使指针仍在刘海上，刘海也会收起；拖动文件打开的刘海，在拖动结束且指针不在刘海上时收起。
- 功耗：充电扫光和时间敏感通知的彩虹描边都由 Core Animation 播放，动画运行时主进程几乎不占 CPU。混音器仅在页面打开或有应用音频经由混音器输出时轮询 Core Audio；通知数据库改为在文件变更时读取，并保留低频定时检查；剪贴板每秒检查一次。
- 简体中文：补全了大部分未翻译的文字，自定义功能的界面也提供了中文翻译。

## 编译与安装

需要 macOS 15.6+ 和 Xcode 26+。

```bash
git clone https://github.com/1zumiii/BoringNotch-Custom.git
cd BoringNotch-Custom
git checkout custom-main
open boringNotch.xcodeproj
```

在 Xcode 中打开项目后即可运行。如果需要在重新构建后保留辅助功能和完全磁盘访问授权，每次构建后都要使用固定的代码签名要求重新签名：

```bash
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build

codesign --force --sign - --preserve-metadata=entitlements,flags,runtime \
  -r='designated => identifier "theboringteam.boringnotch"' \
  "build/Build/Products/Release/Boring Notch.app"
```

**只对最外层 App 签名，不要加 `--deep`。** `--deep` 会破坏 XPC 助手的签名，导致通知接管提示缺少辅助功能权限。

## 需要的权限

| 权限 | 用途 |
| --- | --- |
| 辅助功能 | 读取系统通知横幅，并将横幅移到屏幕外 |
| 完全磁盘访问 | 读取通知数据库，用于关闭横幅后的通知展示、来源应用预览和时间敏感通知识别；读取专注模式状态 |
| 系统音频录制 | 控制各应用的音量，读取音频电平 |
| 日历、提醒事项和相机等 | 用于上游已有功能 |

## 自定义功能的代码位置

| 位置 | 内容 |
| --- | --- |
| `boringNotch/managers/SystemNotificationManager.swift` | 通知展示、队列、占位符和优先级 |
| `boringNotch/managers/NotificationDatabaseWatcher.swift` | 读取通知数据库 |
| `boringNotch/managers/NotificationHistory.swift`、`components/Notch/NotificationHistoryView.swift` | 通知历史与通知标签页 |
| `boringNotch/managers/FocusStatusMonitor.swift` | 读取专注模式状态 |
| `BoringNotchXPCHelper/NotificationWatcher.swift`、`EarlyNotificationSource.swift` | 横幅读取和早期信号，在 XPC 助手中运行 |
| `boringNotch/components/Dashboard/`、`components/Usage/` | 仪表盘与用量 |
| `boringNotch/components/Mixer/`、`managers/AudioCaptureManager.swift` | 混音器与音频采集 |
| `boringNotch/models/BatteryAlertTracker.swift` | 电量提醒 |
| `boringNotch/components/Notch/NotchShape.swift` | 电池线与充电扫光 |
| `boringNotch/CustomBuild.swift` | 关闭更新、自定义版本号 |

## 致谢与许可

感谢上游项目 [Boring Notch](https://github.com/TheBoredTeam/boring.notch) 及其贡献者，以及 [MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)、[NotchDrop](https://github.com/Lakr233/NotchDrop) 等依赖的作者。图标由 [@maxtron95](https://github.com/maxtron95) 制作。

本 fork 沿用上游许可证，见 [LICENSE](LICENSE) 和 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)。
