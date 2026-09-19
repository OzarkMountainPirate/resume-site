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

## 3. Tunnel ingress for SSH

Add to `/opt/containers/cloudflared/config.yml`, **above** the catch-all
`http_status:404` rule:

```yaml
  - hostname: resume.alcott.dev
    service: https://traefik
    originRequest:
      noTLSVerify: true

  - hostname: ssh.alcott.dev
    service: ssh://172.27.69.11:22
```

Then `docker compose -f /opt/containers/cloudflared/docker-compose.yml up -d`.
Restarting cloudflared briefly interrupts the other tunnel hostnames.

## 4. Cloudflare **(dashboard)**

- **DNS** — `CNAME resume.alcott.dev → <tunnel-id>.cfargotunnel.com`, proxied.
  Same for `ssh.alcott.dev`.
- **Zero Trust → Access → Applications** — add a self-hosted application for
  `ssh.alcott.dev`. Policy: **Service Auth**, matching one service token.
  Nothing else should satisfy the policy — no email rules, no bypass.
- **Zero Trust → Access → Service Auth** — create a service token. Its Client
  ID and Secret become the `CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET`
  GitHub secrets. The secret is shown once.

Without an Access policy in front of it, `ssh.alcott.dev` would expose sshd to
anyone who resolves the name. The policy is the control, not the obscurity of
the hostname.

## 5. Bring up the site

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
curl -sS -H 'Host: resume.alcott.dev' -k https://172.27.69.11/ | head -5

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
