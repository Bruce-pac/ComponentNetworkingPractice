import Foundation


public enum ResponseError: Error {
    case nilData
    case nonHTTPResponse
    case tokenError
    case apiError(Error, statusCode: Int)
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

    var headerAdapter: AnyAdapter {
        return AnyAdapter { req in
            var req = req
            req.setValue(self.rawValue, forHTTPHeaderField: "Content-Type")
            return req
        }
    }
    
    func dataAdapter(for data: [String: Any]) -> RequestAdapter {
        switch self {
        case .json:
            return JSONRequestDataAdapter(data: data)
        case .form:
            return URLFormRequestDataAdapter(data: data)
        }
    }
}

// MARK: - Request

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
        let request = try adapters.reduce(req) { try $1.adapted($0) }
        return request
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

struct RefreshTokenRequest: Request {
    struct Response: Decodable {
        let token: String
    }

    var url: URL
    let method: HTTPMethod = .POST
    let contentType: ContentType = .json

    let refreshToken: String

    var parameters: [String : Any] {
        return ["refreshToken": refreshToken]
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
        request.httpBody =
            data.map({ (pair) -> String in
            "\(pair.key)=\(pair.value)"
            })
            .joined(separator: "&").data(using: .utf8)
        return request
    }
}

struct URLQueryDataAdapter: RequestAdapter {
    let data: [String: Any]
    func adapted(_ request: URLRequest) throws -> URLRequest {
        // fatalError("not imp yet ")
        return request
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
            let req = try dataAdapter.adapted(request)
            return try contentType.headerAdapter.adapted(req)
        }
    }
}

public struct TokenAdapter: RequestAdapter {
    let token: String?
    public init(token: String?) {
        self.token = token
    }

    public func adapted(_ request: URLRequest) throws -> URLRequest {
        guard let token = token else {
            return request
        }
        var request = request
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }
}

// MARK: - Decision

// 抽象的是对响应数据的下一步动作决策
public enum DecisionAction<Req: Request> {
    case continueWith(Data, HTTPURLResponse)
    case restartWith([Decision])
    case error(Error)
    case done(Req.Response)
}

// 抽象的是处理响应的方式，拿到响应之后要做的事情，即决策的实现
public protocol Decision: AnyObject {
    // 是否应该进行这个决策，判断响应数据是否符合这个决策执行的条件
    func shouldApply<Req: Request>(request: Req, data: Data, response: HTTPURLResponse) -> Bool
    func apply<Req: Request>(request: Req,
                             data: Data,
                             response: HTTPURLResponse,
                             done: @escaping (DecisionAction<Req>) -> Void)
}

public class ParseResultDecision: Decision {
    public init() {}
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

// 可以用来做假数据
public class DataMappingDecision: Decision {
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
        done(.continueWith(transform(data), response))
    }
}

public class RetryDecision: Decision {
    let count: Int

    public init(count: Int) {
        self.count = count
    }

    public func shouldApply<Req>(request: Req, data: Data, response: HTTPURLResponse) -> Bool where Req : Request {
        let isStatusCodeValid = (200..<300).contains(response.statusCode)
        return !isStatusCodeValid && count > 0
    }

    public func apply<Req>(request: Req, data: Data, response: HTTPURLResponse, done: @escaping (DecisionAction<Req>) -> Void) where Req : Request {
        let nextRetry = RetryDecision(count: count - 1)
        let newDecisions = request.decisions.replacing(self, with: nextRetry)
        done(.restartWith(newDecisions))
    }
}

public class RefreshTokenDecision: Decision {
    let url: URL
    let refreshToken: String

    public init(url: URL, refreshToken: String) {
        self.url = url
        self.refreshToken = refreshToken
    }

    public func shouldApply<Req>(request: Req, data: Data, response: HTTPURLResponse) -> Bool where Req : Request {
        response.statusCode == 403
    }

    public func apply<Req>(request: Req, data: Data,
                           response: HTTPURLResponse,
                           done: @escaping (DecisionAction<Req>) -> Void) where Req : Request {
        let refreshTokenRequest = RefreshTokenRequest(url: url, refreshToken: refreshToken)
        HTTPClient(session: .shared).send(refreshTokenRequest) { result in
            switch result {
            case .success(_):
                let decisionsWithoutRefresh = request.decisions.filter { $0 !== self }
                done(.restartWith(decisionsWithoutRefresh))
            case .failure(let error): done(.error(error))
            }
        }
    }
}

// MARK: - HTTPClient

public struct HTTPClient {
    let session: URLSession
    public init(session: URLSession) {
        self.session = session
    }

    @discardableResult
    public func send<Req: Request>(_ request: Req,
                            desicions: [Decision]? = nil,
                            handler: @escaping (Result<Req.Response, Error>) -> Void) -> URLSessionDataTask? {
        let urlRequest: URLRequest
        do {
            urlRequest = try request.buildRequest()
        } catch {
            handler(.failure(error))
            return nil
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
        return task
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

extension Array where Element == Decision {

    func replacing(_ item: Decision, with other: Decision?) -> Array {
        var copy = self
        guard let idx = firstIndex (where: { $0 === item }) else { return self }
        copy.remove(at: idx)
        if let other = other {
            copy.insert(other, at: idx)
        }
        return copy
    }
}

/*
 组件化  单一职责
 纯函数  可测试
 POP    灵活，可扩展
 组合>继承,描述>指令

 */
