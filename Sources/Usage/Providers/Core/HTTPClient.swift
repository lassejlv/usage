import Foundation

struct HTTPRequest {
    var method: String
    var url: URL
    var headers: [String: String] = [:]
    var body: Data?
    var timeout: TimeInterval = 15
}

struct HTTPResponse {
    var statusCode: Int
    var body: Data
    var headers: [String: String]

    var isSuccess: Bool { (200..<300).contains(statusCode) }

    func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

enum HTTPError: Error {
    case connectionFailed
    case invalidResponse
}

/// Thin async wrapper over URLSession so providers don't touch URLSession directly and can be tested
/// against a stub later.
struct HTTPClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw HTTPError.connectionFailed
        }

        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.invalidResponse
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return HTTPResponse(statusCode: http.statusCode, body: data, headers: headers)
    }
}
