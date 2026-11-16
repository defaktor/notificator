import SwiftUI
import UIKit

final class AppDelegate:NSObject,UIApplicationDelegate {
    func application(_ application:UIApplication,didFinishLaunchingWithOptions launchOptions:[UIApplication.LaunchOptionsKey:Any]? = nil) -> Bool { _ = BridgeModel.shared; return true }
}
@main struct ANBridgeApp:App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model=BridgeModel.shared
    @Environment(\.scenePhase) private var scenePhase
    var body:some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .onChange(of:scenePhase) { _, phase in
                    if phase == .active { model.wake() }
                    else { model.historyVisible=false }
                }
        }
    }
}
