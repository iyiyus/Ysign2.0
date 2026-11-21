import SwiftUI

// MARK: - Plist 节点模型

/// Plist 树节点（字典/数组/标量）
final class PlistNode: Identifiable, ObservableObject {
    let id = UUID()

    /// 字典键名（数组元素为索引字符串）
    var key: String

    /// 节点类型
    enum Kind {
        case dictionary
        case array
        case scalar(Any)

        var label: String {
            switch self {
            case .dictionary: return "dict"
            case .array: return "array"
            case .scalar(let v):
                switch v {
                case is String: return "string"
                case is Bool: return "bool"
                case is Int, is Double: return "number"
                case is Date: return "date"
                case is Data: return "data"
                default: return "value"
                }
            }
        }
    }

    let kind: Kind
    @Published var children: [PlistNode]

    init(key: String, kind: Kind, children: [PlistNode] = []) {
        self.key = key
        self.kind = kind
        self.children = children
    }

    var isContainer: Bool {
        switch kind {
        case .dictionary, .array: return true
        case .scalar: return false
        }
    }

    var isDictionary: Bool {
        if case .dictionary = kind { return true }
        return false
    }

    var isArray: Bool {
        if case .array = kind { return true }
        return false
    }

    /// 标量值的显示文本
    var scalarDisplay: String {
        switch kind {
        case .scalar(let v):
            if let s = v as? String { return s }
            if let b = v as? Bool { return b ? "true" : "false" }
            if let d = v as? Date { return d.formatted(date: .abbreviated, time: .shortened) }
            if let data = v as? Data { return "<\(data.count) 字节>" }
            return "\(v)"
        default: return ""
        }
    }

    /// 从任意 plist 值构建节点树
    static func from(key: String, value: Any) -> PlistNode {
        if let dict = value as? [String: Any] {
            let children = dict.keys.sorted().map { k in PlistNode.from(key: k, value: dict[k]!) }
            return PlistNode(key: key, kind: .dictionary, children: children)
        }
        if let array = value as? [Any] {
            let children = array.enumerated().map { PlistNode.from(key: "[\($0.offset)]", value: $0.element) }
            return PlistNode(key: key, kind: .array, children: children)
        }
        if let num = value as? NSNumber {
            // NSNumber 可能是 Bool
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return PlistNode(key: key, kind: .scalar(num.boolValue))
            }
        }
        return PlistNode(key: key, kind: .scalar(value))
    }

    /// 转回 plist 值
    func toValue() -> Any {
        switch kind {
        case .dictionary:
            return Dictionary(uniqueKeysWithValues: children.map { ($0.key, $0.toValue()) })
        case .array:
            return children.map { $0.toValue() }
        case .scalar(let v):
            return v
        }
    }

    /// 修改标量值
    func updateScalar(_ newValue: Any) {
        // kind 是 let，用对象替换语义不行 —— 重建 kind
        // 简化：通过 setValue 存到新节点替换
    }
}

// MARK: - Plist 编辑器页面

/// Plist 树形编辑器（对齐 LCSign 的 PlistEditorModel/PlistNode）
///
/// 功能：树形浏览、编辑标量值（字符串/数字/布尔）、重命名字典键、
/// 添加/删除条目、保存（写回原文件，XML 格式）。
struct PlistEditorView: View {
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss

    @State private var rootNode: PlistNode?
    @State private var errorMessage: String?
    @State private var isModified = false
    @State private var saving = false

    /// 正在编辑的节点
    @State private var editingNode: PlistNode?
    @State private var editingText = ""
    @State private var editingBool = false
    @State private var editingKindIndex = 0
    private let editingKinds = ["string", "number", "bool"]

    var body: some View {
        NavigationStack {
            Group {
                if let rootNode {
                    List {
                        ForEach(rootNode.children) { child in
                            NodeRow(node: child, level: 0) { node in
                                beginEdit(node)
                            } onDelete: { node in
                                rootNode.children.removeAll { $0.id == node.id }
                                isModified = true
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                } else {
                    VStack(spacing: 12) {
                        if let errorMessage {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 44))
                                .foregroundStyle(.secondary)
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        } else {
                            ProgressView()
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(fileURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let root = rootNode, root.isContainer {
                        Menu {
                            Button("添加字符串") { addChild(value: "") }
                            Button("添加数字") { addChild(value: 0) }
                            Button("添加布尔") { addChild(value: false) }
                            Button("添加字典") { addChild(value: [:]) }
                            Button("添加数组") { addChild(value: []) }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                    Button {
                        save()
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            Text(isModified ? "保存" : "已保存")
                        }
                    }
                    .disabled(!isModified || saving || rootNode == nil)
                }
            }
            .sheet(item: $editingNode) { node in
                editSheet(node)
            }
            .onAppear { load() }
        }
    }

    // MARK: - 编辑弹窗

    @ViewBuilder
    private func editSheet(_ node: PlistNode) -> some View {
        NavigationStack {
            Form {
                Section("键名") {
                    TextField("键名", text: Binding(
                        get: { node.key },
                        set: { node.key = $0; isModified = true }
                    ))
                    .textInputAutocapitalization(.never)
                }

                switch node.kind {
                case .scalar:
                    Section("值类型") {
                        Picker("类型", selection: $editingKindIndex) {
                            ForEach(0..<editingKinds.count, id: \.self) { Text(editingKinds[$0]).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: editingKindIndex) { _ in isModified = true }
                    }
                    Section("值") {
                        if editingKinds[editingKindIndex] == "bool" {
                            Toggle("布尔值", isOn: $editingBool)
                                .onChange(of: editingBool) { _ in isModified = true }
                        } else {
                            TextField("值", text: $editingText)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                default:
                    Section {
                        Text("容器节点（dict/array）请通过子项操作")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        applyEdit(node)
                        editingNode = nil
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - 数据操作

    private func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            if let dict = plist as? [String: Any] {
                rootNode = PlistNode(key: fileURL.lastPathComponent, kind: .dictionary,
                                     children: dict.keys.sorted().map { PlistNode.from(key: $0, value: dict[$0]!) })
            } else if let array = plist as? [Any] {
                rootNode = PlistNode(key: fileURL.lastPathComponent, kind: .array,
                                     children: array.enumerated().map { PlistNode.from(key: "[\($0.offset)]", value: $0.element) })
            } else {
                errorMessage = "根节点不是字典或数组"
            }
        } catch {
            errorMessage = "无法解析 Plist: \(error.localizedDescription)"
        }
    }

    private func beginEdit(_ node: PlistNode) {
        guard case .scalar(let v) = node.kind else { return }
        editingNode = node
        if let b = v as? Bool {
            editingBool = b
            editingKindIndex = 2
            editingText = b ? "true" : "false"
        } else {
            editingText = "\(v)"
            editingKindIndex = v is String ? 0 : 1
        }
    }

    private func applyEdit(_ node: PlistNode) {
        switch node.kind {
        case .scalar:
            let newKind: PlistNode.Kind
            switch editingKinds[editingKindIndex] {
            case "bool": newKind = .scalar(editingBool)
            case "number":
                if let i = Int(editingText) { newKind = .scalar(i) }
                else if let d = Double(editingText) { newKind = .scalar(d) }
                else { newKind = .scalar(editingText) }
            default: newKind = .scalar(editingText)
            }
            replaceKind(of: node, with: newKind)
            isModified = true
        default: break
        }
    }

    /// 替换节点的标量类型（PlistNode.kind 为 let，通过查找父节点重建实现）
    private func replaceKind(of target: PlistNode, with newKind: PlistNode.Kind) {
        let newNode = PlistNode(key: target.key, kind: newKind, children: target.children)
        if let root = rootNode, replaceIn(parent: root, target: target, replacement: newNode) {
            refreshRoot()
        }
    }

    /// 递归查找并替换节点
    @discardableResult
    private func replaceIn(parent: PlistNode, target: PlistNode, replacement: PlistNode) -> Bool {
        if let idx = parent.children.firstIndex(where: { $0.id == target.id }) {
            parent.children[idx] = replacement
            return true
        }
        for child in parent.children where child.isContainer {
            if replaceIn(parent: child, target: target, replacement: replacement) { return true }
        }
        return false
    }

    /// 根节点重建后强制刷新树
    private func refreshRoot() {
        guard let root = rootNode else { return }
        rootNode = PlistNode(key: root.key, kind: root.kind,
                             children: root.children.map { clone($0) })
    }

    private func clone(_ node: PlistNode) -> PlistNode {
        PlistNode(key: node.key, kind: node.kind, children: node.children.map { clone($0) })
    }

    private func addChild(value: Any) {
        guard let root = rootNode else { return }
        let key: String
        if root.isDictionary {
            key = "new_key_\(root.children.count + 1)"
        } else {
            key = "[\(root.children.count)]"
        }
        root.children.append(PlistNode.from(key: key, value: value))
        isModified = true
    }

    private func save() {
        guard let rootNode else { return }
        saving = true
        Task {
            do {
                let value = rootNode.toValue()
                let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
                try data.write(to: fileURL)
                await MainActor.run {
                    saving = false
                    isModified = false
                }
            } catch {
                await MainActor.run {
                    saving = false
                    errorMessage = "保存失败: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - 节点行（递归展开）

/// Plist 节点行：容器可展开，标量可点击编辑
struct NodeRow: View {
    @ObservedObject var node: PlistNode
    let level: Int
    var onEdit: (PlistNode) -> Void
    var onDelete: (PlistNode) -> Void

    @State private var expanded = false

    var body: some View {
        Group {
            if node.isContainer {
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    rowLabel(isContainer: true)
                }
                .foregroundColor(.primary)

                if expanded {
                    ForEach(node.children) { child in
                        NodeRow(node: child, level: level + 1, onEdit: onEdit, onDelete: onDelete)
                    }
                    .padding(.leading, CGFloat(level + 1) * 4)
                }
            } else {
                Button {
                    onEdit(node)
                } label: {
                    rowLabel(isContainer: false)
                }
                .foregroundColor(.primary)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        onDelete(node)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowLabel(isContainer: Bool) -> some View {
        HStack(spacing: 8) {
            if isContainer {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(node.key)
                .font(.system(.subheadline, design: .monospaced, weight: .medium))
                .lineLimit(1)
            Text(node.kind.label)
                .font(.system(.caption2, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.blue.opacity(0.1)))
                .foregroundColor(.blue)
            Spacer()
            if !isContainer {
                Text(node.scalarDisplay)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
