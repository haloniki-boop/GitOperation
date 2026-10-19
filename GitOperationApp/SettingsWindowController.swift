import AppKit
import OSLog
#if canImport(GitCore)
import GitCore
#endif

@MainActor
final class SettingsWindowController: NSWindowController {
    private let service = GitService()
    private let githubService = GitHubRepositoryService()
    private let logger = Logger(subsystem: "jp.local.gitoperation", category: "Settings")
    private var repositoryURL: URL?
    private var githubToken = ""
    private var configuredOriginURL = ""

    private let repositoryLabel = NSTextField(labelWithString: "未選択")
    private let branchLabel = NSTextField(labelWithString: "—")
    private let gitVersionLabel = NSTextField(labelWithString: "—")
    private let userNameField = NSTextField()
    private let userEmailField = NSTextField()
    private let githubUsernameField = NSTextField()
    private let repositoryNameField = NSTextField()
    private let originField = NSTextField()
    private let privateRepositoryCheckbox = NSButton(checkboxWithTitle: "非公開リポジトリ", target: nil, action: nil)
    private let envStatusLabel = NSTextField(labelWithString: "未読込")
    private let connectionLabel = NSTextField(labelWithString: "未確認")
    private let gitInstallButton = NSButton(title: "Gitを確認／インストール", target: nil, action: nil)
    private let loadEnvButton = NSButton(title: ".envを読み込む", target: nil, action: nil)
    private let createButton = NSButton(title: "GitHubリポジトリを作成", target: nil, action: nil)
    private let saveButton = NSButton(title: "設定を保存", target: nil, action: nil)
    private let checkButton = NSButton(title: "GitHub接続を確認", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        window.title = "Git操作 — 設定"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        buildContent()
    }

    func show(repositoryPath: String? = nil) {
        logger.notice("Showing settings window")
        NSApp.activate(ignoringOtherApps: true)
        guard let window else {
            logger.error("Settings window is unavailable")
            return
        }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if let repositoryPath {
            loadRepository(URL(fileURLWithPath: repositoryPath))
        } else {
            clearRepositorySelection()
        }
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "GitHubリポジトリ作成")
        heading.font = .systemFont(ofSize: 24, weight: .bold)
        stack.addArrangedSubview(heading)

        gitInstallButton.target = self
        gitInstallButton.action = #selector(checkOrInstallGit)
        stack.addArrangedSubview(gitInstallButton)

        let choose = NSButton(title: "作業フォルダを選択…", target: self, action: #selector(chooseRepository))
        stack.addArrangedSubview(choose)
        stack.addArrangedSubview(row(label: "作業フォルダ", control: repositoryLabel))
        stack.addArrangedSubview(row(label: "現在のブランチ", control: branchLabel))
        stack.addArrangedSubview(row(label: "Git", control: gitVersionLabel))

        loadEnvButton.target = self
        loadEnvButton.action = #selector(loadDotEnv)
        let envActions = NSStackView()
        envActions.orientation = .horizontal
        envActions.spacing = 10
        envActions.addArrangedSubview(loadEnvButton)
        envStatusLabel.textColor = .secondaryLabelColor
        envActions.addArrangedSubview(envStatusLabel)
        stack.addArrangedSubview(row(label: ".env", control: envActions))
        stack.addArrangedSubview(row(label: "ユーザー名", control: userNameField))
        stack.addArrangedSubview(row(label: "メール", control: userEmailField))
        githubUsernameField.placeholderString = "GitHubユーザー名"
        stack.addArrangedSubview(row(label: "GitHubユーザー", control: githubUsernameField))
        repositoryNameField.placeholderString = "repository-name"
        stack.addArrangedSubview(row(label: "リポジトリ名", control: repositoryNameField))
        stack.addArrangedSubview(row(label: "公開範囲", control: privateRepositoryCheckbox))
        originField.placeholderString = "https://github.com/owner/repository.git"
        originField.isEditable = false
        stack.addArrangedSubview(row(label: "origin URL", control: originField))

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 10
        saveButton.target = self
        saveButton.action = #selector(saveSettings)
        checkButton.target = self
        checkButton.action = #selector(checkGitHubConnection)
        actions.addArrangedSubview(saveButton)
        actions.addArrangedSubview(checkButton)
        stack.addArrangedSubview(actions)

        createButton.target = self
        createButton.action = #selector(createGitHubRepository)
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        stack.addArrangedSubview(createButton)

        connectionLabel.textColor = .secondaryLabelColor
        connectionLabel.maximumNumberOfLines = 3
        stack.addArrangedSubview(row(label: "GitHub接続", control: connectionLabel))

        let note = NSTextField(wrappingLabelWithString: ".envからGIT_USER_NAME、GIT_USER_EMAIL、GITHUB_USERNAME、GITHUB_TOKENを読み込みます。トークンは保存・表示せず、GitHub APIへの通信時だけ使用します。.envは自動的に.gitignoreへ追加します。")
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 3
        stack.addArrangedSubview(note)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])
        setEnabled(false)
    }

    private func row(label: String, control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: 120).isActive = true
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 470).isActive = true
        row.addArrangedSubview(title)
        row.addArrangedSubview(control)
        return row
    }

    @objc private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "GitHubリポジトリにする作業フォルダを選択"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let root = try service.initializeRepositoryDefaults(at: url)
            loadRepository(root)
            tryLoadDotEnv(showSuccess: false)
        } catch {
            showError(error)
        }
    }

    private func loadRepository(_ url: URL) {
        do {
            let settings = try service.repositorySettings(at: url)
            repositoryURL = settings.repositoryRoot
            repositoryLabel.stringValue = settings.repositoryRoot.path
            branchLabel.stringValue = settings.currentBranch.isEmpty ? "（detached HEAD）" : settings.currentBranch
            gitVersionLabel.stringValue = settings.gitVersion
            userNameField.stringValue = settings.userName
            userEmailField.stringValue = settings.userEmail
            let draft = try service.githubRepositoryDraft(at: settings.repositoryRoot)
            githubUsernameField.stringValue = draft.username
            repositoryNameField.stringValue = draft.repositoryName.isEmpty
                ? settings.repositoryRoot.lastPathComponent
                : draft.repositoryName
            privateRepositoryCheckbox.state = draft.isPrivate ? .on : .off
            configuredOriginURL = settings.originURL
            originField.stringValue = settings.originURL
            updateDisplayedOriginURL()
            connectionLabel.stringValue = "未確認"
            connectionLabel.textColor = .secondaryLabelColor
            setEnabled(true)
            if !settings.originURL.isEmpty { verifyGitHubConnection() }
        } catch {
            showError(error)
        }
    }

    @objc private func saveSettings() {
        guard let repositoryURL else { return }
        do {
            let username = githubUsernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let repositoryName = repositoryNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !username.isEmpty {
                _ = try githubService.remoteURL(username: username, repositoryName: repositoryName)
            }
            try service.updateRepositorySettings(
                at: repositoryURL,
                userName: userNameField.stringValue,
                userEmail: userEmailField.stringValue,
                originURL: configuredOriginURL
            )
            try service.updateGitHubRepositoryDraft(
                at: repositoryURL,
                username: username,
                repositoryName: repositoryName,
                isPrivate: privateRepositoryCheckbox.state == .on
            )
            loadRepository(repositoryURL)
            showMessage("設定を保存しました", detail: "作業者情報とGitHubリポジトリ設定を、このリポジトリだけに保存しました。")
        } catch {
            showError(error)
        }
    }

    @objc private func checkGitHubConnection() {
        if !githubToken.isEmpty,
           !githubUsernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !repositoryNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            verifyGitHubAPIConnection()
        } else {
            verifyGitHubConnection()
        }
    }

    @objc private func loadDotEnv() {
        tryLoadDotEnv(showSuccess: true)
    }

    private func tryLoadDotEnv(showSuccess: Bool) {
        guard let repositoryURL else { return }
        do {
            let envURL = repositoryURL.appendingPathComponent(".env")
            let configuration = try DotEnvConfiguration.load(from: envURL)
            githubToken = configuration.githubToken
            userNameField.stringValue = configuration.gitUserName
            userEmailField.stringValue = configuration.gitUserEmail
            githubUsernameField.stringValue = configuration.githubUsername
            updateDisplayedOriginURL()
            try ensureDotEnvIsIgnored(at: repositoryURL)
            envStatusLabel.stringValue = "読込済み（トークンは非表示）"
            envStatusLabel.textColor = .systemGreen
            if showSuccess {
                showMessage(".envを読み込みました", detail: "作業者情報とGitHubユーザー名を反映しました。トークンは画面やGit設定へ保存しません。")
            }
        } catch {
            githubToken = ""
            envStatusLabel.stringValue = "読込失敗"
            envStatusLabel.textColor = .systemRed
            if showSuccess { showError(error) }
        }
    }

    @objc private func createGitHubRepository() {
        guard let repositoryURL else { return }
        let name = repositoryNameField.stringValue
        let username = githubUsernameField.stringValue
        let token = githubToken
        guard !token.isEmpty else {
            showError(GitHubRepositoryError.missingEnvironmentValue("GITHUB_TOKEN"))
            return
        }

        do {
            _ = try githubService.remoteURL(username: username, repositoryName: name)
            try service.updateRepositorySettings(
                at: repositoryURL,
                userName: userNameField.stringValue,
                userEmail: userEmailField.stringValue,
                originURL: ""
            )
            try ensureDotEnvIsIgnored(at: repositoryURL)
        } catch {
            showError(error)
            return
        }

        createButton.isEnabled = false
        checkButton.isEnabled = false
        connectionLabel.stringValue = "GitHubに作成中…"
        connectionLabel.textColor = .secondaryLabelColor
        let githubService = githubService
        let isPrivate = privateRepositoryCheckbox.state == .on
        Task { [weak self] in
            guard let self else { return }
            do {
                let repository = try await githubService.createRepository(
                    username: username,
                    name: name,
                    token: token,
                    isPrivate: isPrivate
                )
                try service.updateRepositorySettings(
                    at: repositoryURL,
                    userName: userNameField.stringValue,
                    userEmail: userEmailField.stringValue,
                    originURL: repository.cloneURL
                )
                self.configuredOriginURL = repository.cloneURL
                _ = try await githubService.testConnection(username: repository.owner, name: repository.name, token: token)
                self.originField.stringValue = repository.cloneURL
                self.connectionLabel.stringValue = "接続成功 — GitHubリポジトリを作成して確認しました"
                self.connectionLabel.textColor = .systemGreen
                self.showMessage("GitHubリポジトリを作成しました", detail: repository.cloneURL)
            } catch {
                self.connectionLabel.stringValue = "作成／接続失敗 — \(error.localizedDescription)"
                self.connectionLabel.textColor = .systemRed
            }
            self.createButton.isEnabled = true
            self.checkButton.isEnabled = true
        }
    }

    private func verifyGitHubAPIConnection() {
        let username = githubUsernameField.stringValue
        let name = repositoryNameField.stringValue
        let token = githubToken
        checkButton.isEnabled = false
        connectionLabel.stringValue = "確認中…"
        let githubService = githubService
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await githubService.testConnection(username: username, name: name, token: token)
                self.connectionLabel.stringValue = "接続成功 — GitHub APIからリポジトリを確認できました"
                self.connectionLabel.textColor = .systemGreen
            } catch GitHubRepositoryError.repositoryNotFound(_, _) {
                self.connectionLabel.stringValue = "未作成 — 「GitHubリポジトリを作成」を押してください"
                self.connectionLabel.textColor = .systemOrange
            } catch {
                self.connectionLabel.stringValue = "接続失敗 — \(error.localizedDescription)"
                self.connectionLabel.textColor = .systemRed
            }
            self.checkButton.isEnabled = true
        }
    }

    private func ensureDotEnvIsIgnored(at root: URL) throws {
        let ignoreURL = root.appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: ignoreURL, encoding: .utf8)) ?? ""
        let lines = Set(existing.split(whereSeparator: \.isNewline).map(String.init))
        guard !lines.contains(".env"), !lines.contains("/.env") else { return }
        var updated = existing
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated.append("\n") }
        updated.append(".env\n")
        try updated.write(to: ignoreURL, atomically: true, encoding: .utf8)
    }

    private func updateDisplayedOriginURL() {
        if !configuredOriginURL.isEmpty {
            originField.stringValue = configuredOriginURL
            return
        }
        originField.stringValue = (try? githubService.remoteURL(
            username: githubUsernameField.stringValue,
            repositoryName: repositoryNameField.stringValue
        )) ?? ""
    }

    @objc private func checkOrInstallGit() {
        do {
            let result = try GitCommandRunner().run(arguments: ["--version"], currentDirectory: nil)
            gitVersionLabel.stringValue = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            showMessage("Gitは利用できます", detail: gitVersionLabel.stringValue)
        } catch {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            process.arguments = ["--install"]
            do {
                try process.run()
                process.waitUntilExit()
                showMessage("Gitのインストールを開始しました", detail: "表示されたCommand Line Toolsの案内に従い、完了後にもう一度確認してください。")
            } catch {
                showError(error)
            }
        }
    }

    private func verifyGitHubConnection() {
        guard let repositoryURL else { return }
        checkButton.isEnabled = false
        connectionLabel.stringValue = "確認中…"
        let service = service
        DispatchQueue.global(qos: .userInitiated).async { [self, service, repositoryURL] in
            let outcome = Result { try service.checkAndInitializeGitHubRemote(at: repositoryURL) }
            DispatchQueue.main.async {
                self.checkButton.isEnabled = true
                switch outcome {
                case .success(let result):
                    if result.initializedMain {
                        self.connectionLabel.stringValue = "接続成功 — 空のリモートへ初期リポジトリ（main）を登録しました"
                    } else {
                        self.connectionLabel.stringValue = "接続成功 — origin の参照を取得できました"
                    }
                    self.connectionLabel.textColor = .systemGreen
                case .failure(let error):
                    self.connectionLabel.stringValue = "接続失敗 — \(error.localizedDescription)"
                    self.connectionLabel.textColor = .systemRed
                }
            }
        }
    }

    private func clearRepositorySelection() {
        repositoryURL = nil
        repositoryLabel.stringValue = "未選択"
        branchLabel.stringValue = "—"
        gitVersionLabel.stringValue = "—"
        userNameField.stringValue = ""
        userEmailField.stringValue = ""
        githubUsernameField.stringValue = ""
        repositoryNameField.stringValue = ""
        originField.stringValue = ""
        configuredOriginURL = ""
        githubToken = ""
        envStatusLabel.stringValue = "未読込"
        connectionLabel.stringValue = "未確認"
        connectionLabel.textColor = .secondaryLabelColor
        setEnabled(false)
    }

    private func setEnabled(_ enabled: Bool) {
        userNameField.isEnabled = enabled
        userEmailField.isEnabled = enabled
        githubUsernameField.isEnabled = enabled
        repositoryNameField.isEnabled = enabled
        privateRepositoryCheckbox.isEnabled = enabled
        originField.isEnabled = enabled
        loadEnvButton.isEnabled = enabled
        createButton.isEnabled = enabled
        saveButton.isEnabled = enabled
        checkButton.isEnabled = enabled
    }

    private func showError(_ error: Error) {
        showMessage("操作を完了できません", detail: error.localizedDescription, style: .critical)
    }

    private func showMessage(_ title: String, detail: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) }
    }
}
