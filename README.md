# YSign

纯 Swift 实现的 iOS IPA 签名工具，所有签名计算均在设备本地完成，无需任何后端服务。

## 主要特性

### 签名核心

- **纯离线签名**：基于 `Security.framework` + `CryptoKit`，全部签名计算在设备本机完成
- **完整签名流水线**：解压 → 预处理 → 代码签名 → 重新打包，一站式完成
- **dylib 注入**：签名时可拷贝并注入动态库
- **证书与描述文件管理**：P12 导入（OpenSSL 兼容解析）、`mobileprovision` 解析与归档、OCSP 吊销检查
- **防调试保护**：内置反调试守卫，检测到调试器附加时阻断使用

### 应用能力

- **IPA 资源库**：从系统文件 / WiFi 传输导入，支持预览与一键签名
- **软件源与下载管理**：可订阅 JSON 软件源、分类浏览、内置下载队列
- **双通道安装**：
  - **服务器中转**（默认）：签名产物上传到中转服务器，通过 `itms-services://` 在线安装
  - **本地安装**：设备本地起 HTTP 服务承载 IPA + manifest，无需任何外部服务器
- **WiFi 文件传输**：设备本地 HTTP 服务器，电脑浏览器上传 / 下载 / 删除文件；端口占用自动回退（8080 → 8088–8092）、大文件分块流式下载、Bonjour 局域网发现、深浅色自适应品牌网页
- **备份与还原**：应用数据打包为 **AES-GCM 加密**备份文件（可选密码），自带 SHA-256 完整性校验；可选择性备份配置 / 工作区 / 文件
- **存储空间管理**：分类扫描占用分布，逐文件勾选清理，证书与描述文件永不参与清理
- **设备 UDID 工具**：描述文件方式获取真机 UDID（服务端部署于 `ip.iosk.cn/udid`）
- **启动体验**：纯白启动屏 + "Ysign" 手写字标淡入、笔画书写式展开动画

### 界面

- **SwiftUI 全新 UI**：声明式 UI、自研设计系统（`Theme.swift`）、**深浅色全量自适应**、最低支持 iOS 16

## 技术架构

| 层级 | 技术选型 | 说明 |
|------|----------|------|
| UI | SwiftUI | 声明式 UI，iOS 16+，深浅色动态色适配 |
| 状态管理 | ObservableObject + @EnvironmentObject | 单一数据源 |
| 异步 | Swift Concurrency | `async/await` + `TaskGroup` 并发签名 |
| 签名引擎 | Security.framework + CryptoKit | 系统原生，硬件加速 |
| 压缩 | ZIPFoundation | IPA 解压 / 打包 / 备份打包 |
| 安装 | NWListener + itms-services | 本地 HTTP 服务器 / 服务器中转 |
| 工程文件 | XcodeGen + CocoaPods | `project.yml` 生成工程，Pods 提供 OpenSSL 等附属能力 |
| 最低版本 | iOS 16.0 | |

## 性能要点

1. **并发签名**：使用 `TaskGroup` 并行签名 Frameworks 与 PlugIns
2. **硬件加速哈希**：CryptoKit SHA-256 自动利用 Apple Silicon 硬件加速
3. **流式 ZIP**：可在不全量解压的前提下预览 IPA 元信息
4. **内存映射**：大体积可执行文件使用 `mmap` 避免一次性加载
5. **流式下载**：WiFi 传输按 256KB 分块发送文件，大 IPA 不占额外内存

## 项目结构

```
Ysign2.0/
├── YSign/                              ← 主应用代码
│   ├── YSignApp.swift                  ← App 入口（启动动画挂载）
│   ├── AppState.swift                  ← 全局状态管理
│   ├── ContentView.swift               ← 根 TabView（5 个 Tab）
│   ├── Theme.swift                     ← 设计系统（色令牌 / 卡片 / 按钮，深浅色自适应）
│   ├── Models/                         ← 数据模型
│   │   ├── CertificateInfo.swift       ← 证书信息
│   │   ├── IPAFile.swift               ← IPA 文件信息
│   │   ├── AppSource.swift             ← 软件源 / 应用 / 下载任务模型
│   │   ├── MobileProvision.swift       ← 描述文件解析
│   │   ├── SigningTask.swift           ← 签名任务与选项
│   │   └── SigningError.swift          ← 错误定义
│   ├── Views/                          ← SwiftUI 视图
│   │   ├── SplashView.swift            ← 启动动画（字标淡入 + 笔画展开）
│   │   ├── OnboardingView.swift        ← 首次启动引导
│   │   ├── FileManagerView.swift       ← 文件管理器（Tab）
│   │   ├── SigningHubView.swift        ← 签名中心（Tab）
│   │   ├── LibraryView.swift           ← IPA 资源库
│   │   ├── SigningView.swift           ← 签名任务列表
│   │   ├── SigningConfigView.swift     ← 签名配置页
│   │   ├── SigningProgressView.swift   ← 签名进度页
│   │   ├── SigningDefaultsView.swift   ← 签名默认参数
│   │   ├── CertificatesView.swift      ← 证书管理
│   │   ├── AppSourcesView.swift        ← 软件源管理（Tab）
│   │   ├── AddSourceView.swift         ← 添加软件源
│   │   ├── SourceAppsView.swift        ← 源内应用浏览
│   │   ├── DownloadView.swift          ← 下载管理（Tab）
│   │   ├── SettingsView.swift          ← 设置页（Tab）
│   │   ├── StorageView.swift           ← 存储空间管理
│   │   ├── BackupView.swift            ← 备份与还原
│   │   ├── IPAInstallServerView.swift  ← 安装方式与服务器配置
│   │   ├── QuickInstallView.swift      ← 快速安装
│   │   ├── WiFiTransferView.swift      ← WiFi 文件传输
│   │   ├── DeviceUDIDView.swift        ← 设备 UDID 工具
│   │   ├── PlistEditorView.swift       ← Plist 编辑器
│   │   ├── MachOInspectorView.swift    ← Mach-O 检视器
│   │   ├── HexViewerView.swift         ← 二进制查看
│   │   ├── AntiDebugBlockView.swift    ← 反调试阻断页
│   │   └── InAppFilePicker.swift       ← 应用内文件选择器
│   ├── Stores/                         ← 数据持久化
│   │   ├── CertificateStore.swift      ← 证书存储
│   │   ├── ProvisioningProfileStore.swift ← 描述文件存储
│   │   ├── IPALibraryManager.swift     ← IPA 库管理
│   │   ├── AppSourceStore.swift        ← 软件源存储 + 网络拉取
│   │   ├── DownloadManager.swift       ← 下载任务管理
│   │   └── SigningProcessQueue.swift   ← 签名任务队列
│   ├── Services/                       ← 设备相关服务
│   │   ├── UDIDService.swift           ← 描述文件 UDID 获取（ip.iosk.cn/udid）
│   │   └── RevocationService.swift     ← 证书吊销（OCSP）检查
│   ├── Utils/                          ← 通用工具
│   │   ├── IPAInstaller.swift          ← 本地 HTTP + itms-services 安装
│   │   ├── WiFiFileServer.swift        ← WiFi 传输 HTTP 服务器
│   │   ├── BackupService.swift         ← AES-GCM 加密备份 / 还原
│   │   ├── StorageAnalyzer.swift       ← 存储占用分析与清理
│   │   ├── BackgroundKeepAlive.swift   ← 后台保活（传输 / 安装期间）
│   │   ├── CertificateImportService.swift ← 证书导入
│   │   └── AntiDebugGuard.swift        ← 反调试守卫
│   └── ObjC/                           ← Swift 与 OpenSSL 桥接
│       ├── OpenSSLP12Parser.mm         ← P12 兼容解析
│       └── OCSPChecker.mm              ← OCSP 吊销检查
├── Sources/SigningEngine/              ← 签名引擎核心
│   ├── CertificateParser.swift         ← P12 证书解析
│   ├── MachOParser.swift               ← Mach-O 二进制解析
│   ├── CodeSigner.swift                ← 代码签名器
│   ├── DylibInjector.swift             ← 动态库注入
│   ├── IPAHandler.swift                ← IPA 解压 / 打包
│   ├── ArchiveKit.swift                ← 归档工具
│   └── SigningPipeline.swift           ← 签名流水线编排
├── Server/                             ← UDID 服务端（部署到 ip.iosk.cn/udid）
│   ├── receive.php                     ← 接收 UDID 并回跳 App
│   └── udid.mobileconfig               ← 描述文件模板
├── Tests/SigningEngineTests/           ← 签名引擎单元测试
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
git clone https://github.com/iyiyus/Ysign2.0.git
cd Ysign2.0

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

可使用 Xcode 命令行构建未签名 IPA，便于后续在 iOS 设备上由其他签名工具二次签名安装：

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
输出签名后的 IPA → 安装（服务器中转 / 本地安装）
```

## 主要 Tab 一览

- **文件**：浏览、整理、分享应用沙盒文件
- **应用**：签名中心，包含资源库、签名配置、任务进度
- **软件源**：订阅 JSON 软件源并按分类浏览
- **下载**：管理 IPA / 资源下载任务
- **设置**：证书管理、UDID、外观（深浅色）、安装方式、WiFi 传输、备份还原、存储空间、签名默认参数

## UDID 服务端部署

`Server/` 目录包含获取 UDID 的服务端文件，部署到支持 PHP 的 HTTPS 站点（默认配置为 `ip.iosk.cn/udid`）：

1. 上传 `receive.php` 与 `udid.mobileconfig` 到站点 `udid/` 目录
2. 确保描述文件内回调地址与 `receive.php` 地址一致
3. 如需更换域名，同步修改 `UDIDService.swift` 中的 `mobileconfigURL`

## 开发维护

- 所有代码均带有详细中文注释
- 每个文件顶部说明职责与设计思路
- 核心算法附有原理解释，便于二次开发

## 许可证

仅供学习与研究使用。任何使用本项目对未授权 IPA 进行修改、签名、分发等行为，由使用者本人承担全部法律责任，与项目作者无关。
