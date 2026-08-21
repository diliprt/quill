import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Stand-ins for the Cocoa-side types the shipped STT/Cleaner sources reference.
// Only what those files actually touch is stubbed; behavior-neutral.

enum Log {
    static func write(_ line: String) {
        FileHandle.standardError.write(Data(("LOG " + line + "\n").utf8))
    }
}

enum Vocabulary {
    static func promptBlock(limit: Int) -> String { "" }
    static func count() -> Int { 0 }
}

enum Inserter {
    struct CleanupContext {
        var hasUsableText: Bool { false }
        func promptBlock() -> String { "" }
        var logSummary: String { "" }
    }
}

#if canImport(FoundationNetworking)
// corelibs Foundation only ships the async send/receive. These overloads give
// the shipped macOS call sites (`send(...) { _ in }`, `receive { result in }`)
// something to resolve to, without touching the sources under test.
extension URLSessionWebSocketTask {
    func send(_ message: Message, completionHandler: @escaping (Error?) -> Void) {
        Task {
            do { try await self.send(message); completionHandler(nil) }
            catch { completionHandler(error) }
        }
    }

    func receive(completionHandler: @escaping (Result<Message, Error>) -> Void) {
        Task {
            do { completionHandler(.success(try await self.receive())) }
            catch { completionHandler(.failure(error)) }
        }
    }
}
#endif
