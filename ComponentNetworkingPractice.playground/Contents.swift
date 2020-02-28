import Foundation
import PlaygroundSupport
import ComponentNetworkingPractice_Sources

let page = PlaygroundPage.current
page.needsIndefiniteExecution = true

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

