import Foundation


public enum ResponseError: Error {
    case nilData
    case nonHTTPResponse
    case tokenError
    
}

public enum HTTPMethod: String {
    case GET
    case POST
}

public extension HTTPMethod {
    var adapter: AnyAdapter {
        return AnyAdapter { req in
            var req = req
            req.httpMethod = self.rawValue
            return req
        }
    }
}

public enum ContentType: String {
    case json = "application/json"
    case form = "application/x-www-form-urlencoded; charset=utf-8"
    
    func dataAdapter(for data: [String: Any]) -> RequestAdapter {
        switch self {
        case .json:
            return JSONRequestDataAdapter(data: data)
        case .form:
            return URLFormRequestDataAdapter(data: data)
        }
    }
}

public protocol Request {
    associatedtype Response: Decodable
    
    var url: URL { get }
    var method: HTTPMethod { get }
    var parameters: [String: Any] { get }
    var contentType: ContentType { get }
    
    var decisions: [Decision] { get }
    var adapters: [RequestAdapter] { get }
}

public extension Request{
    func buildRequest() throws -> URLRequest {
        let req = URLRequest(url: url)
        let reqq = try adapters.reduce(req) { (req, adapter) -> URLRequest in
            try adapter.adapted(req)
        }
        return reqq
    }
    
    var decisions: [Decision] {
        return [DataMappingDecision(condition: { (data) -> Bool in
            return data.isEmpty
        }, transform: { (data) -> Data in
            "{}".data(using: .utf8)!
        }),
        ParseResultDecision()]
    }

    var adapters: [RequestAdapter] {
        return [method.adapter,
                RequestContentAdapter(method: method, content: parameters, contentType: contentType)]
    }
    
}

// MARK: RequestAdapter

public protocol RequestAdapter {
    func adapted(_ request: URLRequest) throws -> URLRequest
}

public struct AnyAdapter: RequestAdapter {
    let block: (URLRequest) throws -> URLRequest
    public func adapted(_ request: URLRequest) throws -> URLRequest {
        return try block(request)
    }
}

struct JSONRequestDataAdapter: RequestAdapter {
    let data: [String: Any]
    func adapted(_ request: URLRequest) throws -> URLRequest {
        var request = request
        request.httpBody = try JSONSerialization.data(withJSONObject: data, options: [])
        return request
    }
}

struct URLFormRequestDataAdapter: RequestAdapter {
    let data: [String: Any]
    func adapted(_ request: URLRequest) throws -> URLRequest {
        var request = request
        request.httpBody = data
            .map({ (pair) -> String in
            "\(pair.key)=\(pair.value)"
            })
            .joined(separator: "&").data(using: .utf8)
        return request
    }
}

struct URLQueryDataAdapter: RequestAdapter {
    let data: [String: Any]
    func adapted(_ request: URLRequest) throws -> URLRequest {
        fatalError("not imp yet ")
    }
}

public struct RequestContentAdapter: RequestAdapter {
    let method: HTTPMethod
    let content: [String: Any]
    let contentType: ContentType
    
    public func adapted(_ request: URLRequest) throws -> URLRequest {
        switch method {
        case .GET:
            return try URLQueryDataAdapter(data: content).adapted(request)
        case .POST:
            let dataAdapter = contentType.dataAdapter(for: content)
            var req = try dataAdapter.adapted(request)
            req.setValue(contentType.rawValue, forHTTPHeaderField: "Content-Type")
            return req
        }
    }
}

// MARK: - Decision

public enum DecisionAction<Req: Request> {
    case continueWith(Data, HTTPURLResponse)
    case restartWith([Decision])
    case error(Error)
    case done(Req.Response)
}

public protocol Decision {
    func shouldApply<Req: Request>(request: Req, data: Data, response: HTTPURLResponse) -> Bool
    func apply<Req: Request>(request: Req,
                             data: Data,
                             response: HTTPURLResponse,
                             done: (DecisionAction<Req>) -> Void)
}

public struct ParseResultDecision: Decision {
    
    public init() { }
    
    public func shouldApply<Req>(request: Req, data: Data, response: HTTPURLResponse) -> Bool where Req : Request {
        return true
    }
    
    public func apply<Req>(request: Req, data: Data, response: HTTPURLResponse, done: (DecisionAction<Req>) -> Void) where Req : Request {
        do {
            let value = try JSONDecoder().decode(Req.Response.self, from: data)
            done(.done(value))
        } catch {
            done(.error(error))
        }
    }
}

public struct DataMappingDecision: Decision {
    let condition: (Data) -> Bool
    let transform: (Data) -> Data
    
    public init(condition: @escaping (Data) -> Bool, transform: @escaping (Data) -> Data) {
        self.condition = condition
        self.transform = transform
    }
    
    public func shouldApply<Req>(request: Req, data: Data, response: HTTPURLResponse) -> Bool where Req : Request {
        return condition(data)
    }
    
    public func apply<Req>(request: Req, data: Data, response: HTTPURLResponse, done: (DecisionAction<Req>) -> Void) where Req : Request {
        print("DataMappingDecision")
        done(.continueWith(transform(data), response))
    }
}

public struct HTTPClient {
    let session: URLSession
    public init(session: URLSession) {
        self.session = session
    }
    
    public func send<Req: Request>(_ request: Req,
                            desicions: [Decision]? = nil,
                            handler: @escaping (Result<Req.Response, Error>) -> Void) {
        let urlRequest: URLRequest
        do {
            urlRequest = try request.buildRequest()
        } catch {
            handler(.failure(error))
            return
        }
        
        let task = session.dataTask(with: urlRequest) { (data, response, error) in
            guard let data = data else {
                handler(.failure(error ?? ResponseError.nilData))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                handler(.failure(ResponseError.nonHTTPResponse))
                return
            }
            self.handleDecision(request, data: data, response: response, decisions: desicions ?? request.decisions,
                                handler: handler)
            
        }
        task.resume()
    }
    
    func handleDecision<Req: Request>(_ request: Req,
                                      data: Data,
                                      response: HTTPURLResponse,
                                      decisions: [Decision],
                                      handler: @escaping (Result<Req.Response, Error>) -> Void) {
        guard !decisions.isEmpty else {
            fatalError("No decision left but did not reach a stop")
        }
        var decisions = decisions
        let first = decisions.removeFirst()
        
        guard first.shouldApply(request: request, data: data, response: response) else {
            handleDecision(request, data: data, response: response, decisions: decisions, handler: handler)
            return
        }
        first.apply(request: request, data: data, response: response) { (action) in
            switch action {
            case let .continueWith(data, response):
                self.handleDecision(request, data: data, response: response, decisions: decisions, handler: handler)
            case .restartWith(let decisions):
                self.send(request, desicions: decisions, handler: handler)
            case .error(let error):
                handler(.failure(error))
            case .done(let value):
                handler(.success(value))
            }
        }
    }
}
