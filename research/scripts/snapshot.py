"""Archive only study-area OSM records from a checksum-verified dated extract."""
from pathlib import Path
import gzip
import hashlib
import json
import urllib.request

import osmium

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"
CFG = json.loads((ROOT / "configs/design.json").read_text())
URL = "https://download.geofabrik.de/asia/india/southern-zone-260101.osm.pbf"
MD5 = "28fc4b5e4f569f50ac9dc45a98abaff5"
ARCHIVE = DATA / "bengaluru.json.gz"
META = DATA / "snapshot.json"
TAGS = set("""highway access foot bicycle motorcar motor_vehicle vehicle oneway
    junction cycleway cycleway:left cycleway:right area service maxspeed surface
    barrier locked railway natural water waterway amenity name construction
    bicycle_road motorroad""".split())


def digest(path, algorithm="sha256"):
    with path.open("rb") as f:
        return hashlib.file_digest(f, algorithm).hexdigest()


def inside(lon, lat, padding=0):
    west, south, east, north = CFG["bbox"]
    return west-padding <= lon <= east+padding and south-padding <= lat <= north+padding


def tags(obj):
    return {t.k: t.v for t in obj.tags if t.k in TAGS or
            t.k.startswith(("oneway:", "access:", "foot:", "motor_vehicle:",
                            "motorcar:", "bicycle:", "vehicle:"))}


def build():
    if META.exists() and ARCHIVE.exists():
        if digest(ARCHIVE) != json.loads(META.read_text())["archive_sha256"]:
            raise ValueError("Archived extract checksum mismatch")
        return
    DATA.mkdir(exist_ok=True)
    source = DATA / URL.split("/")[-1]
    if not source.exists():
        part = source.with_suffix(".part")
        urllib.request.urlretrieve(URL, part)
        if digest(part, "md5") != MD5:
            raise ValueError("Source download checksum mismatch")
        part.replace(source)
    if digest(source, "md5") != MD5:
        raise ValueError("Regional PBF checksum mismatch")
    nodes, features, ways = {}, [], []
    halo = CFG["halo_deg"]
    node_filter = osmium.filter.KeyFilter("amenity", "barrier", "access", "foot", "bicycle", "motor_vehicle", "motorcar")
    for n in osmium.FileProcessor(source, osmium.osm.NODE).with_filter(node_filter):
        if inside(n.lon, n.lat, halo):
            features.append([n.id, n.version, n.lon, n.lat, tags(n)])
    way_filter = osmium.filter.KeyFilter("highway", "railway", "natural", "waterway")
    for w in osmium.FileProcessor(source).with_locations().with_filter(osmium.filter.EntityFilter(osmium.osm.WAY)).with_filter(way_filter):
        # A crossing segment is retained only when both endpoint nodes are in the halo.
        run = []
        for n in w.nodes:
            if n.location.valid() and inside(n.lon, n.lat, halo):
                run.append(n.ref)
                nodes[n.ref] = [n.lon, n.lat]
            elif run:
                if len(run) >= 2:
                    ways.append([w.id, w.version, tags(w), run])
                run = []
        if len(run) >= 2:
            ways.append([w.id, w.version, tags(w), run])
    payload = json.dumps(dict(nodes=nodes, features=features, ways=ways), ensure_ascii=False,
                         separators=(",", ":")).encode()
    ARCHIVE.write_bytes(gzip.compress(payload, compresslevel=9, mtime=0))
    reader = osmium.io.Reader(str(source))
    timestamp = reader.header().get("osmosis_replication_timestamp")
    reader.close()
    META.write_text(json.dumps(dict(url=URL, source_md5=MD5, source_sha256=digest(source),
        archive_sha256=digest(ARCHIVE), replication_timestamp=timestamp,
        date_label="2026-01-01", bbox_wsen=CFG["bbox"], halo_degrees=halo,
        node_coordinates=len(nodes), way_parts=len(ways), point_features=len(features),
        license="ODbL 1.0", attribution="© OpenStreetMap contributors; extract by Geofabrik"),
        ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    build()

