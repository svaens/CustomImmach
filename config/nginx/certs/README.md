Place your TLS certificate material here as:

- `server.crt`
- `server.key`

If you use a local CA-based setup, also keep:

- `ca.crt`
- `ca.key`

For local testing only, you can generate a local CA and server certificate with:

```bash
/home/sean/Personal/dev/Immach/scripts/generate-local-ca-certificates.sh
```

By default the script reads `PUBLIC_HOSTNAME` from `/home/sean/Personal/dev/Immach/.env`
and also adds `localhost` plus `127.0.0.1` as SANs.

Unlike the previous one-file helper, this script creates a local CA plus a CA-signed server certificate:

- `ca.crt`: import this into your browser/device trust store
- `server.crt`: used by nginx
