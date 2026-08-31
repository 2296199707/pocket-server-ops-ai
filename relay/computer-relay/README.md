# PocketServerOps computer relay

This is the small relay used by the Windows Agent. It does not execute
commands and it does not expose an arbitrary TCP forward. The phone and the
Windows Agent use separate WebSocket connections; the phone submits a named
request, the Agent receives it over its outbound connection, and the relay
returns the result by request ID.

## One-command install

On a Linux relay server that already has Docker Engine and Docker Compose v2:

```bash
curl -fsSL https://raw.githubusercontent.com/2296199707/pocket-server-ops-ai/beta/relay/computer-relay/install.sh | sudo bash
```

The installer downloads the beta source, starts an isolated Compose project, and
stores the relay under `/www/pocket-server-ops-computer-relay`. It does not
install or restart Docker, change an existing Caddy/Nginx configuration, or
stop other Compose projects. The relay binds to `127.0.0.1:8787` by default.

The command requires `curl`, `tar`, `openssl`, Docker Engine, and Docker Compose
v2. If Docker is missing, install it separately so an existing website is not
changed unexpectedly.

## Deploy from a checkout

Run `sudo bash deploy.sh` on the relay server. The default install directory is
`/www/pocket-server-ops-computer-relay`; set `RELAY_INSTALL_DIR` to change it.
The deploy script copies `package-lock.json` as well as the service files. It
requires Docker Compose v2 and prints no token. Read the API token from the
protected `.env` file and enter it in the app.

The management API is HTTP based, while the device and phone channels are
WebSockets. Put the relay behind an HTTPS/WSS reverse proxy before exposing it
to the Internet. The API token is for the phone; each Windows device is
registered with a separate device token from the app. Device tokens are stored
as hashes in `data/devices.json`.

For an existing Caddy site, add a separate subdomain and reload Caddy after
validating the configuration:

```caddyfile
relay.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

Use `https://relay.example.com` in the App and `wss://relay.example.com` in the
Windows Agent. The existing website can continue using its current domain.

Register a device with the phone API token:

```text
POST /v1/devices/<device_id>/register
Authorization: Bearer <relay-api-token>
{"name":"Office PC","device_token":"<device-token>"}
```

The Agent connects to `/device/ws` and the phone connects to
`/v1/devices/<device_id>/ws`. Requests and results are short-lived relay
metadata; command results are retained only long enough for a reconnect to
retrieve an already completed request. The relay never runs a command.
