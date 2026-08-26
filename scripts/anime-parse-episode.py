#!/usr/bin/env python3
"""
Extract release kind, season, and episode number from a torrent/
release file name.

Tries several common naming conventions, most specific first, and
prints three lines on success:

    KIND
    SEASON
    EPISODE

KIND is one of: episode, movie, ova, special.

Exits with status 1 and prints nothing if no pattern matches. Season
defaults to 1 for absolute-numbered releases and for movie/OVA/
special items, since each MAL entry is already season/entry-scoped
by which folder/RSS rule downloaded it.

An optional second argument -- a known series name (typically the
download folder name) -- is used to avoid mistaking a number that's
part of the *title itself* (e.g. "86", "Zom 100") for an episode
number. If the real episode number happens to match a number in the
title, parsing fails rather than silently guessing wrong.
"""

import re
import sys


def extract_title_numbers(title):
    return set(re.findall(r"(?<!\d)\d{1,4}(?!\d)", title))

def strip_known_title(name, known_name):
    if not known_name:
        return name

    return re.sub(re.escape(known_name), " ", name, flags=re.I)

def mask_title_numbers(name, title_numbers):
    if not title_numbers:
        return name

    pattern = r"(?<!\d)(?:%s)(?!\d)" % "|".join(
        re.escape(n) for n in sorted(title_numbers, key=len, reverse=True)
    )

    return re.sub(pattern, lambda m: "#" * len(m.group(0)), name)


KIND_MARKERS = {
    "movie": "movie",
    "ova": "ova",
    "oad": "ova",
    "special": "special",
    "specials": "special",
    "sp": "special",
}


def try_kind_marker(name):
    m = re.search(
        r"\b(Movie|OVA|OAD|Specials?|SP)(?![A-Za-z])\.?\s*(\d{1,3})?",
        name,
        re.I,
    )

    if not m:
        return None

    kind = KIND_MARKERS[m.group(1).lower()]
    number = int(m.group(2)) if m.group(2) else 1

    return kind, 1, number


def try_patterns(name, known_name=""):
    # 1. Classic SxxEyy, with or without a separator between the two
    #    parts ("S01E03", "S01 - E03", "S01.E03", "s1e3").
    m = re.search(r"S(\d{1,2})[\s._-]*E(\d{1,4})", name, re.I)
    if m:
        return "episode", int(m.group(1)), int(m.group(2))

    # 2. "1x03" scene-style season x episode.
    m = re.search(r"(?<!\d)(\d{1,2})x(\d{2,4})(?!\d)", name, re.I)
    if m:
        return "episode", int(m.group(1)), int(m.group(2))

    # 3. Season spelled out with a separate episode marker,
    #    e.g. "Season 2 Episode 05", "Season 2 - Ep05".
    m = re.search(
        r"Season\s*(\d{1,2}).{0,10}?(?:Episode|Ep)\.?\s*(\d{1,4})",
        name,
        re.I,
    )
    if m:
        return "episode", int(m.group(1)), int(m.group(2))

    # 4. Movie / OVA / OAD / Special marker, with an optional part
    #    number ("Movie 2", "OVA2", "SP01"). Checked before the
    #    generic absolute-number patterns since an explicit keyword
    #    is more specific than a bare number. The known series name
    #    is stripped first so a title that itself contains a marker
    #    word can't be mistaken for the marker.
    kind_result = try_kind_marker(strip_known_title(name, known_name))
    if kind_result:
        return kind_result

    # From here on, patterns are ambiguous absolute-number matches --
    # mask out any number that's part of the known series name first,
    # so a title like "86" or "Zom 100" can't be mistaken for an
    # episode number.
    title_numbers = extract_title_numbers(known_name) if known_name else set()
    masked = mask_title_numbers(name, title_numbers)

    # 5. Absolute episode number, fansub style. Handles a leading
    #    dash if present ("Show - 12 [1080p].mkv") but doesn't
    #    require one ("Show 1085 [1080p].mkv", "Show 1085.mkv").
    #    Excludes anything immediately followed by "p" so it can't
    #    grab a resolution tag like "1080p" or "720p" by mistake.
    #    Season assumed 1.
    m = re.search(
        r"(?:-\s*)?(?<!\d)(\d{2,4})(?!\d)(?!p)(?:v\d+)?"
        r"(?=\s*(?:\[|\(|\.\w{2,4}$|$))",
        masked,
    )
    if m:
        return "episode", 1, int(m.group(1))

    # 6. Explicit "Episode NN" / "Ep NN" without a season marker.
    m = re.search(r"\b(?:Episode|Ep)\.?\s*(\d{1,4})\b", masked, re.I)
    if m:
        return "episode", 1, int(m.group(1))

    # 7. Bare "Exx" with no season at all (rare, last resort).
    m = re.search(r"(?<![A-Za-z])E(\d{2,4})(?!\d)", masked, re.I)
    if m:
        return "episode", 1, int(m.group(1))

    return None


def main():
    if len(sys.argv) not in (2, 3):
        print(
            "Usage: anime-parse-episode.py TORRENT_NAME [KNOWN_NAME]",
            file=sys.stderr,
        )
        sys.exit(1)

    torrent_name = sys.argv[1]
    known_name = sys.argv[2] if len(sys.argv) == 3 else ""

    result = try_patterns(torrent_name, known_name)

    if result is None:
        sys.exit(1)

    kind, season, episode = result
    print(kind)
    print(season)
    print(episode)


if __name__ == "__main__":
    main()
