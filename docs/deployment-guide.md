# RequestRocket edge data plane

This guide is for installing the RequestRocket data plane on a server you operate. This repository contains the Compose files, Traefik configuration, and the update scripts. The data plane itself is a container image pulled from `ghcr.io/requestrocket/data-plane`. No application source is included.

Every connection to RequestRocket is outbound from your host. The control plane does not open a connection to the data plane, and it does not need to know the host's address.

### Outbound network access

The host needs outbound HTTPS (port 443) to the following:

| Destination | Purpose |
|---|---|
| `api.requestrocket.com` | Control plane -- configuration sync and telemetry forwarding |
| `ghcr.io` | Container registry -- image pulls and digest checks |
| `*.requestrocket.com` | MCP discovery endpoints (e.g. `mcp.requestrocket.com`) |
| Your upstream APIs | The third-party APIs your proxies call on behalf of callers |

If your network uses an allowlist, add all of the above. The data plane does not require any inbound connections from RequestRocket.

---

## 1. Prerequisites

- Docker and Docker Compose v2 (Docker 23.0 or later)
- `docker buildx` (bundled since Docker 23.0; used by `update.sh` for digest comparison)
- `jq`, `flock`, and `timeout` (present on a typical systemd Linux host)
- The registry username and token RequestRocket sent you
- An RSA key pair you generate (see below)
- A deployment created in the RequestRocket app (see below)

A single Linux host is enough for a first deployment. Docker Desktop on macOS or Windows can run the containers; the hourly timer examples below are for systemd and cron.

### Hardware

| Resource | Minimum | Recommended |
|---|---|---|
| CPU | 2 cores | 4 cores |
| RAM | 2 GB | 4 GB |
| Disk | 10 GB | 20 GB+ (scales with request history) |
| Network | Outbound HTTPS to `ghcr.io` and the control plane | Same |

MongoDB uses about half of available RAM for its cache. At 2 GB total it is functional but slow under load. At 4 GB it has a usable cache alongside the data plane and Traefik. During a blue-green swap two data plane images exist on disk at once (roughly 500 MB each).

---

## 2. Generate a key pair and create a deployment

The data plane holds a private key that only it can read. The control plane holds the matching public key. Credential secrets synced to the data plane are encrypted with the public key so only the data plane can decrypt them.

### Generate an RSA key pair

The key must be RSA, at least 2048 bits. Run this on the machine where you will store the private key, or on any trusted workstation:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out private_key.pem
openssl rsa -in private_key.pem -pubout -out public_key.pem
chmod 600 private_key.pem
```

**The private key cannot be recovered.** RequestRocket stores only the public half. If the private key is lost:

- The data plane cannot decrypt credential secrets synced from the control plane. Proxies that inject credentials into upstream calls will stop working.
- A replacement deployment on new infrastructure cannot use the same key pair. You would need to create a new deployment, generate a new key pair, and reconfigure all proxies, credentials, and rules that referenced the old deployment.
- Request history and telemetry stored locally in MongoDB cannot be re-associated with the new deployment.

Store `private_key.pem` in a secure, backed-up location (a secrets manager, an encrypted vault, or offline media) in addition to the `secrets/` directory on the host. Treat it with the same care as a TLS private key or a database master password.

You will place a copy of `private_key.pem` in the `secrets/` directory in step 4. The `public_key.pem` file is submitted to RequestRocket in the next step and can be discarded after that.

### Create a deployment in RequestRocket

1. Log in to the RequestRocket app.
2. Navigate to **Deployments** under your client.
3. Click **Create Deployment**.
4. Give the deployment a name and paste the contents of `public_key.pem` into the public key field.
5. After creation, note the **deployment ID** and the **control plane API key** shown on the deployment page. You will need both for `config.json` and the `secrets/` directory.

---

## 3. Authenticate to the container registry

```bash
docker login ghcr.io -u <your-username> -p <token-provided-by-requestrocket>
```

Automatic updates run when nobody is logged in, including after a reboot. The Docker credential store has to keep this login. Use a [credential helper](https://docs.docker.com/engine/reference/commandline/login/#credential-helpers), or confirm that `~/.docker/config.json` still contains the token after a restart.

If the token expires, the update script logs a manifest error and leaves the running container alone. Log in again and the next hourly check will continue.

---

## 4. Configure the deployment

From the package directory:

```bash
cp config.example.json config.json
```

| Field | What to put |
|---|---|
| `controlPlaneBase` | Base URL RequestRocket gave you, such as `https://api.requestrocket.com` |
| `clientId` | Your RequestRocket client ID |
| `deploymentId` | The deployment ID from the RequestRocket app |
| `publicUrl` | The URL your callers use to reach this host. The data plane reports it to the control plane |
| `pollIntervalMs` | How often to sync configuration, in milliseconds. Default `30000` |
| `mongodbUri` | MongoDB connection string. Default `mongodb://mongo:27017/dataplane` uses the bundled database |
| `port` | Port the data plane listens on inside the Docker network. Default `3000`. Callers do not use this port; Traefik does |
| `nodeEnv` | `production` |
| `imageTag` | Which published image to track. `latest` is production. `qas` and `dev` are the other channels. Default `latest` |

`imageTag` must match the control plane you set in `controlPlaneBase`. A deployment talking to the production API tracks `latest`. A deployment talking to QAS tracks `qas`. A deployment talking to dev tracks `dev`. The three tags are updated independently when RequestRocket publishes that stage.

Create the secrets directory using the private key from step 2 and the API key shown on the deployment page:

```bash
mkdir -p secrets
cp /path/to/your/private_key.pem secrets/private_key.pem
echo -n "your-control-plane-api-key" > secrets/api_key
chmod 600 secrets/private_key.pem secrets/api_key
```

The private key and API key are mounted as Docker secrets (`/run/secrets/private_key` and `/run/secrets/api_key`). They are not copied into the image and they are not visible in `docker inspect`.

### Alternative key storage

The `secrets/` directory is the simplest approach, but the private key file sits on the host filesystem in plain text. If your security policy requires stronger protection, the data plane supports two alternatives:

**Point at an external path.** Set the `PRIVATE_KEY_FILE` environment variable (and `API_KEY_FILE`) in the compose file to a path on an encrypted volume, a FUSE-mounted secrets manager, or any other location your security tooling controls:

```yaml
environment:
  - PRIVATE_KEY_FILE=/mnt/vault/requestrocket/private_key.pem
  - API_KEY_FILE=/mnt/vault/requestrocket/api_key
```

Remove the `secrets:` block from the compose file when using this approach. The data plane reads the file at startup.

**Use a Docker secrets backend.** Docker Swarm mode and some orchestrators support external secrets providers (e.g. HashiCorp Vault, AWS Secrets Manager). The secret appears at `/run/secrets/private_key` without a plaintext file on the host.

In all cases, the private key is read into memory once at startup. It is never logged, never sent to the control plane, and never written to MongoDB.

---

## 5. Ports and TLS

By default the package publishes port 80 on the host and Traefik routes that port to the data plane. Callers authenticate with a bearer credential, so do not expose plain HTTP on an untrusted network.

### Change the published port

Edit `docker-compose.yml` and replace the port mapping:

```yaml
ports:
  - "8443:80"   # host port 8443 → Traefik port 80
```

Only the host side changes. Traefik and the data plane keep their internal ports. Run `docker compose up -d traefik` to apply.

### Option A: terminate TLS upstream (default)

Place a load balancer or reverse proxy in front of the host that terminates TLS and forwards to the data plane's published port. Set `publicUrl` in `config.json` to the HTTPS URL callers actually use.

No changes to Traefik or the compose files are needed.

### Option B: terminate TLS on Traefik

If you want Traefik itself to serve HTTPS:

1. Add your certificate and key:

```bash
mkdir -p traefik/certs traefik/dynamic
cp /path/to/certificate.crt traefik/certs/server.crt
cp /path/to/private.key     traefik/certs/server.key
```

2. Create `traefik/dynamic/certificate.yml`:

```yaml
tls:
  certificates:
    - certFile: /etc/traefik/certs/server.crt
      keyFile: /etc/traefik/certs/server.key
```

3. Replace `traefik/traefik.yml` with a TLS-enabled config:

```yaml
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"

providers:
  docker:
    exposedByDefault: false
    network: dataplane-net
  file:
    directory: /etc/traefik/dynamic
    watch: true

log:
  level: INFO

accessLog: {}
```

4. Update `docker-compose.yml` to publish port 443 and mount the extra directories:

```yaml
traefik:
  ports:
    - "80:80"
    - "443:443"
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock:ro
    - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro
    - ./traefik/dynamic:/etc/traefik/dynamic:ro
    - ./traefik/certs:/etc/traefik/certs:ro
```

5. Update the Traefik labels in `docker-compose.blue.yml` and `docker-compose.green.yml` to use the `websecure` entrypoint:

```yaml
labels:
  - "traefik.http.routers.data-plane.entrypoints=websecure"
  - "traefik.http.routers.data-plane.tls=true"
```

6. Apply:

```bash
export IMAGE_TAG="$(jq -r '.imageTag // "latest"' config.json)"
docker compose up -d traefik
```

Set `publicUrl` to the HTTPS URL (e.g. `https://data-plane.example.com`).

All of these are host-side changes. They survive image auto-updates. See section 9.

---

## 6. First start

```bash
export IMAGE_TAG="$(jq -r '.imageTag // "latest"' config.json)"
docker compose up -d
curl http://localhost/health
```

A healthy process responds with JSON whose `status` field is `ok`.

`docker compose up -d` starts three containers: Traefik, MongoDB, and one data plane container named `data-plane`. That first container is the bootstrap slot. The next update moves traffic onto `data-plane-blue` or `data-plane-green` and removes the bootstrap container. Traefik and MongoDB stay running.

`IMAGE_TAG` has to be set for this first Compose command, because Compose does not read `config.json` itself. If you omit it, Compose pulls `latest`. Later runs of `deploy.sh` and `update.sh` read `imageTag` from `config.json`.

---

## 7. Automatic updates

`update.sh` is the hourly check.

1. It takes a non-blocking lock so a second run exits immediately if the first is still going.
2. It asks the registry for the manifest digest of `ghcr.io/requestrocket/data-plane:<imageTag>`. That request is a few kilobytes. It does not download the image.
3. It compares that digest with the image the running container was started from.
4. When they match, it exits.
5. When they differ, it pulls the image (3 minute limit) and runs `./deploy.sh --no-pull`.

`deploy.sh` starts the idle slot beside the one that is serving, waits until the new container is healthy, then stops the old one. Traefik follows the healthy container. MongoDB is not restarted.

If the new container does not become healthy, `deploy.sh` removes it and leaves the previous container in place. There is no traffic cut-over on a failed health check.

The whole script is limited to 10 minutes. A stuck pull or a stuck deploy is killed, and the lock releases when the process exits. The next hour tries again.

| Step | Limit | If it expires |
|---|---|---|
| Registry digest check | up to 120 seconds | Exit. Current container keeps serving |
| Image download | 180 seconds | Exit. Current container keeps serving |
| New container health check | about 60 seconds | New container is removed. Previous container keeps serving |
| Whole script | 600 seconds | Process is killed and the lock releases |

### Enable it with systemd

Edit `systemd/requestrocket-update.service` and replace `/opt/requestrocket` with the directory you unpacked this package into. Then:

```bash
sudo cp systemd/requestrocket-update.service /etc/systemd/system/
sudo cp systemd/requestrocket-update.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now requestrocket-update.timer
systemctl list-timers requestrocket-update.timer
```

### Enable it with cron

Use this on a host that does not run systemd (Alpine, or a Docker Desktop VM you schedule yourself):

```bash
0 * * * * cd /opt/requestrocket && timeout 600 ./update.sh >> /var/log/requestrocket-update.log 2>&1
```

---

## 8. Update immediately

You do not have to wait for the hour. From the package directory:

```bash
chmod +x deploy.sh update.sh
./update.sh
```

`./update.sh` still checks the digest first. To pull and swap even without that check:

```bash
./deploy.sh
```

`deploy.sh` on its own pulls the tag from `config.json` unless you pass `--no-pull`.

---

## 9. What the timer updates, and what it does not

The timer replaces the data plane container image. That covers application code: proxy behaviour, authenticators, sync, and dependency updates inside the image.

It does not change files on the host. Install a new package and run `docker compose up -d` when RequestRocket ships a change to any of:

- `docker-compose.yml`, `docker-compose.blue.yml`, or `docker-compose.green.yml`
- Traefik configuration
- new `config.json` fields
- `deploy.sh`, `update.sh`, or the systemd units

After the first blue-green swap, `docker compose up -d` with no service name would also start the bootstrap `data-plane` service again. To recreate only Traefik and MongoDB:

```bash
export IMAGE_TAG="$(jq -r '.imageTag // "latest"' config.json)"
docker compose up -d traefik mongo
```

RequestRocket release notes will say when a host-side reinstall is required.

---

## 10. Scaling

All three containers run on one host by default. To give MongoDB more of that host, set a limit on the `mongo` service in `docker-compose.yml` and run `docker compose up -d mongo`.

To use a database you already run, set `mongodbUri` and remove the `mongo` service from `docker-compose.yml`. Atlas, Amazon DocumentDB, and any other MongoDB-compatible endpoint works. Example:

```json
"mongodbUri": "mongodb+srv://user:pass@cluster.example.net/dataplane?retryWrites=true"
```

A replica set is the same change with a longer URI:

```json
"mongodbUri": "mongodb://host1:27017,host2:27017,host3:27017/dataplane?replicaSet=rs0"
```

The data plane process does not store caller configuration outside MongoDB. Several hosts can point at one database and sit behind your own load balancer. Each host has its own `publicUrl` and its own copy of the secrets. This Compose change is a manual re-deploy, not an image update.

---

## 11. Troubleshooting

| What you see | What to run |
|---|---|
| Health check never returns | `docker logs data-plane` or `docker logs data-plane-blue` / `data-plane-green` |
| Data plane cannot reach MongoDB | `docker logs mongo` |
| Callers get no response on port 80 | `docker logs traefik` and `docker compose ps` |
| Update log says the manifest could not be read | `docker login ghcr.io` again. The token is missing or expired |
| Update log says the pull timed out | Nothing was swapped. The next run retries. Check outbound access to `ghcr.io` |
| Two data plane containers are serving | The bootstrap container is still up. `docker compose stop data-plane && docker compose rm -f data-plane` |

`docker compose ps` shows which slot is running. After a successful update the name is `data-plane-blue` or `data-plane-green`.

The control plane record for the deployment shows the version the running image was built with (`deploymentReportedVersion`) after the new container syncs. That field confirms a roll-out. It does not start one.

---

## 12. Support

Contact RequestRocket support if the host cannot pull the image, the health check stays down, or a release note asks you to reinstall host files you do not have.
