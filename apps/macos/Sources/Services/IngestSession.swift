import Foundation

final class RejectIngestRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

let ingestSession = URLSession(configuration: .ephemeral, delegate: RejectIngestRedirects(), delegateQueue: nil)
