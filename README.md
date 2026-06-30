# Eclipse

<p align="center">
  <strong>A media hub for anime, movies, shows, manga, light novels, downloads, tracker sync, and in-app playback.</strong>
</p>

<p align="center">
  <a href="https://github.com/Soupy-dev/Eclipse/releases">
    <img alt="GitHub release downloads" src="https://img.shields.io/github/downloads/Soupy-dev/Eclipse/total.svg?style=for-the-badge&label=Downloads&cacheSeconds=3600">
  </a>
  <a href="https://www.patreon.com/soupy698">
    <img alt="Patreon" src="https://img.shields.io/badge/Patreon-Support%20Development-FF424D?style=for-the-badge&logo=patreon&logoColor=white">
  </a>
  <a href="https://ko-fi.com/soupydev">
    <img alt="Ko-fi" src="https://img.shields.io/badge/Ko--fi-Support%20Development-FF5E5B?style=for-the-badge&logo=kofi&logoColor=white">
  </a>
  <a href="https://discord.gg/UjHgGaEbn">
    <img alt="Discord" src="https://img.shields.io/badge/Discord-Join%20Server-5865F2?style=for-the-badge&logo=discord&logoColor=white">
  </a>
</p>

<p align="center">
  <a href="#preview">Preview</a> |
  <a href="#screenshots">Screenshots</a> |
  <a href="#features">Features</a> |
  <a href="#install">Install</a> |
  <a href="#support">Support</a> |
  <a href="#build-configuration">Build</a> |
  <a href="#license">License</a>
</p>

## Why Eclipse

Eclipse was designed to bridge Luna services (more well known as Sora modules) with Stremio addons in one polished app. The goal is simple: search faster, pick the right result with better metadata, watch with stronger controls, keep progress synced, and continue across anime, movies, shows, manga, and novels. Now powered by Aidoku as well. Star the repo, join the Discord, or support on Patreon or Ko-fi if you like my work!

## Screenshots

<table>
  <tr>
    <td align="center" width="20%"><img src="docs/screenshots/home-v2.jpeg" width="140" alt="Home screen"></td>
    <td align="center" width="20%"><img src="docs/screenshots/discover-v2.jpeg" width="140" alt="TV discovery screen"></td>
    <td align="center" width="20%"><img src="docs/screenshots/schedule-v2.jpeg" width="140" alt="Schedule screen"></td>
    <td align="center" width="20%"><img src="docs/screenshots/library-v2.jpeg" width="140" alt="Library screen"></td>
    <td align="center" width="20%"><img src="docs/screenshots/settings-v2.jpeg" width="140" alt="Settings screen"></td>
  </tr>
  <tr>
    <td align="center" width="20%"><strong>Home</strong><br>Featured picks and continue watching</td>
    <td align="center" width="20%"><strong>Discover</strong><br>Catalog rows and rich posters</td>
    <td align="center" width="20%"><strong>Schedule</strong><br>Local and UTC anime air times</td>
    <td align="center" width="20%"><strong>Library</strong><br>Bookmarks and custom collections</td>
    <td align="center" width="20%"><strong>Settings</strong><br>Playback, services, trackers, and backups</td>
  </tr>
</table>


## Features

- Anime, movie, and TV discovery powered by TMDB and AniList metadata
- User-controlled catalogs from TMDB and AniList
- Continue Watching with smarter TMDB and AniList matching
- AniList, MyAnimeList, and Trakt tracker support
- Manga library support with reading progress, collections, and tracker sync
- Light novel support
- Stremio addon support for stream discovery
- Downloads with HLS support
- Backup and restore
- Automatic cache cleanup
- User ratings and private notes
- Anime schedule integration through AniList
- Western schedule by trakt
- MPV playback with subtitle defaults, language defaults, next episode actions, AniSkip, IntroDB, and TheIntroDB support
- A redesigned interface built around browsing, watching, reading, and managing progress
- Customizable UI
- Aidoku support
- And more!

## Install

Get the TestFlight build (Recommended for most iOS users, easiest to download and update):

https://testflight.apple.com/join/FDXvrxVg

AltStore and SideStore users can add this source:

```text
https://raw.githubusercontent.com/Soupy-dev/Eclipse/main/altsource.json
```

## Support

- Join the Discord server for help, updates, and community discussion: https://discord.gg/UjHgGaEbn
- Patreon and Ko-fi are available if you want to support development: https://www.patreon.com/soupy698 or https://ko-fi.com/soupydev but they will never unlock features or paywall anything. They're just ways to support development if you want to. And no, ads/telemetry will never be a thing in this app, so you don't have to worry about that either.

## Notes

- MPV is the advanced in-app player and is default
- VLC is not supported anymore, but may come back if v4 is good.
- Use GitHub Issues for feature requests and bug reports.
- Development started in December 2025



## License

Eclipse is released under the GNU General Public License version 3. See `LICENSE`.

The original Luna project is available at `https://github.com/cranci1/Luna`.

Source code for builds distributed from this repository is available at `https://github.com/Soupy-dev/Eclipse`. If you redistribute an IPA or another binary, provide the corresponding source under GPLv3.

Credits to https://github.com/Aidoku/Aidoku for powering Reader Mode.

Credit to https://github.com/NuvioMedia/NuvioMobile for Nuvio Plugins.

This program comes with no warranty, to the extent permitted by law.

## Bring Your Own Sources

Eclipse ships as an app shell and media manager. It does not provide hosted media, built-in piracy sources, or bundled addons.

Users are responsible for the services and addons they choose to add. The app and developer do not support piracy.

To add a service/addon, click the top right settings icon in the homescreen and then click services. Then click the top right plus icon and choose whichever type of link you copied.
