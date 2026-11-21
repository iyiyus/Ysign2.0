import Foundation
import UIKit

/// UDID 获取服务
///
/// 通过 Safari 打开服务器上的 .mobileconfig 描述文件链接获取设备 UDID。
///
/// 流程：
/// 1. Safari 打开 https://域名/udid.mobileconfig
/// 2. 用户在「设置」中安装描述文件
/// 3. iOS 将设备信息 POST 到描述文件中配置的回调 URL
/// 4. 服务器解析 UDID 后 301 重定向到 ysign://?udid=xxx
/// 5. App 接收并保存 UDID
///
/// 服务端文件在 Server/ 目录下：
/// - udid.mobileconfig → 描述文件（修改其中的回调 URL 为你的域名）
/// - receive.php → 接收 UDID 并重定向回 App
class UDIDService {

    static let shared = UDIDService()
    private init() {}

    /// 描述文件的 HTTPS 地址
    /// ⚠️ 部署前请替换为你自己服务器上的地址
    static let mobileconfigURL = "https://ip.iosk.cn/udid/udid.mobileconfig"

    /// 打开 Safari 安装描述文件获取 UDID
    func openInSafari() {
        guard let url = URL(string: Self.mobileconfigURL) else { return }
        UIApplication.shared.open(url)
    }

    /// 保存从 URL Scheme 回调中收到的 UDID
    func saveUDID(_ udid: String) {
        guard !udid.isEmpty else { return }
        UserDefaults.standard.set(udid, forKey: "deviceUDID")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        print("[UDIDService] ✅ UDID 已保存: \(udid)")
    }
}
