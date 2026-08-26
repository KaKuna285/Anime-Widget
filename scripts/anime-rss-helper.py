#!/usr/bin/env python3

import http.cookiejar
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

CONFIG = os.path.expanduser("~/.config/anime-todo/qbit.conf")


def load_config():
    config = {}

    with open(CONFIG, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()

            if "=" not in line:
                continue

            key, value = line.split("=", 1)
            config[key.strip()] = value.strip()

    required = ["WEBUI_HOST", "WEBUI_PORT", "WEBUI_USER", "WEBUI_PASS"]
    missing = [k for k in required if k not in config]

    if missing:
        raise RuntimeError(
            f"qbit.conf missing required field(s): {', '.join(missing)}"
        )

    return config


def make_opener():
    cookie_jar = http.cookiejar.CookieJar()
    return urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(cookie_jar)
    )

def base_url(config):
    return f"http://{config['WEBUI_HOST']}:{config['WEBUI_PORT']}"


def login(opener, config):
    url = f"{base_url(config)}/api/v2/auth/login"

    data = urllib.parse.urlencode({
        "username": config["WEBUI_USER"],
        "password": config["WEBUI_PASS"],
    }).encode()

    request = urllib.request.Request(
        url,
        data=data,
        headers={
            "Referer": base_url(config),
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )

    # urlopen already raises HTTPError on any non-2xx status, so
    # reaching this point without an exception means the login
    # succeeded -- older qBittorrent versions return 200 with body
    # "Ok.", newer ones return 204 with an empty body. Either way,
    # no exception here means we're authenticated.
    with opener.open(request) as response:
        response.read()


def flatten_feeds(node, path=""):
    feeds = []

    for name, entry in (node or {}).items():
        current_path = f"{path}\\{name}" if path else name

        if isinstance(entry, dict) and "url" in entry:
            feeds.append({"name": current_path, "url": entry["url"]})
        elif isinstance(entry, dict):
            feeds.extend(flatten_feeds(entry, current_path))

    return feeds


def list_feeds():
    config = load_config()
    opener = make_opener()
    login(opener, config)

    url = f"{base_url(config)}/api/v2/rss/items?withData=false"

    request = urllib.request.Request(
        url,
        headers={"Referer": base_url(config)},
    )

    with opener.open(request) as response:
        tree = json.load(response)

    feeds = flatten_feeds(tree)

    print(json.dumps(feeds, ensure_ascii=False, indent=2))


def create_rule(series_name, feed_url, save_path):
    config = load_config()
    opener = make_opener()
    login(opener, config)

    rule_def = {
        "enabled": True,
        "mustContain": series_name,
        "mustNotContain": "",
        "useRegex": False,
        "episodeFilter": "",
        "smartFilter": False,
        "previouslyMatchedEpisodes": [],
        "affectedFeeds": [feed_url],
        "ignoreDays": 0,
        "lastMatch": "",
        "addPaused": None,
        "assignedCategory": "",
        "savePath": save_path,
        "torrentContentLayout": None,
    }

    url = f"{base_url(config)}/api/v2/rss/setRule"

    data = urllib.parse.urlencode({
        "ruleName": series_name,
        "ruleDef": json.dumps(rule_def),
    }).encode()

    request = urllib.request.Request(
        url,
        data=data,
        headers={
            "Referer": base_url(config),
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )

    with opener.open(request) as response:
        response.read()

    print(f"Created RSS rule '{series_name}' -> {save_path}")

def check_matches(series_name, feed_name):
    config = load_config()
    opener = make_opener()
    login(opener, config)

    url = f"{base_url(config)}/api/v2/rss/items?withData=true"

    request = urllib.request.Request(
        url,
        headers={"Referer": base_url(config)},
    )

    with opener.open(request) as response:
        raw = response.read().decode("utf-8", errors="replace")

    try:
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        data = {}

    feed = data.get(feed_name, {})
    articles = feed.get("articles", []) if isinstance(feed, dict) else []

    needle = series_name.lower()
    titles = []

    for article in articles:
        if not isinstance(article, dict):
            continue

        title = article.get("title", "")

        if needle in title.lower():
            titles.append(title)

    print(json.dumps({
        "totalMatches": len(titles),
        "titles": titles[:5],
    }, ensure_ascii=False))

def print_usage():
    print(
        f"Usage:\n"
        f"  {sys.argv[0]} list-feeds\n"
        f"  {sys.argv[0]} create-rule SERIES_NAME FEED_URL SAVE_PATH\n"
        f"  {sys.argv[0]} check-matches SERIES_NAME FEED_NAME"
    )

def main():
    if len(sys.argv) < 2:
        print_usage()
        sys.exit(1)

    command = sys.argv[1]

    try:
        if command == "list-feeds":
            list_feeds()
        elif command == "create-rule":
            if len(sys.argv) != 5:
                print_usage()
                sys.exit(1)

            create_rule(sys.argv[2], sys.argv[3], sys.argv[4])
        elif command == "check-matches":
            if len(sys.argv) != 4:
                print_usage()
                sys.exit(1)

            check_matches(sys.argv[2], sys.argv[3])
        else:
            print_usage()
            sys.exit(1)

    except urllib.error.URLError as e:
        print(
            f"Could not reach qBittorrent WebUI at "
            f"{os.environ.get('WEBUI_HOST', '?')} -- is it running and "
            f"is the WebUI enabled? ({e})",
            file=sys.stderr,
        )
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
