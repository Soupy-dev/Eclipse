# Eclipse Android Port

This directory is the Android foundation for the Luna/Eclipse port. It lives beside the existing Apple app and does not change the current iOS target.

The Android namespace now uses `dev.soupy.eclipse.android` rather than the earlier `cranci`-based placeholder naming.

## What is implemented here

- A separate Android Gradle project rooted in `android/`
- Modular structure for:
  - `app`
  - `core:design`
  - `core:model`
  - `core:network`
  - `core:storage`
  - `core:player`
  - `core:js`
  - `feature:home`
  - `feature:search`
  - `feature:detail`
  - `feature:schedule`
  - `feature:services`
  - `feature:library`
  - `feature:downloads`
  - `feature:settings`
  - `feature:manga`
  - `feature:novel`
- A Luna-inspired Jetpack Compose shell with navigation across Home, Search, Detail, Schedule, Library, Settings, and the remaining planned feature routes
- Parity-minded core models for TMDB, AniList, Stremio, playback context, and backup data
- Network foundations using OkHttp plus Kotlin serialization
- Room/DataStore/file-backed persistence foundations
- A working Media3 normal-player boundary with subtitle track import, subtitle styling, language defaults, hold-to-speed, double-tap seek, 85s skip, external-player handoff, and landscape-lock settings
- Playback can now hydrate AniSkip/TheIntroDB skip segments for resolved sources and exposes manual or auto-skip behavior through the Android player surface
- JS runtime and WebView helper interfaces for the sideload-first provider ecosystem, including a first-pass WebView-backed Kanzen module runtime with fetch bridging
- Live TMDB/AniList-backed browse, search, detail, and airing schedule flows, including iOS-parity TMDB movie rows for now playing, upcoming, and top-rated movies
- Persisted Android-side library and continue-watching state, with direct-player progress now syncing typed movie/episode progress, last-source metadata, and resume entries automatically
- Android-owned parity stores for iOS backup sections including progress, catalogs, tracker state, ratings, recommendation cache, Kanzen modules, logs, cache metrics, and recent searches
- A DataStore-backed settings screen with player selection, subtitle/player defaults, next-episode controls, auto-mode, quality-threshold, similarity-algorithm, horror-filter, and auto-cache-clear controls, reader defaults, tracker account controls, storage diagnostics, logger controls, and iOS-style catalog enable/reorder controls
- Settings backup import/export that restores and re-exports Android-owned backup sections while preserving unsupported/unknown Luna backup data
- Home now respects the backed catalog order/visibility and includes iOS catalog IDs for Just For You, Because You Watched, networks, genres, companies, featured, ranked rows, TMDB rows, and AniList rows, with the backed TMDB horror filter applied to Home rows
- Search now stores recent queries locally, fetches multiple TMDB pages alongside AniList anime results, and applies the backed TMDB horror filter to TMDB matches
- Detail pages now hydrate richer TMDB metadata including content ratings, cast, recommendations, episode stills/runtimes/descriptions, and broader season coverage
- Detail pages now expose watched/unwatched actions, mark-previous-episodes support, and backed user ratings that feed the recommendation cache/user-ratings backup path
- First-pass Stremio addon stream resolution on TMDB movie and series detail pages, with Auto Mode now respecting backed high-quality threshold and selected similarity algorithm settings, plus a richer AniList-to-TMDB anime bridge with relation-aware matching, episode-count/year scoring, and mapped TMDB season metadata for anime episode rows
- Episode-aware stream resolution from detail episode rows instead of only resolving the first series episode
- Torrent-style Stremio results, tokenized `.torrent` URLs, download URIs, and player sources are rejected before playback/download; direct HTTP(S) media streams remain the only accepted Stremio stream shape
- Offline downloads can capture resolved direct HTTP streams, keep separate episode-specific queue entries, package basic HLS playlists with AES-128 keys, download subtitle files, persist local file metadata, retry captured direct sources, verify restored local files, remove local media while keeping queue metadata, clean up completed/title/all queue files plus orphaned app-private files, and play completed local files through the Android player surface
- Settings can display restored AniList/Trakt tracker state, save manual token/PIN fallback accounts, toggle tracker sync, run manual watched-progress sync, disconnect accounts, and export that state through the Luna backup shape
- Connected/manual AniList tracker accounts can import the user's AniList anime library into Android Library, including resume entries when AniList episode progress can be converted into a percentage
- Connected/manual AniList tracker accounts can also import the user's AniList manga library into Android Manga/Novel storage, including chapter progress entries and novel-format items
- Backup-backed manga and novel overview surfaces for restored Kanzen library/progress/module data, plus live AniList manga/novel browse/search, active Kanzen module-backed search, Android library save/remove actions, native reader-progress panels with exact chapter marking, jump, next/previous controls, chapter read/unread controls, unread counts, favorite/bookmark collection support, custom manga collection create/delete/add/remove controls, resettable reading progress, and Kanzen module URL add/update/toggle/remove controls on the Manga and Novel tabs
- Kanzen module adds and updates now fetch Luna-compatible manifests, resolve and validate `scriptURL`, preserve real source metadata, support manual update-all actions, run backed due auto-update checks, and keep the edited module list in the iOS-compatible backup path
- Module-backed manga/novel rows now preserve source IDs through save/progress, hydrate richer detail panels through Kanzen `extractDetails`, load module chapter lists in the Android reader panels, can navigate next/previous runtime chapters, and can request manga page images or novel text through the Kanzen runtime

## Version choices

The Android dependency versions in `gradle/libs.versions.toml` were chosen from current official release sources on April 23, 2026, including Android Developers, Kotlin docs, and official project release pages.

## Current limitations

- The full feature set from the Apple app is not finished yet. Android is now roughly 85% of the way to iOS parity: it has a real shell, persistence, catalog controls, backup flow, richer detail/progress actions, first-pass Stremio resolution, working manga/novel module detail and reader flows, and backed reader settings applied to Android reader rendering, but it is still short of full parity.
- Anime-specific source resolution now has a relation-aware AniList-to-TMDB bridge with season metadata, but it still does not yet reconstruct full sequel graphs, orphaned seasons, or AniMap specials to the same depth as the Apple app.
- Torrent-style Stremio results are intentionally rejected to match the iOS safety guardrails. Android does not accept magnet/infoHash streams or torrent handoff.
- OAuth tracker login, advanced reader overlays/preloading/caching, and native VLC/mpv backends are still earlier-stage compared with the Apple app. Android now has first-pass Kanzen module search/chapter/content extraction, native reader-progress shells for manga/novels with backed mode/font/spacing/margin/alignment settings, Media3 owns the parity-backed playback implementation for direct streams, and manual tracker sync now covers watched local progress for connected AniList/Trakt accounts.

## Running on Windows

1. Open Android Studio and choose `Open`, then select the `android/` directory in this repo.
2. Let Gradle sync. The repo already includes `gradlew.bat`, so Android Studio can use the checked-in wrapper.
3. Create an emulator in `Device Manager`.
   Recommended starter target: a Pixel-class phone running a recent Google Play image.
4. Start the emulator.
5. In Android Studio, choose the `app` run configuration and click `Run`.

You can also build from a terminal:

`cd android`

`.\gradlew.bat :app:assembleDebug`

The debug APK will land under `android/app/build/outputs/apk/debug/`.

## Next recommended steps

1. Continue hardening the anime-specific AniList/TMDB hybrid flow with full sequel/orphan season reconstruction and AniMap special/OVA mapping.
2. Broaden Stremio support only for safe direct URL streams, subtitles, headers, and addon configuration while continuing to reject torrents.
3. Expand tracker OAuth, AniList import, and manga progress sync on top of the new watched-progress sync path.
4. Continue expanding Kanzen reader parity with richer HTML/image rendering, chapter preloading/caching, reader overlays, and offline reader cache behavior.
5. Keep hardening downloads with true background pause/resume behavior, richer transfer progress, and more offline playback edge cases.
