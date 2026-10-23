import XCTest
@testable import StatusWatchr

final class PublicHookIsolationTests: XCTestCase {
    func testPublicInstallAndRemovalPreservePrivateHandlers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hooks.json")
        let privateCommand = CodexHookInstaller.command.replacingOccurrences(of: "48732", with: "48731")
        let groups: [[String: Any]] = [["hooks": [["type": "command", "command": privateCommand]]]]
        let hooks = Dictionary(uniqueKeysWithValues: CodexHookInstaller.eventNames.map { ($0, groups) })
        let original = try JSONSerialization.data(withJSONObject: ["hooks": hooks, "unrelated": "preserved"])
        try original.write(to: url)

        XCTAssertEqual(CodexHookServer.port, 48732)
        XCTAssertFalse(CodexHookInstaller.isInstalled(at: url))
        try CodexHookInstaller.install(at: url)
        try CodexHookInstaller.install(at: url)
        XCTAssertTrue(CodexHookInstaller.isInstalled(at: url))
        let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let installedHooks = installed["hooks"] as! [String: [[String: Any]]]
        for event in CodexHookInstaller.eventNames {
            let commands = installedHooks[event]!.flatMap { $0["hooks"] as! [[String: Any]] }.compactMap { $0["command"] as? String }
            XCTAssertEqual(commands.filter { $0 == privateCommand }.count, 1)
            XCTAssertEqual(commands.filter { $0 == CodexHookInstaller.command }.count, 1)
        }
        try CodexHookInstaller.remove(at: url)
        XCTAssertFalse(CodexHookInstaller.isInstalled(at: url))
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! NSDictionary
        let expected = try JSONSerialization.jsonObject(with: original) as! NSDictionary
        XCTAssertEqual(restored, expected)
    }
}
