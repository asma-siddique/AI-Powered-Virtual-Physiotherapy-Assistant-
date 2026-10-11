"""Row-level data isolation (US 8.1): the database itself refuses to show or
change one patient's data for anyone but that patient and the
physiotherapist they are assigned to now.

The API's own ownership checks stay as they are. This is the second lock: if
one of them is ever wrong or missing, the query still comes back empty,
because PostgreSQL applies its row-level security policies to every statement
the API runs (migration 0012).

How it works: every transaction of a request runs as the unprivileged role
``physioai_app`` and carries who is asking in two settings, ``app.user_id``
and ``app.role``. The policies read those. A request starts as nobody
("anonymous") and becomes somebody only once its token has been checked.
"""

import contextlib
from collections.abc import Iterator

from sqlalchemy import event, text
from sqlalchemy.engine import Connection
from sqlalchemy.orm import Session

from app.models import Account

# The role the policies apply to. It cannot log in; the API switches to it.
APP_ROLE = "physioai_app"

Context = tuple[str, str]
# Before a request has proved who it is from: no patient data at all.
ANONYMOUS: Context = ("", "anonymous")
# Work the system does on its own behalf, with nobody signed in: sending due
# reminders, linking a newly registered patient, seeding. Used on purpose
# and in few places; see `system()`.
SYSTEM: Context = ("", "system")

_KEY = "rls"


def _apply(connection: Connection, context: Context) -> None:
    # LOCAL: both last until the transaction ends, so nothing leaks to the
    # next request that borrows this connection from the pool.
    connection.exec_driver_sql(f"SET LOCAL ROLE {APP_ROLE}")
    connection.execute(
        text("SELECT set_config('app.user_id', :user, true), set_config('app.role', :role, true)"),
        {"user": context[0], "role": context[1]},
    )


@event.listens_for(Session, "after_begin")
def _on_begin(session: Session, transaction: object, connection: Connection) -> None:
    """A request commits several times; each new transaction is told again
    who is asking."""
    _apply(connection, session.info.get(_KEY, ANONYMOUS))


def _set(db: Session, context: Context) -> None:
    db.info[_KEY] = context
    # Also for the transaction already under way.
    _apply(db.connection(), context)


def set_user(db: Session, account: Account) -> None:
    """From here on, this session acts as [account] and sees what they may."""
    _set(db, (str(account.id), account.role.value))


def current(db: Session) -> Context:
    return db.info.get(_KEY, ANONYMOUS)


@contextlib.contextmanager
def system(db: Session) -> Iterator[None]:
    """Runs a block as the system itself, then goes back to whoever was
    asking. For the few things that have to touch a patient's rows before
    anyone is signed in or on nobody's behalf."""
    before = current(db)
    _set(db, SYSTEM)
    try:
        yield
    finally:
        _set(db, before)


def as_system(db: Session) -> Session:
    """Marks a session the system opened for its own work (the reminder
    scheduler, seeding)."""
    db.info[_KEY] = SYSTEM
    return db
