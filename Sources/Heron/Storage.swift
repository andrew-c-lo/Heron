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
                    Lenient.decode($0, defaults: Macro(name: "Untitled", steps: []), encoder: Self.encoder, decoder: Self.decoder)?.migrated()
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
        // Only files that are macros: other JSON would otherwise fill in as an empty one.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["steps"] is [Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard var m = Lenient.decode(data, defaults: Macro(name: url.deletingPathExtension().lastPathComponent, steps: []),
                                     encoder: Self.encoder, decoder: Self.decoder) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        m = m.migrated()
        m.id = UUID()
        m.created = Date()
        // Someone else's macro doesn't start on its own until you switch its schedule on.
        m.schedule?.enabled = false
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
              let base = try? JSONSerialization.jsonObject(with: encoder.encode(defaults)) else { return nil }
        var merged = merge(base, stored)
        // Still unreadable (a value this version doesn't know, say from a newer Heron, or a damaged file): put the
        // default back at exactly the spot the decoder complains about, or drop that one list item, and try again.
        // Losing one setting beats the whole macro vanishing from the list.
        for _ in 0..<50 {
            guard let json = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
            do { return try decoder.decode(T.self, from: json) } catch let error as DecodingError {
                guard let path = Self.path(of: error), !path.isEmpty,
                      let fixed = Self.repair(merged, base: base, at: path) else { return nil }
                merged = fixed
            } catch { return nil }
        }
        return nil
    }

    private static func path(of error: DecodingError) -> [CodingKey]? {
        switch error {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): c.codingPath
        case .keyNotFound(_, let c): c.codingPath
        @unknown default: nil
        }
    }

    /// `value` with the item at `path` replaced by the default (or removed when there's no default for it).
    private static func repair(_ value: Any, base: Any?, at path: [CodingKey]) -> Any? {
        guard let key = path.first else { return base }
        let rest = Array(path.dropFirst())
        if var dict = value as? [String: Any] {
            let b = (base as? [String: Any])?[key.stringValue]
            if rest.isEmpty || dict[key.stringValue] == nil {
                if let b { dict[key.stringValue] = b } else if dict[key.stringValue] != nil { dict[key.stringValue] = nil } else { return nil }
                return dict
            }
            guard let inner = repair(dict[key.stringValue]!, base: b, at: rest) else { return nil }
            dict[key.stringValue] = inner
            return dict
        }
        if var list = value as? [Any], let i = key.intValue, list.indices.contains(i) {
            let b = (base as? [Any]).flatMap { $0.indices.contains(i) ? $0[i] : nil }
            if rest.isEmpty || b == nil && !(list[i] is [String: Any]) { list.remove(at: i); return list }
            if let inner = repair(list[i], base: b, at: rest) { list[i] = inner } else { list.remove(at: i) }
            return list
        }
        return nil
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
