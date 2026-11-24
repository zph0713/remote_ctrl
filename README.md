# MiVoice

![build](https://github.com/zph0713/remote_ctrl/actions/workflows/build.yml/badge.svg)

把小米蓝牙遥控器 2 Pro（RC003）变成 MacBook Pro 的本地语音输入设备，只保留两件事：

1. **按住语音键说话，松开后文字粘贴到当前应用**
2. **把遥控器按键映射成键盘按键 / 快捷键 / 打开应用**

为 macOS 14+ / Apple Silicon 重新实现的精简版本，参考了 [SayAll / remote-mic-app](https://github.com/HD838A/remote-mic-app) 的协议实现，但去掉了原项目的联网、自动更新、会员、虚拟声卡驱动、语音历史、MCP、多设备适配和大型 UI。

## 和 SayAll 的关键区别

| | SayAll | MiVoice |
|---|---|---|
| 语音去向 | 写入虚拟声卡，交给第三方输入法 | macOS 离线语音识别，直接得到文字 |
| 网络 | 有 Sparkle 更新、官网公告、MCP 等 | **没有任何联网代码** |
| 第三方依赖 | Sparkle、BlackHole 衍生驱动、私有会员包 | 无 |
| 音频落盘 | 不落盘 | 不落盘（只在内存） |
| 语音历史 | 可开启回眸 | 不保存 |
| 安装 | PKG + 音频驱动 + 重启 CoreAudio | 一个 `.app`，无驱动、无系统改动 |
| 代码规模 | 数十万行 | 约 2 千行 |

> 取舍：Apple 的离线中文识别通常不如豆包/微信输入法，标点和专有名词可能更差；换来的是零联网、零驱动、零音频路由故障。对“日常说一段话变成文字”足够，对“逐字听写”不一定。

## 两种语音方式

| 方式 | 需要什么 | 音频去哪 | 适合 |
|---|---|---|---|
| **Apple 离线识别**（默认） | 无额外驱动 | 只在本机内存，识别后由 MiVoice 粘贴 | 要求音频绝不出本机 |
| **微信输入法（虚拟麦克风）** | BlackHole 2ch，或 SayAll 的 MiRemoteV 2ch | 写进虚拟麦克风，由微信输入法录音/识别 | 中文准确率优先，接受微信输入法的隐私政策 |

MiVoice 不内置 HAL 音频驱动。驱动安装、CoreAudio 重启和版本冲突正是 SayAll 容易卡死的部分；这里复用已经装好的 BlackHole / MiRemoteV，应用本身仍然是一个无驱动的 `.app`。

微信输入法 2.0+ 的语音输入是**按住 Fn 说话**。MiVoice 在 HID 层把遥控器的 F5 直接映射成 Fn（和物理 Fn 一样，不是合成事件），并把 16 kHz 音频写进虚拟麦克风；普通遥控器按键同时被映射为 0，避免系统重复响应。MiVoice 本身不联网，但**微信输入法会按它自己的隐私政策处理语音**，这是选它时必须接受的取舍。

## 下载与安装（GitHub Release）

1. 打开 [Releases](https://github.com/zph0713/remote_ctrl/releases/latest)，下载 `MiVoice-v1.3.1.zip`。
2. 解压，把 `MiVoice.app` 拖进“应用程序”或 `~/Applications`。
3. 首次打开如果被 Gatekeeper 拦截：

```bash
xattr -dr com.apple.quarantine /Applications/MiVoice.app
open /Applications/MiVoice.app
```

4. 按下面的“首次启动”授权蓝牙、语音识别、辅助功能、输入监控。

发布包是 ad-hoc 签名，没有 Apple 公证；如果你有 Developer ID，可以自己重新签名：

```bash
codesign --force --deep --sign "Developer ID Application: 你的名字 (TEAMID)" /Applications/MiVoice.app
```

## 环境要求

- Apple Silicon Mac（M1/M2/M3/M4），macOS 14 或更高
- 小米蓝牙遥控器 2 Pro（RC003；HID `0x2717:0x32B8`）
- Xcode 或 Xcode Command Line Tools（只需要 `swift` 命令）
- 遥控器已在 **系统设置 → 蓝牙** 中配对

## 构建与安装

```bash
cd mivoice
swift test                 # 协议/解码/设置的单元测试
INSTALL=1 ./scripts/build-app.sh
open ~/Applications/MiVoice.app
```

只构建不安装：

```bash
./scripts/build-app.sh     # 产物在 dist/MiVoice.app
```

GitHub Actions 每次 push 会在 macOS 15 上构建、跑测试、执行联网审计，并上传 `MiVoice-app` 产物：仓库 **Actions → 最新 build → Artifacts**。产物是 ad-hoc 签名，下载后如被 Gatekeeper 拦截：

```bash
xattr -dr com.apple.quarantine ~/Downloads/MiVoice.app
```

签名：

- 默认 ad-hoc 签名（`-`），本机使用足够。
- 每次重新构建后，macOS 可能要求重新授予“输入监控”。日常使用建议用固定的签名证书：

```bash
CODESIGN_IDENTITY="Apple Development: 你的名字 (TEAMID)" INSTALL=1 ./scripts/build-app.sh
```

也可以先在“钥匙串访问 → 证书助理 → 创建证书”里建一个“代码签名”自签名证书，然后把名字传给 `CODESIGN_IDENTITY`。

> 应用没有做 Apple 公证。如果通过网络/网盘传到 Mac 后被 Gatekeeper 拦住，执行
> `xattr -dr com.apple.quarantine ~/Applications/MiVoice.app`。

## 从 SayAll 迁移

1. 菜单栏彻底退出 SayAll（不是只关窗口），并在“系统设置 → 通用 → 登录项”里移除它。
2. 不需要卸载它的虚拟声卡；MiVoice 不使用它。想彻底清理可以运行 SayAll 的卸载 PKG。
3. 确认没有 Karabiner 等其它软件占用遥控器按键。
4. 再启动 MiVoice。两个程序同时运行时，BLE 连接和 HID 独占会互相抢。

## 首次启动

应用是菜单栏图标（没有 Dock 图标）。首次启动会自动打开设置窗口，按顺序授权：

1. **蓝牙**：第一次扫描时系统会弹窗。
2. **语音识别**：弹窗允许。
3. **辅助功能**：用于把文字粘贴到当前应用、发送自定义按键。
4. **输入监控**：用于读取遥控器按键。授权后**退出并重新打开应用**。
5. **麦克风**：只在设置窗口打开时读取内建麦克风，用于“电脑麦克风”电平对比；不参与识别，不保存音频。

授权入口都在设置窗口的“权限”卡片里，点“请求”会打开对应的系统设置页。

### 让离线中文识别可用

系统必须已经安装中文听写模型：

- **系统设置 → 键盘 → 听写 → 语言 → 添加“中文（普通话）”**
- 如果从不使用系统听写，也可以在“键盘快捷键 → 听写”里把 F5 快捷键关掉，避免与遥控器语音键冲突（MiVoice 成功独占遥控器时系统看不到 F5，这一步不是必需）。

设置窗口里的“检查离线识别”会显示：

```
授权：已授权　可用：是　离线模型：有　语言支持：是
```

如果“离线模型：无”，MiVoice 会直接报错，**不会**退回联网识别。

## 用微信输入法识别（虚拟麦克风）

### 1. 安装虚拟麦克风

推荐 **BlackHole 2ch**（开源 HAL 插件，不需要内核扩展）：

```bash
brew install --cask blackhole-2ch
```

没有 Homebrew 的话，从 [BlackHole Releases](https://github.com/ExistentialAudio/BlackHole/releases) 下载 `BlackHole2ch.pkg` 安装。安装会重启 CoreAudio，期间声音会短暂中断。

如果机器上还留着 SayAll 的 `MiRemoteV 2ch`，MiVoice 会直接识别它，不必再装 BlackHole。

### 2. 在 MiVoice 里选择

设置 → **语音方式**：

- 识别方式：`微信输入法（虚拟麦克风）`
- 虚拟麦克风：`BlackHole 2ch`（或 `MiRemoteV 2ch`）
- 打开“语音时自动切换系统输入到虚拟麦克风”

点“重新应用 Fn 映射”，状态应显示 `已映射 F5 → Fn`。然后按住遥控器语音键试一次。如果微信输入法没反应，先确认：

- 微信输入法 2.0.0 或更高版本；
- 微信输入法已在“系统设置 → 键盘 → 输入法”中启用，并且当前是活动输入法；
- 焦点在一个可输入的文本框里；
- MiVoice 有“输入监控”和“辅助功能”权限（HID 映射与按键注入需要）。授予输入监控后要**退出并重新打开 MiVoice**，否则 HID 服务列表可能为空。

### 3. 微信输入法的设置

微信输入法 2.0+ 默认**按住 Fn 说话**，一般不需要改快捷键。如果它有自己的麦克风选项，选 `BlackHole 2ch`；如果没有，就依赖 MiVoice 的“自动切换系统输入”。也可以在“系统设置 → 声音 → 输入”里确认当前输入是 `BlackHole 2ch`。

### 4. 使用

把光标放进输入框 → 按住遥控器语音键说话 → 松开。系统把遥控器 F5 当作 Fn，微信输入法负责录音、识别和上屏；MiVoice 只把音频写进虚拟麦克风，不再自己粘贴文字。

> 设置页有两根电平条：上面是**遥控器麦克风**（BLE 音频 → 虚拟麦），下面是**电脑麦克风**（内建麦，仅在设置窗口打开时监听）。对着遥控器说话看上条，对着电脑说话看下条，就能确认声音来源。
>
> 如果微信输入法仍用内置麦：先把系统输入设为 `BlackHole 2ch`，然后**重启微信输入法**（有些版本会缓存输入设备）。

> 隐私：这条链路里 MiVoice 不上传任何数据，但微信输入法会按它自己的隐私政策处理语音（通常需要联网）。如果要求音频绝不出本机，请用默认的 `Apple 离线识别`。

## 使用

- **语音**：按住遥控器语音键，说一句话，松开。文字会粘贴到当前焦点所在的输入框。
- **按键**：默认方向键 / 确定 / 返回 / 主页 / 菜单 / TV / 音量，按设置里的映射执行。
- **三种手势**：每个按键可分别设置单击、双击、长按；未配置双击/长按时会立即执行单击。双击窗口 300 ms，长按 550 ms。
- **自定义快捷键**：设置 → 遥控器按键 → 选手势 → 类型选“自定义快捷键” → 点“录制” → 按下组合键（Esc 取消）。
- **输入文字**：类型选“输入文字”，填入常用短语；按键时粘贴到当前输入框。
- **打开应用**：类型选“打开应用” → 选择 `.app`。
- **电源键默认无动作**，避免误触睡眠；可以自行映射成“锁定屏幕”。

按住语音键期间菜单栏图标会变成波形；松开后显示“识别中…”，完成后显示“已输入 N 字”。

## 隐私与安全

设计上的硬约束：

- `Sources/` 中没有 `URLSession`、`Network`、`WebKit`、`http(s)://` 等联网代码；
- `Package.swift` 没有外部依赖；
- 没有 Sparkle、没有官网检查、没有账号、没有统计、没有云同步；
- 音频只在进程内存中解码，不写临时文件、不写日志；
- Apple 模式使用 `SFSpeechRecognizer`，每个请求都设置 `requiresOnDeviceRecognition = true`；没有离线模型时请求失败，不会把音频发给服务器；
- 微信输入法模式只把音频写进本机虚拟声卡；音频之后由微信输入法处理，MiVoice 无法控制其上传行为；
- 识别结果只粘贴到当前应用，不保存历史；
- 剪贴板在粘贴后自动恢复（可在设置中关闭）；
- 日志只有连接状态和错误，不记录语音、文字、遥控器地址或前台应用。

自检：

```bash
./scripts/audit.sh
sudo lsof -i -p "$(pgrep MiVoice)"    # 应没有任何网络连接
```

进一步审计入口：

- `Sources/MiVoice/BLE/RemoteLink.swift`：CoreBluetooth，只连接 RC003
- `Sources/MiVoice/Speech/SpeechEngine.swift`：离线识别
- `Sources/MiVoice/Input/RemoteButtons.swift`：IOHID 按键
- `Sources/MiVoice/Input/KeyInjector.swift`：CGEvent / 剪贴板

## 稳定性设计

- 单线程主队列状态机，CoreBluetooth 回调固定在 main queue；
- 一次只允许一个连接尝试、一个重连定时器、一个识别会话；
- 连接 10 秒超时、语音通道初始化 8 秒超时、单次语音最长 60 秒；
- 断线按 2/4/8/15 秒退避重连，唤醒后自动重连；
- HID 报告做 30ms 去重，避免多接口重复触发；
- 只对遥控器自己的 HID 服务做设备级 `UserKeyMapping`（退出/锁屏时恢复），不安装驱动、不重启 CoreAudio、不创建全局事件 tap；
- 权限缺失时**关闭相关功能并明确提示**，而不是带着半失效状态运行。

## 诊断日志

MiVoice 会把运行日志写到 `~/Library/Logs/MiVoice/MiVoice.log`（超过 2 MB 轮转，保留 4 份）。日志包含：

- 应用版本、macOS 版本、CPU 架构、权限状态；
- 休眠/锁屏/唤醒的每个步骤及耗时；
- BLE 扫描/连接、HID 打开/独占、Fn 映射写入/恢复；
- 虚拟麦克风、内建麦克风、系统输入切换的结果和错误；
- 主线程看门狗：主线程超过 4 秒不响应时写入 `WATCHDOG main thread stalled ... lastStep=...`。

**不记录**音频、识别出的文字或剪贴板内容。

卡死或异常后：

1. 强制退出 MiVoice（菜单栏 → 退出，或活动监视器）。
2. 重新打开 MiVoice。
3. 菜单栏 → **导出诊断日志…**，会在桌面生成 `MiVoice-Diagnostics-<时间>.zip`。
4. 把 zip 发给我；里面包含日志、系统信息和最近的 MiVoice 崩溃/挂起报告。

也可以直接点“打开日志文件夹”查看 `MiVoice.log`。

## 故障排查

| 现象 | 处理 |
|---|---|
| 设置里“输入监控：未授权” | 点“请求”，然后在系统设置里打开开关，点“退出并重新打开” |
| “仅监听（自定义按键停用）” | 有别的软件（SayAll、Karabiner 等）占着遥控器。退出它们，点“重试” |
| 按语音键触发了系统听写 | 关闭系统听写快捷键，或确认 MiVoice 已独占（“已独占”状态） |
| 没有识别到语音 | 确认“离线模型：有”；靠近遥控器；按住键说完再松开 |
| 微信输入法没反应 | 确认“Fn 映射：已映射 F5 → Fn”；点“重新应用 Fn 映射”；确认它是当前输入法、焦点在文本框，且 MiVoice 有输入监控/辅助功能权限 |
| 设置里“遥控器麦克风”电平不跳 | 遥控器麦克风没开或 BLE 音频没通：重连遥控器；确认没有别的 App 占着遥控器 |
| 设置里“电脑麦克风”电平不跳 | 授权麦克风；确认状态显示“监听中：内建麦克风”；如果仍不动，退出并重开 MiVoice |
| 电平在跳但微信输入法没字 | 微信输入法没录到虚拟麦克风：把系统输入设为 `BlackHole 2ch`，**退出并重开微信输入法**；再检查微信输入法自己的麦克风设置 |
| 微信输入法仍用内置麦 | 先把系统设置 → 声音 → 输入设为 `BlackHole 2ch`，再重启微信输入法；有些版本会缓存输入设备 |
| 识别成功但没有文字 | 授权“辅助功能”；确认当前有文本输入焦点；密码框等安全输入框不支持粘贴 |
| 找不到遥控器 | 在系统设置 → 蓝牙里确认已配对；按一下遥控器按键唤醒；点“重新连接” |
| 重启后权限又没了 | 使用了 ad-hoc 签名。改用固定证书签名，或重新授权 |

## 已知限制

- 只适配 RC003（小米蓝牙遥控器 2 Pro）。其他型号需要改 `RemoteButton` 的 usage 表和 `RemoteButtons` 的 VID/PID。
- 不支持长按连发；方向键需要重复按。
- 单次语音上限 60 秒。
- 不做实时逐字上屏，只在松开后一次性粘贴，因此松开到出字有约 1 秒延迟。
- 不内置 HAL 驱动：微信输入法模式需要预先安装 BlackHole 2ch，或使用 SayAll 的 MiRemoteV 2ch。
- 不提供自动更新；升级就是重新构建、替换 `.app`。

## 目录结构

```
Sources/MiVoiceCore/     纯 Foundation：ATVV、ADPCM、HID 报告解析、设置模型
Sources/MiVoice/         AppKit/SwiftUI 应用：BLE、语音、按键、注入、界面
Tests/MiVoiceCoreTests/  协议与设置的单元测试（可在 Linux 上跑）
Packaging/Info.plist     TCC 用途说明、LSUIElement
scripts/build-app.sh     构建 .app 并签名
scripts/audit.sh         联网 API / 依赖审计
docs/ARCHITECTURE.md     协议与数据流细节
```

## 许可证

GPL-3.0-only。部分协议与解码代码改编自 [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app) 与 [xxb26553663-star/remote-bridge-hub](https://github.com/xxb26553663-star/remote-bridge-hub)，详见 `NOTICE`。本项目不使用 SayAll 的 Logo/图标资源。
