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

    /// The app's name is the same in every language.
    static let appName = "Compare Text"
    static var quit: String { t("Stop \(appName)", "Quit \(appName)") }
    static var about: String { t("Over \(appName)", "About \(appName)") }
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
    static var leftPlaceholder: String {
        t("Plak hier de originele tekst (⌘V) of sleep een bestand hierheen",
          "Paste the original text here (⌘V) or drop a file here")
    }
    static var rightPlaceholder: String {
        t("Plak hier de nieuwe tekst (⌘V) of sleep een bestand hierheen",
          "Paste the new text here (⌘V) or drop a file here")
    }

    static func fileLoaded(_ name: String) -> String {
        t("\u{201C}\(name)\u{201D} geladen.", "Loaded \u{201C}\(name)\u{201D}.")
    }
    static func fileTooLarge(_ name: String) -> String {
        t("\u{201C}\(name)\u{201D} is groter dan 50 MB en is niet geopend.",
          "\u{201C}\(name)\u{201D} is larger than 50 MB and was not opened.")
    }
    static func fileNotText(_ name: String) -> String {
        t("\u{201C}\(name)\u{201D} is geen tekstbestand en is niet geopend.",
          "\u{201C}\(name)\u{201D} is not a text file and was not opened.")
    }
    static func fileUnreadable(_ name: String) -> String {
        t("\u{201C}\(name)\u{201D} kon niet worden geopend.",
          "\u{201C}\(name)\u{201D} could not be opened.")
    }
    static var onlyTwoFiles: String {
        t("Alleen de eerste twee bestanden zijn geopend.", "Only the first two files were opened.")
    }

    static var ignoreWhitespace: String { t("Negeer witruimte", "Ignore whitespace") }
    static var ignoreWhitespaceTooltip: String {
        t("Verschillen in inspringing, spaties, regelafbreking en lege regels worden genegeerd.",
          "Differences in indentation, spaces, line wrapping and blank lines are ignored.")
    }
    static var copyDifferences: String { t("Kopieer verschillen", "Copy Differences") }
    static var compareFirst: String { t("Vergelijk eerst de teksten.", "Compare the texts first.") }
    static var nothingToCopy: String { t("Geen verschillen om te kopiëren.", "No differences to copy.") }
    static func differencesCopied(_ count: Int) -> String {
        t(count == 1 ? "1 verschil als tekst gekopieerd." : "\(count) verschillen als tekst gekopieerd.",
          count == 1 ? "Copied 1 difference as text." : "Copied \(count) differences as text.")
    }
    static var wrapLines: String { t("Regels afbreken", "Wrap lines") }
    static var wrapLinesTooltip: String {
        t("Lange regels lopen door op de volgende regel. Uit: horizontaal scrollen.",
          "Long lines continue on the next line. Off: scroll horizontally.")
    }
    static var ignoreCase: String { t("Negeer hoofdletters", "Ignore case") }
    static var ignoreCaseTooltip: String {
        t("Hoofdletters en kleine letters tellen als gelijk.", "Upper- and lowercase letters count as equal.")
    }
    static var identicalExceptIgnored: String {
        t("Geen inhoudelijke verschillen — alleen witruimte, regelafbreking, lege regels of hoofdletters verschillen.",
          "No content differences — only whitespace, line wrapping, blank lines or letter case differ.")
    }
    static var identicalExceptWhitespace: String {
        t("Geen inhoudelijke verschillen — alleen witruimte, regelafbreking of lege regels verschillen.",
          "No content differences — only whitespace, line wrapping or blank lines differ.")
    }

    static var hintStart: String { t("Plak of sleep tekst in beide velden; de vergelijking start vanzelf.",
                                     "Paste or drop text into both fields; the comparison starts by itself.") }
    static var hintOtherSide: String { t("Plak of sleep nu de tekst voor het andere veld.",
                                         "Now paste or drop the text for the other field.") }
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

    /// "Verschil 3 van 17: 11 regels toegevoegd." — what happened, not
    /// where: the marker already shows where.
    static func differencePosition(_ index: Int, of total: Int, _ description: String) -> String {
        t("Verschil \(index) van \(total): \(description).", "Difference \(index) of \(total): \(description).")
    }

    private static func lines(_ count: Int) -> String {
        t(count == 1 ? "1 regel" : "\(count) regels", count == 1 ? "1 line" : "\(count) lines")
    }
    static func linesAdded(_ count: Int) -> String { t("\(lines(count)) toegevoegd", "\(lines(count)) added") }
    static func linesRemoved(_ count: Int) -> String { t("\(lines(count)) verwijderd", "\(lines(count)) removed") }
    static func linesChanged(_ count: Int) -> String { t("\(lines(count)) gewijzigd", "\(lines(count)) changed") }
    static func linesReplaced(_ removed: Int, by added: Int) -> String {
        t("\(lines(removed)) vervangen door \(added)", "\(lines(removed)) replaced by \(added)")
    }
    static func blockMoved(_ count: Int) -> String {
        t(count == 1 ? "1 regel verplaatst" : "blok van \(count) regels verplaatst",
          count == 1 ? "1 line moved" : "block of \(count) lines moved")
    }
}
