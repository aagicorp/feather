import Foundation

/// Turns a request and its variables into what is sent, sends it, and hands back the answer with its timing.
/// Bodies stream to a temporary file, so a large download never sits in memory; small ones are read back.
final class APIRequestSender: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    /// Answers up to this size are kept in memory; larger ones stay in `bodyFile`.
    static let maxBodyInMemory = 50 * 1024 * 1024

    struct Failure: Error, Equatable {
        let message: String
        var localizedDescription: String { message }
    }

    /// Everything the request needs from its surroundings.
    struct Context {
        var variables: APIVariables
        /// The auth chain above the request: folders innermost first, then the collection.
        var inheritedAuth: [APIAuth] = []
        var environment: APIEnvironment?
        /// For relative file paths in multipart bodies.
        var projectRoot: URL?
    }

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var followsRedirects = true
    private var verifiesCertificates = true
    private var startedAt: CFAbsoluteTime = 0
    private var completion: ((Result<APIResponse, Failure>) -> Void)?

    // MARK: Resolving

    /// The request with variables replaced and auth applied, or why it cannot be sent.
    static func resolve(_ request: APIRequest, context: Context) throws -> APIResolvedRequest {
        let variables = context.variables
        var urlText = variables.resolve(request.url.trimmingCharacters(in: .whitespaces))
        if !urlText.contains("://") { urlText = "http://" + urlText }
        guard var components = URLComponents(string: urlText) ?? URLComponents(string: urlText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            throw Failure(message: "The address is not a valid URL: \(urlText)")
        }
        var query = components.queryItems ?? []
        for param in request.params where param.enabled && !param.name.isEmpty {
            query.append(URLQueryItem(name: variables.resolve(param.name), value: variables.resolve(param.value)))
        }
        var headers: [(String, String)] = request.headers.filter { $0.enabled && !$0.name.isEmpty }
            .map { (variables.resolve($0.name), variables.resolve($0.value)) }

        // Auth: the request's own, else the nearest folder's, else the collection's.
        let auth = ([request.auth] + context.inheritedAuth).first { $0.kind != .inherit } ?? .none
        switch auth.kind {
        case .bearer: headers.append(("Authorization", "Bearer " + variables.resolve(auth.token)))
        case .basic:
            let pair = variables.resolve(auth.username) + ":" + variables.resolve(auth.password)
            headers.append(("Authorization", "Basic " + Data(pair.utf8).base64EncodedString()))
        case .apiKey:
            if auth.keyIn == .header { headers.append((variables.resolve(auth.keyName), variables.resolve(auth.keyValue))) }
            else { query.append(URLQueryItem(name: variables.resolve(auth.keyName), value: variables.resolve(auth.keyValue))) }
        case .none, .inherit: break
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, url.host != nil else { throw Failure(message: "The address needs a host: \(urlText)") }

        var body: Data?
        var description: String?
        switch request.body.kind {
        case .none: break
        case .raw:
            let text = variables.resolve(request.body.text)
            body = Data(text.utf8)
            if !headers.contains(where: { $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                headers.append(("Content-Type", request.body.contentType))
            }
        case .urlencoded, .form:
            var form = URLComponents()
            form.queryItems = request.body.fields.filter { $0.enabled && !$0.name.isEmpty }
                .map { URLQueryItem(name: variables.resolve($0.name), value: variables.resolve($0.value)) }
            body = Data((form.percentEncodedQuery ?? "").utf8)
            headers.append(("Content-Type", "application/x-www-form-urlencoded"))
        case .multipart:
            let boundary = "FeatherBoundary" + UUID().uuidString.prefix(8)
            var data = Data()
            for field in request.body.fields where field.enabled && !field.name.isEmpty {
                data += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(variables.resolve(field.name))\"\r\n\r\n\(variables.resolve(field.value))\r\n".utf8)
            }
            for file in request.body.files where file.enabled {
                let url = file.path.hasPrefix("/") ? URL(fileURLWithPath: file.path) : (context.projectRoot ?? URL(fileURLWithPath: NSHomeDirectory())).appendingPathComponent(file.path)
                guard let contents = try? Data(contentsOf: url) else { throw Failure(message: "The file to upload was not found: \(file.path)") }
                data += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(url.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
                data += contents
                data += Data("\r\n".utf8)
            }
            data += Data("--\(boundary)--\r\n".utf8)
            body = data
            headers.append(("Content-Type", "multipart/form-data; boundary=\(boundary)"))
            description = "multipart form, \(request.body.fields.count) fields, \(request.body.files.count) files"
        }
        return APIResolvedRequest(method: request.method, url: url, headers: headers.map { (name: $0.0, value: $0.1) }, body: body, bodyDescription: description)
    }

    // MARK: Sending

    /// Sends and calls back on the main queue. Only one request per sender at a time; `cancel()` stops it.
    func send(_ resolved: APIResolvedRequest, environment: APIEnvironment?, completion: @escaping (Result<APIResponse, Failure>) -> Void) {
        cancel()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = environment?.timeout ?? 30
        configuration.timeoutIntervalForResource = max(environment?.timeout ?? 30, 60) * 4
        // Cookies are the jar's business (APICookies.swift): the system would drop a Secure cookie from
        // http://localhost, which is how a local back end signs you in.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        followsRedirects = environment?.followsRedirects ?? true
        verifiesCertificates = environment?.verifiesCertificates ?? true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        self.completion = completion
        var urlRequest = URLRequest(url: resolved.url)
        urlRequest.httpMethod = resolved.method.rawValue
        for header in resolved.headers { urlRequest.addValue(header.value, forHTTPHeaderField: header.name) }
        urlRequest.httpBody = resolved.body
        startedAt = CFAbsoluteTimeGetCurrent()
        let task = session.downloadTask(with: urlRequest)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        completion = nil
    }

    var isSending: Bool { task != nil }

    private func finish(_ result: Result<APIResponse, Failure>) {
        let completion = self.completion
        self.completion = nil
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        DispatchQueue.main.async { completion?(result) }
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(followsRedirects ? request : nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if !verifiesCertificates, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let duration = CFAbsoluteTimeGetCurrent() - startedAt
        guard let http = downloadTask.response as? HTTPURLResponse else {
            finish(.failure(Failure(message: "No HTTP answer came back.")))
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int) ?? 0
        var body = Data()
        var bodyFile: URL?
        if size <= APIRequestSender.maxBodyInMemory {
            body = (try? Data(contentsOf: location)) ?? Data()
        } else {
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent("feather-api-\(UUID().uuidString).body")
            try? FileManager.default.moveItem(at: location, to: kept)
            bodyFile = kept
        }
        let headers = http.allHeaderFields.compactMap { key, value -> (name: String, value: String)? in
            guard let name = key as? String else { return nil }
            return (name, String(describing: value))
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        let cookies = http.url.map { APICookieParser.cookies(in: headers, for: $0) } ?? []
        finish(.success(APIResponse(status: http.statusCode, statusText: APIRequestSender.statusText(http.statusCode),
                                    headers: headers, body: body, bodyFile: bodyFile, duration: duration, size: size, url: http.url, cookies: cookies)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }                 // success was reported from didFinishDownloadingTo
        if (error as NSError).code == NSURLErrorCancelled { finish(.failure(Failure(message: "Cancelled."))); return }
        finish(.failure(Failure(message: APIRequestSender.plainMessage(for: error))))
    }

    /// The reason phrase HTTP uses ("OK", "Not Found"), which reads better than Foundation's "No Error".
    static func statusText(_ code: Int) -> String {
        let known: [Int: String] = [200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 301: "Moved Permanently",
                                    302: "Found", 304: "Not Modified", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                                    404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 422: "Unprocessable Entity",
                                    429: "Too Many Requests", 500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable",
                                    504: "Gateway Timeout"]
        return known[code] ?? HTTPURLResponse.localizedString(forStatusCode: code).capitalized
    }

    /// The system's wording, made a little friendlier for the common cases.
    static func plainMessage(for error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorCannotConnectToHost: return "Nothing is listening at that address. Is the server running?"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "The host name could not be found."
        case NSURLErrorTimedOut: return "The server did not answer in time."
        case NSURLErrorNotConnectedToInternet: return "This Mac is not connected to the internet."
        case NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed:
            return "The server's certificate is not trusted. The environment can be set to skip certificate checks for local servers."
        default: return nsError.localizedDescription
        }
    }
}
