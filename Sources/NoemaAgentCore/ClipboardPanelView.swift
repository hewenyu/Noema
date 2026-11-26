import AppKit
import NoemaClipboardCore
import SwiftUI

/// The Raycast-style clipboard panel: search and filter on top, the date-grouped list on
/// the left (~40%), the preview and inspector on the right, the action bar at the bottom.
/// Keys: ↑/↓ move, ↵ pastes, Esc closes, ⌘K opens the actions.
struct ClipboardPanelView: View {
    @Bindable var model: ClipboardPanelModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            statusPills
            Divider()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ClipboardListPane(model: model)
                        .frame(width: geometry.size.width * 0.4)
                    Divider()
                    ClipboardDetailPane(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            bottomBar
        }
        .overlay(alignment: .bottomTrailing) {
            if model.showsActions { ClipboardActionsMenu(model: model).padding(.trailing, 12).padding(.bottom, 48) }
        }
        .onKeyPress(.upArrow) {
            model.moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.moveSelection(1)
            return .handled
        }
        .onKeyPress(.escape) {
            if model.showsActions { model.showsActions = false } else { model.close() }
            return .handled
        }
        .onChange(of: model.query) { model.reload() }
        .onChange(of: model.filter) { model.reload() }
        .onChange(of: model.openGeneration, initial: true) { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索剪贴板历史", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit { model.performPrimary() }
                // On the field itself: its editor would otherwise take ↑/↓ as caret moves.
                .onKeyPress(.upArrow) {
                    model.moveSelection(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.moveSelection(1)
                    return .handled
                }
            Picker("筛选", selection: $model.filter) {
                ForEach(ClipboardFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 250)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusPills: some View {
        let pills = statusMessages
        if !pills.isEmpty {
            HStack(spacing: 8) {
                ForEach(pills, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.18), in: Capsule())
                }
                Spacer()
                if !model.isAccessibilityTrusted {
                    Button("打开辅助功能设置…") { model.openAccessibilitySettings() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var statusMessages: [String] {
        var messages: [String] = []
        if model.storeError != nil {
            messages.append("历史存储不可用")
        } else if model.storeState == .keychainLocked {
            messages.append("钥匙串已锁定，暂停记录")
        }
        if model.accessStatus != .alwaysAllow { messages.append("剪贴板访问：\(model.accessStatus.title)") }
        if !model.isAccessibilityTrusted { messages.append("未授权辅助功能：只复制，不自动粘贴") }
        return messages
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.caption)
            Text("\(model.items.count) 条 · AES-GCM 加密").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                model.performPrimary()
            } label: {
                Text("\(model.primaryActionTitle) ↵")
            }
            .disabled(model.selected == nil)
            Button {
                model.showsActions.toggle()
            } label: {
                Text("操作 ⌘K")
            }
            .keyboardShortcut("k", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// The ⌘K actions, drawn inside the panel (no extra window, so the panel stays key).
struct ClipboardActionsMenu: View {
    @Bindable var model: ClipboardPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            action("粘贴", "doc.on.clipboard") { model.performPrimary() }
            action("仅复制", "doc.on.doc") { model.copyOnly() }
            action(model.selected?.isPinned == true ? "取消固定" : "固定", "pin") { model.togglePin() }
            action("删除", "trash") { model.deleteSelected() }
            Divider()
            action("清空未固定历史", "clear") { model.clearUnpinned() }
            action("打开辅助功能设置…", "accessibility") { model.openAccessibilitySettings() }
        }
        .padding(6)
        .frame(width: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
    }

    private func action(_ title: String, _ symbol: String, _ perform: @escaping () -> Void) -> some View {
        Button {
            model.showsActions = false
            perform()
        } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

struct ClipboardListPane: View {
    @Bindable var model: ClipboardPanelModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    if model.items.isEmpty {
                        Text(model.query.isEmpty ? "暂无记录" : "没有匹配的记录")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(model.sections(), id: \.0) { section, items in
                        Section {
                            ForEach(items) { item in
                                ClipboardRow(model: model, item: item, isSelected: item.id == model.selected?.id)
                                    .id(item.id)
                                    .onTapGesture(count: 2) {
                                        model.selectedID = item.id
                                        model.performPrimary()
                                    }
                                    .onTapGesture { model.selectedID = item.id }
                            }
                        } header: {
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .onChange(of: model.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }
}

struct ClipboardRow: View {
    let model: ClipboardPanelModel
    let item: ClipboardEntryMetadata
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            leading.frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 4) {
                    if item.isPinned { Image(systemName: "pin.fill") }
                    Text(item.source.name ?? "未知来源")
                    Text("·")
                    Text(item.lastUsedAt, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leading: some View {
        if item.kind == .image, let image = model.thumbnail(for: item) {
            Image(nsImage: image).resizable().scaledToFill().frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            Image(systemName: item.kind == .image ? "photo" : model.isMasked(item) ? "lock.doc" : "doc.text")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch item.kind {
        case .image: "图片 \(item.imageWidth ?? 0)×\(item.imageHeight ?? 0)"
        case .text: model.isMasked(item) ? "••••••••（敏感内容已隐藏）" : (item.preview ?? "（无法解密）")
        }
    }
}

struct ClipboardDetailPane: View {
    @Bindable var model: ClipboardPanelModel
    /// Characters shown in the preview; the full text is still pasted.
    static let previewCharacterLimit = 100_000

    var body: some View {
        if let item = model.selected {
            VStack(spacing: 0) {
                preview(item).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inspector(item).padding(12)
            }
        } else {
            ContentUnavailableView("没有选中的记录", systemImage: "clipboard")
        }
    }

    @ViewBuilder
    private func preview(_ item: ClipboardEntryMetadata) -> some View {
        switch item.kind {
        case .text:
            if model.isMasked(item) {
                VStack(spacing: 12) {
                    Image(systemName: "eye.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text("疑似密钥或令牌，内容已隐藏").foregroundStyle(.secondary)
                    Button("显示内容") { model.toggleReveal(item) }
                }
            } else if case .text(let text)? = model.content(for: item) {
                ScrollView {
                    Text(String(text.prefix(Self.previewCharacterLimit)))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .overlay(alignment: .topTrailing) {
                    if item.sensitivity == .sensitive {
                        Button("隐藏") { model.toggleReveal(item) }.padding(8)
                    }
                }
            } else {
                Text("无法解密这条记录").foregroundStyle(.secondary)
            }
        case .image:
            if let image = model.image(for: item) {
                Image(nsImage: image).resizable().scaledToFit().padding(12)
            } else {
                Text("无法解密这张图片").foregroundStyle(.secondary)
            }
        }
    }

    private func inspector(_ item: ClipboardEntryMetadata) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("来源 App", item.source.name ?? item.source.bundleID ?? "未知")
            row("类型", item.kind == .image ? "图片（PNG）" : item.sensitivity == .sensitive ? "文本（敏感）" : "文本")
            if item.kind == .image {
                row("尺寸", "\(item.imageWidth ?? 0) × \(item.imageHeight ?? 0)")
            } else {
                row("字数", "\(item.charCount) 字 · \(item.lineCount) 行")
            }
            row("大小", ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file))
            row("时间", item.lastUsedAt.formatted(date: .abbreviated, time: .shortened))
            row("加密", "AES-256-GCM（密钥 v\(item.keyVersion)，存于钥匙串）")
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
    }
}
