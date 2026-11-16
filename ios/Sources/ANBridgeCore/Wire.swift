import Foundation
import CoreFoundation

public enum BridgeError: Error, Equatable {
    case framing, timeout, schema, version, authentication, ordering, notReady, storage, invalidQR
}
public enum Framing {
    public static func encode(_ message: Data, id: UInt16, frameBytes: Int) throws -> [Data] {
        guard (20...512).contains(frameBytes), !message.isEmpty, message.count <= 4096 else { throw BridgeError.framing }
        let payload = frameBytes - 6, count = (message.count + payload - 1) / payload
        return (0..<count).map { index in
            var data = Data()
            for word in [id, UInt16(index), UInt16(count)] { data.append(UInt8(word >> 8)); data.append(UInt8(word & 255)) }
            data.append(message.subdata(in: index * payload..<min(message.count, (index + 1) * payload)))
            return data
        }
    }
}
public struct FrameAssembler {
    public var frameBytes: Int = 20
    private var expectedID: UInt16
    private var nextIndex = 0, count = 0
    private var bytes = Data()
    private var lastTime: TimeInterval?
    public init(expectedID: UInt16 = 0) { self.expectedID = expectedID }
    public var incomplete: Bool { nextIndex != 0 }
    public func checkIdle(now: TimeInterval) throws {
        if let lastTime, now - lastTime >= 15 { throw BridgeError.timeout }
    }
    public mutating func receive(_ frame: Data, now: TimeInterval) throws -> Data? {
        try checkIdle(now:now)
        guard (20...512).contains(frameBytes), frame.count > 6, frame.count <= frameBytes else { throw BridgeError.framing }
        let b = Array(frame)
        func u16(_ p: Int) -> Int { Int(b[p]) * 256 + Int(b[p+1]) }
        let id = UInt16(u16(0)), index = u16(2), total = u16(4), payload = frameBytes - 6
        guard id == expectedID, total > 0, total <= (4096+payload-1)/payload, index < total, index == nextIndex else { throw BridgeError.framing }
        if nextIndex == 0 { count = total }
        guard total == count, index == total-1 || frame.count == frameBytes,
              bytes.count + frame.count - 6 <= 4096 else { throw BridgeError.framing }
        bytes.append(contentsOf:b.dropFirst(6)); nextIndex += 1; lastTime = now
        if nextIndex == count {
            let result = bytes
            bytes = Data(); nextIndex = 0; count = 0; lastTime = nil; expectedID &+= 1
            return result
        }
        return nil
    }
}
public struct Event: Codable, Equatable, Identifiable {
    public var id:String { eventId }
    public let eventId:String
    public let seq:Int64
    public let sourcePackage:String, appName:String, title:String, body:String
    public let occurredAt:Int64
    public let privacy:String
    public let delayed:Bool
    public let batchId:String?
    public let test:Bool?
    public let truncated:Bool?
    public init(eventId:String, seq:Int64, sourcePackage:String, appName:String, title:String, body:String, occurredAt:Int64, privacy:String, delayed:Bool, batchId:String? = nil, test:Bool? = nil, truncated:Bool? = nil) {
        self.eventId=eventId; self.seq=seq; self.sourcePackage=sourcePackage; self.appName=appName; self.title=title; self.body=body; self.occurredAt=occurredAt; self.privacy=privacy; self.delayed=delayed; self.batchId=batchId; self.test=test; self.truncated=truncated
    }
}
public enum Message: Equatable {
    case hello(pairId:String,maxFrameBytes:Int), ready(pairId:String,maxFrameBytes:Int)
    case event(Event), ack(String), syncBegin(String), syncEnd(String), syncAck(String), unlink
}
public enum Wire {
    public static func uuid(_ string:String) -> Bool { UUID(uuidString:string)?.uuidString.lowercased() == string }
    static func integer(_ value:Any?, min:Int64 = 0, max:Int64 = 9007199254740991) throws -> Int64 {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue.rounded(.towardZero) == n.doubleValue, n.doubleValue >= Double(min), n.doubleValue <= Double(max) else { throw BridgeError.schema }
        return n.int64Value
    }
    static func bool(_ value:Any?) throws -> Bool {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw BridgeError.schema }; return n.boolValue
    }
    static func string(_ obj:[String:Any], _ key:String, limit:Int) throws -> String {
        guard let s = obj[key] as? String, s.utf8.count <= limit else { throw BridgeError.schema }; return s
    }
    static func id(_ obj:[String:Any], _ key:String) throws -> String {
        let s = try string(obj,key,limit:36); guard uuid(s) else { throw BridgeError.schema }; return s
    }
    public static func decode(_ data:Data) throws -> Message {
        guard !data.isEmpty, data.count <= 4080, let o = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw BridgeError.schema }
        guard try integer(o["v"]) == 1 else { throw BridgeError.version }
        guard let type = o["type"] as? String else { throw BridgeError.schema }
        switch type {
        case "HELLO", "READY":
            let pair = try id(o,"pairId"), limit = Int(try integer(o["maxFrameBytes"],min:20,max:512))
            return type == "HELLO" ? .hello(pairId:pair,maxFrameBytes:limit) : .ready(pairId:pair,maxFrameBytes:limit)
        case "EVENT":
            let privacy = try string(o,"privacy",limit:7), delayed = try bool(o["delayed"])
            let title = try string(o,"title",limit:512), body = try string(o,"body",limit:2048)
            guard privacy == "full" || privacy == "appOnly", privacy != "appOnly" || (title.isEmpty && body.isEmpty) else { throw BridgeError.schema }
            let batch:String? = o["batchId"] == nil ? nil : try id(o,"batchId")
            guard delayed == (batch != nil) else { throw BridgeError.schema }
            return .event(Event(eventId:try id(o,"eventId"),seq:try integer(o["seq"],min:1),sourcePackage:try string(o,"sourcePackage",limit:255),appName:try string(o,"appName",limit:256),title:title,body:body,occurredAt:try integer(o["occurredAt"]),privacy:privacy,delayed:delayed,batchId:batch,test:try o["test"].map { try bool($0) },truncated:try o["truncated"].map { try bool($0) }))
        case "ACK": return .ack(try id(o,"eventId"))
        case "SYNC_BEGIN": return .syncBegin(try id(o,"batchId"))
        case "SYNC_END": return .syncEnd(try id(o,"batchId"))
        case "SYNC_ACK": return .syncAck(try id(o,"batchId"))
        case "UNLINK": return .unlink
        default: throw BridgeError.schema
        }
    }
    public static func encode(_ message:Message) throws -> Data {
        var o:[String:Any] = ["v":1]
        switch message {
        case .hello(let pair,let max),.ready(let pair,let max):
            if case .hello = message { o["type"]="HELLO" } else { o["type"]="READY" }
            o["pairId"]=pair; o["maxFrameBytes"]=max
        case .event(let e):
            o = try JSONSerialization.jsonObject(with:JSONEncoder().encode(e)) as! [String:Any]
            o["v"]=1; o["type"]="EVENT"
        case .ack(let id): o["type"]="ACK"; o["eventId"]=id
        case .syncBegin(let id): o["type"]="SYNC_BEGIN"; o["batchId"]=id
        case .syncEnd(let id): o["type"]="SYNC_END"; o["batchId"]=id
        case .syncAck(let id): o["type"]="SYNC_ACK"; o["batchId"]=id
        case .unlink: o["type"]="UNLINK"
        }
        let data = try JSONSerialization.data(withJSONObject:o,options:[.sortedKeys,.withoutEscapingSlashes])
        _ = try decode(data)
        return data
    }
}
