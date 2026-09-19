#!/usr/bin/env bash
# ── Pre-push checks — run before every commit ─────────────────────
# Adapted from the loz-web house pattern, plus a content gate that
# validates the rendered output before it can be published.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[0;32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '    \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=1; }
warn() { printf '    \033[0;33mWARN\033[0m %s\n' "$*"; }

say "TOML"
for T in config.toml data/*.toml; do
  if python3 -c "import tomllib,sys;tomllib.load(open(sys.argv[1],'rb'))" "$T" 2>/dev/null; then
    ok "$(basename "$T")"
  else
    bad "$T"
    python3 -c "import tomllib,sys;tomllib.load(open(sys.argv[1],'rb'))" "$T" 2>&1 | tail -2 | sed 's/^/         /'
  fi
done

# Keys placed after a [[table]] header belong to that table. They parse
# fine and render nothing — the trap that silently blanks a section.
say "Top-level keys"
python3 - <<'PY'
import tomllib, re, sys
EXPECTED = {
  "data/profile.toml": {"name","role","tagline","summary","location","email",
                        "email_href","github","github_url","resume_pdf"},
  "data/homelab.toml": {"intro"},
}
bad = False
for path, keys in EXPECTED.items():
    raw = open(path, encoding="utf-8").read()
    data = tomllib.load(open(path, "rb"))
    present = set(re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=", raw, re.M))
    missing = sorted((present & keys) - set(data.keys()))
    if missing:
        print(f"MISSING {path}: {','.join(missing)}"); bad = True
    else:
        print(f"OK {path}")
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] && ok "no keys swallowed by a table header" || bad "keys defined after a [[table]] header"

say "Zola"
zola check >/dev/null 2>&1 && ok "zola check" || { bad "zola check"; zola check 2>&1 | grep -iE 'error|warn' | head -5 | sed 's/^/         /'; }
zola build >/dev/null 2>&1 && ok "zola build" || { bad "zola build"; zola build 2>&1 | tail -5 | sed 's/^/         /'; }

say "Private data must not reach the build"
PRIVATE=( '000-000-0000' '(000) 000-0000' '0000000000' '00000' 'Example Town'
          'compensation' 'internal-note'
          'old-address' 'cfsbgone' )
for PAT in "${PRIVATE[@]}"; do
  HITS=$(grep -ril -- "$PAT" public/ 2>/dev/null | tr '\n' ' ')
  [ -n "$HITS" ] && bad "'$PAT' present in: $HITS" || ok "'$PAT' absent"
done

if [ -f public/carl-alcott-resume.pdf ] && command -v pdftotext >/dev/null; then
  PDFTEXT=$(pdftotext public/carl-alcott-resume.pdf - 2>/dev/null)
  for PAT in '000-0000' '00000' 'Example Town'; do
    grep -q -- "$PAT" <<<"$PDFTEXT" && bad "résumé PDF still contains '$PAT'" || ok "PDF clean of '$PAT'"
  done
else
  warn "résumé PDF not checked (missing file or pdftotext)"
fi

say "Housekeeping"
N=$(grep -rIn --exclude-dir=public --exclude-dir=.git --exclude-dir=scripts 'TODO' . 2>/dev/null | wc -l)
[ "$N" -gt 0 ] && warn "$N TODO marker(s)" || ok "no TODOs"
LEAKS=$(grep -rIn --exclude-dir=public --exclude-dir=.git --exclude-dir=scripts -e 'CHANGEME' -e '555-01' -e '203\.0\.113' . 2>/dev/null || true)
[ -n "$LEAKS" ] && { warn "placeholders:"; sed 's/^/         /' <<<"$LEAKS" | head -8; } || ok "no placeholders"
ok "base_url = $(grep -m1 '^base_url' config.toml | cut -d'"' -f2)"

echo
if [ "$FAIL" -ne 0 ]; then printf '\033[0;31mChecks FAILED — do not push.\033[0m\n'; exit 1
else printf '\033[0;32mAll checks passed.\033[0m\n'; fi
