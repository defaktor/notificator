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
    private var recovery=ConnectionRecovery()
    private var retryAfterClose=false
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
    var versionDescription:String {
        let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown"
        let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown"
        return "\(version) (\(build))"
    }
    private var transportState:String {
        if recovery.closing != nil { return "closing" }
        if ready { return "ready" }
        if let peripheral {
            switch peripheral.state {
            case .connecting: return "connecting"
            case .connected: return "handshake"
            case .disconnecting: return "disconnecting"
            case .disconnected: return "disconnected"
            @unknown default: return "unknown"
            }
        }
        return manager?.isScanning == true ? "scanning" : "idle"
    }
    func exportDiagnostics() {
        let bluetooth=manager?.state.rawValue ?? -1
        let header="ANBridge \(versionDescription) diagnostics\nbluetoothState=\(bluetooth) transport=\(transportState) paired=\(candidate != nil) ready=\(ready) foreground=\(UIApplication.shared.applicationState == .active)\n"
        diagnosticsText=header+diagnostics.map { "\($0.at.ISO8601Format()) \($0.code) count=\($0.count)" }.joined(separator:"\n")
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
    /// Automatic recovery leaves a known-device connection registered in the background.
    func reconnect() { requestReconnect(manual:false) }
    /// A deliberate retry also recovers from a stale, indefinitely pending CBPeripheral.
    func retryConnection() {
        log("manual_recovery"); rejected=[]; retryAttempt=0; retryAfterClose=false
        requestReconnect(manual:true)
    }
    private var transportAvailable:Bool { candidate != nil && store != nil && manager?.state == .poweredOn }
    private func requestReconnect(manual:Bool) {
        let action=recovery.request(manual:manual,available:transportAvailable,current:peripheral?.identifier,ready:ready)
        applyRecovery(action)
        observePendingDiscovery()
    }
    private func applyRecovery(_ action:ConnectionRecovery.Action) {
        guard action != .none else { return }
        retry?.cancel(); retry=nil
        switch action {
        case .none: break
        case .cancel:
            guard let p=peripheral else { return }
            manager.stopScan(); resetSession()
            status="Подключение"; explanation="Закрываем прежнюю попытку и заново ищем Android рядом."
            log("cancel_for_scan")
            // Keep ownership until the terminal callback. Otherwise its late arrival
            // could reset a newly discovered connection to the same device.
            manager.cancelPeripheralConnection(p)
        case .known:
            status="Подключение"
            if let id=candidate?.peripheralId.flatMap(UUID.init(uuidString:)),let known=manager.retrievePeripherals(withIdentifiers:[id]).first {
                connect(known,observeDiscovery:true)
            } else { startScan() }
        case .scan: startScan()
        }
    }
    private func startScan() {
        guard transportAvailable,peripheral == nil,recovery.closing == nil else { return }
        manager.stopScan(); status="Подключение"
        explanation="Ищем ANBridge на Android рядом по Bluetooth. Откройте приложение на Android."
        manager.scanForPeripherals(withServices:[Self.service],options:[CBCentralManagerScanOptionAllowDuplicatesKey:false])
        log("scan_started")
    }
    private func connect(_ p:CBPeripheral,observeDiscovery:Bool=false) {
        guard transportAvailable,recovery.closing == nil,peripheral == nil else { return }
        manager.stopScan(); peripheral=p; p.delegate=self
        recovery.started(p.identifier,now:ProcessInfo.processInfo.systemUptime,observeDiscovery:observeDiscovery)
        manager.connect(p,options:nil); log("connect_pending")
        // A background pending operation can wake us. A foreground attempt gets a
        // bounded rediscovery fallback in tick(), since BLE addresses can change.
        handshakeDeadline=nil
        observePendingDiscovery()
    }
    private func observePendingDiscovery() {
        guard recovery.shouldObserveDiscovery(available:transportAvailable,current:peripheral?.identifier,ready:ready),!manager.isScanning else { return }
        manager.scanForPeripherals(withServices:[Self.service],options:[CBCentralManagerScanOptionAllowDuplicatesKey:false])
        log("known_pending_scan")
    }
    private func owns(_ p:CBPeripheral) -> Bool {
        peripheral === p && recovery.acceptsCallback(from:p.identifier,current:peripheral?.identifier)
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager) {
        guard central === manager else { return }
        switch central.state {
        case .poweredOn: reconnect()
        case .unauthorized: stopTransport(); status="Требуется разрешение"; explanation="Разрешите Bluetooth в Настройках → ANBridge."
        case .poweredOff: stopTransport(); status="Вне связи"; explanation="Включите Bluetooth в настройках iPhone."
        case .unsupported: stopTransport(); status="Требуется разрешение"; explanation="Bluetooth Low Energy недоступен на этом устройстве."
        default: stopTransport(); status=candidate == nil ? "Нет пары" : "Вне связи"
        }
    }
    func centralManager(_ central:CBCentralManager,willRestoreState dict:[String:Any]) {
        guard central === manager else { return }
        guard candidate != nil,store != nil else {
            (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.forEach { central.cancelPeripheralConnection($0) }; return
        }
        if let known=(dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first(where:{ $0.identifier.uuidString == candidate?.peripheralId }) {
            peripheral=known; known.delegate=self
            log("transport_restored")
            switch known.state {
            case .connected,.disconnecting:
                // A restored physical link may still carry Android's old Noise state.
                // Wait for its closure before constructing a new session.
                recovery.restored(known.identifier,connected:true,now:ProcessInfo.processInfo.systemUptime)
                reconnect()
            case .connecting:
                // Core Bluetooth already owns this pending operation.
                recovery.restored(known.identifier,connected:false,now:ProcessInfo.processInfo.systemUptime)
                observePendingDiscovery()
            case .disconnected:
                peripheral=nil
                reconnect()
            @unknown default: stopTransport()
            }
        }
    }
    func centralManager(_ central:CBCentralManager,didDiscover p:CBPeripheral,advertisementData:[String:Any],rssi RSSI:NSNumber) {
        guard central === manager,transportAvailable,recovery.closing == nil,!rejected.contains(p.identifier) else { return }
        if let pending=peripheral {
            let action=recovery.discoveryWhilePending(available:transportAvailable,current:pending.identifier,ready:ready)
            if action != .none { log("known_pending_rediscovered"); applyRecovery(action) }
            return
        }
        log("service_discovered"); connect(p)
    }
    func centralManager(_ central:CBCentralManager,didConnect p:CBPeripheral) {
        guard central === manager,owns(p) else {
            if central === manager { central.cancelPeripheralConnection(p) }
            log("stale_connect_ignored"); return
        }
        manager.stopScan(); recovery.linkConnected(p.identifier); log("link_connected"); beginDiscovery(p)
    }
    private func beginDiscovery(_ p:CBPeripheral) {
        resetSession(); p.delegate=self; p.discoverServices([Self.service]); handshakeDeadline=Date().addingTimeInterval(20)
    }
    func peripheral(_ p:CBPeripheral,didDiscoverServices error:Error?) {
        guard owns(p) else { return }
        guard error == nil, let service=p.services?.first(where:{$0.uuid == Self.service}) else { fail(.framing); return }
        p.discoverCharacteristics([Self.dataUUID,Self.controlUUID],for:service)
    }
    func peripheral(_ p:CBPeripheral,didDiscoverCharacteristicsFor service:CBService,error:Error?) {
        guard owns(p) else { return }
        guard error == nil else { fail(.framing); return }
        control=service.characteristics?.first(where:{$0.uuid == Self.controlUUID && $0.properties.contains(.write)})
        dataCharacteristic=service.characteristics?.first(where:{$0.uuid == Self.dataUUID && $0.properties.contains(.indicate)})
        guard control != nil,let dataCharacteristic else { fail(.framing); return }
        p.setNotifyValue(true,for:dataCharacteristic)
    }
    func peripheral(_ p:CBPeripheral,didUpdateNotificationStateFor characteristic:CBCharacteristic,error:Error?) {
        guard owns(p),characteristic === dataCharacteristic else { return }
        guard error == nil,characteristic.isNotifying,characteristic.uuid == Self.dataUUID,let candidate else { fail(.framing); return }
        do {
            session=try SecureSession(candidate:candidate,resume:candidate.confirmed || candidate.attempted)
            handshakePending=true
            try sendRaw(session!.start())
        } catch { fail(.authentication) }
    }
    func peripheral(_ p:CBPeripheral,didUpdateValueFor characteristic:CBCharacteristic,error:Error?) {
        guard owns(p),characteristic === dataCharacteristic else { return }
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
            recovery.authenticated()
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
        guard owns(p),characteristic === control,characteristic.uuid == Self.controlUUID else { return }
        guard error == nil else { fail(.framing); return }
        do {
            writeStarted=nil
            if let tag=try writes.acknowledge() { completions.removeValue(forKey:tag)?() }
            writeNext()
        } catch { fail(.framing) }
    }
    func centralManager(_ central:CBCentralManager,didFailToConnect p:CBPeripheral,error:Error?) {
        guard central === manager else { return }
        disconnected(p,failed:true)
    }
    func centralManager(_ central:CBCentralManager,didDisconnectPeripheral p:CBPeripheral,error:Error?) {
        guard central === manager else { return }
        disconnected(p,failed:false)
    }
    private func disconnected(_ p:CBPeripheral,failed:Bool) {
        guard peripheral === p else { return }
        let requestedClose=recovery.isClosing(p.identifier)
        guard recovery.closed(p.identifier) else { return }
        let shouldDelay=retryAfterClose; retryAfterClose=false
        p.delegate=nil; peripheral=nil; resetSession()
        log(requestedClose ? "retry_transport_closed" : failed ? "connect_failed" : "link_disconnected")
        guard candidate != nil,store != nil else { return }
        status="Вне связи"; explanation=candidate?.confirmed == true ? "Телефоны соединятся снова в зоне Bluetooth. После ручного закрытия откройте ANBridge." : "Если Android не сохранил пару, удалите её здесь и создайте новый QR."
        if requestedClose { if shouldDelay { scheduleReconnect() } else { reconnect() } }
        else if !failed,transportAvailable { reconnect() }
        else { recovery.preferDiscovery(); scheduleReconnect() }
    }
    private func scheduleReconnect() {
        guard transportAvailable,peripheral == nil,recovery.closing == nil else { return }
        if UIApplication.shared.applicationState != .active {
            // A registered Core Bluetooth operation, unlike a Timer, can wake the suspended application.
            reconnect(); return
        }
        retry?.cancel(); let delay=min(60,pow(2,Double(min(retryAttempt,6))))*Double.random(in:0.8...1.2); retryAttempt += 1
        log("retry_scheduled")
        let work=DispatchWorkItem { [weak self] in self?.reconnect() }; retry=work; DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:work)
    }
    private func resetSession() {
        ready=false; handshakePending=false; session=nil; assembler=FrameAssembler(); frameBytes=20; writes=WriteQueue(); completions=[:]; writeStarted=nil; control=nil; dataCharacteristic=nil; handshakeDeadline=nil
    }
    private func stopTransport() {
        retry?.cancel(); retry=nil; manager?.stopScan()
        if let p=peripheral { p.delegate=nil; manager?.cancelPeripheralConnection(p) }
        peripheral=nil; retryAfterClose=false; recovery.stopped(); resetSession()
    }
    private func fail(_ error:BridgeError) {
        log(error == .authentication ? "authentication" : error == .version ? "version" : "session_error")
        if error == .version { status="Несовместимая версия"; explanation="Обновите ANBridge на обоих телефонах." }
        else if error == .authentication {
            if let p=peripheral { rejected.insert(p.identifier) }
            explanation="Ключ Android не совпадает или привязка не завершена. Проверьте QR на Android."
        }
        guard error != .version,transportAvailable else { stopTransport(); return }
        status="Вне связи"
        // Cancel through the same close fence as a manual retry, then rediscover.
        retryAfterClose=true
        requestReconnect(manual:true)
    }
    private func tick() {
        guard store != nil else { return }
        let recoveryAction=recovery.check(now:ProcessInfo.processInfo.systemUptime,
            foreground:UIApplication.shared.applicationState == .active,available:transportAvailable,
            current:peripheral?.identifier,ready:ready)
        if recoveryAction != .none { log("connect_scan_fallback"); applyRecovery(recoveryAction); return }
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
