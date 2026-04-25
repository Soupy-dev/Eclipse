# Eclipse Android Port

This directory contains the Android implementation for the Luna/Eclipse app. It lives beside the existing Apple app and does not change the current iOS target.

The Android namespace uses `dev.soupy.eclipse.android`.

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
- A Luna-inspired Jetpack Compose shell with Luna tabs for Home, Schedule, Downloads, Library, and Search, plus a Kanzen shell for Home, Library, Search, History, and Settings
- Parity-minded core models for TMDB, AniList, Stremio, playback context, and backup data
- Network access using OkHttp plus Kotlin serialization
- Room/DataStore/file-backed persistence for settings, library, downloads, providers, backups, and reader data
- A working Media3 normal-player boundary with subtitle track import, subtitle styling, language defaults, hold-to-speed, double-tap seek, 85s skip, embedded LibVLC playback for the VLC player option, targeted mpv/custom external-player Android handoff, and landscape-lock settings
- Playback can now hydrate AniSkip/TheIntroDB skip segments for resolved sources and exposes manual or auto-skip behavior through the Android player surface
- JS runtime and WebView helper interfaces for the sideload-first provider ecosystem, including a WebView-backed Kanzen module runtime with fetch bridging
- Live TMDB/AniList-backed browse, search, detail, and airing schedule flows, including iOS-parity TMDB movie rows for now playing, upcoming, and top-rated movies
- Persisted Android-side library and continue-watching state, with direct-player progress now syncing typed movie/episode progress, last-source metadata, and resume entries automatically
- Android-owned parity stores for iOS backup sections including progress, catalogs, tracker state, ratings, recommendation cache, Kanzen modules, logs, cache metrics, and recent searches
- A DataStore-backed settings screen with player selection, subtitle/player defaults, next-episode controls, auto-mode, quality-threshold, similarity-algorithm, horror-filter, and auto-cache-clear controls, reader defaults, OAuth/manual tracker account controls, storage diagnostics, logger controls, and iOS-style catalog enable/reorder controls
- Settings backup import/export that restores and re-exports Android-owned backup sections while preserving unsupported/unknown Luna backup data
- Home now respects the backed catalog order/visibility and includes iOS catalog IDs for Just For You, Because You Watched, networks, genres, companies, featured, ranked rows, TMDB rows, and AniList rows, with the backed TMDB horror filter applied to Home rows
- Search now stores recent queries locally, fetches multiple TMDB pages alongside AniList anime results, and applies the backed TMDB horror filter to TMDB matches
- Detail pages now hydrate richer TMDB metadata including content ratings, cast, recommendations, episode stills/runtimes/descriptions, and broader season coverage
- Detail pages now expose watched/unwatched actions, mark-previous-episodes support, and backed user ratings that feed the recommendation cache/user-ratings backup path
- First-pass Stremio addon stream resolution on TMDB movie and series detail pages, with addon manifest diagnostics/configuration-required handling/refresh/embedded configure actions, custom JS provider configuration forms, Auto Mode now respecting backed high-quality threshold and selected similarity algorithm settings, plus a richer AniList-to-TMDB anime bridge with recursive relation-aware matching, episode-count/year scoring, special-season scoring, relation-graph episode reconstruction, and mapped TMDB season metadata for anime episode rows
- Episode-aware stream resolution from detail episode rows instead of only resolving the first series episode
- Torrent-style Stremio results, tokenized `.torrent` URLs, download URIs, and player sources are rejected before playback/download; direct HTTP(S) media streams remain the only accepted Stremio stream shape
- Offline downloads can capture resolved direct HTTP streams, keep separate episode-specific queue entries, enqueue true WorkManager background transfers, package basic HLS playlists with AES-128 keys, download subtitle files, persist local file metadata, pause/cancel/retry captured direct sources, resume interrupted queued/downloading transfers on Downloads startup, verify restored local files, remove local media while keeping queue metadata, clean up completed/title/all queue files plus orphaned app-private files, and play completed local files through the Android player surface
- Settings can display restored AniList/Trakt tracker state, launch AniList/Trakt OAuth, receive Android deep-link callbacks, exchange authorization codes for tokens, refresh OAuth tokens during sync, save manual token/PIN fallback accounts, toggle tracker sync, run manual watched-progress sync, sync AniList-backed manga/novel chapter progress, disconnect accounts, and export that state through the Luna backup shape
- Connected/manual AniList tracker accounts can import the user's AniList anime library into Android Library, including resume entries when AniList episode progress can be converted into a percentage
- Connected/manual AniList tracker accounts can also import the user's AniList manga library into Android Manga/Novel storage, including chapter progress entries and novel-format items
- Backup-backed manga and novel overview surfaces for restored Kanzen library/progress/module data, plus live AniList manga/novel browse/search, active Kanzen module-backed search, Android library save/remove actions, native reader-progress panels with exact chapter marking, jump, next/previous controls, collapsible reader controls, orientation lock, manga zoom, novel auto-scroll, chapter read/unread controls, unread counts, favorite/bookmark collection support, custom manga collection create/delete/add/remove controls, resettable reading progress, and Kanzen module URL add/update/toggle/remove controls on the Manga and Novel tabs
- Kanzen module adds and updates now fetch Luna-compatible manifests, resolve and validate `scriptURL`, preserve real source metadata, support manual update-all actions, run backed due auto-update checks, and keep the edited module list in the iOS-compatible backup path
- Module-backed manga/novel rows now preserve source IDs through save/progress, hydrate richer detail panels through Kanzen `extractDetails`, load module chapter lists in the Android reader panels, can navigate next/previous runtime chapters, request manga page images or novel text through the Kanzen runtime, cache loaded reader chapters for offline reuse, preload the next runtime chapter, and expose reader cache diagnostics/clearing on Manga and Novel
- Settings logger diagnostics can now be shared through Android's native share sheet for parity with the iOS log export flow

## Version choices

The Android dependency versions in `gradle/libs.versions.toml` were chosen from current official release sources, including Android Developers, Kotlin docs, official project release pages, AndroidX WorkManager release notes, and VideoLAN's LibVLC Maven Central artifacts.

## Current limitations

- The full feature set from the Apple app is at the intended Android implementation pass rather than a literal identical runtime. Android now has a real shell, persistence, catalog controls, backup flow, richer detail/progress actions, safer Stremio resolution/config diagnostics with embedded addon configuration, custom provider configuration, relation-reconstructed anime matching, OAuth/manual tracker connection with token refresh, media and manga tracker sync, working manga/novel module detail and reader flows, backed reader settings, reader cache/preload behavior, reader overlays/zoom/orientation/auto-scroll controls, WorkManager-backed direct downloads, embedded VLC, targeted mpv app handoff, and shareable logs.
- Anime-specific source resolution now has a relation-aware AniList-to-TMDB bridge with season metadata, recursive relation seeds, sequel/prequel season assignment, and special-season hints. Android reconstructs AniMap-style episode maps from AniList/TMDB data available at runtime; it does not bundle an external AniMap database file.
- Torrent-style Stremio results are intentionally rejected to match the iOS safety guardrails. Android does not accept magnet/infoHash streams or torrent handoff.
- mpv remains a targeted Android app handoff rather than an embedded library because upstream mpv-android is distributed as a player app, not a reusable Gradle/AAR library. VLC is embedded through LibVLC.

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

1. Run a manual emulator/device smoke test for embedded VLC playback, mpv handoff, WorkManager download pause/resume, provider configuration, and restored backups.
2. Add mocked integration coverage around tracker OAuth refresh, WorkManager retries, provider configuration persistence, and Stremio rejection paths.
3. Continue polishing Kanzen reader HTML/image rendering and gesture feel.
4. Keep expanding edge-case anime mapping fixtures as real AniList/TMDB mismatches are found.
5. Profile APK size/startup after bundling LibVLC native libraries.
