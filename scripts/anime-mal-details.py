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


def get_num_episodes(mal_id, client_id):
    url = f"{DETAILS_URL}/{mal_id}?fields=num_episodes"

    request = urllib.request.Request(
        url,
        headers={"X-MAL-Client-ID": client_id},
    )

    with urllib.request.urlopen(request) as response:
        data = json.load(response)

    return data.get("num_episodes")


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} MAL_ID", file=sys.stderr)
        sys.exit(1)

    mal_id = int(sys.argv[1])

    try:
        client_id = load_client_id()
        num_episodes = get_num_episodes(mal_id, client_id)
    except Exception as e:
        print(f"Failed to fetch episode count: {e}", file=sys.stderr)
        sys.exit(1)

    # MAL returns 0 for ongoing/unknown-length series -- treat as
    # "unknown" too, since we can't detect a final episode either way.
    if not num_episodes:
        sys.exit(1)

    print(num_episodes)


if __name__ == "__main__":
    main()
