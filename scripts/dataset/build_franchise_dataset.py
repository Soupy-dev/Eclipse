#!/usr/bin/env python3
"""Eclipse franchise-dataset builder (v4).

Walks all of AniList offline, computes franchise connected components over
typed SEQUEL/PREQUEL/SEASON relations, joins AniMap TMDB mappings, and emits:

  franchises-meta-v1.json  - schema/version, watermark, compact indexes
  franchises-blob-v1.bin   - per-component packed JSON slices (byte ranges
                             recorded in the meta, mmap-friendly; same shape
                             as the app's AniMap v3 global index)

AniList caps Page pagination at 5,000 results per query shape and has no id
cursor (`id_greater` is not in the schema), so the sweep is PARTITIONED:
one partition per seasonYear (each far below the cap), plus plain ID-asc and
ID-desc partitions to cover entries with no season year (very old entries and
not-yet-released announcements). Partitions checkpoint independently, so
interrupted runs resume. Rate limiting adapts to AniList headers.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.expanduser(os.environ.get("ECLIPSE_DATASET_DIR", "~/Documents/Eclipse/_claude_ops/dataset"))
PAGES_PATH = os.path.join(ROOT, "pages.jsonl")
PARTS_PATH = os.path.join(ROOT, "partitions.done")
PROGRESS_PATH = os.path.join(ROOT, "progress.txt")
META_PATH = os.path.join(ROOT, "franchises-meta-v1.json")
BLOB_PATH = os.path.join(ROOT, "franchises-blob-v1.bin")
ANILIST_URL = "https://graphql.anilist.co"
ANIMAP_ALL_URL = "https://animap.s0n1c.ca/mappings/all"
SCHEMA_VERSION = 1
PER_PAGE = 50
MAX_PAGES_PER_PARTITION = 100  # AniList hard cap: 5,000 results per query shape
FIRST_SEASON_YEAR = 1917
ALLOWED_RELATIONS = {"SEQUEL", "PREQUEL", "SEASON"}

QUERY = """
query ($page: Int, $perPage: Int, $seasonYear: Int, $sort: [MediaSort]) {
  Page(page: $page, perPage: $perPage) {
    pageInfo { hasNextPage currentPage }
    media(type: ANIME, seasonYear: $seasonYear, sort: $sort) {
      id
      idMal
      format
      status
      episodes
      isAdult
      seasonYear
      season
      startDate { year month day }
      title { romaji english native }
      coverImage { large medium }
      relations { edges { relationType node { id type } } }
    }
  }
}
"""


def log_progress(msg):
    line = "%s %s" % (time.strftime("%H:%M:%S"), msg)
    print(line, flush=True)
    try:
        with open(PROGRESS_PATH, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def post_graphql(variables, min_interval_holder, label):
    payload = json.dumps({"query": QUERY, "variables": variables}).encode("utf-8")
    req = urllib.request.Request(
        ANILIST_URL,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "Eclipse-Franchise-Dataset/1.0 (github.com/Soupy-dev/Eclipse)",
        },
    )
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                limit = resp.headers.get("X-RateLimit-Limit")
                if limit and limit.isdigit() and int(limit) > 0:
                    min_interval_holder[0] = max(60.0 / int(limit), 0.67)
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 429:
                retry_after = e.headers.get("Retry-After")
                wait = int(retry_after) if retry_after and retry_after.isdigit() else 30
                log_progress("429 in %s; sleeping %ds" % (label, wait + 1))
                time.sleep(wait + 1)
                continue
            if e.code >= 500:
                log_progress("HTTP %d in %s; retry %d" % (e.code, label, attempt))
                time.sleep(5 * (attempt + 1))
                continue
            try:
                body = e.read().decode("utf-8", "replace")[:800]
            except Exception:
                body = "<unreadable>"
            log_progress("HTTP %d in %s body: %s" % (e.code, label, body))
            raise
        except (urllib.error.URLError, TimeoutError) as e:
            log_progress("network error in %s (%s); retry %d" % (label, e, attempt))
            time.sleep(5 * (attempt + 1))
    raise RuntimeError("giving up in partition %s" % label)


def sweep_anilist():
    """Partitioned sweep with per-partition resume. Returns dict of media by id."""
    media = {}
    if os.path.exists(PAGES_PATH):
        with open(PAGES_PATH) as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                for m in rec.get("media") or []:
                    media[m["id"]] = m
        log_progress("resumed: %d media cached" % len(media))

    done = set()
    if os.path.exists(PARTS_PATH):
        with open(PARTS_PATH) as f:
            done = {ln.strip() for ln in f if ln.strip()}
        log_progress("resumed: %d partitions complete" % len(done))

    min_interval = [0.7]
    last_request = [0.0]
    out = open(PAGES_PATH, "a")

    def throttle():
        wait = min_interval[0] - (time.monotonic() - last_request[0])
        if wait > 0:
            time.sleep(wait)
        last_request[0] = time.monotonic()

    def run_partition(label, extra):
        if label in done:
            return
        page = 1
        added = 0
        while page <= MAX_PAGES_PER_PARTITION:
            throttle()
            variables = {"page": page, "perPage": PER_PAGE}
            variables.update(extra)
            data = post_graphql(variables, min_interval, label)
            page_data = data.get("data", {}).get("Page")
            if page_data is None:
                raise RuntimeError("malformed response in %s: %s" % (label, str(data)[:200]))
            batch = page_data.get("media") or []
            for m in batch:
                media[m["id"]] = m
            added += len(batch)
            if batch:
                out.write(json.dumps({"label": label, "page": page, "media": batch}) + "\n")
                out.flush()
            if not batch or not page_data.get("pageInfo", {}).get("hasNextPage"):
                break
            page += 1
        with open(PARTS_PATH, "a") as f:
            f.write(label + "\n")
        done.add(label)
        log_progress(
            "partition %s done: %d rows, %d pages (total %d media, interval %.2fs)"
            % (label, added, page, len(media), min_interval[0])
        )

    # Plain ascending ids: covers the oldest/no-season-year range (first 5,000 ids).
    run_partition("id-asc", {"sort": ["ID"]})
    current_year = time.gmtime().tm_year
    for year in range(FIRST_SEASON_YEAR, current_year + 3):
        run_partition("y%d" % year, {"seasonYear": year, "sort": ["ID"]})
    # Newest ids last: covers recent/TBA entries that have no seasonYear yet.
    run_partition("id-desc", {"sort": ["ID_DESC"]})

    out.close()
    log_progress("sweep complete: %d media" % len(media))
    return media


def fetch_animap():
    req = urllib.request.Request(ANIMAP_ALL_URL, headers={"User-Agent": "Eclipse/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            rows = json.loads(resp.read().decode("utf-8"))
    except Exception as e:  # AniMap outage: dataset still builds, mapping columns empty
        log_progress("WARNING animap fetch failed (%s); building without join" % e)
        return {}
    by_anilist = {}
    for row in rows:
        aid = row.get("anilist_id")
        if isinstance(aid, int) and aid > 0:
            by_anilist.setdefault(aid, []).append(row)
    log_progress("animap join table: %d rows, %d anilist ids" % (len(rows), len(by_anilist)))
    return by_anilist


class UnionFind:
    def __init__(self):
        self.parent = {}

    def find(self, x):
        p = self.parent.setdefault(x, x)
        while p != x:
            self.parent[x] = self.parent.setdefault(p, p)
            x = p
            p = self.parent[x]
        return p

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.parent[max(ra, rb)] = min(ra, rb)


SEASON_ORDINAL = {"WINTER": 0, "SPRING": 1, "SUMMER": 2, "FALL": 3}


def member_record(m, animap_by_anilist):
    """Exactly the fields AnimeStructureOrderingCandidate + assembly consume."""
    edges = []
    for e in (m.get("relations") or {}).get("edges") or []:
        node = e.get("node") or {}
        if node.get("type") != "ANIME":
            continue
        rt = e.get("relationType")
        if not rt:
            continue
        edges.append([rt, node["id"]])
    title = m.get("title") or {}
    start = m.get("startDate") or {}
    cover = m.get("coverImage") or {}
    mappings = []
    for row in animap_by_anilist.get(m["id"], []):
        mappings.append({
            "tmdbShow": row.get("tmdb_show_id"),
            "tmdbSeason": row.get("tmdb_season"),
            "tvdbSeason": row.get("tvdb_season"),
            "tvdbOffset": row.get("tvdb_epoffset"),
            "kitsu": row.get("kitsu_id"),
            "mediaType": row.get("media_type"),
        })
    return {
        "id": m["id"],
        "mal": m.get("idMal"),
        "format": m.get("format"),
        "status": m.get("status"),
        "eps": m.get("episodes"),
        "adult": bool(m.get("isAdult")),
        "y": start.get("year"),
        "mo": start.get("month"),
        "d": start.get("day"),
        "sy": m.get("seasonYear"),
        "so": SEASON_ORDINAL.get(m.get("season") or "", 4),
        "tr": title.get("romaji"),
        "te": title.get("english"),
        "tn": title.get("native"),
        "cover": cover.get("large") or cover.get("medium"),
        "edges": edges,
        "map": mappings,
    }


def build(media, animap_by_anilist):
    uf = UnionFind()
    for m in media.values():
        uf.find(m["id"])
        for e in (m.get("relations") or {}).get("edges") or []:
            node = e.get("node") or {}
            if node.get("type") != "ANIME":
                continue
            if e.get("relationType") in ALLOWED_RELATIONS and isinstance(node.get("id"), int):
                # Only union nodes we actually swept; unswept ids would create
                # phantom members with no data.
                if node["id"] in media:
                    uf.union(m["id"], node["id"])

    components = {}
    for mid in media:
        components.setdefault(uf.find(mid), []).append(mid)

    blob = bytearray()
    component_range = {}
    by_anilist = {}
    by_tmdb_show = {}
    for cid in sorted(components):
        members = sorted(components[cid])
        records = [member_record(media[mid], animap_by_anilist) for mid in members]
        encoded = json.dumps(records, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        start = len(blob)
        blob.extend(encoded)
        component_range[str(cid)] = [start, len(encoded)]
        for rec in records:
            by_anilist[str(rec["id"])] = cid
            for mp in rec["map"]:
                show = mp.get("tmdbShow")
                if isinstance(show, int) and show > 0:
                    by_tmdb_show.setdefault(str(show), cid)

    meta = {
        "schemaVersion": SCHEMA_VERSION,
        "builtAt": int(time.time()),
        "mediaCount": len(media),
        "componentCount": len(components),
        "blobByteCount": len(blob),
        "componentRangeById": component_range,
        "componentIdByAniListId": by_anilist,
        "componentIdByTmdbShowId": by_tmdb_show,
    }
    with open(BLOB_PATH, "wb") as f:
        f.write(bytes(blob))
    with open(META_PATH, "w") as f:
        json.dump(meta, f, separators=(",", ":"))
    log_progress(
        "built: %d media, %d components, blob %.1f MB, meta %.1f MB"
        % (len(media), len(components), len(blob) / 1e6, os.path.getsize(META_PATH) / 1e6)
    )


def main():
    os.makedirs(ROOT, exist_ok=True)
    log_progress("=== dataset build starting ===")
    media = sweep_anilist()
    animap = fetch_animap()
    build(media, animap)
    log_progress("=== dataset build DONE ===")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log_progress("FATAL: %r" % e)
        sys.exit(1)
