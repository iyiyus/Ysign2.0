# YSign

纯 Swift 实现的 iOS IPA 签名工具，所有签名计算均在设备本地完成，无需任何后端服务。

## 主要特性

- **纯离线签名**：基于 `Security.framework` + `CryptoKit`，全部签名计算在设备本机完成
- **完整签名流水线**：解压 → 预处理 → 代码签名 → 重新打包，一站式完成
- **证书与描述文件管理**：支持 P12 证书导入、`mobileprovision` 解析与归档
- **资源库与文件管理**：内置 IPA 资源库、文件管理器、WiFi 文件传输
- **软件源与下载管理**：可订阅 JSON 软件源、查看分类应用、内置下载队列
- **本地安装支持**：通过本地 HTTP + `itms-services://` 链路在 iOS 设备上安装签好的 IPA
- **设备 UDID 工具**：内置描述文件方式获取真机 UDID
- **SwiftUI 全新 UI**：声明式 UI、深浅色自适应、最低支持 iOS 16

## 技术架构

| 层级 | 技术选型 | 说明 |
|------|----------|------|
| UI | SwiftUI | 声明式 UI，iOS 16+ |
| 状态管理 | ObservableObject + @EnvironmentObject | 单一数据源 |
| 异步 | Swift Concurrency | `async/await` + `TaskGroup` 并发签名 |
| 签名引擎 | Security.framework + CryptoKit | 系统原生，硬件加速 |
| 压缩 | ZIPFoundation | IPA 解压 / 打包 |
| 工程文件 | XcodeGen + CocoaPods | `project.yml` 生成工程，Pods 提供 OpenSSL 等附属能力 |
| 最低版本 | iOS 16.0 | |

## 性能要点

1. **并发签名**：使用 `TaskGroup` 并行签名 Frameworks 与 PlugIns
2. **硬件加速哈希**：CryptoKit SHA-256 自动利用 Apple Silicon 硬件加速
3. **流式 ZIP**：可在不全量解压的前提下预览 IPA 元信息
4. **内存映射**：大体积可执行文件使用 `mmap` 避免一次性加载

## 项目结构

```
YSign/
├── YSign/                              ← 主应用代码
│   ├── YSignApp.swift                  ← App 入口
│   ├── AppState.swift                  ← 全局状态管理
│   ├── ContentView.swift               ← 根 TabView（5 个 Tab）
│   ├── Models/                         ← 数据模型
│   │   ├── CertificateInfo.swift       ← 证书信息
│   │   ├── IPAFile.swift               ← IPA 文件信息
│   │   ├── AppSource.swift             ← 软件源 / 应用 / 下载任务模型
│   │   ├── MobileProvision.swift       ← 描述文件解析
│   │   ├── SigningTask.swift           ← 签名任务与选项
│   │   └── SigningError.swift          ← 错误定义
│   ├── Views/                          ← SwiftUI 视图
│   │   ├── FileManagerView.swift       ← 文件管理器（Tab）
│   │   ├── SigningHubView.swift        ← 签名中心（Tab）
│   │   ├── LibraryView.swift           ← IPA 资源库
│   │   ├── SigningView.swift           ← 签名任务列表
│   │   ├── SigningConfigView.swift     ← 签名配置页
│   │   ├── SigningProgressView.swift   ← 签名进度页
│   │   ├── SigningDefaultsView.swift   ← 签名默认参数
│   │   ├── CertificatesView.swift      ← 证书管理
│   │   ├── AppSourcesView.swift        ← 软件源管理（Tab）
│   │   ├── SourceAppsView.swift        ← 源内应用浏览
│   │   ├── DownloadView.swift          ← 下载管理（Tab）
│   │   ├── SettingsView.swift          ← 设置页（Tab）
│   │   ├── IPAInstallServerView.swift  ← 安装服务器配置
│   │   ├── HexViewerView.swift         ← 二进制查看
│   │   ├── WiFiTransferView.swift      ← WiFi 文件传输
│   │   ├── DeviceUDIDView.swift        ← 设备 UDID 工具
│   │   └── InAppFilePicker.swift       ← 应用内文件选择器
│   ├── Stores/                         ← 数据持久化
│   │   ├── CertificateStore.swift      ← 证书存储
│   │   ├── ProvisioningProfileStore.swift ← 描述文件存储
│   │   ├── IPALibraryManager.swift     ← IPA 库管理
│   │   ├── AppSourceStore.swift        ← 软件源存储 + 网络拉取
│   │   └── DownloadManager.swift       ← 下载任务管理
│   ├── Services/                       ← 设备相关服务
│   │   └── UDIDService.swift           ← 描述文件 UDID 获取
│   ├── Utils/                          ← 通用工具
│   │   └── IPAInstaller.swift          ← 本地 HTTP + itms-services 安装
│   └── ObjC/                           ← Swift 与 OpenSSL 桥接
│       └── OpenSSLP12Parser.mm         ← P12 兼容解析
├── Sources/SigningEngine/              ← 签名引擎核心
│   ├── CertificateParser.swift         ← P12 证书解析
│   ├── MachOParser.swift               ← Mach-O 二进制解析
│   ├── CodeSigner.swift                ← 代码签名器
│   ├── DylibInjector.swift             ← 动态库注入
│   ├── IPAHandler.swift                ← IPA 解压 / 打包
│   └── SigningPipeline.swift           ← 签名流水线编排
├── Podfile / Podfile.lock              ← CocoaPods 依赖
├── Package.swift                       ← Swift Package Manager 描述
├── project.yml                         ← XcodeGen 工程配置
├── YSign.xcodeproj                     ← 生成的 Xcode 工程
└── YSign.xcworkspace                   ← Pods 集成后的工作区
```

## 环境要求

- macOS + Xcode 15 及以上
- iOS 16.0 及以上的真机或模拟器
- CocoaPods（用于附属依赖）
- 可选：XcodeGen（重新生成 `YSign.xcodeproj`）

## 快速开始

```bash
# 1. 克隆仓库
git clone <your-repo-url>
cd YSign

# 2. 安装 CocoaPods 依赖
pod install

# 3. 打开工作区（必须使用 .xcworkspace）
open YSign.xcworkspace
```

如需重新生成 Xcode 工程：

```bash
brew install xcodegen
xcodegen generate
pod install
```

## 构建未签名 IPA

仓库已经过验证，可使用 Xcode 命令行构建未签名 IPA，便于后续在 iOS 设备上由其他签名工具二次签名安装：

```bash
# Release 构建并跳过代码签名
xcodebuild \
  -workspace YSign.xcworkspace \
  -scheme YSign \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

# 将 .app 打包成未签名 IPA
APP_PATH="build/Build/Products/Release-iphoneos/YSign.app"
STAGE="$(mktemp -d)/Payload"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"
( cd "$(dirname "$STAGE")" && zip -qr "$PWD/../YSign-unsigned.ipa" Payload )
```

输出文件即可作为未签名 IPA 使用。

## 签名流程

```
用户选择 IPA
    ↓
选择证书 + 配置签名选项
    ↓
┌─── 签名流水线 (SigningPipeline) ───┐
│  1. 解压 IPA → 临时目录             │
│  2. 预处理                          │
│     - 修改 Bundle ID / 名称 / 版本  │
│     - 替换图标（可选）              │
│     - 移除 PlugIns / Watch          │
│     - 拷贝并注入 dylib              │
│     - 嵌入描述文件                  │
│  3. 代码签名                        │
│     - 并发签名 Frameworks           │
│     - 签名主可执行文件              │
│     - 生成 CodeResources            │
│  4. 重新打包为 IPA                  │
│  5. 清理临时文件                    │
└─────────────────────────────────────┘
    ↓
输出签名后的 IPA
```

## 主要 Tab 一览

- **文件**：浏览、整理、分享应用沙盒文件
- **应用**：签名中心，包含资源库、签名配置、任务进度
- **软件源**：订阅 JSON 软件源并按分类浏览
- **下载**：管理 IPA / 资源下载任务
- **设置**：证书管理、UDID、外观、安装服务器、签名默认参数、缓存清理

## 开发维护

- 所有代码均带有详细中文注释
- 每个文件顶部说明职责与设计思路
- 核心算法附有原理解释，便于二次开发

## 许可证

仅供学习与研究使用。任何使用本项目对未授权 IPA 进行修改、签名、分发等行为，由使用者本人承担全部法律责任，与项目作者无关。
