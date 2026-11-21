import SwiftUI
import Darwin

/// 首次安装启动引导
///
/// 三步流程（只在新安装后展示一次）：
/// 1. 用户使用协议 —— 必须同意，不同意则退出
/// 2. 网络权限说明 —— 说明本地网络/网络权限的用途与隐私边界
/// 3. 支持与帮助 —— 教程、社区、协议入口，完成后进入主界面
struct OnboardingView: View {
    /// 是否已完成引导（UserDefaults 持久化，卸载重装会重置）
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    /// 当前步骤：持久化，避免启动后数据刷新导致视图重建时退回第一页
    @AppStorage("onboardingPage") private var page: Int = {
        #if DEBUG
        // 调试用：--onboarding-preview=0|1|2 直接预览指定页
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--onboarding-preview=") }),
           let value = Int(arg.split(separator: "=").last ?? ""),
           (0...2).contains(value) { return value }
        #endif
        return 0
    }()
    @State private var showingDisagreeAlert = false

    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            progressIndicator

            // 不做页面转场动画：两页按钮位置相同，动画期间重叠会导致一次点击被
            // 新旧视图同时接收（连跳两步）。直接切换最稳妥。
            Group {
                switch page {
                case 0: agreementPage
                case 1: networkPage
                default: supportPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background.ignoresSafeArea())
        .alert("退出应用", isPresented: $showingDisagreeAlert) {
            Button("不同意并退出", role: .destructive) { exit(0) }
            Button("再看看", role: .cancel) {}
        } message: {
            Text("必须同意《用户使用协议》才能使用 YSign。")
        }
    }

    // MARK: - 公共组件

    private var progressIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == page ? DS.primary : DS.divider)
                    .frame(width: index == page ? 22 : 8, height: 6)
            }
        }
        .padding(.top, 16)
        .animation(.spring(response: 0.3), value: page)
    }

    /// 页面头部：标题 + 副标题
    private func header(
        title: String,
        subtitle: String
    ) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(DS.text)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 44)
        .padding(.horizontal, DS.paddingScreen)
    }

    /// 底部固定的主按钮
    private func primaryFooter(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(DSPrimaryButtonStyle())
        .padding(.horizontal, DS.paddingScreen)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .background(DS.background)
    }

    private func goNext() {
        page += 1
    }

    private func finish() {
        page = 0
        hasCompletedOnboarding = true
    }

    // MARK: - 第 1 页：用户使用协议

    private let agreementSections: [(title: String, body: String)] = [
        ("一、协议说明",
         "本协议系你（以下简称「用户」）与本应用开发者之间就使用 YSign 所达成的协议。YSign 是一款面向 iOS 平台的本地签名与文件处理工具，提供证书管理、应用重签名、动态库注入、Mach-O 检视、归档解压、文本与十六进制查看等功能。请在使用前仔细阅读全部条款，点击「同意并继续」即表示你已完整阅读、充分理解并同意接受本协议的全部内容。"),
        ("二、服务范围",
         "本应用为用户提供本地化的签名与文件处理能力。除用户主动启用的软件源拉取、证书状态查询与在线安装外，处理过程均在用户设备本地完成；证书、安装包、插件等资源由用户自行准备。本应用不提供任何受版权保护的应用程序、破解资源、第三方插件源、用户账号体系或付费内容，一切以本应用名义进行的资源分发、二次发行均与开发者无关。"),
        ("三、使用规范",
         "用户应确保对导入的 IPA、证书、描述文件及插件拥有合法使用权，并遵守所在地区法律法规与 Apple 相关条款。不得利用本应用分发侵权内容、绕过授权机制或从事其他违法违规行为。因用户提供的资源或操作引发的纠纷与责任，由用户自行承担。"),
        ("四、网络与数据",
         "安装签名应用需要通过本机服务向 iOS 系统派发安装队列（本地网络），证书状态查询、软件源刷新与应用下载需要访问互联网。本应用不收集 Apple ID、手机号、通讯录、相册、定位、剪贴板等个人敏感信息；仅在完成用户主动发起的操作时使用机型标识、系统版本、应用版本与本地随机 UUID。"),
        ("五、免责与更新",
         "本应用按「现状」提供，不对签名结果、安装成功率或证书有效性作任何保证。因使用本应用产生的签名失败、安装失败、设备数据变更等后果由用户自行承担。开发者可根据功能调整更新本协议，更新后继续使用即视为接受。")
    ]

    private var agreementPage: some View {
        VStack(spacing: 0) {
            header(
                title: "欢迎使用 YSign",
                subtitle: "在开始之前，请阅读以下服务协议与隐私政策"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label("用户使用协议", systemImage: "doc.text.fill")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(DS.primary)

                    Text("请在使用前仔细阅读以下条款，点击同意即视为接受。")
                        .font(.footnote)
                        .foregroundStyle(DS.textSecondary)

                    ForEach(agreementSections.indices, id: \.self) { index in
                        let section = agreementSections[index]
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(DS.text)
                            Text(section.body)
                                .font(.footnote)
                                .foregroundStyle(DS.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dsCard()
                    }

                    Link(destination: URL(string: "https://www.julyedu.com/agreement/priv")!) {
                        HStack(spacing: 6) {
                            Text("查看完整服务及隐私协议")
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
                .padding(.horizontal, DS.paddingScreen)
                .padding(.top, 20)
                .padding(.bottom, 8)
            }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button("不同意并退出") { showingDisagreeAlert = true }
                        .buttonStyle(DSSecondaryButtonStyle())
                        .foregroundStyle(DS.textSecondary)
                    Button("同意并继续") { goNext() }
                        .buttonStyle(DSPrimaryButtonStyle())
                }
                .padding(.horizontal, DS.paddingScreen)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .background(DS.background)
            }
        }
    }

    // MARK: - 第 2 页：网络权限说明

    private var networkPage: some View {
        VStack(spacing: 0) {
            header(
                title: "网络权限说明",
                subtitle: "使用本应用前，请确认以下网络权限事项"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 隐私政策摘要
                    VStack(alignment: .leading, spacing: 12) {
                        Label("隐私政策摘要", systemImage: "lock.shield.fill")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(DS.text)

                        policyRow(
                            icon: "checkmark.circle.fill", color: DS.success,
                            title: "仅收集基础设备信息",
                            detail: "机型标识、iOS 版本号、应用版本号、本地随机软件 UUID"
                        )
                        policyRow(
                            icon: "xmark.circle.fill", color: DS.destructive,
                            title: "绝不收集个人敏感信息",
                            detail: "Apple ID、手机号、通讯录、相册、定位、剪贴板等"
                        )
                        policyRow(
                            icon: "lock.fill", color: DS.primary,
                            title: "数据加密传输",
                            detail: "所有上行数据均经过加密与完整性校验"
                        )
                    }
                    .dsCard()

                    // 权限用途
                    VStack(alignment: .leading, spacing: 12) {
                        Label("为什么需要网络权限", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(DS.text)

                        bullet("安装签名应用：通过本机服务向 iOS 系统派发安装队列，必须使用本地网络")
                        bullet("证书状态查询：检查证书是否被吊销，需访问 Apple 签发机构")
                        bullet("软件源与下载：拉取软件源数据、下载用户选择的应用安装包")
                        bullet("版本控制：检查当前应用是否为最新版本，必要时提示更新")
                    }
                    .dsCard()

                    // 提示
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DS.warning)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("此权限为应用核心功能所必需")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(DS.text)
                            Text("安装服务、证书校验等关键流程依赖网络通信，请勿关闭网络权限，避免部分核心功能受影响。")
                                .font(.caption)
                                .foregroundStyle(DS.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .background(DS.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous))
                }
                .padding(.horizontal, DS.paddingScreen)
                .padding(.top, 20)
                .padding(.bottom, 8)
            }

            primaryFooter("我已知悉，继续使用") { goNext() }
        }
    }

    private func policyRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(DS.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(DS.primary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 第 3 页：支持与帮助

    private var supportPage: some View {
        VStack(spacing: 0) {
            header(
                title: "支持与帮助",
                subtitle: "遇到问题或有建议，可以从这里开始"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(spacing: 0) {
                        supportLink(
                            icon: "book.fill", title: "使用教程",
                            subtitle: "签名、证书、软件源的完整上手指南",
                            url: "https://docs.qq.com/doc/DUmZhR2JhYld2U2Z5"
                        )
                        Divider().padding(.leading, 58)
                        supportLink(
                            icon: "bubble.left.fill", title: "联系我们",
                            subtitle: "Telegram @ysign · 反馈问题与交流",
                            url: "https://t.me/ysign"
                        )
                        Divider().padding(.leading, 58)
                        supportLink(
                            icon: "doc.text.fill", title: "服务及隐私协议",
                            subtitle: "随时查阅协议全文",
                            url: "https://www.julyedu.com/agreement/priv"
                        )
                    }
                    .dsCard(padding: 12)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("关于 YSign", systemImage: "app.badge.checkmark")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(DS.text)
                        Text("纯 Swift 实现的 iOS 应用签名工具，使用 Security.framework + CryptoKit 原生签名引擎。所有签名与文件处理均在你的设备本地完成，不上传你的 IPA 与证书。")
                            .font(.footnote)
                            .foregroundStyle(DS.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsCard()
                }
                .padding(.horizontal, DS.paddingScreen)
                .padding(.top, 20)
                .padding(.bottom, 8)
            }

            primaryFooter("我已了解，开始使用") { finish() }
        }
    }

    private func supportLink(icon: String, title: String, subtitle: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                DSIconBadge(systemName: icon, color: DS.primary, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DS.text)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(DS.textTertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
    }
}
