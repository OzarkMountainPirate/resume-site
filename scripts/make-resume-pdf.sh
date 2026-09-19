#!/usr/bin/env bash
# ── Build the public résumé PDF ───────────────────────────────────
# The source .docx carries a phone number and a home town of ~100
# people. Neither belongs on a public page, so the web PDF is built
# from a sanitized copy rather than converted directly.
#
# Usage:  ./scripts/make-resume-pdf.sh /path/to/source.docx
#
# Output: static/carl-alcott-resume.pdf
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:?usage: make-resume-pdf.sh <source.docx>}"
[ -f "$SRC" ] || { echo "no such file: $SRC" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

python3 - "$SRC" "$TMP/resume-web.docx" <<'PY'
import zipfile, re, sys
src, dst = sys.argv[1], sys.argv[2]
zin = zipfile.ZipFile(src)
x = zin.read('word/document.xml').decode('utf8')
REL = 'word/_rels/document.xml.rels'
rels = zin.read(REL).decode('utf8')

# The source .docx displays carl@arcfob.space but still LINKS to the old
# old-address@example.com address. Repoint every mailto at the live mailbox.
rels = re.sub(r'Target="mailto:[^"]*"', 'Target="mailto:carl@arcfob.space"', rels)

# Town + ZIP, and the bare town on the current-role line -> region only.
x = re.sub(r'(<w:t[^>]*>)Example Town, ST 00000(</w:t>)', r'\1Lake of the Ozarks, MO\2', x)
x = re.sub(r'(<w:t[^>]*>[^<]*?)Example Town, ST(</w:t>)', r'\1Lake of the Ozarks, MO\2', x)

# Phone: drop the run and the one bullet separator in front of it.
x = re.sub(r'(<w:t[^>]*>)\(816\) 000-0000(</w:t>)', r'\1@@PHONE@@\2', x)
x = re.sub(r'<w:r\b(?:(?!</w:r>).)*?<w:t[^>]*>\s*•\s*</w:t>.*?</w:r>'
           r'(?=(?:(?!</w:r>).)*?@@PHONE@@)', '', x, count=1, flags=re.S)
x = re.sub(r'<w:r\b(?:(?!</w:r>).)*?@@PHONE@@.*?</w:r>', '', x, count=1, flags=re.S)

with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as zout:
    for it in zin.infolist():
        if it.filename == 'word/document.xml':
            payload = x.encode('utf8')
        elif it.filename == REL:
            payload = rels.encode('utf8')
        else:
            payload = zin.read(it.filename)
        zout.writestr(it, payload)
zin.close()
PY

soffice --headless --convert-to pdf --outdir "$TMP" "$TMP/resume-web.docx" >/dev/null 2>&1
install -m 644 "$TMP/resume-web.pdf" static/carl-alcott-resume.pdf

# Refuse to ship a PDF that still carries anything private.
if command -v pdftotext >/dev/null; then
  TEXT="$(pdftotext static/carl-alcott-resume.pdf - 2>/dev/null)"
  for PAT in '000-0000' '00000' 'Example Town' 'old-address'; do
    if grep -q "$PAT" <<<"$TEXT" || grep -qa "$PAT" static/carl-alcott-resume.pdf; then
      echo "FAIL: '$PAT' still present in the built PDF" >&2
      rm -f static/carl-alcott-resume.pdf; exit 1
    fi
  done
  echo "==> static/carl-alcott-resume.pdf  (sanitized, verified)"
else
  echo "==> static/carl-alcott-resume.pdf  (pdftotext absent — NOT verified)" >&2
fi
