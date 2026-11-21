# RequestRocket data plane

This repository is the install kit for a self-hosted RequestRocket data plane. Clone it onto the host that will run the deployment, then follow the deployment guide.

The data plane authenticates callers, syncs configuration from the RequestRocket control plane, and proxies requests to upstream APIs. The container image is not in this repository. Docker Compose pulls `ghcr.io/requestrocket/data-plane` from the RequestRocket registry. RequestRocket sends the registry username and token separately.

You need a deployment license, a deployment created in the RequestRocket app, and an RSA key pair before the first start. Every connection to RequestRocket is outbound from your host. The control plane does not open a connection to the data plane.

## Start here

Install, TLS, automatic updates, and scaling are in [docs/deployment-guide.md](docs/deployment-guide.md).

| Step | Where to read |
|---|---|
| Host requirements | [Prerequisites](docs/deployment-guide.md#1-prerequisites) |
| Key pair and the deployment record | [Generate a key pair and create a deployment](docs/deployment-guide.md#2-generate-a-key-pair-and-create-a-deployment) |
| Registry login | [Authenticate to the container registry](docs/deployment-guide.md#3-authenticate-to-the-container-registry) |
| `config.json` and secrets | [Configure the deployment](docs/deployment-guide.md#4-configure-the-deployment) |
| Ports and certificates | [Ports and TLS](docs/deployment-guide.md#5-ports-and-tls) |
| First start | [First start](docs/deployment-guide.md#6-first-start) |
| Hourly image updates | [Automatic updates](docs/deployment-guide.md#7-automatic-updates) |
| Deploy without waiting for the timer | [Update immediately](docs/deployment-guide.md#8-update-immediately) |
| Compose, Traefik, or script changes | [What the timer updates, and what it does not](docs/deployment-guide.md#9-what-the-timer-updates-and-what-it-does-not) |
| More than one host, or your own database | [Scaling](docs/deployment-guide.md#10-scaling) |
| Health checks and update failures | [Troubleshooting](docs/deployment-guide.md#11-troubleshooting) |

Copy [config.example.json](config.example.json) to `config.json` and fill in the values from the deployment page. The same template is repeated at [docs/config.example.json](docs/config.example.json). `config.json` and the `secrets/` directory stay on the host. Both are listed in `.gitignore`.

## What is in this repository

| Path | Purpose |
|---|---|
| [docs/deployment-guide.md](docs/deployment-guide.md) | Installation and operations guide |
| [config.example.json](config.example.json) | Template for `config.json` |
| [docker-compose.yml](docker-compose.yml) | Traefik, MongoDB, and the first data plane container |
| [docker-compose.blue.yml](docker-compose.blue.yml), [docker-compose.green.yml](docker-compose.green.yml) | Blue-green slots used by updates |
| [traefik/traefik.yml](traefik/traefik.yml) | Ingress configuration. Port 80 by default; put TLS in front before production |
| [deploy.sh](deploy.sh) | Starts the idle slot and cuts over after it is healthy |
| [update.sh](update.sh) | Compares the registry digest and runs `deploy.sh` only when the image has changed |
| [systemd/](systemd/) | Hourly timer for `update.sh`. Edit the paths in the service file before installing it |

`update.sh` replaces the data plane image. A change to the files in this repository is applied by pulling this repository again and following [what the timer does not update](docs/deployment-guide.md#9-what-the-timer-updates-and-what-it-does-not).

## License

Use of these files is covered by [LICENSE](LICENSE). The grant is limited to operating a RequestRocket data plane under a current deployment license. The container image is licensed separately.
