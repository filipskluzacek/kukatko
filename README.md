# Kukátko

**Označte cokoli, kdekoli. Kukátko to vysvětlí.**

Malá appka do horní lišty macOS. V jakékoli aplikaci označíte text nebo zkopírujete obrázek a vedle se objeví lišta **Krátce · Dlouze · Proč · Obrázek**. Odpověď se ukáže v plovoucím panelu, kde se dá ptát dál, a obrázky jdou rovnou přetáhnout, zkopírovat nebo uložit.

AI běží v cloudu přes **Google Gemini** v bezplatné úrovni, takže se nic neplatí. Každý si jen jednou vytvoří vlastní klíč (účet Google, bez platební karty).

## Instalace

1. Stáhněte **[Kukatko.zip](https://github.com/filipskluzacek/kukatko/raw/main/vydani/Kukatko.zip)** a rozbalte ho.
2. Přetáhněte **Kukátko** do složky Aplikace a otevřete ho.
3. macOS napíše, že aplikaci nejde ověřit (není z App Storu). Otevřete **Nastavení systému → Soukromí a zabezpečení**, sjeďte dolů a u Kukátka klikněte na **Přesto otevřít**.
4. Kukátko vás provede zbytkem:
   - **Klíč Gemini**: klikněte na „Získat klíč zdarma“, přihlaste se účtem Google, dejte *Create API key*, klíč zkopírujte a vložte.
   - **Zpřístupnění**: zapněte Kukátko v *Nastavení systému → Soukromí a zabezpečení → Zpřístupnění*. Díky tomu vidí, co máte označené.

Potřebujete macOS 26 nebo novější a Mac s Apple Silicon (M1 a novější).

## Aktualizace

Kukátko si samo hlídá nové verze (po spuštění a pak každých pár hodin). Když nějaká vyjde, nabídne **Aktualizovat**: stáhne ji, ověří, že je podepsaná stejně jako ta vaše, vymění se a znovu se spustí. Povolení i klíč zůstanou. Ručně: ikona v horní liště → **Zkontrolovat aktualizace…**

## Jak se používá

| Co | Jak |
|---|---|
| Označený text | stačí ho označit myší (tažení, dvojklik, trojklik) |
| Obrázek | zkopírovat ho (Kopírovat obrázek, ⌃⇧⌘4) |
| Cokoli označeného, i obrázek | **⌥⌘E** |
| Oblast obrazovky | **⌥⌘R** |
| Odkudkoli | pravé tlačítko → Služby → Kukátko |

**Proč** u označeného výroku řekne, jestli vůbec platí, vysvětlí příčiny a mechanismus a proč nefungují jiné varianty (třeba „závodní auta jsou typicky benzínová“ → energetická hustota paliva, otáčky, proč ne nafta nebo baterie).

V panelu: **Esc** zavře, špendlík ho nechá otevřený, dole se dá ptát dál (v záložce Obrázky hledat jiný dotaz).

## Soukromí

Označený text nebo obrázek se posílá do Google Gemini. Google smí dotazy z bezplatné úrovně používat ke zlepšování svých služeb, proto do Kukátka neposílejte citlivé údaje. Hesla (zabezpečená pole) Kukátko nečte nikdy. Obrázky se hledají na celém webu přes DuckDuckGo Obrázky, doplňkově na Wikipedii a Wikimedia Commons. Klíče zůstávají jen na vašem Macu (soubor čitelný jen pro vašeho uživatele).

V Nastavení jde místo Gemini zapnout Claude (přes Claude Code nebo placený API klíč).

## Když něco nejde

- **Pořád to chce Zpřístupnění, i když je zapnuté:** v seznamu Kukátko vyberte, odeberte tlačítkem − a přidejte znovu (nebo ho vypněte a zapněte).
- **„Bezplatný limit je vyčerpaný“:** bezplatná úroveň má limit dotazů za minutu a za den. Chvíli počkejte.
- **V některé aplikaci se lišta neukáže:** použijte ⌥⌘E.

## Pro vývojáře

```bash
./balicek/postav.sh                               # dist/Kukatko.app + dist/Kukatko.zip
./balicek/postav.sh --instaluj                    # a rovnou do /Applications
./balicek/vydej.sh X.Y "Co je nového"             # vydání (X.Y = vyšší než poslední v vydani/aktualizace.json): zip do vydani/, aktualizace.json, commit + push
```

Nainstalovaná Kukátka čtou `vydani/aktualizace.json` a nainstalují jen zip podepsaný stejným certifikátem. Proto se vydání smí sestavit jen na Macu, kde je „Kukatko Code Signing“.

Swift Package bez Xcode projektu. `postav.sh` podepisuje certifikátem „Kukatko Code Signing“ z Klíčenky, když existuje, aby povolení Zpřístupnění vydrželo i nová sestavení. Jinak podepíše ad-hoc.

- `SelectionWatcher`: myš → Accessibility API (`AXSelectedText`, poloha výběru, okolní text). Chromium a Electron dostanou `AXManualAccessibility`. Když aplikace výběr nevydá, pošle se ⌘C a schránka se hned vrátí.
- `ClipboardWatcher`: hlídá, jestli do schránky přišel obrázek.
- `AIClient`: Gemini (`streamGenerateContent` přes SSE), Claude Code (`claude -p`), Claude API.
- `ImageSearch`: celý web přes DuckDuckGo Obrázky (token `vqd` + `i.js`), Wikipedie a Wikimedia Commons. Bez klíčů.

Ladění bez povolení: `Kukatko --ukazka "text" short|long|images --snimek /složka 12` otevře panel a po 12 s uloží jeho PNG.
