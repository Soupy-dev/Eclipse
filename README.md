# Eclipse

Eclipse is a feature-rich fork of Luna for iOS, built for anime, movies, shows, manga, light novels, downloads, tracker sync, and a stronger in-app playback experience.

Eclipse is a modified fork of Luna, originally developed at `https://github.com/cranci1/Luna`. Eclipse is not affiliated with the original Luna project. The app does not include content services, addons, or media. Users are responsible for the services and addons they choose to add. The app and dev do not support piracy.

If you don't know how to sideload, dont worry! Here's a recommended guide https://gist.github.com/sinceohsix/688637ac04695d1ff38f844acc8ba7f3, if you don't want to use SideStore there are other options too, google and reddit r/sideloaded have great guides.

## Why Eclipse

Eclipse was designed to bridge the gap between Luna services and stremio addons. It brings streaming sources, Stremio addons, local downloads, anime metadata, manga reading, light novels, playback progress, ratings, and tracker sync into a single app with a modern interface.

The goal is simple: search faster, pick the right result with better metadata, watch with stronger controls, keep progress synced, and continue across anime, movies, shows, manga, and novels.

## Highlights

- Anime, movie, and TV discovery powered by a TMDB and AniList hybrid flow
- User-controlled catalogs from TMDB and AniList
- Continue Watching with smarter TMDB and AniList matching
- AniList, MyAnimeList, and Trakt tracker support
- Manga support with library, reading progress, collections, and tracker sync
- Light novel support
- Stremio addon support for stream discovery
- Downloads with HLS support
- Backup and restore
- Automatic cache cleanup
- User ratings and private notes
- Anime schedule integration through AniList
- Episode descriptions in service result sheets
- VLC playback with subtitle defaults, language defaults, next episode actions, AniSkip, and TheIntroDB support
- A redesigned Eclipse interface built around browsing, watching, reading, and managing progress

## Install

AltStore and SideStore users can add this source:

`https://raw.githubusercontent.com/Soupy-dev/Luna/main/altsource.json`

## Bring Your Own Sources

Eclipse ships as an app shell and media manager. It does not provide hosted media, built-in piracy sources, or bundled addons.

## License

Eclipse is released under the GNU General Public License version 3. See `LICENSE`.

The original Luna project is available at `https://github.com/cranci1/Luna`.

Source code for builds distributed from this repository is available at `https://github.com/Soupy-dev/Luna`. If you redistribute an IPA or another binary, provide the corresponding source under GPLv3.

This program comes with no warranty, to the extent permitted by law.

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

- VLC is the preferred in-app player in this fork.
- VLC uses the Swift Package Manager `VLCKitSPM` build.
- Picture in Picture is not enabled for VLC because of current VLCKit stability limits.
- Use GitHub Issues for feature requests and bug reports.
- The app does use AI for development. As I don't know swift well (learning other languages like Java and soon C, not swift). Just for transparency. The app gets tested a ton, and I do try to make sure the code looks okay.
- Patreon is not required and will never block any feature. Just a way to help out if you want.

## Support

Patreon support is optional and does not unlock features, media, services, addons, or special access to content.

Support development here:

`https://www.patreon.com/c/soupy698`
