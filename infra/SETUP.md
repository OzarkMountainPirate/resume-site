# Host setup — styx

One-time provisioning for `resume.alcott.dev`. Steps marked **(dashboard)**
happen in Cloudflare and can't be scripted from here.

## 1. Dataset, document root, and deploy user

Every container on styx gets its own ZFS dataset — never a plain directory
inside `tank/containers`. That keeps the teardown path to `compose down -v`
plus one `zfs destroy`, and lets snapshot policy be set per workload.

```bash
sudo zfs create -o recordsize=16K -o quota=1G tank/containers/resume
sudo install -d -m 755 /opt/containers/resume/site
```

**Why these properties**, evaluated against what this dataset actually holds:

| property | value | reasoning |
|---|---|---|
| `recordsize` | `16K` | The webroot is many small files — HTML pages around 8–20K, CSS ~6K, SVG under 1K. Nothing benefits from the 128K default, and it matches the small-record convention already used for bookstack, crowdsec, and joplin. |
| `quota` | `1G` | Hygiene. The content is ~200K; a quota three orders of magnitude above that still catches a runaway deploy before it touches the pool. |
| `compression` | inherited `lz4` | The content is entirely text — HTML, CSS, SVG, XML. Compresses well and the parent already sets it. |
| `atime` | inherited `off` | nginx reads every file on every request. Writing access times for that is pure waste. |
| `sync` | default `standard` | Left alone. `rsync` does not fsync per file by default, so `sync=disabled` would buy little here and is not worth the durability tradeoff. |

**Exclude it from Sanoid.** The webroot is derived data — every byte is
reproducible from git by one CI run — so snapshotting it 36 times a day
retains nothing of value. This matches the existing treatment of
`elastic/esdata` and `pihole-ftl`. Add to `/etc/sanoid/sanoid.conf`:

```ini
[tank/containers/resume]
	use_template = exclude
```

Then the deploy user — unprivileged, no password:

```bash
sudo useradd --system --create-home --shell /bin/bash deploy
sudo chown -R deploy:deploy /opt/containers/resume/site
```

## 2. Restrict the deploy key

`rrsync` ships with rsync and confines a key to one directory. On styx it is
at `/usr/bin/rrsync`. Pin the key to a write-only session inside the document
root:

```bash
sudo install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
sudo tee /home/deploy/.ssh/authorized_keys >/dev/null <<'EOF'
restrict,command="/usr/bin/rrsync -wo /opt/containers/resume/site" ssh-ed25519 AAAA...REPLACE... github-actions-deploy
EOF
sudo chmod 600 /home/deploy/.ssh/authorized_keys
sudo chown deploy:deploy /home/deploy/.ssh/authorized_keys
```

`restrict` disables port, agent, and X11 forwarding plus PTY allocation.
`-wo` makes the transfer write-only: the key can push files into the document
root and cannot read elsewhere, run a shell, or escape the path.

Generate the pair on a trusted machine, never on the runner:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/styx_deploy -C github-actions-deploy -N ''
# ~/.ssh/styx_deploy      → GitHub secret STYX_SSH_KEY
# ~/.ssh/styx_deploy.pub  → the authorized_keys line above
```

Load the private half into GitHub without it touching a shell history:

```bash
gh secret set STYX_SSH_KEY --repo OzarkMountainPirate/resume-site < ~/.ssh/styx_deploy
```

## 3. Tunnel routes — dashboard, not config.yml

This tunnel is **remotely managed**: its routes come from the Cloudflare
dashboard, and the `ingress:` block in
`/opt/containers/cloudflared/config.yml` is ignored. Editing that file has no
effect and will mislead whoever reads it next.

Add routes under **Zero Trust → Networks → Tunnels → <tunnel> → Public
Hostname**. Adding one there creates the DNS record automatically — there is
no separate DNS step.

| Subdomain | Type | URL |
|---|---|---|
| `resume` | HTTPS | `https://traefik` (TLS verification off) |
| *(deploy channel — see below)* | SSH | `<host-lan-ip>:22` |

**The deploy hostname is deliberately not recorded here.** It is an opaque
label, not `ssh` or any other word a subdomain scanner would try, and it lives
only in the `STYX_SSH_HOST` GitHub secret. Nothing types it by hand, so there
is no cost to it being unguessable.

This is worth doing because the zone's certificates are wildcards: individual
subdomains never appear in Certificate Transparency logs, so dictionary
brute-forcing is the only realistic way to find one. A name that is not in a
wordlist defeats that. It is defence in depth, not the control — the Access
policy is the control.

## 4. Cloudflare Access for the SSH route **(dashboard)**

Order matters — create the token first so the policy can reference it.

1. **Zero Trust → Access → Service Auth → Create Service Token.** Name it for
   the job (e.g. `github-actions-resume-deploy`). The Client Secret is shown
   **once**; capture it now.
2. **Zero Trust → Access → Applications → Add → Self-hosted.**
2b. Application domain: the opaque hostname from step 3, never a guessable one.

3. Add one policy, and set its **Action to `Service Auth`** — not `Allow`.
   `Allow` expects an interactive identity and will not accept a token
   non-interactively. Include: **Service Token** → the token from step 1.
4. Delete any other policy on the application, including bypass rules. The
   policy is the only thing standing in front of `sshd`; a second rule that
   matches more broadly silently widens the door.

## 5. Bring up the site## 5. Bring up the site

```bash
cd /opt/containers/resume
docker compose up -d
docker compose logs -f resume
```

Teardown, if it ever comes to that, is two commands and leaves nothing behind:

```bash
docker compose down -v
sudo zfs destroy tank/containers/resume
```

Traefik picks the router up from the container labels. TLS comes from the
existing `cloudflare` resolver's wildcard for `*.alcott.dev`, so no new
certificate work is needed.

## 6. Verify

```bash
# From the LAN, bypassing Cloudflare:
curl -sS -H 'Host: resume.alcott.dev' -k https://<host-lan-ip>/ | head -5

# End to end:
curl -sSI https://resume.alcott.dev | head -12

# Confirm the security chain is actually attached, not silently dropped:
#   Traefik dashboard → HTTP → Routers → resume
#   should list middleware `security-chain@file`
```

## 7. Turn the deploy on

Only after the above passes: set repo variable `DEPLOY_ENABLED=true`.

```bash
gh variable set DEPLOY_ENABLED --body true --repo OzarkMountainPirate/resume-site
```
