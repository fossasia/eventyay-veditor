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

## Code Style

This plugin enforces code style via `ruff` (import sorting + formatting). CI runs these checks automatically on every PR.

To check locally:

```bash
ruff check --select I .
ruff format --check .
```

To auto-fix:

```bash
ruff check --select I --fix .
ruff format .
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
