import Foundation
import GitCore

private final class RecordingRunner: GitCommandRunning, @unchecked Sendable {
    struct Call: Equatable { let arguments: [String]; let directory: URL? }
    var calls: [Call] = []
    var outputs: [GitCommandResult] = []

    func run(arguments: [String], currentDirectory: URL?) throws -> GitCommandResult {
        calls.append(Call(arguments: arguments, directory: currentDirectory))
        return outputs.isEmpty
            ? GitCommandResult(exitCode: 0, standardOutput: "", standardError: "")
            : outputs.removeFirst()
    }
}

private enum SelfTestError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): "テスト失敗: \(message)" }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SelfTestError.failed(message) }
}

private func makeRepositoryDirectory() throws -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: base.appendingPathComponent(".git"), withIntermediateDirectories: true)
    return base
}

private func runTests() throws {
    do {
        let result = try GitCommandRunner().run(arguments: ["--version"], currentDirectory: nil)
        try expect(result.standardOutput.hasPrefix("git version"), "実際のgitコマンドを起動できない")
    }

    do {
        let base = try makeRepositoryDirectory()
        let nested = base.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try GitService(runner: RecordingRunner()).repositoryRoot(containing: nested)
        try expect(root.standardizedFileURL == base.standardizedFileURL, "ネストしたフォルダからリポジトリルートを探索できない")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        _ = try GitService(runner: runner).commit(at: base, message: "変更を保存")
        try expect(runner.calls.map(\.arguments) == [["add", "--all"], ["commit", "--message", "変更を保存"]], "コミット前に全変更をステージしていない")
    }

    do {
        // A nested empty repository must not make the parent commit fail with
        // "does not have a commit checked out".
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = base.appendingPathComponent("GitOperationApp", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let command = GitCommandRunner()
        _ = try command.run(arguments: ["init", "--quiet", "-b", "main"], currentDirectory: base)
        _ = try command.run(arguments: ["config", "user.name", "Self Test"], currentDirectory: base)
        _ = try command.run(arguments: ["config", "user.email", "self-test@example.com"], currentDirectory: base)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try command.run(arguments: ["init", "--quiet", "-b", "main"], currentDirectory: nested)
        try Data("nested file\n".utf8).write(to: nested.appendingPathComponent("README.md"))
        _ = try GitService().commit(at: base, message: "親リポジトリへ保存")
        try expect(FileManager.default.fileExists(atPath: nested.appendingPathComponent(".git").path), "空の入れ子Gitメタデータを復元していない")
        let tracked = try command.run(arguments: ["ls-files", "--", "GitOperationApp/README.md"], currentDirectory: base)
        try expect(tracked.standardOutput.contains("GitOperationApp/README.md"), "入れ子フォルダのファイルを親リポジトリへ追加していない")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        runner.outputs = [
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "feature/test\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ]
        _ = try GitService(runner: runner).createOrSwitchBranch(at: base, branchName: "feature/test")
        try expect(runner.calls.last?.arguments == ["switch", "feature/test"], "既存ブランチへ切り替えていない")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        runner.outputs = [
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ]
        _ = try GitService(runner: runner).createOrSwitchBranch(at: base, branchName: "feature/new")
        try expect(runner.calls.last?.arguments == ["switch", "--create", "feature/new"], "新規ブランチを作成していない")
    }

    do {
        let runner = RecordingRunner()
        do {
            _ = try GitService(runner: runner).commit(at: URL(fileURLWithPath: "/tmp"), message: "  ")
            throw SelfTestError.failed("空のコミットメッセージを受理した")
        } catch GitServiceError.emptyCommitMessage {
            // Expected.
        }
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        runner.outputs = [
            GitCommandResult(exitCode: 0, standardOutput: "main\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "テストユーザー\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "test@example.com\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "https://github.com/example/repo.git\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "git version 2.50.0\n", standardError: "")
        ]
        let settings = try GitService(runner: runner).repositorySettings(at: base)
        try expect(settings.currentBranch == "main", "現在のブランチを読み取れない")
        try expect(settings.userName == "テストユーザー", "user.nameを読み取れない")
        try expect(settings.userEmail == "test@example.com", "user.emailを読み取れない")
        try expect(settings.originURL.hasPrefix("https://github.com/"), "origin URLを読み取れない")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        runner.outputs = [
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "origin\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ]
        try GitService(runner: runner).updateRepositorySettings(
            at: base,
            userName: "New User",
            userEmail: "new@example.com",
            originURL: "https://github.com/example/new.git"
        )
        try expect(runner.calls.last?.arguments == ["remote", "set-url", "origin", "https://github.com/example/new.git"], "既存originを更新していない")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        let service = GitService(runner: runner)
        try service.updateGitHubRepositoryDraft(
            at: base,
            username: "octocat",
            repositoryName: "hello-world",
            isPrivate: true
        )
        try expect(
            runner.calls.map(\.arguments) == [
                ["config", "--local", "gitoperation.githubUsername", "octocat"],
                ["config", "--local", "gitoperation.repositoryName", "hello-world"],
                ["config", "--local", "gitoperation.private", "true"]
            ],
            "GitHubリポジトリ設定をローカルGit設定へ保存していない"
        )
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        runner.outputs = [
            GitCommandResult(exitCode: 0, standardOutput: "git@github.com:example/repo.git\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "ref\tHEAD\n", standardError: "")
        ]
        _ = try GitService(runner: runner).checkGitHubConnection(at: base)
        try expect(runner.calls.last?.arguments == ["ls-remote", "origin"], "GitHub接続確認が読み取り専用になっていない")
    }

    do {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let envURL = base.appendingPathComponent(".env")
        try """
        GIT_USER_NAME="Test User"
        GIT_USER_EMAIL=test@example.com
        GITHUB_USERNAME=test-owner
        GITHUB_TOKEN=secret-token # local only
        """.write(to: envURL, atomically: true, encoding: .utf8)
        let configuration = try DotEnvConfiguration.load(from: envURL)
        try expect(configuration.gitUserName == "Test User", ".envからユーザー名を読めない")
        try expect(configuration.gitUserEmail == "test@example.com", ".envからメールを読めない")
        try expect(configuration.githubUsername == "test-owner", ".envからGitHubユーザー名を読めない")
        try expect(configuration.githubToken == "secret-token", ".envの末尾コメントを除去できない")
    }

    do {
        let github = GitHubRepositoryService()
        let remote = try github.remoteURL(username: "octocat", repositoryName: "hello-world")
        try expect(remote == "https://github.com/octocat/hello-world.git", "GitHubのorigin URLが正しくない")
        do {
            _ = try github.remoteURL(username: "bad/user", repositoryName: "repo")
            throw SelfTestError.failed("不正なGitHubユーザー名を受理した")
        } catch GitHubRepositoryError.invalidUsername {
            // Expected.
        }
        let notFound = GitHubRepositoryError.repositoryNotFound(username: "octocat", name: "missing")
        try expect(notFound.localizedDescription.contains("まだ作成されていません"), "GitHubの404を未作成として説明できない")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        runner.outputs = [
            GitCommandResult(exitCode: 0, standardOutput: "https://github.com/example/empty.git\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "abc123\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "main\n", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            GitCommandResult(exitCode: 0, standardOutput: "abc123\trefs/heads/main\n", standardError: "")
        ]
        let result = try GitService(runner: runner).checkAndInitializeGitHubRemote(at: base)
        try expect(result.initializedMain, "空のGitHubリモートを初期化していない")
        try expect(runner.calls.contains { $0.arguments == ["push", "--set-upstream", "origin", "main"] }, "mainをoriginへ送信していない")
        try expect(runner.calls.last?.arguments == ["ls-remote", "origin"], "初期化後にリモートを再確認していない")
    }

    do {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try GitService().initializeRepositoryDefaults(at: base)
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path), "Git対象フォルダを初期化していない")
        let branch = try GitCommandRunner().run(arguments: ["branch", "--show-current"], currentDirectory: root)
        try expect(branch.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "main", "初期ブランチがmainではない")
    }

    do {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let child = parent.appendingPathComponent("SelectedWorkFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let runner = GitCommandRunner()
        _ = try runner.run(arguments: ["init", "--initial-branch=main"], currentDirectory: parent)
        let root = try GitService(runner: runner).initializeRepositoryDefaults(at: child)
        try expect(root.standardizedFileURL == child.standardizedFileURL, "選択フォルダではなく親リポジトリを作業フォルダにしている")
        try expect(FileManager.default.fileExists(atPath: child.appendingPathComponent(".git").path), "選択フォルダをリポジトリとして初期化していない")
    }

    do {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = GitCommandRunner()
        _ = try runner.run(arguments: ["init", "--initial-branch=main"], currentDirectory: base)
        let service = GitService(runner: runner)
        try service.updateRepositorySettings(
            at: base,
            userName: "Integration Test",
            userEmail: "integration@example.com",
            originURL: "https://github.com/example/integration.git"
        )
        let settings = try service.repositorySettings(at: base)
        try expect(settings.userName == "Integration Test", "実リポジトリへuser.nameを保存できない")
        try expect(settings.userEmail == "integration@example.com", "実リポジトリへuser.emailを保存できない")
        try expect(settings.originURL == "https://github.com/example/integration.git", "実リポジトリへoriginを保存できない")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let ignoredFile = base.appendingPathComponent("build output.log")
        let ignoredDirectory = base.appendingPathComponent("Generated", isDirectory: true)
        try Data().write(to: ignoredFile)
        try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)

        let service = GitService(runner: RecordingRunner())
        let first = try service.addToGitIgnore(items: [ignoredFile, ignoredDirectory])
        let contents = try String(contentsOf: base.appendingPathComponent(".gitignore"), encoding: .utf8)
        try expect(first.addedPatterns == ["/Generated/", "/build output.log"], ".gitignoreへ選択項目を登録できない")
        try expect(contents.contains("/Generated/\n") && contents.contains("/build output.log\n"), ".gitignoreの保存内容が正しくない")

        let second = try service.addToGitIgnore(items: [ignoredFile, ignoredDirectory])
        try expect(second.addedPatterns.isEmpty, ".gitignoreへ重複登録している")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        runner.outputs = [GitCommandResult(exitCode: 0, standardOutput: "* abc123 (HEAD -> main) Initial\n", standardError: "")]
        let result = try GitService(runner: runner).branchGraph(at: base)
        try expect(result.standardOutput.contains("main"), "ブランチ構成を取得できない")
        try expect(
            runner.calls.last?.arguments == ["log", "--all", "--graph", "--decorate", "--oneline", "--date-order", "--max-count=200"],
            "ブランチ構成のGitコマンドが正しくない"
        )
    }

    do {
        let parsed = GitPorcelainParser.parse(
            " M Sources/Changed.swift\0A  Sources/New.swift\0UU Sources/Conflict.swift\0" +
            " D Sources/Deleted.swift\0?? Notes/Draft.md\0!! Build/\0"
        )
        try expect(parsed["Sources/Changed.swift"] == .modified, "Modified状態を解析できない")
        try expect(parsed["Sources/New.swift"] == .added, "Added状態を解析できない")
        try expect(parsed["Sources/Conflict.swift"] == .conflict, "Conflict状態を解析できない")
        try expect(parsed["Sources/Deleted.swift"] == .deleted, "Deleted状態を解析できない")
        try expect(parsed["Notes/Draft.md"] == .unversioned, "Unversioned状態を解析できない")
        try expect(parsed["Build"] == .ignored, "Ignored状態を解析できない")

        let folderSnapshot = GitStatusSnapshot(
            repositoryRoot: URL(fileURLWithPath: "/tmp/FolderBadgeRepository", isDirectory: true),
            statusesByRelativePath: parsed
        )
        try expect(
            folderSnapshot.status(forRelativePath: "Sources", isDirectory: true) == .conflict,
            "フォルダ内の最優先状態をフォルダへ集約できない"
        )
        try expect(
            folderSnapshot.status(forRelativePath: "Notes", isDirectory: true) == .unversioned,
            "未登録ファイルを含むフォルダへ状態を集約できない"
        )
        try expect(
            folderSnapshot.status(forRelativePath: "Build", isDirectory: true) == .ignored,
            "無視対象フォルダの状態を集約できない"
        )
    }

    do {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = GitCommandRunner()
        _ = try runner.run(arguments: ["init", "--initial-branch=main"], currentDirectory: base)
        _ = try runner.run(arguments: ["config", "user.name", "Badge Test"], currentDirectory: base)
        _ = try runner.run(arguments: ["config", "user.email", "badge@example.com"], currentDirectory: base)
        try "ignored.log\n".write(to: base.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "initial\n".write(to: base.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        _ = try runner.run(arguments: ["add", ".gitignore", "tracked.txt"], currentDirectory: base)
        _ = try runner.run(arguments: ["commit", "-m", "initial"], currentDirectory: base)

        try "changed\n".write(to: base.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "added\n".write(to: base.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
        _ = try runner.run(arguments: ["add", "added.txt"], currentDirectory: base)
        try "draft\n".write(to: base.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
        try "ignored\n".write(to: base.appendingPathComponent("ignored.log"), atomically: true, encoding: .utf8)

        let snapshot = try GitStatusScanner().snapshot(containing: base)
        try expect(snapshot.status(forRelativePath: "tracked.txt", isDirectory: false) == .modified, "実リポジトリの変更状態を取得できない")
        try expect(snapshot.status(forRelativePath: "added.txt", isDirectory: false) == .added, "実リポジトリの追加状態を取得できない")
        try expect(snapshot.status(forRelativePath: "draft.txt", isDirectory: false) == .unversioned, "実リポジトリの未登録状態を取得できない")
        try expect(snapshot.status(forRelativePath: "ignored.log", isDirectory: false) == .ignored, "実リポジトリの無視状態を取得できない")
        try expect(snapshot.status(forRelativePath: "", isDirectory: true) == .modified, "フォルダへ配下の最優先状態を集約できない")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        _ = try GitService(runner: runner).sync(at: base)
        try expect(
            runner.calls.map(\.arguments) == [
                ["fetch", "--all", "--prune"],
                ["pull", "--ff-only"],
                ["push"]
            ],
            "同期をFetch、Pull、Pushの順で実行していない"
        )
    }

    do {
        let base = try makeRepositoryDirectory()
        let item = base.appendingPathComponent("Sources/Test.swift")
        try FileManager.default.createDirectory(at: item.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: item)
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        let service = GitService(runner: runner)
        _ = try service.add(at: item, items: [item])
        _ = try service.diff(at: item, items: [item])
        _ = try service.revert(at: item, items: [item])
        try expect(runner.calls[0].arguments == ["add", "--", "Sources/Test.swift"], "追加対象のパスが正しくない")
        try expect(runner.calls[1].arguments == ["diff", "--", "Sources/Test.swift"], "差分対象のパスが正しくない")
        try expect(
            runner.calls[2].arguments == ["restore", "--source=HEAD", "--staged", "--worktree", "--", "Sources/Test.swift"],
            "変更破棄の対象が正しくない"
        )
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        let service = GitService(runner: runner)
        _ = try service.createBranch(at: base, branchName: "feature/menu")
        _ = try service.switchBranch(at: base, branchName: "main")
        _ = try service.merge(at: base, branch: "feature/menu")
        _ = try service.rebase(at: base, branch: "main")
        _ = try service.reset(at: base, reference: "HEAD~1")
        try expect(runner.calls.contains { $0.arguments == ["switch", "--create", "feature/menu"] }, "ブランチを作成できない")
        try expect(runner.calls.contains { $0.arguments == ["switch", "main"] }, "ブランチを切り替えできない")
        try expect(runner.calls.contains { $0.arguments == ["merge", "feature/menu"] }, "マージコマンドが正しくない")
        try expect(runner.calls.contains { $0.arguments == ["rebase", "main"] }, "リベースコマンドが正しくない")
        try expect(runner.calls.contains { $0.arguments == ["reset", "--mixed", "HEAD~1"] }, "安全なmixed resetになっていない")
    }

    do {
        let base = try makeRepositoryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runner = RecordingRunner()
        let service = GitService(runner: runner)
        _ = try service.createPatch(at: base, range: "origin/main..HEAD")
        _ = try service.applyPatch(at: base, patchURL: URL(fileURLWithPath: "/tmp/change.patch"))
        _ = try service.updateSubmodules(at: base)
        _ = try service.bisect(at: base, arguments: "good HEAD~2")
        _ = try service.cleanup(at: base)
        try expect(runner.calls.contains { $0.arguments == ["format-patch", "origin/main..HEAD"] }, "パッチ作成コマンドが正しくない")
        try expect(runner.calls.contains { $0.arguments == ["am", "--3way", "/tmp/change.patch"] }, "パッチ適用コマンドが正しくない")
        try expect(runner.calls.contains { $0.arguments == ["submodule", "update", "--init", "--recursive"] }, "サブモジュール更新コマンドが正しくない")
        try expect(runner.calls.contains { $0.arguments == ["bisect", "good", "HEAD~2"] }, "Bisectコマンドが正しくない")
        try expect(runner.calls.contains { $0.arguments == ["clean", "-f", "-d"] }, "Cleanupコマンドが正しくない")
    }
}

do {
    try runTests()
    print("GitCoreSelfTest: 25件すべて成功")
} catch {
    print(error)
    exit(1)
}
