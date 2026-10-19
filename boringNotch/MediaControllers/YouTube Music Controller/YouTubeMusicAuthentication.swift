//
//  YouTubeMusicAuthentication.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-14.
//

import Foundation

// MARK: - Authentication Manager
actor YouTubeMusicAuthManager {
    private var accessToken: String?
    private var authenticationTask: Task<String, Error>?
    private let httpClient: YouTubeMusicHTTPClient
    
    init(httpClient: YouTubeMusicHTTPClient) {
        self.httpClient = httpClient
    }
    
    var currentToken: String? {
        accessToken
    }
    
    private var revision = 0

    func authenticate() async throws -> String {
        let stamp = revision
        if let token = accessToken { return token }
        if let task = authenticationTask {
            let token = try await task.value
            guard stamp == revision else { throw CancellationError() }
            return token
        }
        let client = httpClient
        let task = Task<String, Error> {
            let token = try await client.authenticate()
            try Task.checkCancellation()
            return token
        }
        authenticationTask = task
        do {
            let token = try await task.value
            guard stamp == revision else { throw CancellationError() }
            accessToken = token
            authenticationTask = nil
            return token
        } catch {
            if stamp == revision { authenticationTask = nil }
            throw error
        }
    }

    func invalidateToken() {
        revision += 1
        accessToken = nil
        authenticationTask?.cancel()
        authenticationTask = nil
    }

}

// MARK: - Authentication State
enum AuthenticationState: Sendable {
    case unauthenticated
    case authenticating
    case authenticated(String)
    case failed(Error)
    
    var isAuthenticated: Bool {
        if case .authenticated = self {
            return true
        }
        return false
    }
    
    var token: String? {
        if case .authenticated(let token) = self {
            return token
        }
        return nil
    }
}