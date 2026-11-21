import Foundation

/// 证书吊销检查服务（OCSP）
///
/// 对齐 LCSign 的状态分类：有效 / 已吊销 / 已过期 / 即将到期 / 无法确认
/// 底层通过 OCSPChecker（ObjC++ + OpenSSL）构造 OCSP request 查询证书签发机构的 responder。
/// 签发者证书优先取 P12 内含的证书链，缺省时由 OCSPChecker 从内置 Apple WWDR 中间证书匹配。
///
/// 自动检查策略：
/// - App 在前台时每 30 秒检查一次全部证书（`startAutoCheck` / `stopAutoCheck`）
/// - 证书详情页下拉刷新可立即强制检查（`checkAwait`）
@MainActor
final class RevocationService: ObservableObject {

    static let shared = RevocationService()

    /// 自动检查间隔（秒）
    private static let autoCheckInterval: TimeInterval = 30
    /// 防抖窗口（秒）：窗口内的重复检查直接跳过
    private static let debounceInterval: TimeInterval = 5

    /// 检查状态
    enum CheckStatus {
        case checking
        case valid
        case revoked
        case expired
        case expiringSoon
        case unknown

        var label: String {
            switch self {
            case .checking: return "查询中..."
            case .valid: return "有效 (OCSP 通过)"
            case .revoked: return "已吊销"
            case .expired: return "已过期"
            case .expiringSoon: return "即将到期"
            case .unknown: return "无法确认"
            }
        }

        var colorHex: String {
            switch self {
            case .checking: return "gray"
            case .valid: return "green"
            case .revoked, .expired: return "red"
            case .expiringSoon: return "orange"
            case .unknown: return "gray"
            }
        }
    }

    /// 各证书的检查结果（key = CertificateInfo.id）
    @Published private(set) var results: [UUID: (status: CheckStatus, message: String)] = [:]

    /// 前台自动检查定时器
    private var autoTimer: Timer?
    /// 证书列表提供者（自动检查时读取最新列表）
    private var certsProvider: (() -> [CertificateInfo])?
    /// 上次发起检查的时间（防抖）
    private var lastCheckDates: [UUID: Date] = [:]

    deinit {
        autoTimer?.invalidate()
    }

    // MARK: - 检查

    /// 发起吊销检查
    ///
    /// - Parameters:
    ///   - force: 强制检查（下拉刷新）；默认 5 秒内重复检查会被跳过
    ///   - completion: 检查完成回调（含跳过场景）
    func check(cert: CertificateInfo, force: Bool = false, completion: (() -> Void)? = nil) {
        if !force, let last = lastCheckDates[cert.id],
           Date().timeIntervalSince(last) < Self.debounceInterval {
            completion?()
            return
        }
        lastCheckDates[cert.id] = Date()
        results[cert.id] = (.checking, "查询中...")

        guard let info = try? OpenSSLP12Parser.parseP12Data(cert.p12Data, password: cert.password),
              let leafDER = info.certificateData else {
            results[cert.id] = (.unknown, "P12 解析失败")
            completion?()
            return
        }

        OCSPChecker.checkLeafCertDER(leafDER, issuerCertDER: info.issuerCertData) { result in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion?()
                    return
                }
                switch result.status {
                case .valid:
                    self.results[cert.id] = (.valid, result.message ?? "OCSP 查询通过")
                case .revoked:
                    self.results[cert.id] = (.revoked, result.message ?? "证书已被吊销")
                case .expired:
                    self.results[cert.id] = (.expired, result.message ?? "证书已过期")
                case .expiringSoon:
                    self.results[cert.id] = (.expiringSoon, result.message ?? "证书即将到期")
                default:
                    self.results[cert.id] = (.unknown, result.message ?? "无法确认")
                }
                completion?()
            }
        }
    }

    /// 检查全部证书
    func checkAll(certs: [CertificateInfo]? = nil) {
        let list = certs ?? certsProvider?() ?? []
        for cert in list {
            check(cert: cert)
        }
    }

    /// 强制检查单个证书并等待完成（下拉刷新用）
    func checkAwait(cert: CertificateInfo) async {
        await withCheckedContinuation { continuation in
            check(cert: cert, force: true) {
                continuation.resume()
            }
        }
    }

    // MARK: - 前台自动检查

    /// App 进入前台时调用：立即检查一次，之后每 30 秒检查
    func startAutoCheck(certsProvider: @escaping () -> [CertificateInfo]) {
        self.certsProvider = certsProvider
        checkAll()
        if autoTimer == nil {
            autoTimer = Timer.scheduledTimer(withTimeInterval: Self.autoCheckInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkAll()
                }
            }
        }
    }

    /// App 退到后台时调用
    func stopAutoCheck() {
        autoTimer?.invalidate()
        autoTimer = nil
    }
}
