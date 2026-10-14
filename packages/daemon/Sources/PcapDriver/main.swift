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

/// An `append` request's arguments as the store takes them. With no `captured_at`, it's now, as
/// in the reference.
func capture(_ args: [String: Any]) throws -> NewCapture {
    var payload: (bytes: Data, mediaType: String)?
    if let p = args["payload"] as? [String: Any], let b64 = p["bytes_base64"] as? String, let bytes = Data(base64Encoded: b64) {
        payload = (bytes, p["media_type"] as? String ?? "application/octet-stream")
    }
    return NewCapture(
        captureId: string(args, "capture_id"), capturedAt: string(args, "captured_at").flatMap(CaptureStore.date) ?? Date(),
        captureType: try required(args, "capture_type"), source: try required(args, "source"), sourceApp: string(args, "source_app"),
        sourceUrl: string(args, "source_url"), privacyLevel: try required(args, "privacy_level"), classification: string(args, "classification"),
        contentText: string(args, "content_text"), payload: payload, extraction: string(args, "extraction"),
        derivedFrom: string(args, "derived_from"), dedupeKey: string(args, "dedupe_key"))
}

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
        return ["capture_id": try need().append(try capture(args))]
    case "append_all":
        guard let captures = args["captures"] as? [[String: Any]] else { throw DriverError(code: "bad_request", message: "captures must be an array") }
        return ["capture_ids": try need().appendAll(try captures.map(capture))]
    case "register_projection":
        try need().registerProjection(name: try required(args, "name"), kind: try required(args, "kind"))
        return [:]
    case "add_projection_entry":
        var output: (kind: String, json: Data)?
        if let kind = string(args, "output_kind") { output = (kind, Data((string(args, "output_json") ?? "null").utf8)) }
        try need().addProjectionEntry(projection: try required(args, "projection"), captureId: try required(args, "capture_id"),
                                      entryRef: try required(args, "entry_ref"), output: output)
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
    case "issue_grant":
        guard let expires = string(args, "expires_at").flatMap(CaptureStore.date) else {
            throw DriverError(code: "bad_request", message: "a grant with no expiry is not issuable")
        }
        var grant = NewGrant(clientId: try required(args, "client_id"), expiresAt: expires)
        if let v = args["privacy_levels"] as? [String] { grant.privacyLevels = v }
        if let v = args["capture_types"] as? [String] { grant.captureTypes = v }
        if let v = args["sources"] as? [String] { grant.sources = v }
        if let v = args["domains"] as? [String] { grant.domains = v }
        grant.timeFrom = string(args, "time_from").flatMap(CaptureStore.date)
        grant.timeTo = string(args, "time_to").flatMap(CaptureStore.date)
        if let v = (args["max_rows_per_query"] as? NSNumber)?.intValue { grant.maxRowsPerQuery = v }
        return ["grant_id": try need().issueGrant(grant)]
    case "revoke_grant":
        try need().revokeGrant(try required(args, "grant_id"))
        return [:]
    case "read":
        let request = ReadRequest(
            tool: try required(args, "tool"), query: string(args, "query") ?? "", contains: string(args, "contains"),
            limit: (args["limit"] as? NSNumber)?.intValue, afterSequence: (args["after_sequence"] as? NSNumber)?.intValue)
        return ["envelopes": try need().read(grantId: try required(args, "grant_id"), request).map(\.foundation)]
    case "read_ids":
        guard let ids = args["capture_ids"] as? [String] else { throw DriverError(code: "bad_request", message: "capture_ids must be a list of capture ids") }
        return ["envelopes": try need().readCaptures(grantId: try required(args, "grant_id"), tool: try required(args, "tool"),
                                                      query: string(args, "query") ?? "", captureIds: ids).map(\.foundation)]
    case "read_outputs":
        let after = args["after_output_sequence"].flatMap { $0 is NSNull ? nil : $0 }
        guard after == nil || after is NSNumber else { throw DriverError(code: "bad_request", message: "after_output_sequence must be a whole number") }
        return ["envelopes": try need().readOutputs(grantId: try required(args, "grant_id"), tool: try required(args, "tool"), kind: string(args, "kind"),
                                                      afterOutputSequence: (after as? NSNumber)?.intValue ?? 0,
                                                      limit: (args["limit"] as? NSNumber)?.intValue).map(\.foundation)]
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
        case .constraint, .revoked: code = "constraint"
        case .wrongKey: code = "key"
        case .denied: code = "denied"
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
