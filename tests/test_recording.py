"""Unit tests for the VEditor recording provider and schedule signal."""

from __future__ import annotations

from unittest.mock import MagicMock

from veditor.recording import VEditorRecordingProvider
from veditor.signals import agenda_recording_veditor


def test_recording_provider_do_not_record():
    event = MagicMock()
    provider = VEditorRecordingProvider(event)

    submission = MagicMock()
    submission.do_not_record = True
    submission.recording_url = "https://example.com/video.mp4"

    result = provider.get_recording(submission)
    assert result == {}


def test_recording_provider_no_recording_available():
    event = MagicMock()
    provider = VEditorRecordingProvider(event)

    submission = MagicMock()
    submission.do_not_record = False
    submission.recording_url = None
    submission.resources.filter.return_value.first.return_value = None

    result = provider.get_recording(submission)
    assert result == {}


def test_recording_provider_direct_video_mp4():
    event = MagicMock()
    provider = VEditorRecordingProvider(event)

    submission = MagicMock()
    submission.do_not_record = False
    submission.recording_url = "https://cdn.example.com/videos/talk1.mp4"

    result = provider.get_recording(submission)
    assert "iframe" in result
    assert "csp_header" in result
    assert "<video controls" in result["iframe"]
    assert 'src="https://cdn.example.com/videos/talk1.mp4"' in result["iframe"]
    assert result["csp_header"] == "https://cdn.example.com"


def test_recording_provider_direct_video_webm():
    event = MagicMock()
    provider = VEditorRecordingProvider(event)

    submission = MagicMock()
    submission.do_not_record = False
    submission.recording_url = "https://cdn.example.com/videos/talk1.webm?token=abc"

    result = provider.get_recording(submission)
    assert "<video controls" in result["iframe"]
    assert result["csp_header"] == "https://cdn.example.com"


def test_recording_provider_iframe_embed():
    event = MagicMock()
    provider = VEditorRecordingProvider(event)

    submission = MagicMock()
    submission.do_not_record = False
    submission.recording_url = "https://studio.veditor.org/embed/42"

    result = provider.get_recording(submission)
    assert "<iframe" in result["iframe"]
    assert 'src="https://studio.veditor.org/embed/42"' in result["iframe"]
    assert result["csp_header"] == "https://studio.veditor.org"


def test_recording_provider_from_resource_model():
    event = MagicMock()
    provider = VEditorRecordingProvider(event)

    resource_mock = MagicMock()
    resource_mock.link = "https://archive.org/embed/my-event-talk"

    submission = MagicMock(spec=["do_not_record", "resources"])
    submission.do_not_record = False
    submission.resources.filter.return_value.first.return_value = resource_mock

    result = provider.get_recording(submission)
    assert "<iframe" in result["iframe"]
    assert 'src="https://archive.org/embed/my-event-talk"' in result["iframe"]
    assert result["csp_header"] == "https://archive.org"


def test_recording_provider_html_escaping():
    event = MagicMock()
    provider = VEditorRecordingProvider(event)

    submission = MagicMock()
    submission.do_not_record = False
    submission.recording_url = 'https://example.com/video?foo="bar"&baz=<tag>'

    result = provider.get_recording(submission)
    assert "&quot;bar&quot;&amp;baz=&lt;tag&gt;" in result["iframe"]


def test_agenda_recording_signal_with_plugin_active():
    event = MagicMock()
    event.plugins = "veditor,pretalx_pages"

    provider = agenda_recording_veditor(sender=event)
    assert isinstance(provider, VEditorRecordingProvider)
    assert provider.event == event


def test_agenda_recording_signal_without_plugin():
    event = MagicMock()
    event.plugins = "pretalx_pages"

    provider = agenda_recording_veditor(sender=event)
    assert provider is None


def test_recording_provider_invalid_scheme_rejected():
    event = MagicMock()
    provider = VEditorRecordingProvider(event)

    for bad_url in (
        "javascript:alert(1)",
        "data:text/html,<script>alert(1)</script>",
        "ftp://example.com/video.mp4",
        "//example.com/video.mp4",
        "/relative/path.mp4",
        "https://",
    ):
        submission = MagicMock()
        submission.do_not_record = False
        submission.recording_url = bad_url
        assert provider.get_recording(submission) == {}


def test_agenda_recording_signal_with_plugin_list():
    event = MagicMock()
    del event.plugins
    event.plugin_list = ["veditor", "pretalx_pages"]

    provider = agenda_recording_veditor(sender=event)
    assert isinstance(provider, VEditorRecordingProvider)
    assert provider.event == event


def test_agenda_recording_signal_with_plugins_none():
    event = MagicMock()
    event.plugin_list = None
    event.plugins = None

    provider = agenda_recording_veditor(sender=event)
    assert provider is None


def test_agenda_recording_signal_with_substring_plugin_name():
    event = MagicMock()
    del event.plugin_list
    event.plugins = "veditor_extra,veditor_extension"

    provider = agenda_recording_veditor(sender=event)
    assert provider is None


def test_agenda_recording_signal_without_plugins_attribute():
    event = MagicMock(spec=[])

    provider = agenda_recording_veditor(sender=event)
    assert provider is None
