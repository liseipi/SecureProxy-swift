import Foundation

struct ProxyConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var sniHost: String
    var path: String
    var serverPort: Int
    var socksPort: Int
    var httpPort: Int
    var preSharedKey: String
    
    enum CodingKeys: String, CodingKey {
        case name
        case sniHost = "sni_host"
        case path
        case serverPort = "server_port"
        case socksPort = "socks_port"
        case httpPort = "http_port"
        case preSharedKey = "pre_shared_key"
    }
    
    static func == (lhs: ProxyConfig, rhs: ProxyConfig) -> Bool {
        return lhs.id == rhs.id
    }
}
