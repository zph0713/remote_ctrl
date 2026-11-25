import CoreBluetooth
import Foundation
import MiVoiceCore

protocol RemoteLinkDelegate: AnyObject {
    func remoteLink(_ link: RemoteLink, didChange state: RemoteLink.State)
    func remoteLinkDidStartAudio(_ link: RemoteLink)
    func remoteLink(_ link: RemoteLink, didDecode samples: [Int16])
    func remoteLinkDidStopAudio(_ link: RemoteLink)
    func remoteLink(_ link: RemoteLink, didFail message: String)
}

/// Minimal ATVV client for the Xiaomi RC003.
///
/// Everything runs on the main queue. Only one connection attempt and one
/// reconnect timer can exist at a time, which keeps the state machine small.
final class RemoteLink: NSObject {
    enum State: Equatable {
        case idle
        case bluetoothOff
        case unauthorized
        case scanning
        case connecting
        case initializing
        case ready(String)
        case reconnecting
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "未启动"
            case .bluetoothOff: return "蓝牙已关闭"
            case .unauthorized: return "蓝牙权限被拒绝"
            case .scanning: return "正在查找遥控器…"
            case .connecting: return "正在连接…"
            case .initializing: return "正在初始化语音通道…"
            case .ready(let name): return "已连接 \(name)"
            case .reconnecting: return "连接断开，正在重连…"
            case .failed(let message): return message
            }
        }
    }

    weak var delegate: RemoteLinkDelegate?

    private(set) var state: State = .idle {
        didSet {
            if oldValue != state {
                delegate?.remoteLink(self, didChange: state)
            }
        }
    }

    private let serviceUUID = CBUUID(string: ATVVProtocol.serviceUUID)
    private let transmitUUID = CBUUID(string: ATVVProtocol.transmitUUID)
    private let audioUUID = CBUUID(string: ATVVProtocol.audioUUID)
    private let controlUUID = CBUUID(string: ATVVProtocol.controlUUID)
    private let savedUUIDKey = "remote.peripheralUUID"

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var transmit: CBCharacteristic?
    private var audioCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var notifying: Set<CBUUID> = []

    private var capabilities = ATVVCapabilities(
        version: 0x0100,
        codecs: 0x02,
        interaction: 0x03,
        frameSize: 120,
        selectedCodec: 0x02,
        sampleRate: 16_000
    )
    private var capabilitiesConfirmed = false
    private var capabilitiesRequested = false
    private var accumulator = FrameAccumulator()
    private var decoder = IMAADPCMDecoder()
    private var pendingSync: (predictor: Int, stepIndex: Int)?
    private var streaming = false
    private var audioStartedAt: Date?
    private var micOpened = false
    private var sessionID: UInt8 = 0

    private var shouldRun = false
    private var failureCount = 0
    private var scanWork: DispatchWorkItem?
    private var connectWork: DispatchWorkItem?
    private var initWork: DispatchWorkItem?
    private var reconnectWork: DispatchWorkItem?

    func start() {
        guard !shouldRun else { return }
        shouldRun = true
        failureCount = 0
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    func stop() {
        shouldRun = false
        cancelTimers()
        tearDownConnection()
        central?.stopScan()
        central?.delegate = nil
        central = nil
        state = .idle
    }

    func reconnectNow() {
        guard shouldRun else { return }
        cancelTimers()
        if let peripheral, peripheral.state == .connected {
            return
        }
        tearDownConnection()
        failureCount = 0
        guard let central, central.state == .poweredOn else {
            state = .bluetoothOff
            return
        }
        connectSavedOrScan()
    }

    /// Best-effort host request; the remote may also start streaming by itself.
    @discardableResult
    func sendMicrophoneOpen() -> Bool {
        guard case .ready = state, capabilitiesConfirmed, !streaming, !micOpened else { return false }
        let data = ATVVProtocol.microphoneOpen(
            version: capabilities.version,
            codec: capabilities.selectedCodec
        )
        guard write(data) else { return false }
        micOpened = true
        Log.debug("ATVV mic open requested")
        return true
    }

    func sendMicrophoneClose() {
        guard micOpened || streaming else { return }
        _ = write(ATVVProtocol.microphoneClose(
            version: capabilities.version,
            sessionID: sessionID
        ))
        micOpened = false
    }

    // MARK: - Connection

    private func connectSavedOrScan() {
        guard let central, central.state == .poweredOn else { return }
        if let saved = savedPeripheralIdentifier,
           let savedPeripheral = central.retrievePeripherals(withIdentifiers: [saved]).first {
            connect(savedPeripheral)
            return
        }
        // The remote is usually already connected to macOS as a Bluetooth
        // keyboard, so it may not advertise. Ask the system for connected
        // peripherals that expose the ATVV service before scanning.
        let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
        if let target = connected.first(where: {
            matches(name: $0.name ?? "", advertisement: [:])
        }) ?? connected.first {
            connect(target)
            return
        }
        beginScan()
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn, shouldRun else { return }
        cancelScan()
        state = .scanning
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .scanning else { return }
            self.central?.stopScan()
            self.state = .failed("未找到遥控器：请确认已配对并开机")
        }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func connect(_ peripheral: CBPeripheral) {
        guard let central else { return }
        cancelScan()
        reconnectWork?.cancel()
        reconnectWork = nil
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        central.connect(peripheral, options: nil)

        let work = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral, peripheral === self.peripheral,
                  self.state == .connecting else { return }
            self.central?.cancelPeripheralConnection(peripheral)
            self.handleFailure("连接超时")
        }
        connectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func startInitializationTimeout() {
        initWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.capabilitiesConfirmed else { return }
            self.handleFailure("语音通道初始化超时")
        }
        initWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func handleFailure(_ message: String) {
        guard shouldRun else { return }
        Log.error("link failure: \(message)")
        state = .failed(message)
        delegate?.remoteLink(self, didFail: message)
        tearDownConnection()
        failureCount += 1
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldRun else { return }
        reconnectWork?.cancel()
        let delay = min(15.0, pow(2.0, Double(max(1, failureCount))))
        state = .reconnecting
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldRun else { return }
            guard let central = self.central, central.state == .poweredOn else {
                self.state = .bluetoothOff
                return
            }
            if self.failureCount >= 3 {
                self.beginScan()
            } else {
                self.connectSavedOrScan()
            }
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelScan() {
        scanWork?.cancel()
        scanWork = nil
        central?.stopScan()
    }

    private func cancelTimers() {
        scanWork?.cancel(); scanWork = nil
        connectWork?.cancel(); connectWork = nil
        initWork?.cancel(); initWork = nil
        reconnectWork?.cancel(); reconnectWork = nil
    }

    private func tearDownConnection() {
        connectWork?.cancel()
        connectWork = nil
        initWork?.cancel()
        initWork = nil
        if streaming {
            streaming = false
            audioStartedAt = nil
            delegate?.remoteLinkDidStopAudio(self)
        }
        capabilitiesConfirmed = false
        capabilitiesRequested = false
        micOpened = false
        notifying.removeAll()
        accumulator.reset()
        pendingSync = nil
        decoder.reset()
        transmit = nil
        audioCharacteristic = nil
        controlCharacteristic = nil
        if let peripheral {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
    }

    private var savedPeripheralIdentifier: UUID? {
        guard let string = UserDefaults.standard.string(forKey: savedUUIDKey) else { return nil }
        return UUID(uuidString: string)
    }

    private func savePeripheralIdentifier(_ peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: savedUUIDKey)
    }

    // MARK: - ATVV

    private func write(_ data: Data) -> Bool {
        guard let peripheral, peripheral.state == .connected, let transmit else { return false }
        let type: CBCharacteristicWriteType = transmit.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        peripheral.writeValue(data, for: transmit, type: type)
        return true
    }

    private func requestCapabilitiesIfReady() {
        guard !capabilitiesRequested,
              capabilitiesConfirmed == false,
              transmit != nil,
              let audioCharacteristic,
              let controlCharacteristic,
              notifying.contains(audioCharacteristic.uuid),
              notifying.contains(controlCharacteristic.uuid) else { return }
        capabilitiesRequested = true
        _ = write(ATVVProtocol.getCapabilitiesV10)
        state = .initializing
        Log.debug("ATVV capabilities requested")
    }

    private func handleControl(_ data: Data) {
        let bytes = Array(data)
        guard let opcode = bytes.first else { return }

        switch opcode {
        case 0x0B:
            guard let parsed = ATVVCapabilities.parse(data) else {
                handleFailure("遥控器返回了无效的语音能力")
                return
            }
            guard ATVVProtocol.supportsAudio(sampleRate: parsed.sampleRate) else {
                handleFailure("遥控器未使用 16 kHz 语音编码")
                return
            }
            capabilities = parsed
            capabilitiesConfirmed = true
            initWork?.cancel()
            initWork = nil
            failureCount = 0
            if let peripheral {
                savePeripheralIdentifier(peripheral)
                state = .ready(peripheral.name ?? "MI RC")
            } else {
                state = .ready("MI RC")
            }
            Log.info("ATVV ready frame=\(parsed.frameSize)")

        case 0x08:
            _ = sendMicrophoneOpen()

        case 0x04:
            guard capabilitiesConfirmed else { return }
            if bytes.count >= 3, bytes[2] != 0x02 {
                handleFailure("遥控器切换到了不支持的语音编码")
                return
            }
            sessionID = bytes.count >= 4 ? bytes[3] : 0
            startAudio()

        case 0x00:
            stopAudio()

        case 0x0A:
            guard bytes.count >= 7 else { return }
            let predictorBits = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
            pendingSync = (Int(Int16(bitPattern: predictorBits)), Int(bytes[6]))
            accumulator.reset()

        default:
            break
        }
    }

    private func startAudio() {
        guard capabilitiesConfirmed, !streaming else { return }
        accumulator.reset()
        pendingSync = nil
        decoder.reset()
        streaming = true
        audioStartedAt = Date()
        Log.info("ATVV audio start")
        delegate?.remoteLinkDidStartAudio(self)
    }

    private func stopAudio() {
        guard streaming else { return }
        streaming = false
        audioStartedAt = nil
        micOpened = false
        accumulator.reset()
        pendingSync = nil
        Log.info("ATVV audio stop")
        delegate?.remoteLinkDidStopAudio(self)
    }

    private func handleAudio(_ data: Data) {
        guard capabilitiesConfirmed, let peripheral, peripheral.state == .connected else { return }
        if !streaming {
            startAudio()
        }
        guard streaming else { return }
        if let started = audioStartedAt, Date().timeIntervalSince(started) > 60 {
            sendMicrophoneClose()
            stopAudio()
            return
        }

        let frames = accumulator.append(data, frameSize: capabilities.frameSize)
        guard !frames.isEmpty else { return }
        for frame in frames {
            if let sync = pendingSync {
                decoder.reset(predictor: sync.predictor, stepIndex: sync.stepIndex)
                pendingSync = nil
            }
            let decoded = decoder.decode(frame)
            let samples = PCMPostprocessor.process(decoded)
            delegate?.remoteLink(self, didDecode: samples)
        }
    }

    private func matches(name: String, advertisement: [String: Any]) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "mi rc" { return true }
        if normalized.contains("xiaomi bluetooth remote 2") { return true }
        if normalized.contains("remote 2 pro") { return true }
        if normalized.contains("小米蓝牙") { return true }
        if let services = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           services.contains(serviceUUID) {
            return true
        }
        return false
    }
}

extension RemoteLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard shouldRun else { return }
        switch central.state {
        case .poweredOn:
            Log.info("bluetooth powered on")
            if let peripheral, peripheral.state == .connected { return }
            if state == .scanning || state == .connecting || state == .initializing { return }
            connectSavedOrScan()
        case .poweredOff:
            cancelTimers()
            tearDownConnection()
            state = .bluetoothOff
        case .unauthorized:
            cancelTimers()
            tearDownConnection()
            state = .unauthorized
        case .unsupported:
            state = .failed("此 Mac 不支持蓝牙低功耗")
        case .resetting, .unknown:
            state = .idle
        @unknown default:
            state = .idle
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard shouldRun, state == .scanning else { return }
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""
        guard matches(name: name, advertisement: advertisementData) else { return }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        connectWork?.cancel()
        connectWork = nil
        state = .initializing
        peripheral.discoverServices([serviceUUID])
        startInitializationTimeout()
        Log.info("bluetooth connected")
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        handleFailure("连接失败：\(error?.localizedDescription ?? "未知错误")")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        connectWork?.cancel()
        connectWork = nil
        initWork?.cancel()
        initWork = nil
        if streaming {
            streaming = false
            audioStartedAt = nil
            micOpened = false
            delegate?.remoteLinkDidStopAudio(self)
        }
        self.peripheral = nil
        transmit = nil
        audioCharacteristic = nil
        controlCharacteristic = nil
        capabilitiesConfirmed = false
        capabilitiesRequested = false
        micOpened = false
        notifying.removeAll()
        Log.info("bluetooth disconnected")
        guard shouldRun else { return }
        failureCount += 1
        scheduleReconnect()
    }
}

extension RemoteLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        if let error {
            handleFailure("发现服务失败：\(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            handleFailure("遥控器没有提供语音服务")
            return
        }
        peripheral.discoverCharacteristics(
            [transmitUUID, audioUUID, controlUUID],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        if let error {
            handleFailure("发现语音通道失败：\(error.localizedDescription)")
            return
        }
        guard service.uuid == serviceUUID else { return }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case transmitUUID: transmit = characteristic
            case audioUUID: audioCharacteristic = characteristic
            case controlUUID: controlCharacteristic = characteristic
            default: break
            }
        }
        guard transmit != nil,
              let audioCharacteristic,
              let controlCharacteristic else {
            handleFailure("遥控器语音通道不完整")
            return
        }
        peripheral.setNotifyValue(true, for: audioCharacteristic)
        peripheral.setNotifyValue(true, for: controlCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        if let error {
            handleFailure("订阅语音通道失败：\(error.localizedDescription)")
            return
        }
        if characteristic.isNotifying {
            notifying.insert(characteristic.uuid)
        } else {
            notifying.remove(characteristic.uuid)
        }
        requestCapabilitiesIfReady()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === self.peripheral, error == nil, let data = characteristic.value else { return }
        if characteristic.uuid == controlUUID {
            handleControl(data)
        } else if characteristic.uuid == audioUUID {
            handleAudio(data)
        }
    }
}
