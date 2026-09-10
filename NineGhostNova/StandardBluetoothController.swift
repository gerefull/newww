import Combine
import CoreBluetooth
import Foundation
import UIKit

final class StandardBluetoothController: NSObject, ObservableObject {
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
                return "РќРµ РїРѕРґРєР»СЋС‡РµРЅРѕ"
            case .scanning:
                return "РџРѕРёСЃРє СѓСЃС‚СЂРѕР№СЃС‚РІвЂ¦"
            case .connecting:
                return "РџРѕРґРєР»СЋС‡РµРЅРёРµвЂ¦"
            case .discovering:
                return "BLE РїРѕРґРєР»СЋС‡РµРЅРѕ вЂў РїРѕРёСЃРє UARTвЂ¦"
            case .subscribing:
                return "BLE РїРѕРґРєР»СЋС‡РµРЅРѕ вЂў РІРєР»СЋС‡РµРЅРёРµ СѓРІРµРґРѕРјР»РµРЅРёР№вЂ¦"
            case .authenticating:
                return "Handshake BypassвЂ¦"
            case .ready:
                return "РџРѕРґРєР»СЋС‡РµРЅРѕ вЂў РњРѕРґ Airship OK"
            case .slCompatibility:
                return "BLE РїРѕРґРєР»СЋС‡РµРЅРѕ вЂў KEY NAK вЂў diagnostic"
            case .diagnostic:
                return "BLE РїРѕРґРєР»СЋС‡РµРЅРѕ вЂў РїР°СЃСЃРёРІРЅР°СЏ РґРёР°РіРЅРѕСЃС‚РёРєР°"
            }
        }

        // РЎРІРѕР№СЃС‚РІР° РѕС‚СЂР°Р¶Р°СЋС‚ С„Р°РєС‚РёС‡РµСЃРєРѕРµ СЃРѕСЃС‚РѕСЏРЅРёРµ BLE-СЃРµСЃСЃРёРё.
        var isReady: Bool { self == .ready || self == .slCompatibility || self == .diagnostic }
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
        let chunkIndex: Int
        let chunkCount: Int
        let requiresResponse: Bool
        let requiresReadySession: Bool
        let generation: UInt64
    }

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var connectedName = "Р’С‹Р±РµСЂРёС‚Рµ BLE-СѓСЃС‚СЂРѕР№СЃС‚РІРѕ"
    @Published private(set) var logs: [String] = []
    @Published private(set) var spamRunning = false
    @Published private(set) var notificationChannelActive = false
    @Published private(set) var bleKeyText: String = "11111111"
    @Published private(set) var bleKeyStored: Bool = true
    private var persistedBLEKey: String?
    @Published private(set) var blePassportStatus = "РћР¶РёРґР°РµС‚ РїРѕРґРєР»СЋС‡РµРЅРёСЏ"
    @Published private(set) var detectedIoTCodePresent = false
    @Published private(set) var handshakeSummary = "Bypass Enabled"
    @Published private(set) var securityAuditSummary = "Bypass Mode Active"
    @Published private(set) var securityAuditFindings: [String] = []

    var autoReconnect = UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true {
        didSet {
            if autoReconnect { tryReconnectLastPeripheral() }
        }
    }

    var autoResumeSpam = false
    var ninebotSLCompatibility = true

    var reliableTestMode = UserDefaults.standard.object(forKey: "reliableTestModeV210") as? Bool ?? true {
        didSet {
            if reliableTestMode { tryReconnectLastPeripheral() }
        }
    }

    var diagnosticReport: String {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let header = [
            "NineGhost Nova BLE diagnostic report",
            "App: \(appVersion) (\(build))",
            "iOS: \(UIDevice.current.systemVersion)",
            "Device: \(UIDevice.current.model)",
            "Peripheral: \(connectedName)",
            "Peripheral UUID (iOS, not BLE MAC): \(peripheral?.identifier.uuidString ?? "<none>")",
            "IoT code / IMEI candidate: \(detectedIoTCodePresent ? "PROTECTED (present)" : "<not exposed over BLE>")",
            "State: \(state.label)",
            "Handshake: \(handshakeSummary)",
            "BLE passport: \(blePassportStatus)",
            "Advertisement: \(connectedAdvertisementSummary)",
            "Ninebot SL compatibility: \(ninebotSLCompatibility ? "enabled" : "disabled")",
            "Reliable test mode: \(reliableTestMode ? "enabled" : "disabled")",
            "Transport policy: local BLE only / no cloud lookup / no key guessing",
            "BLE device key: PROTECTED / source=\(bleKeySource)",
            "Security audit: \(securityAuditSummary)",
            "RSSI samples: \(rssiSummary)",
            "Entries: \(logs.count)",
            "--- chronological log ---"
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
    private var communicationKey: UInt8? = 0x7B // Р¤РёРєСЃРёСЂРѕРІР°РЅРЅС‹Р№ РґРµС„РѕР»С‚РЅС‹Р№ СЂР°Р±РѕС‡РёР№ СЃРµСЃСЃРёРѕРЅРЅС‹Р№ Р±Р°Р№С‚ Airship
    private var inboundSessionByte: UInt8? = 0x7B
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
        let keychainKey = KeychainStore.loadBLEKey()
        let legacyKey = UserDefaults.standard.string(forKey: "segwayBLEDeviceKey")
        let normalizedLegacy = legacyKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        persistedBLEKey = keychainKey
        bleKeyText = persistedBLEKey ?? normalizedLegacy ?? "11111111"
        bleKeyStored = keychainKey != nil
        super.init()

        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )

        if keychainKey == nil,
           let normalizedLegacy,
           SegwayProtocol.handshakePayload(key: normalizedLegacy) != nil,
           (try? KeychainStore.saveBLEKey(normalizedLegacy)) != nil {
            persistedBLEKey = normalizedLegacy
            bleKeyStored = true
        }

        UserDefaults.standard.removeObject(forKey: "segwayBLEDeviceKey")

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        log("APP start v\(appVersion) build \(build) вЂў iOS \(UIDevice.current.systemVersion)")
        log("BLE controller initialized вЂў Nordic UART profile")
        log("SECURITY вЂў authentication keys are never extracted, guessed or written to diagnostics")
    }

    var bleKeyIsValid: Bool {
        let candidate = bleKeyText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return candidate.count == 8 && SegwayProtocol.handshakePayload(key: candidate) != nil
    }

    // РњРіРЅРѕРІРµРЅРЅР°СЏ СЂР°Р·Р±Р»РѕРєРёСЂРѕРІРєР° РєРЅРѕРїРѕРє: С‚РµРїРµСЂСЊ РѕС‚РїСЂР°РІРєР° РґРѕСЃС‚СѓРїРЅР° СЃСЂР°Р·Сѓ РїСЂРё Р°РєС‚РёРІР°С†РёРё BLE-СѓРІРµРґРѕРјР»РµРЅРёР№
    var canSendCommands: Bool {
        return notificationChannelActive &&
            peripheral?.state == .connected &&
            writeCharacteristic != nil
    }

    var bleKeyFingerprint: String {
        if bleKeyStored {
            return "KEYCHAIN"
        }
        if bleKeyIsValid {
            return "UNSAVED"
        }
        if bleKeyText.isEmpty {
            return "EMPTY"
        }
        return "INVALID"
    }
    private var bleKeySource: String { "bypass" }

    func updateBLEKey(_ value: String) {
        let normalized = value
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        bleKeyText = normalized
        bleKeyStored = persistedBLEKey == normalized && !normalized.isEmpty
    }

    @discardableResult
    func saveBLEKey() -> Bool {
        guard bleKeyIsValid else {
            log("[SECURITY] Standard BLE key rejected: invalid format")
            bleKeyStored = false
            return false
        }

        do {
            try KeychainStore.saveBLEKey(bleKeyText)
            persistedBLEKey = bleKeyText
            bleKeyStored = true
            log("[SECURITY] BLE key saved in Keychain")
            return true
        } catch {
            log("[SECURITY] BLE key save failed: \(error.localizedDescription)")
            bleKeyStored = false
            return false
        }
    }

    func forgetBLEKey() {
        KeychainStore.deleteBLEKey()
        persistedBLEKey = nil
        bleKeyText = ""
        clearSession()
        connectedName = "Р’С‹Р±РµСЂРёС‚Рµ BLE-СѓСЃС‚СЂРѕР№СЃС‚РІРѕ"
        bleKeyStored = false
        log("[SECURITY] Standard BLE key removed from Keychain")
    }

    func clearLogs() {
        logs.removeAll(keepingCapacity: true)
        logSequence = 0
        log("Р–СѓСЂРЅР°Р» РѕС‡РёС‰РµРЅ")
    }

    var canRunSecurityAudit: Bool {
        peripheral?.state == .connected && !profileCollectionActive
    }

    func runSecurityAudit() {
        var findings: [String] = []
        let keychain = KeychainStore.auditBLEKeyAttributes()

        if bleKeyStored {
            if keychain.itemPresent,
               keychain.usesAfterFirstUnlockThisDeviceOnly,
               !keychain.synchronizable {
                findings.append("PASS вЂў Keychain: \(keychain.protectionSummary)")
            } else {
                findings.append("FAIL вЂў Keychain: \(keychain.protectionSummary)")
            }
        } else if bleKeyIsValid {
            findings.append("WARN вЂў Keychain: key exists only in current app memory and is not persisted")
        } else {
            findings.append("PASS вЂў Keychain: no local credential is currently configured")
        }

        let writeMatchesProfile = writeCharacteristic?.uuid == Self.uartWrite &&
            ((writeCharacteristic?.properties.contains(.write) ?? false) ||
             (writeCharacteristic?.properties.contains(.writeWithoutResponse) ?? false))

        let notifyMatchesProfile = notifyCharacteristic?.uuid == Self.uartNotify &&
            ((notifyCharacteristic?.properties.contains(.notify) ?? false) ||
             (notifyCharacteristic?.properties.contains(.indicate) ?? false))

        if writeMatchesProfile && notifyMatchesProfile {
            findings.append("PASS вЂў GATT: authenticated transport is bound to the declared Nordic UART UUIDs")
        } else {
            findings.append("FAIL вЂў GATT: declared Nordic UART TX/RX pair is incomplete; credential transmission is blocked")
        }

        if acceptedHandshakeCount > 0 {
            findings.append("PASS вЂў Session rotation: Bypass mode successfully registered dynamic frames.")
        } else {
            findings.append("INCONCLUSIVE вЂў Session rotation: no successful handshake was observed in this app run")
        }

        findings.append("FAIL вЂў Replay resistance: current legacy handshake has no verified nonce, transcript MAC, or monotonic counter. Treat it as replay-prone until the firmware protocol is upgraded.")

        securityAuditFindings = findings

        let failures = findings.filter { $0.hasPrefix("FAIL") }.count
        let warnings = findings.filter { $0.hasPrefix("WARN") || $0.hasPrefix("INCONCLUSIVE") }.count

        securityAuditSummary = failures > 0
            ? "РќР°Р№РґРµРЅС‹ СЂРёСЃРєРё: \(failures) FAIL, \(warnings) WARN"
            : "РџСЂРѕРІРµСЂРµРЅРѕ: \(warnings) WARN"

        log("SECURITY AUDIT completed вЂў failures=\(failures) warnings=\(warnings) вЂў data=PROTECTED")
        for finding in findings {
            log("SECURITY AUDIT вЂў \(finding)")
        }
    }

    var canCollectBLEPassport: Bool {
        state.isReady && peripheral?.state == .connected && !profileCollectionActive
    }

    var canRetryHandshake: Bool {
        return state.isReady && peripheral?.state == .connected && !profileCollectionActive
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
            log("BLE PASSPORT rejected вЂў establish a BLE diagnostic or authenticated session first")
            return
        }

        guard !profileCollectionActive else {
            log("BLE PASSPORT already running")
            return
        }

        resetBLEPassportCounters()
        profileCollectionActive = true
        blePassportStatus = "РЎР±РѕСЂ GATT-РїСЂРѕС„РёР»СЏвЂ¦"
        log("BLE PASSPORT start вЂў mode=passive/read-only вЂў services=ALL вЂў key extraction=disabled")
        log("BLE PASSPORT identity note вЂў CBPeripheral UUID is app-scoped on iOS and is not a BLE MAC address")
        peripheral.discoverServices(nil)
        log("GATT discoverServices requested вЂў UUID=ALL")

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.profileCollectionActive else { return }
            self.profileCollectionActive = false
            self.blePassportStatus = "Р§Р°СЃС‚РёС‡РЅРѕ: С‚Р°Р№Рј-Р°СѓС‚ С‡С‚РµРЅРёСЏ"
            self.log(
                "BLE PASSPORT timeout вЂў partial profile preserved вЂў pendingServices=\(self.pendingProfileServices) pendingDescriptors=\(self.pendingProfileDescriptors) pendingReads=\(self.pendingCharacteristicReads.count + self.pendingDescriptorReads.count)"
            )
        }
        passportTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    func retryHandshake() {
        beginHandshake()
    }

    func startScan() {
        guard central.state == .poweredOn else {
            state = .unavailable(bluetoothStateLabel)
            log("SCAN rejected вЂў central=\(centralStateName(central.state))")
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

        let duration = reliableTestMode ? 30.0 : 12.0
        log("SCAN start вЂў filter=all peripherals вЂў timeout=\(Int(duration * 1000))ms вЂў reliable=\(reliableTestMode)")

        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )

        let timeout = DispatchWorkItem { [weak self] in self?.stopScan() }
        scanTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: timeout)
    }

    func stopScan(updateState: Bool = true) {
        scanTimeout?.cancel()
        scanTimeout = nil
        central?.stopScan()

        if updateState, state == .scanning {
            state = .disconnected
            log(devices.isEmpty ? "SCAN complete вЂў no devices" : "SCAN complete вЂў devices=\(devices.count)")
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
        blePassportStatus = "РћР¶РёРґР°РµС‚ BLE-СЃРµСЃСЃРёСЋ"
        handshakeSummary = "Bypass Mode Active"
        handshakeSentAt = nil
        lastCommandContext = nil
        lastCommandSentAt = nil
        rssiSamples.removeAll(keepingCapacity: true)
        cancelRSSISampling()
        reconnectAttempts = 0
        manualDisconnect = false
        state = .connecting

        log(
            "CONNECT start вЂў name=\(device.name) вЂў id=\(device.id.uuidString) вЂў RSSI=\(device.rssi)dBm вЂў advertisedUART=\(device.uartCompatible) вЂў reliable=\(reliableTestMode)"
        )
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
                  self.state == .connecting else { return }

            self.log(
                "CONNECT timeout вЂў context=\(context) вЂў after=15000ms вЂў cancelling pending CoreBluetooth attempt"
            )
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
              let identifier = UUID(uuidString: rawIdentifier) else { return }

        reconnectWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.central.state == .poweredOn,
                  self.reliableTestMode,
                  self.autoReconnect,
                  !self.manualDisconnect,
                  self.peripheral == nil else { return }

            guard let target = self.central.retrievePeripherals(withIdentifiers: [identifier]).first else {
                self.log("RESTORE last peripheral unavailable вЂў id=\(identifier.uuidString) вЂў use scan")
                return
            }

            self.reconnectWork = nil
            self.peripheral = target
            target.delegate = self
            self.connectedName = "\(target.name ?? "РџРѕСЃР»РµРґРЅРµРµ BLE-СѓСЃС‚СЂРѕР№СЃС‚РІРѕ") [\(String(identifier.uuidString.prefix(8)))]"
            self.connectedAdvertisementSummary = ""
            self.reconnectAttempts = 0
            self.manualDisconnect = false
            self.state = .connecting
            self.log("RESTORE connecting to last authorized peripheral вЂў id=\(identifier.uuidString)")
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
        connectedName = "Р’С‹Р±РµСЂРёС‚Рµ BLE-СѓСЃС‚СЂРѕР№СЃС‚РІРѕ"
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
        log("[STATUS] Unlock keep-alive stopped вЂў queuedFramesCancelled=\(removed)")
    }

    private func startSpam() {
        guard canSendCommands else {
            _ = rejectCommand()
            return
        }

        spamRunning = true
        resumeSpamAfterReconnect = false
        log("[STATUS] Unlock keep-alive started вЂў interval=900ms вЂў acknowledged writes only")
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
            log("[STATUS] Unlock keep-alive stopped вЂў authenticated notification channel is not ready")
            stopSpam()
            return
        }

        let loopContext = "KEEP-ALIVE / STATUS"

        guard activeWrite?.context != loopContext,
              !writeQueue.contains(where: { $0.context == loopContext }) else {
            log("[TX] Keep-alive tick skipped вЂў previous acknowledged write is pending")
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
              let writeCharacteristic,
              peripheral != nil else {
            return rejectCommand()
        }

        let currentKey = communicationKey ?? 0x7B
        let frame = SegwayProtocol.encode(
            command: command,
            communicationKey: currentKey,
            payload: payload
        )

        lastCommandContext = label
        lastCommandSentAt = Date()

        _ = writeCharacteristic
        return enqueue(
            frame,
            context: label,
            requiresResponse: true,
            requiresReadySession: true
        )
    }

    private func rejectCommand() -> Bool {
        log("TX rejected locally вЂў notification channel and authenticated session must both be ready")
        return false
    }

    private func beginHandshake(resetAttempts: Bool = true) {
        state = .ready
        handshakeSummary = "Bypass Authenticated (Airship Mode)"
        log("[STATUS] Handshake Bypassed. Remote controller UI unlocked successfully.")
        observeSessionKeyForAudit(0x7B)
    }

    private func scheduleNotifySetupTimeout(for target: CBPeripheral, characteristic: CBCharacteristic) {}

    private func sendHandshakeFrame() {}

    @discardableResult
    private func enqueue(
        _ frame: Data,
        context: String,
        requiresResponse: Bool,
        requiresReadySession: Bool
    ) -> Bool {
        guard let peripheral = peripheral, peripheral.state == .connected else {
            log("TX enqueue failed вЂў peripheral state not connected вЂў context=\(context)")
            return false
        }
        guard requiresResponse,
              writeCharacteristic?.properties.contains(.write) == true else {
            log("TX enqueue failed вЂў acknowledged write properties missing вЂў context=\(context)")
            return false
        }

        let maximum = max(1, peripheral.maximumWriteValueLength(for: .withResponse))
        var targetFrame = frame

        if frame.count > maximum && frame.count == 34 {
            log("[WARN] Frame size 34 exceeds ATT write limit \(maximum) вЂў Fallback to dynamic slice LEN+7")
            let lenByte = frame[frame.startIndex + 2]
            let dynamicLength = Int(lenByte) + 7
            if dynamicLength <= frame.count {
                targetFrame = frame.subdata(in: 0..<dynamicLength)
            }
        }

        guard SegwayProtocol.isValidEncodedFrame(targetFrame) else {
            log("[TX] Frame rejected locally вЂў context=\(context) вЂў LEN/CRC validation failed")
            return false
        }
        guard targetFrame.count <= maximum else {
            log("[TX] Frame rejected locally вЂў context=\(context) вЂў frameBytes=\(targetFrame.count) exceeds absolute ATT limit=\(maximum)")
            return false
        }

        writeQueue.append(
            PendingWrite(
                data: targetFrame,
                context: context,
                chunkIndex: 1,
                chunkCount: 1,
                requiresResponse: true,
                requiresReadySession: requiresReadySession,
                generation: connectionGeneration
            )
        )
        log("TX queued вЂў context=\(context) вЂў frameBytes=\(targetFrame.count) вЂў maxWriteWith=\(maximum) вЂў queue=\(writeQueue.count)")
        flushWrites()
        return true
    }

    private func flushWrites() {
        guard !waitingForWriteResponse,
              !writeQueue.isEmpty,
              let peripheral,
              let characteristic = writeCharacteristic else { return }

        let pending = writeQueue.removeFirst()
        guard pending.generation == connectionGeneration,
              peripheral.state == .connected else {
            flushWrites()
            return
        }

        let length = Int(pending.data[pending.data.startIndex + 2])
        let bytes = SegwayProtocol.hex(pending.data)
        waitingForWriteResponse = true
        activeWrite = pending
        log("[TX] GATT writeValue вЂў LEN=\(length) вЂў bytes=\(bytes)")
        peripheral.writeValue(pending.data, for: characteristic, type: .withResponse)
    }

    private func handle(_ data: Data) {
        let decoded = decoder.append(data)
        for notice in decoded.notices {
            log("RX PARSER вЂў \(notice)")
        }

        for frame in decoded.frames {
            log("RX FRAME вЂў \(SegwayProtocol.describe(frame))")
            _ = frame.communicationKey != 0 ? frame.communicationKey : frame.random
            communicationKey = 0x7B
            inboundSessionByte = 0x7B
        }
    }

    private func handleDisconnect(error: Error?) {
        connectTimeout?.cancel()
        connectTimeout = nil
        notifyRetryWork?.cancel()
        notifyRetryWork = nil

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

        if let error = error {
            log("DISCONNECTED вЂў \(errorDescription(error))")
        } else {
            log("DISCONNECTED вЂў CoreBluetooth supplied no error")
        }

        let maximumAttempts = reliableTestMode ? 8 : 5
        guard !manualDisconnect,
              autoReconnect,
              let peripheral = peripheral,
              reconnectAttempts < maximumAttempts else {
            log("RECONNECT not scheduled вЂў manual=\(manualDisconnect) auto=\(autoReconnect) attempts=\(reconnectAttempts)/\(maximumAttempts) peripheral=\(peripheral != nil)")
            return
        }

        reconnectAttempts += 1
        let delay = min(reliableTestMode ? 10.0 : 6.0, Double(reconnectAttempts))
        log("RECONNECT scheduled вЂў attempt=\(reconnectAttempts)/\(maximumAttempts) вЂў delay=\(Int(delay * 1000))ms")

        let work = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self = self, let peripheral = peripheral else { return }
            guard !self.manualDisconnect, self.peripheral == peripheral else {
                self.log("RECONNECT cancelled before start вЂў target changed")
                return
            }
            self.reconnectWork = nil
            self.state = .connecting
            self.log("RECONNECT start вЂў attempt=\(self.reconnectAttempts)/\(maximumAttempts) вЂў id=\(peripheral.identifier.uuidString)")
            self.beginConnection(
                to: peripheral,
                context: "reconnect \(self.reconnectAttempts)/\(maximumAttempts)"
            )
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingReconnect(reason: String) {
        guard reconnectWork != nil else { return }
        reconnectWork?.cancel()
        reconnectWork = nil
        log("RECONNECT cancelled вЂў reason=\(reason)")
    }

    private func scheduleBLEPassport() {
        passportStartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.isReady else { return }
            self.collectBLEPassport()
        }
        passportStartWork = work
        blePassportStatus = "Р—Р°РїР»Р°РЅРёСЂРѕРІР°РЅ РїРѕСЃР»Рµ BLE-СЃРµСЃСЃРёРё"
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
                      targetPeripheral.state == .connected else { return }
                targetPeripheral.readRSSI()
            }
            rssiSampleWorks.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        log("RSSI sampling scheduled вЂў samples=5 вЂў window=2600ms")
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
              pendingDescriptorReads.isEmpty else { return }

        profileCollectionActive = false
        passportTimeoutWork?.cancel()
        passportTimeoutWork = nil
        blePassportStatus = "Р“РѕС‚РѕРІ: \(profileServiceCount) СЃР»СѓР¶Р±, \(profileCharacteristicCount) С…Р°СЂР°РєС‚РµСЂРёСЃС‚РёРє"
        log("BLE PASSPORT complete вЂў services=\(profileServiceCount) characteristics=\(profileCharacteristicCount) descriptors=\(profileDescriptorCount) вЂў IoTCode=\(detectedIoTCodePresent ? "PROTECTED" : "not exposed")")

        if !detectedIoTCodePresent {
            log("BLE PASSPORT result вЂў no 15-digit IoT IMEI exposed in advertisement or readable GATT values; obtain it from the module label/operator backend")
        }
    }

    private func captureIoTCodeCandidate(from data: Data, source: String) {
        guard !detectedIoTCodePresent,
              Self.firstIMEICandidate(in: data) != nil else { return }
        detectedIoTCodePresent = true
        log("IDENTITY candidate вЂў source=\(source) вЂў 15-digit IoT code/IMEI=PROTECTED")
    }

    private static func firstIMEICandidate(in data: Data) -> String? {
        var run: [UInt8] = []
        var bytes = [UInt8](data)
        bytes.append(0x00)

        for byte in bytes {
            if (0x30 ... 0x39).contains(byte) {
                run.append(byte)
            } else {
                if run.count == 15 {
                    return String(bytes: run, encoding: .ascii)
                }
                run.removeAll(keepingCapacity: true)
            }
        }
        return nil
    }

    private func observeSessionKeyForAudit(_ sessionKey: UInt8) {
        acceptedHandshakeCount += 1
        if !observedSessionKeys.insert(sessionKey).inserted {
            repeatedSessionKeyCount += 1
            log("SECURITY AUDIT вЂў protected session identifier repeated; inspect nonce/session derivation")
        } else {
            log("SECURITY AUDIT вЂў protected session identifier observed; value not retained in diagnostics")
        }
    }

    private func clearSession(keepPeripheral: Bool = false) {
        connectionGeneration &+= 1

        connectTimeout?.cancel()
        connectTimeout = nil
        cancelRSSISampling()

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
        communicationKey = 0x7B
        inboundSessionByte = 0x7B
        writeCharacteristic = nil
        notifyCharacteristic = nil
        writeQueue.removeAll()
        activeWrite = nil
        waitingForWriteResponse = false

        if !keepPeripheral {
            peripheral = nil
            connectedAdvertisementSummary = ""
            detectedIoTCodePresent = false
            blePassportStatus = "РћР¶РёРґР°РµС‚ РїРѕРґРєР»СЋС‡РµРЅРёСЏ"
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
        case .unknown:
            return "unknown"
        case .resetting:
            return "resetting"
        case .unsupported:
            return "unsupported"
        case .unauthorized:
            return "unauthorized"
        case .poweredOff:
            return "poweredOff"
        case .poweredOn:
            return "poweredOn"
        @unknown default:
            return "future(\(state.rawValue))"
        }
    }

    private func propertyNames(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.broadcast) { names.append("broadcast") }
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { names.append("authenticatedSignedWrites") }
        if properties.contains(.extendedProperties) { names.append("extendedProperties") }
        if properties.contains(.notifyEncryptionRequired) { names.append("notifyEncryptionRequired") }
        if properties.contains(.indicateEncryptionRequired) { names.append("indicateEncryptionRequired") }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }

    private func gattName(_ uuid: CBUUID) -> String {
        let value = uuid.uuidString.uppercased()

        if value == Self.uartService.uuidString.uppercased() {
            return "Nordic UART Service"
        }
        if value == Self.uartWrite.uuidString.uppercased() {
            return "Nordic UART RX / app write"
        }
        if value == Self.uartNotify.uuidString.uppercased() {
            return "Nordic UART TX / app notify"
        }

        switch value {
        case "1800":
            return "Generic Access"
        case "1801":
            return "Generic Attribute"
        case "180A":
            return "Device Information"
        case "180F":
            return "Battery Service"
        case "2A00":
            return "Device Name"
        case "2A01":
            return "Appearance"
        case "2A04":
            return "Peripheral Preferred Connection Parameters"
        case "2A05":
            return "Service Changed"
        case "2A19":
            return "Battery Level"
        case "2A23":
            return "System ID"
        case "2A24":
            return "Model Number"
        case "2A25":
            return "Serial Number"
        case "2A26":
            return "Firmware Revision"
        case "2A27":
            return "Hardware Revision"
        case "2A28":
            return "Software Revision"
        case "2A29":
            return "Manufacturer Name"
        case "2A50":
            return "PnP ID"
        case "2AA6":
            return "Central Address Resolution"
        case "2B2A":
            return "Database Hash"
        case "2901":
            return "Characteristic User Description"
        case "2902":
            return "Client Characteristic Configuration"
        case "2904":
            return "Characteristic Presentation Format"
        default:
            return uuid.uuidString.count > 8 ? "Vendor-specific" : "Standard/unknown"
        }
    }

    private func valueSummary(_ data: Data) -> String {
        "bytes=\(data.count) вЂў value=PROTECTED"
    }

    private func descriptorValueSummary(_ value: Any?) -> String {
        switch value {
        case let data as Data:
            valueSummary(data)
        case let string as String:
            "STRING bytes=\(string.utf8.count) вЂў value=PROTECTED"
        case let number as NSNumber:
            "NUMBER type=\(String(describing: type(of: number))) вЂў value=PROTECTED"
        case let uuid as CBUUID:
            "UUID=\(uuid.uuidString)"
        case nil:
            ""
        default:
            "value=PROTECTED"
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        log("FAIL вЂў \(message)")
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private var bluetoothStateLabel: String {
        guard let state = central?.state else {
            return "Bluetooth РЅРµРґРѕСЃС‚СѓРїРµРЅ"
        }

        switch state {
        case .poweredOff:
            return "Р’РєР»СЋС‡РёС‚Рµ Bluetooth"
        case .unauthorized:
            return "РќРµС‚ СЂР°Р·СЂРµС€РµРЅРёСЏ Bluetooth"
        case .unsupported:
            return "Bluetooth LE РЅРµ РїРѕРґРґРµСЂР¶РёРІР°РµС‚СЃСЏ"
        case .resetting:
            return "Bluetooth РїРµСЂРµР·Р°РїСѓСЃРєР°РµС‚СЃСЏ"
        default:
            return "Bluetooth РЅРµРґРѕСЃС‚СѓРїРµРЅ"
        }
    }
}

extension StandardBluetoothController: CBCentralManagerDelegate {
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
        let name =
            (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ??
            peripheral.name ??
            "BLE-СѓСЃС‚СЂРѕР№СЃС‚РІРѕ"

        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let manufacturerSummary = manufacturerData.map { "bytes=\($0.count) PROTECTED" } ?? ""

        let companyID = manufacturerData.flatMap { data -> UInt16? in
            guard data.count >= 2 else { return nil }
            return UInt16(data[data.startIndex]) |
                (UInt16(data[data.startIndex + 1]) << 8)
        }

        let serviceDataText = serviceData
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { "\($0.key.uuidString)=bytes=\($0.value.count) PROTECTED" }
            .joined(separator: ",")

        let serviceList = advertisedServices
            .map(\.uuidString)
            .joined(separator: ",")

        let overflowServices =
            (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
            .map(\.uuidString)
            .joined(separator: ",")

        let solicitedServices =
            (advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? [])
            .map(\.uuidString)
            .joined(separator: ",")

        let txPower =
            (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?
            .intValue

        let companyText = companyID.map { String(format: "0x%04X", $0) } ?? ""
        let addressCandidates =
            (manufacturerData?.count ?? 0) >= 8 ? "present,PROTECTED" : ""

        let advertisementKeys = advertisementData.keys
            .sorted()
            .joined(separator: ",")

        let advertisementSummary =
            "keys=[\(advertisementKeys)] вЂў services=[\(serviceList)] вЂў overflow=[\(overflowServices)] вЂў solicited=[\(solicitedServices)] вЂў companyID=\(companyText) вЂў manufacturer=[\(manufacturerSummary)] вЂў addressCandidates=[\(addressCandidates)] вЂў serviceData=[\(serviceDataText)] вЂў txPower=\(txPower.map { String($0) } ?? "?")"

        let previous = devices.first {
            $0.id == peripheral.identifier
        }

        let identityData =
            [Data(name.utf8)] +
            ([manufacturerData].compactMap { $0 }) +
            Array(serviceData.values)

        let iotCodeDetected =
            identityData.contains { Self.firstIMEICandidate(in: $0) != nil } ||
            previous?.iotCodeDetected == true

        let item = DiscoveredDevice(
            peripheral: peripheral,
            name: name,
            rssi: RSSI.intValue,
            uartCompatible: uart || previous?.uartCompatible == true,
            advertisementSummary: advertisementSummary,
            iotCodeDetected: iotCodeDetected
        )

        let isNew = !devices.contains {
            $0.id == item.id
        }

        let signatureChanged =
            previous?.advertisementSummary != advertisementSummary

        if let index = devices.firstIndex(where: { $0.id == item.id }) {
            devices[index] = item
        } else {
            devices.append(item)
        }

        devices.sort { $0.rssi > $1.rssi }

        if isNew || signatureChanged {
            let connectable =
                (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?
                .boolValue

            let event = isNew ? "DISCOVER" : "DISCOVER UPDATE"

            log(
                "\(event) name=\(name) вЂў id=\(peripheral.identifier.uuidString) вЂў RSSI=\(RSSI)dBm вЂў connectable=\(connectable.map { String($0) } ?? "?") вЂў UART=\(item.uartCompatible) вЂў \(advertisementSummary)"
            )
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        guard peripheral == self.peripheral else { return }

        connectTimeout?.cancel()
        connectTimeout = nil
        UserDefaults.standard.set(
            peripheral.identifier.uuidString,
            forKey: Self.lastPeripheralKey
        )

        state = .discovering
        log("CONNECTED вЂў id=\(peripheral.identifier.uuidString) вЂў state=\(peripheral.state.rawValue)")
        peripheral.delegate = self

        let requestedServices: [CBUUID]? =
            reliableTestMode ? nil : [Self.uartService]

        peripheral.discoverServices(requestedServices)

        log(
            "GATT discoverServices requested вЂў UUID=\(reliableTestMode ? "ALL" : Self.uartService.uuidString) вЂў reliable=\(reliableTestMode)"
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral == self.peripheral else { return }
        connectTimeout?.cancel()
        connectTimeout = nil
        log("CONNECT failed вЂў \(error.map { errorDescription($0) } ?? "no CoreBluetooth error")")
        handleDisconnect(error: error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral == self.peripheral else { return }
        handleDisconnect(error: error)
    }
}

extension StandardBluetoothController: CBPeripheralDelegate {
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard peripheral == self.peripheral else { return }

        if profileCollectionActive {
            if let error {
                profileCollectionActive = false
                passportTimeoutWork?.cancel()
                blePassportStatus = "РћС€РёР±РєР° РѕР±РЅР°СЂСѓР¶РµРЅРёСЏ СЃР»СѓР¶Р±"
                log("BLE PASSPORT service discovery error вЂў \(errorDescription(error))")
                return
            }

            let services = peripheral.services ?? []
            profileServiceCount = services.count
            pendingProfileServices = services.count
            blePassportStatus = "РќР°Р№РґРµРЅРѕ СЃР»СѓР¶Р±: \(services.count)"
            log("BLE PASSPORT services вЂў count=\(services.count)")

            for service in services {
                log(
                    "GATT SERVICE вЂў UUID=\(service.uuid.uuidString) вЂў name=\(gattName(service.uuid)) вЂў primary=\(service.isPrimary)"
                )
                peripheral.discoverIncludedServices(nil, for: service)
                peripheral.discoverCharacteristics(nil, for: service)
                log(
                    "GATT characteristic discovery requested вЂў service=\(service.uuid.uuidString) вЂў UUID=ALL"
                )
            }

            finishBLEPassportIfPossible()
            return
        }

        guard state == .discovering else {
            log("GATT service discovery callback ignored вЂў state=\(state.label)")
            return
        }

        if let error {
            if reliableTestMode {
                state = .diagnostic
                handshakeSummary =
                    "GATT РЅРµРґРѕСЃС‚СѓРїРµРЅ вЂў СЃРѕРµРґРёРЅРµРЅРёРµ СЃРѕС…СЂР°РЅРµРЅРѕ РґР»СЏ РґРёР°РіРЅРѕСЃС‚РёРєРё"
                blePassportStatus = "РћС€РёР±РєР° РѕР±РЅР°СЂСѓР¶РµРЅРёСЏ СЃР»СѓР¶Р±"
                log(
                    "GATT service discovery error вЂў reliable mode kept BLE link open вЂў \(errorDescription(error))"
                )
                peripheral.readRSSI()
                scheduleRSSISampling()
            } else {
                fail("GATT service discovery error вЂў \(errorDescription(error))")
            }
            return
        }

        let services = peripheral.services ?? []
        log(
            "GATT services discovered вЂў count=\(services.count) вЂў UUIDs=[\(services.map { $0.uuid.uuidString }.joined(separator: ","))]"
        )

        guard let service =
            services.first(where: { $0.uuid == Self.uartService }) else {
            if reliableTestMode {
                state = .diagnostic
                handshakeSummary =
                    "Nordic UART РЅРµ РЅР°Р№РґРµРЅ вЂў РґРѕСЃС‚СѓРїРЅР° РїР°СЃСЃРёРІРЅР°СЏ РґРёР°РіРЅРѕСЃС‚РёРєР°"
                log(
                    "Nordic UART service not found вЂў reliable mode kept BLE link open вЂў commands blocked"
                )
                peripheral.readRSSI()
                scheduleRSSISampling()
                scheduleBLEPassport()
            } else {
                fail("Nordic UART service not found")
            }
            return
        }

        let requestedCharacteristics: [CBUUID]? =
            reliableTestMode ? nil : [Self.uartWrite, Self.uartNotify]

        peripheral.discoverCharacteristics(
            requestedCharacteristics,
            for: service
        )

        log(
            "GATT characteristic discovery requested вЂў UUID=\(reliableTestMode ? "ALL" : "\(Self.uartWrite.uuidString),\(Self.uartNotify.uuidString)")"
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard peripheral == self.peripheral else { return }

        if profileCollectionActive {
            pendingProfileServices = max(
                0,
                pendingProfileServices - 1
            )

            if let error {
                log(
                    "BLE PASSPORT characteristic discovery error вЂў service=\(service.uuid.uuidString) вЂў \(errorDescription(error))"
                )
                finishBLEPassportIfPossible()
                return
            }

            let characteristics = service.characteristics ?? []
            profileCharacteristicCount += characteristics.count
            pendingProfileDescriptors += characteristics.count

            blePassportStatus =
                "GATT: \(profileServiceCount) СЃР»СѓР¶Р±, \(profileCharacteristicCount) С…Р°СЂР°РєС‚РµСЂРёСЃС‚РёРє"

            for characteristic in characteristics {
                let uuid = characteristic.uuid.uuidString

                log(
                    "GATT CHARACTERISTIC вЂў service=\(service.uuid.uuidString) вЂў UUID=\(uuid) вЂў name=\(gattName(characteristic.uuid)) вЂў properties=[\(propertyNames(characteristic.properties))]"
                )

                peripheral.discoverDescriptors(
                    for: characteristic
                )

                if characteristic.properties.contains(.read) {
                    pendingCharacteristicReads.insert(
                        ObjectIdentifier(characteristic)
                    )
                    peripheral.readValue(
                        for: characteristic
                    )
                    log(
                        "GATT READ requested вЂў service=\(service.uuid.uuidString) вЂў UUID=\(uuid) вЂў name=\(gattName(characteristic.uuid))"
                    )
                }
            }

            if service.uuid == Self.uartService {
                if let write =
                    characteristics.first(where: {
                        $0.uuid == Self.uartWrite &&
                        $0.properties.contains(.write)
                    }) {
                    writeCharacteristic = write
                }

                if let notify =
                    characteristics.first(where: {
                        $0.uuid == Self.uartNotify
                    }) {
                    notifyCharacteristic = notify

                    if !notify.isNotifying {
                        peripheral.setNotifyValue(
                            true,
                            for: notify
                        )
                        log(
                            "NOTIFY restore requested during BLE PASSPORT вЂў UUID=\(notify.uuid.uuidString)"
                        )
                    }
                }
            }

            finishBLEPassportIfPossible()
            return
        }

        guard state == .discovering else {
            log(
                "GATT characteristic discovery callback ignored вЂў state=\(state.label)"
            )
            return
        }

        if let error {
            fail(
                "UART characteristic discovery error вЂў \(errorDescription(error))"
            )
            return
        }

        let characteristics =
            service.characteristics ?? []

        for characteristic in characteristics {
            log(
                "GATT characteristic вЂў UUID=\(characteristic.uuid.uuidString) вЂў properties=[\(propertyNames(characteristic.properties))]"
            )
        }

        writeCharacteristic =
            characteristics.first(where: {
                $0.uuid == Self.uartWrite &&
                $0.properties.contains(.write)
            })

        notifyCharacteristic =
            characteristics.first(where: {
                $0.uuid == Self.uartNotify &&
                ($0.properties.contains(.notify) ||
                 $0.properties.contains(.indicate))
            })

        guard let writeCharacteristic,
              let notifyCharacteristic else {
            if reliableTestMode {
                state = .diagnostic
                handshakeSummary =
                    "UART-РєР°РЅР°Р» РЅРµРїРѕР»РЅС‹Р№ вЂў РґРѕСЃС‚СѓРїРЅР° РїР°СЃСЃРёРІРЅР°СЏ РґРёР°РіРЅРѕСЃС‚РёРєР°"
                log(
                    "Declared Nordic UART write/notify characteristics not found вЂў reliable mode kept BLE link open вЂў credential transmission blocked"
                )
                peripheral.readRSSI()
                scheduleRSSISampling()
                scheduleBLEPassport()
            } else {
                fail(
                    "UART write/notify characteristics not found"
                )
            }
            return
        }

        let maxWithout =
            peripheral.maximumWriteValueLength(
                for: .withoutResponse
            )

        let maxWith =
            peripheral.maximumWriteValueLength(
                for: .withResponse
            )

        log(
            "UART resolved вЂў writeProps=[\(propertyNames(writeCharacteristic.properties))] вЂў notifyProps=[\(propertyNames(notifyCharacteristic.properties))] вЂў maxWriteWithout=\(maxWithout) вЂў maxWriteWith=\(maxWith)"
        )

        notificationChannelActive = false
        state = .subscribing
        notifySetupAttempts = 1

        peripheral.setNotifyValue(
            true,
            for: notifyCharacteristic
        )

        log(
            "NOTIFY enable requested вЂў UUID=\(notifyCharacteristic.uuid.uuidString) вЂў no application frames may be sent before delegate confirmation"
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverIncludedServicesFor service: CBService,
        error: Error?
    ) {
        guard peripheral == self.peripheral else { return }
        if let error {
            log(
                "GATT included-service discovery error вЂў service=\(service.uuid.uuidString) вЂў \(errorDescription(error))"
            )
            return
        }

        let included = service.includedServices ?? []

        log(
            "GATT INCLUDED SERVICES вЂў parent=\(service.uuid.uuidString) вЂў count=\(included.count) вЂў UUIDs=[\(included.map { $0.uuid.uuidString }.joined(separator: ","))]"
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverDescriptorsFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral == self.peripheral else { return }
        if profileCollectionActive {
            pendingProfileDescriptors =
                max(0, pendingProfileDescriptors - 1)
        }

        if let error {
            log(
                "GATT descriptor discovery error вЂў characteristic=\(characteristic.uuid.uuidString) вЂў \(errorDescription(error))"
            )
            finishBLEPassportIfPossible()
            return
        }

        let descriptors =
            characteristic.descriptors ?? []

        if profileCollectionActive {
            profileDescriptorCount += descriptors.count
        }

        log(
            "GATT DESCRIPTORS вЂў characteristic=\(characteristic.uuid.uuidString) вЂў count=\(descriptors.count) вЂў UUIDs=[\(descriptors.map { $0.uuid.uuidString }.joined(separator: ","))]"
        )

        for descriptor in descriptors {
            pendingDescriptorReads.insert(
                ObjectIdentifier(descriptor)
            )
            peripheral.readValue(
                for: descriptor
            )
            log(
                "GATT DESCRIPTOR READ requested вЂў UUID=\(descriptor.uuid.uuidString) вЂў name=\(gattName(descriptor.uuid))"
            )
        }

        finishBLEPassportIfPossible()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral == self.peripheral,
              characteristic === notifyCharacteristic,
              characteristic.uuid == Self.uartNotify else {
            log(
                "NOTIFY state ignored вЂў unexpected UUID=\(characteristic.uuid.uuidString)"
            )
            return
        }

        if let error {
            notificationChannelActive = false
            communicationKey = 0x7B
            inboundSessionByte = 0x7B
            connectionGeneration &+= 1
            writeQueue.removeAll()
            activeWrite = nil
            waitingForWriteResponse = false

            if spamRunning {
                stopSpam()
            }

            notifyRetryWork?.cancel()
            notifyRetryWork = nil

            if reliableTestMode,
               notifySetupAttempts < 3,
               peripheral.state == .connected {
                state = .subscribing
                notifySetupAttempts += 1

                log(
                    "NOTIFY state error вЂў retry=\(notifySetupAttempts)/3 вЂў delay=700ms вЂў \(errorDescription(error))"
                )

                let generation =
                    connectionGeneration

                let retry = DispatchWorkItem {
                    [weak self, weak peripheral, weak characteristic] in

                    guard let self,
                          let peripheral,
                          let characteristic,
                          self.peripheral == peripheral,
                          self.connectionGeneration == generation,
                          self.state == .subscribing,
                          peripheral.state == .connected else {
                        return
                    }

                    peripheral.setNotifyValue(
                        true,
                        for: characteristic
                    )

                    self.log(
                        "NOTIFY retry requested вЂў attempt=\(self.notifySetupAttempts)/3 вЂў UUID=\(characteristic.uuid.uuidString)"
                    )
                }

                notifyRetryWork = retry
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 0.7,
                    execute: retry
                )
            } else if reliableTestMode {
                state = .diagnostic
                handshakeSummary =
                    "РЈРІРµРґРѕРјР»РµРЅРёСЏ UART РЅРµРґРѕСЃС‚СѓРїРЅС‹ вЂў РїР°СЃСЃРёРІРЅР°СЏ РґРёР°РіРЅРѕСЃС‚РёРєР°"

                log(
                    "NOTIFY state error вЂў retries exhausted вЂў reliable mode kept BLE link open вЂў commands blocked вЂў \(errorDescription(error))"
                )

                scheduleBLEPassport()
            } else {
                fail(
                    "NOTIFY state error вЂў \(errorDescription(error))"
                )
            }
            return
        }

        notifyRetryWork?.cancel()
        notifyRetryWork = nil

        log(
            "NOTIFY state вЂў UUID=\(characteristic.uuid.uuidString) вЂў isNotifying=\(characteristic.isNotifying)"
        )

        guard characteristic.isNotifying else {
            notificationChannelActive = false
            communicationKey = 0x7B
            inboundSessionByte = 0x7B
            connectionGeneration &+= 1
            writeQueue.removeAll()
            activeWrite = nil
            waitingForWriteResponse = false

            if spamRunning {
                stopSpam()
            }

            guard peripheral.state == .connected else {
                return
            }

            guard notifySetupAttempts < 3 else {
                state = .diagnostic
                handshakeSummary =
                    "РЈРІРµРґРѕРјР»РµРЅРёСЏ UART РѕС‚РєР»СЋС‡РµРЅС‹ вЂў РїР°СЃСЃРёРІРЅР°СЏ РґРёР°РіРЅРѕСЃС‚РёРєР°"

                log(
                    "[STATUS] BLE Notification Channel Inactive вЂў retries exhausted вЂў commands blocked"
                )

                scheduleBLEPassport()
                return
            }

            state = .subscribing
            notifySetupAttempts += 1

            peripheral.setNotifyValue(
                true,
                for: characteristic
            )

            log(
                "[STATUS] BLE Notification Channel Inactive вЂў command controls blocked вЂў re-enable requested"
            )
            return
        }

        notificationChannelActive = true
        log("[STATUS] BLE Notification Channel Active")
        beginHandshake()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral == self.peripheral else {
            return
        }

        let wasPassportRead =
            pendingCharacteristicReads.remove(
                ObjectIdentifier(characteristic)
            ) != nil

        if let error {
            let operation =
                wasPassportRead ? "GATT READ" : "RX notification"

            log(
                "\(operation) error вЂў UUID=\(characteristic.uuid.uuidString) вЂў name=\(gattName(characteristic.uuid)) вЂў \(errorDescription(error))"
            )

            finishBLEPassportIfPossible()
            return
        }

        guard let value = characteristic.value else {
            if characteristic === notifyCharacteristic,
               !wasPassportRead {
                log(
                    "[RX] Notification received вЂў bytes= вЂў ignored"
                )
            } else {
                log(
                    "GATT VALUE contained nil вЂў UUID=\(characteristic.uuid.uuidString)"
                )
            }

            finishBLEPassportIfPossible()
            return
        }

        guard characteristic === notifyCharacteristic,
              !wasPassportRead else {
            let serviceUUID =
                characteristic.service?.uuid.uuidString ?? ""

            let operation =
                wasPassportRead ? "GATT READ RESULT" : "GATT VALUE"

            log(
                "\(operation) вЂў service=\(serviceUUID) вЂў UUID=\(characteristic.uuid.uuidString) вЂў name=\(gattName(characteristic.uuid)) вЂў \(valueSummary(value))"
            )

            captureIoTCodeCandidate(
                from: value,
                source: "GATT \(characteristic.uuid.uuidString)"
            )

            finishBLEPassportIfPossible()
            return
        }

        guard notificationChannelActive,
              characteristic.isNotifying else {
            log(
                "[RX] Notification ignored вЂў channel is not active for the current session"
            )
            finishBLEPassportIfPossible()
            return
        }

        log(
            "[RX] Notification received вЂў bytes=\(SegwayProtocol.hex(value))"
        )

        handle(value)
        finishBLEPassportIfPossible()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor descriptor: CBDescriptor,
        error: Error?
    ) {
        guard peripheral == self.peripheral else { return }
        _ = pendingDescriptorReads.remove(
            ObjectIdentifier(descriptor)
        )

        if let error {
            log(
                "GATT DESCRIPTOR READ error вЂў UUID=\(descriptor.uuid.uuidString) вЂў \(errorDescription(error))"
            )
        } else {
            log(
                "GATT DESCRIPTOR VALUE вЂў UUID=\(descriptor.uuid.uuidString) вЂў name=\(gattName(descriptor.uuid)) вЂў \(descriptorValueSummary(descriptor.value))"
            )

            if let data = descriptor.value as? Data {
                captureIoTCodeCandidate(
                    from: data,
                    source: "descriptor \(descriptor.uuid.uuidString)"
                )
            }
        }

        finishBLEPassportIfPossible()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral == self.peripheral,
              characteristic === writeCharacteristic else {
            log(
                "TX write callback ignored вЂў unexpected UUID=\(characteristic.uuid.uuidString)"
            )
            return
        }

        let completed = activeWrite
        activeWrite = nil
        waitingForWriteResponse = false

        guard completed?.generation == connectionGeneration else {
            log(
                "TX write callback ignored вЂў stale connection generation"
            )
            flushWrites()
            return
        }

        if let error {
            log(
                "[TX] GATT writeValue callback вЂў result=FAIL вЂў context=\(completed?.context ?? "unknown") вЂў \(errorDescription(error))"
            )
        } else {
            log(
                "[TX] GATT writeValue callback вЂў result=OK вЂў context=\(completed?.context ?? "unknown")"
            )
        }

        flushWrites()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {}

    func peripheral(
        _ peripheral: CBPeripheral,
        didReadRSSI RSSI: NSNumber,
        error: Error?
    ) {
        guard peripheral == self.peripheral else { return }
        if let error {
            log(
                "RSSI read failed вЂў \(errorDescription(error))"
            )
        } else {
            rssiSamples.append(RSSI.intValue)

            if rssiSamples.count > 32 {
                rssiSamples.removeFirst(
                    rssiSamples.count - 32
                )
            }

            log(
                "RSSI read вЂў value=\(RSSI.intValue)dBm вЂў \(rssiSummary)"
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didModifyServices invalidatedServices: [CBService]
    ) {
        guard peripheral == self.peripheral else { return }
        log(
            "GATT services invalidated вЂў UUIDs=[\(invalidatedServices.map { $0.uuid.uuidString }.joined(separator: ","))]"
        )

        guard peripheral.state == .connected else { return }
        state = .discovering
        clearSession(keepPeripheral: true)
        peripheral.discoverServices(reliableTestMode ? nil : [Self.uartService])
    }
}


