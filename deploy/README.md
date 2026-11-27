# Deploy MallMate

Use a Linux server with systemd, Node.js 22, npm and Caddy. Point a hostname at the server and allow inbound TCP 80 and 443 for Caddy. The Node process listens on loopback. Caddy serves the website and proxies same-origin API and WebSocket requests.

1. Copy this repository to `/opt/mallmate-review`. From its root, run `npm ci --prefix web --omit=dev --ignore-scripts` and confirm `/usr/bin/node --version` reports v22. If Node is installed at a different system path, update `ExecStart` in the service template.
2. Create the service user and install the templates.

   ```sh
   sudo useradd --system --user-group --no-create-home --shell /usr/sbin/nologin mallmate-review
   sudo install -d -m 0755 /etc/mallmate-review
   sudo install -m 0600 deploy/service.env.example /etc/mallmate-review/service.env
   sudo install -m 0644 deploy/mallmate-review.service /etc/systemd/system/mallmate-review.service
   ```

3. Edit `/etc/mallmate-review/service.env`. Set `MALLMATE_PUBLIC_ORIGIN` to the exact HTTPS origin, without a path or trailing slash. Add the block in `deploy/Caddyfile.example` to Caddy's configuration, replacing `mallmate.example.org` with the same hostname. Keep existing Caddy site blocks.
4. Run `sudo systemctl daemon-reload`, `sudo systemctl enable --now mallmate-review` and `sudo systemctl reload caddy`. Open `https://YOUR-HOST/healthz` and then the site on a phone.

## RouteWalk store bindings

In `/etc/mallmate-review/service.env`, set `MALLMATE_STORE_ROUTES` to a one-line JSON object mapping each store ID to its saved RouteWalk route ID. This example binds the UNIQLO store:

```dotenv
MALLMATE_STORE_ROUTES='{"amap-B02001HUD4":"2ed6cf8f-e9df-4574-99a0-60ec304441fb"}'
```

Replace the example UUID with the ID copied from RouteWalk. Add more entries inside the same object for additional stores. Keep the single quotes around the JSON and the double quotes around each ID. For local desktop testing, put the same setting in the repository root's `.env`.

Restart the Node service with `sudo systemctl restart mallmate-review` on Linux. Check `GET /api/public/stores` for the configured store under `navigationDestinations`. Reload the usual HTTPS store map on the same iPhone and tap **Go here**. [Copying a route ID and opening RouteWalk](../README.md#open-routewalk-from-the-map)

## Optional provider credentials

Create provider credentials using your own accounts. Each credential file contains one line with just the value. On Linux, place the files in `/etc/mallmate-review/credentials/` and put the provider settings in `/etc/mallmate-review/service.env`. For a local run, use the directory set in `CREDENTIALS_DIRECTORY` and put the provider settings in the repository root's `.env`.

| Service | Where to obtain the credential | Credential filename | Additional server settings |
| --- | --- | --- | --- |
| DeepSeek AI recommendations | Create an API key and enable billing in the DeepSeek API Platform. [DeepSeek API setup](https://api-docs.deepseek.com/) | `deepseek-api-key` | — |
| Qwen streaming speech recognition | Create a pay-as-you-go API key in a Qwen AI Platform workspace with access to `qwen-audio-3.0-asr-flash-streaming`. [Qwen API keys](https://platform.qianwenai.com/docs/developer-guides/administration/api-keys) · [Qwen streaming model](https://platform.qianwenai.com/docs/models/qwen-audio-3-0-asr-flash-streaming) | `dashscope-api-key` | `MALLMATE_QWEN_STREAMING=1` |
| Your Softr Stores table | [Import the CSV](../data/README.md) into your workspace and [create a personal access token](https://docs.softr.io/softr-api/softr-database-api/authorisation) scoped to it. | `softr-api-token` | `MALLMATE_CATALOGUE_SOURCE=review-softr`, `MALLMATE_SOFTR_DATABASE_ID` and `MALLMATE_SOFTR_STORES_TABLE_ID` |

On the Linux server, create the credential directory and the service override directory.

```sh
sudo install -d -m 0700 /etc/mallmate-review/credentials
sudo install -d -m 0755 /etc/systemd/system/mallmate-review.service.d
```

Create each credential file as root with mode `0600`. For a new file, use `sudo install -m 0600 /dev/null /etc/mallmate-review/credentials/deepseek-api-key`, substituting the filename from the table. For an existing file, open it directly with `sudoedit`. Enter the key through the editor. Copy `credentials.conf.example` to `/etc/systemd/system/mallmate-review.service.d/credentials.conf` for a new configuration, then uncomment the lines for the credentials you installed. Apply the changes with `sudo systemctl daemon-reload` and `sudo systemctl restart mallmate-review`.

Verify the services you enabled:

- **Softr:** `GET /api/public/stores` returns 65 records and the source `softr-review+production-public-snapshot`.
- **DeepSeek:** `GET /api/public/ai/status` reports `configured: true`. Submit a shopper request and confirm that the app returns a recommendation.
- **Qwen:** `GET /api/public/speech/status` reports `configured: true`. On the HTTPS site, allow microphone access, speak a short phrase and confirm that the text appears.

Keep credential values on the server and share the website link with the people using it.
