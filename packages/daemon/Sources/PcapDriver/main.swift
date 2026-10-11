import CaptureStore
import CryptoKit
import Foundation

// The conformance driver (docs/spec/DRIVER.md) over CaptureStore: one JSON request a line on
// stdin, one response a line on stdout. A test fixture: it takes the master key in the clear,
// which the app never does.

struct DriverError: Error {
    let code: String
    let message: String
}

var store: CaptureStore?

func need() throws -> CaptureStore {
    guard let store else { throw DriverError(code: "bad_request", message: "no store is open") }
    return store
}

func string(_ args: [String: Any], _ key: String) -> String? { args[key] as? String }

func required(_ args: [String: Any], _ key: String) throws -> String {
    guard let value = string(args, key) else { throw DriverError(code: "bad_request", message: "\(key) is required") }
    return value
}

func json(_ value: Any?) -> Any { value ?? NSNull() }

func handle(_ op: String, _ args: [String: Any]) throws -> [String: Any] {
    switch op {
    case "hello":
        return ["protocol": "1", "implementation": "presence-capture macOS daemon (Swift)"]
    case "open":
        guard store == nil else { throw DriverError(code: "bad_request", message: "a store is already open") }
        let hex = try required(args, "master_key_hex")
        guard hex.count == 64, let bytes = Data(hex: hex) else { throw DriverError(code: "bad_request", message: "master_key_hex must be 64 hex characters") }
        store = try CaptureStore(path: try required(args, "path"), masterKey: SymmetricKey(data: bytes))
        return [:]
    case "append":
        var payload: (bytes: Data, mediaType: String)?
        if let p = args["payload"] as? [String: Any], let b64 = p["bytes_base64"] as? String, let bytes = Data(base64Encoded: b64) {
            payload = (bytes, p["media_type"] as? String ?? "application/octet-stream")
        }
        let capture = NewCapture(
            captureId: string(args, "capture_id"), capturedAt: string(args, "captured_at").flatMap(CaptureStore.date),
            captureType: try required(args, "capture_type"), source: try required(args, "source"), sourceApp: string(args, "source_app"),
            sourceUrl: string(args, "source_url"), privacyLevel: try required(args, "privacy_level"), classification: string(args, "classification"),
            contentText: string(args, "content_text"), payload: payload, extraction: string(args, "extraction"),
            derivedFrom: string(args, "derived_from"), dedupeKey: string(args, "dedupe_key"))
        return ["capture_id": try need().append(capture)]
    case "register_projection":
        try need().registerProjection(name: try required(args, "name"), kind: try required(args, "kind"))
        return [:]
    case "add_projection_entry":
        try need().addProjectionEntry(projection: try required(args, "projection"), captureId: try required(args, "capture_id"),
                                      entryRef: try required(args, "entry_ref"))
        return [:]
    case "revoke":
        let r = try need().revoke(scopeKind: try required(args, "scope_kind"), scopeValue: try required(args, "scope_value"),
                                  reason: string(args, "reason"))
        return ["revocation_id": r.revocationId, "revoked_capture_ids": r.revokedCaptureIds, "erased_on_disk": r.erasedOnDisk]
    case "retain":
        guard let days = (args["days"] as? NSNumber)?.doubleValue else { throw DriverError(code: "bad_request", message: "days is required") }
        let now = string(args, "now").flatMap(CaptureStore.date) ?? Date()
        guard let r = try need().retain(days: days, now: now) else { return ["revocation_id": NSNull(), "revoked_capture_ids": [String]()] }
        return ["revocation_id": r.revocationId, "revoked_capture_ids": r.revokedCaptureIds, "erased_on_disk": r.erasedOnDisk]
    case "content":
        return ["text": json(try need().contentText(try required(args, "capture_id")))]
    case "payload":
        return ["bytes_base64": json(try need().payloadBytes(try required(args, "capture_id"))?.base64EncodedString())]
    case "close":
        store?.close()
        store = nil
        return [:]
    default:
        throw DriverError(code: "bad_request", message: "unknown op: \(op)")
    }
}

func respond(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"id":null,"ok":false,"error":{"code":"internal","message":"unencodable"}}"#.utf8)
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

while let line = readLine() {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    guard let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
        respond(["id": NSNull(), "ok": false, "error": ["code": "bad_request", "message": "not JSON"]])
        continue
    }
    let id = request["id"] ?? NSNull()
    do {
        let result = try handle(request["op"] as? String ?? "", request["args"] as? [String: Any] ?? [:])
        respond(["id": id, "ok": true, "result": result])
    } catch let error as DriverError {
        respond(["id": id, "ok": false, "error": ["code": error.code, "message": error.message]])
    } catch let error as StoreError {
        let code: String
        switch error {
        case .constraint: code = "constraint"
        case .wrongKey: code = "key"
        default: code = "internal"
        }
        respond(["id": id, "ok": false, "error": ["code": code, "message": error.description]])
    } catch {
        respond(["id": id, "ok": false, "error": ["code": "internal", "message": "\(error)"]])
    }
}

extension Data {
    init?(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
