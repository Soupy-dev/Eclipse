# Eclipse

<p align="center">
  <strong>A media hub for anime, movies, shows, manga, light novels, downloads, tracker sync, and in-app playback.</strong>
</p>

<p align="center">
  <a href="#screenshots">Screenshots</a> |
  <a href="#features">Features</a> |
  <a href="#install">Install</a> |
  <a href="#build-configuration">Build</a> |
  <a href="#license">License</a>
</p>

Eclipse is a feature rich fork of Luna for iOS. It keeps Luna's service driven foundation and adds a stronger browsing, Stremio addon, metadata, download, and playback experience.

Eclipse is a modified fork of Luna, originally developed at `https://github.com/cranci1/Luna`. Eclipse is not affiliated with the original Luna project.

## Screenshots

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/home-featured.jpeg" width="170" alt="Home screen"></td>
    <td align="center"><img src="docs/screenshots/discover-tv.jpeg" width="170" alt="TV discovery screen"></td>
    <td align="center"><img src="docs/screenshots/schedule.jpeg" width="170" alt="Schedule screen"></td>
    <td align="center"><img src="docs/screenshots/library-collections.jpeg" width="170" alt="Library screen"></td>
    <td align="center"><img src="docs/screenshots/settings.jpeg" width="170" alt="Settings screen"></td>
  </tr>
  <tr>
    <td align="center"><strong>Home</strong><br>Featured picks and continue watching</td>
    <td align="center"><strong>Discover</strong><br>Catalog rows and rich posters</td>
    <td align="center"><strong>Schedule</strong><br>Local and UTC anime air times</td>
    <td align="center"><strong>Library</strong><br>Bookmarks and custom collections</td>
    <td align="center"><strong>Settings</strong><br>Playback, services, trackers, and backups</td>
  </tr>
</table>

## Why Eclipse

Eclipse was designed to bridge Luna services with Stremio addons in one polished app. The goal is simple: search faster, pick the right result with better metadata, watch with stronger controls, keep progress synced, and continue across anime, movies, shows, manga, and novels.

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
- Episode descriptions in service result sheets
- VLC playback with subtitle defaults, language defaults, next episode actions, AniSkip, and TheIntroDB support
- A redesigned interface built around browsing, watching, reading, and managing progress

## Install

AltStore and SideStore users can add this source:

```text
https://raw.githubusercontent.com/Soupy-dev/Luna/main/altsource.json
```

New to sideloading? This guide is a good starting point:

```text
https://gist.github.com/sinceohsix/688637ac04695d1ff38f844acc8ba7f3
```

SideStore is not required. Other sideloading options work too, and `r/sideloaded` has many community guides.



## Build Configuration

Secrets and API keys are loaded from ignored local configuration files instead of tracked source files.

For iOS, copy `Build.local.xcconfig.example` to `Build.local.xcconfig` and fill in the values you need.

For Android, copy `android/local.properties.example` to `android/local.properties` and fill in the values you need. Gradle also accepts matching environment variables or Gradle properties.

Configured keys include:

- `TMDB_API_KEY`
- `ANILIST_CLIENT_ID`
- `ANILIST_CLIENT_SECRET`
- `TRAKT_CLIENT_ID`
- `TRAKT_CLIENT_SECRET`
- `MAL_CLIENT_ID`
- `MAL_CLIENT_SECRET`

## Notes

- VLC is the preferred in-app player in this fork. MPV is undergoing a rewrite to make it up to standard.
- VLC uses the Swift Package Manager `VLCKitSPM` build.
- Picture in Picture is not enabled for VLC because of current VLCKit stability limits.
- Use GitHub Issues for feature requests and bug reports.
- The app does use AI for development. As I don't know swift well (learning other languages like Java and soon C, not swift). Just for transparency. The app gets tested a ton, and I do try to make sure the code looks okay
- Patreon support is optional and I will never paywall any feature or version.

## Support

Patreon support is optional and does not unlock features, media, services, addons, or special access to content.

Support development here:

https://www.patreon.com/c/soupy698

## License

Eclipse is released under the GNU General Public License version 3. See `LICENSE`.

The original Luna project is available at `https://github.com/cranci1/Luna`.

Source code for builds distributed from this repository is available at `https://github.com/Soupy-dev/Luna`. If you redistribute an IPA or another binary, provide the corresponding source under GPLv3.

This program comes with no warranty, to the extent permitted by law.

## Bring Your Own Sources

Eclipse ships as an app shell and media manager. It does not provide hosted media, built-in piracy sources, or bundled addons.

Users are responsible for the services and addons they choose to add. The app and developer do not support piracy.
