"""Mechanical Linux shims for the sources under test.

Applied IDENTICALLY to the baseline (git main) and current copies so the
before/after comparison stays fair. Three kinds of edit, all transport-level,
none touching the timing logic being measured:

1. conditional FoundationNetworking import (URLSession lives there on Linux)
2. `waitsForConnectivity` setter is Darwin-only -> guard it out on Linux
3. baseline copies lack the QUILL_STT_URL / QUILL_CHAT_URL env overrides the
   current sources ship with -> give the baseline the same override
"""
import sys

IMPORT_SHIM = (
    "import Foundation\n"
    "#if canImport(FoundationNetworking)\n"
    "import FoundationNetworking\n"
    "#endif\n"
)

CONNECTIVITY = "config.waitsForConnectivity = false"
CONNECTIVITY_GUARDED = (
    "#if !canImport(FoundationNetworking)\n"
    "        config.waitsForConnectivity = false\n"
    "        #endif"
)

STT_URL_HARDCODED = 'var components = URLComponents(string: "wss://api.x.ai/v1/stt")!'
STT_URL_ENV = (
    "var components = URLComponents(string: "
    'ProcessInfo.processInfo.environment["QUILL_STT_URL"] ?? "wss://api.x.ai/v1/stt")!'
)

CHAT_URL_HARDCODED = (
    '    private static let endpoint = URL(string: "https://api.x.ai/v1/chat/completions")!'
)
CHAT_URL_ENV = (
    "    private static let endpoint: URL = {\n"
    '        let override = ProcessInfo.processInfo.environment["QUILL_CHAT_URL"] ?? ""\n'
    '        return URL(string: override) ?? URL(string: "https://api.x.ai/v1/chat/completions")!\n'
    "    }()"
)


def patch(path):
    with open(path) as f:
        source = f.read()

    if "FoundationNetworking" not in source:
        source = source.replace("import Foundation\n", IMPORT_SHIM, 1)
    if CONNECTIVITY_GUARDED not in source:
        source = source.replace(CONNECTIVITY, CONNECTIVITY_GUARDED)
    source = source.replace(STT_URL_HARDCODED, STT_URL_ENV)
    source = source.replace(CHAT_URL_HARDCODED, CHAT_URL_ENV)

    # Vocabulary.swift: AppKit is only needed for the reveal-in-Finder helper.
    source = source.replace("import AppKit\n", "")
    source = source.replace(
        "        NSWorkspace.shared.activateFileViewerSelecting([fileURL])",
        "        // NSWorkspace reveal is macOS-only (not exercised by tests).")

    with open(path, "w") as f:
        f.write(source)
    print(f"patched {path}")


for p in sys.argv[1:]:
    patch(p)
