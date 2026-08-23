Anime-Widget

A lightweight KDE Plasma 6 widget for keeping track of newly downloaded anime episodes.

 Anime-Widget displays newly downloaded episodes as a persistent checklist. Once an episode is checked off, it is removed from the list and recorded in a local history so it can be undone if needed.

Features
Displays newly downloaded anime episodes in a compact Plasma widget
Persistent checklist — checked episodes are remembered
Undo the most recently completed episode
Groups episodes by series
Automatically refreshes at a configurable interval
MyAnimeList integration for updating episode progress
Works with local anime download automation
Keeps personal anime data and authentication tokens outside the repository

Requirements
KDE Plasma 6
Bash
Python 3
kpackagetool6
curl
A local setup that calls anime-downloaded.sh when new episodes are downloaded

MyAnimeList integration additionally requires a MyAnimeList API application.

Installation

Clone the repository and run the installer:

git clone https://github.com/KaKuna285/Anime-Widget.git
cd Anime-Widget
./install.sh

The installer:

Installs the Plasma widget.
Copies the helper scripts to ~/.local/bin/.
Sets the required executable permissions.
Upgrades an existing installation when appropriate.

After installation, add Anime-Widget to your Plasma desktop or panel.

Configuration

The widget can be configured through its Plasma settings.


The helper scripts can communicate with MyAnimeList to retrieve and update anime watching status.

Run the authentication script to connect your MAL account:

~/.local/bin/anime-mal-auth.py

Authentication data is stored locally in:

~/.config/anime-todo/mal-token.json

The token is never stored in the Git repository.

Local Data

Anime-Widget stores its runtime data in the user's home directory:

~/.local/share/anime-todo.json
~/.local/share/anime-history.json
~/.local/share/anime-mal.log
~/.config/anime-todo/mal-token.json

These files contain personal runtime data and authentication information and are intentionally excluded from Git.

Updating

If you installed the project by cloning the repository:

cd ~/anime-todo
git pull
./install.sh

The installer will update both the helper scripts and the Plasma widget.

License

MIT License.
