import SwiftUI

// MARK: - Root view

struct SearchFormView: View {
    @ObservedObject var viewModel: SearchViewModel
    @State private var showPermissionsPopover = false
    @State private var showAppInfo = false

    var body: some View {
        VStack(spacing: 0) {
            formPane
            Divider()
            outputPane
        }
        .frame(minWidth: 680, minHeight: 560)
    }

    // MARK: - Form pane

    private var formPane: some View {
        VStack(alignment: .leading, spacing: 8) {

            // ── Logo + Title + Info + Environment picker ────────────────────
            HStack(spacing: 10) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                
                Text("Jamf Search - Scripts & EAs")
                    .font(.title2.weight(.semibold))
                
                Button {
                    showAppInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.plain)
                .help("About this app")
                .popover(isPresented: $showAppInfo, arrowEdge: .bottom) {
                    AppInfoPopover()
                }

                Spacer()

                // Environment badge + picker
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.selectedEnvironment.badgeColor)
                        .frame(width: 7, height: 7)
                    Picker("", selection: $viewModel.selectedEnvironment) {
                        ForEach(ServerEnvironment.allCases) { env in
                            Text(env.rawValue).tag(env)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 110)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    viewModel.selectedEnvironment.badgeColor.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .help("Switch between Production and Sandbox — each has its own saved credentials")

                if viewModel.saveCredentials {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .help("Credentials saved in Keychain for \(viewModel.selectedEnvironment.rawValue)")
                }
            }

            Divider()

            // ── 1. Credentials grid ─────────────────────────────────────────
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: 8, verticalSpacing: 5) {

                GridRow {
                    fieldLabel("Jamf URL")
                    TextField("https://instance.jamfcloud.com", text: $viewModel.jamfURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .font(.callout)
                }

                GridRow {
                    fieldLabel("Client ID")
                    TextField("API Client ID", text: $viewModel.clientID)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .font(.callout)
                }

                GridRow {
                    fieldLabel("Client Secret")
                    SecureField("API Client Secret", text: $viewModel.clientSecret)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                }
            }

            // ── 2. Search string field ──────────────────────────────────────
            HStack(spacing: 8) {
                fieldLabel("Search String")
                TextField(
                    "e.g. python  •  /usr/bin/python3  •  case-insensitive, literal match",
                    text: $viewModel.searchString
                )
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            }

            // ── 3. Keychain + Clear + API Privileges + Validation ───────────
            HStack(spacing: 10) {
                Toggle("Save to Keychain", isOn: $viewModel.saveCredentials)
                    .toggleStyle(.checkbox)
                    .font(.callout.weight(.medium))
                    .help("Securely save credentials for \(viewModel.selectedEnvironment.rawValue) in the macOS Keychain")

                if viewModel.saveCredentials {
                    Button {
                        viewModel.clearCredentials()
                    } label: {
                        Text("Clear").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .help("Remove \(viewModel.selectedEnvironment.rawValue) credentials from Keychain")
                }

                Spacer()

                Button {
                    showPermissionsPopover = true
                } label: {
                    Label("API Privileges Required", systemImage: "lock.shield")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.teal)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $showPermissionsPopover, arrowEdge: .bottom) {
                    PermissionsPopover()
                }

                Spacer()

                if let hint = viewModel.validationMessage, !viewModel.isSearching {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                        Text(hint)
                            .font(.callout.weight(.medium))
                    }
                    .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 6)

            // ── 4. Search In picker + Run Search button ─────────────────────
            HStack(spacing: 10) {
                fieldLabel("Search In")
                
                Picker("", selection: $viewModel.searchScope) {
                    ForEach(SearchScope.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Spacer()

                Button {
                    Task { await viewModel.runSearch() }
                } label: {
                    HStack(spacing: 5) {
                        if viewModel.isSearching {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        }
                        Text(viewModel.isSearching ? "Searching…" : "Run Search")
                            .font(.body.weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!viewModel.canSearch)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    // MARK: - Output pane

    private var outputPane: some View {
        VStack(spacing: 0) {

            // Error banner
            if let error = viewModel.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        Task { @MainActor in
                            viewModel.errorMessage = nil
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.red.opacity(0.08))
                Divider()
            }

            // Tab bar
            HStack(spacing: 2) {
                outputTabButton(.activity, icon: "terminal",    label: "Activity")
                outputTabButton(.results,  icon: "list.bullet", label: "Results",
                                badge: viewModel.searchFinished ? viewModel.results.count : nil)
                Spacer()
                // Env tag in output area for context
                Text(viewModel.selectedEnvironment.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(viewModel.selectedEnvironment.badgeColor)
                    .padding(.trailing, 10)
            }
            .padding(.horizontal, 10)
            .padding(.top, 5)

            Divider()

            // Content
            switch viewModel.selectedOutputTab {
            case .activity: activityPane
            case .results:  resultsPane
            }
        }
    }

    // MARK: - Tab button

    private func outputTabButton(
        _ tab: SearchViewModel.OutputTab,
        icon: String,
        label: String,
        badge: Int? = nil
    ) -> some View {
        let isSelected = viewModel.selectedOutputTab == tab
        return Button { 
            Task { @MainActor in
                viewModel.selectedOutputTab = tab
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption)
                Text(label).font(.caption.weight(.medium))
                if let b = badge, b > 0 {
                    Text("\(b)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Activity pane

    private var activityPane: some View {
        VStack(spacing: 0) {
            if viewModel.isSearching && viewModel.progressTotal > 0 {
                VStack(spacing: 2) {
                    ProgressView(value: viewModel.progressFraction)
                        .progressViewStyle(.linear)
                    Text("Checking \(viewModel.progressCompleted) of \(viewModel.progressTotal)…")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if viewModel.logLines.isEmpty {
                            Text("Activity will appear here when a search runs.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(10)
                        }
                        ForEach(viewModel.logLines) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(line.time)
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                                Text(line.text)
                                    .foregroundStyle(line.isError ? .red : .primary)
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 10.5, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: viewModel.logLines.count) { _, _ in
                    if let last = viewModel.logLines.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results pane

    private var resultsPane: some View {
        Group {
            if !viewModel.searchFinished {
                emptyState(icon: "magnifyingglass",
                           text: "Run a search to see results here.")
            } else if viewModel.results.isEmpty && viewModel.resourceErrors.isEmpty {
                // No matches and no errors - clean empty state
                emptyState(icon: "checkmark.circle",
                           text: "No matches found for \"\(viewModel.searchString)\".")
            } else {
                // Show results and/or errors
                VStack(spacing: 0) {
                    // Summary bar - only show if there are matches or errors
                    if !viewModel.results.isEmpty || !viewModel.resourceErrors.isEmpty || !viewModel.searchedTypes.isEmpty {
                        HStack(spacing: 14) {
                            // Show count pills for successfully searched types
                            if viewModel.searchedTypes.contains(.script) {
                                if viewModel.scriptMatchCount > 0 {
                                    summaryPill("doc.text",
                                               "\(viewModel.scriptMatchCount) Script\(viewModel.scriptMatchCount == 1 ? "" : "s")",
                                               .blue)
                                } else {
                                    noMatchPill("Scripts")
                                }
                            }
                            
                            if viewModel.searchedTypes.contains(.extensionAttribute) {
                                if viewModel.eaMatchCount > 0 {
                                    summaryPill("square.and.pencil",
                                               "\(viewModel.eaMatchCount) EA\(viewModel.eaMatchCount == 1 ? "" : "s")",
                                               .purple)
                                } else {
                                    noMatchPill("EAs")
                                }
                            }
                            
                            // Show error pills for failed resource types
                            ForEach(viewModel.resourceErrors, id: \.resourceType.rawValue) { error in
                                errorPill(error.resourceType == .script ? "Scripts" : "EAs",
                                         error.error)
                            }
                            
                            Spacer()
                            
                            if !viewModel.results.isEmpty {
                                Button {
                                    viewModel.exportCSV()
                                } label: {
                                    Label("Export CSV", systemImage: "square.and.arrow.up")
                                        .font(.callout.weight(.medium))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(nsColor: .controlBackgroundColor))

                        Divider()
                    }

                    if viewModel.results.isEmpty {
                        // No matches but there were errors
                        emptyState(icon: "exclamationmark.triangle",
                                  text: "Search completed with errors. See error details above and check Activity tab.")
                    } else {
                        List(viewModel.results) { result in
                            ResultRow(result: result)
                                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        }
                        .listStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .gridColumnAlignment(.trailing)
            .frame(minWidth: 90, alignment: .trailing)
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3).foregroundStyle(.quaternary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryPill(_ icon: String, _ label: String, _ color: Color) -> some View {
        Label(label, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
    }
    
    private func noMatchPill(_ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 10))
            Text("\(label): No match found")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
    }
    
    private func errorPill(_ label: String, _ errorMessage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text(label)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.red)
        .cornerRadius(4)
        .help(errorMessage)
    }
}

// MARK: - Result Row

private struct ResultRow: View {
    let result: SearchResult
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Text(result.resourceType == .script ? "Scripts" : "EA")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            result.resourceType == .script
                                ? Color.blue.opacity(0.15) : Color.purple.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 3)
                        )
                        .foregroundStyle(result.resourceType == .script ? Color.blue : Color.purple)

                    Text(result.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("\(result.matchCount)✕")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(result.name)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.bottom, 2)
                    
                    HStack {
                        Text("ID \(result.resourceID)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Link("Open in Jamf Pro ↗", destination: result.url)
                            .font(.caption2)
                    }
                    Text("Lines: " + result.matchingLines.map(String.init).joined(separator: ", "))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                .padding(.leading, 4)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: expanded)
    }
}



// MARK: - App Info Popover

private struct AppInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            
            HStack(spacing: 8) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jamf Search - Scripts & EAs")
                        .font(.title3.weight(.semibold))
                    Text("Version 1.0")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Divider()
            
            Text("Search for text strings across all Scripts and Computer Extension Attributes in your Jamf Pro instance.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Features")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                
                FeatureRow(icon: "magnifyingglass", text: "Case-insensitive literal string search")
                FeatureRow(icon: "scope", text: "Search Scripts, Extension Attributes, or both")
                FeatureRow(icon: "lock.shield", text: "OAuth 2.0 authentication with token revocation")
                FeatureRow(icon: "key.fill", text: "Secure Keychain credential storage per environment")
                FeatureRow(icon: "square.and.arrow.up", text: "CSV export with matching line numbers")
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.blue)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Permissions Popover

private struct PermissionsPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Required API Permissions")
                    .font(.headline)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("API Role Privileges")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                PermissionRow(name: "Read Scripts",
                              description: "Search Jamf Pro Scripts")
                PermissionRow(name: "Read Computer Extension Attributes",
                              description: "Search Computer Extension Attributes")
            }

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("How to create an API Client")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("1. Open Jamf Pro → Settings")
                    .font(.caption).foregroundStyle(.secondary)
                Text("2. Go to API Roles and Clients")
                    .font(.caption).foregroundStyle(.secondary)
                Text("3. Create a Role with the privileges above")
                    .font(.caption).foregroundStyle(.secondary)
                Text("4. Create a Client and assign the Role")
                    .font(.caption).foregroundStyle(.secondary)
                Text("5. Copy the Client ID and generate a Secret")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

private struct PermissionRow: View {
    let name: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.caption.weight(.medium))
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}