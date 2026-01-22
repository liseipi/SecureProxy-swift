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
    
    // MARK: - URL Format Support
    
    /// 导出为 URL 字符串格式
    /// 格式: wss://host:port/path?psk=xxx&socks=1080&http=1081&name=MyProxy
    func toURLString() -> String {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = sniHost
        components.port = serverPort
        components.path = path
        
        components.queryItems = [
            URLQueryItem(name: "psk", value: preSharedKey),
            URLQueryItem(name: "socks", value: String(socksPort)),
            URLQueryItem(name: "http", value: String(httpPort)),
            URLQueryItem(name: "name", value: name)
        ]
        
        return components.url?.absoluteString ?? ""
    }
    
    /// 从 URL 字符串格式导入
    /// 格式: wss://host:port/path?psk=xxx&socks=1080&http=1081&name=MyProxy
    static func from(urlString: String) -> ProxyConfig? {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        
        // 验证协议
        guard components.scheme == "wss" else {
            return nil
        }
        
        // 提取基本信息
        guard let host = components.host else {
            return nil
        }
        
        let port = components.port ?? 443
        let path = components.path.isEmpty ? "/ws" : components.path
        
        // 提取查询参数
        var queryDict: [String: String] = [:]
        components.queryItems?.forEach { item in
            if let value = item.value {
                queryDict[item.name] = value
            }
        }
        
        // 提取 PSK（必需）
        guard let psk = queryDict["psk"], psk.count == 64 else {
            return nil
        }
        
        // 提取其他参数（可选，使用默认值）
        let socksPort = Int(queryDict["socks"] ?? "1080") ?? 1080
        let httpPort = Int(queryDict["http"] ?? "1081") ?? 1081
        let name = queryDict["name"] ?? host
        
        return ProxyConfig(
            name: name,
            sniHost: host,
            path: path,
            serverPort: port,
            socksPort: socksPort,
            httpPort: httpPort,
            preSharedKey: psk
        )
    }
}
