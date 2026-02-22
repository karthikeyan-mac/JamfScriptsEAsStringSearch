import Foundation

// MARK: - Models

/// Response from a search operation, including both successful results and any errors encountered.
struct SearchResponse {
    let results: [SearchResult]
    let errors: [ResourceError]
    let searchedTypes: Set<SearchResult.ResourceType>  // Successfully searched (even if 0 matches)
    
    struct ResourceError {
        let resourceType: SearchResult.ResourceType
        let error: String
    }
}

/// A single search result representing one matching resource (Script or EA).
struct SearchResult: Identifiable {
    let id = UUID()
    let resourceType: ResourceType
    let name: String
    let resourceID: Int
    let url: URL
    let matchCount: Int
    let matchingLines: [Int]   // 1-based line numbers containing the search string

    enum ResourceType: String {
        case script             = "Script"
        case extensionAttribute = "Extension Attribute"
    }
}

/// Errors surfaced to the UI with human-readable descriptions.
enum JamfAPIError: LocalizedError {
    case invalidURL
    case emptyResponse
    case invalidCredentials
    case authenticationFailed
    case forbidden(String)
    case httpError(Int, String)
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Jamf Pro URL. Please verify you have entered the correct URL (e.g., https://yourinstance.jamfcloud.com)."
        case .emptyResponse:
            return "No response from server. Please verify your Jamf Pro URL is correct and the server is accessible."
        case .invalidCredentials:
            return "Invalid client credentials. Please verify you have entered the correct Client ID and Client Secret."
        case .authenticationFailed:
            return "Authentication failed. Please verify your Client ID, Client Secret, and ensure the API client exists in Jamf Pro."
        case .forbidden(let endpoint):
            return "Access denied. Please verify the API Role has the required permissions: Read Scripts and Read Computer Extension Attributes."
        case .httpError(let code, let endpoint):
            return "HTTP \(code) error. Please verify your URL, credentials, and API permissions are correct."
        case .decodingError:
            return "Unable to read server response. Please verify you have entered the correct URL, Client ID, and Client Secret, and that the API Role has the required permissions."
        }
    }
}

// MARK: - Service

/// Handles all communication with the Jamf Pro Classic API.
/// Uses OAuth 2.0 client credentials for authentication and
/// invalidates the token automatically when the search completes or fails.
final class JamfAPIService {

    private var accessToken: String?

    // MARK: - Authentication

    /// Fetches an OAuth 2.0 access token using client credentials flow.
    func authenticate(jamfURL: String, clientID: String, clientSecret: String) async throws {
        guard let url = URL(string: "\(jamfURL)/api/oauth/token") else {
            throw JamfAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "client_id=\(clientID)&grant_type=client_credentials&client_secret=\(clientSecret)"
            .data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard !data.isEmpty else { throw JamfAPIError.emptyResponse }

        if let raw = String(data: data, encoding: .utf8), raw.contains("invalid_client") {
            throw JamfAPIError.invalidCredentials
        }

        struct TokenResponse: Decodable { let access_token: String }
        do {
            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            self.accessToken = tokenResponse.access_token
        } catch {
            throw JamfAPIError.decodingError
        }
    }

    /// Revokes the current access token. Always called after a search run, success or failure.
    func invalidateToken(jamfURL: String) async {
        guard let token = accessToken,
              let url = URL(string: "\(jamfURL)/api/v1/auth/invalidate-token") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
        self.accessToken = nil
    }

    // MARK: - Networking

    /// Performs an authenticated GET and returns raw Data, or throws a typed error.
    private func get(jamfURL: String, endpoint: String) async throws -> Data {
        guard let token = accessToken else { throw JamfAPIError.authenticationFailed }
        guard let url = URL(string: "\(jamfURL)\(endpoint)") else { throw JamfAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:       return data
        case 401:       throw JamfAPIError.authenticationFailed
        case 403:       throw JamfAPIError.forbidden(endpoint)
        default:        throw JamfAPIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, endpoint)
        }
    }

    // MARK: - XML Parsing

    /// Parses a list response and returns only the top-level IDs.
    /// Uses XMLParser to avoid matching <id> inside nested sub-elements.
    private func parseIDs(from data: Data, itemElement: String) -> [Int] {
        let parser = IDListParser(itemElement: itemElement)
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.ids
    }

    /// Extracts a named text field and the script content from a detail response.
    /// Handles both plain text and CDATA-wrapped content correctly.
    private func parseDetail(from data: Data, contentPath: [String]) -> (name: String, content: String) {
        let parser = DetailParser(contentPath: contentPath)
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return (parser.name, parser.scriptContent)
    }

    // MARK: - Search

    /// Searches Scripts and/or Extension Attributes for the given string.
    /// Returns partial results if one resource type fails - continues with working types.
    func search(
        jamfURL: String,
        searchString: String,
        searchScope: SearchScope,
        progress: @escaping (Int, Int) -> Void
    ) async throws -> SearchResponse {

        // Define each resource type's API shape
        struct ResourceDef {
            let endpoint: String
            let itemElement: String        // XML element name for each item in the list
            let contentPath: [String]      // Path of elements to the script content field
            let urlPath: String
            let type: SearchResult.ResourceType
        }

        var defs: [ResourceDef] = []

        if searchScope == .scripts || searchScope == .both {
            defs.append(ResourceDef(
                endpoint:     "/JSSResource/scripts",
                itemElement:  "script",
                // Scripts: <script><script_contents>...</script_contents></script>
                contentPath:  ["script", "script_contents"],
                urlPath:      "/view/settings/computer-management/scripts",
                type:         .script
            ))
        }

        if searchScope == .extensionAttributes || searchScope == .both {
            defs.append(ResourceDef(
                endpoint:     "/JSSResource/computerextensionattributes",
                itemElement:  "computer_extension_attribute",
                // EAs: <computer_extension_attribute><input_type><script>...</script></input_type>
                contentPath:  ["computer_extension_attribute", "input_type", "script"],
                urlPath:      "/computerExtensionAttributes.html?id=",
                type:         .extensionAttribute
            ))
        }

        // Track errors for each resource type
        var resourceErrors: [SearchResponse.ResourceError] = []
        var searchedTypes: Set<SearchResult.ResourceType> = []
        
        // First pass — fetch all ID lists to get the total count for the progress bar
        var allIDsByDef: [[Int]] = []
        var totalResources = 0

        for def in defs {
            do {
                let data = try await get(jamfURL: jamfURL, endpoint: def.endpoint)
                let ids  = parseIDs(from: data, itemElement: def.itemElement)
                allIDsByDef.append(ids)
                totalResources += ids.count
                searchedTypes.insert(def.type)  // Mark as successfully searched
            } catch let error as JamfAPIError {
                // Resource type failed - record error and continue with empty list
                allIDsByDef.append([])
                resourceErrors.append(SearchResponse.ResourceError(
                    resourceType: def.type,
                    error: error.errorDescription ?? "Unknown error"
                ))
            } catch {
                allIDsByDef.append([])
                resourceErrors.append(SearchResponse.ResourceError(
                    resourceType: def.type,
                    error: error.localizedDescription
                ))
            }
        }

        progress(0, totalResources)

        // Second pass — fetch each resource detail and search its content
        var results: [SearchResult] = []
        var completed = 0

        for (index, def) in defs.enumerated() {
            for resourceID in allIDsByDef[index] {

                let detailData = try await get(
                    jamfURL:  jamfURL,
                    endpoint: "\(def.endpoint)/id/\(resourceID)"
                )
                let (name, content) = parseDetail(from: detailData, contentPath: def.contentPath)

                completed += 1
                progress(completed, totalResources)

                // Skip EAs with no script content (Text Field, Pop-up Menu input types, etc.)
                guard !content.isEmpty else { continue }

                // Case-insensitive literal line search
                let lines = content.components(separatedBy: "\n")
                let matchingLineNumbers = lines
                    .enumerated()
                    .compactMap { index, line in
                        line.localizedCaseInsensitiveContains(searchString) ? index + 1 : nil
                    }

                guard !matchingLineNumbers.isEmpty else { continue }

                // Build the direct Jamf Pro UI link for this resource
                let urlSuffix = def.type == .extensionAttribute
                    ? "\(def.urlPath)\(resourceID)"
                    : "\(def.urlPath)/\(resourceID)"

                guard let url = URL(string: "\(jamfURL)\(urlSuffix)") else { continue }

                results.append(SearchResult(
                    resourceType:  def.type,
                    name:          name.isEmpty ? "ID \(resourceID)" : name,
                    resourceID:    resourceID,
                    url:           url,
                    matchCount:    matchingLineNumbers.count,
                    matchingLines: matchingLineNumbers
                ))
            }
        }

        return SearchResponse(results: results, errors: resourceErrors, searchedTypes: searchedTypes)
    }
}

// MARK: - IDListParser

/// Parses a Jamf list response (e.g. /JSSResource/scripts) and collects
/// only the top-level <id> values — ignores <id> in nested sub-elements.
private final class IDListParser: NSObject, XMLParserDelegate {

    let itemElement: String
    var ids: [Int] = []

    private var insideItem    = false
    private var insideID      = false
    private var depth         = 0      // tracks nesting within the item element
    private var currentString = ""

    init(itemElement: String) {
        self.itemElement = itemElement
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {

        if elementName == itemElement {
            insideItem = true
            depth      = 0
        } else if insideItem {
            depth += 1
            // Only read <id> at depth 1 (direct child of the item element)
            if elementName == "id" && depth == 1 {
                insideID      = true
                currentString = ""
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideID { currentString += string }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {

        if elementName == "id" && insideID {
            if let id = Int(currentString.trimmingCharacters(in: .whitespacesAndNewlines)) {
                ids.append(id)
            }
            insideID      = false
            currentString = ""
        }

        if elementName == itemElement {
            insideItem = false
            depth      = 0
        } else if insideItem {
            depth -= 1
        }
    }
}

// MARK: - DetailParser

/// Parses a Jamf resource detail response to extract the name and script content.
/// contentPath defines the chain of XML elements to navigate to the script field,
/// e.g. ["computer_extension_attribute", "input_type", "script"].
/// Handles both plain text and CDATA content transparently.
private final class DetailParser: NSObject, XMLParserDelegate {

    let contentPath: [String]
    var name: String          = ""
    var scriptContent: String = ""

    private var elementStack:    [String] = []
    private var currentString:   String   = ""
    private var capturingName:   Bool     = false
    private var capturingScript: Bool     = false

    // The root element of the content path (e.g. "script" or "computer_extension_attribute")
    private var rootElement: String { contentPath.first ?? "" }
    // The leaf element that holds the script text (e.g. "script_contents" or "script")
    private var leafElement: String { contentPath.last ?? "" }

    init(contentPath: [String]) {
        self.contentPath = contentPath
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {

        elementStack.append(elementName)
        currentString = ""

        // Capture <name> at the top level (direct child of root)
        if elementName == "name" && elementStack.count == 2 {
            capturingName  = true
        }

        // Capture the script leaf element when the full content path is matched
        if elementName == leafElement && stackMatchesPath() {
            capturingScript = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingName || capturingScript {
            currentString += string
        }
    }

    // XMLParser calls this for CDATA sections — treat identically to plain characters
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if capturingScript, let s = String(data: CDATABlock, encoding: .utf8) {
            currentString += s
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {

        if capturingName && elementName == "name" {
            name          = currentString.trimmingCharacters(in: .whitespacesAndNewlines)
            capturingName = false
        }

        if capturingScript && elementName == leafElement {
            scriptContent    = currentString.trimmingCharacters(in: .whitespacesAndNewlines)
            capturingScript  = false
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
        currentString = ""
    }

    /// Returns true when the current element stack ends with the full contentPath.
    private func stackMatchesPath() -> Bool {
        guard elementStack.count >= contentPath.count else { return false }
        let tail = elementStack.suffix(contentPath.count)
        return Array(tail) == contentPath
    }
}

// MARK: - SearchScope

enum SearchScope: String, CaseIterable, Identifiable {
    case scripts             = "Scripts"
    case extensionAttributes = "Extension Attributes"
    case both                = "Both"

    var id: String { rawValue }
}
