# MyS3

MyS3 is a minimal, open-source object store inspired by AWS S3. It exposes a JSON-only HTTP API, stores every object directly on the filesystem, and is designed to run anywhere Puma and Sinatra are available.

Just rent a [Storage VPS](https://contabo.com/en/storage-vps/) and run your own Simple-Storage-Service for cheap.

## Features
- JSON-over-HTTP API with API-key authentication only
- Filesystem-backed storage with nested folders/prefixes
- Thread-safe operations compatible with Puma multi-threading
- Configurable upload limits, logging, timezone, and symlink policy
- Zero external services: no database, queues, or UI
- Lightweight landing page at `/` to confirm the daemon is live (no API key required)

## Requirements
- Ruby 3.1.2 (or newer 3.1.x)
- Bundler
- A writable directory for the storage root and log files

## Installation
```bash
bundle install
cp config.example.yml config.yml
$EDITOR config.yml
```

Set `MY_S3_CONFIG=/absolute/path/to/config.yml` if the file lives outside the project root.

## Configuration
All configuration lives in `config.yml` and is never exposed through the API. The file must define the following keys:

| Key | Description |
| --- | --- |
| `api_key` | Shared secret required in the `X-API-Key` header. |
| `storage_root` | Absolute or relative path used as the storage sandbox. |
| `public_base_url` | Base URL used to build public/download URLs. |
| `bind_host` / `port` | Interface and port Puma should bind to. |
| `max_upload_size_mb` | Maximum accepted upload size (per file). |
| `follow_symlinks` | Allow (`true`) or reject (`false`, default) symlinks inside the storage root. |
| `puma_threads_min/max` | Puma thread pool size hints. |
| `log_level`, `log_file` | Standard Ruby logger options. |
| `timezone` | Sets `ENV['TZ']` for consistent timestamps. |

Any relative paths are resolved against the configuration file directory. The application creates the storage root and `log/` directory on boot when needed.

## Running
```bash
MY_S3_CONFIG=/srv/my_s3/config.yml bundle exec puma \
	-t 4:16 \
	-b tcp://0.0.0.0:4567 \
	config.ru
```

Always point Puma at `config.ru`; it bootstraps the Rack app and pulls in `app.rb`. Run the command from the repository root so Bundler picks up the correct Gemfile (or export `BUNDLE_GEMFILE=/abs/path/to/Gemfile` if you insist on running it elsewhere). Use the same host/port and thread counts configured in your `config.yml`. Puma’s multi-threaded mode is required; every disk operation is wrapped in thread-safe primitives inside the app.

Browsing to `/` in a web browser now shows a minimal “MyS3 is live” page (no authentication needed) so you can confirm the daemon is healthy without hitting the JSON API directly. Every other endpoint still requires `X-API-Key`.

## API Overview
All endpoints:

- Require `X-API-Key: <your api_key>`
- Accept/return JSON (except `upload.json`, which uses multipart form data)

| Endpoint | Method | Description |
| --- | --- | --- |
| `/list.json` | `GET` | List files and folders inside `path` (default: root). |
| `/create_folder.json` | `POST` | Create `folder_name` inside `path`. |
| `/delete_folder.json` | `DELETE` | Delete a folder (and all children). |
| `/rename_folder.json` | `POST` | Rename a folder to `new_name`. |
| `/upload.json` | `POST` | Multipart upload for a single file. |
| `/delete.json` | `DELETE` | Delete `filename` inside `path`. |
| `/delete_older_than.json` | `POST` | Delete files older than an ISO 8601 timestamp. |
| `/get_download_url.json` | `POST` | Build a public download URL for a file. |
| `/get_public_url.json` | `POST` | Build a browser-friendly public URL for a file. |

### Example Calls

List everything at the root:

```bash
curl -H "X-API-Key: CHANGE_ME" \
  'http://127.0.0.1:4567/list.json?path='
```

Create a folder:

```bash
curl -X POST -H "Content-Type: application/json" \
	-H "X-API-Key: CHANGE_ME" \
	-d '{"path":"projects","folder_name":"images"}' \
	http://127.0.0.1:4567/create_folder.json
```

Upload a file (multipart):

```bash
curl -X POST -H "X-API-Key: CHANGE_ME" \
	-F path=projects/images \
	-F file=@./example.png \
	http://127.0.0.1:4567/upload.json
```

Delete files older than 30 days:

```bash
curl -X POST -H "Content-Type: application/json" \
	-H "X-API-Key: CHANGE_ME" \
	-d '{"path":"projects/images","older_than":"2025-01-01T00:00:00Z"}' \
	http://127.0.0.1:4567/delete_older_than.json
```

Generate a URL:

```bash
curl -X POST -H "Content-Type: application/json" \
	-H "X-API-Key: CHANGE_ME" \
	-d '{"path":"projects/images","filename":"example.png"}' \
	http://127.0.0.1:4567/get_public_url.json
```

## Logging & Monitoring
- Logs are written to the path defined by `log_file` (defaults to `log/app.log`).
- Every unhandled exception is logged with a stack trace and surfaces as a `500 Internal Server Error` JSON payload.
- Add your own metrics/forwarding by tailing the log file, shipping to Loki, etc.

## Production Checklist
- Run behind a TLS-terminating reverse proxy (nginx, Traefik, Caddy).
- Rotate the API key regularly and store it outside version control.
- Mount the storage root on durable disks (e.g., attached volume, network share).
- Create and monitor backups; objects live on disk only.
- Configure log rotation to keep disk usage predictable.

Enjoy!

