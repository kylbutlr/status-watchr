import Foundation

// HTTP is only useful for a server on this Mac. Remote origins keep TLS and
// userinfo is never an acceptable place for the ingestion credential.
func canUseWatchrServer(_ url: URL) -> Bool {
    guard url.user == nil, url.password == nil, let host = url.host else { return false }
    if url.scheme == "https" { return true }
    return url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
}
