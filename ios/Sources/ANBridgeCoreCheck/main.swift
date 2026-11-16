// Portable check runner for Command Line Tools installations without XCTest.
import Foundation
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, file:StaticString = #file, line:UInt = #line) { if (try? !value()) != false { fatalError("Expected true",file:file,line:line) } }
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, file:StaticString = #file, line:UInt = #line) { if (try? value()) != false { fatalError("Expected false",file:file,line:line) } }
func XCTAssertEqual<T:Equatable>(_ a: @autoclosure () throws -> T,_ b: @autoclosure () throws -> T,file:StaticString = #file,line:UInt = #line) { if (try? a() == b()) != true { fatalError("Values differ",file:file,line:line) } }
func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?,file:StaticString = #file,line:UInt = #line) { do { if try value() != nil { fatalError("Expected nil",file:file,line:line) } } catch { fatalError("Unexpected error: \(error)",file:file,line:line) } }
func XCTAssertThrowsError<T>(_ value:@autoclosure () throws -> T,file:StaticString = #file,line:UInt = #line) { do { _ = try value() } catch { return }; fatalError("Expected rejection",file:file,line:line) }
func XCTUnwrap<T>(_ value:T?) throws -> T { guard let value else { throw BridgeError.schema }; return value }
func XCTFail() { fatalError("Unexpected branch") }
import Crypto
import Noise
import ANBridgeCore
final class CoreTests {
    let pair = "4dd77dd7-03ca-4057-a9bb-bdddd7def110"
    func event(_ id: String = UUID().uuidString.lowercased(), seq: Int64 = 1, delayed: Bool = false, batch: String? = nil) -> Event {
        Event(eventId:id,seq:seq,sourcePackage:"org.example.messages",appName:"Сообщения",title:"Анна",body:"Встреча 😀",occurredAt:1794740400000,privacy:"full",delayed:delayed,batchId:batch)
    }
    func test4096BytesRoundTripAtTwentyAndCounterWrap() throws {
        let data = Data((0..<4096).map { UInt8($0 % 251) })
        let frames = try Framing.encode(data, id:65535, frameBytes:20)
        XCTAssertEqual(frames.count,293)
        var decoder = FrameAssembler(expectedID:65535)
        var result:Data?
        for f in frames { result = try decoder.receive(f,now:1) }
        XCTAssertEqual(result,data)
        XCTAssertEqual(try decoder.receive(Framing.encode(Data([7]),id:0,frameBytes:20)[0],now:2),Data([7]))
        XCTAssertThrowsError(try Framing.encode(Data(repeating:0,count:4097),id:0,frameBytes:20))
    }
    func testRejectsInterleavingEmptyOrderOversizeAndIdle() throws {
        let frames = try Framing.encode(Data(repeating:1,count:30),id:0,frameBytes:20)
        var d = FrameAssembler()
        XCTAssertNil(try d.receive(frames[0],now:0))
        XCTAssertThrowsError(try d.receive(frames[1],now:16))
        d = FrameAssembler()
        XCTAssertThrowsError(try d.receive(frames[1],now:0))
        XCTAssertThrowsError(try d.receive(Data([0,0,0,0,0,1]),now:0))
        d = FrameAssembler()
        _ = try d.receive(frames[0],now:0)
        XCTAssertThrowsError(try d.receive(Framing.encode(Data([1]),id:1,frameBytes:20)[0],now:0))
    }
    func testSchemaRejectsVersionPrivacyBoundsAndUnknownType() throws {
        let raw = try Wire.encode(.event(event()))
        guard case .event(let decoded) = try Wire.decode(raw) else { return XCTFail() }
        XCTAssertEqual(decoded.body,"Встреча 😀")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with:raw) as? [String:Any])
        obj["v"] = 2
        XCTAssertThrowsError(try Wire.decode(JSONSerialization.data(withJSONObject:obj)))
        obj["v"] = 1; obj["privacy"] = "appOnly"
        XCTAssertThrowsError(try Wire.decode(JSONSerialization.data(withJSONObject:obj)))
        obj["privacy"] = "full"; obj["seq"] = 9007199254740992 as Int64
        XCTAssertThrowsError(try Wire.decode(JSONSerialization.data(withJSONObject:obj)))
        obj["seq"] = true
        XCTAssertThrowsError(try Wire.decode(JSONSerialization.data(withJSONObject:obj)))
        XCTAssertThrowsError(try Wire.decode(Data("{\"v\":1,\"type\":\"UNKNOWN\"}".utf8)))
    }
    func testReceiptSurvivesRestartAndClearWithoutDuplicateBanner() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:url) }
        let e = event()
        var store = try ReceiptStore(url:url)
        XCTAssertTrue(try store.receive(e,pairId:pair,now:1,suppressBanner:false))
        XCTAssertEqual(store.history.count,1); XCTAssertEqual(store.jobs.count,1)
        store = try ReceiptStore(url:url)
        try store.clearHistory(now:2)
        XCTAssertFalse(try store.receive(e,pairId:pair,now:3,suppressBanner:false))
        XCTAssertTrue(store.history.isEmpty); XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertTrue(try store.receive(event(seq:2),pairId:pair,now:4,suppressBanner:false))
    }
    func testFailedDurableWriteCannotAcknowledgeOrChangeMemory() throws {
        let store = try ReceiptStore(writer: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try store.receive(event(),pairId:pair,now:1,suppressBanner:false))
        XCTAssertTrue(store.history.isEmpty); XCTAssertTrue(store.jobs.isEmpty)
    }
    func testBatchReplayOneSummaryAndOutOfOrderRejected() throws {
        let store = try ReceiptStore()
        let batch = UUID().uuidString.lowercased()
        try store.beginBatch(batch,pairId:pair,now:1)
        XCTAssertTrue(try store.receive(event(seq:2,delayed:true,batch:batch),pairId:pair,now:1,suppressBanner:false))
        XCTAssertThrowsError(try store.receive(event(seq:1,delayed:true,batch:batch),pairId:pair,now:1,suppressBanner:false))
        XCTAssertTrue(store.jobs.isEmpty)
        try store.endBatch(batch,pairId:pair,now:2,suppressBanner:false)
        try store.endBatch(batch,pairId:pair,now:3,suppressBanner:false)
        XCTAssertEqual(store.jobs.count,1); XCTAssertEqual(store.jobs.first?.count,1)
        let job = try XCTUnwrap(store.startNextJob(now:4))
        XCTAssertEqual(job.kind,"summary")
        XCTAssertNil(try store.startNextJob(now:5))
    }
    func testDedupExpiresAtSevenDaysAndDistinctIDsSameTextRemainDistinct() throws {
        let store = try ReceiptStore()
        let e = event()
        _ = try store.receive(e,pairId:pair,now:0,suppressBanner:false)
        _ = try store.receive(event(seq:2),pairId:pair,now:1,suppressBanner:false)
        XCTAssertEqual(store.history.count,2)
        try store.prune(now:604802)
        XCTAssertTrue(store.history.isEmpty)
    }
    func testOldCompletedBatchCannotCloseCurrentBatch() throws {
        let store = try ReceiptStore()
        let a = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased()
        try store.beginBatch(a,pairId:pair,now:1)
        try store.endBatch(a,pairId:pair,now:2,suppressBanner:false)
        try store.beginBatch(b,pairId:pair,now:3)
        XCTAssertThrowsError(try store.endBatch(a,pairId:pair,now:4,suppressBanner:false))
        _ = try store.receive(event(seq:1,delayed:true,batch:b),pairId:pair,now:5,suppressBanner:false)
    }
    func testInterruptedEmptyBatchSurvivesRestartAndEndsBeforeLiveEvents() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:url) }
        var store = try ReceiptStore(url:url)
        let batch = UUID().uuidString.lowercased()
        try store.beginBatch(batch,pairId:pair,now:1)
        store = try ReceiptStore(url:url)
        XCTAssertThrowsError(try store.receive(event(seq:1),pairId:pair,now:2,suppressBanner:false))
        try store.beginBatch(batch,pairId:pair,now:3)
        try store.endBatch(batch,pairId:pair,now:4,suppressBanner:false)
        XCTAssertTrue(store.jobs.isEmpty)
        _ = try store.receive(event(seq:1),pairId:pair,now:5,suppressBanner:false)
        XCTAssertEqual(store.history.count,1)
    }
    func testOutboundQueuesNextACKBeforePreviousWriteCallback() throws {
        var queue = WriteQueue()
        try queue.enqueue(Data(repeating:1,count:30),frameBytes:20,completion:"first")
        let initial = try XCTUnwrap(queue.nextFrame())
        try queue.enqueue(Data([2]),frameBytes:20,completion:"second")
        XCTAssertNil(queue.nextFrame())
        var decoded = FrameAssembler()
        XCTAssertNil(try decoded.receive(initial,now:0))
        XCTAssertNil(try queue.acknowledge())
        XCTAssertNil(try decoded.receive(XCTUnwrap(queue.nextFrame()),now:0))
        XCTAssertNil(try queue.acknowledge())
        XCTAssertEqual(try decoded.receive(XCTUnwrap(queue.nextFrame()),now:0),Data(repeating:1,count:30))
        XCTAssertEqual(try queue.acknowledge(),"first")
        XCTAssertEqual(try decoded.receive(XCTUnwrap(queue.nextFrame()),now:0),Data([2]))
        XCTAssertEqual(try queue.acknowledge(),"second")
        XCTAssertTrue(queue.isEmpty)
        XCTAssertThrowsError(try queue.acknowledge())
    }
    func testQRStrictAndNoisePinsBeforeSecret() throws {
        let android = Curve25519.KeyAgreement.PrivateKey()
        let qr = QRPair(pairId:pair,androidKey:android.publicKey.rawRepresentation,token:Data(repeating:7,count:32))
        let candidate = PairCandidate(qr:qr)
        let initiator = try SecureSession(candidate:candidate,resume:false)
        let responder = try Noise.HandshakeState(config:Noise.Config(cipherSuite:Noise.CipherSuite(keyCurve:.x25519,cipher:.ChaChaPoly1305,hashFunction:.sha256),handshake:.XX_Responder,prologue:Array(("anbridge/1/"+pair).utf8),staticKeypair:android))
        let first = try initiator.start()
        XCTAssertTrue(try responder.readMessage(Array(first)).0.isEmpty)
        let second = try responder.writeMessage(payload:[]).0
        let third = try initiator.receiveHandshake(Data(second))
        let result = try responder.readMessage(Array(third))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(result.0)) as? [String:Any])
        XCTAssertEqual(payload["op"] as? String,"pair")
        XCTAssertEqual(payload["token"] as? String,qr.token.base64URL)
        let hello = try initiator.encrypt(Wire.encode(.hello(pairId:pair,maxFrameBytes:20)))
        XCTAssertEqual(try result.1!.decrypt(ciphertext:Array(hello)),Array(try Wire.encode(.hello(pairId:pair,maxFrameBytes:20))))
        let other = PairCandidate(qr:QRPair(pairId:pair,androidKey:Data(repeating:0,count:32),token:qr.token))
        let wrong = try SecureSession(candidate:other,resume:false)
        let r2 = try Noise.HandshakeState(config:Noise.Config(cipherSuite:Noise.CipherSuite(keyCurve:.x25519,cipher:.ChaChaPoly1305,hashFunction:.sha256),handshake:.XX_Responder,prologue:Array(("anbridge/1/"+pair).utf8),staticKeypair:android))
        _ = try r2.readMessage(Array(wrong.start()))
        XCTAssertThrowsError(try wrong.receiveHandshake(Data(r2.writeMessage(payload:[]).0)))
    }
}

let checks=CoreTests()
try checks.test4096BytesRoundTripAtTwentyAndCounterWrap(); print("PASS test4096BytesRoundTripAtTwentyAndCounterWrap")
try checks.testRejectsInterleavingEmptyOrderOversizeAndIdle(); print("PASS testRejectsInterleavingEmptyOrderOversizeAndIdle")
try checks.testSchemaRejectsVersionPrivacyBoundsAndUnknownType(); print("PASS testSchemaRejectsVersionPrivacyBoundsAndUnknownType")
try checks.testReceiptSurvivesRestartAndClearWithoutDuplicateBanner(); print("PASS testReceiptSurvivesRestartAndClearWithoutDuplicateBanner")
try checks.testFailedDurableWriteCannotAcknowledgeOrChangeMemory(); print("PASS testFailedDurableWriteCannotAcknowledgeOrChangeMemory")
try checks.testBatchReplayOneSummaryAndOutOfOrderRejected(); print("PASS testBatchReplayOneSummaryAndOutOfOrderRejected")
try checks.testDedupExpiresAtSevenDaysAndDistinctIDsSameTextRemainDistinct(); print("PASS testDedupExpiresAtSevenDaysAndDistinctIDsSameTextRemainDistinct")
try checks.testOldCompletedBatchCannotCloseCurrentBatch(); print("PASS testOldCompletedBatchCannotCloseCurrentBatch")
try checks.testInterruptedEmptyBatchSurvivesRestartAndEndsBeforeLiveEvents(); print("PASS testInterruptedEmptyBatchSurvivesRestartAndEndsBeforeLiveEvents")
try checks.testQRStrictAndNoisePinsBeforeSecret(); print("PASS testQRStrictAndNoisePinsBeforeSecret")
try checks.testOutboundQueuesNextACKBeforePreviousWriteCallback(); print("PASS testOutboundQueuesNextACKBeforePreviousWriteCallback")
print("11 portable core checks passed")
