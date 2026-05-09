import SwiftUI

/// 证书管理页面
///
/// 证书和描述文件配对管理：
/// - 先导入 P12 证书 → 列表显示"未导入描述文件"
/// - 再导入描述文件 → 与证书关联
/// - 点击证书 → 显示详细信息（名称、组织、过期、设备、权限等）
struct CertificatesView: View {
    @EnvironmentObject var appState: AppState

    /// 导入 P12
    @State private var showingP12Importer = false
    @State private var showingPasswordAlert = false
    @State private var pendingP12URL: URL?
    @State private var p12Password = ""

    /// 错误 / 成功提示
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var successMessage: String?
    @State private var showingSuccess = false

    var body: some View {
        VStack {
            if appState.certificates.isEmpty {
                emptyStateView
            } else {
                certificateListView
            }
        }
        .sheet(isPresented: $showingP12Importer) {
            InAppFilePicker(
                allowedExtensions: ["p12", "pfx"],
                title: "选择 P12 证书"
            ) { url in
                pendingP12URL = url
                p12Password = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showingPasswordAlert = true
                }
            }
        }
        .alert("输入证书密码", isPresented: $showingPasswordAlert) {
            SecureField("密码", text: $p12Password)
            Button("导入") { importCertificate() }
            Button("取消", role: .cancel) { p12Password = "" }
        } message: {
            Text("请输入 P12 证书的保护密码")
        }
        .alert("错误", isPresented: $showingError) {
            Button("确定") {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .alert("成功", isPresented: $showingSuccess) {
            Button("确定") {}
        } message: {
            Text(successMessage ?? "")
        }
        .onAppear {
            Task { await appState.loadCertificates() }
        }
    }

    // MARK: - 子视图

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("还没有导入证书")
                .font(.title2)
                .fontWeight(.medium)

            Text("先导入 P12 证书，再导入描述文件\n支持个人证书和企业证书")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showingP12Importer = true
            } label: {
                Label("导入 P12 证书", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var certificateListView: some View {
        List {
            ForEach(appState.certificates) { cert in
                NavigationLink {
                    CertificateDetailView(cert: cert)
                        .environmentObject(appState)
                } label: {
                    CertificateRow(cert: cert)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        deleteCertificate(cert)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }

            Section {
                Button {
                    showingP12Importer = true
                } label: {
                    Label("导入新证书", systemImage: "plus.circle")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - P12 导入

    private func importCertificate() {
        guard let url = pendingP12URL else { return }

        Task {
            do {
                let store = CertificateStore()
                let cert = try await store.importP12(from: url, password: p12Password)
                await appState.loadCertificates()
                successMessage = "证书 \"\(cert.name)\" 已导入\n请继续导入描述文件"
                showingSuccess = true
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }

            p12Password = ""
            pendingP12URL = nil
        }
    }

    private func deleteCertificate(_ cert: CertificateInfo) {
        Task {
            let store = CertificateStore()
            try? await store.delete(id: cert.id)
            await appState.loadCertificates()
        }
    }
}

// MARK: - 证书列表行

struct CertificateRow: View {
    let cert: CertificateInfo

    var body: some View {
        HStack(spacing: 12) {
            // 状态图标
            Image(systemName: cert.hasProfile ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.title2)
                .foregroundColor(statusColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(cert.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if cert.hasProfile {
                    Text(cert.profileBundleID ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("⚠ 未导入描述文件")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Text(cert.displayExpiryStatus)
                    .font(.caption2)
                    .foregroundColor(cert.isExpired ? .red : .green)
            }

            Spacer()

            // 证书类型标签
            Text(cert.certificateType)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.1))
                .foregroundColor(.blue)
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        if cert.isExpired { return .red }
        if !cert.hasProfile { return .orange }
        return .green
    }
}

// MARK: - 证书详情页

struct CertificateDetailView: View {
    @EnvironmentObject var appState: AppState
    let cert: CertificateInfo

    @State private var showingProfileImporter = false
    @State private var showingDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var successMessage: String?
    @State private var showingSuccess = false

    /// 实时获取最新证书数据
    private var currentCert: CertificateInfo {
        appState.certificates.first(where: { $0.id == cert.id }) ?? cert
    }

    var body: some View {
        List {
            // 证书基本信息
            Section("证书信息") {
                DetailRow(title: "名称", value: currentCert.name)
                DetailRow(title: "类型", value: currentCert.certificateType)
                DetailRow(title: "组织", value: currentCert.teamName)
                DetailRow(title: "组织单位 (OU)", value: currentCert.organizationalUnit)
                DetailRow(title: "团队 ID", value: currentCert.teamID)
                DetailRow(title: "序列号", value: currentCert.serialNumber)
                DetailRow(title: "支持平台", value: currentCert.platform)
            }

            // 证书状态
            Section("证书状态") {
                HStack {
                    Text("状态")
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Circle()
                            .fill(currentCert.isExpired ? .red : .green)
                            .frame(width: 8, height: 8)
                        Text(currentCert.displayExpiryStatus)
                            .foregroundColor(currentCert.isExpired ? .red : .green)
                    }
                }
                DetailRow(title: "生效时间", value: formatDate(currentCert.creationDate))
                DetailRow(title: "过期时间", value: formatDate(currentCert.expirationDate))
            }

            // 描述文件信息
            Section {
                if currentCert.hasProfile {
                    DetailRow(title: "名称", value: currentCert.profileName ?? "-")
                    DetailRow(title: "Bundle ID", value: currentCert.profileBundleID ?? "-")
                    DetailRow(title: "类型", value: currentCert.profileType ?? "-")
                    if let expDate = currentCert.profileExpirationDate {
                        DetailRow(title: "过期时间", value: formatDate(expDate))
                    }

                    // 更换描述文件
                    Button {
                        showingProfileImporter = true
                    } label: {
                        Label("更换描述文件", systemImage: "arrow.triangle.2.circlepath")
                    }

                    // 移除描述文件
                    Button(role: .destructive) {
                        unlinkProfile()
                    } label: {
                        Label("移除描述文件", systemImage: "trash")
                    }
                } else {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("未导入描述文件，无法签名")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        showingProfileImporter = true
                    } label: {
                        Label("导入描述文件", systemImage: "plus.circle.fill")
                    }
                }
            } header: {
                Text("描述文件")
            }

            // 支持的设备 UDID
            if let devices = currentCert.provisionedDevices, !devices.isEmpty {
                Section {
                    ForEach(devices, id: \.self) { udid in
                        Text(udid)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("已注册设备 (\(devices.count) 台)")
                } footer: {
                    Text("只有这些 UDID 的设备可以安装签名后的应用")
                }
            } else if currentCert.hasProfile && currentCert.provisionedDevices == nil {
                Section("设备支持") {
                    HStack {
                        Image(systemName: "globe")
                            .foregroundColor(.green)
                        Text("不限设备（企业证书 / App Store）")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 证书权限
            if let keys = currentCert.entitlementKeys, !keys.isEmpty {
                Section {
                    ForEach(keys, id: \.self) { key in
                        Text(key)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("证书权限 (Entitlements)")
                }
            }

            // 删除证书
            Section {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        Label("删除证书", systemImage: "trash")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("证书详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingProfileImporter) {
            InAppFilePicker(
                allowedExtensions: ["mobileprovision"],
                title: "选择描述文件"
            ) { url in
                importProfile(from: url)
            }
        }
        .alert("确认删除", isPresented: $showingDeleteConfirm) {
            Button("删除", role: .destructive) { deleteCert() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复，确定删除该证书？")
        }
        .alert("错误", isPresented: $showingError) {
            Button("确定") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("成功", isPresented: $showingSuccess) {
            Button("确定") {}
        } message: {
            Text(successMessage ?? "")
        }
    }

    // MARK: - 操作

    private func importProfile(from url: URL) {
        Task {
            do {
                let store = CertificateStore()
                let updated = try await store.linkProfile(certID: cert.id, profileURL: url)
                await appState.loadCertificates()
                successMessage = "描述文件 \"\(updated.profileName ?? "")\" 已关联"
                showingSuccess = true
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    private func unlinkProfile() {
        Task {
            let store = CertificateStore()
            try? await store.unlinkProfile(certID: cert.id)
            await appState.loadCertificates()
        }
    }

    private func deleteCert() {
        Task {
            let store = CertificateStore()
            try? await store.delete(id: cert.id)
            await appState.loadCertificates()
        }
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }
}

// MARK: - 详情行

struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
