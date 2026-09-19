#!/usr/bin/env bash
# ── Build the published résumé PDF ────────────────────────────────
# The published PDF is derived from a source document rather than
# committed by hand, so the pipeline stays the single source of truth
# and the published copy is reproducible.
#
# Substitutions are defined in scripts/redactions.conf, which is not
# tracked. See redactions.conf.example for the format.
#
# Usage:  ./scripts/make-resume-pdf.sh <source.docx>
# Output: static/carl-alcott-resume.pdf
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:?usage: make-resume-pdf.sh <source.docx>}"
CONF="${REDACTIONS_CONF:-scripts/redactions.conf}"
[ -f "$SRC" ]  || { echo "no such file: $SRC" >&2; exit 1; }
[ -f "$CONF" ] || { echo "missing $CONF — copy redactions.conf.example and fill it in" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

python3 - "$SRC" "$TMP/out.docx" "$CONF" <<'PY'
import zipfile, re, sys

src, dst, conf = sys.argv[1], sys.argv[2], sys.argv[3]
rules = {"text": [], "drop": [], "mailto": None}
for line in open(conf, encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    kind, _, rest = line.partition(" ")
    rest = rest.strip()
    if kind == "text" and "|" in rest:
        rules["text"].append(tuple(rest.split("|", 1)))
    elif kind == "drop":
        rules["drop"].append(rest)
    elif kind == "mailto":
        rules["mailto"] = rest

zin = zipfile.ZipFile(src)
doc = zin.read("word/document.xml").decode("utf8")
REL = "word/_rels/document.xml.rels"
rels = zin.read(REL).decode("utf8")

for find, repl in rules["text"]:
    doc = re.sub(rf"(<w:t[^>]*>[^<]*?){re.escape(find)}", rf"\1{repl}", doc)

for i, target in enumerate(rules["drop"]):
    tok = f"@@DROP{i}@@"
    doc = re.sub(rf"(<w:t[^>]*>){re.escape(target)}(</w:t>)", rf"\1{tok}\2", doc)
    # Remove the separator run immediately preceding it, then the run itself.
    doc = re.sub(rf"<w:r\b(?:(?!</w:r>).)*?<w:t[^>]*>\s*[·•]\s*</w:t>.*?</w:r>"
                 rf"(?=(?:(?!</w:r>).)*?{tok})", "", doc, count=1, flags=re.S)
    doc = re.sub(rf"<w:r\b(?:(?!</w:r>).)*?{tok}.*?</w:r>", "", doc, count=1, flags=re.S)

if rules["mailto"]:
    rels = re.sub(r'Target="mailto:[^"]*"', f'Target="mailto:{rules["mailto"]}"', rels)

with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
    for it in zin.infolist():
        if it.filename == "word/document.xml":
            payload = doc.encode("utf8")
        elif it.filename == REL:
            payload = rels.encode("utf8")
        else:
            payload = zin.read(it.filename)
        zout.writestr(it, payload)
zin.close()
PY

soffice --headless --convert-to pdf --outdir "$TMP" "$TMP/out.docx" >/dev/null 2>&1
install -m 644 "$TMP/out.pdf" static/carl-alcott-resume.pdf

# Refuse to publish if any denied string survived into the output.
if command -v pdftotext >/dev/null; then
  TEXT="$(pdftotext static/carl-alcott-resume.pdf - 2>/dev/null)"
  FAILED=0
  while read -r kind rest; do
    [ "$kind" = "deny" ] || continue
    if grep -qF "$rest" <<<"$TEXT" || grep -qaF "$rest" static/carl-alcott-resume.pdf; then
      echo "refusing to publish: a denied value survived into the PDF" >&2
      FAILED=1
    fi
  done < <(grep -v '^[[:space:]]*#' "$CONF")
  [ "$FAILED" -eq 0 ] || { rm -f static/carl-alcott-resume.pdf; exit 1; }
  echo "==> static/carl-alcott-resume.pdf  (verified)"
else
  echo "==> static/carl-alcott-resume.pdf  (pdftotext absent — not verified)" >&2
fi
