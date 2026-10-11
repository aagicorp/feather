import AppKit

/// A sheet for the variables of an environment (with its timeout and connection settings) or of a collection.
/// A variable marked secret shows dots and is kept in the Keychain by the workspace, never in the file.
final class APIEnvironmentSheet: NSWindowController, NSTextFieldDelegate {
    private enum Subject {
        case environment(APIEnvironment, isNew: Bool)
        case collection(APICollection)
    }

    private weak var controller: APIClientController?
    private var subject: Subject
    private var variables: [APIVariable] = []
    private var completion: ((APIEnvironment?) -> Void)?

    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField()
    private var table: APIEditableTable!
    private let timeoutField = NSTextField()
    private let redirects = NSButton(checkboxWithTitle: "Follow redirects", target: nil, action: nil)
    private let certificates = NSButton(checkboxWithTitle: "Check the server's certificate (untick for a local server with a self-made one)", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var environmentRows: [NSView] = []

    /// Opens the sheet on an environment; `completion` gets what was saved, or nil.
    static func present(in controller: APIClientController, environment: APIEnvironment, isNew: Bool, completion: @escaping (APIEnvironment?) -> Void) {
        guard let window = controller.window?.window else { return }
        let sheet = APIEnvironmentSheet(controller: controller, subject: .environment(environment, isNew: isNew))
        sheet.completion = completion
        sheet.show(in: window)
    }

    static func present(in controller: APIClientController, collection: APICollection) {
        guard let window = controller.window?.window else { return }
        APIEnvironmentSheet(controller: controller, subject: .collection(collection)).show(in: window)
    }

    private init(controller: APIClientController, subject: Subject) {
        self.controller = controller
        self.subject = subject
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440), styleMask: [.titled], backing: .buffered, defer: true)
        super.init(window: window)
        build()
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static var open: [APIEnvironmentSheet] = []

    private func show(in parent: NSWindow) {
        guard let window else { return }
        APIEnvironmentSheet.open.append(self)             // sheets are kept alive until they close
        parent.beginSheet(window) { [weak self] _ in
            APIEnvironmentSheet.open.removeAll { $0 === self }
        }
    }

    private var isEnvironment: Bool {
        if case .environment = subject { return true }
        return false
    }

    // MARK: Building

    private func build() {
        guard let content = window?.contentView else { return }
        let theme = Settings.shared.theme
        let title = NSTextField(labelWithString: isEnvironment ? "Environment" : "Collection variables")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        picker.controlSize = .small
        picker.target = self
        picker.action = #selector(pickerChanged)
        let newButton = NSButton(title: "New", target: self, action: #selector(newEnvironmentClicked))
        let deleteButton = NSButton(title: "Delete…", target: self, action: #selector(deleteClicked))
        for button in [newButton, deleteButton] { button.bezelStyle = .rounded; button.controlSize = .small }
        let pickerRow = NSStackView(views: [label("Environment:"), picker, newButton, deleteButton])
        pickerRow.spacing = 8

        nameField.placeholderString = "Name"
        nameField.controlSize = .small
        nameField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let nameRow = NSStackView(views: [label("Name:"), nameField])
        nameRow.spacing = 8

        let rows: () -> [APIVariable] = { [weak self] in self?.variables ?? [] }
        table = APIEditableTable(columns: [
            .init(id: "on", title: "", width: 24, cell: { .toggle(rows()[$0].enabled) }, set: { [weak self] index, value in self?.change(index) { $0.enabled = value == "1" } }),
            .init(id: "name", title: "Name", width: 160, cell: { .text(rows()[$0].name, placeholder: "baseUrl") }, set: { [weak self] index, value in self?.change(index) { $0.name = value } }),
            .init(id: "value", title: "Value", width: nil, cell: { .text(rows()[$0].value, placeholder: "https://localhost:8080", secret: rows()[$0].secret) },
                  set: { [weak self] index, value in self?.change(index) { $0.value = value } }),
            .init(id: "secret", title: "Secret", width: 50, cell: { .toggle(rows()[$0].secret) }, set: { [weak self] index, value in self?.change(index) { $0.secret = value == "1" } }),
        ], addTip: "Add a variable", removeTip: "Remove the selected variable")
        table.count = { rows().count }
        table.emptyText = "Variables fill in {{name}} in addresses, headers and bodies."
        table.onAdd = { [weak self] in self?.variables.append(APIVariable("", "")) }
        table.onRemove = { [weak self] index in
            guard let self, self.variables.indices.contains(index) else { return }
            self.variables.remove(at: index)
        }
        table.translatesAutoresizingMaskIntoConstraints = false
        table.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = theme.lineNumber
        hint.stringValue = isEnvironment
            ? "A secret's value goes to your Keychain and is left out of the file, so it is safe to share the environment through git."
            : "Collection variables apply to every request in the collection; an environment's variable with the same name wins."

        timeoutField.controlSize = .small
        timeoutField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let formatter = NumberFormatter()
        formatter.minimum = 1
        formatter.maximum = 3600
        timeoutField.formatter = formatter
        let timeoutRow = NSStackView(views: [label("Give up after:"), timeoutField, label("seconds")])
        timeoutRow.spacing = 8
        environmentRows = [pickerRow, timeoutRow, redirects, certificates]

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.spacing = 8

        let column = NSStackView(views: [title, pickerRow, nameRow, table, hint, timeoutRow, redirects, certificates, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            table.widthAnchor.constraint(equalTo: column.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: column.widthAnchor),
            hint.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        if !isEnvironment { environmentRows.forEach { $0.isHidden = true } }
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        return field
    }

    private func change(_ index: Int, _ edit: (inout APIVariable) -> Void) {
        guard variables.indices.contains(index) else { return }
        edit(&variables[index])
    }

    private func load() {
        guard let workspace = controller?.workspace else { return }
        switch subject {
        case .environment(let environment, let isNew):
            picker.removeAllItems()
            for stored in workspace.environments {
                picker.addItem(withTitle: stored.value.name)
                picker.lastItem?.representedObject = stored.value.id
            }
            if isNew {
                picker.addItem(withTitle: environment.name + " (new)")
                picker.lastItem?.representedObject = environment.id
            }
            if let index = picker.itemArray.firstIndex(where: { $0.representedObject as? String == environment.id }) { picker.selectItem(at: index) }
            nameField.stringValue = environment.name
            variables = workspace.variables(of: environment)
            timeoutField.integerValue = Int(environment.timeout)
            redirects.state = environment.followsRedirects ? .on : .off
            certificates.state = environment.verifiesCertificates ? .on : .off
        case .collection(let collection):
            nameField.stringValue = collection.name
            nameField.isEditable = false
            variables = workspace.variables(of: collection)
        }
        table.reload()
    }

    /// What the sheet holds now, written back into the subject.
    private func collect() {
        window?.makeFirstResponder(nil)
        variables = variables.filter { !$0.name.isEmpty || !$0.value.isEmpty }
        switch subject {
        case .environment(var environment, let isNew):
            environment.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            if environment.name.isEmpty { environment.name = "Environment" }
            environment.variables = variables
            environment.timeout = Double(max(1, timeoutField.integerValue))
            environment.followsRedirects = redirects.state == .on
            environment.verifiesCertificates = certificates.state == .on
            subject = .environment(environment, isNew: isNew)
        case .collection(var collection):
            collection.variables = variables
            subject = .collection(collection)
        }
    }

    private func saveSubject() -> APIEnvironment? {
        guard let workspace = controller?.workspace else { return nil }
        collect()
        switch subject {
        case .environment(let environment, _):
            workspace.save(environment)
            return environment
        case .collection(let collection):
            workspace.save(collection)
            return nil
        }
    }

    // MARK: Buttons

    @objc private func pickerChanged() {
        guard let id = picker.selectedItem?.representedObject as? String, let workspace = controller?.workspace else { return }
        if case .environment(let current, _) = subject, current.id == id { return }
        _ = saveSubject()                                   // what was typed so far is not lost
        guard let next = workspace.environment(id: id) else { return }
        subject = .environment(next, isNew: false)
        load()
    }

    @objc private func newEnvironmentClicked() {
        _ = saveSubject()
        subject = .environment(APIEnvironment(name: "New Environment"), isNew: true)
        load()
        window?.makeFirstResponder(nameField)
    }

    @objc private func deleteClicked() {
        guard case .environment(let environment, let isNew) = subject, let window, let workspace = controller?.workspace else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the environment “\(environment.name)”?"
        alert.informativeText = "Its file is removed and its secrets are taken out of your Keychain."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if !isNew { workspace.delete(environmentID: environment.id) }
            if self.controller?.selectedEnvironmentID == environment.id { self.controller?.selectedEnvironmentID = nil }
            if let next = workspace.environments.first?.value {
                self.subject = .environment(next, isNew: false)
                self.load()
            } else {
                self.close(with: nil)
            }
        }
    }

    @objc private func cancelClicked() { close(with: nil) }

    @objc private func saveClicked() { close(with: saveSubject()) }

    private func close(with saved: APIEnvironment?) {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        completion?(saved)
        completion = nil
    }
}
