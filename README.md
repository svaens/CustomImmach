# Immich Project - docker installation

This project bootstraps a local `Immich` stack in `/home/sean/Personal/dev/Immach` with:

- Docker Compose using the official Immich services.
- Nginx reverse proxy on `80` and `443`.
- Built-in face recognition through `immich-machine-learning`.
- Bind-mounted media storage at `./data/images:/data`.
- Storage template enabled, so CLI uploads land in Immich-native managed storage instead of staying as an external library.
- Bind-mounted Postgres data, model cache, and config files.
- A folder import script that repairs missing timestamps before upload.
- A systemd timer installer that repeatedly scans a folder and imports new assets.

## Layout

- `docker-compose.yml`: Immich stack.
- `.env`: Compose settings.
- `config/immich-config.json`: Immich config with storage template enabled.
- `config/nginx/conf.d/immich.conf`: TLS reverse proxy config.
- `config/importer.env.example`: Importer config template.
- `config/daemon.env.example`: Daemon config template.
- `scripts/import-to-immich.sh`: One-shot importer.
- `scripts/run-folder-import-scan.sh`: Scan wrapper used by systemd.
- `scripts/install-folder-import-daemon.sh`: systemd installer.
- `scripts/generate-local-ca-certificates.sh`: helper for local CA-based HTTPS testing.

## Start Immich

Set the host name you want clients to use in `.env`:

```bash
PUBLIC_HOSTNAME=happygolucky-xmg
```

Put TLS files in `config/nginx/certs/` first:

- a real certificate and key named `server.crt` and `server.key`, or
- a local CA plus server certificate generated for local testing:

```bash
/home/sean/Personal/dev/Immach/scripts/generate-local-ca-certificates.sh
```

```bash
cd /home/sean/Personal/dev/Immach
docker compose up -d
```

Open `https://$PUBLIC_HOSTNAME` or `https://localhost`, create the first admin user, then create an API key in the Immich web UI.

For browser trust of the locally generated CA, import:

- `/home/sean/Personal/dev/Immach/config/nginx/certs/ca.crt`

## HTTPS And Routing

Nginx now listens on:

- `80` for redirect to HTTPS
- `443` for TLS termination and proxying to Immich

Immich is served at the site root:

- `https://your-host/`

Important: current Immich documentation says it does **not** support being served on a sub-path such as `/immich`. Because of that, this setup does not proxy the app under `/immach`.

Instead:

- `https://your-host/immach` redirects to `https://your-host/`

If you want a branded URL, the supported shape is a dedicated host or subdomain such as:

- `https://immach.example.com/`

## Import Photos Once

1. Copy the example importer config:

```bash
cp /home/sean/Personal/dev/Immach/config/importer.env.example /home/sean/Personal/dev/Immach/config/importer.env
```

2. Edit `config/importer.env` and set `IMMICH_API_KEY`.

3. Run the importer:

```bash
/home/sean/Personal/dev/Immach/scripts/import-to-immich.sh /photos-legacy
```

What the importer does:

- Repairs missing `DateTimeOriginal` and `CreateDate` from `FileModifyDate` using `exiftool`.
- Uploads recursively with the current Immich CLI container.
- Uses Immich server-side duplicate detection, so re-running the import is safe.
- Preserves original files and metadata during upload.

Optional flags:

- `--dry-run`
- `--album-name "Legacy Import"`
- `--no-auto-album`
- `--delete`

## Install Recurring Folder Scans

The daemon installer uses a systemd timer rather than a long-running watcher. For large recursive trees this is simpler and more reliable, and it still gives you automated recurring imports.

Example:

```bash
sudo /home/sean/Personal/dev/Immach/scripts/install-folder-import-daemon.sh \
  --import-dir /photos-legacy \
  --server-url https://localhost/api \
  --api-key YOUR_API_KEY \
  --run-user sean \
  --interval-minutes 10
```

That command writes:

- `config/importer.env`
- `config/daemon.env`
- `/etc/systemd/system/immich-folder-import.service`
- `/etc/systemd/system/immich-folder-import.timer`

The timer triggers `scripts/run-folder-import-scan.sh`, which then calls the importer script against your chosen folder.

## Notes

- Immich stores uploaded originals under `./data/images`. With the storage template enabled, originals move into the `library` tree in Immich-native layout.
- Face recognition is already built into Immich through `immich-machine-learning`; no separate plugin is required.
- Redis is left ephemeral here because the critical persistent state is the asset storage and Postgres database.
- HTTPS is handled by the bundled Nginx reverse proxy, not by Immich directly.
- `PUBLIC_HOSTNAME` is the project setting used when generating the local CA-signed server certificate.
- For Android and other mobile clients, a private local CA setup may still require manual trust on the device. The reliable internet-facing fix is a real certificate from a trusted public CA.
