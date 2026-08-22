import Foundation

// Minimal Log stand-in for tests that compile the real Vocabulary.swift
// (which cannot coexist with the Vocabulary stub in Support.swift).
enum Log {
    static func write(_ line: String) {
        FileHandle.standardError.write(Data(("LOG " + line + "\n").utf8))
    }
}
