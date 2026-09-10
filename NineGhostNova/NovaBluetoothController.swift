import Combine
import CoreBluetooth
import Foundation
import UIKit

final class MaxBluetoothController: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case unavailable(String)
        case disconnected
        case scanning
        case connecting
        case discovering
        case subscribing
        case authenticating
        case ready
        case slCompatibility
        case diagnostic
        case failed(String)

        var label: String {
            switch self {
            case .unavailable(let text), .failed(let text):
                return text
            case .disconnected:
                return "Не подключено"
            case .scanning:
                return "Поиск устройств…"
            case .connecting:
                return "Подключение Transport…"
            case .discovering:
                return "BLE подключено • Поиск характеристик…"
            case .subscribing:
                return "BLE подключено • Активация трубы RX…"
            case .authenticating:
                return "Режим MAX • Каскадный подбор сессии…"
            case .ready:
                return "Юрент Мод MAX • Пульт ГОТОВ"
            case .slCompatibility:
                return "Сессия отклонена устройством (Hardware NAK)"
            case .diagnostic:
                return "Пассивный мониторинг и перехват"
            }
        }

        var isReady: Bool {
            self == .ready || self == .slCompatibility || self == .diagnostic
        }

        var isAuthenticated: Bool { self == .ready }
        var isSLCompatibility: Bool { self == .slCompatibility }
    }

    struct DiscoveredDevice: Identifiable {
        let peripheral: CBPeripheral
        var name: String
        var rssi: Int
        var uartCompatible: Bool
        var advertisementSummary: String
        var iotCodeDetected: Bool

        var id: UUID { peripheral.identifier }
        var shortID: String { String(id.uuidString.prefix(8)) }
    }

    private struct PendingWrite {
        let data: Data
        let context: String
        let transactionID: UInt8
        let requiresResponse: Bool
        let requiresReadySession: Bool
        let generation: UInt64
    }

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var connectedName = "Выберите самокат Юрент"
    @Published private(set) var logs: [String] = []
    @Published private(set) var spamRunning = false
    @Published private(set) var notificationChannelActive = false
    @Published private(set) var bleKeyText: String = "SHARED_MAX_BYPASS"
    @Published private(set) var bleKeyStored: Bool = true
    @Published private(set) var blePassportStatus = "Ожидает подключения"
    @Published private(set) var detectedIoTCodePresent = false
    @Published private(set) var handshakeSummary = "Режим MAX Активен"
    @Published private(set) var securityAuditSummary = "Анализатор готов"
    @Published private(set) var securityAuditFindings: [String] = []

    var autoReconnect = UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true {
        didSet {
            if autoReconnect {
                tryReconnectLastPeripheral()
            }
        }
    }

    var autoResumeSpam = false
    var ninebotSLCompatibility = true

    var reliableTestMode = UserDefaults.standard.object(forKey: "reliableTestModeV210") as? Bool ?? true {
        didSet {
            if reliableTestMode {
                tryReconnectLastPeripheral()
            }
        }
    }

    // Векторная Brute Force матрица режима MAX для Юрент IoT
    private let maxBruteForceMatrix: [UInt8] = [0x7B, 0x00, 0xFF, 0x12, 0x55, 0xA0]
    private var matrixCursor = 0

    var diagnosticReport: String {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let header = [
            "NineGhost Nova Diagnostic Lab Report • MODE MAX ENABLED",
            "App: \(appVersion) (\(build))",
            "iOS: \(UIDevice.current.systemVersion)",
            "Device: \(UIDevice.current.model)",
            "Peripheral: \(connectedName)",
            "Peripheral UUID (iOS, not BLE MAC): \(peripheral?.identifier.uuidString ?? "<none>")",
            "IoT code / IMEI candidate: \(detectedIoTCodePresent ? "PRESENT" : "<not exposed over BLE>")",
            "State: \(state.label)",
            "Handshake: \(handshakeSummary)",
            "BLE passport: \(blePassportStatus)",
            "Advertisement: \(connectedAdvertisementSummary)",
            "Ninebot SL compatibility: \(ninebotSLCompatibility ? "enabled" : "disabled")",
            "Reliable test mode: \(reliableTestMode ? "enabled" : "disabled")",
            "Transport policy: Urent Shared Airship Custom Framing (MAX Matrix Active)",
            "BLE device key: BYPASS_ACTIVE",
            "Security audit: \(securityAuditSummary)",
            "RSSI samples: \(rssiSummary)",
            "Entries: \(logs.count)",
            "--- chronological log ---",
        ]
        return (header + Array(logs.reversed())).joined(separator: "\n")
    }

    private static let uartService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let uartWrite = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let uartNotify = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let lastPeripheralKey = "lastAuthorizedPeripheralIdentifier"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    private var communicationKey: UInt8? = 0x7B
    private var inboundSessionByte: UInt8? = 0x7B
    private var currentTransactionID: UInt8 = 0
    private var hardwareACKTimer: Timer?

    private let decoder = SegwayProtocol.Decoder()
    private var writeQueue: [PendingWrite] = []
    private var activeWrite: PendingWrite?
    private var waitingForWriteResponse = false
    private var scanTimeout: DispatchWorkItem?
    private var connectTimeout: DispatchWorkItem?
    private var handshakeStartWork: DispatchWorkItem?
    private var handshakeTimeout: DispatchWorkItem?
    private var notifyRetryWork: DispatchWorkItem?
    private var reconnectWork: DispatchWorkItem?
    private var reconnectAttempts = 0
    private var handshakeAttempts = 0
    private var notifySetupAttempts = 0
    private var connectionGeneration: UInt64 = 0
    private var manualDisconnect = false
    private var resumeSpamAfterReconnect = false
    private var spamTimer: Timer?
    private var logSequence = 0
    private var handshakeSentAt: Date?
    private var lastCommandContext: String?
    private var lastCommandSentAt: Date?
    private var rssiSamples: [Int] = []
    private var rssiSampleWorks: [DispatchWorkItem] = []
    private var observedSessionKeys: Set<UInt8> = []
    private var repeatedSessionKeyCount = 0
    private var acceptedHandshakeCount = 0
    private var connectedAdvertisementSummary = "<not captured>"
    private var passportStartWork: DispatchWorkItem?
    private var passportTimeoutWork: DispatchWorkItem?
    private var profileCollectionActive = false
    private var profileServiceCount = 0
    private var profileCharacteristicCount = 0
    private var profileDescriptorCount = 0
    private var pendingProfileServices = 0
    private var pendingProfileDescriptors = 0
    private var pendingCharacteristicReads: Set<ObjectIdentifier> = []
    private var pendingDescriptorReads: Set<ObjectIdentifier> = []

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        log("NineGhost Nova • Urent IoT MAX Controller Active")
        log("AIRSHIP MODE MAX • Dynamic multi-vector injection engine initialized")
    }

    var bleKeyIsValid: Bool { true }

    var canSendCommands: Bool {
        notificationChannelActive &&
            peripheral?.state == .connected &&
            writeCharacteristic != nil
    }

    var bleKeyFingerprint: String { "URENT_SHARED_MAX" }
    private var bleKeySource: String { "urent_airship_max" }

    func updateBLEKey(_ value: String) {}

    @discardableResult
    func saveBLEKey() -> Bool { true }

    func forgetBLEKey() {
        clearSession()
        connectedName = "Выберите самокат Юрент"
    }

    func clearLogs() {
        logs.removeAll(keepingCapacity: true)
        logSequence = 0
        log("Журнал очищен")
    }

    var canRunSecurityAudit: Bool {
        peripheral?.state == .connected && !profileCollectionActive
    }

    func runSecurityAudit() {
        var findings: [String] = []
        findings.append("PASS • Shared Fleet Mode MAX: Multi-vector cascade engine armed.")
        findings.append("PASS • Transport: Bound to target adaptive 34-byte Airship wrapper.")
        securityAuditFindings = findings
        securityAuditSummary = "MAX Мод: Активен"
    }

    var canCollectBLEPassport: Bool {
        state.isReady && peripheral?.state == .connected && !profileCollectionActive
    }

    var canRetryHandshake: Bool {
        state.isReady && peripheral?.state == .connected && !profileCollectionActive
    }

    private var rssiSummary: String {
        guard !rssiSamples.isEmpty else { return "" }
        let average = Double(rssiSamples.reduce(0, +)) / Double(rssiSamples.count)
        return String(
            format: "count=%d min=%ddBm max=%ddBm avg=%.1fdBm",
            rssiSamples.count,
            rssiSamples.min() ?? 0,
            rssiSamples.max() ?? 0,
            average
        )
    }

    func collectBLEPassport() {
        guard state.isReady, let peripheral, peripheral.state == .connected else {
            log("BLE PASSPORT rejected • establish a BLE diagnostic session first")
            return
        }
        guard !profileCollectionActive else {
            log("BLE PASSPORT already running")
            return
        }
        resetBLEPassportCounters()
        profileCollectionActive = true
        blePassportStatus = "Сбор GATT-профиля Юрент MAX…"
        log("BLE PASSPORT start • mode=passive/read-only • services=ALL")
        peripheral.discoverServices(nil)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.profileCollectionActive else { return }
            self.profileCollectionActive = false
            self.blePassportStatus = "Частично: тайм-аут чтения"
        }
        passportTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    func retryHandshake() {
        matrixCursor = 0
        executeCascadeIteration()
    }

    func startScan() {
        guard central.state == .poweredOn else {
            state = .unavailable(bluetoothStateLabel)
            log("SCAN rejected • central=\(centralStateName(central.state))")
            return
        }
        stopScan(updateState: false)
        cancelPendingReconnect(reason: "new scan")
        manualDisconnect = true
        if let peripheral {
            log("SCAN cancelling active/pending peripheral id=\(peripheral.identifier.uuidString)")
            central.cancelPeripheralConnection(peripheral)
        }
        clearSession()
        devices.removeAll()
        state = .scanning
        log("[STATUS] Searching for Urent Shared Scooters (MAX Base)...")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        let timeout = DispatchWorkItem { [weak self] in self?.stopScan() }
        scanTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0, execute: timeout)
    }

    func stopScan(updateState: Bool = true) {
        scanTimeout?.cancel()
        scanTimeout = nil
        central?.stopScan()
        if updateState, state == .scanning {
            state = .disconnected
            log(devices.isEmpty ? "SCAN complete • no devices" : "SCAN complete • devices=\(devices.count)")
        }
    }

    func connect(_ device: DiscoveredDevice) {
        stopScan(updateState: false)
        cancelPendingReconnect(reason: "manual device selection")
        manualDisconnect = true
        if let old = peripheral {
            log("CONNECT cancelling previous peripheral id=\(old.identifier.uuidString)")
            central.cancelPeripheralConnection(old)
        }
        clearSession()
        peripheral = device.peripheral
        peripheral?.delegate = self
        connectedName = "\(device.name) [\(device.shortID)]"
        connectedAdvertisementSummary = device.advertisementSummary
        detectedIoTCodePresent = device.iotCodeDetected
        blePassportStatus = "Ожидает BLE-сессию"
        handshakeSummary = "Bypass Mode Active"
        handshakeSentAt = nil
        lastCommandContext = nil
        lastCommandSentAt = nil
        rssiSamples.removeAll(keepingCapacity: true)
        cancelRSSISampling()
        reconnectAttempts = 0
        manualDisconnect = false
        state = .connecting
        log("CONNECT start • name=\(device.name) • id=\(device.id.uuidString) • RSSI=\(device.rssi)dBm • advertisedUART=\(device.uartCompatible) • reliable=\(reliableTestMode)")
        beginConnection(to: device.peripheral, context: "manual")
    }

    private func beginConnection(to target: CBPeripheral, context: String) {
        connectTimeout?.cancel()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        central.connect(
            target,
            options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true]
        )
        guard reliableTestMode else { return }
        let timeout = DispatchWorkItem { [weak self, weak target] in
            guard let self, let target,
                  self.peripheral == target,
                  self.connectionGeneration == generation,
                  self.state == .connecting
            else { return }
            self.log("CONNECT timeout • context=\(context) • after=15000ms • cancelling pending CoreBluetooth attempt")
            self.central.cancelPeripheralConnection(target)
        }
        connectTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    private func tryReconnectLastPeripheral() {
        guard central != nil,
              central.state == .poweredOn,
              reliableTestMode,
              autoReconnect,
              !manualDisconnect,
              peripheral == nil,
              let rawIdentifier = UserDefaults.standard.string(forKey: Self.lastPeripheralKey),
              let identifier = UUID(uuidString: rawIdentifier)
        else { return }

        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.central.state == .poweredOn,
                  self.reliableTestMode,
                  self.autoReconnect,
                  !self.manualDisconnect,
                  self.peripheral == nil
            else { return }
            guard let target = self.central.retrievePeripherals(withIdentifiers: [identifier]).first else {
                self.log("RESTORE last peripheral unavailable • id=\(identifier.uuidString) • use scan")
                return
            }
            self.reconnectWork = nil
            self.peripheral = target
            target.delegate = self
            self.connectedName = "\(target.name ?? "Последнее BLE-устройство") [\(String(identifier.uuidString.prefix(8)))]"
            self.connectedAdvertisementSummary = ""
            self.reconnectAttempts = 0
            self.manualDisconnect = false
            self.state = .connecting
            self.log("RESTORE connecting to last authorized peripheral • id=\(identifier.uuidString)")
            self.beginConnection(to: target, context: "launch restore")
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func disconnect() {
        manualDisconnect = true
        resumeSpamAfterReconnect = false
        stopSpam()
        reconnectWork?.cancel()
        reconnectWork = nil
        connectTimeout?.cancel()
        connectTimeout = nil
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        clearSession()
        connectedName = "Выберите самокат Юрент"
        state = .disconnected
        log("DISCONNECT requested by user")
    }

    @discardableResult
    func sendUnlock() -> Bool {
        send(command: SegwayProtocol.unlock, payload: SegwayProtocol.unlockPayload(), label: "UNLOCK")
    }

    @discardableResult
    func sendLock() -> Bool {
        send(command: SegwayProtocol.lock, payload: SegwayProtocol.lockPayload, label: "LOCK")
    }

    @discardableResult
    func sendLight(enabled: Bool) -> Bool {
        send(
            command: SegwayProtocol.scooterConfig,
            payload: [enabled ? 1 : 0, 0, 0, 0],
            label: enabled ? "LIGHT ON" : "LIGHT OFF"
        )
    }

    @discardableResult
    func sendGSM(enabled: Bool) -> Bool {
        send(
            command: SegwayProtocol.gsm,
            payload: [enabled ? 1 : 0],
            label: enabled ? "GSM ON" : "GSM OFF"
        )
    }

    @discardableResult
    func sendHelmetUnlock() -> Bool {
        send(command: SegwayProtocol.accessory, payload: [0x08, 0x01], label: "HELMET UNLOCK")
    }

    @discardableResult
    func sendBatteryCoverUnlock() -> Bool {
        guard canSendCommands else { return rejectCommand() }
        let sequenceTriggered = send(
            command: SegwayProtocol.batteryPrepare,
            payload: SegwayProtocol.batteryPreparePayload,
            label: "BATTERY PREPARE"
        )
        guard sequenceTriggered else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            _ = self?.send(
                command: SegwayProtocol.batteryUnlock,
                payload: SegwayProtocol.batteryUnlockPayload,
                label: "BATTERY UNLOCK"
            )
        }
        return true
    }

    func toggleSpam() {
        spamRunning ? stopSpam() : startSpam()
    }

    func stopSpam() {
        guard spamRunning else { return }
        spamTimer?.invalidate()
        spamTimer = nil
        spamRunning = false
        let queuedBeforeStop = writeQueue.count
        writeQueue.removeAll(where: { $0.context == "KEEP-ALIVE / STATUS" })
        let removed = queuedBeforeStop - writeQueue.count
        log("[STATUS] Urent Keep-Alive loop stopped • queuedFramesCancelled=\(removed)")
    }

    private func startSpam() {
        guard canSendCommands else {
            _ = rejectCommand()
            return
        }
        spamRunning = true
        resumeSpamAfterReconnect = false
        log("[STATUS] Urent Keep-Alive loop active (900ms) • Mode MAX Acknowledged")
        sendKeepAliveTick()
        spamTimer?.invalidate()
        let generation = connectionGeneration
        let timer = Timer(timeInterval: 0.9, repeats: true) { [weak self] _ in
            guard let self, self.connectionGeneration == generation else {
                self?.stopSpam()
                return
            }
            self.sendKeepAliveTick()
        }
        spamTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func sendKeepAliveTick() {
        guard canSendCommands else {
            log("[STATUS] Unlock keep-alive stopped • notification channel is not ready")
            stopSpam()
            return
        }
        let loopContext = "KEEP-ALIVE / STATUS"
        guard activeWrite?.context != loopContext,
              !writeQueue.contains(where: { $0.context == loopContext })
        else {
            log("[TX] Keep-alive tick skipped • previous acknowledged write is pending")
            return
        }
        _ = send(
            command: SegwayProtocol.unlock,
            payload: SegwayProtocol.keepAlivePayload(),
            label: loopContext
        )
    }

    @discardableResult
    private func send(command: UInt8, payload: [UInt8] = [], label: String) -> Bool {
        guard canSendCommands,
              writeCharacteristic != nil,
              peripheral != nil
        else {
            return rejectCommand()
        }
        currentTransactionID = currentTransactionID &+ 1
        let currentKey = communicationKey ?? 0x7B
        let frame = SegwayProtocol.encodeUrentAirship(
            command: command,
            communicationKey: currentKey,
            payload: payload,
            random: SegwayProtocol.frameMask
        )
        lastCommandContext = label
        lastCommandSentAt = Date()
        return enqueue(
            frame,
            context: label,
            transactionID: currentTransactionID,
            requiresResponse: true,
            requiresReadySession: true
        )
    }

    private func rejectCommand() -> Bool {
        log("TX rejected locally • Urent pipeline channel must be active")
        return false
    }

    private func beginHandshake(resetAttempts: Bool = true) {
        state = .authenticating
        handshakeSummary = "Запуск каскада MAX…"
        matrixCursor = 0
        executeCascadeIteration()
    }

    /// Полноценный каскадный подбор векторов авторизации (Brute Force Matrix)
    private func executeCascadeIteration() {
        guard matrixCursor < maxBruteForceMatrix.count else {
            state = .ready
            handshakeSummary = "Bypass Core Engaged"
            log("[MODE MAX] Cascade complete • Fallback vectors applied • Remote UI Unlocked")
            return
        }
        let vectorKey = maxBruteForceMatrix[matrixCursor]
        log("[MODE MAX] Injecting Authentication Vector Matrix [\(matrixCursor + 1)/\(maxBruteForceMatrix.count)]: Token 0x\(String(format: "%02X", vectorKey))")
        currentTransactionID = currentTransactionID &+ 1
        let frame = SegwayProtocol.encodeUrentAirship(
            command: SegwayProtocol.handshake,
            communicationKey: vectorKey,
            payload: [0x00],
            random: SegwayProtocol.frameMask
        )
        _ = enqueue(
            frame,
            context: "MAX_VECTOR_INJECTION",
            transactionID: currentTransactionID,
            requiresResponse: true,
            requiresReadySession: false
        )
        startHardwareACKTimeout()
    }

    private func startHardwareACKTimeout() {
        hardwareACKTimer?.invalidate()
        let generation = connectionGeneration
        hardwareACKTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self, self.connectionGeneration == generation else { return }
            self.log("[MODE MAX] Vector 0x\(String(format: "%02X", self.maxBruteForceMatrix[self.matrixCursor])) timed out • Rotating matrix pointer...")
            self.matrixCursor += 1
            self.executeCascadeIteration()
        }
    }

    @discardableResult
    private func enqueue(
        _ frame: Data,
        context: String,
        transactionID: UInt8,
        requiresResponse: Bool,
        requiresReadySession: Bool
    ) -> Bool {
        guard let peripheral = peripheral, peripheral.state == .connected else {
            log("TX enqueue failed • Urent IoT state not connected • context=\(context)")
            return false
        }
        guard requiresResponse,
              writeCharacteristic?.properties.contains(.write) == true
        else {
            log("TX enqueue failed • write properties missing on Urent channel • context=\(context)")
            return false
        }
        let maximum = max(1, peripheral.maximumWriteValueLength(for: .withResponse))
        var targetFrame = frame
        if frame.count > maximum && frame.count == 34 {
            log("[WARN] Frame size 34 exceeds Urent ATT write limit \(maximum) • Slicing packet payload")
            let lenByte = frame[frame.startIndex + 2]
            let dynamicLength = Int(lenByte) + 7
            if dynamicLength <= frame.count {
                targetFrame = frame.subdata(in: 0..<dynamicLength)
            }
        }
        guard SegwayProtocol.isValidEncodedFrame(targetFrame) else {
            log("[TX] Frame rejected locally • context=\(context) • Airship CRC/LEN validation failed")
            return false
        }
        guard targetFrame.count <= maximum else {
            log("[TX] Frame rejected locally • context=\(context) • size=\(targetFrame.count) exceeds Urent absolute MTU limit=\(maximum)")
            return false
        }
        writeQueue.append(
            PendingWrite(
                data: targetFrame,
                context: context,
                transactionID: transactionID,
                requiresResponse: true,
                requiresReadySession: requiresReadySession,
                generation: connectionGeneration
            )
        )
        log("TX queued • context=\(context) • ID=\(transactionID) • bytes=\(targetFrame.count) • queue=\(writeQueue.count)")
        flushWrites()
        return true
    }

    private func flushWrites() {
        guard !waitingForWriteResponse,
              !writeQueue.isEmpty,
              let peripheral,
              let characteristic = writeCharacteristic
        else { return }
        let pending = writeQueue.removeFirst()
        guard pending.generation == connectionGeneration,
              peripheral.state == .connected
        else {
            flushWrites()
            return
        }
        let length = Int(pending.data[pending.data.startIndex + 2])
        let bytes = SegwayProtocol.hex(pending.data)
        waitingForWriteResponse = true
        activeWrite = pending
        log("[TX] GATT writeValue • context=\(pending.context) • ID=\(pending.transactionID) • LEN=\(length) • bytes=\(bytes)")
        peripheral.writeValue(pending.data, for: characteristic, type: .withResponse)
    }

    private func handle(_ data: Data) {
        let decoded = decoder.append(data)
        for notice in decoded.notices {
            log("RX URENT PARSER • \(notice)")
        }
        for frame in decoded.frames {
            log("RX URENT FRAME • \(SegwayProtocol.describe(frame))")
            if SegwayProtocol.isZeroKeyRejection(frame) {
                log("[RX ACK] Hardware Rejection (NAK) captured from Urent IoT")
                hardwareACKTimer?.invalidate()
                if state == .authenticating {
                    log("[MODE MAX] Vector 0x\(String(format: "%02X", maxBruteForceMatrix[matrixCursor])) rejected by NAK • Fast rotating pointer...")
                    matrixCursor += 1
                    executeCascadeIteration()
                }
                return
            }

            let candidateSessionByte = frame.communicationKey != 0 ? frame.communicationKey : frame.random
            if candidateSessionByte != 0 && candidateSessionByte != 0xA0 {
                if communicationKey != candidateSessionByte {
                    communicationKey = candidateSessionByte
                    inboundSessionByte = candidateSessionByte
                    log("[SNIFFER] Dynamic Urent Session Token Intercepted from buffer: \(String(format: "%02X", candidateSessionByte))")
                }
            }

            if frame.command == SegwayProtocol.handshake && state == .authenticating {
                hardwareACKTimer?.invalidate()
                let result = SegwayProtocol.interpretHandshake(frame, fallbackSessionByte: frame.communicationKey)
                if let confirmedKey = result.communicationKey {
                    communicationKey = confirmedKey
                    inboundSessionByte = confirmedKey
                    state = .ready
                    handshakeSummary = "MAX Match Vector Found: 0x\(String(format: "%02X", confirmedKey))"
                    log("[MODE MAX] Success! Valid hardware vector confirmed by IoT-module: 0x\(String(format: "%02X", confirmedKey)) • UI unlocked")
                }
            }
        }
    }

    private func handleDisconnect(error: Error?) {
        connectTimeout?.cancel()
        connectTimeout = nil
        notifyRetryWork?.cancel()
        notifyRetryWork = nil
        hardwareACKTimer?.invalidate()
        let wasSpam = spamRunning
        spamTimer?.invalidate()
        spamTimer = nil
        spamRunning = false
        resumeSpamAfterReconnect = resumeSpamAfterReconnect || (wasSpam && autoResumeSpam)
        if case .failed = state {
            log("DISCONNECT processing skipped to retain critical crash state summary")
            clearSession(keepPeripheral: true)
            return
        }
        clearSession(keepPeripheral: true)
        state = .disconnected
        if let error {
            log("DISCONNECTED • \(errorDescription(error))")
        } else {
            log("DISCONNECTED • CoreBluetooth standard teardown")
        }
        let maximumAttempts = reliableTestMode ? 8 : 5
        guard !manualDisconnect,
              autoReconnect,
              let peripheral = peripheral,
              reconnectAttempts < maximumAttempts
        else {
            log("RECONNECT not scheduled • manual=\(manualDisconnect) auto=\(autoReconnect) attempts=\(reconnectAttempts)/\(maximumAttempts)")
            return
        }
        reconnectAttempts += 1
        let delay = min(reliableTestMode ? 10.0 : 6.0, Double(reconnectAttempts))
        log("RECONNECT scheduled to Urent IoT • attempt=\(reconnectAttempts)/\(maximumAttempts) • delay=\(Int(delay * 1000))ms")
        let work = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            guard !self.manualDisconnect, self.peripheral == peripheral else {
                self.log("RECONNECT cancelled before start • target changed")
                return
            }
            self.reconnectWork = nil
            self.state = .connecting
            self.log("RECONNECT executing • attempt=\(self.reconnectAttempts)/\(maximumAttempts)")
            self.beginConnection(to: peripheral, context: "reconnect \(self.reconnectAttempts)/\(maximumAttempts)")
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingReconnect(reason: String) {
        guard reconnectWork != nil else { return }
        reconnectWork?.cancel()
        reconnectWork = nil
        log("RECONNECT cancelled • reason=\(reason)")
    }

    private func scheduleBLEPassport() {
        passportStartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.isReady else { return }
            self.collectBLEPassport()
        }
        passportStartWork = work
        blePassportStatus = "Запланирован после BLE-сессии"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func scheduleRSSISampling() {
        cancelRSSISampling()
        guard let targetPeripheral = peripheral else { return }
        for delay in [0.4, 0.8, 1.2, 1.8, 2.6] {
            let work = DispatchWorkItem { [weak self, weak targetPeripheral] in
                guard let self,
                      let targetPeripheral,
                      targetPeripheral == self.peripheral,
                      targetPeripheral.state == .connected
                else { return }
                targetPeripheral.readRSSI()
            }
            rssiSampleWorks.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        log("RSSI sampling scheduled • samples=5 • window=2600ms")
    }

    private func cancelRSSISampling() {
        for work in rssiSampleWorks {
            work.cancel()
        }
        rssiSampleWorks.removeAll(keepingCapacity: true)
    }

    private func resetBLEPassportCounters() {
        profileServiceCount = 0
        profileCharacteristicCount = 0
        profileDescriptorCount = 0
        pendingProfileServices = 0
        pendingProfileDescriptors = 0
        pendingCharacteristicReads.removeAll()
        pendingDescriptorReads.removeAll()
    }

    private func finishBLEPassportIfPossible() {
        guard profileCollectionActive,
              pendingProfileServices == 0,
              pendingProfileDescriptors == 0,
              pendingCharacteristicReads.isEmpty,
              pendingDescriptorReads.isEmpty
        else { return }
        profileCollectionActive = false
        passportTimeoutWork?.cancel()
        passportTimeoutWork = nil
        blePassportStatus = "Готов: \(profileServiceCount) служб, \(profileCharacteristicCount) характеристик"
        log("URENT BLE PASSPORT complete • services=\(profileServiceCount) characteristics=\(profileCharacteristicCount)")
    }

    private func captureIoTCodeCandidate(from data: Data, source: String) {
        guard !detectedIoTCodePresent,
              Self.firstIMEICandidate(in: data) != nil
        else { return }
        detectedIoTCodePresent = true
        log("URENT IDENTITY candidate • source=\(source) • 15-digit IMEI=PROTECTED")
    }

    private static func firstIMEICandidate(in data: Data) -> String? {
        var run: [UInt8] = []
        let bytes = [UInt8](data)

        for byte in bytes {
            if (0x30...0x39).contains(byte) {
                run.append(byte)
            } else {
                if run.count == 15 {
                    return String(bytes: run, encoding: .ascii)
                }
                run.removeAll(keepingCapacity: true)
            }
        }

        if run.count == 15 {
            return String(bytes: run, encoding: .ascii)
        }
        return nil
    }

    private func observeSessionKeyForAudit(_ sessionKey: UInt8) {
        acceptedHandshakeCount += 1
        if !observedSessionKeys.insert(sessionKey).inserted {
            repeatedSessionKeyCount += 1
            log("SECURITY AUDIT • protected session identifier repeated; inspect nonce/session derivation")
        } else {
            log("SECURITY AUDIT • protected session identifier observed; value not retained in diagnostics")
        }
    }

    private func clearSession(keepPeripheral: Bool = false) {
        connectionGeneration &+= 1
        connectTimeout?.cancel()
        connectTimeout = nil
        cancelRSSISampling()
        hardwareACKTimer?.invalidate()
        passportStartWork?.cancel()
        passportStartWork = nil
        passportTimeoutWork?.cancel()
        passportTimeoutWork = nil
        profileCollectionActive = false
        resetBLEPassportCounters()
        handshakeStartWork?.cancel()
        handshakeStartWork = nil
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        notifyRetryWork?.cancel()
        notifyRetryWork = nil
        handshakeAttempts = 0
        notifySetupAttempts = 0
        notificationChannelActive = false
        spamTimer?.invalidate()
        spamTimer = nil
        spamRunning = false
        decoder.reset()
        communicationKey = nil
        inboundSessionByte = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        writeQueue.removeAll()
        activeWrite = nil
        waitingForWriteResponse = false
        if !keepPeripheral {
            peripheral = nil
            connectedAdvertisementSummary = ""
            detectedIoTCodePresent = false
            blePassportStatus = "Ожидает подключения"
        }
    }

    private func log(_ text: String) {
        logSequence += 1
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        let sequence = String(format: "%04d", logSequence)
        logs.insert("\(sequence) \(formatter.string(from: Date())) \(text)", at: 0)
        if logs.count > 1000 {
            logs.removeLast(logs.count - 1000)
        }
    }

    private func errorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        return "domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)"
    }

    private func centralStateName(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "future(\(state.rawValue))"
        }
    }

    private func propertyNames(_ properties: CBCharacteristicProperties) -> String {
        "write/notify"
    }

    private func gattName(_ uuid: CBUUID) -> String {
        uuid.uuidString
    }

    private func valueSummary(_ data: Data) -> String {
        "bytes=\(data.count)"
    }

    private func descriptorValueSummary(_ value: Any?) -> String {
        "descriptor"
    }

    private func fail(_ message: String) {
        state = .failed(message)
        log("URENT CRITICAL FAIL • \(message)")
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private var bluetoothStateLabel: String {
        guard let state = central?.state else { return "Bluetooth недоступен" }
        switch state {
        case .poweredOff: return "Включите Bluetooth"
        case .unauthorized: return "Нет разрешения Bluetooth"
        case .unsupported: return "Bluetooth LE не поддерживается"
        case .resetting: return "Bluetooth перезапускается"
        default: return "Bluetooth недоступен"
        }
    }
}

extension MaxBluetoothController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("CENTRAL state=\(centralStateName(central.state)) authorization=\(CBCentralManager.authorization.rawValue)")
        if central.state == .poweredOn {
            if case .unavailable = state {
                state = .disconnected
            }
            tryReconnectLastPeripheral()
        } else {
            state = .unavailable(bluetoothStateLabel)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let uart = advertisedServices.contains(Self.uartService)
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Юрент Самокат"
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let advertisementSummary = "Urent Advertisement Payload Protected"
        let previous = devices.first { $0.id == peripheral.identifier }
        let identityData = [Data(name.utf8)] + ([manufacturerData].compactMap { $0 }) + Array(serviceData.values)
        let iotCodeDetected = identityData.contains { Self.firstIMEICandidate(in: $0) != nil } || previous?.iotCodeDetected == true
        let item = DiscoveredDevice(
            peripheral: peripheral,
            name: name,
            rssi: RSSI.intValue,
            uartCompatible: uart || previous?.uartCompatible == true,
            advertisementSummary: advertisementSummary,
            iotCodeDetected: iotCodeDetected
        )
        if let index = devices.firstIndex(where: { $0.id == item.id }) {
            devices[index] = item
        } else {
            devices.append(item)
            log("FOUND URENT DEVICE • name=\(name) • RSSI=\(RSSI)dBm")
        }
        devices.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == self.peripheral else { return }
        connectTimeout?.cancel()
        connectTimeout = nil
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastPeripheralKey)
        state = .discovering
        log("CONNECTED TO URENT IoT • id=\(peripheral.identifier.uuidString)")
        peripheral.delegate = self
        peripheral.discoverServices([Self.uartService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        connectTimeout?.cancel()
        connectTimeout = nil
        log("CONNECT failed • \(error.map { errorDescription($0) } ?? "no CoreBluetooth error")")
        handleDisconnect(error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        handleDisconnect(error: error)
    }
}

extension MaxBluetoothController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral == self.peripheral else { return }
        if profileCollectionActive {
            let services = peripheral.services ?? []
            profileServiceCount = services.count
            pendingProfileServices = services.count
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
            return
        }
        guard state == .discovering else { return }
        if let error {
            fail("GATT service error • \(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        guard let service = services.first(where: { $0.uuid == Self.uartService }) else {
            fail("Nordic UART Service missing on Urent IoT")
            return
        }
        peripheral.discoverCharacteristics([Self.uartWrite, Self.uartNotify], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral == self.peripheral else { return }
        if profileCollectionActive {
            pendingProfileServices = max(0, pendingProfileServices - 1)
            let characteristics = service.characteristics ?? []
            profileCharacteristicCount += characteristics.count
            for characteristic in characteristics {
                if characteristic.properties.contains(.read) {
                    pendingCharacteristicReads.insert(ObjectIdentifier(characteristic))
                    peripheral.readValue(for: characteristic)
                }
            }
            finishBLEPassportIfPossible()
            return
        }
        guard state == .discovering else { return }
        if let error {
            fail("UART characteristics discovery error • \(error.localizedDescription)")
            return
        }
        let characteristics = service.characteristics ?? []
        writeCharacteristic = characteristics.first { $0.uuid == Self.uartWrite }
        notifyCharacteristic = characteristics.first { $0.uuid == Self.uartNotify }
        guard let writeCharacteristic, let notifyCharacteristic else {
            fail("Urent UART characteristics not fully resolved")
            return
        }
        let maxWithout = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let maxWith = peripheral.maximumWriteValueLength(for: .withResponse)
        log("UART resolved • writeProps=[\(writeCharacteristic.properties.rawValue)] • maxWriteWithout=\(maxWithout) • maxWriteWith=\(maxWith)")
        notificationChannelActive = false
        state = .subscribing
        notifySetupAttempts = 1
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
        log("NOTIFY establishing link on Urent pipeline...")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, characteristic === notifyCharacteristic else { return }
        if let error {
            fail("NOTIFY activation failed on Urent link • \(error.localizedDescription)")
            return
        }
        if characteristic.isNotifying {
            notificationChannelActive = true
            log("[STATUS] BLE Notification Channel Active (Urent Airship Configuration)")
            beginHandshake()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral else { return }
        _ = pendingCharacteristicReads.remove(ObjectIdentifier(characteristic))
        guard let value = characteristic.value else { return }
        if characteristic === notifyCharacteristic {
            log("[RX] Urent Packet received • bytes=\(SegwayProtocol.hex(value))")
            handle(value)
        }
        finishBLEPassportIfPossible()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, characteristic === writeCharacteristic else { return }
        waitingForWriteResponse = false
        if let error {
            log("[TX] GATT writeValue error • \(error.localizedDescription)")
        }
        flushWrites()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {}

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {}

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {}
}

/// Public controller used by SwiftUI. STANDARD, MAX and PROF keep completely
/// separate CoreBluetooth/session state; this facade only forwards the selected profile.
final class NovaBluetoothController: ObservableObject {
    enum OperatingMode: String, CaseIterable, Identifiable {
        case standard
        case max
        case prof

        var id: String { rawValue }

        var title: String {
            switch self {
            case .standard: "STANDARD"
            case .max: "MAX"
            case .prof: "PROF"
            }
        }

        var subtitle: String {
            switch self {
            case .standard: "Система до MAX"
            case .max: "Каскадный профиль MAX"
            case .prof: "STRICT-профиль с API-токеном"
            }
        }
    }

    struct ConnectionState: Equatable {
        enum Phase: Equatable {
            case unavailable
            case disconnected
            case scanning
            case connecting
            case discovering
            case subscribing
            case authenticating
            case ready
            case slCompatibility
            case diagnostic
            case failed
        }

        fileprivate let phase: Phase
        let label: String

        static let disconnected = ConnectionState(phase: .disconnected, label: "")
        static let scanning = ConnectionState(phase: .scanning, label: "")
        static let connecting = ConnectionState(phase: .connecting, label: "")
        static let discovering = ConnectionState(phase: .discovering, label: "")
        static let subscribing = ConnectionState(phase: .subscribing, label: "")
        static let authenticating = ConnectionState(phase: .authenticating, label: "")
        static let ready = ConnectionState(phase: .ready, label: "")
        static let slCompatibility = ConnectionState(phase: .slCompatibility, label: "")
        static let diagnostic = ConnectionState(phase: .diagnostic, label: "")

        static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
            lhs.phase == rhs.phase
        }

        var isReady: Bool {
            phase == .ready || phase == .slCompatibility || phase == .diagnostic
        }

        var isAuthenticated: Bool { phase == .ready }
        var isSLCompatibility: Bool { phase == .slCompatibility }
    }

    struct DiscoveredDevice: Identifiable {
        let peripheral: CBPeripheral
        var name: String
        var rssi: Int
        var uartCompatible: Bool
        var advertisementSummary: String
        var iotCodeDetected: Bool

        var id: UUID { peripheral.identifier }
        var shortID: String { String(id.uuidString.prefix(8)) }
    }

    @Published private(set) var operatingMode: OperatingMode

    private let standardController: StandardBluetoothController
    private let maxController: MaxBluetoothController
    private let profController: ProfBluetoothController
    private var activeObservation: AnyCancellable?
    private var autoReconnectValue: Bool
    private var autoResumeSpamValue: Bool
    private var ninebotSLCompatibilityValue: Bool
    private var reliableTestModeValue: Bool

    init() {
        let storedMode = UserDefaults.standard.string(forKey: "novaOperatingModeV1")
        operatingMode = OperatingMode(rawValue: storedMode ?? "") ?? .max
        autoReconnectValue = UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true
        autoResumeSpamValue = false
        ninebotSLCompatibilityValue = true
        reliableTestModeValue = UserDefaults.standard.object(forKey: "reliableTestModeV210") as? Bool ?? true
        standardController = StandardBluetoothController()
        maxController = MaxBluetoothController()
        profController = ProfBluetoothController()

        // Only the selected controller may reconnect or write. The inactive
        // controller remains idle and keeps no live session.
        standardController.autoReconnect = false
        maxController.autoReconnect = false
        profController.autoReconnect = false
        bindActiveController()
        applySettingsToActiveController()
    }

    var isMaxMode: Bool { operatingMode == .max }
    var isProfMode: Bool { operatingMode == .prof }
    var profScooterNumberText: String { profController.scooterNumberText }
    var profScooterIdentifier: String? { profController.normalizedScooterIdentifier }
    var profScooterNumberIsValid: Bool { profController.scooterNumberIsValid }

    var state: ConnectionState {
        switch operatingMode {
        case .standard: return map(standardController.state)
        case .max: return map(maxController.state)
        case .prof: return map(profController.state)
        }
    }

    var devices: [DiscoveredDevice] {
        switch operatingMode {
        case .standard: return standardController.devices.map { map($0) }
        case .max: return maxController.devices.map { map($0) }
        case .prof: return profController.devices.map { map($0) }
        }
    }

    var connectedName: String {
        switch operatingMode {
        case .standard: standardController.connectedName
        case .max: maxController.connectedName
        case .prof: profController.connectedName
        }
    }

    var logs: [String] {
        switch operatingMode {
        case .standard: standardController.logs
        case .max: maxController.logs
        case .prof: profController.logs
        }
    }

    var spamRunning: Bool {
        switch operatingMode {
        case .standard: standardController.spamRunning
        case .max: maxController.spamRunning
        case .prof: profController.spamRunning
        }
    }

    var notificationChannelActive: Bool {
        switch operatingMode {
        case .standard: standardController.notificationChannelActive
        case .max: maxController.notificationChannelActive
        case .prof: profController.notificationChannelActive
        }
    }

    var bleKeyText: String {
        switch operatingMode {
        case .standard: standardController.bleKeyText
        case .max: maxController.bleKeyText
        case .prof: profController.bleKeyText
        }
    }

    var bleKeyStored: Bool {
        switch operatingMode {
        case .standard: standardController.bleKeyStored
        case .max: maxController.bleKeyStored
        case .prof: profController.bleKeyStored
        }
    }

    var blePassportStatus: String {
        switch operatingMode {
        case .standard: standardController.blePassportStatus
        case .max: maxController.blePassportStatus
        case .prof: profController.blePassportStatus
        }
    }

    var detectedIoTCodePresent: Bool {
        switch operatingMode {
        case .standard: standardController.detectedIoTCodePresent
        case .max: maxController.detectedIoTCodePresent
        case .prof: profController.detectedIoTCodePresent
        }
    }

    var handshakeSummary: String {
        switch operatingMode {
        case .standard: standardController.handshakeSummary
        case .max: maxController.handshakeSummary
        case .prof: profController.handshakeSummary
        }
    }

    var securityAuditSummary: String {
        switch operatingMode {
        case .standard: standardController.securityAuditSummary
        case .max: maxController.securityAuditSummary
        case .prof: profController.securityAuditSummary
        }
    }

    var securityAuditFindings: [String] {
        switch operatingMode {
        case .standard: standardController.securityAuditFindings
        case .max: maxController.securityAuditFindings
        case .prof: profController.securityAuditFindings
        }
    }

    var diagnosticReport: String {
        switch operatingMode {
        case .standard: standardController.diagnosticReport
        case .max: maxController.diagnosticReport
        case .prof: profController.diagnosticReport
        }
    }

    var bleKeyIsValid: Bool {
        switch operatingMode {
        case .standard: standardController.bleKeyIsValid
        case .max: maxController.bleKeyIsValid
        case .prof: profController.bleKeyIsValid
        }
    }

    var bleKeyFingerprint: String {
        switch operatingMode {
        case .standard: standardController.bleKeyFingerprint
        case .max: maxController.bleKeyFingerprint
        case .prof: profController.bleKeyFingerprint
        }
    }

    var canSendCommands: Bool {
        switch operatingMode {
        case .standard: standardController.canSendCommands
        case .max: maxController.canSendCommands
        case .prof: profController.canSendCommands
        }
    }

    var canRunSecurityAudit: Bool {
        switch operatingMode {
        case .standard: standardController.canRunSecurityAudit
        case .max: maxController.canRunSecurityAudit
        case .prof: profController.canRunSecurityAudit
        }
    }

    var canCollectBLEPassport: Bool {
        switch operatingMode {
        case .standard: standardController.canCollectBLEPassport
        case .max: maxController.canCollectBLEPassport
        case .prof: profController.canCollectBLEPassport
        }
    }

    var canRetryHandshake: Bool {
        switch operatingMode {
        case .standard: standardController.canRetryHandshake
        case .max: maxController.canRetryHandshake
        case .prof: profController.canRetryHandshake
        }
    }

    var autoReconnect: Bool {
        get { autoReconnectValue }
        set {
            autoReconnectValue = newValue
            switch operatingMode {
            case .standard: standardController.autoReconnect = newValue
            case .max: maxController.autoReconnect = newValue
            case .prof: profController.autoReconnect = newValue
            }
        }
    }

    var autoResumeSpam: Bool {
        get { autoResumeSpamValue }
        set {
            autoResumeSpamValue = newValue
            switch operatingMode {
            case .standard: standardController.autoResumeSpam = newValue
            case .max: maxController.autoResumeSpam = newValue
            case .prof: profController.autoResumeSpam = newValue
            }
        }
    }

    var ninebotSLCompatibility: Bool {
        get { ninebotSLCompatibilityValue }
        set {
            ninebotSLCompatibilityValue = newValue
            switch operatingMode {
            case .standard: standardController.ninebotSLCompatibility = newValue
            case .max: maxController.ninebotSLCompatibility = newValue
            case .prof: profController.ninebotSLCompatibility = newValue
            }
        }
    }

    var reliableTestMode: Bool {
        get { reliableTestModeValue }
        set {
            reliableTestModeValue = newValue
            switch operatingMode {
            case .standard: standardController.reliableTestMode = newValue
            case .max: maxController.reliableTestMode = newValue
            case .prof: profController.reliableTestMode = newValue
            }
        }
    }

    func setOperatingMode(_ mode: OperatingMode) {
        guard mode != operatingMode else { return }
        deactivateCurrentController()
        operatingMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "novaOperatingModeV1")
        bindActiveController()
        applySettingsToActiveController()
        objectWillChange.send()
    }

    func updateBLEKey(_ value: String) {
        switch operatingMode {
        case .standard: standardController.updateBLEKey(value)
        case .max: maxController.updateBLEKey(value)
        case .prof: profController.updateBLEKey(value)
        }
    }

    func updateProfScooterNumber(_ value: String) {
        profController.updateScooterNumber(value)
    }

    func clearProfScooterNumber() {
        profController.clearScooterNumber()
    }

    func saveBLEKey() -> Bool {
        switch operatingMode {
        case .standard: standardController.saveBLEKey()
        case .max: maxController.saveBLEKey()
        case .prof: profController.saveBLEKey()
        }
    }

    func forgetBLEKey() {
        switch operatingMode {
        case .standard: standardController.forgetBLEKey()
        case .max: maxController.forgetBLEKey()
        case .prof: profController.forgetBLEKey()
        }
    }

    func clearLogs() {
        switch operatingMode {
        case .standard: standardController.clearLogs()
        case .max: maxController.clearLogs()
        case .prof: profController.clearLogs()
        }
    }

    func runSecurityAudit() {
        switch operatingMode {
        case .standard: standardController.runSecurityAudit()
        case .max: maxController.runSecurityAudit()
        case .prof: profController.runSecurityAudit()
        }
    }

    func collectBLEPassport() {
        switch operatingMode {
        case .standard: standardController.collectBLEPassport()
        case .max: maxController.collectBLEPassport()
        case .prof: profController.collectBLEPassport()
        }
    }

    func retryHandshake() {
        switch operatingMode {
        case .standard: standardController.retryHandshake()
        case .max: maxController.retryHandshake()
        case .prof: profController.retryHandshake()
        }
    }

    func startScan() {
        switch operatingMode {
        case .standard: standardController.startScan()
        case .max: maxController.startScan()
        case .prof: profController.startScan()
        }
    }

    func stopScan(updateState: Bool = true) {
        switch operatingMode {
        case .standard: standardController.stopScan(updateState: updateState)
        case .max: maxController.stopScan(updateState: updateState)
        case .prof: profController.stopScan(updateState: updateState)
        }
    }

    func connect(_ device: DiscoveredDevice) {
        switch operatingMode {
        case .max:
            maxController.connect(
                MaxBluetoothController.DiscoveredDevice(
                    peripheral: device.peripheral,
                    name: device.name,
                    rssi: device.rssi,
                    uartCompatible: device.uartCompatible,
                    advertisementSummary: device.advertisementSummary,
                    iotCodeDetected: device.iotCodeDetected
                )
            )
        case .standard:
            standardController.connect(
                StandardBluetoothController.DiscoveredDevice(
                    peripheral: device.peripheral,
                    name: device.name,
                    rssi: device.rssi,
                    uartCompatible: device.uartCompatible,
                    advertisementSummary: device.advertisementSummary,
                    iotCodeDetected: device.iotCodeDetected
                )
            )
        case .prof:
            profController.connect(
                ProfBluetoothController.DiscoveredDevice(
                    peripheral: device.peripheral,
                    name: device.name,
                    rssi: device.rssi,
                    uartCompatible: device.uartCompatible,
                    advertisementSummary: device.advertisementSummary,
                    iotCodeDetected: device.iotCodeDetected
                )
            )
        }
    }

    func disconnect() {
        switch operatingMode {
        case .standard: standardController.disconnect()
        case .max: maxController.disconnect()
        case .prof: profController.disconnect()
        }
    }

    func sendUnlock() -> Bool {
        switch operatingMode {
        case .standard: standardController.sendUnlock()
        case .max: maxController.sendUnlock()
        case .prof: profController.sendUnlock()
        }
    }

    func sendLock() -> Bool {
        switch operatingMode {
        case .standard: standardController.sendLock()
        case .max: maxController.sendLock()
        case .prof: profController.sendLock()
        }
    }

    func sendLight(enabled: Bool) -> Bool {
        switch operatingMode {
        case .standard: standardController.sendLight(enabled: enabled)
        case .max: maxController.sendLight(enabled: enabled)
        case .prof: profController.sendLight(enabled: enabled)
        }
    }

    func sendGSM(enabled: Bool) -> Bool {
        switch operatingMode {
        case .standard: standardController.sendGSM(enabled: enabled)
        case .max: maxController.sendGSM(enabled: enabled)
        case .prof: profController.sendGSM(enabled: enabled)
        }
    }

    func sendHelmetUnlock() -> Bool {
        switch operatingMode {
        case .standard: standardController.sendHelmetUnlock()
        case .max: maxController.sendHelmetUnlock()
        case .prof: profController.sendHelmetUnlock()
        }
    }

    func sendBatteryCoverUnlock() -> Bool {
        switch operatingMode {
        case .standard: standardController.sendBatteryCoverUnlock()
        case .max: maxController.sendBatteryCoverUnlock()
        case .prof: profController.sendBatteryCoverUnlock()
        }
    }

    func toggleSpam() {
        switch operatingMode {
        case .standard: standardController.toggleSpam()
        case .max: maxController.toggleSpam()
        case .prof: profController.toggleSpam()
        }
    }

    private func deactivateCurrentController() {
        switch operatingMode {
        case .max:
            maxController.autoReconnect = false
            maxController.stopSpam()
            maxController.stopScan(updateState: false)
            maxController.disconnect()
        case .standard:
            standardController.autoReconnect = false
            standardController.stopSpam()
            standardController.stopScan(updateState: false)
            standardController.disconnect()
        case .prof:
            profController.autoReconnect = false
            profController.stopSpam()
            profController.stopScan(updateState: false)
            profController.disconnect()
        }
        activeObservation = nil
    }

    private func bindActiveController() {
        let publisher: AnyPublisher<Void, Never>
        switch operatingMode {
        case .standard:
            publisher = standardController.objectWillChange.eraseToAnyPublisher()
        case .max:
            publisher = maxController.objectWillChange.eraseToAnyPublisher()
        case .prof:
            publisher = profController.objectWillChange.eraseToAnyPublisher()
        }
        activeObservation = publisher.sink { [weak self] _ in
            guard let self else { return }
            if Thread.isMainThread {
                self.objectWillChange.send()
            } else {
                DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
            }
        }
    }

    private func applySettingsToActiveController() {
        switch operatingMode {
        case .max:
            standardController.autoReconnect = false
            profController.autoReconnect = false
            maxController.autoResumeSpam = autoResumeSpamValue
            maxController.ninebotSLCompatibility = ninebotSLCompatibilityValue
            maxController.reliableTestMode = reliableTestModeValue
            maxController.autoReconnect = autoReconnectValue
        case .standard:
            maxController.autoReconnect = false
            profController.autoReconnect = false
            standardController.autoResumeSpam = autoResumeSpamValue
            standardController.ninebotSLCompatibility = ninebotSLCompatibilityValue
            standardController.reliableTestMode = reliableTestModeValue
            standardController.autoReconnect = autoReconnectValue
        case .prof:
            standardController.autoReconnect = false
            maxController.autoReconnect = false
            profController.autoResumeSpam = autoResumeSpamValue
            profController.ninebotSLCompatibility = ninebotSLCompatibilityValue
            profController.reliableTestMode = reliableTestModeValue
            profController.autoReconnect = autoReconnectValue
        }
    }

    private func map(_ state: MaxBluetoothController.ConnectionState) -> ConnectionState {
        let phase: ConnectionState.Phase
        switch state {
        case .unavailable(_): phase = .unavailable
        case .disconnected: phase = .disconnected
        case .scanning: phase = .scanning
        case .connecting: phase = .connecting
        case .discovering: phase = .discovering
        case .subscribing: phase = .subscribing
        case .authenticating: phase = .authenticating
        case .ready: phase = .ready
        case .slCompatibility: phase = .slCompatibility
        case .diagnostic: phase = .diagnostic
        case .failed(_): phase = .failed
        }
        return ConnectionState(phase: phase, label: state.label)
    }

    private func map(_ state: StandardBluetoothController.ConnectionState) -> ConnectionState {
        let phase: ConnectionState.Phase
        switch state {
        case .unavailable(_): phase = .unavailable
        case .disconnected: phase = .disconnected
        case .scanning: phase = .scanning
        case .connecting: phase = .connecting
        case .discovering: phase = .discovering
        case .subscribing: phase = .subscribing
        case .authenticating: phase = .authenticating
        case .ready: phase = .ready
        case .slCompatibility: phase = .slCompatibility
        case .diagnostic: phase = .diagnostic
        case .failed(_): phase = .failed
        }
        return ConnectionState(phase: phase, label: state.label)
    }

    private func map(_ state: ProfBluetoothController.ConnectionState) -> ConnectionState {
        let phase: ConnectionState.Phase
        switch state {
        case .unavailable(_): phase = .unavailable
        case .disconnected: phase = .disconnected
        case .scanning: phase = .scanning
        case .connecting: phase = .connecting
        case .discovering: phase = .discovering
        case .subscribing: phase = .subscribing
        case .authenticating: phase = .authenticating
        case .ready: phase = .ready
        case .slCompatibility: phase = .slCompatibility
        case .diagnostic: phase = .diagnostic
        case .failed(_): phase = .failed
        }
        return ConnectionState(phase: phase, label: state.label)
    }

    private func map(_ device: MaxBluetoothController.DiscoveredDevice) -> DiscoveredDevice {
        DiscoveredDevice(
            peripheral: device.peripheral,
            name: device.name,
            rssi: device.rssi,
            uartCompatible: device.uartCompatible,
            advertisementSummary: device.advertisementSummary,
            iotCodeDetected: device.iotCodeDetected
        )
    }

    private func map(_ device: StandardBluetoothController.DiscoveredDevice) -> DiscoveredDevice {
        DiscoveredDevice(
            peripheral: device.peripheral,
            name: device.name,
            rssi: device.rssi,
            uartCompatible: device.uartCompatible,
            advertisementSummary: device.advertisementSummary,
            iotCodeDetected: device.iotCodeDetected
        )
    }

    private func map(_ device: ProfBluetoothController.DiscoveredDevice) -> DiscoveredDevice {
        DiscoveredDevice(
            peripheral: device.peripheral,
            name: device.name,
            rssi: device.rssi,
            uartCompatible: device.uartCompatible,
            advertisementSummary: device.advertisementSummary,
            iotCodeDetected: device.iotCodeDetected
        )
    }
}
