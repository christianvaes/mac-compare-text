import Foundation

/// Minimal localization: Dutch when the system prefers Dutch, English
/// otherwise. Add a language by extending the switch cases.
enum L10n {
    private static let lang: String = {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("nl") ? "nl" : "en"
    }()

    private static func t(_ nl: String, _ en: String) -> String {
        lang == "nl" ? nl : en
    }

    static var appName: String { t("Vergelijk Tekst", "Compare Text") }
    static var quit: String { t("Stop Vergelijk Tekst", "Quit Compare Text") }
    static var about: String { t("Over Vergelijk Tekst", "About Compare Text") }
    static var builtOn: String { t("Gebouwd op", "Built on") }
    static var version: String { t("Versie", "Version") }

    static var editMenu: String { t("Wijzig", "Edit") }
    static var undo: String { t("Herstel", "Undo") }
    static var redo: String { t("Opnieuw", "Redo") }
    static var cut: String { t("Knip", "Cut") }
    static var copy: String { t("Kopieer", "Copy") }
    static var paste: String { t("Plak", "Paste") }
    static var delete: String { t("Verwijder", "Delete") }
    static var selectAll: String { t("Selecteer alles", "Select All") }
    static var find: String { t("Zoek…", "Find…") }

    static var compareMenu: String { t("Vergelijking", "Comparison") }
    static var compare: String { t("Vergelijk", "Compare") }
    static var nextDifference: String { t("Volgend verschil", "Next Difference") }
    static var previousDifference: String { t("Vorig verschil", "Previous Difference") }
    static var swapTexts: String { t("Wissel teksten", "Swap Texts") }
    static var clearAll: String { t("Maak beide velden leeg", "Clear Both Fields") }
    static var clearButton: String { t("Leegmaken", "Clear") }
    static var swapButton: String { t("Wissel", "Swap") }

    static var leftTitle: String { t("Tekst 1 — origineel", "Text 1 — original") }
    static var rightTitle: String { t("Tekst 2 — nieuw", "Text 2 — new") }
    static var leftLegend: String { t("rood = verwijderd/gewijzigd", "red = removed/changed") }
    static var rightLegend: String { t("groen = toegevoegd/gewijzigd", "green = added/changed") }
    static var leftPlaceholder: String { t("Plak hier de originele tekst (⌘V)", "Paste the original text here (⌘V)") }
    static var rightPlaceholder: String { t("Plak hier de nieuwe tekst (⌘V)", "Paste the new text here (⌘V)") }

    static var hintStart: String { t("Plak tekst in beide velden en klik op Vergelijk (↩ of ⌘↩).",
                                     "Paste text into both fields and click Compare (↩ or ⌘↩).") }
    static var hintEdited: String { t("Tekst gewijzigd — klik op Vergelijk voor een nieuwe vergelijking.",
                                      "Text changed — click Compare to compare again.") }
    static var identical: String { t("Geen verschillen — de teksten zijn identiek.",
                                     "No differences — the texts are identical.") }

    static func summary(removed: Int, added: Int, hunks: Int) -> String {
        t("\(hunks) verschil\(hunks == 1 ? "" : "len"): \(removed) regel(s) rood links, \(added) regel(s) groen rechts.",
          "\(hunks) difference\(hunks == 1 ? "" : "s"): \(removed) line(s) red on the left, \(added) line(s) green on the right.")
    }

    static func differencePosition(_ index: Int, of total: Int) -> String {
        t("Verschil \(index) van \(total).", "Difference \(index) of \(total).")
    }
}
