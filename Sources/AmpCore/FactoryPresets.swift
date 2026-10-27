import Foundation

/// Presentation names for the files shipped with a locally installed THR Remote.
/// Style/amp references are descriptive inferences, not Yamaha endorsements or
/// claims that an artist used these exact settings. The original file is retained.
public enum FactoryPresets {
    public static var titles: [String: String] {
        get throws {
            let url = Bundle.module.url(forResource: "factory-preset-titles", withExtension: "json")!
            return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        }
    }
    public static func load(from resources: URL) throws -> [LibraryEntry] {
        let titles = try titles
        let urls = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "thrl6p" }
        var result: [LibraryEntry] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let displayName = titles[url.lastPathComponent] else { continue }
            let preset = try THRRemoteFile.importFile(url)
            let publisher = url.lastPathComponent.contains("Chris Buck") ? "Yamaha / Chris Buck" : "Yamaha"
            let source = PresetSource(
                id: "yamaha-thr-remote/\(url.lastPathComponent)", publisher: publisher,
                originalName: preset.name, reference: nil, relationship: "factory file; display title is descriptive"
            )
            result.append(LibraryEntry(preset: preset, displayName: displayName, source: source))
        }
        return result
    }
}
