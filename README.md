# Eclipse

<p align="center">
  <strong>A media hub for anime, movies, shows, manga, light novels, downloads, tracker sync, and in-app playback.</strong>
</p>

<p align="center">
  <a href="https://github.com/Soupy-dev/Eclipse/releases">
    <img alt="GitHub release downloads" src="https://img.shields.io/github/downloads/Soupy-dev/Eclipse/total.svg?style=for-the-badge&label=Downloads&cacheSeconds=3600">
  </a>
  <a href="https://ko-fi.com/soupydev">
    <img alt="Ko-fi" src="https://img.shields.io/badge/Ko--fi-Support%20Development-FF5E5B?style=for-the-badge&logo=kofi&logoColor=white">
  </a>
  <a href="https://discord.gg/cuhAwNwh25">
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

Eclipse was designed to bridge Luna services (more well known as Sora modules) with Stremio addons in one polished app. The goal is simple: search faster, pick the right result with better metadata, watch with stronger controls, keep progress synced, and continue across anime, movies, shows, manga, and novels. Now powered by Mangayomi, SkyStream, and Nuvio as well. Star the repo, join the Discord, or support on Ko-fi if you like my work!

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
- Mangayomi, SkyStream, Nuvio support
- And more!

## Install

Get the TestFlight build (Recommended for latest updates):

https://testflight.apple.com/join/FDXvrxVg

Get the App Store build:

https://apps.apple.com/us/app/eclipse-media-hub/id6779367402

## Support

- Join the Discord server for help, updates, and community discussion: https://discord.gg/UjHgGaEbn
- Ko-fi is available if you want to support development: https://ko-fi.com/soupydev but it will never unlock features or paywall anything. It's just a way to support development if you want to. And no, ads/telemetry will never be a thing in this app, so you don't have to worry about that either.

## Notes

- MPV is the advanced in-app player and is default
- VLC is not supported anymore, but may come back if v4 is good.
- Use GitHub Issues or the discord for feature requests and bug reports.
- Development started in December 2025
- Ipas are no longer supported


## Bring Your Own Sources

Eclipse ships as an app shell and media manager. It does not provide hosted media, built-in piracy sources, or bundled addons.

Users are responsible for the services and addons they choose to add. The app and developer do not support piracy.

To add a service/addon, click the top right settings icon in the homescreen and then click services. Then click the top right plus icon and choose whichever type of link you copied.


## Credits and acknowledgements

Eclipse is built on the work of many projects and services:

- [Luna](https://github.com/cranci1/Luna) is the original upstream project from which Eclipse was derived.
- [SkyStream](https://github.com/akashdh11/skystream), created by Akash, defined the plugin format and behavior supported by Eclipse's SkyStream compatibility layer. SkyStream plugins are independent projects and are not bundled with Eclipse.
- [SkyStream Tools](https://github.com/akashdh11/skystream-tools) (GPLv3) provides the reference SDK and extractor behavior adapted by Eclipse's local compatibility layer.
- [Nuvio](https://github.com/NuvioMedia/NuvioMobile) defined the plugin format and behavior supported by Eclipse's Nuvio compatibility layer. Nuvio plugins are independent projects and are not bundled with Eclipse.
- [SoraCore](https://github.com/cranci1/SoraCore) (GPLv3) is no longer linked as a dependency, but Eclipse's local service runtime and network layer are adapted from it.
- Runtime libraries and components include [FakeWebKit](https://github.com/undeaDD/FakeWebKit) (GPLv3), [Kingfisher](https://github.com/onevcat/Kingfisher) (MIT), [Nuke](https://github.com/kean/Nuke) (MIT), [PLCrashReporter](https://github.com/microsoft/plcrashreporter), [SwiftSoup](https://github.com/scinfu/SwiftSoup) (MIT), [Texture](https://github.com/Skittyblock/Texture) (Apache 2.0), [Wasm3](https://github.com/Skittyblock/Wasm3) (MIT), and [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (MIT).
- Playback uses Eclipse's [MPVKit fork](https://github.com/Soupy-dev/MPVKit), based on [MPVKit](https://github.com/mpvkit/MPVKit), and the multimedia projects bundled by MPVKit, including [mpv](https://github.com/mpv-player/mpv), [FFmpeg](https://github.com/FFmpeg/FFmpeg), and [MoltenVK](https://github.com/KhronosGroup/MoltenVK).
- The Enhanced Upscaling options bundle third-party mpv user shaders under `Eclipse/Player/Shaders`, each alongside its full license text: [ArtCNN](https://github.com/Artoriuz/ArtCNN) (`ArtCNN_C4F16.glsl` and the denoise-and-sharpen `ArtCNN_C4F16_DS.glsl`, MIT, © 2024 Joao Chrisostomo and Kacper Michajłow) for animation, and [AMD FidelityFX Super Resolution 1](https://github.com/GPUOpen-Effects/FidelityFX-FSR) (`AMD_FSR1_EASU_RCAS.glsl`, MIT, © 2021 Advanced Micro Devices, Inc.) for live action. Eclipse's mpv GLSL adaptation of FSR 1 is based on hooke007's `AMD_FSR1_RT` port and uses EASU with conservative RCAS sharpening. The shader files are also their corresponding source.
- Optional metadata, tracking, subtitle, schedule, mapping, and skip-data features use services including [TMDB](https://www.themoviedb.org), [AniList](https://anilist.co), [MyAnimeList](https://myanimelist.net), [Trakt](https://trakt.tv), [TVmaze](https://www.tvmaze.com), [Jikan](https://jikan.moe), [Kitsu](https://kitsu.io), [AniMap](https://animap.s0n1c.ca), [AniSkip](https://aniskip.com), [TheIntroDB](https://theintrodb.org), [IntroDB](https://introdb.app), [OpenSubtitles](https://www.opensubtitles.com), and the [Stremio addon protocol](https://github.com/Stremio/stremio-addon-sdk).

This product uses the TMDB API but is not endorsed or certified by TMDB.

All product names, trademarks, services, and projects belong to their respective owners. Their inclusion above is an acknowledgement, not a claim of affiliation or endorsement. Each dependency and service remains subject to its own license or terms.

License links, copyright notices, and the expanded component inventory are available in Eclipse under **Settings > Legal & Source > Third-Party Notices**.

## License

Eclipse is released under the GNU General Public License version 3. See `LICENSE`.

Source code for builds distributed from this repository is available at `https://github.com/Soupy-dev/Eclipse`. If you redistribute an IPA or another binary, provide the corresponding source under GPLv3.

This program comes with no warranty, to the extent permitted by law.
