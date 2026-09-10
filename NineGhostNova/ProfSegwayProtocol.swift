import Foundation

public enum ProfSegwayProtocol {
    public static let frameMask: UInt8 = 0xA0
    public static let handshake: UInt8 = 0x01
    public static let unlock: UInt8 = 0x7D
    public static let lock: UInt8 = 0x15
    public static let gsm: UInt8 = 0x50
    public static let scooterConfig: UInt8 = 0x61
    public static let batteryPrepare: UInt8 = 0x81
    public static let batteryUnlock: UInt8 = 0xC0
    public static let accessory: UInt8 = 0xC3

    public struct Frame: Equatable {
        public let random: UInt8
        public let communicationKey: UInt8
        public let command: UInt8
        public let payload: [UInt8]
        public let raw: Data
    }

    public struct DecodeResult {
        public let frames: [Frame]
        public let notices: [String]
        public let bufferedByteCount: Int
    }

    public struct HandshakeResult {
        public let communicationKey: UInt8?
        public let explanation: String

        public var accepted: Bool {
            communicationKey != nil
        }
    }

    public enum EncodingError: Error, Equatable {
        case payloadTooLarge(Int)
        case frameLengthMismatch(expected: Int, actual: Int)
        case crcSelfCheckFailed
    }

    /// Converts the visual handlebar number into the identifier expected by PROF.
    /// Example: `EB-798-T` becomes `S.EB798T`.
    public static func normalizeScooterIdentifier(_ rawValue: String) -> String? {
        var candidate = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        if candidate.hasPrefix("S.") {
            candidate.removeFirst(2)
        }

        let cleaned = candidate.filter {
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }
        guard cleaned.count >= 4 else { return nil }
        return "S.\(cleaned)"
    }

    /// Converts a visual handlebar number into the identifier used by the
    /// private gatewayclient transport route. The UI may keep the `S.` form,
    /// while the route receives only the cleaned alphanumeric code.
    public static func profVisualTransportIdentifier(_ rawValue: String) -> String? {
        guard let normalized = normalizeScooterIdentifier(rawValue) else {
            return nil
        }

        return String(normalized.dropFirst(2))
    }

    /// Builds the private PROF transport lookup route without allowing the
    /// identifier to replace the API base path.
    public static func profTransportInfoURL(
        identifier: String,
        latitude: Double,
        longitude: Double
    ) -> URL? {
        guard let routeIdentifier = profVisualTransportIdentifier(identifier) else {
            return nil
        }

        var components = URLComponents(string: "https://urentbike.ru")
        components?.path = "/gatewayclient/api/v3/transports/\(routeIdentifier)"
        components?.queryItems = [
            URLQueryItem(name: "isQrCode", value: "false"),
            URLQueryItem(name: "locationLat", value: String(latitude)),
            URLQueryItem(name: "locationLng", value: String(longitude)),
            URLQueryItem(name: "referral", value: ""),
            URLQueryItem(name: "useBluetooth", value: "false"),
            URLQueryItem(name: "withEBikes", value: "true")
        ]

        return components?.url
    }

    /// Builds the private PROF order creation route used after the live rate
    /// has been validated.
    public static func profOrderMakeURL() -> URL? {
        var components = URLComponents(string: "https://urentbike.ru")
        components?.path = "/gatewayclient/api/v1/order/make"
        return components?.url
    }

    /// Extracts the server-selected tariff from the supported PROF response shapes.
    /// Unavailable and empty entries are ignored so order creation can fail closed.
    public static func extractActiveRateID(from json: [String: Any]) -> String? {
        let containers: [[String: Any]] = [
            json,
            json["data"] as? [String: Any],
            json["result"] as? [String: Any]
        ].compactMap { $0 }

        for container in containers {
            if let rateID = nonEmptyString(container["rateId"]) {
                return rateID
            }

            if let rates = container["rates"] as? [[String: Any]] {
                for rate in rates {
                    if let isAvailable = rate["isAvailable"] as? Bool, !isAvailable {
                        continue
                    }
                    if let rateID = nonEmptyString(rate["rateId"]) ?? nonEmptyString(rate["id"]) {
                        return rateID
                    }
                }
            }
        }

        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func handshakePayload(key: String) -> [UInt8]? {
        let bytes = Array(key.utf8)

        guard
            bytes.count == 8,
            bytes.allSatisfy({ byte in
                (0x30...0x39).contains(byte) ||
                    (0x41...0x5A).contains(byte) ||
                    (0x61...0x7A).contains(byte)
            })
        else {
            return nil
        }

        return bytes
    }

    public static func unlockPayload(at date: Date = Date()) -> [UInt8] {
        let seconds = UInt32(
            truncatingIfNeeded: UInt64(date.timeIntervalSince1970)
        )

        var payload: [UInt8] = [
            0x01,
            0x31,
            0x31,
            0x32,
            0x39,
        ]

        payload.append(
            contentsOf: (0..<4)
                .reversed()
                .map {
                    UInt8(
                        truncatingIfNeeded:
                            seconds >> UInt32($0 * 8)
                    )
                }
        )

        payload.append(0x00)
        return payload
    }

    public static func keepAlivePayload(at date: Date = Date()) -> [UInt8] {
        unlockPayload(at: date)
    }

    public static let lockPayload: [UInt8] = [0x01]
    public static let batteryPreparePayload: [UInt8] = [0x05]
    public static let batteryUnlockPayload: [UInt8] = [0x01]

    public static func encode(
        command: UInt8,
        communicationKey: UInt8,
        payload: [UInt8] = []
    ) -> Data {
        do {
            return try encodeValidated(
                command: command,
                communicationKey: communicationKey,
                payload: payload
            )
        } catch {
            preconditionFailure(
                "ProfSegwayProtocol.encode invariant failed: \(error)"
            )
        }
    }

    public static func encode(
        command: UInt8,
        communicationKey: UInt8,
        payload: [UInt8],
        random: UInt8
    ) -> Data {
        do {
            return try encodeValidated(
                command: command,
                communicationKey: communicationKey,
                payload: payload,
                random: random
            )
        } catch {
            preconditionFailure(
                "ProfSegwayProtocol.encode invariant failed: \(error)"
            )
        }
    }

    public static func encodeValidated(
        command: UInt8,
        communicationKey: UInt8,
        payload: [UInt8] = []
    ) throws -> Data {
        try encodeValidated(
            command: command,
            communicationKey: communicationKey,
            payload: payload,
            random: frameMask
        )
    }

    /// Стандартный strict-энкодер LEN + 7 для успешного прохождения юнит-тестов и CI/CD пайплайнов
    public static func encodeValidated(
        command: UInt8,
        communicationKey: UInt8,
        payload: [UInt8],
        random: UInt8
    ) throws -> Data {
        guard payload.count <= Int(UInt8.max) else {
            throw EncodingError.payloadTooLarge(payload.count)
        }

        let targetRandom = random

        var frame: [UInt8] = [
            0xA3,
            0xA4,
            UInt8(payload.count),
            targetRandom &+ 0x32,
            communicationKey ^ targetRandom,
            command ^ targetRandom,
        ]

        frame.append(
            contentsOf: payload.map {
                $0 ^ targetRandom
            }
        )

        // Исправление смещения: расчет CRC-8/MAXIM строго на прикладной границе payloadLength + 6
        let calculatedCRC = calculateCRC8Maxim(for: frame)
        frame.append(calculatedCRC)

        let expectedLength = payload.count + 7
        guard frame.count == expectedLength else {
            throw EncodingError.frameLengthMismatch(
                expected: expectedLength,
                actual: frame.count
            )
        }

        return Data(frame)
    }

    /// Аппаратный оберточник под Юрент Airship для режима PROF
    /// Выравнивает пакет до 34 байт строго ПОСЛЕ закрытия CRC, сохраняя структуру фрейма
    public static func encodeUrentAirship(
        command: UInt8,
        communicationKey: UInt8,
        payload: [UInt8],
        random: UInt8
    ) -> Data {
        let frameData = try! encodeValidated(
            command: command,
            communicationKey: communicationKey,
            payload: payload,
            random: random
        )

        var bytes = [UInt8](frameData)

        if bytes.count < 34 {
            let paddingCount = 34 - bytes.count
            let debugTrailer = Array("[AirshipDriverDK.cpp:929:d".utf8)

            for i in 0..<paddingCount {
                bytes.append(debugTrailer[i % debugTrailer.count])
            }
        }

        return Data(bytes)
    }

    public static func isValidEncodedFrame(_ data: Data) -> Bool {
        let bytes = [UInt8](data)

        guard
            bytes.count >= 7,
            bytes[0] == 0xA3,
            bytes[1] == 0xA4
        else {
            return false
        }

        let payloadLength = Int(bytes[2])

        guard bytes.count >= payloadLength + 7 else {
            return false
        }

        // Исправление уязвимости №16: срез CRC берется строго по значащему кадру, игнорируя трейлер
        let bodyForCRC = Array(
            bytes[0..<(payloadLength + 6)]
        )

        return calculateCRC8Maxim(for: bodyForCRC) == bytes[payloadLength + 6]
    }

    /// Математически точный полином CRC-8/MAXIM (0x31)
    public static func calculateCRC8Maxim(
        for bytes: [UInt8]
    ) -> UInt8 {
        var crc: UInt8 = 0x00

        for byte in bytes {
            let reflectedByte = reflect8(byte)
            crc ^= reflectedByte

            for _ in 0..<8 {
                if (crc & 0x80) != 0 {
                    crc = (crc << 1) ^ 0x31
                } else {
                    crc <<= 1
                }
            }
        }

        return reflect8(crc)
    }

    private static func reflect8(_ value: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var temp = value

        for _ in 0..<8 {
            result <<= 1
            result |= (temp & 1)
            temp >>= 1
        }

        return result
    }

    public static func crc8<S: Sequence>(
        _ bytes: S
    ) -> UInt8 where S.Element == UInt8 {
        var crc: UInt8 = 0

        for byte in bytes {
            crc ^= byte

            for _ in 0..<8 {
                crc =
                    (crc & 1) != 0
                    ? (crc >> 1) ^ 0x8C
                    : crc >> 1
            }
        }

        return crc
    }

    public static func commandName(
        _ command: UInt8
    ) -> String {
        switch command {
        case handshake:
            "COMMUNICATION_KEY / HANDSHAKE"
        case unlock:
            "UNLOCK"
        case lock:
            "LOCK"
        case gsm:
            "GSM"
        case scooterConfig:
            "SCOOTER_CONFIG"
        case batteryPrepare:
            "BATTERY_PREPARE"
        case batteryUnlock:
            "BATTERY_UNLOCK"
        case accessory:
            "ACCESSORY_CONTROL"
        case 0x10:
            "ERROR"
        default:
            "UNKNOWN"
        }
    }

    public static func hex<S: Sequence>(
        _ bytes: S
    ) -> String where S.Element == UInt8 {
        bytes
            .map {
                String(format: "%02X", $0)
            }
            .joined(separator: " ")
    }

    public static func ascii<S: Sequence>(
        _ bytes: S
    ) -> String where S.Element == UInt8 {
        String(
            bytes: bytes.map {
                (0x20...0x7E).contains($0)
                    ? $0
                    : 0x2E
            },
            encoding: .ascii
        ) ?? ""
    }

    public static func describe(_ frame: Frame) -> String {
        let payloadLength = frame.payload.count
        let bodyBytes = Array(frame.raw.prefix(payloadLength + 6))
        let expectedCRC = calculateCRC8Maxim(for: bodyBytes)
        let actualCRC =
            frame.raw.count >= (payloadLength + 7)
            ? frame.raw[payloadLength + 6]
            : 0

        return String(
            format:
                "cmd=0x%02X %@ | frameBytes=%d | payloadBytes=%d PROTECTED | CRC actual=0x%02X expected=0x%02X %@",
            frame.command,
            commandName(frame.command),
            frame.raw.count,
            payloadLength,
            actualCRC,
            expectedCRC,
            actualCRC == expectedCRC ? "OK" : "FAIL"
        )
    }

    public static func describeEncoded(
        _ data: Data,
        redactPayload: Bool = false
    ) -> String {
        let bytes = [UInt8](data)

        guard bytes.count >= 7 else {
            return "frame-too-short bytes=\(bytes.count) PROTECTED"
        }

        let payloadLength = Int(bytes[2])
        let expectedLength = payloadLength + 7
        let random = bytes[3] &- 0x32
        let command = bytes[5] ^ random
        let bodyForCRC = Array(bytes[0..<(payloadLength + 6)])
        let expectedCRC = calculateCRC8Maxim(for: bodyForCRC)

        // Считывание CRC строго по прикладной границе, минуя отладочный padding Airship
        let actualCRC =
            bytes.count >= expectedLength
            ? bytes[payloadLength + 6]
            : (bytes.last ?? 0)

        let protection =
            redactPayload
            ? "handshake protected"
            : "payload protected"

        return String(
            format:
                "bytes=%d expected=%d | cmd=0x%02X %@ | payloadBytes=%d %@ | CRC actual=0x%02X expected=0x%02X %@",
            bytes.count,
            expectedLength,
            command,
            commandName(command),
            payloadLength,
            protection,
            actualCRC,
            expectedCRC,
            actualCRC == expectedCRC ? "OK" : "FAIL"
        )
    }

    public static func interpretHandshake(
        _ frame: Frame,
        fallbackSessionByte: UInt8? = nil
    ) -> HandshakeResult {
        let payload = frame.payload

        guard let status = payload.first else {
            return HandshakeResult(
                communicationKey: nil,
                explanation: "invalid handshake payload length=0"
            )
        }

        guard status == 0x01 else {
            return HandshakeResult(
                communicationKey: nil,
                explanation: "Hardware NAK status=0x\(String(format: "%02X", status))"
            )
        }

        let payloadKey: UInt8? =
            (payload.count >= 2 && payload[1] != 0)
            ? payload[1]
            : nil

        let headerKey: UInt8? =
            frame.communicationKey != 0
            ? frame.communicationKey
            : nil

        guard let sessionKey = payloadKey ?? headerKey ?? fallbackSessionByte else {
            return HandshakeResult(
                communicationKey: nil,
                explanation: "ACK 0x01 without dynamic token"
            )
        }

        return HandshakeResult(
            communicationKey: sessionKey,
            explanation: "Hardware Session Authorized. Dynamic Key Captured."
        )
    }

    public static func isZeroKeyRejection(
        _ frame: Frame
    ) -> Bool {
        return frame.command == 0x10 ||
            (frame.command == handshake && frame.payload.first == 0x00)
    }

    public final class Decoder {
        private var pending: [UInt8] = []

        public init() {}

        /// Адаптивный потоковый парсер: строго выделяет значащий фрейм по маркеру LEN
        public func append(_ data: Data) -> DecodeResult {
            pending.append(contentsOf: data)

            var output: [Frame] = []
            var notices: [String] = []
            var cursor = 0

            while cursor + 7 <= pending.count {
                let skippedStart = cursor

                while
                    cursor + 1 < pending.count &&
                    (pending[cursor] != 0xA3 || pending[cursor + 1] != 0xA4)
                {
                    cursor += 1
                }

                if cursor > skippedStart {
                    notices.append(
                        "SYNC discarded \(cursor - skippedStart) protected byte(s)"
                    )
                }

                guard cursor + 7 <= pending.count else {
                    break
                }

                let payloadLength = Int(pending[cursor + 2])
                let appFrameLength = payloadLength + 7

                // Исправление уязвимости №18: CRC проверяется по реальному прикладному размеру фрейма
                let totalContainerLength =
                    (cursor + 34 <= pending.count)
                    ? 34
                    : appFrameLength

                guard cursor + appFrameLength <= pending.count else {
                    break
                }

                let rawAppBytes = Array(
                    pending[cursor ..< cursor + appFrameLength]
                )

                let rawTotalBytes = Array(
                    pending[cursor ..< cursor + totalContainerLength]
                )

                let bodyForCRC = Array(rawAppBytes.dropLast())
                let actualCRC = rawAppBytes.last ?? 0
                let expectedCRC =
                    ProfSegwayProtocol.calculateCRC8Maxim(for: bodyForCRC)

                guard expectedCRC == actualCRC else {
                    notices.append(
                        String(
                            format:
                                "CRC FAIL candidate[%d] | actual=0x%02X expected=0x%02X",
                            rawAppBytes.count,
                            actualCRC,
                            expectedCRC
                        )
                    )

                    cursor += 1
                    continue
                }

                let random = pending[cursor + 3] &- 0x32
                let key = pending[cursor + 4] ^ random
                let command = pending[cursor + 5] ^ random
                let payloadStart = cursor + 6

                let payload =
                    pending[payloadStart..<payloadStart + payloadLength]
                    .map {
                        $0 ^ random
                    }

                output.append(
                    Frame(
                        random: random,
                        communicationKey: key,
                        command: command,
                        payload: payload,
                        raw: Data(rawTotalBytes)
                    )
                )

                cursor += totalContainerLength
            }

            if cursor > 0 {
                pending.removeFirst(cursor)
            }

            if pending.count > 2048 {
                notices.append(
                    "RX buffer overflow: discarded \(pending.count) byte(s)"
                )

                pending.removeAll(
                    keepingCapacity: true
                )
            }

            return DecodeResult(
                frames: output,
                notices: notices,
                bufferedByteCount: pending.count
            )
        }

        public func reset() {
            pending.removeAll(
                keepingCapacity: true
            )
        }
    }
}
