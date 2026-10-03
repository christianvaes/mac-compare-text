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

    static var leftTitle: String { t("Origineel", "Original") }
    static var rightTitle: String { t("Nieuw", "New") }
    static var legendRemoved: String { t("verwijderd", "removed") }
    static var legendAdded: String { t("toegevoegd", "added") }
    static var legendMoved: String { t("verplaatst", "moved") }
    static var options: String { t("Opties", "Options") }

    static func lineCount(_ count: Int) -> String {
        t("\(count) regel\(count == 1 ? "" : "s")", "\(count) line\(count == 1 ? "" : "s")")
    }

    static var scrollTogether: String { t("Scroll samen", "Scroll together") }
    static var scrollTogetherTooltip: String {
        t("Beide panelen scrollen samen zodat overeenkomende regels naast elkaar blijven.",
          "Both panes scroll together so matching lines stay side by side.")
    }
    static var leftPlaceholder: String { t("Plak hier de originele tekst (⌘V)", "Paste the original text here (⌘V)") }
    static var rightPlaceholder: String { t("Plak hier de nieuwe tekst (⌘V)", "Paste the new text here (⌘V)") }

    static var ignoreWhitespace: String { t("Negeer witruimte", "Ignore whitespace") }
    static var ignoreWhitespaceTooltip: String {
        t("Verschillen in inspringing, spaties en lege regels worden genegeerd.",
          "Differences in indentation, spaces and blank lines are ignored.")
    }
    static var identicalExceptWhitespace: String {
        t("Geen inhoudelijke verschillen — alleen witruimte/lege regels verschillen.",
          "No content differences — only whitespace/blank lines differ.")
    }

    static var hintStart: String { t("Plak tekst in beide velden en druk op ⌘↩ om te vergelijken.",
                                     "Paste text into both fields and press ⌘↩ to compare.") }
    static var hintEdited: String { t("Tekst gewijzigd — klik op Vergelijk voor een nieuwe vergelijking.",
                                      "Text changed — click Compare to compare again.") }
    static var identical: String { t("Geen verschillen — de teksten zijn identiek.",
                                     "No differences — the texts are identical.") }

    static func summary(movedBlocks: Int, hunks: Int) -> String {
        var text = t("\(hunks) verschil\(hunks == 1 ? "" : "len") gevonden",
                     "\(hunks) difference\(hunks == 1 ? "" : "s") found")
        if movedBlocks > 0 {
            text += t(", waarvan \(movedBlocks) blok\(movedBlocks == 1 ? "" : "ken") verplaatst",
                      ", \(movedBlocks) block\(movedBlocks == 1 ? "" : "s") moved")
        }
        return text + t(" — ⌘] voor het volgende.", " — ⌘] for the next one.")
    }

    static func differencePosition(_ index: Int, of total: Int) -> String {
        t("Verschil \(index) van \(total).", "Difference \(index) of \(total).")
    }
}
