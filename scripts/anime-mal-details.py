#!/usr/bin/env python3

import json
import os
import sys
import urllib.request

CONFIG = os.path.expanduser("~/.config/anime-todo/mal.conf")

DETAILS_URL = "https://api.myanimelist.net/v2/anime"


def load_client_id():
    with open(CONFIG, "r", encoding="utf-8") as f:
        for line in f:
            if line.startswith("CLIENT_ID="):
                return line.strip().split("=", 1)[1]

    raise RuntimeError("CLIENT_ID not found in mal.conf")


def get_details(mal_id, client_id):
    url = f"{DETAILS_URL}/{mal_id}?fields=num_episodes,alternative_titles"

    request = urllib.request.Request(
        url,
        headers={"X-MAL-Client-ID": client_id},
    )

    with urllib.request.urlopen(request) as response:
        data = json.load(response)

    num_episodes = data.get("num_episodes")
    english_title = (data.get("alternative_titles") or {}).get("en")

    return num_episodes, english_title


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} MAL_ID", file=sys.stderr)
        sys.exit(1)

    mal_id = int(sys.argv[1])

    try:
        client_id = load_client_id()
        num_episodes, english_title = get_details(mal_id, client_id)
    except Exception as e:
        print(f"Failed to fetch anime details: {e}", file=sys.stderr)
        sys.exit(1)

    # MAL returns 0 for unknown/ongoing episode counts, and many
    # anime simply have no English title -- print an empty line for
    # either rather than failing, so a caller gets whichever field
    # is actually available.
    print(num_episodes if num_episodes else "")
    print(english_title if english_title else "")


if __name__ == "__main__":
    main()
