# 架构与协议

## 数据流

```
RC003 (BLE)
 ├─ HID report (reportID 1) ──► RemoteButtons ──► AppModel ──► KeyInjector (CGEvent)
 │                                   │
 │                                   └─ voice key 0x3E ──► beginVoice/endVoice
 │
 └─ ATVV GATT
      ├─ Control 0x0B capabilities
      ├─ Control 0x04 audio start, 0x00 stop, 0x0A sync
      └─ Audio  ADPCM frames ──► IMAADPCMDecoder ──► PCM 16 kHz
                                     └─► SpeechEngine (Speech.framework, on-device)
                                              └─► AppModel ──► paste text
```

## ATVV

| 用途 | UUID |
|---|---|
| Service | `AB5E0001-5A21-4F05-BC7D-AF01F617B664` |
| Transmit | `AB5E0002-5A21-4F05-BC7D-AF01F617B664` |
| Audio (notify) | `AB5E0003-5A21-4F05-BC7D-AF01F617B664` |
| Control (notify) | `AB5E0004-5A21-4F05-BC7D-AF01F617B664` |

连接顺序：

1. 订阅 Audio 和 Control；
2. 两者都进入 notifying 后，向 Transmit 写 `0A 01 00 00 03 03`（v1.0 get capabilities）；
3. 收到 `0x0B` 能力包，校验 16 kHz（codec `0x02`），进入 ready；
4. 遥控器按语音键时发 `0x04`，随后 Audio 上出现 ADPCM 帧；松开发 `0x00`；
5. 主机也可以在按住语音键时发 `0x0C 0x00` 主动打开麦克风。

能力包：

```
0B | version_hi version_lo | codecs | interaction | frame_hi frame_lo
```

`frameSize` 默认 120 字节 → 240 个 16 kHz 样本 → 15 ms。

ADPCM：IMA/DVI，高半字节优先；每个 `0x0A` 同步包携带 predictor（bytes 4–5，大端有符号）和 step index（byte 6），收到后重置解码器。

## HID

- 匹配：`kIOHIDVendorIDKey = 0x2717`，`kIOHIDProductIDKey = 0x32B8`
- 报告：report ID 1，2 字节一个小端 usage，最多 3 个同时按下的键
- 语音键：`0x3E`（F5），部分固件也用 `0x0C`
- 使用 `IOHIDManagerOpen(..., kIOHIDOptionsTypeSeizeDevice)` 独占，系统不再收到遥控器按键
- 独占失败时退回普通监听：语音仍可用，但自定义按键停用，避免同一按键触发两次系统动作

## 语音识别

每个会话：

1. `SFSpeechRecognizer(locale:)`，要求 `supportsOnDeviceRecognition == true`
2. `SFSpeechAudioBufferRecognitionRequest`，`requiresOnDeviceRecognition = true`
3. 把 PCM 转成 16 kHz 单声道 Float32 `AVAudioPCMBuffer` 追加
4. 松开语音键 → `endAudio()`
5. `isFinal` 或 4 秒超时 → 取 `bestTranscription.formattedString`
6. 通过剪贴板 + `⌘V` 粘贴，0.8 秒后恢复原剪贴板

不使用 `AVAudioEngine` 输入节点，因此不需要麦克风权限，也不会碰系统默认输入设备。

## 状态机

`RemoteLink.State`：

```
idle → scanning → connecting → initializing → ready
                    │              │
                    └─ failed ◄────┘
ready → (disconnect) → reconnecting → scanning/connecting …
```

约束：

- 只有一个 `reconnectWork`；新连接前先取消旧定时器
- 每个回调都校验 `peripheral === self.peripheral`
- 连接 10 s 超时；初始化 8 s 超时
- 断开后失败计数 +1，重连间隔 2/4/8/15 s；ready 后清零

## 安全不变量

1. 没有导入 `Network` / `WebKit`，没有 `URLSession`
2. 没有第三方 SwiftPM 依赖
3. 语音请求强制 on-device；模型缺失即失败
4. 不写音频、不写识别文本、不保存历史
5. 不修改系统 HID 映射（`UserKeyMapping`）、不装驱动、不建事件 tap
6. 权限缺失时功能关闭并提示，不静默降级

`scripts/audit.sh` 对 1、2 做自动检查；`lsof -i -p $(pgrep MiVoice)` 用于运行时确认。
