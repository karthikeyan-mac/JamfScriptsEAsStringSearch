import Foundation
import SwiftUI
import AppKit

// MARK: - ServerEnvironment

/// Represents a Jamf Pro server environment. Each has its own
/// Keychain entries and persisted URL, so switching environment
/// instantly loads the right credentials.
enum ServerEnvironment: String, CaseIterable, Identifiable {
    case production = "Production"
    case sandbox    = "Sandbox"

    var id: String { rawValue }

    var keychainPrefix: String { rawValue.lowercased() }

    var badgeColor: Color {
        switch self {
        case .production: return .blue
        case .sandbox:    return .orange
        }
    }

    /// UserDefaults key for storing the URL per environment
    var urlDefaultsKey: String { "jamfURL.\(keychainPrefix)" }
}

// MARK: - ViewModel

@MainActor
final class SearchViewModel: ObservableObject {

    // MARK: - Environment

    @Published var selectedEnvironment: ServerEnvironment = .production {
        didSet {
            guard oldValue != selectedEnvironment else { return }
            // Defer to next run loop to avoid publishing during view update
            Task { @MainActor in
                environmentDidChange()
            }
        }
    }

    // MARK: - Form fields (per-environment, loaded on env switch)

    // URL auto-saves to UserDefaults on every keystroke.
    // _suppressURLSave is set true during programmatic loads so we don't
    // overwrite a real saved value with an empty string during init or env switch.
    @Published var jamfURL: String = "" {
        didSet {
            guard !_suppressURLSave, !jamfURL.isEmpty else { return }
            UserDefaults.standard.set(jamfURL, forKey: selectedEnvironment.urlDefaultsKey)
        }
    }
    private var _suppressURLSave = false
    @Published var clientID     = ""
    @Published var clientSecret = ""
    @Published var searchString = ""
    @Published var searchScope  = SearchScope.both

    @Published var saveCredentials = false {
        didSet { handleSaveCredentialsToggle() }
    }

    // MARK: - Output state

    @Published var isSearching       = false
    @Published var progressCompleted = 0
    @Published var progressTotal     = 0
    @Published var results: [SearchResult] = []
    @Published var resourceErrors: [SearchResponse.ResourceError] = []
    @Published var searchedTypes: Set<SearchResult.ResourceType> = []
    @Published var logLines: [LogLine]     = []
    @Published var errorMessage: String?
    @Published var searchFinished    = false
    @Published var selectedOutputTab: OutputTab = .activity

    enum OutputTab { case activity, results }

    // MARK: - Derived

    var scriptMatchCount: Int { results.filter { $0.resourceType == .script }.count }
    var eaMatchCount:     Int { results.filter { $0.resourceType == .extensionAttribute }.count }

    var progressFraction: Double {
        progressTotal > 0 ? Double(progressCompleted) / Double(progressTotal) : 0
    }

    var canSearch: Bool {
        !jamfURL.isEmpty && !clientID.isEmpty &&
        !clientSecret.isEmpty && !searchString.isEmpty && !isSearching
    }

    var validationMessage: String? {
        if jamfURL.isEmpty      { return "Jamf URL required" }
        if clientID.isEmpty     { return "Client ID required" }
        if clientSecret.isEmpty { return "Client Secret required" }
        if searchString.isEmpty { return "Search string required" }
        return nil
    }

    // MARK: - Log

    struct LogLine: Identifiable {
        let id = UUID()
        let time: String
        let text: String
        let isError: Bool

        init(_ text: String, isError: Bool = false) {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            self.time = f.string(from: Date())
            self.text = text
            self.isError = isError
        }
    }

    private func log(_ text: String, isError: Bool = false) {
        logLines.append(LogLine(text, isError: isError))
    }

    // MARK: - Dependencies

    private let api      = JamfAPIService()
    private let keychain = KeychainService.shared

    init() {
        // Suppress URL didSet writes while loading so we never write empty over saved values
        _suppressURLSave = true
        loadCredentialsForCurrentEnvironment()
        _suppressURLSave = false
    }

    // MARK: - Environment switching

    /// Called whenever the user picks a different environment.
    /// Saves the current form state for the old environment first,
    /// then loads saved state for the new one.
    private func environmentDidChange() {
        // Suppress URL didSet write-back while loading the new environment's saved URL
        _suppressURLSave = true
        loadCredentialsForCurrentEnvironment()
        _suppressURLSave = false
        // Clear output — previous env's results are not relevant to the new env
        results           = []
        logLines          = []
        errorMessage      = nil
        searchFinished    = false
        selectedOutputTab = .activity
    }

    private func loadCredentialsForCurrentEnvironment() {
        let env = selectedEnvironment

        // URL is stored in UserDefaults (not sensitive)
        jamfURL = UserDefaults.standard.string(forKey: env.urlDefaultsKey) ?? ""

        // Credentials come from Keychain — only populate if all three exist
        if let id     = keychain.load(.clientID(env)),
           let secret = keychain.load(.clientSecret(env)) {
            clientID        = id
            clientSecret    = secret
            saveCredentials = true
        } else {
            clientID        = ""
            clientSecret    = ""
            saveCredentials = false
        }
    }

    private func saveCredentialsForCurrentEnvironment() {
        let env = selectedEnvironment
        // URL is already persisted via didSet on jamfURL — only save secrets here
        keychain.save(clientID,     for: .clientID(env))
        keychain.save(clientSecret, for: .clientSecret(env))
    }

    // MARK: - Search

    func runSearch() async {
        guard canSearch else { return }

        let baseURL = jamfURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        isSearching       = true
        searchFinished    = false
        errorMessage      = nil
        results           = []
        resourceErrors    = []
        searchedTypes     = []
        logLines          = []
        progressCompleted = 0
        progressTotal     = 0
        selectedOutputTab = .activity

        if saveCredentials { saveCredentialsForCurrentEnvironment() }

        log("[\(selectedEnvironment.rawValue)] Connecting to \(baseURL)…")

        do {
            try await api.authenticate(
                jamfURL:      baseURL,
                clientID:     clientID,
                clientSecret: clientSecret
            )
            log("Authenticated successfully.")

            let scopeLabel = searchScope == .both
                ? "Scripts & Extension Attributes"
                : searchScope == .scripts ? "Scripts" : "Extension Attributes"
            log("Searching \(scopeLabel) for \"\(searchString)\"…")

            let response = try await api.search(
                jamfURL:      baseURL,
                searchString: searchString,
                searchScope:  searchScope,
                progress: { [weak self] completed, total in
                    Task { @MainActor [weak self] in
                        self?.progressCompleted = completed
                        self?.progressTotal     = total
                    }
                }
            )
            
            results = response.results
            resourceErrors = response.errors
            searchedTypes = response.searchedTypes
            
            // Log any resource-specific errors
            for error in response.errors {
                let resourceName = error.resourceType == .script ? "Scripts" : "Extension Attributes"
                log("ERROR: \(resourceName) - \(error.error)", isError: true)
            }

            searchFinished = true
            
            // Build completion message
            var completionMsg = "\(progressTotal) resource(s) checked, \(results.count) match(es) found"
            if !response.errors.isEmpty {
                let failedTypes = response.errors.map { $0.resourceType == .script ? "Scripts" : "EAs" }.joined(separator: ", ")
                completionMsg += " (\(failedTypes) failed - see errors above)"
            }
            log("Complete — \(completionMsg).")
            
            selectedOutputTab = .results

        } catch let error as JamfAPIError {
            errorMessage = error.errorDescription
            log(error.errorDescription ?? "Unknown error", isError: true)
        } catch {
            errorMessage = error.localizedDescription
            log(error.localizedDescription, isError: true)
        }

        await api.invalidateToken(jamfURL: baseURL)
        log("Access token revoked.")
        isSearching = false
    }

    // MARK: - CSV Export

    func exportCSV() {
        guard !results.isEmpty else { return }

        var csv = "Environment,Type,Name,ID,URL,Match Count,Matching Lines\n"
        for r in results {
            csv += [
                selectedEnvironment.rawValue,
                r.resourceType.rawValue,
                r.name.csvEscaped,
                String(r.resourceID),
                r.url.absoluteString.csvEscaped,
                String(r.matchCount),
                r.matchingLines.map(String.init).joined(separator: "; ").csvEscaped
            ].joined(separator: ",") + "\n"
        }

        let panel = NSSavePanel()
        panel.title                = "Export Results"
        panel.nameFieldStringValue = "jamf_search_\(selectedEnvironment.rawValue.lowercased())_results.csv"
        panel.allowedContentTypes  = [.commaSeparatedText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Keychain toggle

    private func handleSaveCredentialsToggle() {
        if saveCredentials {
            saveCredentialsForCurrentEnvironment()
        } else {
            keychain.deleteAll(for: selectedEnvironment)
        }
    }

    func clearCredentials() {
        let env = selectedEnvironment
        keychain.deleteAll(for: env)
        UserDefaults.standard.removeObject(forKey: env.urlDefaultsKey)
        jamfURL = ""; clientID = ""; clientSecret = ""
        saveCredentials = false
    }
}

private extension String {
    var csvEscaped: String { "\"\(replacingOccurrences(of: "\"", with: "\"\""))\"" }
}
