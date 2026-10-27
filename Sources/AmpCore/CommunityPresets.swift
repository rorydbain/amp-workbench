import Foundation
import CryptoKit
import ZIPFoundation

/// Fetches the complete, pinned community archive into the user's local library.
/// We distribute no third-party preset files with the app.
public enum CommunityPresets {
    public static let revision = "d5b602eecf20d119ebda2a68dbb830dfa5f05567"
    public static let archiveSHA256 = "6930ae596c2d8534b9af5002579fb0669a5751fc3cb6a5ca9f0754be964f952c"
    public static let archiveURL = URL(string:"https://raw.githubusercontent.com/f3sty/Yamaha_THRII_presets/\(revision)/presets/0_All_Presets.zip")!
    public static let sourceURL = "https://github.com/f3sty/Yamaha_THRII_presets/tree/\(revision)/presets"
    public static let mayerFileID = "1tIJATNfWoK16yYzaFNRN6cK_-Mfa41kn"
    public static let mayerSHA256 = "2360a9c5d3b9d988b3ba72bd2013eb1f2d5bc0db55cb884e7188509e795dafb3"

    public static func download(into directory: URL) async throws -> [LibraryEntry] {
        let archive = directory.appendingPathComponent("community-presets-\(revision).zip")
        let data: Data
        if FileManager.default.fileExists(atPath:archive.path) {
            data=try Data(contentsOf:archive)
        } else {
            let (response, _) = try await URLSession.shared.data(from:archiveURL)
            data=response
        }
        guard data.count < 5_000_000 else { throw AmpError("Community preset archive exceeds 5 MB.") }
        let digest=SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        guard digest == archiveSHA256 else { throw AmpError("Community archive checksum differs from the reviewed revision.") }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if !FileManager.default.fileExists(atPath:archive.path) { try data.write(to:archive,options:.atomic) }
        let extraction=directory.appendingPathComponent(".extract-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:extraction,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:extraction) }
        let zip = try Archive(url: archive, accessMode: .read)
        let members = zip.filter { $0.path.lowercased().hasSuffix(".thrl6p") }
        guard members.count == 234,
              members.allSatisfy({ $0.uncompressedSize < 1_000_000 }),
              members.reduce(0, { $0 + $1.uncompressedSize }) < 25_000_000 else {
            throw AmpError("Community archive contains unexpected preset files.")
        }
        var extracted = Set<String>()
        for member in members {
            let filename = URL(fileURLWithPath: member.path).lastPathComponent
            guard !filename.isEmpty, extracted.insert(filename).inserted else { throw AmpError("Duplicate community preset filename.") }
            _ = try zip.extract(member, to: extraction.appendingPathComponent(filename))
        }
        let urls=try FileManager.default.contentsOfDirectory(at:extraction,includingPropertiesForKeys:nil)
            .filter { $0.pathExtension.lowercased() == "thrl6p" }
        guard urls.count == 234 else { throw AmpError("Expected 234 community THR II presets, found \(urls.count).") }
        return try urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).map { url in
            let preset=try THRRemoteFile.decode(Data(contentsOf:url),ignoringInactiveParameters:true)
            let source=PresetSource(
                id:"f3sty/\(revision)/\(url.lastPathComponent)",
                publisher:"THR II community", originalName:preset.name,
                reference:sourceURL,
                relationship:"community-generated preset; artist/song names are contributor labels, not endorsements; inactive template fields omitted"
            )
            return LibraryEntry(preset:preset,displayName:CommunityPresetTitles.format(preset.name),source:source)
        }
    }
    public static func downloadFeatured(into directory: URL) async throws -> [LibraryEntry] {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let path=directory.appendingPathComponent("john-mayer-who-did-you-think-i-was.thrl6p")
        let data:Data
        if FileManager.default.fileExists(atPath:path.path) { data=try Data(contentsOf:path) }
        else {
            let url=URL(string:"https://drive.google.com/uc?export=download&id=\(mayerFileID)")!
            let (downloaded,_) = try await URLSession.shared.data(from:url)
            data=downloaded
        }
        guard data.count < 1_000_000 else { throw AmpError("John Mayer community patch exceeds 1 MB.") }
        let digest=SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        guard digest == mayerSHA256 else { throw AmpError("John Mayer patch checksum differs from the reviewed file.") }
        if !FileManager.default.fileExists(atPath:path.path) { try data.write(to:path,options:.atomic) }
        var preset=try THRRemoteFile.decode(data)
        preset.description="Community recreation of John Mayer's Who Did You Think I Was tone."
        preset.tags=["community","John Mayer","Who Did You Think I Was","blues rock"]
        preset.suggestions="Contributor used a Strat-style neck single coil; guitar volume around 3 for the opening, then fully up for more gain."
        let source=PresetSource(
            id:"cifra-club/gabriel-crispino/who-did-you-think-i-was",
            publisher:"Cifra Club · Gabriel Crispino", originalName:preset.name,
            reference:"https://forum.cifraclub.com.br/forum/10/340094/",
            relationship:"community recreation with audio demo; not John Mayer-endorsed"
        )
        return [LibraryEntry(preset:preset,displayName:"John Mayer · Who Did You Think I Was",source:source)]
    }
}
