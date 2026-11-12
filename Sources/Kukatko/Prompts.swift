import AppKit

enum Prompts {
    static func system() -> String {
        let lang = Settings.shared.language
        return """
        Jsi Kukátko, vysvětlovač vestavěný do macOS. Uživatel si v nějaké aplikaci označil text nebo obrázek \
        a chce rychle pochopit, co to je. Odpovídej \(lang).

        Pravidla:
        - Rovnou k věci. Žádné úvodní fráze („Jistě“, „Skvělá otázka“), neopakuj zadání.
        - Je-li označený text v jiném jazyce, začni jeho krátkým překladem.
        - Je-li to kód, příkaz nebo vzorec, vysvětli, co dělá.
        - Zkratky a odborné termíny vysvětluj ve významu, který sedí na okolní text.
        - Je-li to věta nebo odstavec, vysvětli jeho smysl a těžká místa, nepřepisuj ho celý.
        - Když si nejsi jistý, řekni to; nevymýšlej si fakta, čísla ani citace.
        - Markdown používej střídmě: **tučně** pro klíčový pojem, odrážky jen tam, kde pomáhají.
        """
    }

    static func firstQuestion(for c: Captured, mode: ResultMode) -> AIMessage {
        let source = c.app?.localizedName.map { " (z aplikace \($0))" } ?? ""
        let instruction: String
        switch mode {
        case .short:
            instruction = c.content.isImage
                ? "Řekni krátce, co je na obrázku a co to znamená – nejvýš 3 věty, bez nadpisů a odrážek."
                : "Vysvětli krátce – nejvýš 3 věty, bez nadpisů a odrážek."
        case .long, .images:
            instruction = c.content.isImage
                ? "Popiš a vysvětli obrázek podrobně: co na něm je, kontext, zajímavosti, případný text v obraze přelož. Strukturuj krátkými nadpisy (###) a odrážkami, do 350 slov."
                : "Vysvětli podrobně: co to je, souvislosti, konkrétní příklad a na co si dát pozor. Strukturuj krátkými nadpisy (###) a odrážkami, do 350 slov."
        }
        switch c.content {
        case .text(let t):
            var s = "\(instruction)\n\nOznačený text\(source):\n<oznaceno>\n\(t)\n</oznaceno>"
            if let ctx = c.context, !ctx.isEmpty {
                s += "\n\nOkolní text (jen pro kontext):\n<okoli>\n\(ctx)\n</okoli>"
            }
            return AIMessage(role: .user, text: s)
        case .image(let img):
            return AIMessage(role: .user, text: "\(instruction)\n\nObrázek\(source) je přiložený.", image: img)
        }
    }

    static let keywordsSystem = """
    Navrhuješ dotazy pro vyhledávání obrázků. Vrať jen JSON objekt bez dalšího textu ve tvaru \
    {"cs": "...", "en": "..."} – v každém krátký dotaz o 1 až 4 slovech, který najde fotku nebo ilustraci \
    toho hlavního, o čem označený obsah je (konkrétní věc, osoba, místo, druh, pojem). Žádné uvozovky uvnitř.
    """

    static func keywordsQuestion(for c: Captured) -> AIMessage {
        switch c.content {
        case .text(let t):
            var s = "Označený text:\n\(t.prefix(3000))"
            if let ctx = c.context { s += "\n\nKontext:\n\(ctx.prefix(800))" }
            return AIMessage(role: .user, text: s)
        case .image(let img):
            return AIMessage(role: .user, text: "Co je na obrázku? Navrhni dotazy, které najdou podobné obrázky.", image: img)
        }
    }
}
