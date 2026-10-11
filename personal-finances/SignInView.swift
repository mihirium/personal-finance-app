//
//  SignInView.swift
//  personal-finances
//
//  Created by Codex on 8/30/26.
//

import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @State private var username = ""

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "creditcard.and.123")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.tint)

                Text("Personal Finances")
                    .font(.largeTitle.bold())

                Text("Sign in with a username to view your purchase history.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await authViewModel.signIn(username: username) }
                } label: {
                    Text("Log In")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(authViewModel.isSubmitting)

                Button {
                    Task { await authViewModel.signUp(username: username) }
                } label: {
                    Text("Sign Up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(authViewModel.isSubmitting)
            }
            .frame(maxWidth: 320)

            if authViewModel.isSubmitting {
                ProgressView()
            }

            if let errorMessage = authViewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .padding()
    }
}
