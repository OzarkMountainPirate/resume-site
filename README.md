# resume-site

The source and deployment pipeline for [resume.alcott.dev](https://resume.alcott.dev).

A [Zola](https://www.getzola.org/) static site. Content lives in `data/*.toml`;
templates only render it. No JavaScript, no build step beyond Zola, no runtime.

## Why it is built this way

The site is served from a host with **no inbound path from the internet**. That
constraint drives the whole design:

```
  GitHub Actions ──► Cloudflare Access ──► Cloudflare Tunnel ──► sshd
       (build)        (service token)        (outbound only)      │
                                                                  ▼
                                                        rrsync ──► docroot
                                                                  │
  visitor ──► Cloudflare ──► Tunnel ──► Traefik ──► nginx ◄────────┘
                                          │
                              CrowdSec · rate limit · security headers
```

Nothing listens on a public port. The tunnel dials out; Cloudflare Access
authenticates the deploy with a service token before a packet reaches `sshd`;
and the key that arrives is pinned to a single `rrsync` command, so it can
write the document root and do nothing else.

## Layout

```
config.toml          base_url, Zola settings
content/             one markdown file per page, front matter only
data/
  profile.toml       identity — scalars only
  experience.toml    [[jobs]]
  projects.toml      [[projects]]
  skills.toml        [[groups]]
  homelab.toml       [[systems]] — current infrastructure
  credentials.toml   certifications, education, involvement
  navigation.toml    [[links]]
templates/           base + one per page type, partials/ for shared fragments
sass/style.scss      one flat stylesheet
infra/               the Styx side: nginx container and its config
scripts/
  check.sh           run before every push
  make-resume-pdf.sh builds the public PDF from a private source .docx
```

## Working on it

```bash
zola serve            # preview at 127.0.0.1:1111
./scripts/check.sh    # before committing
```

## Rules that exist for a reason

- **`public/` is gitignored.** Zola regenerates it on every build.
- **Top-level keys in `data/*.toml` must sit above any `[[table]]` header.**
  TOML assigns keys written after a table header *to that table*, so a
  misplaced key parses cleanly and renders nothing. `check.sh` catches it.
- **The published PDF is generated, not committed by hand.**
  `scripts/make-resume-pdf.sh` derives it from a source document, so the
  published copy is reproducible and the pipeline stays the single source
  of truth.
- **`check.sh` validates the build output, not the inputs.** Structure,
  internal links, and content constraints are asserted against the
  rendered site rather than assumed from the templates. CI runs it
  before the deploy step.
- **Deploy triggers on `push` to `main` only.** This repository is public. A
  `pull_request` trigger would hand fork branches a path to the deploy secrets.

## Licence

Site content and résumé text © Carl Alcott. The templates, stylesheet,
tooling, and deployment configuration are MIT — take anything useful.
