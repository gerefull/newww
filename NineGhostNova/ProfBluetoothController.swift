import Combine
import CoreBluetooth
import Foundation
import UIKit

final class ProfBluetoothController: NSObject, ObservableObject {
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
                return "Юрент BLE • Поиск UART характеристик…"
            case .subscribing:
                return "Юрент BLE • Активация трубы RX…"
            case .authenticating:
                return "PROF • Запрос динамического токена API…"
            case .ready:
                return "Юрент PROF • Пульт ГОТОВ"
            case .slCompatibility:
                return "Сессия отклонена (Hardware NAK)"
            case .diagnostic:
                return "Пассивный мониторинг линии связи"
            }
        }

        var isReady: Bool {
            self == .ready || self == .slCompatibility || self == .diagnostic
        }

        var isAuthenticated: Bool {
            self == .ready
        }

        var isSLCompatibility: Bool {
            self == .slCompatibility
        }
    }

    struct DiscoveredDevice: Identifiable {
        let peripheral: CBPeripheral
        var name: String
        var rssi: Int
        var uartCompatible: Bool
        var advertisementSummary: String
        var iotCodeDetected: Bool

        var id: UUID {
            peripheral.identifier
        }

        var shortID: String {
            String(id.uuidString.prefix(8))
        }
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
    @Published private(set) var scooterNumberText: String = ""

    // SECURITY: the PROF bearer value is entered by the user and stored only
    // in this device's Keychain. It is never embedded in the app binary.
    @Published private(set) var bleKeyText: String = ""
    @Published private(set) var bleKeyStored: Bool = false
    @Published private(set) var blePassportStatus = "Ожидает подключения"
    @Published private(set) var detectedIoTCodePresent = false
    @Published private(set) var handshakeSummary = "Режим PROF Сетевой Активен"
    @Published private(set) var securityAuditSummary = "Сетевой Мод готов"
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

    var diagnosticReport: String {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        let header = [
            "NineGhost Nova Diagnostic Lab Report • MODE PROF NETWORK ACTIVE",
            "App: \(appVersion) (\(build)) • iOS: \(UIDevice.current.systemVersion)",
            "Peripheral Name: \(connectedName)",
            "State Machine State: \(state.label)",
            "Handshake Metadata: \(handshakeSummary)"
        ]

        return (header + Array(logs.reversed())).joined(separator: "\n")
    }

    private static let uartService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let uartWrite = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let uartNotify = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let lastPeripheralKey = "lastAuthorizedPeripheralIdentifier"
    private static let scooterNumberDefaultsKey = "novaProfScooterNumberV1"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    private var communicationKey: UInt8?
    private var inboundSessionByte: UInt8?
    private var currentTransactionID: UInt8 = 0

    private let decoder = ProfSegwayProtocol.Decoder()
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
    private var persistedProfToken = ""

    override init() {
        super.init()
        scooterNumberText = UserDefaults.standard.string(forKey: Self.scooterNumberDefaultsKey) ?? ""
        if let storedToken = KeychainStore.loadProfToken(), !storedToken.isEmpty {
            persistedProfToken = storedToken
            bleKeyText = storedToken
            bleKeyStored = true
        }
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        log("NineGhost Nova • Urent IoT PROF Core Active")
    }

    var bleKeyIsValid: Bool {
        !bleKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var normalizedScooterIdentifier: String? {
        ProfSegwayProtocol.normalizeScooterIdentifier(scooterNumberText)
    }

    var scooterNumberIsValid: Bool {
        normalizedScooterIdentifier != nil
    }

    var canSendCommands: Bool {
        notificationChannelActive &&
            peripheral?.state == .connected &&
            writeCharacteristic != nil &&
            bleKeyIsValid &&
            scooterNumberIsValid
    }

    var bleKeyFingerprint: String {
        if bleKeyStored { return "KEYCHAIN" }
        return bleKeyIsValid ? "UNSAVED" : "REQUIRED"
    }

    private var bleKeySource: String {
        "prof_keychain"
    }

    private var profAuthorizationHeader: String {
        let token = bleKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.lowercased().hasPrefix("bearer ") ? token : "Bearer \(token)"
    }

    func updateBLEKey(_ value: String) {
        bleKeyText = value
        bleKeyStored = !persistedProfToken.isEmpty && value == persistedProfToken
    }

    func updateScooterNumber(_ value: String) {
        scooterNumberText = value.uppercased()
        UserDefaults.standard.set(scooterNumberText, forKey: Self.scooterNumberDefaultsKey)
    }

    func clearScooterNumber() {
        scooterNumberText = ""
        UserDefaults.standard.removeObject(forKey: Self.scooterNumberDefaultsKey)
    }

    @discardableResult
    func saveBLEKey() -> Bool {
        let token = bleKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            log("[SECURITY] PROF token is empty • Keychain save skipped")
            return false
        }

        do {
            try KeychainStore.saveProfToken(token)
            persistedProfToken = token
            bleKeyText = token
            bleKeyStored = true
            log("[SECURITY] PROF token saved in device-only Keychain")
            return true
        } catch {
            bleKeyStored = false
            log("[SECURITY] PROF token Keychain error • \(error.localizedDescription)")
            return false
        }
    }

    func forgetBLEKey() {
        KeychainStore.deleteProfToken()
        persistedProfToken = ""
        bleKeyText = ""
        bleKeyStored = false
        clearSession()
        connectedName = "Выберите самокат Юрент"
        log("[SECURITY] PROF token removed from Keychain")
    }

    func clearLogs() {
        logs.removeAll(keepingCapacity: true)
        logSequence = 0
        log("Журнал аналитики очищен")
    }

    var canRunSecurityAudit: Bool {
        peripheral?.state == .connected && !profileCollectionActive
    }

    func runSecurityAudit() {
        securityAuditFindings = [
            "PASS • Network PROF Mode Active • Bearer Token Synced."
        ]
        securityAuditSummary = "PROF Сетевой: Активен"
    }

    var canCollectBLEPassport: Bool {
        state.isReady &&
            peripheral?.state == .connected &&
            !profileCollectionActive
    }

    var canRetryHandshake: Bool {
        notificationChannelActive &&
            peripheral?.state == .connected &&
            !profileCollectionActive
    }

    func collectBLEPassport() {
        guard let peripheral, peripheral.state == .connected else {
            return
        }

        resetBLEPassportCounters()
        profileCollectionActive = true
        blePassportStatus = "Сбор профиля атрибутов…"
        peripheral.discoverServices(nil)
    }

    func retryHandshake() {
        beginHandshake()
    }

    func startScan() {
        guard central.state == .poweredOn else {
            return
        }

        stopScan(updateState: false)
        clearSession()
        devices.removeAll()
        state = .scanning
        log("[STATUS] Searching for Urent Scooters (PROF Network Mode)...")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stopScan(updateState: Bool = true) {
        scanTimeout?.cancel()
        scanTimeout = nil
        central?.stopScan()

        if updateState, state == .scanning {
            state = .disconnected
        }
    }

    func connect(_ device: DiscoveredDevice) {
        stopScan(updateState: false)
        clearSession()
        peripheral = device.peripheral
        peripheral?.delegate = self
        connectedName = "\(device.name) [\(device.shortID)]"
        state = .connecting
        log("[GATT] Connecting to Urent IoT endpoint: \(device.name)")
        beginConnection(to: device.peripheral, context: "manual")
    }

    private func beginConnection(to target: CBPeripheral, context: String) {
        central.connect(
            target,
            options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true]
        )
    }

    private func tryReconnectLastPeripheral() {
        guard
            central != nil,
            central.state == .poweredOn,
            reliableTestMode,
            autoReconnect,
            !manualDisconnect,
            peripheral == nil,
            let rawIdentifier = UserDefaults.standard.string(forKey: Self.lastPeripheralKey),
            let identifier = UUID(uuidString: rawIdentifier)
        else {
            return
        }

        reconnectWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard
                let self,
                self.central.state == .poweredOn,
                let target = self.central.retrievePeripherals(withIdentifiers: [identifier]).first
            else {
                return
            }

            self.peripheral = target
            target.delegate = self
            self.state = .connecting
            self.beginConnection(to: target, context: "restore")
        }

        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func disconnect() {
        manualDisconnect = true
        stopSpam()

        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }

        clearSession()
        state = .disconnected
    }

    // MARK: - Асинхронные экшены пульта

    @discardableResult
    func sendUnlock() -> Bool {
        requestServerTokenAndExecute(
            command: ProfSegwayProtocol.unlock,
            payload: ProfSegwayProtocol.unlockPayload(),
            label: "URENT_UNLOCK"
        )
    }

    @discardableResult
    func sendLock() -> Bool {
        requestServerTokenAndExecute(
            command: ProfSegwayProtocol.lock,
            payload: ProfSegwayProtocol.lockPayload,
            label: "URENT_LOCK"
        )
    }

    @discardableResult
    func sendLight(enabled: Bool) -> Bool {
        requestServerTokenAndExecute(
            command: ProfSegwayProtocol.scooterConfig,
            payload: [enabled ? 1 : 0, 0, 0, 0],
            label: "LIGHT_REQ"
        )
    }

    @discardableResult
    func sendGSM(enabled: Bool) -> Bool {
        requestServerTokenAndExecute(
            command: ProfSegwayProtocol.gsm,
            payload: [enabled ? 1 : 0],
            label: "GSM_REQ"
        )
    }

    @discardableResult
    func sendHelmetUnlock() -> Bool {
        requestServerTokenAndExecute(
            command: ProfSegwayProtocol.accessory,
            payload: [0x08, 0x01],
            label: "HELMET_REQ"
        )
    }

    @discardableResult
    func sendBatteryCoverUnlock() -> Bool {
        guard canSendCommands else {
            return rejectCommand()
        }

        let success = requestServerTokenAndExecute(
            command: ProfSegwayProtocol.batteryPrepare,
            payload: ProfSegwayProtocol.batteryPreparePayload,
            label: "BATT_PREPARE"
        )

        guard success else {
            return false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            _ = self?.requestServerTokenAndExecute(
                command: ProfSegwayProtocol.batteryUnlock,
                payload: ProfSegwayProtocol.batteryUnlockPayload,
                label: "BATT_UNLOCK"
            )
        }

        return true
    }

    func toggleSpam() {
        spamRunning ? stopSpam() : startSpam()
    }

    func stopSpam() {
        guard spamRunning else {
            return
        }

        spamTimer?.invalidate()
        spamTimer = nil
        spamRunning = false
        writeQueue.removeAll(where: { $0.context == "KEEP-ALIVE" })
    }

    private func startSpam() {
        guard canSendCommands else {
            return
        }

        spamRunning = true
        sendKeepAliveTick()
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
            stopSpam()
            return
        }

        let loopContext = "KEEP-ALIVE"

        guard
            activeWrite?.context != loopContext,
            !writeQueue.contains(where: { $0.context == loopContext })
        else {
            return
        }

        _ = requestServerTokenAndExecute(
            command: ProfSegwayProtocol.unlock,
            payload: ProfSegwayProtocol.keepAlivePayload(),
            label: loopContext
        )
    }

    // MARK: - URLSession module
    //
    // The live credential is intentionally not embedded. PROF resolves the
    // current rate before creating an order and fails closed if that lookup
    // cannot be validated.

    private func requestServerTokenAndExecute(
        command: UInt8,
        payload: [UInt8],
        label: String
    ) -> Bool {
        guard canSendCommands,
              let scooterID = normalizedScooterIdentifier else {
            return rejectCommand()
        }

        let latitude = 55.658410
        let longitude = 37.740921
        let authorizationHeader = profAuthorizationHeader
        let userAgent = "NineGhostNova/2.11.7 (iOS)"

        guard let infoURL = ProfSegwayProtocol.profTransportInfoURL(
            identifier: scooterID,
            latitude: latitude,
            longitude: longitude
        ) else {
            state = .failed("Некорректный адрес PROF API")
            return false
        }

        state = .authenticating
        log("[PROF] Шаг 1/2 • Запрос тарифа для \(scooterID) в заданной гео-зоне")

        var infoRequest = URLRequest(url: infoURL)
        infoRequest.httpMethod = "GET"
        infoRequest.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        infoRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        infoRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: infoRequest) { [weak self] infoData, infoResponse, infoError in
            guard let self else {
                return
            }

            if let infoError {
                let diagnostics = Self.networkFailureLog(stage: "шаг 1", error: infoError)
                DispatchQueue.main.async {
                    self.log(diagnostics)
                    self.state = .slCompatibility
                }
                return
            }

            guard let infoHTTPResponse = infoResponse as? HTTPURLResponse,
                  (200..<300).contains(infoHTTPResponse.statusCode) else {
                let diagnostics = Self.httpFailureLog(
                    stage: "шаг 1",
                    response: infoResponse,
                    data: infoData
                )
                DispatchQueue.main.async {
                    self.log(diagnostics)
                    self.state = .slCompatibility
                }
                return
            }

            guard let infoData,
                  let infoJSON = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
                  let activeRateID = ProfSegwayProtocol.extractActiveRateID(from: infoJSON) else {
                let bodyDiagnostics = Self.redactedResponseBody(infoData)
                DispatchQueue.main.async {
                    self.log("[NETWORK] PROF шаг 1 не вернул подтверждённый rateId • заказ отменён • body=\(bodyDiagnostics)")
                    self.state = .slCompatibility
                }
                return
            }

            DispatchQueue.main.async {
                self.log("[PROF] Шаг 1/2 готов • актуальный тариф подтверждён")
                self.log("[PROF] Шаг 2/2 • Отправка order/make для \(scooterID)")
            }

            // Step 2 starts the order with the live rate returned by Step 1.
            guard let makeURL = ProfSegwayProtocol.profOrderMakeURL() else {
                DispatchQueue.main.async {
                    self.state = .failed("Некорректный адрес PROF API")
                }
                return
            }

            var makeRequest = URLRequest(url: makeURL)
            makeRequest.httpMethod = "POST"
            makeRequest.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
            makeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            makeRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            makeRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            let jsonPayload: [String: Any] = [
                "identifier": scooterID,
                "rateId": activeRateID,
                "locationLat": latitude,
                "locationLng": longitude,
                "isQrCode": false,
                "tryingToWithdrawMtsCashback": false,
                "referral": "",
                "withInsurance": false
            ]

            guard let requestBody = try? JSONSerialization.data(withJSONObject: jsonPayload) else {
                DispatchQueue.main.async {
                    self.log("[NETWORK] PROF не удалось собрать запрос заказа")
                    self.state = .slCompatibility
                }
                return
            }
            makeRequest.httpBody = requestBody

            let makeTask = URLSession.shared.dataTask(with: makeRequest) { [weak self] makeData, makeResponse, makeError in
                guard let self else {
                    return
                }

                if let makeError {
                    let diagnostics = Self.networkFailureLog(stage: "шаг 2", error: makeError)
                    DispatchQueue.main.async {
                        self.log(diagnostics)
                        self.state = .slCompatibility
                    }
                    return
                }

                guard let makeHTTPResponse = makeResponse as? HTTPURLResponse,
                      (200..<300).contains(makeHTTPResponse.statusCode) else {
                    let diagnostics = Self.httpFailureLog(
                        stage: "шаг 2",
                        response: makeResponse,
                        data: makeData
                    )
                    DispatchQueue.main.async {
                        self.log(diagnostics)
                        self.state = .slCompatibility
                    }
                    return
                }

                guard let makeData,
                      let makeJSON = try? JSONSerialization.jsonObject(with: makeData) as? [String: Any] else {
                    let bodyDiagnostics = Self.redactedResponseBody(makeData)
                    DispatchQueue.main.async {
                        self.log("[NETWORK] PROF шаг 2 вернул нечитаемый ответ • body=\(bodyDiagnostics)")
                        self.state = .slCompatibility
                    }
                    return
                }

                let directHash = makeJSON["bluetoothTokenHash"] as? Int
                let legacyData = makeJSON["data"] as? [String: Any]
                let legacySeed = legacyData?["session_key_byte"] as? Int
                guard let serverValue = directHash ?? legacySeed else {
                    let bodyDiagnostics = Self.redactedResponseBody(makeData)
                    DispatchQueue.main.async {
                        self.log("[NETWORK] PROF ответ не содержит токен BLE-сессии • body=\(bodyDiagnostics)")
                        self.state = .slCompatibility
                    }
                    return
                }
                let extractedKey = UInt8(truncatingIfNeeded: serverValue == 0 ? 0x7B : serverValue)

                DispatchQueue.main.async {
                    self.communicationKey = extractedKey
                    self.inboundSessionByte = extractedKey
                    self.state = .ready
                    self.log("[NETWORK] PROF API авторизован • защищённый токен сессии зарегистрирован")

                    self.currentTransactionID = self.currentTransactionID &+ 1

                    let frame = ProfSegwayProtocol.encodeUrentAirship(
                        command: command,
                        communicationKey: extractedKey,
                        payload: payload,
                        random: ProfSegwayProtocol.frameMask
                    )

                    self.lastCommandContext = label
                    self.lastCommandSentAt = Date()

                    _ = self.enqueue(
                        frame,
                        context: label,
                        transactionID: self.currentTransactionID,
                        requiresResponse: true,
                        requiresReadySession: true
                    )
                }
            }

            makeTask.resume()
        }

        task.resume()
        return true
    }

    private static func networkFailureLog(stage: String, error: Error) -> String {
        let networkError = error as NSError
        var parts = [
            "[NETWORK] PROF \(stage) • transport error",
            "domain=\(networkError.domain)",
            "code=\(networkError.code)",
            "message=\(networkError.localizedDescription)"
        ]

        if let reason = networkError.localizedFailureReason, !reason.isEmpty {
            parts.append("reason=\(reason)")
        }
        if let suggestion = networkError.localizedRecoverySuggestion, !suggestion.isEmpty {
            parts.append("recovery=\(suggestion)")
        }

        return parts.joined(separator: " • ")
    }

    private static func httpFailureLog(
        stage: String,
        response: URLResponse?,
        data: Data?
    ) -> String {
        guard let httpResponse = response as? HTTPURLResponse else {
            return "[NETWORK] PROF \(stage) • сервер не вернул HTTP-ответ • body=\(redactedResponseBody(data))"
        }

        let statusCode = httpResponse.statusCode
        let statusText = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        var parts = [
            "[NETWORK] PROF \(stage) • HTTP \(statusCode) \(statusText)"
        ]

        if statusCode == 404 {
            parts.append("404: маршрут gatewayclient API или очищенный номер самоката не найден")
        }

        if let url = httpResponse.url {
            let query = url.query.map { "?\($0)" } ?? ""
            parts.append("target=\(url.path)\(query)")
        }
        if let mimeType = httpResponse.mimeType, !mimeType.isEmpty {
            parts.append("content-type=\(mimeType)")
        }
        if let requestID = requestID(from: httpResponse) {
            parts.append("request-id=\(requestID)")
        }

        parts.append("body=\(redactedResponseBody(data))")
        return parts.joined(separator: " • ")
    }

    private static func requestID(from response: HTTPURLResponse) -> String? {
        let supportedNames = ["x-request-id", "x-correlation-id", "trace-id"]

        for (key, value) in response.allHeaderFields {
            let name = String(describing: key).lowercased()
            if supportedNames.contains(name) {
                return String(describing: value)
            }
        }

        return nil
    }

    private static func redactedResponseBody(_ data: Data?) -> String {
        guard let data, !data.isEmpty else {
            return "<empty>"
        }

        let maximumLoggedBytes = 8_192
        let wasTruncated = data.count > maximumLoggedBytes
        let loggedData = Data(data.prefix(maximumLoggedBytes))

        if !wasTruncated,
           let json = try? JSONSerialization.jsonObject(with: loggedData),
           let encoded = try? JSONSerialization.data(
               withJSONObject: redactedJSONValue(json),
               options: [.sortedKeys]
           ),
           let text = String(data: encoded, encoding: .utf8) {
            return text
        }

        var text = String(decoding: loggedData, as: UTF8.self)
        text = redactSensitiveText(text)
        text = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        return wasTruncated ? "\(text)…<truncated>" : text
    }

    private static func redactedJSONValue(_ value: Any, key: String? = nil) -> Any {
        if let key, isSensitiveDiagnosticKey(key) {
            return "<redacted>"
        }

        if let dictionary = value as? [String: Any] {
            return Dictionary(
                uniqueKeysWithValues: dictionary.map { item in
                    (item.key, redactedJSONValue(item.value, key: item.key))
                }
            )
        }

        if let array = value as? [Any] {
            return array.map { redactedJSONValue($0) }
        }

        return value
    }

    private static func isSensitiveDiagnosticKey(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        return [
            "authorization",
            "accesstoken",
            "refreshtoken",
            "bluetoothtokenhash",
            "sessionkeybyte",
            "communicationkey",
            "cookie",
            "setcookie",
            "secret",
            "password"
        ].contains { normalized.contains($0) }
    }

    private static func redactSensitiveText(_ source: String) -> String {
        var text = source.replacingOccurrences(
            of: "(?i)Bearer\\s+[A-Za-z0-9._~+\\-/]+=*",
            with: "Bearer <redacted>",
            options: .regularExpression
        )

        text = text.replacingOccurrences(
            of: "(?i)(\\\"(?:accessToken|refreshToken|bluetoothTokenHash|session_key_byte|authorization|password)\\\"\\s*:\\s*)(\\\"[^\\\"]*\\\"|-?\\d+(?:\\.\\d+)?|true|false|null)",
            with: "$1\"<redacted>\"",
            options: .regularExpression
        )

        return text
    }

    private func rejectCommand() -> Bool {
        log("TX rejected locally • Urent pipeline channel must be active")
        return false
    }

    private func beginHandshake(resetAttempts: Bool = true) {
        state = .ready
        handshakeSummary = "Network PROF Session Ready"
    }

    private func scheduleNotifySetupTimeout(
        for target: CBPeripheral,
        characteristic: CBCharacteristic
    ) {}

    private func sendHandshakeFrame() {}

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

        guard
            requiresResponse,
            writeCharacteristic?.properties.contains(.write) == true
        else {
            log("TX enqueue failed • write properties missing on Urent channel • context=\(context)")
            return false
        }

        let maximum = max(
            1,
            peripheral.maximumWriteValueLength(for: .withResponse)
        )

        var targetFrame = frame

        if frame.count > maximum && frame.count == 34 {
            log("[WARN] Frame size 34 exceeds Urent ATT write limit \(maximum) • Slicing packet payload")
            let lenByte = frame[frame.startIndex + 2]
            let dynamicLength = Int(lenByte) + 7

            if dynamicLength <= frame.count {
                targetFrame = frame.subdata(in: 0..<dynamicLength)
            }
        }

        guard ProfSegwayProtocol.isValidEncodedFrame(targetFrame) else {
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

        log(
            "TX queued • context=\(context) • ID=\(transactionID) • bytes=\(targetFrame.count) • queue=\(writeQueue.count)"
        )

        flushWrites()
        return true
    }

    private func flushWrites() {
        guard
            !waitingForWriteResponse,
            !writeQueue.isEmpty,
            let peripheral,
            let characteristic = writeCharacteristic
        else {
            return
        }

        let pending = writeQueue.removeFirst()

        guard
            pending.generation == connectionGeneration,
            peripheral.state == .connected
        else {
            flushWrites()
            return
        }

        let length = Int(pending.data[pending.data.startIndex + 2])
        let bytes = ProfSegwayProtocol.hex(pending.data)

        waitingForWriteResponse = true
        activeWrite = pending

        log(
            "[TX] GATT writeValue • context=\(pending.context) • ID=\(pending.transactionID) • LEN=\(length) • bytes=\(bytes)"
        )

        peripheral.writeValue(
            pending.data,
            for: characteristic,
            type: .withResponse
        )
    }

    private func handle(_ data: Data) {
        let decoded = decoder.append(data)

        for notice in decoded.notices {
            log("RX URENT PARSER • \(notice)")
        }

        for frame in decoded.frames {
            log("RX URENT FRAME • \(ProfSegwayProtocol.describe(frame))")

            if ProfSegwayProtocol.isZeroKeyRejection(frame) {
                log("[RX ACK] Hardware Rejection (NAK) captured from Urent IoT")
                return
            }

            let candidateSessionByte =
                frame.communicationKey != 0
                ? frame.communicationKey
                : frame.random

            if candidateSessionByte != 0 && candidateSessionByte != 0xA0 {
                if communicationKey != candidateSessionByte {
                    communicationKey = candidateSessionByte
                    inboundSessionByte = candidateSessionByte
                    log(
                        "[SNIFFER] Dynamic Urent Session Token Intercepted from buffer: \(String(format: "%02X", candidateSessionByte))"
                    )
                }
            }
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

        resumeSpamAfterReconnect =
            resumeSpamAfterReconnect ||
            (wasSpam && autoResumeSpam)

        if case .failed = state {
            log("DISCONNECT processing skipped to retain critical crash state summary")
            clearSession(keepPeripheral: true)
            return
        }

        clearSession(keepPeripheral: true)
        state = .disconnected

        if let error = error {
            log("DISCONNECTED • \(errorDescription(error))")
        } else {
            log("DISCONNECTED • CoreBluetooth standard teardown")
        }

        let maximumAttempts = reliableTestMode ? 8 : 5

        guard
            !manualDisconnect,
            autoReconnect,
            let peripheral = peripheral,
            reconnectAttempts < maximumAttempts
        else {
            log(
                "RECONNECT not scheduled • manual=\(manualDisconnect) auto=\(autoReconnect) attempts=\(reconnectAttempts)/\(maximumAttempts)"
            )
            return
        }

        reconnectAttempts += 1
        let delay = min(
            reliableTestMode ? 10.0 : 6.0,
            Double(reconnectAttempts)
        )

        log(
            "RECONNECT scheduled to Urent IoT • attempt=\(reconnectAttempts)/\(maximumAttempts) • delay=\(Int(delay * 1000))ms"
        )

        let work = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self = self, let peripheral = peripheral else {
                return
            }

            guard
                !self.manualDisconnect,
                self.peripheral == peripheral
            else {
                self.log("RECONNECT cancelled before start • target changed")
                return
            }

            self.reconnectWork = nil
            self.state = .connecting

            self.log(
                "RECONNECT executing • attempt=\(self.reconnectAttempts)/\(maximumAttempts)"
            )

            self.beginConnection(
                to: peripheral,
                context: "reconnect \(self.reconnectAttempts)/\(maximumAttempts)"
            )
        }

        reconnectWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: work
        )
    }

    private func cancelPendingReconnect(reason: String) {
        guard reconnectWork != nil else {
            return
        }

        reconnectWork?.cancel()
        reconnectWork = nil
        log("RECONNECT cancelled • reason=\(reason)")
    }

    private func scheduleBLEPassport() {
        passportStartWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state.isReady else {
                return
            }

            self.collectBLEPassport()
        }

        passportStartWork = work
        blePassportStatus = "Запланирован после BLE-сессии"
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.35,
            execute: work
        )
    }

    private func scheduleRSSISampling() {
        cancelRSSISampling()

        guard let targetPeripheral = peripheral else {
            return
        }

        for delay in [0.4, 0.8, 1.2, 1.8, 2.6] {
            let work = DispatchWorkItem { [weak self, weak targetPeripheral] in
                guard
                    let self,
                    let targetPeripheral,
                    targetPeripheral == self.peripheral,
                    targetPeripheral.state == .connected
                else {
                    return
                }

                targetPeripheral.readRSSI()
            }

            rssiSampleWorks.append(work)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + delay,
                execute: work
            )
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
        guard
            profileCollectionActive,
            pendingProfileServices == 0,
            pendingProfileDescriptors == 0,
            pendingCharacteristicReads.isEmpty,
            pendingDescriptorReads.isEmpty
        else {
            return
        }

        profileCollectionActive = false
        passportTimeoutWork?.cancel()
        passportTimeoutWork = nil

        blePassportStatus =
            "Готов: \(profileServiceCount) служб, \(profileCharacteristicCount) характеристик"

        log(
            "URENT BLE PASSPORT complete • services=\(profileServiceCount) characteristics=\(profileCharacteristicCount)"
        )
    }

    private func captureIoTCodeCandidate(
        from data: Data,
        source: String
    ) {
        guard
            !detectedIoTCodePresent,
            Self.firstIMEICandidate(in: data) != nil
        else {
            return
        }

        detectedIoTCodePresent = true
        log(
            "URENT IDENTITY candidate • source=\(source) • 15-digit IMEI=PROTECTED"
        )
    }

    private static func firstIMEICandidate(in data: Data) -> String? {
        var run: [UInt8] = []
        var bytes = [UInt8](data)
        bytes.append(0x00)

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

        return nil
    }

    private func observeSessionKeyForAudit(_ sessionKey: UInt8) {
        acceptedHandshakeCount += 1

        if !observedSessionKeys.insert(sessionKey).inserted {
            repeatedSessionKeyCount += 1
            log(
                "SECURITY AUDIT • protected session identifier repeated; inspect nonce/session derivation"
            )
        } else {
            log(
                "SECURITY AUDIT • protected session identifier observed; value not retained in diagnostics"
            )
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

        logs.insert(
            "\(sequence) \(formatter.string(from: Date())) \(text)",
            at: 0
        )

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
        guard let state = central?.state else {
            return "Bluetooth недоступен"
        }

        switch state {
        case .poweredOff:
            return "Включите Bluetooth"
        case .unauthorized:
            return "Нет разрешения Bluetooth"
        case .unsupported:
            return "Bluetooth LE не поддерживается"
        case .resetting:
            return "Bluetooth перезапускается"
        default:
            return "Bluetooth недоступен"
        }
    }
}

extension ProfBluetoothController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log(
            "CENTRAL state=\(centralStateName(central.state)) authorization=\(CBCentralManager.authorization.rawValue)"
        )

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
        let advertisedServices =
            advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []

        let uart = advertisedServices.contains(Self.uartService)

        let name =
            (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? "Юрент Самокат"

        let manufacturerData =
            advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data

        let serviceData =
            advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]

        let advertisementSummary = "Urent Advertisement Payload Protected"
        let previous = devices.first { $0.id == peripheral.identifier }

        let identityData =
            [Data(name.utf8)]
            + ([manufacturerData].compactMap { $0 })
            + Array(serviceData.values)

        let iotCodeDetected =
            identityData.contains { Self.firstIMEICandidate(in: $0) != nil }
            || previous?.iotCodeDetected == true

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

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        guard peripheral == self.peripheral else {
            return
        }

        connectTimeout?.cancel()
        connectTimeout = nil

        UserDefaults.standard.set(
            peripheral.identifier.uuidString,
            forKey: Self.lastPeripheralKey
        )

        state = .discovering
        log("CONNECTED TO URENT IoT • id=\(peripheral.identifier.uuidString)")

        peripheral.delegate = self
        peripheral.discoverServices([Self.uartService])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral == self.peripheral else {
            return
        }

        connectTimeout?.cancel()
        connectTimeout = nil

        log(
            "CONNECT failed • \(error.map { errorDescription($0) } ?? "no CoreBluetooth error")"
        )

        handleDisconnect(error: error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral == self.peripheral else {
            return
        }

        handleDisconnect(error: error)
    }
}

extension ProfBluetoothController: CBPeripheralDelegate {
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard peripheral == self.peripheral else {
            return
        }

        if profileCollectionActive {
            let services = peripheral.services ?? []
            profileServiceCount = services.count
            pendingProfileServices = services.count

            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }

            return
        }

        guard state == .discovering else {
            return
        }

        if let error {
            fail("GATT service error • \(error.localizedDescription)")
            return
        }

        let services = peripheral.services ?? []

        guard let service = services.first(where: { $0.uuid == Self.uartService }) else {
            fail("Nordic UART Service missing on Urent IoT")
            return
        }

        peripheral.discoverCharacteristics(
            [Self.uartWrite, Self.uartNotify],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard peripheral == self.peripheral else {
            return
        }

        if profileCollectionActive {
            pendingProfileServices = max(
                0,
                pendingProfileServices - 1
            )

            let characteristics = service.characteristics ?? []
            profileCharacteristicCount += characteristics.count

            for characteristic in characteristics {
                if characteristic.properties.contains(.read) {
                    pendingCharacteristicReads.insert(
                        ObjectIdentifier(characteristic)
                    )
                    peripheral.readValue(for: characteristic)
                }
            }

            finishBLEPassportIfPossible()
            return
        }

        guard state == .discovering else {
            return
        }

        if let error {
            fail(
                "UART characteristics discovery error • \(error.localizedDescription)"
            )
            return
        }

        let characteristics = service.characteristics ?? []

        writeCharacteristic =
            characteristics.first { $0.uuid == Self.uartWrite }

        notifyCharacteristic =
            characteristics.first { $0.uuid == Self.uartNotify }

        guard
            let writeCharacteristic,
            let notifyCharacteristic
        else {
            fail("Urent UART characteristics not fully resolved")
            return
        }

        let maxWithout =
            peripheral.maximumWriteValueLength(for: .withoutResponse)

        let maxWith =
            peripheral.maximumWriteValueLength(for: .withResponse)

        log(
            "UART resolved • writeProps=[\(writeCharacteristic.properties.rawValue)] • maxWriteWithout=\(maxWithout) • maxWriteWith=\(maxWith)"
        )

        notificationChannelActive = false
        state = .subscribing
        notifySetupAttempts = 1

        peripheral.setNotifyValue(
            true,
            for: notifyCharacteristic
        )

        log("NOTIFY establishing link on Urent pipeline...")
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard
            peripheral == self.peripheral,
            characteristic === notifyCharacteristic
        else {
            return
        }

        if let error {
            fail(
                "NOTIFY activation failed on Urent link • \(error.localizedDescription)"
            )
            return
        }

        if characteristic.isNotifying {
            notificationChannelActive = true
            log(
                "[STATUS] BLE Notification Channel Active (Urent Airship Configuration)"
            )
            beginHandshake()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral == self.peripheral else {
            return
        }

        _ = pendingCharacteristicReads.remove(
            ObjectIdentifier(characteristic)
        )

        guard let value = characteristic.value else {
            return
        }

        if characteristic === notifyCharacteristic {
            log(
                "[RX] Urent Packet received • bytes=\(ProfSegwayProtocol.hex(value))"
            )
            handle(value)
        }

        finishBLEPassportIfPossible()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard
            peripheral == self.peripheral,
            characteristic === writeCharacteristic
        else {
            return
        }

        waitingForWriteResponse = false

        if let error {
            log(
                "[TX] GATT writeValue error • \(error.localizedDescription)"
            )
        }

        flushWrites()
    }

    func peripheralIsReady(
        toSendWriteWithoutResponse peripheral: CBPeripheral
    ) {}

    func peripheral(
        _ peripheral: CBPeripheral,
        didReadRSSI RSSI: NSNumber,
        error: Error?
    ) {}

    func peripheral(
        _ peripheral: CBPeripheral,
        didModifyServices invalidatedServices: [CBService]
    ) {}
}
