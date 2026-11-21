import XCTest
@testable import SigningEngine

/// SigningEngine 单元测试占位文件
///
/// Package.swift 中声明了 SigningEngineTests 测试目标（path: Tests/SigningEngineTests），
/// 此文件保证该路径存在，避免 Xcode 加载 Swift 包时报
/// "invalid custom path 'Tests/SigningEngineTests'" 错误。
/// 后续可为签名引擎补充具体单元测试。
final class SigningEngineTests: XCTestCase {

    /// 占位测试：验证测试目标可正常编译运行
    func testPlaceholder() {
        XCTAssertTrue(true)
    }
}
