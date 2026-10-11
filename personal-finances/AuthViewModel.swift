//
//  AuthViewModel.swift
//  personal-finances
//
//  Created by Codex on 8/30/26.
//

import Foundation

@MainActor
final class AuthViewModel: ObservableObject {
    @Published private(set) var user: AppUser?
    @Published private(set) var isRestoringSession = true
    @Published private(set) var isSubmitting = false
    @Published var errorMessage: String?

    private let authClient = SimpleAuthClient()
    private let userIDKey = "appUserID"
    private let usernameKey = "appUsername"

    var isSignedIn: Bool {
        user != nil
    }

    func restoreSession() {
        defer { isRestoringSession = false }

        guard
            let userID = UserDefaults.standard.string(forKey: userIDKey),
            let username = UserDefaults.standard.string(forKey: usernameKey)
        else {
            return
        }

        user = AppUser(userID: userID, username: username)
    }

    func signIn(username: String) async {
        await submit(username: username, action: authClient.signIn(username:))
    }

    func signUp(username: String) async {
        await submit(username: username, action: authClient.signUp(username:))
    }

    func signOut() {
        UserDefaults.standard.removeObject(forKey: userIDKey)
        UserDefaults.standard.removeObject(forKey: usernameKey)
        user = nil
        errorMessage = nil
    }

    private func submit(username: String, action: (String) async throws -> AppUser) async {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            errorMessage = "Enter a username."
            return
        }

        isSubmitting = true
        errorMessage = nil

        do {
            let user = try await action(trimmedUsername)
            UserDefaults.standard.set(user.userID, forKey: userIDKey)
            UserDefaults.standard.set(user.username, forKey: usernameKey)
            self.user = user
        } catch {
            errorMessage = error.localizedDescription
        }

        isSubmitting = false
    }
}

struct AppUser: Codable, Equatable {
    let userID: String
    let username: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case username
    }
}

private final class SimpleAuthClient {
    private let baseURL = URL(string: "http://127.0.0.1:8000")!
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func signIn(username: String) async throws -> AppUser {
        try await sendAuthRequest(path: "api/users/sign-in", username: username)
    }

    func signUp(username: String) async throws -> AppUser {
        try await sendAuthRequest(path: "api/users/sign-up", username: username)
    }

    private func sendAuthRequest(path: String, username: String) async throws -> AppUser {
        let endpoint = baseURL.appending(path: path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(AuthRequest(username: username))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimpleAuthError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data) {
                throw SimpleAuthError.requestFailed(errorResponse.error)
            }

            throw SimpleAuthError.requestFailed("Request failed with status \(httpResponse.statusCode).")
        }

        return try decoder.decode(AuthResponse.self, from: data).user
    }
}

private struct AuthRequest: Encodable {
    let username: String
}

private struct AuthResponse: Decodable {
    let user: AppUser
}

private struct ErrorResponse: Decodable {
    let error: String
}

private enum SimpleAuthError: LocalizedError {
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The server returned an invalid response."
        case .requestFailed(let message):
            message
        }
    }
}
