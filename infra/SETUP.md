# Host setup — styx

One-time provisioning for `resume.alcott.dev`. Steps marked **(dashboard)**
happen in Cloudflare and can't be scripted from here.

## 1. Document root and deploy user

```bash
sudo install -d -m 755 /opt/containers/resume
sudo install -d -m 755 /opt/containers/resume/site

# Unprivileged, no password, no login shell beyond what rsync needs.
sudo useradd --system --create-home --shell /bin/bash deploy
sudo chown -R deploy:deploy /opt/containers/resume/site
```

## 2. Restrict the deploy key

`rrsync` ships with rsync and confines a key to one directory. Find it, then
pin the key to a write-only session inside the document root:

```bash
RRSYNC=$(ls /usr/bin/rrsync /usr/share/rsync/scripts/rrsync 2>/dev/null | head -1)

sudo install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
sudo tee /home/deploy/.ssh/authorized_keys >/dev/null <<EOF
restrict,command="$RRSYNC -wo /opt/containers/resume/site" ssh-ed25519 AAAA...  github-actions-deploy
EOF
sudo chmod 600 /home/deploy/.ssh/authorized_keys
sudo chown deploy:deploy /home/deploy/.ssh/authorized_keys
```

`restrict` disables port, agent, and X11 forwarding plus PTY allocation.
`-wo` makes the transfer write-only: the key can push files into the document
root and cannot read elsewhere, run a shell, or escape the path.

Generate the pair on a trusted machine, not on the runner:

```bash
ssh-keygen -t ed25519 -f ./styx_deploy -C github-actions-deploy -N ''
# ./styx_deploy      → GitHub secret STYX_SSH_KEY
# ./styx_deploy.pub  → the authorized_keys line above
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
