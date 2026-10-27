import Foundation

/// Original THR II interpretations authored for this app; never artist presets.
public enum CuratedPresets {
    public static func load() throws -> [LibraryEntry] {
        let definitions:[(file:String,id:String,reference:String,relationship:String)] = [
            ("come-when-i-call","amp-workbench/john-mayer-trio/come-when-i-call","https://www.youtube.com/watch?v=NkVtDihe3iQ","Original THR II interpretation inspired by the John Mayer Trio live performance; not an artist preset or verified reproduction"),
            ("pride-and-joy","amp-workbench/stevie-ray-vaughan/pride-and-joy","https://www.mixonline.com/recording/classic-tracks/classic-track-stevie-ray-vaughan-pride-and-joy-367582","Original THR II interpretation informed by the Texas Flood engineer’s account of Vaughan’s guitars and amplifiers; exact song settings are not documented"),
            ("tennessee-whiskey","amp-workbench/chris-stapleton/tennessee-whiskey","https://relix.com/features/detail/chris_stapleton_songs_of_myself","Original THR II interpretation informed by Stapleton’s description of his Jazzmaster and Princeton rig; exact song-session settings are not documented")
        ]
        return try definitions.map { definition in
            let url=Bundle.module.url(forResource:definition.file,withExtension:"json")!
            let preset=try Preset.decode(Data(contentsOf:url))
            let source=PresetSource(id:definition.id,publisher:"Amp Workbench",originalName:preset.name,reference:definition.reference,relationship:definition.relationship)
            return LibraryEntry(preset:preset,displayName:preset.name,source:source)
        }
    }
}
