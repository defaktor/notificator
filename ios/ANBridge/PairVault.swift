import Foundation
import Security
import Darwin
import UserNotifications
import ANBridgeCore

enum PairVault {
    private static let service="dev.anbridge.ios.pair"
    private static var query:[String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"active"] }
    /// Only a verified not-found error means absence. Protected/unreadable files must fail closed.
    private static func isMissing(_ error:Error) -> Bool {
        let error=error as NSError
        if error.domain == NSPOSIXErrorDomain { return error.code == Int(ENOENT) }
        return error.domain == NSCocoaErrorDomain &&
            (error.code == CocoaError.fileReadNoSuchFile.rawValue || error.code == CocoaError.fileNoSuchFile.rawValue)
    }
    private static func readIfPresent(_ url:URL) throws -> Data? {
        do { return try Data(contentsOf:url) }
        catch { if isMissing(error) { return nil }; throw error }
    }
    static func resetForFreshInstall(directory:URL) throws {
        let marker=directory.appendingPathComponent("installation")
        guard try readIfPresent(marker) == nil else { return }
        try erase()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication])
        try Data(UUID().uuidString.utf8).write(to:marker,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        var url=directory; var values=URLResourceValues(); values.isExcludedFromBackup=true; try url.setResourceValues(values)
    }
    /// A durable deletion intent survives a crash between Keychain and private-file erasure.
    static func beginErasure(directory:URL) throws {
        let intent=directory.appendingPathComponent("erasing")
        try Data([1]).write(to:intent,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        let handle=try FileHandle(forWritingTo:intent)
        do { try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
    }
    static func completeErasureIfNeeded(directory:URL) throws {
        let intent=directory.appendingPathComponent("erasing")
        guard try readIfPresent(intent) != nil else { return }
        try erase()
        let receipts=directory.appendingPathComponent("receipts.json")
        do { try FileManager.default.removeItem(at:receipts) } catch { if !isMissing(error) { throw error } }
        UserDefaults.standard.removeObject(forKey:"lastContact")
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        try FileManager.default.removeItem(at:intent)
    }
    static func read() throws -> PairCandidate? {
        var q=query; q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?
        let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data=result as? Data else { throw BridgeError.storage }
        return try JSONDecoder().decode(PairCandidate.self,from:data)
    }
    static func save(_ pair:PairCandidate) throws {
        let data=try JSONEncoder().encode(pair)
        let attrs:[String:Any]=[kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,kSecAttrSynchronizable as String:false]
        var status=SecItemUpdate(query as CFDictionary,attrs as CFDictionary)
        if status == errSecItemNotFound { var q=query; attrs.forEach { q[$0.key]=$0.value }; status=SecItemAdd(q as CFDictionary,nil) }
        guard status == errSecSuccess else { throw BridgeError.storage }
    }
    static func erase() throws {
        let status=SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BridgeError.storage }
    }
}
