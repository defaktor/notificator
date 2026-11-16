import Foundation
/// GATT write-with-response is serialized, while inbound indications remain independent.
/// This queue accepts a new ACK even while the previous ACK's final write callback is pending.
public struct WriteQueue {
    private struct Job { var frames:[Data]; var index:Int = 0; let completion:String }
    private var jobs:[Job]=[]
    private var inFlight=false
    private var nextID:UInt16=0
    public init() {}
    public var isEmpty:Bool { jobs.isEmpty }
    public mutating func enqueue(_ message:Data,frameBytes:Int,completion:String) throws {
        let frames=try Framing.encode(message,id:nextID,frameBytes:frameBytes)
        nextID &+= 1; jobs.append(Job(frames:frames,completion:completion))
    }
    public mutating func nextFrame() -> Data? {
        guard !inFlight,let job=jobs.first else { return nil }
        inFlight=true; return job.frames[job.index]
    }
    public mutating func acknowledge() throws -> String? {
        guard inFlight,!jobs.isEmpty else { throw BridgeError.ordering }
        inFlight=false; jobs[0].index += 1
        if jobs[0].index == jobs[0].frames.count { return jobs.removeFirst().completion }
        return nil
    }
}
