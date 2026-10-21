import AppKit
import SwiftUI
import Security

struct RelayProfile: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    var name = "新中转接口"
    var upstream = ""
    var port = 8182
    var model = ""
    var overrideModel = false
    var mode = "generic"
    var auth = "preserve"
    var timeout = 300
    var sourceID: String? = nil

    var localURL: String { "http://127.0.0.1:\(port)" }
    var pythonConfig: [String: Any] {
        ["id": id, "upstream": upstream, "port": port, "model": model,
         "overrideModel": overrideModel, "mode": mode, "auth": auth, "timeout": timeout]
    }
}

enum Vault {
    static let service = "local.relaybridge.credentials"
    static func read(_ id: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ key: String, id: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id]
        if key.isEmpty { SecItemDelete(query as CFDictionary); return }
        let update: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw BridgeFailure.message("保存钥匙串失败（\(status)）。")
        }
    }
}

enum BridgeFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

@MainActor
final class BridgeStore: ObservableObject {
    @Published var profiles: [RelayProfile] = []
    @Published var selectedID: String?
    @Published var active: Set<String> = []
    @Published var pending: Set<String> = []
    @Published var testing: Set<String> = []
    @Published var notes: [String: String] = [:]
    @Published var notice = ""
    @Published var importing = false
    @Published var keychainEnabled: Bool {
        didSet { UserDefaults.standard.set(keychainEnabled, forKey: "relaybridge.keychainEnabled") }
    }

    private var processes: [String: Process] = [:]
    private var outputs: [String: FileHandle] = [:]
    private var timer: Timer?
    let dataDirectory: URL
    let resourceDirectory: URL
    let python: String
    let session: URLSession

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dataDirectory = root.appendingPathComponent("RelayBridge", isDirectory: true)
        resourceDirectory = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        python = ["/opt/anaconda3/bin/python", "/opt/homebrew/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.connectionProxyDictionary = [:]
        sessionConfig.timeoutIntervalForRequest = 310
        sessionConfig.timeoutIntervalForResource = 320
        session = URLSession(configuration: sessionConfig)
        keychainEnabled = UserDefaults.standard.bool(forKey: "relaybridge.keychainEnabled")
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)
            let file = dataDirectory.appendingPathComponent("profiles.json")
            if FileManager.default.fileExists(atPath: file.path) {
                profiles = try JSONDecoder().decode([RelayProfile].self, from: Data(contentsOf: file))
            } else {
                profiles = [RelayProfile(name: "本地中转", upstream: "",
                    port: 8182, model: "", mode: "generic", auth: "preserve")]
                try persist()
            }
            selectedID = profiles.first?.id
        } catch { notice = "读取配置失败：\(error.localizedDescription)" }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshProcesses() }
        }
    }

    func persist() throws {
        let data = try JSONEncoder().encode(profiles)
        let file = dataDirectory.appendingPathComponent("profiles.json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func profile(_ id: String) -> RelayProfile? { profiles.first { $0.id == id } }

    func nextPort() -> Int {
        var port = 8182
        while profiles.contains(where: { $0.port == port }) { port += 1 }
        return port
    }

    func add() {
        let item = RelayProfile(port: nextPort())
        profiles.append(item)
        selectedID = item.id
        do { try persist() } catch { notice = error.localizedDescription }
    }

    func validate(_ draft: RelayProfile) throws {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw BridgeFailure.message("请填写接口名称。")
        }
        guard let parts = URLComponents(string: draft.upstream),
              ["https", "http"].contains(parts.scheme ?? ""), parts.host != nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw BridgeFailure.message("填写 http(s) 接口基础地址，不能包含密码或查询参数。")
        }
        guard !parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("messages") else {
            throw BridgeFailure.message("填写接口基础地址，不要追加 /v1/messages。")
        }
        guard (1024...65535).contains(draft.port) else { throw BridgeFailure.message("端口必须为 1024–65535。") }
        guard (5...600).contains(draft.timeout) else { throw BridgeFailure.message("请求超时必须为 5–600 秒。") }
        guard !profiles.contains(where: { $0.id != draft.id && $0.port == draft.port }) else {
            throw BridgeFailure.message("端口已分配给另一个接口，请更换。")
        }
        guard !draft.overrideModel || !draft.model.isEmpty else {
            throw BridgeFailure.message("覆盖客户端模型时需要填写模型名称。")
        }
        guard !(["127.0.0.1", "localhost", "::1"].contains(parts.host ?? "") && parts.port == draft.port) else {
            throw BridgeFailure.message("上游不能指向代理自身。")
        }
    }

    @discardableResult
    func save(_ draft: RelayProfile, key: String, updateKey: Bool = true) -> Bool {
        do {
            var item = draft
            item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            item.upstream = item.upstream.trimmingCharacters(in: .whitespacesAndNewlines)
            item.model = item.model.trimmingCharacters(in: .whitespacesAndNewlines)
            try validate(item)
            guard !active.contains(item.id), !pending.contains(item.id) else {
                throw BridgeFailure.message("请先停止该接口，再保存修改。")
            }
            if updateKey && keychainEnabled {
                try Vault.write(key.trimmingCharacters(in: .whitespacesAndNewlines), id: item.id)
            }
            if let index = profiles.firstIndex(where: { $0.id == item.id }) { profiles[index] = item }
            try persist()
            notes[item.id] = "已保存。密钥由客户端转发，或使用钥匙串中的备用密钥。"
            return true
        } catch { notes[draft.id] = error.localizedDescription; return false }
    }

    func remove(_ id: String) {
        guard !testing.contains(id) else { return }
        stop(id)
        profiles.removeAll { $0.id == id }
        if keychainEnabled { try? Vault.write("", id: id) }
        selectedID = profiles.first?.id
        do { try persist() } catch { notice = error.localizedDescription }
    }

    func refreshProcesses() {
        for (id, process) in processes where !process.isRunning {
            processes[id] = nil
            try? outputs.removeValue(forKey: id)?.close()
            active.remove(id)
            pending.remove(id)
            notes[id] = "服务已退出（\(process.terminationStatus)）。请检查端口占用或接口设置。"
        }
    }

    func start(_ id: String) async {
        guard let item = profile(id), processes[id] == nil else { return }
        pending.insert(id)
        defer { pending.remove(id) }
        do {
            try validate(item)
            let backend = resourceDirectory.appendingPathComponent("bridge.py")
            guard FileManager.default.fileExists(atPath: backend.path) else {
                throw BridgeFailure.message("应用缺少 bridge.py，请使用完整的 .app 文件。")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-u", backend.path]
            // Pipes carry the credential once; neither argv nor disk holds it.
            let input = Pipe()
            process.standardInput = input
            let logs = dataDirectory.appendingPathComponent("logs", isDirectory: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let logfile = logs.appendingPathComponent(item.id + ".log")
            FileManager.default.createFile(atPath: logfile.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: logfile)
            process.standardOutput = output
            process.standardError = output
            process.currentDirectoryURL = dataDirectory
            try process.run()
            processes[id] = process
            outputs[id] = output
            var config = item.pythonConfig
            config["apiKey"] = keychainEnabled ? Vault.read(id) : ""
            var bytes = try JSONSerialization.data(withJSONObject: config)
            bytes.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: bytes)
            try input.fileHandleForWriting.close()
            var ready = false
            for _ in 0..<30 {
                guard processes[id] === process, process.isRunning else { break }
                var request = URLRequest(url: URL(string: item.localURL + "/health")!)
                request.timeoutInterval = 0.3
                if let (data, _) = try? await session.data(for: request),
                   let health = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   health["profileID"] as? String == id,
                   health["pid"] as? Int == Int(process.processIdentifier) { ready = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard processes[id] === process else { return }
            guard ready else {
                stop(id)
                throw BridgeFailure.message("启动失败，可能端口 \(item.port) 已被占用。")
            }
            active.insert(id)
            notes[id] = "已启动，可在 CC Switch 中填写 \(item.localURL)"
        } catch { notes[id] = error.localizedDescription }
    }

    func stop(_ id: String) {
        if let process = processes.removeValue(forKey: id), process.isRunning { process.terminate() }
        try? outputs.removeValue(forKey: id)?.close()
        active.remove(id)
        pending.remove(id)
        notes[id] = "已停止。"
    }

    func stopAll() { for id in Array(processes.keys) { stop(id) } }

    func shutdown() {
        stopAll()
        timer?.invalidate()
        timer = nil
    }

    func test(_ id: String) async {
        guard let item = profile(id), !testing.contains(id) else { return }
        guard keychainEnabled else {
            notes[id] = "钥匙串读取已关闭；请在客户端测试正文。"; return
        }
        guard !item.model.isEmpty else { notes[id] = "先填写测试 / 展示模型并保存。"; return }
        guard !Vault.read(id).isEmpty else {
            notes[id] = "内置测试需要钥匙串密钥。也可不保存密钥，直接在客户端测试。"; return
        }
        if !active.contains(id) { await start(id) }
        guard active.contains(id) else { return }
        testing.insert(id)
        notes[id] = "正在测试正文输出；会发起一次实际 API 请求。"
        defer { testing.remove(id) }
        let start = Date()
        do {
            var request = URLRequest(url: URL(string: item.localURL + "/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": item.model, "max_tokens": 256, "stream": true,
                "messages": [["role": "user", "content": "Reply with exactly OK."]]])
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw BridgeFailure.message("没有收到 HTTP 响应。") }
            guard http.statusCode == 200 else {
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let error = object?["error"] as? [String: Any]
                throw BridgeFailure.message(error?["message"] as? String ?? "HTTP \(http.statusCode)")
            }
            var visible = ""
            var stopped = false
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data: ") {
                let bytes = Data(line.dropFirst(6).utf8)
                guard let event = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { continue }
                if event["type"] as? String == "message_stop" { stopped = true }
                if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta" {
                    visible += delta["text"] as? String ?? ""
                }
            }
            guard stopped, !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BridgeFailure.message("回复缺少完整正文事件。")
            }
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
            notes[id] = "正文测试通过 · \(elapsed) 秒\n\(visible.prefix(180))\n此测试不代表全部工具或完整 Cowork 流程已验证。"
        } catch { notes[id] = "测试失败：\(error.localizedDescription)" }
    }

    func copyAddress(_ id: String) {
        guard let item = profile(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.localURL, forType: .string)
        notes[id] = "已复制 \(item.localURL)"
    }

    func importProviders() async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [resourceDirectory.appendingPathComponent("bridge.py").path, "--import-ccswitch"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            var done = false
            for _ in 0..<100 {
                if !process.isRunning { done = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard done else { process.terminate(); throw BridgeFailure.message("读取 CC Switch 超时。") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0,
                  let rows = (try JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                throw BridgeFailure.message("未读到可导入的 Anthropic 供应商。")
            }
            var count = 0
            for row in rows {
                guard let source = row["sourceID"] as? String,
                      !profiles.contains(where: { $0.sourceID == source }) else { continue }
                let upstream = row["upstream"] as? String ?? ""
                let item = RelayProfile(name: row["name"] as? String ?? "中转接口", upstream: upstream,
                    port: nextPort(), model: row["model"] as? String ?? "",
                    mode: "generic", auth: "bearer", sourceID: source)
                try validate(item)
                if keychainEnabled {
                    try Vault.write(row["apiKey"] as? String ?? "", id: item.id)
                }
                profiles.append(item)
                if count == 0 { selectedID = item.id }
                count += 1
            }
            try persist()
            notice = keychainEnabled
                ? "已导入 \(count) 个接口。原 CC Switch 配置未改动，密钥已放入本机钥匙串。"
                : "已导入 \(count) 个接口。原 CC Switch 配置未改动；钥匙串读取已关闭，请使用客户端密钥。"
        } catch { notice = error.localizedDescription }
    }

}

struct ProfileEditor: View {
    @ObservedObject var store: BridgeStore
    @State var draft: RelayProfile
    @State private var key = ""
    @State private var keyEdited = false
    @State private var showDelete = false

    var running: Bool { store.active.contains(draft.id) }
    var starting: Bool { store.pending.contains(draft.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(draft.name).font(.largeTitle.weight(.semibold))
                        Text("完整回复转成客户端可识别的流式输出").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(running ? "运行中" : starting ? "启动中" : "已停止",
                          systemImage: running ? "circle.fill" : "circle")
                        .font(.caption.weight(.medium)).foregroundStyle(running ? .green : .secondary)
                }

                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("客户端连接地址").font(.caption).foregroundStyle(.secondary)
                            Text(draft.localURL).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                        }
                        Spacer()
                        Button("复制地址", systemImage: "doc.on.doc") { store.copyAddress(draft.id) }
                    }.padding(8)
                }

                Form {
                    TextField("接口名称", text: $draft.name)
                    TextField("上游基础地址", text: $draft.upstream).textContentType(.URL)
                    HStack {
                        Text("本地端口")
                        Spacer()
                        TextField("端口", value: $draft.port, format: .number.grouping(.never))
                            .labelsHidden().frame(width: 100)
                    }
                    TextField("测试 / 展示模型", text: $draft.model)
                    Toggle("覆盖客户端请求的模型名称", isOn: $draft.overrideModel)
                    Picker("兼容模式", selection: $draft.mode) {
                        Text("通用：只修复流式输出").tag("generic")
                        Text("justwoker：包含工具兼容").tag("justwoker")
                    }
                    Picker("上游认证", selection: $draft.auth) {
                        Text("沿用客户端认证方式").tag("preserve")
                        Text("Bearer Token").tag("bearer")
                        Text("x-api-key").tag("x-api-key")
                    }
                    Toggle("读取钥匙串备用密钥", isOn: $store.keychainEnabled)
                    if store.keychainEnabled {
                        SecureField("备用 API Key（可选）", text: Binding(
                            get: { key },
                            set: { key = $0; keyEdited = true }
                        ))
                    }
                    HStack {
                        Text("请求超时（秒）")
                        Spacer()
                        TextField("秒", value: $draft.timeout, format: .number.grouping(.never))
                            .labelsHidden().frame(width: 100)
                    }
                }
                .formStyle(.grouped)
                .disabled(running || starting)

                VStack(alignment: .leading, spacing: 7) {
                    Label(store.keychainEnabled
                          ? "密钥仅保存在本机钥匙串，也可以留空由客户端发送。"
                          : "钥匙串读取已关闭；使用客户端发送的密钥。",
                          systemImage: "key")
                    if store.keychainEnabled {
                        Text("已保存的备用密钥不会显示；留空保存会保留钥匙串中的原值。")
                        Text("首次读取旧 RelayBridge 密钥时，macOS 可能询问一次；选择「始终允许」即可。")
                    } else {
                        Text("默认不读取钥匙串，不会弹出钥匙串权限；启动代理时只转发客户端密钥。")
                    }
                    Text(draft.mode == "justwoker"
                         ? "工具兼容仅适用于 justwoker 类接口，会调整工具定义与 token 统计。"
                         : "保留模型、工具定义、思考签名与 token 统计；仅把上游请求改为非流式。")
                    Text("先等待完整回复，再显示正文。每个接口独立运行；关闭窗口后仍可从菜单栏管理。")
                }.font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("保存设置") {
                        store.save(draft, key: key, updateKey: keyEdited)
                    }.disabled(running || starting)
                    Button(running ? "停止代理" : "启动代理") {
                        if running { store.stop(draft.id) }
                        else if store.save(draft, key: key, updateKey: keyEdited) {
                            Task { await store.start(draft.id) }
                        }
                    }.buttonStyle(.borderedProminent).disabled(starting)
                        .accessibilityLabel(running ? "停止代理" : "启动代理")
                        .accessibilityIdentifier("toggleProxy")
                    Button("测试正文") {
                        if running || store.save(draft, key: key, updateKey: keyEdited) {
                            Task { await store.test(draft.id) }
                        }
                    }
                        .disabled(starting || store.testing.contains(draft.id) || !store.keychainEnabled)
                        .help(store.keychainEnabled ? "" : "钥匙串读取已关闭；请在客户端测试")
                    if store.testing.contains(draft.id) || starting { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(role: .destructive) { showDelete = true } label: { Image(systemName: "trash") }
                        .disabled(starting || store.testing.contains(draft.id))
                }

                if let note = store.notes[draft.id] {
                    Text(note).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                }
                GroupBox("连接 Claude Desktop") {
                    Text("CC Switch → Claude Desktop → 新增供应商 → 地址填写上面的本地地址，使用原中转密钥。关闭“需要模型映射”，手动添加模型，然后启用并完全重启 Desktop。")
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }.padding(28)
        }
        .alert("删除此接口？", isPresented: $showDelete) {
            Button("删除", role: .destructive) { store.remove(draft.id) }
            Button("取消", role: .cancel) {}
        } message: { Text("将停止该代理并删除本工具中保存的设置和密钥。") }
    }
}

struct MainView: View {
    @ObservedObject var store: BridgeStore

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $store.selectedID) {
                    ForEach(store.profiles) { item in
                        HStack(spacing: 10) {
                            Image(systemName: store.active.contains(item.id) ? "network" : "server.rack")
                                .foregroundStyle(store.active.contains(item.id) ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.body.weight(.medium))
                                Text("127.0.0.1:\(item.port)").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5).tag(item.id)
                    }
                }
                VStack(spacing: 9) {
                    Button("添加中转接口", systemImage: "plus") { store.add() }.frame(maxWidth: .infinity)
                        .accessibilityLabel("添加中转接口").accessibilityIdentifier("addProfile")
                    Button("从 CC Switch 导入") { Task { await store.importProviders() } }
                        .disabled(store.importing).frame(maxWidth: .infinity)
                    Button("打开设置文件夹", systemImage: "folder") {
                        NSWorkspace.shared.open(store.dataDirectory)
                    }.frame(maxWidth: .infinity)
                    Text("\(store.active.count) 个接口正在运行").font(.caption).foregroundStyle(.secondary)
                }.padding(14)
            }.navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            if let id = store.selectedID, let profile = store.profile(id) {
                ProfileEditor(store: store, draft: profile).id(id)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "network").font(.system(size: 42)).foregroundStyle(.secondary)
                    Text("添加一个中转接口").font(.title2)
                    Button("添加接口") { store.add() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 890, minHeight: 780)
        .alert("RelayBridge", isPresented: Binding(get: { !store.notice.isEmpty }, set: { if !$0 { store.notice = "" } })) {
            Button("好") { store.notice = "" }
        } message: { Text(store.notice) }
    }
}

@MainActor
final class RelayBridgeWindowController: NSObject, NSWindowDelegate {
    let store: BridgeStore
    private var window: NSWindow?

    override init() {
        self.store = BridgeStore()
        super.init()
    }

    var profileCount: Int { store.profiles.count }
    var activeCount: Int { store.active.count }

    func show() {
        let window = ensureWindow()
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func stopAll() { store.stopAll() }

    func shutdown() { store.shutdown() }

    func toggle(_ id: String) {
        if store.active.contains(id) {
            store.stop(id)
        } else {
            Task { await store.start(id) }
        }
    }

    func smokeReport() -> [String: Any] {
        let window = ensureWindow()
        let backend = store.resourceDirectory.appendingPathComponent("bridge.py")
        return ["relayWindowConstructed": true,
                "relayProfileCount": store.profiles.count,
                "relayActiveCount": store.active.count,
                "relayBackendBundled": FileManager.default.fileExists(atPath: backend.path),
                "relayPythonFound": FileManager.default.isExecutableFile(atPath: store.python),
                "relayWindowContentSize": "\(Int(window.contentLayoutRect.width))x\(Int(window.contentLayoutRect.height))"]
    }

    private func ensureWindow() -> NSWindow {
        if let window = window { return window }
        let hosting = NSHostingController(rootView: MainView(store: store))
        let window = NSWindow(contentViewController: hosting)
        window.title = "MacToolbox 中转接口"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 890, height: 780)
        window.setContentSize(NSSize(width: 980, height: 840))
        self.window = window
        return window
    }
}
