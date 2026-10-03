# eventyay-veditor

A plugin for [eventyay](https://github.com/fossasia/eventyay) that integrates [Veditor](https://github.com/fossasia/veditor), the video review and transcode pipeline, with event talks and recordings. This initial package bootstraps plugin registration; later phases will add organiser controls, talk-to-recording mapping, and pipeline status inside eventyay.

## Planned Features

- Organiser settings to connect an event to a Veditor instance
- Mapping of eventyay talks/sessions to Veditor talk records
- Recording ingest, review, and transcode status in the organiser UI
- Download / publish hooks for approved recordings
- Celery-backed status sync with the Veditor API

## Requirements

- eventyay (latest)
- Python 3.12+
- Redis (for Celery)

## Development Setup

1. Make sure you have a working [eventyay development setup](https://github.com/fossasia/eventyay?tab=readme-ov-file#getting-started).

2. Clone this repository:
   ```bash
   git clone https://github.com/fossasia/eventyay-veditor
   ```

3. Activate the virtual environment you use for eventyay development.

4. Install the plugin in editable mode:
   ```bash
   uv pip install -e .
   ```

5. Run migrations:
   ```bash
   python manage.py migrate
   ```

6. Restart your local eventyay server. Enable the plugin from the **Plugins** tab in your event settings.

When using the Eventyay Docker development setup, you can also clone this repository into the gitignored `plugins/` directory at the eventyay repo root so it is installed automatically.

## Webhook Configuration for Organizers

The plugin exposes an inbound webhook receiver to receive pipeline lifecycle events dispatched from VEditor.

### Webhook Endpoint & Authentication

- **Webhook URL**: `https://<your-eventyay-domain>/api/v1/veditor/webhook/`
- **Secret Configuration**: Configure the shared webhook secret either via:
  - Server environment variable: `VEDITOR_WEBHOOK_SECRET` (or `EVENTYAY_VEDITOR_WEBHOOK_SECRET`)
  - Django setting in your deployment configuration: `settings.VEDITOR_WEBHOOK_SECRET`
  - Per-event secret (for dedicated event isolation): provisioned in event settings via `event.settings.set("veditor_webhook_secret", ...)`
- **Signature Verification**: Incoming webhook requests from VEditor must provide an HMAC-SHA256 signature in the `X-Veditor-Signature` header:
  - Supported formats: `sha256=<hex_digest>`, `<hex_digest>`, or timestamped `t=<timestamp>,v1=<hex_digest>`.

### Step-by-Step Organizer Setup in VEditor

1. In your VEditor dashboard, navigate to **Event Settings** for the corresponding event.
2. In the **Outbound Webhook / API Keys** configuration panel:
   - Set the **Webhook URL** to `https://<your-eventyay-domain>/api/v1/veditor/webhook/`.
   - Enter the **Webhook Secret** matching the secret configured in Eventyay.
   - Click **Test Ping** to dispatch a test `ping` webhook and confirm the endpoint responds with `{"status": "pong"}`.
   - Click **Save Webhook**.
3. Once registered, VEditor will automatically notify Eventyay when talk recordings progress through review and publishing.

### Supported Webhook Events

- `talk.bounds_pending`:
  Dispatched when candidate talk cut points are ready for review. Triggers background email delivery of direct SSO review links to the talk's registered speakers.
- `talk.approved`:
  Dispatched when a talk recording review is approved or finalized. Triggers background email delivery of direct SSO review links to the talk's registered speakers.
- `talk.published`:
  Dispatched when video processing is finalized and published. Idempotently attaches the recording URL to the talk's resources, updating the public schedule player without creating duplicate resource entries.
- `ping`:
  Connectivity and HMAC signature verification test.


## Code Style & Linting

This plugin enforces code style via `pre-commit` running `ruff` (linting + formatting). CI runs these checks automatically on every PR.

To install the git hooks locally:

```bash
uv run pre-commit install
```

To run manually across all files:

```bash
uv run pre-commit run --all-files
```

## Running Tests

```bash
pytest tests/
```

## Project Structure

```
veditor/
  apps.py           Plugin AppConfig and EventyayPluginMeta
  signals.py        Signal receivers (nav, dashboard, pipeline hooks)
  urls.py           URL routing (organiser and event patterns)
  templates/        Django HTML templates
  static/           Plugin static assets
  locale/           Translation files
  migrations/       Database migrations (added when models land)
```

## License

Copyright FOSSASIA

Released under the terms of the Apache License 2.0
