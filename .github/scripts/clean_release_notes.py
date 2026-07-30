#!/usr/bin/env python3
"""Strip emoji and long dashes from a release notes file.

Reads the given file, writes the cleaned text to stdout.

    python .github/scripts/clean_release_notes.py RELEASE_NOTES_4x02.md
"""

import re
import sys

# Em dash, en dash, horizontal bar, figure dash. Not U+2212 MINUS SIGN:
# that one is arithmetic, and "-1" must not become "- 1".
LONG_DASHES = "—–―‒"

DASH_WITH_SPACES = re.compile(r" *[" + LONG_DASHES + r"] *")


def is_emoji(ch: str) -> bool:
    """True for pictographic characters and their modifiers.

    Unicode has no 'is emoji' property in the stdlib, so this goes by the
    pictographic blocks. Deliberately narrow: the degree sign, currency
    symbols and arrows sit outside these ranges and belong in prose.
    """
    if ch in "︎️‍":  # variation selectors, ZWJ
        return True
    code = ord(ch)
    return (
        0x1F000 <= code <= 0x1FAFF  # pictographs, emoticons, symbols
        or 0x2600 <= code <= 0x27BF  # misc symbols, dingbats
        or 0x1F1E6 <= code <= 0x1F1FF  # regional indicators (flags)
        or 0xE0020 <= code <= 0xE007F  # tag characters
    )


def clean(text: str) -> str:
    text = "".join(ch for ch in text if not is_emoji(ch))

    # A long dash always separates words, so " - " is right whether or not
    # the original had spaces around it.
    text = DASH_WITH_SPACES.sub(" - ", text)

    lines = []
    for line in text.split("\n"):
        # Removing an emoji leaves a double space behind: "## <gone> Fixes".
        # Leading indentation is markdown structure, so only squeeze runs
        # of spaces after the first non-space character.
        indent = line[: len(line) - len(line.lstrip(" "))]
        line = indent + re.sub(r"  +", " ", line.lstrip(" ")).rstrip()
        lines.append(line if line.strip() else "")

    text = "\n".join(lines)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip() + "\n"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as fh:
        text = clean(fh.read())
    # Write bytes: on Windows the text layer would turn every \n into \r\n.
    sys.stdout.buffer.write(text.encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
