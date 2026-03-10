My fork of Luna. will eventually be merged into the main repo.

Features added:

1: "Mark as watched" and related buttons now work
2: Anilist and trakt sync (works for manga)
3: TMDB and Anilist hybrid system for anime only. Fixes issue of improper anime handling by pure tmdb. Update, fixed known edge cases, its now even more robust and accurate than before.
4: Catalogs provided by tmdb and anilist with control over them
5: Anime schedule provided by anilist
6: Auto clear cache
7: Backup and restore
8: Auto subtitles, auto anime language, Next episode button, AniSkip, and TheIntroDB for VLC only
9: Minor but episodes now have their full descriptions in the services result sheet
10: VLC player (Requires proxy setting enabled to work with every service, otherwise only works with some)
11: Made Crancis Continue Watching respect the TMDB+AniList system
12: Downloads support, ui needed minor revision to add this tab. Settings is now in the top right. HLS downloads are slower due to needing proper playback from mpv and VLC
13: VLC does have subtitle editing. But I just removed pip. I went through many implementations and spent a bunch of time. But VLC just isn't ready for pip, waiting for VLC v4 for better stability and native pip is the best call. I've pretty much pushed VLC as far as it can go.
14: Manga mode completed (ugly ui lowkey but I ain't a designer)
15: Stremio addon support (only ones that return streams, dw they work with downloads and act mostly like regular services)
16: LN support

Notes:

I have 700+ workflows it took a long time. VLC and this Luna in general has come a long way. There are likely minor issues with VLC that can't be fixed/smoothed without v4.


