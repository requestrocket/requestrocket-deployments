# Deploying the RequestRocket data plane with Podman

This guide covers the changes needed to run the RequestRocket data plane using Podman and `podman-compose` instead of Docker. It is a companion to the main [deployment guide](deployment-guide.md). Follow that guide for the full walkthrough — this document only describes what to do differently.

The instructions below were tested on Oracle Linux 9 (x86_64) with Podman 4.x and `podman-compose`. They apply to any RHEL 9 derivative (AlmaLinux, Rocky Linux) and Fedora with minor path differences.

This guide assumes **rootless Podman** — all commands run as a regular (non-root) user. No `sudo` is needed for Podman itself.

---

## 1. Prerequisites

Replace the Docker prerequisites with:

| Docker requirement | Podman equivalent |
|---|---|
| Docker 23.0+ and Docker Compose v2 | `podman` and `podman-compose` |
| `docker buildx` | `skopeo` (for registry digest comparison) |
| Docker credential store | Not required — the image is public |

Install packages (this step does require `sudo`):

```bash
sudo dnf install -y podman podman-compose skopeo aardvark-dns jq util-linux
```

`flock` and `timeout` are in `util-linux`, which is installed by default. `aardvark-dns` provides DNS resolution between containers on user-defined networks — without it, the data plane cannot find MongoDB by hostname.

### Rootless networking

Podman 4.x on Oracle Linux 9 uses **netavark** as the default network backend. Rootless containers on a user-defined bridge network get inter-container DNS via `aardvark-dns` automatically. The default `podman` network does **not** have DNS — only named networks created by the user (or by compose) do.

### Lingering user session

Rootless containers stop when the user logs out unless **linger** is enabled. Enable it so the data plane survives a disconnected SSH session:

```bash
loginctl enable-linger $(whoami)
```

Verify:

```bash
loginctl show-user $(whoami) --property=Linger
```

The output should be `Linger=yes`.

---

## 2. Registry authentication

The `ghcr.io/requestrocket/data-plane` image is public. No login is required. Skip section 3 of the main deployment guide entirely.

If a previous login attempt left stale credentials:

```bash
podman logout ghcr.io
```

---

## 3. Enable the Podman user socket

Traefik discovers containers through a Docker-compatible API socket. Rootless Podman provides a per-user socket, but it is disabled by default.

```bash
systemctl --user enable --now podman.socket
```

Verify:

```bash
ls -la $XDG_RUNTIME_DIR/podman/podman.sock
```

`$XDG_RUNTIME_DIR` is typically `/run/user/$(id -u)`. The socket is owned by your user — no root required.

If `$XDG_RUNTIME_DIR` is not set (e.g. in a cron job or a non-login shell), use the explicit path:

```bash
ls -la /run/user/$(id -u)/podman/podman.sock
```

---

## 4. Compose file changes

The shipped compose files are written for Docker. Several changes are needed. **Do not modify the originals** — copy them and edit the copies, or apply the changes inline.

### 4a. Traefik socket mount

In `docker-compose.yml`, change the Traefik volume mount from:

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock:ro
```

to:

```yaml
volumes:
  - ${XDG_RUNTIME_DIR}/podman/podman.sock:/var/run/docker.sock:ro,z
```

This maps the rootless Podman socket to the path Traefik expects inside the container. The `:z` suffix adds the SELinux `container_file_t` label so the container can read it.

If your shell does not expand `$XDG_RUNTIME_DIR` in YAML, use the literal path instead:

```yaml
volumes:
  - /run/user/1000/podman/podman.sock:/var/run/docker.sock:ro,z
```

Replace `1000` with the output of `id -u`.

### 4b. Published port

Rootless Podman cannot bind to ports below 1024 without extra configuration. The default compose file publishes port 80. Change it to a high port:

```yaml
ports:
  - "8080:80"
```

Callers reach the data plane on port 8080 instead of 80. Set `publicUrl` in `config.json` to the URL callers actually use (e.g. `https://data-plane.example.com:8080`, or the HTTPS URL of a load balancer that terminates TLS and forwards to 8080).

Alternatively, to keep port 80, lower the unprivileged port floor system-wide (requires `sudo` once):

```bash
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
echo "net.ipv4.ip_unprivileged_port_start=80" | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf
```

### 4c. SELinux labels on bind mounts

Every `:ro` bind mount needs `:ro,z` so SELinux allows the container to read the file. Apply this in `docker-compose.yml`, `docker-compose.blue.yml`, and `docker-compose.green.yml`.

In addition to the compose file changes, relabel the host files that are bind-mounted or referenced by Docker secrets **before the first start**:

```bash
chcon -t container_file_t config.json
chcon -t container_file_t secrets/private_key.pem secrets/api_key traefik/traefik.yml
```

The `:z` mount option tells Podman to relabel on container start, but secrets are mounted through a different path (`/run/secrets/`) and may not pick up the label automatically. Running `chcon` up front covers both cases. The label persists until `restorecon` is run on the file.

**`docker-compose.yml` — traefik service:**

```yaml
volumes:
  - ${XDG_RUNTIME_DIR}/podman/podman.sock:/var/run/docker.sock:ro,z
  - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro,z
```

**`docker-compose.yml` — data-plane service:**

```yaml
volumes:
  - ./config.json:/app/config.json:ro,z
```

**`docker-compose.blue.yml` — data-plane-blue service:**

```yaml
volumes:
  - ./config.json:/app/config.json:ro,z
```

**`docker-compose.green.yml` — data-plane-green service:**

```yaml
volumes:
  - ./config.json:/app/config.json:ro,z
```

Use lowercase `z`, not uppercase `Z`. Lowercase marks the file as shared — both the blue and green containers can read `config.json` during a blue-green swap. Uppercase `Z` is a private label and would block the second container.

### 4d. TLS on Traefik (if used)

If you configured TLS termination on Traefik (Option B in the main guide), add `:z` to the certificate and dynamic config mounts as well:

```yaml
volumes:
  - ${XDG_RUNTIME_DIR}/podman/podman.sock:/var/run/docker.sock:ro,z
  - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro,z
  - ./traefik/dynamic:/etc/traefik/dynamic:ro,z
  - ./traefik/certs:/etc/traefik/certs:ro,z
```

---

## 5. First start

```bash
export IMAGE_TAG="$(jq -r '.imageTag // "latest"' config.json)"
podman-compose up -d
```

No `sudo`. Check that all three containers are running:

```bash
podman ps
```

You should see `traefik`, `mongo`, and `data-plane`. Test the health endpoint:

```bash
curl http://localhost:8080/health
```

(Use port 80 instead if you lowered the unprivileged port floor.)

A healthy response has `"status": "ok"`.

### If mongo exits immediately

Check its logs:

```bash
podman logs mongo
```

The most common cause on Oracle Linux 9 is the `mongo:7` image needing AVX support. If the CPU does not have it (some cloud VMs disable it), use `mongo:5` instead.

### If the health check stays at "starting"

Podman may hold the container in `starting` status longer than Docker because it requires multiple consecutive successful probes. The data plane can be healthy and serving traffic while the status still says `starting`. Check directly:

```bash
podman exec data-plane wget -qO- http://localhost:3000/health
```

If that returns `{"status":"ok"}`, the container is working. The healthcheck status will catch up after the full probe cycle completes (up to 45 seconds with the default interval and retries).

### If containers land on the default network

`podman-compose` sometimes does not create or attach to the named `dataplane-net` network. If `podman network ls` shows `dataplane-net` exists but `podman inspect mongo` shows the container on the `podman` default network, create the network manually first:

```bash
podman-compose down
podman network create dataplane-net
podman-compose up -d
```

DNS only works on user-defined networks, not on the default `podman` bridge.

---

## 6. Script changes for automatic updates

`update.sh` and `deploy.sh` use Docker CLI commands. To use them with Podman, the following substitutions are needed. These are listed here as a reference — make the edits in your local copies.

### 6a. `update.sh` — replace `docker buildx` with `skopeo`

`update.sh` uses `docker buildx imagetools inspect` and `docker manifest inspect` to read the registry digest. Podman does not have buildx. Replace both with `skopeo`:

**Replace the buildx version check** (around line 20):

```bash
# Original:
# if ! docker buildx version >/dev/null 2>&1; then ...

# Podman replacement:
if ! command -v skopeo >/dev/null 2>&1; then
  echo "ERROR: skopeo is required for digest comparison"
  echo "Install it with: sudo dnf install skopeo"
  exit 1
fi
```

**Replace the digest lookup** (around lines 40–70):

```bash
# Original uses docker buildx imagetools inspect and docker manifest inspect.

# Podman replacement using skopeo:
REMOTE_DIGEST="$(timeout 60 skopeo inspect --format '{{.Digest}}' "docker://${IMAGE}" 2>/dev/null || true)"
if [ -z "$REMOTE_DIGEST" ] || [ "$REMOTE_DIGEST" = "null" ]; then
  echo "ERROR: could not read a registry digest for ${IMAGE}"
  exit 1
fi
REMOTE_DIGESTS="$REMOTE_DIGEST"
```

**Replace `docker` commands with `podman`** throughout the rest of the file:

| Original | Replacement |
|---|---|
| `docker ps` | `podman ps` |
| `docker inspect` | `podman inspect` |
| `docker image inspect` | `podman image inspect` |
| `docker pull` | `podman pull` |

### 6b. `deploy.sh` — replace `docker` with `podman`

| Original | Replacement |
|---|---|
| `docker inspect` | `podman inspect` |
| `docker ps` | `podman ps` |
| `docker compose -f` | `podman-compose -f` |
| `docker compose stop` | `podman-compose stop` |
| `docker compose rm` | `podman-compose rm` |

The health check format string is the same:

```bash
podman inspect --format='{{.State.Health.Status}}' "$container"
```

### 6c. Increase health check retries

Podman can take longer to transition from `starting` to `healthy`. In `deploy.sh`, increase `HEALTH_RETRIES` from `20` to `30`:

```bash
HEALTH_RETRIES=30
```

This extends the wait from about 60 seconds to about 90 seconds, which accommodates Podman's stricter probe counting.

---

## 7. Systemd timer

Because the data plane runs rootless, the timer must be a **user** unit so it runs as the same user that owns the containers.

### 7a. Update the service unit

The shipped `requestrocket-update.service` has:

```ini
After=docker.service
Requires=docker.service
```

Change both to:

```ini
After=podman.socket
Requires=podman.socket
```

Also update the paths if your install directory is not `/opt/requestrocket`.

### 7b. Install as user units

Copy the units into your user systemd directory (not the system directory):

```bash
mkdir -p ~/.config/systemd/user
cp systemd/requestrocket-update.service ~/.config/systemd/user/
cp systemd/requestrocket-update.timer ~/.config/systemd/user/
```

Enable and start:

```bash
systemctl --user daemon-reload
systemctl --user enable --now requestrocket-update.timer
systemctl --user list-timers requestrocket-update.timer
```

These units run as your user and have access to your rootless Podman socket. They survive logout because linger is enabled (see section 1).

### 7c. Cron alternative

If using cron instead of systemd timers, the cron job must run as the same user (not root) and must have `XDG_RUNTIME_DIR` set:

```bash
0 * * * * XDG_RUNTIME_DIR=/run/user/$(id -u) cd /opt/requestrocket && timeout 600 ./update.sh >> /var/log/requestrocket-update.log 2>&1
```

---

## 8. Summary of all changes

| File | What to change |
|---|---|
| `docker-compose.yml` | Traefik socket: `${XDG_RUNTIME_DIR}/podman/podman.sock:/var/run/docker.sock:ro,z`. Add `:z` to all `:ro` bind mounts. Change published port from `80:80` to `8080:80` (or lower the unprivileged port floor) |
| `docker-compose.blue.yml` | Add `:z` to config.json bind mount |
| `docker-compose.green.yml` | Add `:z` to config.json bind mount |
| `update.sh` | Replace `docker buildx` check with `skopeo` check. Replace digest lookup with `skopeo inspect`. Replace all `docker` commands with `podman` |
| `deploy.sh` | Replace all `docker` / `docker compose` with `podman` / `podman-compose`. Increase `HEALTH_RETRIES` to `30` |
| `systemd/requestrocket-update.service` | Change `After=` and `Requires=` from `docker.service` to `podman.socket`. Install as a user unit, not a system unit |
| System | `sudo dnf install podman podman-compose skopeo aardvark-dns`. `loginctl enable-linger`. `systemctl --user enable --now podman.socket` |

No changes are needed to `traefik/traefik.yml`, `config.json`, or the data plane image itself.

---

## 9. Troubleshooting

| What you see | Cause | Fix |
|---|---|---|
| `EACCES` on `/app/config.json` | SELinux denying bind mount | Add `:z` to the volume mount, or run `chcon -t container_file_t config.json` |
| `ENOTFOUND` for `mongo` | Containers not on the same named network, or `aardvark-dns` missing | `sudo dnf install aardvark-dns`, then `podman-compose down && podman-compose up -d` |
| `statfs /run/docker.sock: no such file or directory` | Podman socket not enabled or wrong mount path | `systemctl --user enable --now podman.socket` and mount `${XDG_RUNTIME_DIR}/podman/podman.sock` |
| Traefik starts but does not route | Traefik cannot see containers via the socket | Confirm `podman.socket` is active: `systemctl --user status podman.socket` |
| Health check never leaves `starting` | Podman requires multiple consecutive successful probes | Increase `HEALTH_RETRIES` in `deploy.sh`. Check health directly: `podman exec data-plane wget -qO- http://localhost:3000/health` |
| `update.sh` fails at buildx check | Podman has no buildx | Replace with `skopeo` as described in section 6a |
| `podman-compose up` creates containers on default network | `podman-compose` did not honour the named network | Run `podman network create dataplane-net` manually before `podman-compose up -d` |
| Containers stop after SSH logout | Linger not enabled for the user | `loginctl enable-linger $(whoami)` |
| `Error: rootlessport cannot expose privileged port 80` | Rootless Podman cannot bind to ports below 1024 | Change the published port to 8080 or lower the floor with `sysctl net.ipv4.ip_unprivileged_port_start=80` |
| Timer does not fire after logout | Timer installed as a system unit instead of a user unit | Move to `~/.config/systemd/user/` and enable with `systemctl --user` |

---

## 10. Support

Contact RequestRocket support if you need help adapting the deployment to Podman, or if the data plane image does not start on your platform.
