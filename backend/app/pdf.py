"""A small PDF writer: enough to lay out a text report with tables and a line
chart on A4 pages, using only the standard library.

It writes PDF 1.4 with the two built-in Helvetica fonts, so nothing has to be
embedded or installed. Text outside Windows-1252 is replaced rather than
dropped silently into a broken file.
"""

import zlib
from collections.abc import Sequence

A4 = (595.28, 841.89)

# Advance widths of Helvetica for the characters 32 to 126, in 1/1000 of the
# font size. Used to wrap and right-align text.
_WIDTHS = (
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
    333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
)  # fmt: skip

Color = tuple[float, float, float]
BLACK: Color = (0.05, 0.12, 0.18)
GREY: Color = (0.33, 0.43, 0.48)
RULE: Color = (0.87, 0.89, 0.92)


def text_width(text: str, size: float, bold: bool = False) -> float:
    total = 0
    for char in text:
        code = ord(char)
        total += _WIDTHS[code - 32] if 32 <= code <= 126 else 556
    # Helvetica-Bold runs a little wider than the regular face.
    return total * size / 1000 * (1.06 if bold else 1)


def wrap(text: str, size: float, width: float, bold: bool = False) -> list[str]:
    """Breaks [text] into lines no wider than [width], at spaces."""
    lines: list[str] = []
    for paragraph in text.splitlines() or [""]:
        line = ""
        for word in paragraph.split():
            candidate = f"{line} {word}".strip()
            if line and text_width(candidate, size, bold) > width:
                lines.append(line)
                line = word
            else:
                line = candidate
        lines.append(line)
    return lines


def _escape(text: str) -> bytes:
    raw = text.encode("cp1252", errors="replace")
    return raw.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)")


class Page:
    """One page's drawing commands. Coordinates are in points from the top
    left, as a reader thinks of a page; PDF's own origin is the bottom left."""

    def __init__(self, size: tuple[float, float]) -> None:
        self.width, self.height = size
        self._ops: list[bytes] = []

    def _y(self, y: float) -> float:
        return self.height - y

    def text(
        self,
        x: float,
        y: float,
        text: str,
        *,
        size: float = 10,
        bold: bool = False,
        color: Color = BLACK,
        align: str = "left",
    ) -> None:
        """Draws one line of text with its baseline at [y]."""
        if align == "right":
            x -= text_width(text, size, bold)
        elif align == "center":
            x -= text_width(text, size, bold) / 2
        font = b"/F2" if bold else b"/F1"
        self._ops.append(
            b"BT %s %.2f Tf %.3f %.3f %.3f rg %.2f %.2f Td (%s) Tj ET"
            % (font, size, *color, x, self._y(y), _escape(text))
        )

    def line(
        self, x1: float, y1: float, x2: float, y2: float, *, color: Color = RULE, width: float = 0.7
    ) -> None:
        self._ops.append(
            b"%.3f %.3f %.3f RG %.2f w %.2f %.2f m %.2f %.2f l S"
            % (*color, width, x1, self._y(y1), x2, self._y(y2))
        )

    def polyline(self, points: Sequence[tuple[float, float]], *, color: Color, width: float = 1.5) -> None:
        if len(points) < 2:
            return
        path = b" ".join(
            b"%.2f %.2f %s" % (x, self._y(y), b"m" if i == 0 else b"l") for i, (x, y) in enumerate(points)
        )
        self._ops.append(b"%.3f %.3f %.3f RG %.2f w 1 j 1 J %s S" % (*color, width, path))

    def rect(self, x: float, y: float, w: float, h: float, *, fill: Color) -> None:
        self._ops.append(b"%.3f %.3f %.3f rg %.2f %.2f %.2f %.2f re f" % (*fill, x, self._y(y + h), w, h))

    def dot(self, x: float, y: float, radius: float, *, fill: Color) -> None:
        """A filled circle, drawn as four curves."""
        k = radius * 0.5523
        cy = self._y(y)
        self._ops.append(
            b"%.3f %.3f %.3f rg %.2f %.2f m "
            b"%.2f %.2f %.2f %.2f %.2f %.2f c %.2f %.2f %.2f %.2f %.2f %.2f c "
            b"%.2f %.2f %.2f %.2f %.2f %.2f c %.2f %.2f %.2f %.2f %.2f %.2f c f"
            % (
                *fill,
                x + radius,
                cy,
                x + radius,
                cy + k,
                x + k,
                cy + radius,
                x,
                cy + radius,
                x - k,
                cy + radius,
                x - radius,
                cy + k,
                x - radius,
                cy,
                x - radius,
                cy - k,
                x - k,
                cy - radius,
                x,
                cy - radius,
                x + k,
                cy - radius,
                x + radius,
                cy - k,
                x + radius,
                cy,
            )  # fmt: skip
        )

    def content(self) -> bytes:
        return b"\n".join(self._ops)


class Document:
    def __init__(self, *, title: str, author: str = "PhysioAI", size: tuple[float, float] = A4) -> None:
        self.title = title
        self.author = author
        self.size = size
        self.pages: list[Page] = []

    def add_page(self) -> Page:
        page = Page(self.size)
        self.pages.append(page)
        return page

    def render(self) -> bytes:
        """The finished file."""
        objects: list[bytes] = []

        def add(body: bytes) -> int:
            objects.append(body)
            return len(objects)

        catalog = add(b"")  # filled in once the page tree's number is known
        pages = add(b"")
        regular = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        bold = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")
        kids: list[int] = []
        for page in self.pages:
            stream = zlib.compress(page.content())
            content = add(
                b"<< /Length %d /Filter /FlateDecode >>\nstream\n%s\nendstream" % (len(stream), stream)
            )
            kids.append(
                add(
                    b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %.2f %.2f] "
                    b"/Resources << /Font << /F1 %d 0 R /F2 %d 0 R >> >> /Contents %d 0 R >>"
                    % (pages, page.width, page.height, regular, bold, content)
                )
            )
        info = add(
            b"<< /Title (%s) /Author (%s) /Producer (PhysioAI) >>"
            % (_escape(self.title), _escape(self.author))
        )
        objects[catalog - 1] = b"<< /Type /Catalog /Pages %d 0 R >>" % pages
        objects[pages - 1] = b"<< /Type /Pages /Count %d /Kids [%s] >>" % (
            len(kids),
            b" ".join(b"%d 0 R" % kid for kid in kids),
        )

        out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
        offsets = []
        for number, body in enumerate(objects, start=1):
            offsets.append(len(out))
            out += b"%d 0 obj\n%s\nendobj\n" % (number, body)
        xref = len(out)
        out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
        for offset in offsets:
            out += b"%010d 00000 n \n" % offset
        out += b"trailer\n<< /Size %d /Root %d 0 R /Info %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (
            len(objects) + 1,
            catalog,
            info,
            xref,
        )
        return bytes(out)
