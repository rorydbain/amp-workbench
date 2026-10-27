import Foundation

/// Editorial references, never replacements for Yamaha model IDs. The THR-II
/// models were adjusted for this amp and are not literal copies of other amps.
/// Source: Yamaha's THR-II catalog and the model/cabinet breakdown attributed to
/// THR engineer John Kim: https://gear.pudge.net/manuals/thr30iiwireless/Yamaha%20THRII%20Presets.pdf
public enum ModelLabels {
    public static let ampTitles: [String: String] = [
        "THR10C_Deluxe": "Fender Deluxe-style clean",
        "THR10C_DC30": "Matchless DC-30-style chime",
        "THR10_Lead": "Marshall Plexi-style lead",
        "THR10_Modern": "Mesa Dual Rectifier-style gain",
        "THR10_Brit": "EVH 5150 III-style brown sound",
        "THR10_Bass_Eden_Marcus": "Eden / Markbass-style vintage bass",
        "THR10_Aco_Condenser1": "Condenser mic-style acoustic",
        "THR10_Flat": "Direct input · neutral",
        "THR10C_BJunior2": "Fender Blues Junior-style clean",
        "THR30_SR101": "Dr. Z Mini Z-style crunch",
        "THR30_Blondie": "Marshall 1987X-style lead",
        "THR30_FLead": "German high-gain blend",
        "THR10X_South": "Krank Krankenstein-style metal",
        "THR10_Bass_Mesa": "Mesa Subway-style bass",
        "THR10_Aco_Tube1": "Tube mic-style acoustic",
        "THR10_Flat_B": "Direct input · bass boost",
        "THR30_Carmen": "Dr. Z Carmen Ghia-style clean",
        "THR10C_Mini": "Vox AC30 / Matchless-style crunch",
        "THR10X_Brown1": "Hot-rodded JCM800-style lead",
        "THR10X_Brown2": "EVH 5150 III-style high gain",
        "THR30_Stealth": "Boosted EVH Stealth-style gain",
        "THR30_JKBass2": "Marshall-circuit bass drive",
        "THR10_Aco_Dynamic1": "Dynamic mic-style acoustic",
        "THR10_Flat_V": "Direct input · mid scoop"
    ]
    public static let cabinetTitles: [String] = [
        "Marshall 1960A-style 4×12", "Mesa-style 4×12", "Peavey 5150-style 4×12",
        "Bogner-style 4×12", "Diezel-style 4×12", "Orange-style 4×12",
        "Hiwatt-style 4×12", "Fender Twin-style 2×12", "Vox AC30-style 2×12",
        "Marshall Bluesbreaker-style 2×12", "Matchless DC-30-style 2×12",
        "Yamaha F100-212-style 2×12", "Mesa Mark III-style 1×12",
        "Fender Deluxe Reverb-style 1×12", "Fender Bassman-style 4×10",
        "Japanese boutique-style 1×12", "No cabinet simulation"
    ]
    public static func ampTitle(_ model: Model) -> String { ampTitles[model.id] ?? model.name }
    public static func cabinetTitle(_ index: Int) -> String {
        cabinetTitles.indices.contains(index) ? cabinetTitles[index] : "Cabinet \(index)"
    }
    public static func ampReference(_ preset: Preset) -> String {
        guard let block = preset.tone["amp"],
              let model = Catalogue.shared.model(block, group: "amp") else { return "" }
        return "\(ampTitle(model)) · Yamaha \(model.name)"
    }
    public static func cabinetReference(_ preset: Preset) -> String {
        guard let index = preset.tone["cabinet"]?.parameters["SpkSimType"]?.number else { return "" }
        return cabinetTitle(Int(index))
    }
}
