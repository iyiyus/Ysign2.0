import SwiftUI

/// 设备 UDID 获取页面
///
/// 通过 Safari 打开服务器上的 .mobileconfig 描述文件获取设备真实 UDID。
///
/// 流程：
/// 1. 用户配置描述文件 URL（如 https://你的域名/udid.mobileconfig）
/// 2. 点击「获取 UDID」→ Safari 打开链接 → 下载描述文件
/// 3. 用户去「设置」安装描述文件
/// 4. 服务器收到设备信息，解析 UDID，重定向到 ysign://?udid=xxx
/// 5. App 接收并显示 UDID
struct DeviceUDIDView: View {

    /// 已存储的 UDID
    @AppStorage("deviceUDID") private var storedUDID: String = ""

    /// 是否已复制
    @State private var copied = false

    /// 设备基本信息
    @State private var deviceName = ""
    @State private var deviceModel = ""
    @State private var systemVersion = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 20)

                Image(systemName: "iphone.badge.checkmark")
                    .font(.system(size: 80))
                    .foregroundColor(.accentColor)

                Text("获取设备 UDID")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("点击【获取 UDID】按钮后，将跳转到 Safari 下载配置描述文件。\n下载完成后请在【设置】App 中安装描述文件，安装后 UDID 会自动回传。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 24)

                // 获取 UDID 按钮
                Button {
                    UDIDService.shared.openInSafari()
                } label: {
                    Text("获取 UDID")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(width: 160, height: 50)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                }

                // 已有 UDID
                if !storedUDID.isEmpty {
                    Divider().padding(.horizontal, 40)

                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("UDID 已获取")
                                .font(.headline)
                        }

                        Text(storedUDID)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                            .padding(.horizontal, 24)

                        Button {
                            UIPasteboard.general.string = storedUDID
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        } label: {
                            HStack {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                Text(copied ? "已复制" : "复制 UDID")
                            }
                            .font(.subheadline).fontWeight(.medium)
                        }
                    }
                }

                // 设备信息
                VStack(spacing: 8) {
                    infoRow("设备名称", value: deviceName)
                    infoRow("设备型号", value: deviceModel)
                    infoRow("系统版本", value: systemVersion)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                .padding(.horizontal, 24)

                Spacer()
            }
        }
        .navigationTitle("设备 UDID")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadDeviceInfo() }
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline)
        }
    }

    private func loadDeviceInfo() {
        let device = UIDevice.current
        deviceName = device.name
        deviceModel = device.model
        systemVersion = "\(device.systemName) \(device.systemVersion)"
    }
}

