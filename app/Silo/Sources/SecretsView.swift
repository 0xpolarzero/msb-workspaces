import SwiftUI

// MARK: - Host-held secret UI models

/// Nonsecret metadata for one host-held secret as rendered by the Secrets tab.
/// Real values never exist in these models.
struct SecretEntry: Identifiable, Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case active
        case restartRequired = "restart-required"
        case removalPendingRestart = "removal-pending-restart"
        case appliesOnNextStart = "applies-on-next-start"
        case error

        var displayName: String {
            switch self {
            case .active: return "Active"
            case .restartRequired: return "Restart required"
            case .removalPendingRestart: return "Removal pending restart"
            case .appliesOnNextStart: return "Applies on next start"
            case .error: return "Error"
            }
        }
    }

    let name: String
    let workspaces: [String]
    let allowedDomains: [String]
    let status: Status
    let pendingOperation: SecretOperation?
    let generation: Int
    /// Safe, nonsecret failure detail.
    let error: String?

    var id: String { name }
}

enum SecretOperation: String, Equatable, Sendable {
    case add
    case edit
    case remove
}

/// Keychain account names are the validated secret name: ASCII letters,
/// digits, and underscores, starting with a letter or underscore, with the
/// CLI-reserved names excluded.
enum SecretNameRule {
       static let reservedNames: Set<String> = ["GH_TOKEN", "GITHUB_TOKEN"]
    /// Process-control variables the CLI reserves so exported secrets can
    /// never hijack the child environment.
    static let processControlNames: Set<String> = [
        "PATH", "HOME", "SHELL", "USER", "LOGNAME", "TMPDIR", "TMP", "TEMP",
        "PWD", "HOSTNAME", "TERM", "LANG", "LC_ALL", "CDPATH", "IFS", "ENV",
        "BASH_ENV", "PS1", "PS2", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
        "NO_PROXY"
    ]
    static let processControlPrefixes = ["DYLD_", "LD_", "LC_", "SILO_"]

    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128,
              let first = name.first, first.isASCII,
              first.isLetter || first == "_" else {
            return false
        }
        let grammarMatches = name.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")
        }
        guard grammarMatches else { return false }
        let uppercased = name.uppercased()
                return !reservedNames.contains(uppercased) &&
            !processControlNames.contains(uppercased) &&
            !processControlPrefixes.contains(where: { uppercased.hasPrefix($0) })
    }

    static var hint: String {
        "Letters, digits, and underscores only, starting with a letter or underscore."
    }
}

/// Allowed-domain grammar: an exact DNS host (`api.openai.com`), a leftmost
/// wildcard over a concrete second-level host (`*.example.com`), or the
/// special wildcard-all `*`. Schemes, paths, ports, whitespace, malformed
/// labels, and broad suffixes such as `*.com` are rejected.
enum SecretDomainRule {
    static func isAllowed(_ domain: String) -> Bool {
        guard !domain.isEmpty,
              domain.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !domain.contains("/"),
              !domain.contains(":") else {
            return false
        }
        if domain == "*" { return true }
        if domain.hasPrefix("*.") {
            let suffix = domain.dropFirst(2)
            let labels = suffix.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 2, labels.allSatisfy(isValidLabel) else { return false }
            return true
        }
        guard !domain.contains("*") else { return false }
        return domain.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy(isValidLabel)
    }

    private static func isValidLabel(_ label: Substring) -> Bool {
        guard let first = label.first, let last = label.last,
              first.isASCII, (first.isLetter || first.isNumber),
              last.isASCII, (last.isLetter || last.isNumber) else {
            return false
        }
        return label.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
        }
    }

    static var hint: String {
        "Exact hosts (api.openai.com), wildcards (*.example.com), or * for any HTTPS server."
    }
}

// MARK: - Secrets tab

struct SecretsView: View {
    @Bindable var model: AppModel

    @State private var editorTarget: SecretEditorTarget?
    @State private var pendingRemovalPlan: SiloSecretPlanResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.vertical, 16)

            Divider()

            if let message = model.secretsRestartBannerMessage {
                restartBanner(message)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
                Divider()
            }

            content
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier("secrets.content")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.refreshSecrets() }
        .sheet(isPresented: Binding(
            get: { editorTarget != nil },
            set: { presented in
                if !presented { editorTarget = nil }
            }
        )) {
            if let target = editorTarget {
                SecretEditorSheet(
                    target: target,
                                       availableWorkspaces: model.workspaces,
                    onCancel: {
                        editorTarget = nil
                    },
                    onSubmit: submitEditor
                )
            }
        }
        .alert(
            pendingRemovalPlan.map { "Remove \($0.name)?" } ?? "Remove secret?",
            isPresented: Binding(
                get: { pendingRemovalPlan != nil },
                set: { presented in
                    if !presented, pendingRemovalPlan != nil {
                        cancelRemoval()
                    }
                }
            ),
            presenting: pendingRemovalPlan
        ) { plan in
            Button("Cancel", role: .cancel) {
                cancelRemoval()
            }
            Button("Remove", role: .destructive) {
                pendingRemovalPlan = nil
                Task {
                    await model.confirmSecretPlan(
                        confirmation: plan.confirmationPhrase,
                        value: nil
                    )
                }
            }
            .accessibilityIdentifier("secrets.remove.confirm")
        } message: { plan in
            Text(
                "This will remove the secret from " +
                    "\(plan.affectedWorkspaces.joined(separator: ", "))."
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Secrets")
                .font(.headline)
                .accessibilityIdentifier("secrets.title")
            Spacer()
            Button("Add Secret…") {
                editorTarget = .add
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.secretsMutationsBlocked)
            .accessibilityIdentifier("secrets.add.button")
        }
    }

    private func restartBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: model.secretsRestartBlockedWorkspaces.isEmpty
                ? "arrow.triangle.2.circlepath"
                : "wrench.and.screwdriver")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout.weight(.medium))
                .accessibilityIdentifier("secrets.restart.banner")
            Spacer()
            if !model.secretsRestartRequiredWorkspaces.isEmpty {
                Button("Restart affected workspaces…") {
                    model.restartWorkspacesForSecrets()
                }
                .controlSize(.small)
                .disabled(model.secretsMutationsBlocked)
                .accessibilityIdentifier("secrets.restart.button")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("secrets.restart.banner.row")
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.secretsError ?? model.secretsOperationError {
            VStack(spacing: 12) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("secrets.error")
                Button("Retry") {
                    Task { await model.retrySecretsOperation() }
                }
                .accessibilityIdentifier("secrets.retry")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isSecretsLoading && model.secretEntries.isEmpty {
            ProgressView("Loading secrets…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("secrets.loading")
        } else if model.secretEntries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No secrets")
                    .font(.body.weight(.semibold))
                Text("Silo gives the VM a placeholder and replaces it with the real value only inside the proxy for allowed requests.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("secrets.empty")
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.secretEntries.enumerated()), id: \.element.id) { index, entry in
                    SecretRow(entry: entry, mutationsBlocked: model.secretsMutationsBlocked) { action in
                        handle(entry: entry, action: action)
                    }
                    if index < model.secretEntries.count - 1 {
                        Divider()
                    }
                }
            }
            .accessibilityIdentifier("secrets.list")
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("secrets.error")
            Spacer()
            Button("Retry") {
                Task { await model.retrySecretsOperation() }
            }
            .controlSize(.small)
            .accessibilityIdentifier("secrets.retry")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func handle(entry: SecretEntry, action: SecretRow.Action) {
        switch action {
        case .edit:
            editorTarget = .edit(entry)
        case .remove:
            prepareRemoval(entry)
        case .retry:
            if entry.pendingOperation == .remove {
                prepareRemoval(entry)
            } else {
                editorTarget = .edit(entry)
            }
        }
    }

    private func prepareRemoval(_ entry: SecretEntry) {
        Task {
            let staged = await model.prepareSecretPlan(
                operation: .remove,
                name: entry.name,
                workspaces: entry.workspaces,
                allowedDomains: entry.allowedDomains
            )
            if staged {
                pendingRemovalPlan = model.pendingSecretPlan
            }
        }
    }

    private func cancelRemoval() {
        pendingRemovalPlan = nil
        model.cancelSecretPlan()
    }

    private func submitEditor(
        operation: SecretOperation,
        name: String,
        workspaces: [String],
        allowedDomains: [String],
        value: String?
    ) async -> Bool {
        let staged = await model.prepareSecretPlan(
            operation: operation,
            name: name,
            workspaces: workspaces,
            allowedDomains: allowedDomains
        )
        if staged {
            if let plan = model.pendingSecretPlan {
                await model.confirmSecretPlan(
                    confirmation: plan.confirmationPhrase,
                    value: value
                )
            }
            editorTarget = nil
        }
        return staged
    }
}

// MARK: - Rows and sheets

private enum SecretEditorTarget: Identifiable {
    case add
    case edit(SecretEntry)

    var id: String {
                switch self {
        case .add: return "add"
        case .edit(let entry): return "edit-\(entry.name)"
        }
    }
}

private struct SecretRow: View {
    enum Action {
        case edit
        case remove
        case retry
    }

    let entry: SecretEntry
    let mutationsBlocked: Bool
    let handle: (Action) -> Void

    init(entry: SecretEntry, mutationsBlocked: Bool, handle: @escaping (Action) -> Void) {
        self.entry = entry
        self.mutationsBlocked = mutationsBlocked
        self.handle = handle
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.body.weight(.medium))
                    .accessibilityIdentifier("secrets.entry.\(entry.name).name")
                Text(entry.workspaces.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("secrets.entry.\(entry.name).workspaces")
                Text(entry.allowedDomains.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("secrets.entry.\(entry.name).domains")
                if let error = entry.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .accessibilityIdentifier("secrets.entry.\(entry.name).error")
                }
            }
            Spacer(minLength: 8)
            Text(entry.status.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(entry.status == .active ? Color.green : Color.orange)
                .accessibilityIdentifier("secrets.entry.\(entry.name).status")
            if entry.status == .error {
                Button("Retry") { handle(.retry) }
                    .controlSize(.small)
                    .disabled(mutationsBlocked)
                    .accessibilityIdentifier("secrets.entry.\(entry.name).retry")
            } else {
                Button("Edit…") { handle(.edit) }
                    .controlSize(.small)
                    .disabled(mutationsBlocked)
                    .accessibilityIdentifier("secrets.entry.\(entry.name).edit")
                Button("Remove…", role: .destructive) { handle(.remove) }
                    .controlSize(.small)
                    .disabled(mutationsBlocked)
                    .accessibilityIdentifier("secrets.entry.\(entry.name).remove")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("secrets.entry.\(entry.name).row")
    }
}

private struct SecretEditorSheet: View {
    let target: SecretEditorTarget
    let availableWorkspaces: [Workspace]
    let onCancel: () -> Void
    let onSubmit: (SecretOperation, String, [String], [String], String?) async -> Bool

    @State private var name = ""
    @State private var value = ""
    @State private var replaceValue = false
    @State private var selectedWorkspaces: Set<String> = []
    @State private var domains: [String] = []
    @State private var domainInput = ""
    @State private var domainError: String?
    @State private var wildcardConfirmed = false
    @State private var formError: String?
    @State private var isSubmitting = false
    @FocusState private var cancelFocused: Bool

    private var operation: SecretOperation {
        switch target {
        case .add: return .add
        case .edit: return .edit
        }
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var hasWildcard: Bool {
        domains.contains("*")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Edit \(editingName)" : "Add Secret")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("secrets.editor.title")

            LabeledContent("Name") {
                TextField(isEditing ? editingName : "OPENAI_API_KEY", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEditing)
                    .accessibilityIdentifier("secrets.editor.name")
            }
            if isEditing {
                Text("The name is fixed. To rename, remove this secret and add it under the new name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("secrets.editor.name-locked")
            }

            if isEditing {
                Toggle("Replace value", isOn: $replaceValue)
                    .accessibilityIdentifier("secrets.editor.replace")
            }
            if !isEditing || replaceValue {
                LabeledContent(isEditing ? "Replacement value" : "Value") {
                    SecureField(isEditing ? "New value" : "Required", text: $value)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("secrets.editor.value")
                }
            } else {
                Text("The current value is not loaded into this form and will be kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("secrets.editor.keep-value")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Workspaces")
                    .font(.callout)
                Text("Select every workspace that may send this secret.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(availableWorkspaces) { workspace in
                        Toggle(workspace.id.rawValue, isOn: Binding(
                            get: { selectedWorkspaces.contains(workspace.id.rawValue) },
                            set: { selected in
                                if selected {
                                    selectedWorkspaces.insert(workspace.id.rawValue)
                                } else {
                                    selectedWorkspaces.remove(workspace.id.rawValue)
                                }
                            }
                        ))
                        .toggleStyle(.button)
                        .accessibilityIdentifier("secrets.editor.workspace.\(workspace.id.rawValue)")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Allowed domains")
                    .font(.callout)
                Text(SecretDomainRule.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The real value is inserted only into HTTPS requests to these domains.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !domains.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(domains, id: \.self) { domain in
                            domainChip(domain)
                        }
                    }
                }
                HStack(spacing: 6) {
                    TextField("api.openai.com", text: $domainInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("secrets.editor.domain.input")
                        .onSubmit(addDomain)
                    Button("Add domain") { addDomain() }
                        .controlSize(.small)
                        .accessibilityIdentifier("secrets.editor.domain.add")
                }
                if let domainError {
                    Text(domainError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("secrets.editor.domain.error")
                }
            }

            if hasWildcard {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "* allows any code in the VM to send this credential to any HTTPS server.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("secrets.editor.wildcard.warning")
                    Toggle("I understand and want to allow any HTTPS destination", isOn: $wildcardConfirmed)
                        .font(.caption)
                        .accessibilityIdentifier("secrets.editor.wildcard.confirm")
                }
                .padding(10)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if let formError {
                Text(formError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("secrets.editor.error")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
                    .accessibilityIdentifier("secrets.editor.cancel")
                Button(isEditing ? "Edit" : "Add") {
                    Task { await submit() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting || !isFormValid)
                .accessibilityIdentifier("secrets.editor.submit")
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 560, maxWidth: 680)
        .onAppear {
            if case .edit(let entry) = target {
                name = entry.name
                selectedWorkspaces = Set(entry.workspaces)
                domains = entry.allowedDomains
            }
            cancelFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("secrets.editor.sheet")
    }

    private var editingName: String {
        if case .edit(let entry) = target { return entry.name }
        return ""
    }

    private var isFormValid: Bool {
        guard SecretNameRule.isValid(name),
              !selectedWorkspaces.isEmpty,
              !domains.isEmpty,
              domains.allSatisfy(SecretDomainRule.isAllowed),
              !hasWildcard || wildcardConfirmed else {
            return false
        }
        if !isEditing || replaceValue {
            return !value.isEmpty
        }
        return true
    }

    private func domainChip(_ domain: String) -> some View {
        HStack(spacing: 4) {
            Text(domain)
                .font(.caption)
            Button {
                domains.removeAll { $0 == domain }
                if domain == "*" { wildcardConfirmed = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .accessibilityLabel("Remove \(domain)")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("secrets.editor.domain.\(domain)")
    }

    private func addDomain() {
        domainError = nil
        let candidate = domainInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        guard SecretDomainRule.isAllowed(candidate) else {
            domainError = "\(candidate) is not an allowed domain. Use an exact host, *.example.com, or *."
            return
        }
        guard !domains.contains(candidate) else {
            domainError = "\(candidate) is already listed."
            return
        }
        domains.append(candidate)
        domainInput = ""
    }

    private func submit() async {
        formError = nil
        guard SecretNameRule.isValid(name) else {
            formError = "Enter a valid secret name. \(SecretNameRule.hint)"
            return
        }
        guard !selectedWorkspaces.isEmpty else {
            formError = "Select at least one workspace."
            return
        }
        guard !domains.isEmpty else {
            formError = "Add at least one allowed domain."
            return
        }
        guard !hasWildcard || wildcardConfirmed else {
            formError = "Confirm the * destination before continuing."
            return
        }
        let submittedValue = (!isEditing || replaceValue) ? value : nil
        guard submittedValue.map({ !$0.isEmpty }) ?? true else {
            formError = "Enter a value."
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        let staged = await onSubmit(
            operation,
            name,
            selectedWorkspaces.sorted(),
            domains,
            submittedValue
        )
        if !staged {
            formError = "The secret change could not be staged."
        }
    }
}


// MARK: - Chip flow layout

/// Minimal left-to-right flow layout for domain chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var height: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth + size.width > width, lineWidth > 0 {
                height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width == .infinity ? lineWidth : width, height: height + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
