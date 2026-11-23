# MiVoice

把小米蓝牙遥控器 2 Pro（RC003）变成 Mac 的本地语音输入和自定义按键工具。

## 本次更新（1.1.1）

- **修复微信输入法模式没有文字**：不再合成 Fn 事件，改为在 HID 层把遥控器 F5 映射成 Fn，和物理 Fn 键走同一条路径。
- 新增虚拟麦克风电平条、测试音和“没有收到遥控器音频”提示，方便定位音频通路。
- Apple 离线模式说话时，悬浮提示会**实时显示已识别的文字**，不用等松开。
- 新增微信输入法（虚拟麦克风）模式：音频写入 BlackHole 2ch / MiRemoteV 2ch。
- 支持语音期间自动切换系统输入并在结束后恢复。
- 新增 Fn 映射状态、重新应用映射和虚拟麦克风设置。

## 下载

- **MiVoice.app**：下载本页下方的 `MiVoice-<版本>.zip`（例如 `MiVoice-v1.1.1.zip`）
- **源码**：GitHub 自动生成的 Source code 压缩包，或 `git clone https://github.com/zph0713/remote_ctrl.git`

要求：Apple Silicon Mac（M1 及以上），macOS 14 或更高，遥控器已在系统设置 → 蓝牙中配对。

## 安装

1. 解压下载到的 `MiVoice-<版本>.zip`。
2. 把 `MiVoice.app` 拖进“应用程序”或 `~/Applications`。
3. 首次打开如果被 Gatekeeper 拦截：

```bash
xattr -dr com.apple.quarantine /Applications/MiVoice.app
open /Applications/MiVoice.app
```

发布包使用 ad-hoc 签名，没有 Apple 公证。有 Developer ID 可以自行重签：

```bash
codesign --force --deep --sign "Developer ID Application: 你的名字 (TEAMID)" /Applications/MiVoice.app
```

## 首次启动

菜单栏会出现麦克风图标。按设置窗口的顺序授权：

1. **蓝牙**：连接遥控器。
2. **语音识别**：Apple 离线识别需要。
3. **辅助功能**：粘贴文字、发送按键需要。
4. **输入监控**：读取遥控器按键；授权后点“退出并重新打开”。

## 两种语音方式

### Apple 离线识别（默认，推荐隐私优先）

不需要任何驱动。按住遥控器语音键说话，松开后 MiVoice 用 macOS 离线模型识别并粘贴到当前输入框。

系统设置 → 键盘 → 听写 → 语言 → 添加“中文（普通话）”，否则设置里的“离线模型”会显示“无”。

### 微信输入法（虚拟麦克风）

需要先安装 **BlackHole 2ch**（或使用 SayAll 留下的 `MiRemoteV 2ch`）：

```bash
brew install --cask blackhole-2ch
```

然后：

1. MiVoice 设置 → 语音方式 → `微信输入法（虚拟麦克风）`
2. 虚拟麦克风 → `BlackHole 2ch`
3. 打开“语音时自动切换系统输入到虚拟麦克风”
4. 点“重新应用 Fn 映射”，确认状态为 `已映射 F5 → Fn`

微信输入法 2.0+ 默认**按住 Fn 说话**。MiVoice 在 HID 层把遥控器 F5 映射成 Fn，并把 16 kHz 音频写入虚拟麦克风；系统/微信输入法收到的是和物理 Fn 一样的按键事件。由微信输入法负责识别和上屏。

如果微信输入法没有反应：确认它是当前输入法、焦点在文本框、MiVoice 有辅助功能权限；也可以手动把系统设置 → 声音 → 输入设为 `BlackHole 2ch`。

> 隐私：MiVoice 本身没有任何联网代码。Apple 模式音频绝不出本机；微信输入法模式只把音频写进本机虚拟声卡，之后由微信输入法按其隐私政策处理（通常需要联网）。

## 自定义按键

设置 → 遥控器按键，可把方向键、确定、返回、主页、菜单、TV、电源、音量映射成：

- 预设动作（回车、Esc、删除、方向键、切换应用、显示桌面等）
- 自定义快捷键（点“录制”，按组合键）
- 打开指定应用

按键通道显示“已独占”时自定义按键可用；显示“仅监听”说明被 SayAll / Karabiner 等程序占用，退出它们后点“重试”。

## 从 SayAll 迁移

1. 菜单栏彻底退出 SayAll，并在“系统设置 → 通用 → 登录项”移除它。
2. 不需要卸载它的虚拟声卡；MiVoice 会识别 `MiRemoteV 2ch`。
3. 再启动 MiVoice，避免两个程序抢 BLE 和 HID。

## 已知限制

- 只适配 RC003（小米蓝牙遥控器 2 Pro）。
- 不支持长按连发。
- 单次语音上限 60 秒。
- 不内置 HAL 驱动；微信输入法模式需要 BlackHole 2ch 或 MiRemoteV 2ch。
- 不提供自动更新。

## 许可证

GPL-3.0-only。协议与音频路由部分改编自 HD838A/remote-mic-app、xxb26553663-star/remote-bridge-hub 和 ericyangpan/mi-remote-helper，详见仓库 `NOTICE` 与 `LICENSE`。
