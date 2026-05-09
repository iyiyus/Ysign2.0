import SwiftUI

/// 签名默认配置页面
///
/// 从设置页进入，配置签名任务的全局默认值。
/// 所有值通过 @AppStorage 持久化，在 SigningConfigView 中作为初始值读取。
struct SigningDefaultsView: View {

    // MARK: - App 名字

    @AppStorage("defaultNamePrefix") private var namePrefix = ""
    @AppStorage("defaultNameSuffix") private var nameSuffix = ""

    // MARK: - 安装设置

    @AppStorage("defaultInstallAfterSign") private var installAfterSign = false

    // MARK: - 动态库注入设置

    @AppStorage("defaultDylibLoadPath") private var dylibLoadPath = "@executable"
    @AppStorage("defaultDylibDirectory") private var dylibDirectory = "Frameworks/"

    // MARK: - Info.plist

    @AppStorage("defaultAddInfoPlistContent") private var addInfoPlistContent = ""

    // MARK: - 打包文件名生成规则

    @AppStorage("defaultFileNameUseName") private var fileNameUseName = true
    @AppStorage("defaultFileNameUseVersion") private var fileNameUseVersion = true
    @AppStorage("defaultFileNameUseBundleID") private var fileNameUseBundleID = false
    @AppStorage("defaultFileNameUseCert") private var fileNameUseCert = false
    @AppStorage("defaultFileNameUseTimestamp") private var fileNameUseTimestamp = true

    // MARK: - 压缩级别

    @AppStorage("defaultCompressionLevel") private var compressionLevel = "兼容"

    // MARK: - 其他

    @AppStorage("defaultRemovePlugins") private var removePlugins = false
    @AppStorage("defaultRemoveWatch") private var removeWatch = false
    @AppStorage("defaultChangeMinVersion") private var changeMinVersion = true
    @AppStorage("defaultRemoveDeviceLimit") private var removeDeviceLimit = true
    @AppStorage("defaultRemoveAppJump") private var removeAppJump = false
    @AppStorage("defaultEnableFileAccess") private var enableFileAccess = false
    @AppStorage("defaultFixWhiteIcon") private var fixWhiteIcon = false
    @AppStorage("defaultAutoFixJailbreak") private var autoFixJailbreak = false
    @AppStorage("defaultConfigOnly") private var configOnly = false
    @AppStorage("defaultRemoveEmbeddedProvision") private var removeEmbeddedProvision = false

    var body: some View {
        Form {
            appNameSection
            installSection
            dylibInjectionSection
            infoPlistSection
            fileNameRuleSection
            compressionSection
            otherSection
        }
        .navigationTitle("签名默认配置")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - App 名字

    private var appNameSection: some View {
        Section("App 名字") {
            NavigationLink {
                Form {
                    Section("前缀") {
                        TextField("前缀（可选）", text: $namePrefix)
                    }
                }
                .navigationTitle("前缀")
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                HStack {
                    Text("前缀：")
                    Spacer()
                    Text(namePrefix.isEmpty ? "未设置" : namePrefix)
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink {
                Form {
                    Section("后缀") {
                        TextField("后缀（可选）", text: $nameSuffix)
                    }
                }
                .navigationTitle("后缀")
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                HStack {
                    Text("后缀：")
                    Spacer()
                    Text(nameSuffix.isEmpty ? "未设置" : nameSuffix)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 安装设置

    private var installSection: some View {
        Section("安装设置") {
            Toggle("签名后立即安装", isOn: $installAfterSign)
        }
    }

    // MARK: - 动态库注入设置

    private var dylibInjectionSection: some View {
        Section {
            HStack {
                Text("注入路径")
                Spacer()
                Picker("", selection: $dylibLoadPath) {
                    Text("@executable").tag("@executable")
                    Text("@rpath").tag("@rpath")
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            HStack {
                Text("注入目录")
                Spacer()
                Picker("", selection: $dylibDirectory) {
                    Text("/").tag("/")
                    Text("Frameworks/").tag("Frameworks/")
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        } header: {
            Text("动态库注入设置")
        } footer: {
            Text("\(dylibLoadPath)_path/\(dylibDirectory)xxx.dylib")
        }
    }

    // MARK: - Info.plist

    private var infoPlistSection: some View {
        Section("添加或者替换 Info.plist 内容") {
            NavigationLink {
                Form {
                    Section {
                        TextEditor(text: $addInfoPlistContent)
                            .frame(minHeight: 200)
                            .font(.system(.caption, design: .monospaced))
                    } footer: {
                        Text("输入要添加或替换的 Info.plist 键值对（XML 格式）")
                    }
                }
                .navigationTitle("Info.plist 内容")
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                Text("添加 Key - Value")
            }
        }
    }

    // MARK: - 打包文件名生成规则

    private var fileNameRuleSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FileNameTagButton(title: "名字", isSelected: $fileNameUseName)
                    FileNameTagButton(title: "版本号", isSelected: $fileNameUseVersion)
                    FileNameTagButton(title: "BundleId", isSelected: $fileNameUseBundleID)
                    FileNameTagButton(title: "证书", isSelected: $fileNameUseCert)
                    FileNameTagButton(title: "时间戳", isSelected: $fileNameUseTimestamp)
                }
                .padding(.vertical, 4)
            }

            Text(fileNameExample)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("打包文件名生成规则")
        }
    }

    private var fileNameExample: String {
        var parts: [String] = []
        if fileNameUseName { parts.append("AppDemo") }
        if fileNameUseVersion { parts.append("1.0") }
        if fileNameUseBundleID { parts.append("com.demo.app") }
        if fileNameUseCert { parts.append("cert") }
        if fileNameUseTimestamp { parts.append("时间戳") }
        let name = parts.isEmpty ? "output" : parts.joined(separator: "_")
        return "例如：\(name).ipa"
    }

    // MARK: - 压缩级别

    private var compressionSection: some View {
        Section {
            HStack {
                Text("压缩级别")
                Spacer()
                Picker("", selection: $compressionLevel) {
                    Text("速度").tag("速度")
                    Text("兼容").tag("兼容")
                    Text("大小").tag("大小")
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        } header: {
            Text("压缩级别设置")
        } footer: {
            switch compressionLevel {
            case "速度":
                Text("压缩速度快，压缩率低，文件较大")
            case "大小":
                Text("压缩率最高，速度较慢，文件较小")
            default:
                Text("兼容模式，平衡压缩速度和大小")
            }
        }
    }

    // MARK: - 其他

    private var otherSection: some View {
        Section("其他") {
            Toggle("移除所有插件 App", isOn: $removePlugins)
            Toggle("移除所有手表 App", isOn: $removeWatch)
            Toggle("修改版本限制为：iOS 10.0", isOn: $changeMinVersion)
            Toggle("移除设备限制", isOn: $removeDeviceLimit)
            Toggle("移除应用跳转", isOn: $removeAppJump)
            Toggle("开启文件访问", isOn: $enableFileAccess)
            Toggle("修复白图标", isOn: $fixWhiteIcon)
            Toggle("自动修改越狱依赖", isOn: $autoFixJailbreak)
            Toggle("仅修改配置，不签名", isOn: $configOnly)
            Toggle("签名后移除 embedded.mobileprovision", isOn: $removeEmbeddedProvision)
        }
    }
}

// MARK: - 文件名标签按钮

struct FileNameTagButton: View {
    let title: String
    @Binding var isSelected: Bool

    var body: some View {
        Button {
            isSelected.toggle()
        } label: {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(.systemGray6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color(.systemGray4), lineWidth: 1)
                )
                .foregroundColor(isSelected ? .accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}
