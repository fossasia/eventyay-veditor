def test_plugin_version():
    import veditor

    assert veditor.__version__ == "0.1.0"


def test_appconfig_meta():
    try:
        from veditor.apps import VeditorApp
    except (RuntimeError, ModuleNotFoundError):
        import pytest

        pytest.skip("eventyay or Django not installed, skipping AppConfig test")

    assert VeditorApp.name == "veditor"
    meta = VeditorApp.EventyayPluginMeta
    assert meta.author == "FOSSASIA"
    assert meta.visible is True
    assert meta.category == "FEATURE"


def test_plugin_entry_point():
    from importlib.metadata import entry_points

    eps = entry_points(group="pretix.plugin")
    names = [ep.name for ep in eps]
    assert "veditor" in names
