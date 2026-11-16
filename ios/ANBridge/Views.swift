import SwiftUI
import AVFoundation
import ANBridgeCore

struct RootView:View {
    @EnvironmentObject var model:BridgeModel
    var body:some View {
        TabView(selection:$model.selectedTab) {
            ConnectionView().tabItem { Label("Подключение",systemImage:"antenna.radiowaves.left.and.right") }.tag(0)
            HistoryView().tabItem { Label("История",systemImage:"tray.full") }.tag(1)
            HelpView().tabItem { Label("Помощь",systemImage:"questionmark.circle") }.tag(2)
            SettingsView().tabItem { Label("Настройки",systemImage:"gearshape") }.tag(3)
        }
        .tint(.indigo)
        .alert("ANBridge",isPresented:Binding(get:{ model.errorMessage != nil },set:{ if !$0 { model.errorMessage=nil } })) { Button("Понятно",role:.cancel) { model.errorMessage=nil } } message:{ Text(model.errorMessage ?? "") }
    }
}
struct StatusCard:View {
    @EnvironmentObject var model:BridgeModel
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Label(model.status,systemImage:model.status == "Подключено" ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right.slash")
                .font(.title3.weight(.semibold)).foregroundStyle(model.status == "Подключено" ? Color.green : Color.primary)
            if let name=model.deviceName { Text(name).font(.headline) }
            Text(model.explanation).font(.subheadline).foregroundStyle(.secondary)
            if let date=model.lastContact { Text("Последний контакт: \(date.formatted(date:.abbreviated,time:.standard))").font(.caption).foregroundStyle(.secondary) }
            else { Text("Успешного обмена ещё не было").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,8)
    }
}
struct ConnectionView:View {
    @EnvironmentObject var model:BridgeModel
    @State private var scanner=false
    @State private var cameraDenied=false
    var body:some View {
        NavigationStack {
            List {
                Section { StatusCard() }
                Section("Два телефона. Один поток уведомлений.") {
                    Label("Android передаёт название приложения, заголовок и доступный текст.",systemImage:"text.bubble")
                    Label("Bluetooth соединяет телефоны напрямую. Интернет и учётная запись не нужны.",systemImage:"network.slash")
                    Label("Камера нужна только для QR. Баннеры показывает ANBridge от имени приложения iPhone.",systemImage:"qrcode.viewfinder")
                }.font(.subheadline)
                Section {
                    if !model.hasPair {
                        Button { openCamera() } label:{ Label("Сканировать QR с Android",systemImage:"qrcode.viewfinder").font(.headline).padding(.vertical,8) }
                    } else {
                        Button { model.retryConnection() } label:{ Label("Подключиться снова",systemImage:"arrow.clockwise") }
                        Text("После подтверждения владельцем отправьте тест в ANBridge на Android. Он должен появиться в истории.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if !model.bannersAllowed {
                        Button("Разрешить уведомления") { model.requestBanners() }
                        SettingsLink()
                        Text("При запрещённых баннерах история продолжает работать.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("ANBridge")
                .sheet(isPresented:$scanner) { QRScanner { code in scanner=false; model.pair(qr:code) } }
                .alert("Нет доступа к камере",isPresented:$cameraDenied) {
                    Button("Открыть настройки") { UIApplication.shared.open(URL(string:UIApplication.openSettingsURLString)!) }
                    Button("Отмена",role:.cancel) {}
                } message:{ Text("Разрешите камеру для сканирования QR с Android.") }
        }
    }
    private func openCamera() {
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized: scanner=true
        case .notDetermined: AVCaptureDevice.requestAccess(for:.video) { allowed in DispatchQueue.main.async { if allowed { scanner=true } else { cameraDenied=true } } }
        default: cameraDenied=true
        }
    }
}
struct HistoryView:View {
    @EnvironmentObject var model:BridgeModel
    @Environment(\.scenePhase) private var phase
    @State private var path:[String]=[]
    @State private var confirmClear=false
    var body:some View {
        NavigationStack(path:$path) {
            Group {
                if model.history.isEmpty {
                    ContentUnavailableView("Пока нет уведомлений",systemImage:"tray",description:Text("Свяжите телефоны, выберите приложения на Android и отправьте тест."))
                } else {
                    List(model.history) { record in
                        NavigationLink(value:record.id) { EventRow(record:record) }
                    }
                }
            }
            .navigationTitle("История")
            .navigationDestination(for:String.self) { id in
                if let record=model.history.first(where:{$0.id == id}) { DetailView(record:record) }
                else { ContentUnavailableView("Запись удалена",systemImage:"tray",description:Text("Другие уведомления доступны в истории.")) }
            }
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Очистить",role:.destructive) { confirmClear=true }.disabled(model.history.isEmpty) } }
            .confirmationDialog("Очистить историю и связанные баннеры?",isPresented:$confirmClear,titleVisibility:.visible) {
                Button("Очистить историю",role:.destructive) { model.clearHistory(); path=[] }
                Button("Отмена",role:.cancel) {}
            } message:{ Text("Повторы уже принятых событий не вернут удалённые записи.") }
        }
        .onAppear { model.historyVisible=phase == .active; openRoute() }
        .onDisappear { model.historyVisible=false }
        .onChange(of:phase) { _, phase in model.historyVisible=phase == .active && model.selectedTab == 1 }
        .onChange(of:model.route) { _,_ in openRoute() }
        .onChange(of:model.selectedTab) { _, tab in model.historyVisible=tab == 1 && phase == .active; if tab == 1 { openRoute() } }
    }
    private func openRoute() {
        guard model.selectedTab == 1,let id=model.route else { return }
        if model.history.contains(where:{$0.id == id}) { path=[id] } else { path=[] }
        model.route=nil
    }
}
struct EventRow:View {
    let record:HistoryRecord
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {
                Text(record.event.appName).font(.subheadline.weight(.semibold)).foregroundStyle(.indigo)
                Spacer()
                Text(Date(timeIntervalSince1970:Double(record.event.occurredAt)/1000),style:.time).font(.caption).foregroundStyle(.secondary)
            }
            if record.event.test == true { Label("Тестовое уведомление",systemImage:"checkmark.seal").font(.caption) }
            if !record.event.title.isEmpty { Text(record.event.title).font(.headline).lineLimit(1) }
            Text(record.event.body.isEmpty ? "Новое уведомление" : record.event.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            if record.event.delayed { Label("Доставлено с задержкой",systemImage:"clock.arrow.circlepath").font(.caption2).foregroundStyle(.secondary) }
        }.padding(.vertical,5)
    }
}
struct DetailView:View {
    let record:HistoryRecord
    var body:some View {
        List {
            Section(record.event.appName) {
                if !record.event.title.isEmpty { Text(record.event.title).font(.title3.weight(.semibold)) }
                Text(record.event.body.isEmpty ? "Новое уведомление" : record.event.body).textSelection(.enabled)
            }
            Section("Доставка") {
                LabeledContent("Время Android",value:Date(timeIntervalSince1970:Double(record.event.occurredAt)/1000).formatted(date:.abbreviated,time:.standard))
                LabeledContent("Принято iPhone",value:Date(timeIntervalSince1970:record.receivedAt).formatted(date:.abbreviated,time:.standard))
                LabeledContent("Режим",value:record.event.privacy == "appOnly" ? "Только название" : "Название и текст")
                if record.event.delayed { Label("Доставлено после восстановления связи",systemImage:"clock.arrow.circlepath") }
                if record.event.truncated == true { Text("Длинный текст сокращён на Android.").foregroundStyle(.secondary) }
                if record.event.test == true { Label("Тест по защищённому каналу",systemImage:"checkmark.shield") }
            }
        }.navigationTitle("Уведомление").navigationBarTitleDisplayMode(.inline)
    }
}
struct HelpView:View {
    @EnvironmentObject var model:BridgeModel
    var body:some View {
        NavigationStack {
            List {
                Section("Состояние") { StatusCard(); SettingsLink() }
                Section("Если уведомления не приходят") {
                    Text("1. Включите Bluetooth на обоих телефонах и держите их рядом.")
                    Text("2. На Android разрешите доступ к уведомлениям и выберите приложения в «Источниках».")
                    Text("3. Проверьте, что пересылка на Android не приостановлена. После паузы старые события не восстанавливаются.")
                    Text("4. Для баннеров разрешите уведомления ANBridge в iOS. Focus, звук и предпросмотр на экране блокировки управляются системой.")
                    Text("5. После ручного закрытия ANBridge откройте его снова. После перезагрузки сначала разблокируйте iPhone и при необходимости откройте приложение.")
                }
                Section("Что означают статусы") {
                    HelpRow(title:"Нет пары",body:"Создайте QR в ANBridge на Android и отсканируйте его здесь.")
                    HelpRow(title:"Подключение",body:"Поднесите телефоны ближе. При первом подключении подтвердите запрос на Android.")
                    HelpRow(title:"Подключено",body:"Защищённая сессия готова. Отправьте тест на Android.")
                    HelpRow(title:"Вне связи",body:"Очередь Android хранится до 24 часов, максимум 1000 событий. Связь восстанавливается с учётом возможностей ОС.")
                    HelpRow(title:"Приостановлено",body:"Возобновите пересылку в ANBridge на Android. Пауза удаляет его очередь.")
                    HelpRow(title:"Требуется разрешение",body:"Откройте системные настройки. Если недоступно хранилище, разблокируйте iPhone и освободите место.")
                    HelpRow(title:"Несовместимая версия",body:"Обновите приложения на обоих телефонах.")
                }
                Section("Ограничения системы") {
                    Text("iOS может задерживать фоновую работу или не перезапускать приложение автоматически. Восстановление Core Bluetooth не гарантирует запуск после ручного закрытия; правила зависят от версии iOS и настройки аксессуара. В таком случае откройте ANBridge.")
                    Text("На Android пересылается только доступный приложению текст. Скрытое содержимое и рабочий профиль могут быть недоступны. Ответы и действия из уведомлений не поддерживаются.")
                }
            }.navigationTitle("Помощь")
        }
    }
}
struct HelpRow:View {
    let title:String,message:String
    init(title:String,body:String) { self.title=title; self.message=body }
    var body:some View { VStack(alignment:.leading,spacing:4) { Text(title).font(.headline); Text(message).font(.subheadline).foregroundStyle(.secondary) } }
}
struct SettingsLink:View {
    var body:some View { Button { UIApplication.shared.open(URL(string:UIApplication.openSettingsURLString)!) } label:{ Label("Открыть настройки iOS",systemImage:"arrow.up.forward.app") } }
}
struct SettingsView:View {
    @EnvironmentObject var model:BridgeModel
    @State private var clear=false
    @State private var forget=false
    var body:some View {
        NavigationStack {
            List {
                Section("Уведомления") {
                    LabeledContent("Баннеры",value:model.bannersAllowed ? "Разрешены" : "Отключены")
                    Button("Запросить разрешение") { model.requestBanners() }; SettingsLink()
                }
                Section("Данные на iPhone") {
                    Text("История: до 1000 записей и до 7 суток. Содержимое защищено системой iOS и исключено из резервных копий. После переустановки требуется новая привязка.").font(.subheadline)
                    Button("Очистить историю",role:.destructive) { clear=true }
                    Button("Забыть Android",role:.destructive) { forget=true }.disabled(!model.hasPair)
                }
                Section("Диагностика") {
                    Text("До 500 технических записей без текста сообщений, названий источников, ключей и QR.").font(.footnote).foregroundStyle(.secondary)
                    Button("Подготовить экспорт") { model.exportDiagnostics() }
                    if !model.diagnosticsText.isEmpty { ShareLink(item:model.diagnosticsText) { Label("Поделиться диагностикой",systemImage:"square.and.arrow.up") } }
                }
                Section { LabeledContent("ANBridge",value:model.versionDescription); Text("Работает локально, без сервера и учётной записи.").font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle("Настройки")
            .confirmationDialog("Очистить историю и баннеры?",isPresented:$clear,titleVisibility:.visible) {
                Button("Очистить историю",role:.destructive) { model.clearHistory() }; Button("Отмена",role:.cancel) {}
            }
            .confirmationDialog("Забыть Android?",isPresented:$forget,titleVisibility:.visible) {
                Button("Забыть Android",role:.destructive) { model.forget() }; Button("Отмена",role:.cancel) {}
            } message:{ Text("Привязка, история и ключи будут удалены. Если Android вне связи, удалите его локальную копию привязки на нём. Для новой пары нужен новый QR.") }
        }
    }
}
