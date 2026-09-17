# LogZilla UI3 Preview

Run the new LogZilla UI3 web interface as a sidecar next to an existing
LogZilla server. It pulls prebuilt public images - no source, no build. Your
LogZilla install is not modified, and you can stop UI3 at any time.

## Quick start

On your LogZilla host, as root:

```bash
# requires root access
sudo su -
cd /opt
git clone https://github.com/logzilla/ui3-preview.git
cd ui3-preview
sudo ./install.sh
```

The installer checks prerequisites, resolves the required secrets from your
running LogZilla, writes `.env`, and starts the sidecar. When it asks for a
LogZilla API token, paste a user-level token or press Enter to create one
(that takes ~10-15 seconds).

Then open **`http://<your-host>:8080/`** and log in with your LogZilla
credentials.

## Requirements

- A running LogZilla Docker install on this host.
- Docker and the Docker Compose v2 plugin (`docker compose`).
- Root on the host (creating the token and accessing Docker require it).

## Managing it

```bash
docker compose ps                              # status
docker compose logs -f                         # logs
docker compose down                            # stop UI3 (LogZilla is untouched)
docker compose pull && docker compose up -d    # update to the latest build
```

Re-running `./install.sh` is safe - it keeps existing secrets and won't create
duplicate tokens. To pin a specific build, change both image tags in
`compose.yml` from `:latest` to a published `:sha-<short>` tag and run
`docker compose up -d`.

## Troubleshooting

| Message / symptom | Fix |
|---|---|
| `no LogZilla Docker network found` | Your network isn't `lz_main`. Find it with `docker network ls \| grep lz`, then `sudo LZ_NETWORK_NAME=<name> ./install.sh`. |
| `LogZilla secrets file not found` | Your config isn't at `/etc/logzilla`. Run `sudo LZ_ETC_PATH=/your/path ./install.sh`. |
| Port already in use | Pick another: `sudo UI3_PORT=9090 ./install.sh`. |
| `that token is ingest-only / invalid` | Use a user-level token (press Enter to have the installer create one). |
| SEC / orchestration errors in the UI | `SEC_API_URL` must be `http://front:80`; the installer sets this - don't change it to `gunicorn:80`. |
| `could not validate the token` | Two common causes. LogZilla's web port isn't on `localhost:80` here: run `sudo LZ_HOST_URL=http://your-lz:PORT ./install.sh`. Or LogZilla is HTTPS-configured and its certificate doesn't match the probed hostname: run `sudo LZ_HOST_URL=https://your-lz-cert-hostname ./install.sh` (the warn line includes curl's exact error). |

## Security

`install.sh` runs as root, may create a LogZilla API token, and starts
containers that mount the Docker socket (read-only) and `/etc/logzilla` - the
same access the standard LogZilla sidecar uses. Read the script before running
it; don't pipe it from the internet straight into a root shell.

## What's here

`install.sh` (the installer), `compose.yml` (runs the two public images), and
`LICENSE` / `NOTICE`. The installer glue is Apache-2.0; the UI3 container images
are LogZilla proprietary, offered for preview against a licensed LogZilla
install. No source or build tooling.
