import Foundation
import Combine
import CoreBluetooth
import UserNotifications
import UIKit
import ANBridgeCore

/// Delegates, protocol processing and durable commits are serialized on the main dispatch queue.
final class BridgeModel:NSObject,ObservableObject,CBCentralManagerDelegate,CBPeripheralDelegate,UNUserNotificationCenterDelegate {
    static let shared=BridgeModel()
    static let service=CBUUID(string:"88c2d19a-32a7-47b8-a7ca-1d47ac540000")
    static let dataUUID=CBUUID(string:"88c2d19a-32a7-47b8-a7ca-1d47ac540001")
    static let controlUUID=CBUUID(string:"88c2d19a-32a7-47b8-a7ca-1d47ac540002")
    @Published var status="Нет пары"
    @Published var explanation="Откройте «Связать iPhone» на Android и отсканируйте QR."
    @Published var history:[HistoryRecord]=[]
    @Published var deviceName:String?
    @Published var lastContact:Date?
    @Published var bannersAllowed=true
    @Published var selectedTab=0
    @Published var route:String?
    @Published var errorMessage:String?
    @Published var diagnosticsText=""
    var hasPair:Bool { candidate != nil }
    var historyVisible=false
    private var store:ReceiptStore?
    private var candidate:PairCandidate?
    private var manager:CBCentralManager!
    private var peripheral:CBPeripheral?
    private var control:CBCharacteristic?, dataCharacteristic:CBCharacteristic?
    private var session:SecureSession?
    private var assembler=FrameAssembler()
    private var frameBytes=20, proposedFrameBytes=20
    private var ready=false, handshakePending=false, handshakeDeadline:Date?
    private var writes=WriteQueue()
    private var completions:[String:() -> Void]=[:]
    private var writeStarted:Date?
    private var reconnectWhenClosed:UUID?
    private var retryAttempt=0
    private var retry:DispatchWorkItem?
    private var ticker:Timer?
    private var rejected=Set<UUID>()
    private var diagnostics:[Diagnostic]=[]
    private var directory:URL!
    private struct Diagnostic:Codable { let at:Date; let code:String; let count:Int }
    override private init() {
        super.init()
        do {
            directory=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("ANBridge",isDirectory:true)
            try PairVault.resetForFreshInstall(directory:directory)
            try PairVault.completeErasureIfNeeded(directory:directory)
            store=try ReceiptStore(url:directory.appendingPathComponent("receipts.json"))
            candidate=try PairVault.read()
            if candidate == nil { try store?.forget(); removeBanners() }
            deviceName=candidate?.deviceName
            try store?.prune(now:Date().timeIntervalSince1970)
            history=store?.history ?? []
            if let data=try? Data(contentsOf:directory.appendingPathComponent("diagnostics.json")),let entries=try? JSONDecoder().decode([Diagnostic].self,from:data) { diagnostics=Array(entries.suffix(500)) }
            if let date=UserDefaults.standard.object(forKey:"lastContact") as? Date { lastContact=date }
        } catch { storageFailure() }
        UNUserNotificationCenter.current().delegate=self
        refreshPermissions()
        // Creating the manager at launch is required for Core Bluetooth restoration callbacks.
        manager=CBCentralManager(delegate:self,queue:.main,options:[CBCentralManagerOptionRestoreIdentifierKey:"dev.anbridge.ios.central.v1",CBCentralManagerOptionShowPowerAlertKey:true])
        ticker=Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in self?.tick() }
        if store != nil { drainJobs() }
    }
    private func log(_ code:String) {
        diagnostics.append(Diagnostic(at:Date(),code:code,count:history.count)); diagnostics=Array(diagnostics.suffix(500))
        if let directory,let bytes=try? JSONEncoder().encode(diagnostics) { try? bytes.write(to:directory.appendingPathComponent("diagnostics.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication]) }
    }
    func exportDiagnostics() {
        diagnosticsText=diagnostics.map { "\($0.at.ISO8601Format()) \($0.code) count=\($0.count)" }.joined(separator:"\n")
    }
    func refreshPermissions() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in DispatchQueue.main.async { self.bannersAllowed = settings.authorizationStatus == .authorized && settings.alertSetting == .enabled } }
    }
    func requestBanners() {
        UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound,.badge]) { _,_ in DispatchQueue.main.async { self.refreshPermissions() } }
    }
    func wake() {
        refreshPermissions()
        if store == nil {
            do {
                if directory == nil { directory=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("ANBridge",isDirectory:true) }
                try PairVault.resetForFreshInstall(directory:directory)
                try PairVault.completeErasureIfNeeded(directory:directory)
                store=try ReceiptStore(url:directory.appendingPathComponent("receipts.json"))
                candidate=try PairVault.read(); if candidate == nil { try store?.forget(); removeBanners() }; deviceName=candidate?.deviceName
            } catch { storageFailure(); return }
        }
        do { try store?.prune(now:Date().timeIntervalSince1970); history=store?.history ?? []; drainJobs(); if !ready { reconnect() } }
        catch { storageFailure() }
    }
    func pair(qr:String) {
        guard candidate == nil, store != nil else { errorMessage="Сначала удалите существующую привязку в настройках."; return }
        do {
            let parsed=try QRPair.parse(qr)
            let pair=PairCandidate(qr:parsed)
            try PairVault.save(pair); candidate=pair; rejected=[]; retryAttempt=0
            status="Подключение"; explanation="Поднесите телефоны друг к другу. Затем подтвердите привязку на Android."
            requestBanners(); reconnect()
        } catch { errorMessage="QR не подходит. Создайте новый QR в ANBridge на Android."; log("qr_invalid") }
    }
    func reconnect() {
        guard candidate != nil, store != nil, manager?.state == .poweredOn, peripheral == nil else { return }
        retry?.cancel()
        status="Подключение"
        if let id=candidate?.peripheralId.flatMap(UUID.init(uuidString:)), let known=manager.retrievePeripherals(withIdentifiers:[id]).first {
            connect(known)
        } else { manager.scanForPeripherals(withServices:[Self.service],options:[CBCentralManagerScanOptionAllowDuplicatesKey:false]) }
    }
    private func connect(_ p:CBPeripheral) {
        manager.stopScan(); peripheral=p; p.delegate=self; manager.connect(p,options:nil)
        // Keep a known-device connect pending while the phone is out of range; iOS may suspend us.
        handshakeDeadline=nil
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager) {
        switch central.state {
        case .poweredOn: reconnect()
        case .unauthorized: stopTransport(); status="Требуется разрешение"; explanation="Разрешите Bluetooth в Настройках → ANBridge."
        case .poweredOff: stopTransport(); status="Вне связи"; explanation="Включите Bluetooth в настройках iPhone."
        case .unsupported: stopTransport(); status="Требуется разрешение"; explanation="Bluetooth Low Energy недоступен на этом устройстве."
        default: stopTransport(); status=candidate == nil ? "Нет пары" : "Вне связи"
        }
    }
    func centralManager(_ central:CBCentralManager,willRestoreState dict:[String:Any]) {
        guard candidate != nil,store != nil else {
            (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.forEach { central.cancelPeripheralConnection($0) }; return
        }
        if let known=(dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first(where:{ $0.identifier.uuidString == candidate?.peripheralId }) {
            peripheral=known; known.delegate=self
            if known.state == .connected {
                // A restored physical link may still carry Android's old Noise state. Reopen it first.
                reconnectWhenClosed=known.identifier; central.cancelPeripheralConnection(known)
            } else { central.connect(known,options:nil) }
        }
    }
    func centralManager(_ central:CBCentralManager,didDiscover p:CBPeripheral,advertisementData:[String:Any],rssi RSSI:NSNumber) {
        guard peripheral == nil,!rejected.contains(p.identifier) else { return }; connect(p)
    }
    func centralManager(_ central:CBCentralManager,didConnect p:CBPeripheral) { beginDiscovery(p) }
    private func beginDiscovery(_ p:CBPeripheral) {
        resetSession(); p.delegate=self; p.discoverServices([Self.service]); handshakeDeadline=Date().addingTimeInterval(20)
    }
    func peripheral(_ p:CBPeripheral,didDiscoverServices error:Error?) {
        guard error == nil, let service=p.services?.first(where:{$0.uuid == Self.service}) else { fail(.framing); return }
        p.discoverCharacteristics([Self.dataUUID,Self.controlUUID],for:service)
    }
    func peripheral(_ p:CBPeripheral,didDiscoverCharacteristicsFor service:CBService,error:Error?) {
        guard error == nil else { fail(.framing); return }
        control=service.characteristics?.first(where:{$0.uuid == Self.controlUUID && $0.properties.contains(.write)})
        dataCharacteristic=service.characteristics?.first(where:{$0.uuid == Self.dataUUID && $0.properties.contains(.indicate)})
        guard control != nil,let dataCharacteristic else { fail(.framing); return }
        p.setNotifyValue(true,for:dataCharacteristic)
    }
    func peripheral(_ p:CBPeripheral,didUpdateNotificationStateFor characteristic:CBCharacteristic,error:Error?) {
        guard error == nil,characteristic.isNotifying,characteristic.uuid == Self.dataUUID,let candidate else { fail(.framing); return }
        do {
            session=try SecureSession(candidate:candidate,resume:candidate.confirmed || candidate.attempted)
            handshakePending=true
            try sendRaw(session!.start())
        } catch { fail(.authentication) }
    }
    func peripheral(_ p:CBPeripheral,didUpdateValueFor characteristic:CBCharacteristic,error:Error?) {
        guard error == nil,characteristic.uuid == Self.dataUUID,let value=characteristic.value else { fail(.framing); return }
        do {
            guard let complete=try assembler.receive(value,now:ProcessInfo.processInfo.systemUptime) else { return }
            guard let session else { throw BridgeError.ordering }
            if handshakePending {
                let third=try session.receiveHandshake(complete)
                guard var pair=candidate else { throw BridgeError.authentication }
                // Persist identical candidate before sending msg3; a lost READY must reconnect with this key.
                pair.attempted=true; pair.peripheralId=p.identifier.uuidString; pair.deviceName=p.name ?? "Android"
                do { try PairVault.save(pair) } catch { throw BridgeError.storage }; candidate=pair
                handshakePending=false
                try sendRaw(third) { [weak self] in
                    guard let self else { return }
                    do {
                        self.proposedFrameBytes=min(512,max(20,p.maximumWriteValueLength(for:.withResponse)))
                        try self.send(.hello(pairId:pair.pairId,maxFrameBytes:self.proposedFrameBytes))
                        self.handshakeDeadline=Date().addingTimeInterval(60)
                        self.explanation="Подтвердите привязку на Android. Ожидание — до 60 секунд."
                    } catch { self.fail(.framing) }
                }
            } else { try handle(Wire.decode(session.decrypt(complete))) }
        } catch let error as BridgeError { if error == .storage { storageFailure() } else { fail(error) } }
        catch { fail(.authentication) }
    }
    private func handle(_ message:Message) throws {
        do { try handleDurably(message) } catch let e as BridgeError { throw e } catch { throw BridgeError.storage }
    }
    private func handleDurably(_ message:Message) throws {
        guard let pair=candidate,let store else { throw BridgeError.storage }
        let now=Date().timeIntervalSince1970
        if !ready {
            guard case .ready(let id,let max)=message,id == pair.pairId,max <= proposedFrameBytes else { throw BridgeError.ordering }
            var confirmed=pair; confirmed.confirmed=true; confirmed.token=nil
            try PairVault.save(confirmed); candidate=confirmed
            // Core Bluetooth has acknowledged the final indication when it delivers this value.
            frameBytes=max; assembler.frameBytes=max; ready=true; retryAttempt=0; handshakeDeadline=nil
            status="Подключено"; deviceName=confirmed.deviceName; explanation="Выберите приложения на Android и отправьте тестовое сообщение."
            contact(); log("ready"); return
        }
        switch message {
        case .event(let event):
            _ = try store.receive(event,pairId:pair.pairId,now:now,suppressBanner:historyVisible && UIApplication.shared.applicationState == .active)
            history=store.history
            try send(.ack(event.eventId)); contact(); drainJobs()
        case .syncBegin(let batch): try store.beginBatch(batch,pairId:pair.pairId,now:now)
        case .syncEnd(let batch):
            try store.endBatch(batch,pairId:pair.pairId,now:now,suppressBanner:historyVisible && UIApplication.shared.applicationState == .active)
            try send(.syncAck(batch)); contact(); drainJobs()
        case .unlink: try eraseLocalPair(); stopTransport()
        default: throw BridgeError.ordering
        }
    }
    private func contact() { lastContact=Date(); UserDefaults.standard.set(lastContact,forKey:"lastContact") }
    private func send(_ message:Message,completion:(() -> Void)? = nil) throws {
        guard let session else { throw BridgeError.notReady }; try sendRaw(session.encrypt(Wire.encode(message)),completion:completion)
    }
    private func sendRaw(_ bytes:Data,completion:(() -> Void)? = nil) throws {
        guard peripheral != nil,control != nil else { throw BridgeError.framing }
        let tag=UUID().uuidString
        try writes.enqueue(bytes,frameBytes:frameBytes,completion:tag)
        completions[tag]=completion; writeNext()
    }
    private func writeNext() {
        guard let p=peripheral,let control,let frame=writes.nextFrame() else { return }
        writeStarted=Date(); p.writeValue(frame,for:control,type:.withResponse)
    }
    func peripheral(_ p:CBPeripheral,didWriteValueFor characteristic:CBCharacteristic,error:Error?) {
        guard p.identifier == peripheral?.identifier,characteristic.uuid == Self.controlUUID else { return }
        guard error == nil else { fail(.framing); return }
        do {
            writeStarted=nil
            if let tag=try writes.acknowledge() { completions.removeValue(forKey:tag)?() }
            writeNext()
        } catch { fail(.framing) }
    }
    func centralManager(_ central:CBCentralManager,didFailToConnect p:CBPeripheral,error:Error?) { disconnected(p,persistConnect:false) }
    func centralManager(_ central:CBCentralManager,didDisconnectPeripheral p:CBPeripheral,error:Error?) {
        if reconnectWhenClosed == p.identifier {
            reconnectWhenClosed=nil; peripheral=nil; resetSession(); scheduleReconnect(); return
        }
        disconnected(p,persistConnect:true)
    }
    private func disconnected(_ p:CBPeripheral,persistConnect:Bool) {
        guard peripheral?.identifier == p.identifier else { return }
        peripheral=nil; resetSession()
        guard candidate != nil,store != nil else { return }
        status="Вне связи"; explanation=candidate?.confirmed == true ? "Телефоны соединятся снова в зоне Bluetooth. После ручного закрытия откройте ANBridge." : "Если Android не сохранил пару, удалите её здесь и создайте новый QR."
        if persistConnect,manager.state == .poweredOn,candidate?.peripheralId == p.identifier.uuidString { connect(p) }
        else { scheduleReconnect() }
    }
    private func scheduleReconnect() {
        guard manager.state == .poweredOn,candidate != nil else { return }
        if UIApplication.shared.applicationState != .active {
            // A registered Core Bluetooth operation, unlike a Timer, can wake the suspended application.
            if let id=candidate?.peripheralId.flatMap(UUID.init(uuidString:)),let p=manager.retrievePeripherals(withIdentifiers:[id]).first { connect(p) }
            else { manager.scanForPeripherals(withServices:[Self.service],options:nil) }
            return
        }
        retry?.cancel(); let delay=min(60,pow(2,Double(min(retryAttempt,6))))*Double.random(in:0.8...1.2); retryAttempt += 1
        let work=DispatchWorkItem { [weak self] in self?.reconnect() }; retry=work; DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:work)
    }
    private func resetSession() {
        ready=false; handshakePending=false; session=nil; assembler=FrameAssembler(); frameBytes=20; writes=WriteQueue(); completions=[:]; writeStarted=nil; control=nil; dataCharacteristic=nil; handshakeDeadline=nil
    }
    private func stopTransport() {
        reconnectWhenClosed=nil; retry?.cancel(); manager?.stopScan()
        if let p=peripheral { manager?.cancelPeripheralConnection(p) }; peripheral=nil; resetSession()
    }
    private func fail(_ error:BridgeError) {
        log(error == .authentication ? "authentication" : error == .version ? "version" : "session_error")
        if error == .version { status="Несовместимая версия"; explanation="Обновите ANBridge на обоих телефонах." }
        else if error == .authentication {
            if let p=peripheral { rejected.insert(p.identifier) }
            explanation="Ключ Android не совпадает или привязка не завершена. Проверьте QR на Android."
        }
        let closing=peripheral?.identifier; stopTransport()
        if candidate != nil,error != .version {
            if error != .version { status="Вне связи" }
            if let closing { reconnectWhenClosed=closing }
            else { scheduleReconnect() }
        }
    }
    private func tick() {
        guard store != nil else { return }
        if let started=writeStarted,Date().timeIntervalSince(started) >= 15 { fail(.timeout); return }
        if let deadline=handshakeDeadline,Date() >= deadline { fail(.timeout); return }
        do { try assembler.checkIdle(now:ProcessInfo.processInfo.systemUptime) } catch { fail(.timeout) }
    }
    private func storageFailure() {
        store=nil; history=[]; status="Требуется разрешение"; explanation="Хранилище недоступно. Освободите место, разблокируйте iPhone и откройте ANBridge. Доставка не подтверждается."
        log("storage_error"); if manager != nil { stopTransport() }
    }
    private func drainJobs() {
        guard let store else { return }
        do {
            while let job=try store.startNextJob(now:Date().timeIntervalSince1970) {
                let content=UNMutableNotificationContent()
                if let e=job.event {
                    content.title=e.appName+(e.title.isEmpty ? "" : " · "+e.title)
                    content.body=e.privacy == "appOnly" || e.body.isEmpty ? "Новое уведомление" : e.body
                    if e.test == true { content.title="Тест · "+content.title }
                    content.userInfo=["eventId":e.eventId]; content.sound = .default
                } else {
                    content.title="ANBridge"; content.body="Получено пропущенных уведомлений: \(job.count)" // deliberately quiet
                }
                let request=UNNotificationRequest(identifier:job.id,content:content,trigger:nil)
                UNUserNotificationCenter.current().add(request) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        do { try self.store?.finishJob(job.id,now:Date().timeIntervalSince1970); if error != nil { self.log("banner_unavailable") } }
                        catch { self.storageFailure() }
                    }
                }
            }
        } catch { storageFailure() }
    }
    private func removeBanners() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
    func clearHistory() {
        do {
            try store?.clearHistory(now:Date().timeIntervalSince1970); history=store?.history ?? []
            UNUserNotificationCenter.current().removeAllDeliveredNotifications(); UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        } catch { storageFailure() }
    }
    func forget() {
        do {
            if ready { try send(.unlink) { [weak self] in self?.stopTransport() } }
            try eraseLocalPair()
            if writes.isEmpty { stopTransport() }
            else { DispatchQueue.main.asyncAfter(deadline:.now()+5) { [weak self] in self?.stopTransport() } }
        } catch { storageFailure() }
    }
    private func eraseLocalPair() throws {
        try PairVault.beginErasure(directory:directory)
        try PairVault.completeErasureIfNeeded(directory:directory)
        candidate=nil; store=try ReceiptStore(url:directory.appendingPathComponent("receipts.json")); history=[]; deviceName=nil; lastContact=nil
        UserDefaults.standard.removeObject(forKey:"lastContact")
        status="Нет пары"; explanation="Создайте новый QR на Android, чтобы связать телефоны."
        UNUserNotificationCenter.current().removeAllDeliveredNotifications(); UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
    func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler completionHandler:@escaping () -> Void) {
        DispatchQueue.main.async {
            self.selectedTab=1; self.route=response.notification.request.content.userInfo["eventId"] as? String
            completionHandler()
        }
    }
    func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(historyVisible ? [] : [.banner,.list,.sound])
    }
}
