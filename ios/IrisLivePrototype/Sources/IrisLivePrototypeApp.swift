//
//  IrisLivePrototypeApp.swift
//  IrisLivePrototype
//

import SwiftUI

@main
struct IrisLivePrototypeApp: App {
    /// The only UIKit in the app. SwiftUI has no hook for the remote-
    /// notification registration callbacks, and the notification-centre
    /// delegate has to be installed before launch finishes or a tap from a
    /// cold start never arrives. See PushService.swift.
    @UIApplicationDelegateAdaptor(IrisAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
