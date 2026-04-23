Eclipse is my fork of Luna. Has no affiliation with the parent repo. And user is responsible for what they do with the app. Does not come with services or addons. Use GitHub Issues for feature requests and bug reports

## Overview

Eclipse extends Luna with a broader feature set for anime, manga, light novels, downloads, and playback controls.

## Install

AltStore and SideStore users can add this source:

`https://raw.githubusercontent.com/Soupy-dev/Luna/main/altsource.json`

Releases are distributed as GitHub Release IPA assets. Before publishing a new source update, make sure `altsource.json` points to the uploaded `.ipa` and that the version, build, date, and `size` fields match the release asset.

## Main changes

1. Mark as watched actions are implemented.
2. AniList and Trakt sync are available, including manga support.
3. Anime handling uses a TMDB and AniList hybrid flow with fixes for known edge cases.
4. Catalogs from TMDB and AniList are available with user control.
5. Anime schedule data is integrated through AniList.
6. Automatic cache clearing is supported.
7. Backup and restore are included.
8. VLC playback includes subtitle and language defaults, next episode actions, AniSkip, and TheIntroDB support.
9. Episode descriptions are shown in service result sheets.
10. Continue Watching is aligned with the TMDB and AniList hybrid logic.
11. Downloads are supported, including an HLS pipeline.
12. Stremio stream addons are supported and work with downloads.
13. Manga mode is available.
14. Light novel support is available.
15. The app UI has been overhauled.

## Notes

- VLC is the preferred in-app player in this fork.
- Picture in Picture is not enabled for VLC due to current VLC limitations.



