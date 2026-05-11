import SwiftUI

/// 贴牌启动图浮层
///
/// 品牌初始化完成后短暂展示一张品牌启动图。
/// 启动图地址来自 `BrandConfig.appLaunchIconURL`，运行时下发，无需重签资源。
struct BrandLaunchOverlayView: View {

    let urlString: String
    var onFinished: () -> Void

    @State private var image: UIImage?
    @State private var visible = true

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            }
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: visible)
        .onAppear {
            loadAndDismiss()
        }
    }

    private func loadAndDismiss() {
        Task {
            image = await BrandLaunchImageCache.loadImage(for: urlString)
            // 展示 2 秒后淡出
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            visible = false
            try? await Task.sleep(nanoseconds: 350_000_000)
            await MainActor.run { onFinished() }
        }
    }
}

/// 启动图磁盘缓存
enum BrandLaunchImageCache {

    static func loadImage(for urlString: String) async -> UIImage? {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return nil }

        let cacheURL = cacheFileURL(for: urlString)

        // 命中缓存
        if let data = try? Data(contentsOf: cacheURL), let img = UIImage(data: data) {
            // 后台静默刷新
            Task.detached(priority: .utility) { _ = await download(url: url, saveTo: cacheURL) }
            return img
        }

        // 首次下载
        return await download(url: url, saveTo: cacheURL)
    }

    @discardableResult
    private static func download(url: URL, saveTo cacheURL: URL) async -> UIImage? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let img = UIImage(data: data) else { return nil }
            try? FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: cacheURL, options: .atomic)
            return img
        } catch {
            return nil
        }
    }

    private static func cacheFileURL(for urlString: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("BrandLaunch", isDirectory: true)
        // 简单稳定哈希做文件名
        var h: UInt64 = 5381
        for b in urlString.utf8 { h = (h &* 33) &+ UInt64(b) }
        return dir.appendingPathComponent(String(h, radix: 16) + ".img")
    }
}
