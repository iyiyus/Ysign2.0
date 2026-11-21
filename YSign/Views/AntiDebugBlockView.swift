import SwiftUI

/// 反调试拦截页（YSign 设计系统风格）
///
/// 浅色背景 + 危险色图标徽章 + 标题副标题 + 已拦截动态库卡片，不可关闭。
/// 预览态（从设置页进入）底部提供「退出预览」按钮。
struct AntiDebugBlockView: View {
    /// 拦截结果
    let result: AntiDebugGuard.CheckResult

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            warningHeader

            blockedListCard
                .padding(.top, 24)

            Spacer(minLength: 0)

            if result.isPreview {
                Button {
                    AntiDebugGuard.shared.dismissPreview()
                } label: {
                    Text("退出预览")
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .padding(.horizontal, DS.paddingScreen)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.background.ignoresSafeArea())
        .padding(.horizontal, DS.paddingScreen)
    }

    // MARK: - 子视图

    /// 危险图标 + 标题 + 副标题
    private var warningHeader: some View {
        VStack(spacing: 16) {
            DSIconBadge(systemName: "exclamationmark.octagon.fill", color: DS.destructive, size: 84)
                .padding(.bottom, 4)

            Text("你已被停止使用")
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(DS.text)

            Text(result.debuggerAttached && result.injectedLibs.isEmpty
                 ? "检测到调试器附着，已触发反调试机制，请卸载后进入。"
                 : "检测到调试工具 / 外部动态库注入，已触发反调试机制，请卸载后进入。")
                .font(.subheadline)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    /// 已拦截动态库卡片
    private var blockedListCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                DSIconBadge(systemName: "shield.slash.fill", color: DS.destructive, size: 34)
                Text("已拦截动态库 (\(result.displayLibs.count))")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(DS.text)
                Spacer()
                DSCountBadge(count: result.displayLibs.count)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            DSDivider()

            VStack(alignment: .leading, spacing: 12) {
                ForEach(result.displayLibs, id: \.self) { lib in
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DS.destructive)
                        Text(lib)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("已拦截")
                            .font(.caption2)
                            .foregroundStyle(DS.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(DS.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous)
                .strokeBorder(DS.divider.opacity(0.7), lineWidth: 1)
        )
    }
}
