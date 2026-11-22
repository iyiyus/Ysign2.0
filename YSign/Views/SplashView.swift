import SwiftUI
import UIKit

/// 启动动画页（每次冷启动显示一次）
///
/// 纯白背景 + Ysign 手写字标：
/// - 字标先淡入，再按书写方向从左到右展开笔画
/// - 展开完成后整体淡出，过渡到主界面
///
/// 实现说明：字标不直接用 SwiftUI Text——花体（SnellRoundhand）的笔画
/// 会延伸出排版边界，且不同 iOS 版本的字形溢出量不一样（真机 16.3 与
/// 模拟器差异明显），mask 的边界会把溢出笔画裁掉（左侧起笔断笔）。
/// 因此启动时把字标渲染成一张左右各留 150pt 空白的位图，笔画永远
/// 落在画布内，遮罩边界不可能切到任何笔画。
struct SplashView: View {
    /// 动画播放完毕后回调（由调用方移除本页）
    let onFinished: () -> Void

    /// 预渲染的字标位图
    @State private var wordmark: UIImage?
    /// 是否已完成淡入
    @State private var appeared = false
    /// 笔画展开进度（0 = 未展开，1 = 完整显示）
    @State private var reveal: CGFloat = 0
    /// 整体淡出
    @State private var fadingOut = false

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            if let img = wordmark {
                Image(uiImage: img)
                    .opacity(appeared ? 1 : 0)
                    .mask(alignment: .leading) {
                        GeometryReader { geo in
                            strokeReveal(width: geo.size.width)
                        }
                    }
            }
        }
        .opacity(fadingOut ? 0 : 1)
        .scaleEffect(fadingOut ? 1.05 : 1)
        .offset(y: fadingOut ? -14 : 0)
        .onAppear {
            if wordmark == nil { wordmark = Self.renderWordmark() }
            playAnimation()
        }
    }

    // MARK: - 字标渲染

    /// 把 "Ysign" 渲染成位图
    ///
    /// 画布左右各留 150pt 空白吸收花体笔画溢出（任何系统版本的字形
    /// 都远小于这个余量），保证遮罩永不裁切笔画。
    /// 颜色固定用品牌深青（启动屏强制白底，不跟随深色模式变浅）。
    private static func renderWordmark() -> UIImage? {
        guard let font = UIFont(name: "SnellRoundhand-Bold", size: 78) else { return nil }
        let text = NSAttributedString(string: "Ysign", attributes: [
            .font: font,
            .foregroundColor: UIColor(red: 13 / 255, green: 148 / 255, blue: 136 / 255, alpha: 1),
        ])

        let pad: CGFloat = 150
        let bounds = text.boundingRect(
            with: CGSize(width: 1200, height: 240),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let canvas = CGSize(width: ceil(bounds.width) + pad * 2, height: ceil(bounds.height) + 60)

        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        return renderer.image { _ in
            text.draw(at: CGPoint(x: pad, y: 30))
        }
    }

    // MARK: - 遮罩

    /// 从左到右展开的遮罩，带墨迹渐变尾迹（模拟笔画书写）
    private func strokeReveal(width: CGFloat) -> some View {
        LinearGradient(
            stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: 0.85),
                .init(color: .clear, location: 1.0),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: width * reveal * 1.15)
    }

    // MARK: - 动画时序

    private func playAnimation() {
        // 1. 淡入
        withAnimation(.easeIn(duration: 0.65)) {
            appeared = true
        }
        // 2. 笔画从左到右展开（放慢，充分呈现书写感）
        withAnimation(.easeOut(duration: 1.6).delay(0.4)) {
            reveal = 1
        }
        // 3. 展开完成 → 停留约 1.2s → 整体淡出 → 移除
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            withAnimation(.easeInOut(duration: 0.6)) {
                fadingOut = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                onFinished()
            }
        }
    }
}
