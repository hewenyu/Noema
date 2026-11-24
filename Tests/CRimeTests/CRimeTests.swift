import CRime
import Foundation
import NoemaEngine
import Testing

/// Real, headless librime: no mocks. librime is a process-global singleton
/// (setup/initialize/finalize, one deployer), so every test that touches it lives
/// in this serialized suite.
@Suite(.serialized)
struct CRimeTests {
    @Test func apiTableIsAvailable() throws {
        let api = try #require(noema_rime_get_api())
        #expect(noema_rime_api_available() == 1)
        #expect(RimeRuntime.isAvailable)
        let version = String(cString: try #require(api.pointee.get_version?()))
        #expect(version == "1.17.0")
        #expect(try RimeRuntime.version() == version)
    }

    /// Many tasks query the runtime at once (on a cold process this includes the
    /// first rime_get_api() call, which noema_rime_get_api() serializes); every
    /// task must see the same table and the same answers.
    @Test func concurrentQueriesAgree() async throws {
        let expected = try RimeRuntime.info()
        let tableAddress = Int(bitPattern: try #require(noema_rime_get_api()))
        let results = await withTaskGroup(of: (Bool, RimeRuntimeInfo?, Int?).self) { group in
            for _ in 0..<64 {
                group.addTask {
                    (RimeRuntime.isAvailable, try? RimeRuntime.info(), noema_rime_get_api().map { Int(bitPattern: $0) })
                }
            }
            var results: [(Bool, RimeRuntimeInfo?, Int?)] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(results.count == 64)
        for (available, info, address) in results {
            #expect(available)
            #expect(info == expected)
            #expect(address == tableAddress)
        }
        #expect(expected.version == "1.17.0")
        #expect(expected.allModulesRegistered)
    }

    /// The struct initializers ignore NULL instead of crashing.
    @Test func structInitializersIgnoreNull() {
        noema_rime_traits_init(nil)
        noema_rime_context_init(nil)
        noema_rime_status_init(nil)
        noema_rime_commit_init(nil)
        var status = RimeStatus()
        noema_rime_status_init(&status)
        #expect(status.data_size == Int32(MemoryLayout<RimeStatus>.stride - MemoryLayout<Int32>.size))
    }

    @Test(arguments: ["core", "dict", "gears", "levers", "deployer", "lua", "octagram", "grammar"])
    func mergedModuleIsRegistered(_ name: String) throws {
        let findModule = try #require(noema_rime_get_api()?.pointee.find_module)
        #expect(findModule(name) != nil, "module \(name) is not registered in librime.1.dylib")
        #expect(try RimeRuntime.hasModule(name))
    }

    @Test func unknownModuleIsNotRegistered() throws {
        let findModule = try #require(noema_rime_get_api()?.pointee.find_module)
        #expect(findModule("noema_nonexistent_module") == nil)
        #expect(try !RimeRuntime.hasModule("noema_nonexistent_module"))
        #expect(try RimeRuntime.info().allModulesRegistered)
    }

    /// Deploys a tiny inline schema (one table translator over a two-entry dictionary
    /// plus a one-line Lua translator) into a fresh temporary user_data_dir, then
    /// types through a real session and checks what gets committed.
    @Test func deploysSchemaAndCommitsLuaAndTableCandidates() throws {
        let workspace = try RimeWorkspace()
        defer { workspace.remove() }
        let api = try #require(noema_rime_get_api()).pointee

        var traits = RimeTraits()
        noema_rime_traits_init(&traits)
        let strings = CStrings()
        defer { strings.free() }
        traits.shared_data_dir = strings.make(workspace.shared.path)
        traits.user_data_dir = strings.make(workspace.user.path)
        traits.distribution_name = strings.make("Noema")
        traits.distribution_code_name = strings.make("noema-tests")
        traits.distribution_version = strings.make("0.1.0")
        traits.app_name = strings.make("rime.noema-tests")
        traits.min_log_level = 2
        traits.log_dir = strings.make(workspace.logs.path)

        try #require(api.setup != nil && api.deployer_initialize != nil && api.initialize != nil)
        api.setup(&traits)
        api.deployer_initialize(&traits)
        #expect(api.deploy() != 0, "RimeDeployWorkspace failed")
        let compiled = workspace.user.appending(path: "build/noema_test.table.bin")
        #expect(FileManager.default.fileExists(atPath: compiled.path), "dictionary was not compiled")

        api.initialize(&traits)
        defer { api.finalize() }

        let session = api.create_session()
        try #require(session != 0)
        defer { _ = api.destroy_session(session) }
        #expect(api.select_schema(session, "noema_test") != 0)

        // Lua translator: "hello" -> noema_lua_ok, committed by selecting it.
        try type("hello", into: session, api: api)
        let luaCandidates = try candidates(in: session, api: api)
        let luaIndex = try #require(luaCandidates.firstIndex(of: "noema_lua_ok"), "candidates: \(luaCandidates)")
        #expect(api.select_candidate_on_current_page(session, luaIndex) != 0)
        #expect(try commit(from: session, api: api) == "noema_lua_ok")

        // Table translator: "nihao" -> 你好 as the first candidate, committed with space.
        try type("nihao", into: session, api: api)
        #expect(try candidates(in: session, api: api).first == "你好")
        #expect(api.process_key(session, 0x20, 0) != 0)
        #expect(try commit(from: session, api: api) == "你好")

        // Input no translator knows yields no candidates.
        try type("qqq", into: session, api: api)
        #expect(try candidates(in: session, api: api).isEmpty)
        api.clear_composition(session)
    }
}

// MARK: - Helpers

private func type(_ text: String, into session: RimeSessionId, api: RimeApi) throws {
    for byte in text.utf8 {
        // X11 keysyms for printable ASCII equal the ASCII code.
        try #require(api.process_key(session, Int32(byte), 0) != 0, "key \(byte) not handled")
    }
}

private func candidates(in session: RimeSessionId, api: RimeApi) throws -> [String] {
    var context = RimeContext()
    noema_rime_context_init(&context)
    try #require(api.get_context(session, &context) != 0)
    defer { _ = api.free_context(&context) }
    let count = Int(context.menu.num_candidates)
    guard count > 0, let items = context.menu.candidates else { return [] }
    return (0..<count).compactMap { items[$0].text.map { String(cString: $0) } }
}

private func commit(from session: RimeSessionId, api: RimeApi) throws -> String? {
    var commit = RimeCommit()
    noema_rime_commit_init(&commit)
    guard api.get_commit(session, &commit) != 0 else { return nil }
    defer { _ = api.free_commit(&commit) }
    return commit.text.map { String(cString: $0) }
}

/// C strings that must outlive the librime calls that borrow them.
private final class CStrings {
    private var pointers: [UnsafeMutablePointer<CChar>] = []

    func make(_ string: String) -> UnsafePointer<CChar> {
        let pointer = strdup(string)!
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }

    func free() {
        pointers.forEach { Foundation.free($0) }
        pointers.removeAll()
    }

    deinit { free() }
}

/// A throwaway shared/user data directory pair holding the inline test schema.
private struct RimeWorkspace {
    let root: URL
    var shared: URL { root.appending(path: "shared") }
    var user: URL { root.appending(path: "user") }
    var logs: URL { root.appending(path: "log") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "noema-crime-tests-\(UUID().uuidString)")
        for directory in [shared, user, logs, shared.appending(path: "lua")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write("default.yaml", """
            schema_list:
              - schema: noema_test
            menu:
              page_size: 5
            """)
        try write("noema_test.schema.yaml", """
            schema:
              schema_id: noema_test
              name: Noema Test
              version: "1"
            engine:
              processors:
                - speller
                - selector
                - express_editor
              segmentors:
                - abc_segmentor
                - fallback_segmentor
              translators:
                - table_translator
                - lua_translator@*noema_hello
            speller:
              alphabet: abcdefghijklmnopqrstuvwxyz
            translator:
              dictionary: noema_test
              enable_user_dict: false
            """)
        try write("noema_test.dict.yaml", """
            ---
            name: noema_test
            version: "1"
            sort: original
            ...
            你好\tnihao
            世界\tshijie

            """)
        try write("lua/noema_hello.lua", """
            return function(input, seg) if input == "hello" then yield(Candidate("lua", seg.start, seg._end, "noema_lua_ok", "")) end end

            """)
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: shared.appending(path: name), atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
