# Eclipse on macOS

Eclipse has a native macOS target named `Eclipse-macOS`, with standard Apple
Silicon and Intel architectures. It uses SwiftUI/AppKit windows and MPVKit's
native `gpu-next` renderer; it is not a Mac Catalyst wrapper around the iOS
interface.

The native target requires macOS 15.0 or later.

## Supported

- Eclipse-style Home, search, details, real season/episode browsing, bookmarks,
  ratings, Continue Watching, customizable catalogs, and an upcoming-airings
  schedule
- Eclipse JavaScript Services and Stremio addon installation, search,
  resolution, and direct HTTP stream playback
- MPVKit playback with headers, VideoToolbox, PiP, subtitles, audio-track
  switching, speed control, resume positions, menus, and keyboard shortcuts
- Managed video downloads with progress, retry, Reveal, and Export
- CloudKit bookmarks, ratings, movie progress, and episode progress using the
  existing `EclipseMediaState` zone and record schema
- AniList, MyAnimeList, and Trakt OAuth account authentication; AniList and
  MyAnimeList anime playback-progress, rating, and optional reader-progress
  synchronization; and Trakt playback scrobbling
- Additive AniList and MyAnimeList library imports that add matched anime to
  the flat Mac Library without deleting existing titles or downgrading their
  stored state
- Kanzen local-file/PDF/HTML reading, Aidoku source lists and WASM sources,
  search, library history, and bounded offline chapter downloads
- StoreKit support purchases and restore
- Native macOS schedule reminders for Library shows with explicit notification
  permission
- Eclipse player skins, precise seeking, comfort-audio filters, subtitle style
  controls, and bounded MPV stream buffering

## Deliberate Mac exclusions

- Torrent, magnet, and info-hash playback remains excluded. Eclipse's provider
  path accepts direct HTTP(S) media only.
- Eclipse Services share the existing JavaScript provider runtime. Providers
  may present a native macOS verification window when Cloudflare interaction
  is required.
- AVPlayer fallback is excluded because it loses codec, subtitle, and request-
  header parity relative to MPVKit.
- SharePlay is excluded from the Mac target.
- Touch gestures, orientation controls, cellular-only policies, and iOS
  external-player URL schemes do not apply to macOS.
- OpenSubtitles lookup and next-episode prewarming stay hidden until their
  selection or preload runtimes are functional on the Mac target.

## Build

```sh
xcodebuild build \
  -project Eclipse.xcodeproj \
  -scheme Eclipse-macOS \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64'
```

The target uses the existing `app.Eclipse.Soupy` identity and
`iCloud.Eclipse.Soupy` container. A signed build therefore requires a Mac App
Development or distribution provisioning profile for that identifier. For a
compile-only local check, add `CODE_SIGNING_ALLOWED=NO`; CloudKit then stays in
local-only mode instead of initializing without its entitlement.
