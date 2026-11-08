#!/bin/bash
# Blocks until the shared state on the server changes (long-poll),
# then exits 0. The widget re-invokes this in a loop so it updates
# instantly -- including when you tick an episode on your phone.
exec python3 "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/anime-client.py" wait
