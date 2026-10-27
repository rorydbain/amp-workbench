import Foundation

/// Reviewed presentation changes only. Names in third-party files are never edited.
public enum CommunityPresetTitles {
    private static let exact: [String: String] = [
        "ACDC": "AC/DC",
        "ACDC Youtube": "AC/DC · YouTube",
        "90's Metal": "’90s Metal",
        "Guns 'N Roses Sweet Child O' Mine": "Guns N’ Roses · Sweet Child O’ Mine",
        "Gilmour Shine On Tou Crazy Diamond THRii": "Gilmour · Shine On You Crazy Diamond · THR II",
        "Metal Rythm Djent": "Metal Rhythm Djent",
        "Plexi AC DC": "Plexi AC/DC",
        "SRV's Pair of Twin Reverbs": "SRV’s Pair of Twin Reverbs",
        "SRV's 60's Fender Super Reverb": "SRV’s ’60s Fender Super Reverb",
        "SlipKnot Drop B Tuning": "Slipknot · Drop B",
        "T_s Juicy Clean": "T’s Juicy Clean",
        "Van Halen 70's 80's": "Van Halen · ’70s / ’80s",
        "Van Halen 90's": "Van Halen · ’90s",
        "U2 Where The Streets Have No Name": "U2 · Where the Streets Have No Name",
        "Still Got The Blues": "Still Got the Blues",
        "Spirit In The Sky": "Spirit in the Sky",
        "Ride The Lightning": "Ride the Lightning",
        "Lenny Kravitz Always On The Run": "Lenny Kravitz · Always on the Run",
        "Knopfler Brothers In Arms": "Knopfler · Brothers in Arms",
        "Slash Give In To Me THRii": "Slash · Give In to Me · THR II",
        "Mastodon (Drop C) w Flanger": "Mastodon · Drop C with Flanger",
        "Mastodon (Drop C) w Chorus": "Mastodon · Drop C with Chorus",
        "Andy Timmons AT_Drive_1": "Andy Timmons · AT Drive 1",
        "Andy Timmons AT_Drive_2": "Andy Timmons · AT Drive 2",
        "Andy Timmons AT_Drive_3": "Andy Timmons · AT Drive 3"
    ]
    public static func format(_ original: String) -> String {
        if let title=exact[original] { return title }
        var title=original.replacingOccurrences(of:"\\s+",with:" ",options:.regularExpression)
            .trimmingCharacters(in:.whitespacesAndNewlines)
        for (pattern,replacement) in [
            ("(?i)\\bACDC\\b", "AC/DC"),
            ("(?i)\\bAC/DC\\b", "AC/DC"),
            ("(?i)\\bAC30\\b", "AC30"),
            ("(?i)\\bDC30\\b", "DC-30"),
            ("(?i)\\bTHRii\\b", "THR II"),
            ("(?i)\\bQOTSA\\b", "QOTSA")
        ] {
            title=title.replacingOccurrences(of:pattern,with:replacement,options:.regularExpression)
        }
        return title
    }
}
