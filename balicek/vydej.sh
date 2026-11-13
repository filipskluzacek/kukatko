#!/bin/zsh
# Vydá novou verzi: ./balicek/vydej.sh 1.2 "Co je nového"
# Sestaví a podepíše appku, dá zip do vydani/, zapíše vydani/aktualizace.json, commitne a pushne.
# Nainstalované Kukátko (u tebe i u kamarádů) si aktualizaci najde samo.
set -e
cd "$(dirname "$0")/.."
VERZE=$1
NOVINKY=${2:-}
[[ -z $VERZE ]] && { echo "Použití: ./balicek/vydej.sh 1.2 \"Co je nového\""; exit 1; }
[[ -n $(git status --porcelain -- Sources balicek Package.swift | grep -v balicek/VERZE) ]] && { echo "Nejdřív commitni změny v kódu."; exit 1; }
security find-identity -p codesigning | grep -q "Kukatko Code Signing" || { echo "Chybí certifikát Kukatko Code Signing – vydání musí být podepsané jím, jinak by se aktualizace odmítla."; exit 1; }

echo $VERZE > balicek/VERZE
./balicek/postav.sh
mkdir -p vydani
cp dist/Kukatko.zip vydani/Kukatko.zip
python3 - "$VERZE" "$NOVINKY" <<'PY'
import json, sys
json.dump({"verze": sys.argv[1],
           "zip": "https://raw.githubusercontent.com/filipskluzacek/kukatko/main/vydani/Kukatko.zip",
           "novinky": sys.argv[2]},
          open("vydani/aktualizace.json", "w"), ensure_ascii=False, indent=2)
PY
git add balicek/VERZE vydani/
git commit -q -m "Vydání $VERZE${NOVINKY:+: $NOVINKY}"
git push -q origin main
echo "Vydáno $VERZE. Kukátka si ho najdou do pár hodin (nebo hned přes Zkontrolovat aktualizace)."
