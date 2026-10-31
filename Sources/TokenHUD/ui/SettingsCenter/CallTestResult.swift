import Foundation

struct CallTestConfirmation {
    let sourceLabel: String
    let model: String
    let target: String
    let providerName: String
}

struct CallTestResult {
    enum Phase { case running, success, failure, uncertain }
    let phase: Phase
    let model: String
    let target: String
    let sourceLabel: String
    let message: String
    let date: Date

    var title: String {
        switch phase {
        case .running: return "测试进行中"
        case .success: return "测试成功"
        case .failure: return "测试未成功"
        case .uncertain: return "调用结果不确定"
        }
    }

    var isError: Bool { phase == .failure || phase == .uncertain }

    static func targetDescription(_ raw: String) -> String {
        guard var components = URLComponents(string: raw),
              components.host != nil else { return "未配置调用地址" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "调用地址"
    }
}
