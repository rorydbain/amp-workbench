import Foundation
import Security

public struct SoundResearchSource: Codable, Hashable, Sendable {
    public let title: String
    public let url: URL
    public let excerpt: String
}

public struct SoundResearchResponse: Codable, Sendable {
    public let query: String
    public let sources: [SoundResearchSource]
    public let basis: String
}

public struct CloudSoundResponse: Codable, Sendable {
    public let intent: SoundDesignIntent
    public let research: SoundResearchResponse?
    public let researchStatus: String
    public let promptTrace: CloudPromptTrace?
}

public struct CloudPromptTrace: Codable, Sendable {
    public let model: String
    public let systemPrompt: String
    public let userPrompt: String
    public let rawResponse: String?
}

public enum SoundAIMode: String, CaseIterable, Identifiable {
    case appleIntelligence = "On-device" // retain the existing saved setting
    case localRules = "Local rules"
    case cloud = "Cloud"
    case openAI = "My OpenAI key"
    public var id: String { rawValue }
    public var title: String { self == .appleIntelligence ? "Apple Intelligence" : rawValue }
}

/// One explicit research request per sound creation; typing in search never calls the web.
public enum SoundResearchClient {
    public static var serviceBaseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AmpWorkbenchServiceBaseURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    public static var isConfigured: Bool { serviceBaseURL != nil }

    public static func serviceURL(_ path: String) -> URL? {
        serviceBaseURL?.appending(path: path)
    }

    public static func search(_ query: String, endpoint: URL? = nil) async throws -> SoundResearchResponse {
        guard let endpoint = endpoint ?? serviceURL("v1/research") else {
            throw AmpError("No hosted sound service is configured for this build.")
        }
        let data = try await post(query, endpoint: endpoint)
        let result = try JSONDecoder().decode(SoundResearchResponse.self, from: data)
        return SoundResearchResponse(query: result.query, sources: Array(result.sources.prefix(5)), basis: result.basis)
    }
    public static func design(_ query: String) async throws -> CloudSoundResponse {
        guard let endpoint = serviceURL("v1/design") else {
            throw AmpError("No hosted sound service is configured for this build.")
        }
        let data = try await post(query, endpoint: endpoint)
        return try JSONDecoder().decode(CloudSoundResponse.self, from: data)
    }
    public static func refine(_ query: String, current: SoundDesignIntent) async throws -> CloudSoundResponse {
        guard let endpoint = serviceURL("v1/refine") else {
            throw AmpError("No hosted sound service is configured for this build.")
        }
        let data = try await post(query, endpoint: endpoint, current: current)
        return try JSONDecoder().decode(CloudSoundResponse.self, from: data)
    }
    private static func post(_ query: String, endpoint: URL, current: SoundDesignIntent? = nil) async throws -> Data {
        guard let key = ResearchAccessKey.load(), !key.isEmpty else {
            throw AmpError("Add your private AI key in Connection to enable cloud AI.")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let current {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": String(query.prefix(200)),
                "current": JSONSerialization.jsonObject(with: JSONEncoder().encode(current))
            ])
        } else {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": String(query.prefix(200))])
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AmpError("Cloud AI did not respond.") }
        if http.statusCode == 403 { throw AmpError("The private AI key was rejected. Check it in Settings.") }
        if http.statusCode == 429 { throw AmpError("The cloud AI limit was reached. Try again tomorrow.") }
        guard http.statusCode == 200 else { throw AmpError("Cloud AI is unavailable right now (\(http.statusCode)).") }
        return data
    }
}

public enum ResearchAccessKey {
    private static let account = "sound-research"
    private static let service = "app.ampworkbench.research"
    public static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public static func save(_ key: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return true }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
