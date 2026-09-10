import Foundation
import Darwin

@main
enum ProtocolSelfTest {
    static func main() {
        require(SegwayProtocol.handshakePayload(key: "A1B2C3D4") == Array("A1B2C3D4".utf8), "valid authorized BLE key")
        require(SegwayProtocol.handshakePayload(key: "short") == nil, "short BLE key rejection")
        require(SegwayProtocol.handshakePayload(key: "1234567!") == nil, "non-alphanumeric BLE key rejection")

        let referenceHandshake = SegwayProtocol.encodeUrentAirship(
            command: SegwayProtocol.handshake,
            communicationKey: 0,
            payload: Array("A1B2C3D4".utf8),
            random: 0x64
        )
        require(
            Array(referenceHandshake.prefix(15)) == [0xA3, 0xA4, 0x08, 0x96, 0x64, 0x65, 0x25, 0x55, 0x26, 0x56, 0x27, 0x57, 0x20, 0x50, 0x1C],
            "official SDK handshake frame prefix"
        )
        require(
            referenceHandshake.count == 34,
            "Airship handshake uses a fixed 34-byte container"
        )
        require(
            Array(referenceHandshake.dropFirst(15)) == Array("[AirshipDriverDK.cpp:929:d".utf8.prefix(19)),
            "Airship handshake padding trailer"
        )

        let fixedDate = Date(timeIntervalSince1970: TimeInterval(0x01020304))
        require(
            SegwayProtocol.unlockPayload(at: fixedDate) == [0x01, 0x31, 0x31, 0x32, 0x39, 0x01, 0x02, 0x03, 0x04, 0x00],
            "official SDK unlock payload"
        )
        require(
            SegwayProtocol.keepAlivePayload(at: fixedDate) == SegwayProtocol.unlockPayload(at: fixedDate),
            "unlock keep-alive payload is rebuilt from the current timestamp"
        )
        require(SegwayProtocol.lockPayload == [0x01], "official SDK lock payload")
        require(SegwayProtocol.batteryPreparePayload == [0x05], "official SDK battery prepare payload")
        require(SegwayProtocol.batteryUnlockPayload == [0x01], "official SDK battery unlock payload")
        require(SegwayProtocol.frameMask == 0xA0, "fixed frame mask")
        require(SegwayProtocol.unlock == 0x7D, "unlock command identifier")

        let standardFrame = StandardSegwayProtocol.encode(
            command: StandardSegwayProtocol.unlock,
            communicationKey: 0x7B,
            payload: [0x01],
            random: StandardSegwayProtocol.frameMask
        )
        require(standardFrame.count == 34, "STANDARD keeps the original fixed Airship container")
        require(StandardSegwayProtocol.isValidEncodedFrame(standardFrame), "STANDARD frame validation")
        let standardDecoded = StandardSegwayProtocol.Decoder().append(standardFrame)
        require(standardDecoded.frames.count == 1, "STANDARD fixed-container decoding")
        require(standardDecoded.frames[0].command == StandardSegwayProtocol.unlock, "STANDARD command decoding")
        require(
            StandardSegwayProtocol.interpretHandshake(standardDecoded.frames[0]).accepted,
            "STANDARD preserves the pre-MAX handshake behavior"
        )

        require(
            ProfSegwayProtocol.handshakePayload(key: "A1B2C3D4") == Array("A1B2C3D4".utf8),
            "PROF strict handshake payload"
        )
        require(
            ProfSegwayProtocol.normalizeScooterIdentifier("EB-798-T") == "S.EB798T",
            "PROF visual scooter number normalization"
        )
        require(
            ProfSegwayProtocol.normalizeScooterIdentifier(" s.eb798t ") == "S.EB798T",
            "PROF normalized scooter identifier remains stable"
        )
        require(
            ProfSegwayProtocol.normalizeScooterIdentifier("---") == nil,
            "PROF rejects an empty scooter identifier"
        )
        require(
            ProfSegwayProtocol.profVisualTransportIdentifier("EE-685-X") == "EE685X" &&
                ProfSegwayProtocol.profVisualTransportIdentifier("S.EE685X") == "EE685X",
            "PROF private route removes formatting and the S. prefix"
        )
        let profTransportURL = ProfSegwayProtocol.profTransportInfoURL(
            identifier: "S.EE685X",
            latitude: 55.658410,
            longitude: 37.740921
        )
        let profTransportComponents = profTransportURL.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
        require(
            profTransportComponents?.scheme == "https" &&
                profTransportComponents?.host == "urentbike.ru",
            "PROF transport lookup keeps the expected HTTPS origin"
        )
        require(
            profTransportComponents?.path == "/gatewayclient/api/v3/transports/EE685X",
            "PROF transport lookup keeps the gatewayclient v3 path and clean visual identifier"
        )
        require(
            profTransportComponents?.queryItems?.first(where: { $0.name == "locationLat" })?.value == "55.65841" &&
                profTransportComponents?.queryItems?.first(where: { $0.name == "locationLng" })?.value == "37.740921",
            "PROF transport lookup keeps the verified coordinates"
        )
        require(
            ProfSegwayProtocol.profTransportInfoURL(
                identifier: "---",
                latitude: 55.658410,
                longitude: 37.740921
            ) == nil,
            "PROF transport lookup rejects an invalid identifier"
        )
        let profOrderURL = ProfSegwayProtocol.profOrderMakeURL()
        let profOrderComponents = profOrderURL.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
        require(
            profOrderComponents?.scheme == "https" &&
                profOrderComponents?.host == "urentbike.ru" &&
                profOrderComponents?.path == "/gatewayclient/api/v1/order/make" &&
                profOrderComponents?.query == nil,
            "PROF order creation keeps the gatewayclient v1 order/make route"
        )
        require(
            ProfSegwayProtocol.extractActiveRateID(from: ["rateId": "rate-live"]) == "rate-live",
            "PROF reads a top-level live rate"
        )
        require(
            ProfSegwayProtocol.extractActiveRateID(from: [
                "data": [
                    "rates": [
                        ["id": "rate-disabled", "isAvailable": false],
                        ["id": "rate-active", "isAvailable": true]
                    ]
                ]
            ]) == "rate-active",
            "PROF selects the first available nested rate"
        )
        require(
            ProfSegwayProtocol.extractActiveRateID(from: [
                "rates": [["id": "rate-disabled", "isAvailable": false]]
            ]) == nil,
            "PROF rejects unavailable rates"
        )
        let profFrame = ProfSegwayProtocol.encodeUrentAirship(
            command: ProfSegwayProtocol.unlock,
            communicationKey: 0x7B,
            payload: [0x01],
            random: ProfSegwayProtocol.frameMask
        )
        require(profFrame.count == 34, "PROF strict fixed Airship container")
        require(ProfSegwayProtocol.isValidEncodedFrame(profFrame), "PROF strict frame validation")
        let profDecoded = ProfSegwayProtocol.Decoder().append(profFrame)
        require(profDecoded.frames.count == 1, "PROF strict fixed-container decoding")
        require(profDecoded.frames[0].command == ProfSegwayProtocol.unlock, "PROF strict command decoding")

        let encoded = SegwayProtocol.encodeUrentAirship(
            command: SegwayProtocol.unlock,
            communicationKey: 0xC7,
            payload: [0x01, 0x02, 0xA5],
            random: 0x5A
        )
        let encodedApplicationLength = Int(encoded[2]) + 7
        require(encoded.count == 34, "Airship encoded container length")
        require(encodedApplicationLength == 10, "LEN is payload byte count")
        require(
            SegwayProtocol.crc8(encoded.prefix(encodedApplicationLength - 1)) == encoded[encodedApplicationLength - 1],
            "encoded application-frame CRC"
        )
        require(SegwayProtocol.isValidEncodedFrame(encoded), "encoded frame validation")
        require(Array(Array(encoded)[6...8]) == [0x5B, 0x58, 0xFF], "wire payload XOR masking")

        let defaultMaskFrame = SegwayProtocol.encodeUrentAirship(
            command: SegwayProtocol.unlock,
            communicationKey: 0x7B,
            payload: [0x01],
            random: SegwayProtocol.frameMask
        )
        require(
            Array(defaultMaskFrame.prefix(8)) == [0xA3, 0xA4, 0x01, 0xD2, 0xDB, 0xDD, 0xA1, 0x8C],
            "default encoder uses R=0xA0 and command=0x7D"
        )
        let defaultApplicationLength = Int(defaultMaskFrame[2]) + 7
        require(defaultMaskFrame.count == 34, "default frame uses Airship container length")
        require(
            SegwayProtocol.crc8(defaultMaskFrame.prefix(defaultApplicationLength - 1)) == defaultMaskFrame[defaultApplicationLength - 1],
            "default application-frame CRC-8/MAXIM"
        )

        let fixedMaskFrame = SegwayProtocol.encodeUrentAirship(
            command: SegwayProtocol.unlock,
            communicationKey: 0x7B,
            payload: [0x01],
            random: 0xA0
        )
        require(Array(fixedMaskFrame.prefix(7)) == [0xA3, 0xA4, 0x01, 0xD2, 0xDB, 0xDD, 0xA1], "fixed 0xA0 mask test vector")
        require(SegwayProtocol.isValidEncodedFrame(fixedMaskFrame), "fixed mask frame validation")

        do {
            _ = try SegwayProtocol.encodeValidated(
                command: SegwayProtocol.unlock,
                communicationKey: 0x7B,
                payload: Array(repeating: 0, count: 256),
                random: 0xA0
            )
            require(false, "oversized payload rejection")
        } catch let error as SegwayProtocol.EncodingError {
            require(error == .payloadTooLarge(256), "oversized payload error")
        } catch {
            require(false, "unexpected oversized payload error")
        }

        let decoder = SegwayProtocol.Decoder()
        let bytes = [UInt8](encoded)
        let first = decoder.append(Data(bytes.prefix(4)))
        require(first.frames.isEmpty && first.bufferedByteCount == 4, "fragment buffering")
        let second = decoder.append(Data(bytes.dropFirst(4)))
        require(second.frames.count == 1, "fragment reassembly")
        let frame = second.frames[0]
        require(frame.command == SegwayProtocol.unlock, "decoded command")
        require(frame.communicationKey == 0xC7, "decoded communication key")
        require(frame.payload == [0x01, 0x02, 0xA5], "decoded payload")
        let safeDescription = SegwayProtocol.describe(frame)
        require(!safeDescription.contains("key=0x"), "diagnostics redact session key")
        require(!safeDescription.contains("01 02 A5"), "diagnostics redact decoded payload")
        require(safeDescription.contains("PROTECTED"), "diagnostics mark protected data")

        let acceptedHandshake = handshake(payload: [0x01, 0x66])
        require(acceptedHandshake.communicationKey == 0x66, "handshake captures the dynamic payload key")
        require(acceptedHandshake.explanation == "Hardware Session Authorized. Dynamic Key Captured.", "authorized handshake diagnostic")
        require(!handshake(payload: [0x00, 0x00]).accepted, "status 00 is rejected")
        require(!handshake(payload: [0x55, 0x00]).accepted, "unknown status is rejected")
        require(!handshake(payload: [0x44]).accepted, "short non-ACK response is rejected")
        require(
            handshake(payload: [0x01, 0x00], fallbackSessionByte: 0x5A).communicationKey == 0x5A,
            "Airship bypass accepts an inbound session-byte fallback"
        )
        require(
            !handshake(payload: [0x00, 0x00], fallbackSessionByte: 0x5A).accepted,
            "fallback does not override a hardware NAK"
        )

        let capturedNAK = Data([0xA3, 0xA4, 0x02, 0x94, 0x62, 0x63, 0x62, 0x62, 0x71])
        let capturedResult = SegwayProtocol.Decoder().append(capturedNAK)
        require(capturedResult.frames.count == 1, "captured device frame parses")
        require(capturedResult.frames[0].random == 0x62, "captured random decode")
        require(capturedResult.frames[0].payload == [0x00, 0x00], "captured payload XOR decode")
        require(!SegwayProtocol.interpretHandshake(capturedResult.frames[0]).accepted, "captured NAK is rejected")
        require(SegwayProtocol.isZeroKeyRejection(capturedResult.frames[0]), "captured NAK is classified as a zero-key rejection")
        require(!SegwayProtocol.isZeroKeyRejection(frame), "normal command is not marked as a rejection")

        var corrupted = encoded
        corrupted[encodedApplicationLength - 1] ^= 0xFF
        require(!SegwayProtocol.isValidEncodedFrame(corrupted), "corrupt encoded frame validation")
        let corruptResult = SegwayProtocol.Decoder().append(corrupted)
        require(corruptResult.frames.isEmpty, "decoder rejects a fixed container with an inbound CRC mismatch")
        require(corruptResult.notices.contains(where: { $0.contains("CRC FAIL") }), "decoder reports an inbound CRC mismatch")

        print("ProtocolSelfTest: PASS")
    }

    private static func handshake(
        payload: [UInt8],
        fallbackSessionByte: UInt8? = nil
    ) -> SegwayProtocol.HandshakeResult {
        let raw = SegwayProtocol.encode(
            command: SegwayProtocol.handshake,
            communicationKey: 0,
            payload: payload,
            random: 0x31
        )
        let frame = SegwayProtocol.Decoder().append(raw).frames[0]
        return SegwayProtocol.interpretHandshake(frame, fallbackSessionByte: fallbackSessionByte)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else {
            fputs("ProtocolSelfTest: FAIL: \(label)\n", stderr)
            exit(1)
        }
    }
}
