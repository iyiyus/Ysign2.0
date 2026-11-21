import SwiftUI

/// 启动动画页（每次冷启动显示一次）
///
/// 纯白背景 + Ysign 手写字标：
/// - 字标先淡入，再按书写方向从左到右展开笔画
/// - 展开完成后整体淡出，过渡到主界面
struct SplashView: View {
    /// 动画播放完毕后回调（由调用方移除本页）
    let onFinished: () -> Void

    /// 是否已完成淡入
    @State private var appeared = false
    /// 笔画展开进度（0 = 未展开，1 = 完整显示）
    @State private var reveal: CGFloat = 0
    /// 整体淡出
    @State private var fadingOut = false

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            Text("Ysign")
                .font(.custom("SnellRoundhand-Bold", size: 78))
                .foregroundStyle(DS.primary)
                .fixedSize()
                .opacity(appeared ? 1 : 0)
                // 花体笔画会延伸出排版边界（如 "Y" 的左起笔），
                // 遮罩只覆盖排版宽度，不留余量会把左侧笔画截掉
                .padding(.horizontal, 32)
                .mask(alignment: .leading) {
                    GeometryReader { geo in
                        strokeReveal(width: geo.size.width)
                    }
                }
        }
        .opacity(fadingOut ? 0 : 1)
        .scaleEffect(fadingOut ? 1.05 : 1)
        .offset(y: fadingOut ? -14 : 0)
        .onAppear { playAnimation() }
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
