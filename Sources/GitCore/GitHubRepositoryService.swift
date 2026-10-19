import Foundation

public struct DotEnvConfiguration: Sendable, Equatable {
    public let gitUserName: String
    public let gitUserEmail: String
    public let githubUsername: String
    public let githubToken: String

    public init(gitUserName: String, gitUserEmail: String, githubUsername: String, githubToken: String) {
        self.gitUserName = gitUserName
        self.gitUserEmail = gitUserEmail
        self.githubUsername = githubUsername
        self.githubToken = githubToken
    }

    public static func load(from fileURL: URL) throws -> DotEnvConfiguration {
        let contents: String
        do {
            contents = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw GitHubRepositoryError.dotEnvNotFound(fileURL.path)
        }

        let values = parse(contents)
        let name = firstValue(in: values, keys: ["GIT_USER_NAME", "GIT_AUTHOR_NAME"])
        let email = firstValue(in: values, keys: ["GIT_USER_EMAIL", "GIT_AUTHOR_EMAIL"])
        let username = firstValue(in: values, keys: ["GITHUB_USERNAME", "GITHUB_OWNER"])
        let token = firstValue(in: values, keys: ["GITHUB_TOKEN", "GH_TOKEN"])

        guard !name.isEmpty else { throw GitHubRepositoryError.missingEnvironmentValue("GIT_USER_NAME") }
        guard !email.isEmpty else { throw GitHubRepositoryError.missingEnvironmentValue("GIT_USER_EMAIL") }
        guard !username.isEmpty else { throw GitHubRepositoryError.missingEnvironmentValue("GITHUB_USERNAME") }
        guard !token.isEmpty else { throw GitHubRepositoryError.missingEnvironmentValue("GITHUB_TOKEN") }
        return DotEnvConfiguration(
            gitUserName: name,
            gitUserEmail: email,
            githubUsername: username,
            githubToken: token
        )
    }

    static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") {
                line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value.removeFirst()
                value.removeLast()
            } else if let comment = value.firstIndex(of: "#"),
                      comment > value.startIndex,
                      value[value.index(before: comment)].isWhitespace {
                value = String(value[..<comment]).trimmingCharacters(in: .whitespaces)
            }
            guard !key.isEmpty else { continue }
            values[key] = value
        }
        return values
    }

    private static func firstValue(in values: [String: String], keys: [String]) -> String {
        for key in keys {
            let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        return ""
    }
}

public struct GitHubRepository: Sendable, Equatable {
    public let owner: String
    public let name: String
    public let cloneURL: String
    public let isPrivate: Bool

    public init(owner: String, name: String, cloneURL: String, isPrivate: Bool) {
        self.owner = owner
        self.name = name
        self.cloneURL = cloneURL
        self.isPrivate = isPrivate
    }
}

public struct GitHubRepositoryService: Sendable {
    private let session: URLSession
    private let apiBaseURL: URL

    public init(session: URLSession = .shared, apiBaseURL: URL = URL(string: "https://api.github.com")!) {
        self.session = session
        self.apiBaseURL = apiBaseURL
    }

    public func createRepository(
        username: String,
        name: String,
        token: String,
        isPrivate: Bool
    ) async throws -> GitHubRepository {
        let owner = try validatedUsername(username)
        let repositoryName = try validatedRepositoryName(name)
        let accessToken = try validatedToken(token)
        let authenticatedUser: UserResponse = try await request(
            path: "/user",
            method: "GET",
            token: accessToken,
            body: nil
        )
        guard authenticatedUser.login.caseInsensitiveCompare(owner) == .orderedSame else {
            throw GitHubRepositoryError.authenticatedUserMismatch(expected: owner, actual: authenticatedUser.login)
        }
        let body = try JSONEncoder().encode(CreateRepositoryRequest(name: repositoryName, isPrivate: isPrivate))
        let response: RepositoryResponse = try await request(path: "/user/repos", method: "POST", token: accessToken, body: body)
        return GitHubRepository(
            owner: response.owner.login,
            name: response.name,
            cloneURL: response.cloneURL,
            isPrivate: response.isPrivate
        )
    }

    public func testConnection(username: String, name: String, token: String) async throws -> GitHubRepository {
        let owner = try validatedUsername(username)
        let repositoryName = try validatedRepositoryName(name)
        let accessToken = try validatedToken(token)
        let encodedOwner = owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? owner
        let encodedName = repositoryName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repositoryName
        let response: RepositoryResponse
        do {
            response = try await request(
                path: "/repos/\(encodedOwner)/\(encodedName)",
                method: "GET",
                token: accessToken,
                body: nil
            )
        } catch GitHubRepositoryError.apiFailure(let statusCode, _) where statusCode == 404 {
            throw GitHubRepositoryError.repositoryNotFound(username: owner, name: repositoryName)
        }
        return GitHubRepository(
            owner: response.owner.login,
            name: response.name,
            cloneURL: response.cloneURL,
            isPrivate: response.isPrivate
        )
    }

    public func remoteURL(username: String, repositoryName: String) throws -> String {
        let owner = try validatedUsername(username)
        let name = try validatedRepositoryName(repositoryName)
        return "https://github.com/\(owner)/\(name).git"
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        token: String,
        body: Data?
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: apiBaseURL) else {
            throw GitHubRepositoryError.invalidAPIResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubRepositoryError.invalidAPIResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorResponse.self, from: data).message)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GitHubRepositoryError.apiFailure(statusCode: http.statusCode, message: message)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GitHubRepositoryError.invalidAPIResponse
        }
    }

    private func validatedUsername(_ value: String) throws -> String {
        let username = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$"#
        guard username.range(of: pattern, options: .regularExpression) != nil else {
            throw GitHubRepositoryError.invalidUsername
        }
        return username
    }

    private func validatedRepositoryName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[A-Za-z0-9._-]{1,100}$"#
        guard name != ".", name != "..", name.range(of: pattern, options: .regularExpression) != nil else {
            throw GitHubRepositoryError.invalidRepositoryName
        }
        return name
    }

    private func validatedToken(_ value: String) throws -> String {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GitHubRepositoryError.missingEnvironmentValue("GITHUB_TOKEN") }
        return token
    }
}

private struct CreateRepositoryRequest: Encodable {
    let name: String
    let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case isPrivate = "private"
    }
}

private struct RepositoryResponse: Decodable {
    struct Owner: Decodable { let login: String }
    let name: String
    let owner: Owner
    let cloneURL: String
    let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case name, owner
        case cloneURL = "clone_url"
        case isPrivate = "private"
    }
}

private struct APIErrorResponse: Decodable { let message: String }
private struct UserResponse: Decodable { let login: String }

public enum GitHubRepositoryError: LocalizedError, Equatable {
    case dotEnvNotFound(String)
    case missingEnvironmentValue(String)
    case invalidUsername
    case invalidRepositoryName
    case repositoryNotFound(username: String, name: String)
    case authenticatedUserMismatch(expected: String, actual: String)
    case apiFailure(statusCode: Int, message: String)
    case invalidAPIResponse

    public var errorDescription: String? {
        switch self {
        case .dotEnvNotFound(let path): ".envファイルを読み込めません: \(path)"
        case .missingEnvironmentValue(let key): ".envに \(key) を設定してください。"
        case .invalidUsername: "GitHubユーザー名の形式が正しくありません。"
        case .invalidRepositoryName: "リポジトリ名は英数字、ピリオド、ハイフン、アンダースコアで1〜100文字にしてください。"
        case .repositoryNotFound(let username, let name):
            "GitHubリポジトリ \(username)/\(name) はまだ作成されていません。"
        case .authenticatedUserMismatch(let expected, let actual):
            ".envのGITHUB_USERNAME（\(expected)）とトークンの所有者（\(actual)）が一致しません。"
        case .apiFailure(let statusCode, let message): "GitHub APIエラー（\(statusCode)）: \(message)"
        case .invalidAPIResponse: "GitHubから不正な応答を受信しました。"
        }
    }
}
