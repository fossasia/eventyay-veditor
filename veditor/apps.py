from django.utils.translation import gettext_lazy as _

from . import __version__

try:
    from eventyay.base.plugins import PluginConfig
except ImportError as e:
    raise RuntimeError("Please use a later version of eventyay") from e


class VeditorApp(PluginConfig):
    default = True
    name = "veditor"
    verbose_name = _("Veditor")

    class EventyayPluginMeta:
        name = _("Veditor")
        author = "FOSSASIA"
        description = _("Video review and transcode plugin for eventyay")
        visible = True
        version = __version__
        category = "FEATURE"

    def ready(self):
        from . import signals  # noqa: F401 — registers signal receivers
