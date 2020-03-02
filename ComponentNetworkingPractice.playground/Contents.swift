import Foundation
import PlaygroundSupport
import ComponentNetworkingPractice_Sources

let page = PlaygroundPage.current
page.needsIndefiniteExecution = true

// MARK: 业务有关的Decision

class BadResponseStatusCodeDecision: Decision {
    let valid: Range<Int>

    init(valid: Range<Int>) {
        self.valid = valid
    }

    func shouldApply<Req>(request: Req, data: Data, response: HTTPURLResponse) -> Bool where Req : Request {
        return !valid.contains(response.statusCode)
    }

    func apply<Req>(request: Req, data: Data, response: HTTPURLResponse, done: @escaping (DecisionAction<Req>) -> Void) where Req : Request {
        do {
            let value = try JSONDecoder().decode(APIError.self, from: data)
            done(.error(ResponseError.apiError(value, statusCode: response.statusCode)))
        } catch {
            done(.error(error))
        }
    }
}

struct HTTPBinPostResponse: Codable {
    struct Form: Codable { let foo: String? }
    let form: Form
    let json: Form
    
}

struct HTTPBinPostRequest: Request {
    
    typealias Response = HTTPBinPostResponse

    var url: URL = URL(string: "https://httpbin.org/post")!
    
    var method: HTTPMethod = .POST
    
    var parameters: [String : Any] {
        return ["foo": foo]
    }
    
    let foo: String
    
    var contentType: ContentType = .json

    var decisions: [Decision] {
        return [RetryDecision(count: 2),
                BadResponseStatusCodeDecision(valid: 200..<300),
                DataMappingDecision(condition: { (data) -> Bool in
            return data.isEmpty
        }, transform: { (data) -> Data in
            "{}".data(using: .utf8)!
        }),
        ParseResultDecision()]
    }

}

struct APIError: Decodable, Error {
    let code: Int
    let reason: String
}

let client = HTTPClient(session: .shared)
let req = HTTPBinPostRequest(foo: "bar")
client.send(req) { (result) in
    switch result {
    case .success(let response):
        print(response)
    case .failure(let error):
        print(error)
    }
}


