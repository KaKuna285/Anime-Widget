#!/usr/bin/env python3

import json
import os
import urllib.request
import urllib.parse

TOKEN_FILE = os.path.expanduser(
    "~/.config/anime-todo/mal-token.json"
)

MAL_ID = 52991

with open(TOKEN_FILE, "r", encoding="utf-8") as f:
    tokens = json.load(f)

access_token = tokens["access_token"]


def get(url):
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {access_token}"
        }
    )

    with urllib.request.urlopen(request) as response:
        return json.load(response)


print("=== Searching your MAL anime list ===")

params = urllib.parse.urlencode({
    "anime_id": MAL_ID,
    "limit": 10
})

data = get(
    "https://api.myanimelist.net/v2/users/@me/animelist?"
    + params
)

print(json.dumps(data, indent=2, ensure_ascii=False))
