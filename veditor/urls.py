"""URL configuration for the VEditor Eventyay plugin."""

from django.urls import path
from eventyay.common.urls import OrganizerSlugConverter  # noqa: F401

from . import views

app_name = "veditor"

urlpatterns = [
    path(
        "common/event/<orgslug:organizer>/<slug:event>/veditor/",
        views.ConnectView.as_view(),
        name="connect",
    ),
]
