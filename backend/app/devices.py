"""Turns a User-Agent header into words a person recognises in their device list."""

# Order matters: Edge, Opera and Samsung Internet all mention Chrome and Safari,
# and Chrome mentions Safari.
_BROWSERS = [
    ("Edg", "Edge"),
    ("OPR/", "Opera"),
    ("SamsungBrowser/", "Samsung Internet"),
    ("Firefox/", "Firefox"),
    ("FxiOS/", "Firefox"),
    ("Chrome/", "Chrome"),
    ("CriOS/", "Chrome"),
    ("Safari/", "Safari"),
]
# Android mentions Linux, and iPhones and iPads mention Mac OS X.
_SYSTEMS = [
    ("Android", "Android"),
    ("iPhone", "iPhone"),
    ("iPad", "iPad"),
    ("Windows", "Windows"),
    ("CrOS", "ChromeOS"),
    ("Mac OS X", "Mac"),
    ("Linux", "Linux"),
]


def describe(user_agent: str | None) -> str:
    if not user_agent:
        return "Unknown device"
    if user_agent.startswith("Dart/"):
        # The mobile app signs in through Dart's own HTTP client.
        return "PhysioAI app"
    browser = next((name for token, name in _BROWSERS if token in user_agent), None)
    system = next((name for token, name in _SYSTEMS if token in user_agent), None)
    if browser and system:
        return f"{browser} on {system}"
    return browser or system or "Unknown device"
