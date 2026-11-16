import Foundation
import Crypto
import Noise
public extension Data {
    var base64URL:String { base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
    init?(base64URL:String) {
        guard !base64URL.isEmpty, base64URL.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }), let data = Data(base64Encoded:base64URL.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")+String(repeating:"=",count:(4-base64URL.count%4)%4)), data.base64URL == base64URL else { return nil }
        self = data
    }
}
public struct QRPair {
    public let pairId:String
    public let androidKey:Data, token:Data
    public init(pairId:String,androidKey:Data,token:Data) { self.pairId=pairId; self.androidKey=androidKey; self.token=token }
    public static func parse(_ text:String) throws -> QRPair {
        guard text.utf8.count <= 1024, let data=text.data(using:.utf8), let o=try JSONSerialization.jsonObject(with:data) as? [String:Any], try Wire.integer(o["v"]) == 1,
              let pair=o["pairId"] as? String, Wire.uuid(pair),
              let key=o["androidKey"] as? String, let kd=Data(base64URL:key), kd.count == 32,
              let token=o["token"] as? String, let td=Data(base64URL:token), td.count == 32 else { throw BridgeError.invalidQR }
        return QRPair(pairId:pair,androidKey:kd,token:td)
    }
}
public struct PairCandidate: Codable {
    public let pairId:String, privateKey:Data, androidKey:Data
    public var token:Data?
    public var confirmed:Bool
    public var attempted:Bool
    public var peripheralId:String?
    public var deviceName:String?
    public init(qr:QRPair) {
        pairId=qr.pairId; androidKey=qr.androidKey; token=qr.token; privateKey=Curve25519.KeyAgreement.PrivateKey().rawRepresentation; confirmed=false; attempted=false
    }
}
/// Every connection creates a new Noise state and nonces. No transport state is persisted.
public final class SecureSession {
    private let candidate:PairCandidate, resume:Bool
    private let handshake:Noise.HandshakeState
    private var sender:Noise.CipherState?, receiver:Noise.CipherState?
    private var phase = 0
    public init(candidate:PairCandidate,resume:Bool) throws {
        guard Wire.uuid(candidate.pairId), candidate.androidKey.count == 32, candidate.privateKey.count == 32,
              resume || candidate.token?.count == 32 else { throw BridgeError.authentication }
        self.candidate=candidate; self.resume=resume
        handshake = try Noise.HandshakeState(config:Noise.Config(cipherSuite:Noise.CipherSuite(keyCurve:.x25519,cipher:.ChaChaPoly1305,hashFunction:.sha256),handshake:.XX_Initiator,prologue:Array(("anbridge/1/"+candidate.pairId).utf8),staticKeypair:Curve25519.KeyAgreement.PrivateKey(rawRepresentation:candidate.privateKey)))
    }
    public func start() throws -> Data {
        guard phase == 0 else { throw BridgeError.ordering }; phase=1
        return Data(try handshake.writeMessage(payload:[]).0)
    }
    public func receiveHandshake(_ message:Data) throws -> Data {
        guard phase == 1, message.count <= 4096 else { throw BridgeError.ordering }
        let result = try handshake.readMessage(Array(message))
        guard result.payload.isEmpty, try handshake.peerStatic().rawRepresentation == candidate.androidKey else { phase = -1; throw BridgeError.authentication }
        // The QR token is not even serialized until Android's decrypted static key matches its pin.
        var auth:[String:Any] = ["op":resume ? "resume" : "pair"]
        if !resume { auth["token"]=candidate.token!.base64URL }
        let third = try handshake.writeMessage(payload:Array(JSONSerialization.data(withJSONObject:auth,options:[.sortedKeys])))
        guard let send=third.c1, let receive=third.c2 else { throw BridgeError.authentication }
        sender=send; receiver=receive; phase=2
        return Data(third.buffer)
    }
    public func encrypt(_ plaintext:Data) throws -> Data {
        guard phase == 2, let sender, plaintext.count <= 4080 else { throw BridgeError.notReady }
        return Data(try sender.encrypt(plaintext:Array(plaintext)))
    }
    public func decrypt(_ ciphertext:Data) throws -> Data {
        guard phase == 2, let receiver, ciphertext.count >= 16, ciphertext.count <= 4096 else { throw BridgeError.notReady }
        return Data(try receiver.decrypt(ciphertext:Array(ciphertext)))
    }
}
