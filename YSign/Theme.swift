import SwiftUI
import UIKit

/// YSign 设计系统 —— Flat Design（深浅色自适应）
///
/// 设计令牌（Design Tokens）:
/// - 主色: 青绿 #0D9488（稳定、专业、工具感）
/// - 强调: 橙色 #EA580C（CTA / 危险操作以外的关键动作）
/// - 背景: 浅色 浅灰青 #F4F7F8 / 深色 深蓝黑 #0B121E
/// - 文字: 浅色 深墨 #0F172A / 深色 浅灰 #E8EEF4
///
/// 所有页面统一引用此文件的颜色与组件，保证一致性。
enum DS {
    // MARK: - 色彩令牌

    /// 主色（品牌青绿）
    static let primary = Color(red: 0.05, green: 0.58, blue: 0.53)          // #0D9488
    /// 主色浅底（用于图标底、选中态背景）
    static let primarySoft = dynamic(
        light: UIColor(red: 0.90, green: 0.98, blue: 0.96, alpha: 1),
        dark: UIColor(red: 0.05, green: 0.58, blue: 0.53, alpha: 0.18)
    )
    /// 强调色（CTA 橙）
    static let accent = Color(red: 0.92, green: 0.35, blue: 0.03)           // #EA580C
    /// 页面背景
    static let background = dynamic(
        light: UIColor(red: 0.957, green: 0.969, blue: 0.973, alpha: 1),    // #F4F7F8
        dark: UIColor(red: 0.043, green: 0.071, blue: 0.118, alpha: 1)      // #0B121E
    )
    /// 卡片背景
    static let card = dynamic(
        light: .white,
        dark: UIColor(red: 0.086, green: 0.125, blue: 0.169, alpha: 1)      // #16202B
    )
    /// 分组背景（嵌入列表的次级卡片）
    static let cardMuted = dynamic(
        light: UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1),       // #F5F8FA
        dark: UIColor(red: 0.114, green: 0.157, blue: 0.208, alpha: 1)      // #1D2835
    )
    /// 主文字
    static let text = dynamic(
        light: UIColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1),       // #0F172A
        dark: UIColor(red: 0.91, green: 0.933, blue: 0.957, alpha: 1)       // #E8EEF4
    )
    /// 次要文字
    static let textSecondary = dynamic(
        light: UIColor(red: 0.39, green: 0.45, blue: 0.55, alpha: 1),       // #64748B
        dark: UIColor(red: 0.604, green: 0.659, blue: 0.722, alpha: 1)      // #9AA8B8
    )
    /// 三级文字
    static let textTertiary = dynamic(
        light: UIColor(red: 0.58, green: 0.64, blue: 0.72, alpha: 1),       // #94A3B8
        dark: UIColor(red: 0.494, green: 0.553, blue: 0.627, alpha: 1)      // #7E8DA0
    )
    /// 分隔线
    static let divider = dynamic(
        light: UIColor(red: 0.89, green: 0.91, blue: 0.94, alpha: 1),       // #E2E8F0
        dark: UIColor(red: 0.149, green: 0.192, blue: 0.247, alpha: 1)      // #26313F
    )
    /// 危险色
    static let destructive = dynamic(
        light: UIColor(red: 0.86, green: 0.15, blue: 0.15, alpha: 1),       // #DC2626
        dark: UIColor(red: 0.937, green: 0.267, blue: 0.267, alpha: 1)      // #EF4444
    )
    /// 成功色
    static let success = dynamic(
        light: UIColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1),       // #22C55E
        dark: UIColor(red: 0.29, green: 0.843, blue: 0.435, alpha: 1)       // #4ADE80
    )
    /// 警告色
    static let warning = dynamic(
        light: UIColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1),       // #F59E0B
        dark: UIColor(red: 0.988, green: 0.702, blue: 0.275, alpha: 1)      // #FCB333
    )

    /// 深浅色自适应色（跟随系统外观）
    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? dark : light
        })
    }

    // MARK: - 尺寸令牌

    static let cornerL: CGFloat = 20
    static let cornerM: CGFloat = 14
    static let cornerS: CGFloat = 10
    static let paddingScreen: CGFloat = 16
}

// MARK: - 卡片容器

/// 统一卡片样式：白底、圆角、发丝级描边
struct DSCardStyle: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(DS.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous)
                    .strokeBorder(DS.divider.opacity(0.7), lineWidth: 1)
            )
    }
}

extension View {
    func dsCard(padding: CGFloat = 14) -> some View {
        modifier(DSCardStyle(padding: padding))
    }
}

// MARK: - 主按钮

/// 品牌主按钮：青绿填充、圆角、按压反馈
struct DSPrimaryButtonStyle: ButtonStyle {
    var color: Color = DS.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous)
                    .fill(color.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 次级按钮：浅青底、青绿文字
struct DSSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(DS.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous)
                    .fill(DS.primarySoft.opacity(configuration.isPressed ? 0.6 : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - 自定义分段控件

/// 胶囊分段控件（替代系统 Segmented，更贴合品牌）
struct DSSegmentedPicker<T: Hashable & CaseIterable>: View {
    @Binding var selection: T
    let options: [T]
    let title: (T) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selection = option
                    }
                } label: {
                    Text(title(option))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(selection == option ? .white : DS.textSecondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background {
                            if selection == option {
                                Capsule().fill(DS.primary)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(DS.cardMuted))
    }
}

// MARK: - 搜索框

/// 品牌搜索框
struct DSSearchField: View {
    @Binding var text: String
    var placeholder: String = "搜索"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(DS.textTertiary)
            TextField(placeholder, text: $text)
                .font(.subheadline)
                .foregroundStyle(DS.text)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.textTertiary)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous).fill(DS.card))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous)
                .strokeBorder(DS.divider.opacity(0.7), lineWidth: 1)
        )
    }
}

// MARK: - 页面大标题

/// 页面顶部大标题区（大字 + 副标题）
struct DSPageHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(DS.text)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(DS.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 图标徽章

/// 圆角图标容器（列表行左侧图标底座）
struct DSIconBadge: View {
    let systemName: String
    var color: Color = DS.primary
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerS, style: .continuous)
                    .fill(color.opacity(0.12))
            )
    }
}

// MARK: - 数量徽章

struct DSCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(.caption2, design: .rounded, weight: .bold))
            .foregroundStyle(DS.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(DS.primarySoft))
    }
}

// MARK: - 空状态

/// 统一空状态组件
struct DSEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var actionIcon: String = "plus"
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(DS.primarySoft)
                    .frame(width: 96, height: 96)
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(DS.primary)
            }
            .padding(.bottom, 4)

            Text(title)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(DS.text)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)

            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: actionIcon)
                        .frame(maxWidth: 220)
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .padding(.top, 6)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 列表行卡片化修饰

/// 将 List 的行呈现为卡片样式（配合 .listStyle(.plain)）
struct DSRowCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(DS.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous)
                    .strokeBorder(DS.divider.opacity(0.7), lineWidth: 1)
            )
            .padding(.horizontal, DS.paddingScreen)
            .padding(.vertical, 5)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
    }
}

extension View {
    func dsRowCard() -> some View {
        modifier(DSRowCard())
    }
}

// MARK: - 表单分组卡片

/// 卡片式表单分组：标题 + 白色卡片容器
struct DSSectionCard<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.footnote, design: .rounded, weight: .bold))
                .foregroundStyle(DS.textTertiary)
                .textCase(.uppercase)
                .padding(.leading, 6)

            VStack(spacing: 0) {
                content
            }
            .background(DS.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous)
                    .strokeBorder(DS.divider.opacity(0.7), lineWidth: 1)
            )

            if let footer {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(DS.textTertiary)
                    .padding(.leading, 6)
            }
        }
    }
}

/// 卡片内行分隔线
struct DSDivider: View {
    var body: some View {
        Rectangle()
            .fill(DS.divider.opacity(0.6))
            .frame(height: 1)
            .padding(.leading, 16)
    }
}

// MARK: - 表单输入行

/// 带标签的圆角输入框
struct DSFormTextField: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""
    var mono: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(DS.textSecondary)

            TextField(placeholder.isEmpty ? title : placeholder, text: $text)
                .font(mono ? .system(.body, design: .monospaced) : .system(.body, design: .rounded))
                .foregroundStyle(DS.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 开关行
struct DSToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .font(.system(.subheadline, design: .rounded))
            .foregroundStyle(DS.text)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .tint(DS.primary)
    }
}
