import Foundation

public struct HistoryRecord: Codable, Equatable, Identifiable {
    public var id:String { event.eventId }
    public let pairId:String, event:Event
    public let receivedAt:TimeInterval
}
public struct BannerJob: Codable, Equatable, Identifiable {
    public let id:String, kind:String
    public let event:Event?
    public let count:Int
    public let createdAt:TimeInterval
    public var started:Bool
}
private struct Batch: Codable {
    var pairId:String, count:Int = 0
    var completedAt:TimeInterval?
}
private struct Snapshot: Codable {
    var version = 1
    var history:[HistoryRecord] = []
    var dedup:[String:TimeInterval] = [:]
    var jobs:[BannerJob] = []
    var batches:[String:Batch] = [:]
    var activeBatch:[String:String] = [:]
    var lastSeq:[String:Int64] = [:]
}
/// A single atomic snapshot is the transaction boundary. In-memory state changes only after durable write succeeds.
/// The application calls this serially from its Bluetooth queue. No ACK may be queued before this API returns.
public final class ReceiptStore {
    private var state:Snapshot
    private let writer:(Data) throws -> Void
    public var history:[HistoryRecord] { state.history.sorted { $0.event.seq > $1.event.seq } }
    public var jobs:[BannerJob] { state.jobs }
    public init(url:URL? = nil, writer:((Data) throws -> Void)? = nil) throws {
        if let url, FileManager.default.fileExists(atPath:url.path) {
            state = try JSONDecoder().decode(Snapshot.self,from:Data(contentsOf:url))
            guard state.version == 1 else { throw BridgeError.storage }
        } else { state=Snapshot() }
        if let writer { self.writer=writer }
        else if let url {
            self.writer = { data in
                try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:url.deletingLastPathComponent().path)
                try data.write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
                #else
                try data.write(to:url,options:.atomic)
                #endif
                let handle=try FileHandle(forWritingTo:url)
                do { try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
                var protectedURL=url
                var values=URLResourceValues(); values.isExcludedFromBackup=true
                try protectedURL.setResourceValues(values)
            }
        } else { self.writer = { _ in } }
    }
    private func commit(_ next:Snapshot) throws {
        let data=try JSONEncoder().encode(next)
        try writer(data)
        state=next
    }
    private func pruned(_ snapshot:Snapshot,now:TimeInterval) -> Snapshot {
        var s=snapshot
        s.history.removeAll { now-$0.receivedAt >= 604800 }
        s.dedup=s.dedup.filter { now-$0.value < 604800 }
        s.batches=s.batches.filter { $0.value.completedAt.map { now-$0 < 604800 } ?? true }
        let visible=Set(s.history.map { "event."+$0.event.eventId })
        s.jobs.removeAll { now-$0.createdAt >= 604800 || ($0.kind == "event" && !visible.contains($0.id)) }
        return s
    }
    public func prune(now:TimeInterval) throws { try commit(pruned(state,now:now)) }
    @discardableResult public func receive(_ event:Event,pairId:String,now:TimeInterval,suppressBanner:Bool) throws -> Bool {
        _ = try Wire.encode(.event(event))
        guard Wire.uuid(pairId) else { throw BridgeError.schema }
        var s=pruned(state,now:now)
        let key=pairId+"/"+event.eventId
        if s.dedup[key] != nil { try commit(s); return false }
        guard event.seq > (s.lastSeq[pairId] ?? 0) else { throw BridgeError.ordering }
        if let batch=event.batchId {
            guard s.activeBatch[pairId] == batch, s.batches[batch]?.completedAt == nil else { throw BridgeError.ordering }
            s.batches[batch]!.count += 1
        } else if s.activeBatch[pairId] != nil { throw BridgeError.ordering }
        s.lastSeq[pairId]=event.seq
        s.dedup[key]=now
        s.history.append(HistoryRecord(pairId:pairId,event:event,receivedAt:now))
        if s.history.count > 1000 { s.history.removeFirst(s.history.count-1000) }
        if !event.delayed && !suppressBanner {
            s.jobs.append(BannerJob(id:"event."+event.eventId,kind:"event",event:event,count:1,createdAt:now,started:false))
        }
        try commit(pruned(s,now:now))
        return true
    }
    public func beginBatch(_ batchId:String,pairId:String,now:TimeInterval) throws {
        guard Wire.uuid(batchId), Wire.uuid(pairId) else { throw BridgeError.schema }
        var s=pruned(state,now:now)
        if let active=s.activeBatch[pairId], active != batchId { throw BridgeError.ordering }
        if let existing=s.batches[batchId] {
            guard existing.pairId == pairId else { throw BridgeError.ordering }
            // A retransmitted completed group may be opened and closed again, but never recounted.
        } else { s.batches[batchId]=Batch(pairId:pairId) }
        s.activeBatch[pairId]=batchId
        try commit(s)
    }
    public func endBatch(_ batchId:String,pairId:String,now:TimeInterval,suppressBanner:Bool) throws {
        var s=pruned(state,now:now)
        guard var batch=s.batches[batchId], batch.pairId == pairId else { throw BridgeError.ordering }
        if batch.completedAt != nil {
            if let active=s.activeBatch[pairId], active != batchId { throw BridgeError.ordering }
            s.activeBatch.removeValue(forKey:pairId); try commit(s); return
        }
        guard s.activeBatch[pairId] == batchId else { throw BridgeError.ordering }
        batch.completedAt=now; s.batches[batchId]=batch; s.activeBatch.removeValue(forKey:pairId)
        if batch.count > 0 && !suppressBanner { s.jobs.append(BannerJob(id:"batch."+batchId,kind:"summary",event:nil,count:batch.count,createdAt:now,started:false)) }
        try commit(s)
    }
    public func startNextJob(now:TimeInterval) throws -> BannerJob? {
        var s=pruned(state,now:now)
        guard let index=s.jobs.firstIndex(where:{ !$0.started }) else { return nil }
        s.jobs[index].started=true
        let job=s.jobs[index]
        try commit(s) // Must precede UNUserNotificationCenter.add; started jobs never replay after a crash.
        return job
    }
    public func finishJob(_ id:String,now:TimeInterval) throws {
        var s=pruned(state,now:now); s.jobs.removeAll { $0.id == id }; try commit(s)
    }
    public func clearHistory(now:TimeInterval) throws {
        var s=pruned(state,now:now); s.history=[]; s.jobs=[]; try commit(s)
    }
    public func forget() throws { try commit(Snapshot()) }
}
