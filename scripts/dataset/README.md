# Franchise Dataset Pipeline

`build_franchise_dataset.py` sweeps AniList's GraphQL API (partitioned by
season year to stay under the API's 5,000-results-per-query-shape cap),
computes franchise connected components over typed SEQUEL/PREQUEL/SEASON
relation edges, joins AniMap's TMDB/TVDB/Kitsu mapping columns, and emits:

- `franchises-meta-v1.json` — schema version, build watermark, and three
  compact indexes: `componentRangeById` (byte ranges into the blob),
  `componentIdByAniListId`, `componentIdByTmdbShowId`.
- `franchises-blob-v1.bin` — concatenated per-component JSON slices, designed
  to be memory-mapped by the app (clean file-backed pages, same layout as the
  AniMap v3 global index).

The `franchise-dataset.yml` workflow rebuilds it daily and replaces the assets
on the rolling `franchise-dataset-v1` release, which the app downloads.

Side-story/special edges are retained per member (for the specials surface)
but never merge components. `NOT_YET_RELEASED` entries are included and
filtered client-side, because the notifications feature surfaces upcoming
seasons while the regular season list excludes them.

Data sources: [AniList](https://anilist.co) (metadata and relations, fetched
at public API rate limits) and [AniMap](https://animap.s0n1c.ca) (TMDB
mappings). This dataset is a derived cache for Eclipse's own use; both
services remain the authoritative sources and are credited in the app's
acknowledgements.
