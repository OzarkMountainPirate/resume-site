#!/usr/bin/env bash
# ── Pre-push checks — run before every commit ─────────────────────
# Validates the rendered output rather than the inputs: structure,
# internal links, and content constraints are asserted against the
# built site instead of assumed from the templates.
#
# The content gate matches classes of value rather than literals, so
# this file never has to name the things it excludes — and so it
# catches any phone number or postal address, not one known set.
# Extra project-specific literals can be supplied out of band via
# scripts/denylist.local (untracked, one string per line).
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

say "Content gate"

# Classes of value that must never appear in a published page. Matching
# on shape rather than on literals keeps the patterns meaningful in a
# public repository and catches cases nobody enumerated.
declare -A CLASS=(
  # Text pages only; the PDF is checked separately, as text and as bytes.
  ["a phone number"]='\(?[0-9]{3}\)?[-. ][0-9]{3}[-. ][0-9]{4}'
  ["a postal address"]='[0-9]+ +[A-Z][a-z]+ +(St|Street|Ave|Avenue|Rd|Road|Ln|Lane|Dr|Drive|Ct|Court)\b'
  ["a city-state-ZIP"]='[A-Za-z]+, *[A-Z]{2} *[0-9]{5}'
  ["compensation detail"]='(salary|compensation|pay range|[$][0-9]{2,3},?[0-9]{3})'
  ["an internal annotation"]='(_note\b|_internal\b|verification_)'
)
for NAME in "${!CLASS[@]}"; do
  HITS=$(grep -rIlE -- "${CLASS[$NAME]}" public/ 2>/dev/null | tr '\n' ' ')
  [ -n "$HITS" ] && bad "$NAME appears in: $HITS" || ok "no $NAME"
done

# Only this address may appear anywhere in the output.
ALLOWED_EMAIL=$(grep -m1 '^email ' data/profile.toml | cut -d'"' -f2)
STRAY=$(grep -rhoIE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' public/ 2>/dev/null \
        | grep -vF "$ALLOWED_EMAIL" | sort -u | tr '\n' ' ')
[ -n "$STRAY" ] && bad "unexpected address in output: $STRAY" || ok "only the published address appears"

# Optional out-of-band literals, never committed.
if [ -f scripts/denylist.local ]; then
  while read -r LINE; do
    [ -z "$LINE" ] && continue
    case "$LINE" in \#*) continue ;; esac
    grep -rqlIF -- "$LINE" public/ 2>/dev/null \
      && bad "a denylisted value reached the build output" \
      || ok "denylist entry absent"
  done < scripts/denylist.local
else
  warn "scripts/denylist.local absent — class checks only"
fi

# The published PDF is checked as bytes, not just as extracted text:
# hyperlink targets and metadata live outside the visible text layer.
if [ -f public/carl-alcott-resume.pdf ]; then
  for NAME in "a phone number" "a city-state-ZIP"; do
    if command -v pdftotext >/dev/null && \
       pdftotext public/carl-alcott-resume.pdf - 2>/dev/null | grep -qE -- "${CLASS[$NAME]}"; then
      bad "PDF text contains $NAME"
    else
      ok "PDF free of $NAME"
    fi
  done
  if [ -f scripts/denylist.local ]; then
    while read -r LINE; do
      [ -z "$LINE" ] && continue
      case "$LINE" in \#*) continue ;; esac
      grep -qaF -- "$LINE" public/carl-alcott-resume.pdf && bad "PDF bytes contain a denylisted value"
    done < scripts/denylist.local
    ok "PDF bytes checked against denylist"
  fi
else
  warn "résumé PDF not present"
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
