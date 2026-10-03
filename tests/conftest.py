import pytest
from django.conf import settings
from django.db.backends.signals import connection_created
from django.dispatch import receiver
from django.utils.timezone import now
from eventyay.base.models import Event, Organizer, User


@receiver(connection_created)
def setup_postgres_extensions(sender, connection, **kwargs):
    """Ensure required PostgreSQL extensions exist for models with gin/trigram indexes."""
    if connection.vendor == "postgresql":
        try:
            with connection.cursor() as cursor:
                cursor.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm;")
                cursor.execute("CREATE EXTENSION IF NOT EXISTS unaccent;")
        except Exception:
            pass


@pytest.fixture(autouse=True, scope="session")
def configure_test_databases():
    """Ensure database connections do not persist across tests."""
    for db_config in settings.DATABASES.values():
        db_config["CONN_MAX_AGE"] = 0


@pytest.fixture
def event(db):
    """Create a test event with an organizer."""
    organizer = Organizer.objects.create(name="Test Organizer", slug="test-organizer")
    event = Event.objects.create(
        organizer=organizer,
        name="Test Event",
        slug="test-event",
        live=True,
        date_from=now(),
        plugins="veditor",
    )
    return event


@pytest.fixture
def user(db):
    """Create a test user."""
    return User.objects.create_user(email="tester@example.com", password="secret")


@pytest.fixture
def mock_veditor():
    """Provides a running MockVEditor service harness."""
    from tests.mock_veditor import MockVEditor

    with MockVEditor() as mock:
        yield mock
