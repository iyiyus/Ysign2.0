import SwiftUI

/// 设置页面
///
/// 提供应用的全局配置选项：
/// - 外观设置（深色/浅色模式）
/// - 签名默认选项
/// - 存储管理
/// - 关于信息
struct SettingsView: View {
    /// 外观模式选择（0=跟随系统，1=浅色，2=深色）
    @AppStorage("appearanceMode") private var appearanceMode = 0

    /// 缓存大小文字
    @State private var cacheSize = "计算中..."

    var body: some View {
        NavigationStack {
            Form {
                // 证书与设备
                identitySection

                // 传输
                transferSection

                // 外观设置
                appearanceSection

                // 安装设置
                installSection

                // 签名默认选项
                signingDefaultsSection

                // 存储管理
                storageSection

                // 支持与帮助
                supportSection

                // 关于
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(DS.background.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                cacheSize = await calculateCacheSize()
            }
        }
        .tint(DS.primary)
    }

    /// 带品牌图标底的设置行标签
    private func dsSettingLabel(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            DSIconBadge(systemName: icon, color: color, size: 30)
            Text(title)
                .foregroundStyle(DS.text)
        }
    }

    // MARK: - 各设置分区

    /// 签名身份区域（对应旧版「签名身份」Section）
    private var identitySection: some View {
        Section {
            // 证书管理 → 跳转到签名 Tab 的证书页
            NavigationLink {
                CertificatesView()
            } label: {
                dsSettingLabel("证书管理", icon: "lock.shield", color: DS.primary)
            }

            // 设备 UDID
            NavigationLink {
                DeviceUDIDView()
            } label: {
                dsSettingLabel("设备 UDID", icon: "iphone", color: .indigo)
            }
        } header: {
            Text("签名身份")
        }
    }

    /// 传输区域（对应旧版「传输」Section）
    private var transferSection: some View {
        Section {
            NavigationLink {
                WiFiTransferView()
            } label: {
                dsSettingLabel("WiFi 文件传输", icon: "wifi", color: .blue)
            }
        } header: {
            Text("传输")
        } footer: {
            Text("通过局域网在电脑和设备之间传输文件")
        }
    }

    /// 外观设置区域
    private var appearanceSection: some View {
        Section {
            Picker("外观模式", selection: $appearanceMode) {
                Text("跟随系统").tag(0)
                Text("浅色模式").tag(1)
                Text("深色模式").tag(2)
            }
        } header: {
            Text("外观")
        } footer: {
            Text("设置应用的显示主题")
        }
    }

    /// 安装设置区域
    private var installSection: some View {
        Section {
            NavigationLink {
                IPAInstallServerView()
            } label: {
                dsSettingLabel("IPA 安装服务器", icon: "server.rack", color: .purple)
            }
        } header: {
            Text("IPA 安装")
        } footer: {
            Text("配置 plist.php 安装服务器，支持多个地址自动切换")
        }
    }

    /// 签名默认选项区域
    private var signingDefaultsSection: some View {
        Section {
            NavigationLink {
                SigningDefaultsView()
            } label: {
                dsSettingLabel("签名默认配置", icon: "signature", color: DS.accent)
            }
            NavigationLink {
                BackupView()
            } label: {
                dsSettingLabel("备份与还原", icon: "externaldrive.badge.timemachine", color: .orange)
            }
        } header: {
            Text("签名默认选项")
        } footer: {
            Text("配置签名任务的默认参数，新建签名时将使用这些值")
        }
    }

    /// 存储管理区域
    private var storageSection: some View {
        Section {
            NavigationLink {
                StorageView()
            } label: {
                HStack {
                    dsSettingLabel("存储空间", icon: "internaldrive", color: .orange)
                    Spacer()
                    Text(cacheSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("存储")
        } footer: {
            Text("查看占用分布，按项目选择性清理缓存与临时文件")
        }
    }

    /// 支持与帮助区域（对应旧版「偏好与支持」）
    private var supportSection: some View {
        Section {
            // 使用教程
            Link(destination: URL(string: "https://docs.qq.com/doc/DUmZhR2JhYld2U2Z5")!) {
                HStack {
                    Label("使用教程", systemImage: "book")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundColor(.primary)

            // 联系我们
            Link(destination: URL(string: "https://t.me/ysign")!) {
                HStack {
                    Label("联系我们", systemImage: "bubble.left")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundColor(.primary)

            // 服务及隐私协议
            Link(destination: URL(string: "https://www.julyedu.com/agreement/priv")!) {
                HStack {
                    Label("服务及隐私协议", systemImage: "doc.text")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundColor(.primary)
        } header: {
            Text("支持与帮助")
        }
    }

    /// 关于区域
    private var aboutSection: some View {
        Section {
            HStack {
                Text("版本")
                Spacer()
                Text("2.0.0")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("构建号")
                Spacer()
                Text("1")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("引擎")
                Spacer()
                Text("Swift Native (CryptoKit)")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("关于 YSign")
        } footer: {
            Text("纯 Swift 实现的 iOS 应用签名工具\n使用 Apple Security.framework + CryptoKit 原生签名引擎")
        }
    }

    // MARK: - 操作方法

    /// 统计应用占用（与存储空间页面使用同一套分析逻辑）
    private func calculateCacheSize() async -> String {
        let total = await Task.detached(priority: .utility) {
            StorageAnalyzer.totalSize()
        }.value
        return total.storageSizeString
    }
}
