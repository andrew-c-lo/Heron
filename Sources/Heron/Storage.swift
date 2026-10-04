import AppKit
import ApplicationServices

/// Where Heron keeps its files: ~/Library/Application Support/Heron, or the folder in the
/// HERON_HOME environment variable (used for demo/test copies so they never touch real data).
enum AppFolder {
    static var url: URL {
        if let custom = ProcessInfo.processInfo.environment["HERON_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Heron", isDirectory: true)
        // The app used to be called MacroClicker: bring its folder (macros, pictures, logs) along once.
        let old = base.appendingPathComponent("MacroClicker", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: folder)
        }
        return folder
    }
}

struct MacroStore {
    let directory: URL

    init() {
        directory = AppFolder.url.appendingPathComponent("Macros", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func url(for m: Macro) -> URL { directory.appendingPathComponent("\(m.id.uuidString).json") }

    func loadAll() -> [Macro] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap {
                    Lenient.decode($0, defaults: Macro(name: "Untitled", steps: []), encoder: Self.encoder, decoder: Self.decoder)
                }
            }
            .sorted { $0.created < $1.created }
    }

    func save(_ m: Macro) {
        try? Self.encoder.encode(m).write(to: url(for: m), options: .atomic)
    }

    func delete(_ m: Macro) {
        try? FileManager.default.trashItem(at: url(for: m), resultingItemURL: nil)
    }

    private func snapshotURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).png") }

    func loadSnapshot(_ id: UUID) -> NSImage? {
        guard let rep = NSImageRep(contentsOf: snapshotURL(id)) else { return nil }
        // Stored at 2× pixels; show at point size so it lines up with window-relative coordinates.
        let size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
        rep.size = size
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }

    func saveSnapshot(_ img: NSImage, for id: UUID) {
        // Write the stored pixels as-is. (cgImage(forProposedRect:) would re-render at 1× and halve the size.)
        guard let rep = img.representations.compactMap({ $0 as? NSBitmapImageRep }).first
            ?? img.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:)) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: snapshotURL(id), options: .atomic)
    }

    func deleteSnapshot(_ id: UUID) {
        try? FileManager.default.trashItem(at: snapshotURL(id), resultingItemURL: nil)
    }

    func export(_ m: Macro, to url: URL) throws {
        try Self.encoder.encode(m).write(to: url, options: .atomic)
    }

    func importMacro(from url: URL) throws -> Macro {
        let data = try Data(contentsOf: url)
        guard var m = Lenient.decode(data, defaults: Macro(name: url.deletingPathExtension().lastPathComponent, steps: []),
                                     encoder: Self.encoder, decoder: Self.decoder) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        m.id = UUID()
        m.created = Date()
        return m
    }
}

enum Persist {
    static func load<T: Codable>(_ key: String, default value: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key) else { return value }
        return Lenient.decode(data, defaults: value) ?? value
    }

    static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Decodes JSON on top of a default value, so files written by older versions
/// (missing newer fields) still load instead of being discarded.
enum Lenient {
    static func decode<T: Codable>(_ data: Data, defaults: T,
                                   encoder: JSONEncoder = JSONEncoder(), decoder: JSONDecoder = JSONDecoder()) -> T? {
        if let v = try? decoder.decode(T.self, from: data) { return v }
        guard let stored = try? JSONSerialization.jsonObject(with: data),
              let base = try? JSONSerialization.jsonObject(with: encoder.encode(defaults)),
              let merged = try? JSONSerialization.data(withJSONObject: merge(base, stored)) else { return nil }
        return try? decoder.decode(T.self, from: merged)
    }

    private static func merge(_ base: Any, _ over: Any) -> Any {
        guard var b = base as? [String: Any], let o = over as? [String: Any] else { return over }
        for (k, v) in o { b[k] = b[k].map { merge($0, v) } ?? v }
        return b
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    // The system's permission checks can take a long time to answer; asking from a background thread keeps
    // Heron's window responsive meanwhile (asking on the main thread froze it).
    static func requestAccessibility() {
        DispatchQueue.global(qos: .userInitiated).async {
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        open("Privacy_Accessibility")
    }

    static func requestInputMonitoring() {
        DispatchQueue.global(qos: .userInitiated).async { _ = CGRequestListenEventAccess() }
        open("Privacy_ListenEvent")
    }

    static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
