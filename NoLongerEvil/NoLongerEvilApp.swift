//
//  NoLongerEvilApp.swift
//  NoLongerEvil
//
//  Created by Trevor Pease on 2/20/26.
//

import SwiftUI

@main
struct NoLongerEvilApp: App {
    private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(AppStore(settings: settings))
        }
    }
}

