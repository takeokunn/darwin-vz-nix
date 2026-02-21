import ArgumentParser
@testable import DarwinVZNixLib
import Foundation
import Testing

@Suite("StatusCommand", .tags(.unit))
struct StatusCommandTests {
    @Test("VMStatusOutput JSON encode/decode roundtrip for running VM")
    func jsonRoundtripRunning() throws {
        let original = VMStatusOutput(running: true, pid: 1234, stateDirectory: "/tmp/test")
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VMStatusOutput.self, from: data)
        #expect(decoded.running == true)
        #expect(decoded.pid == 1234)
        #expect(decoded.stateDirectory == "/tmp/test")
    }

    @Test("VMStatusOutput JSON encode/decode roundtrip for stopped VM")
    func jsonRoundtripStopped() throws {
        let original = VMStatusOutput(running: false, pid: nil, stateDirectory: "/tmp/test")
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VMStatusOutput.self, from: data)
        #expect(decoded.running == false)
        #expect(decoded.pid == nil)
    }

    @Test("VMStatusOutput JSON encode/decode for running VM with specific stateDirectory")
    func jsonRunningWithStateDirectory() throws {
        let original = VMStatusOutput(running: true, pid: 42, stateDirectory: "/var/lib/vm")
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VMStatusOutput.self, from: data)
        #expect(decoded.running == true)
        #expect(decoded.pid == 42)
        #expect(decoded.stateDirectory == "/var/lib/vm")
    }

    @Test("default parsing sets json to false")
    func defaultJsonIsFalse() throws {
        let cmd = try Status.parse([])
        #expect(cmd.json == false)
    }

    @Test("parsing with --json sets json to true")
    func jsonFlag() throws {
        let cmd = try Status.parse(["--json"])
        #expect(cmd.json == true)
    }
}
