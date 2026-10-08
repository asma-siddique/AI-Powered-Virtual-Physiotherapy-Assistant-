"""Settings behaviour that the rest of the app relies on."""

import pytest

from app.config import Settings


@pytest.mark.parametrize("blank", ["", "   "])
def test_blank_database_url_and_secret_count_as_not_set(blank):
    # This is what a line such as "DATABASE_URL=" in .env produces. Development
    # start-up (embedded database, automatic migrations) depends on it.
    settings = Settings(_env_file=None, database_url=blank, jwt_secret=blank)

    assert settings.database_url is None
    assert settings.jwt_secret is None


def test_real_values_are_kept():
    settings = Settings(_env_file=None, database_url="postgresql://host/db", jwt_secret="s" * 40)

    assert settings.database_url == "postgresql://host/db"
    assert settings.resolved_jwt_secret() == "s" * 40
