//
//  RootView.swift
//  personal-finances
//
//  Created by Codex on 8/30/26.
//

import SwiftUI

struct RootView: View {
    @StateObject private var authViewModel = AuthViewModel()

    var body: some View {
        Group {
            if authViewModel.isRestoringSession {
                ProgressView("Checking sign-in")
            } else if authViewModel.isSignedIn {
                ContentView()
                    .environmentObject(authViewModel)
            } else {
                SignInView()
                    .environmentObject(authViewModel)
            }
        }
        .onAppear {
            authViewModel.restoreSession()
        }
    }
}
