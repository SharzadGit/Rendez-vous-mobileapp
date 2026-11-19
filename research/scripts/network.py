"""Mode-specific directed arc weights on original OSM way segments."""
import gzip
import json
import re


import numpy as np
import pandas as pd
from pyproj import Transformer
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import connected_components
from scipy.spatial import cKDTree

from snapshot import ARCHIVE, CFG, DATA, inside

PROJECT = Transformer.from_crs(4326, CFG["epsg"], always_xy=True)
ROADS = set("motorway trunk primary secondary tertiary unclassified residential living_street service road track cycleway footway pedestrian path steps bridleway".split())
DENY = {"no", "private", "customers", "destination", "delivery", "agricultural", "forestry", "use_sidepath"}
KEYS = {"walking": ["foot", "access"], "cycling": ["bicycle", "vehicle", "access"],
        "driving": ["motorcar", "motor_vehicle", "vehicle", "access"]}


def permission(tags, mode, suffix=""):
    for key in KEYS[mode]:
        for k in ([key + suffix, key] if suffix else [key]):
            if k in tags:
                return tags[k]
    return ""


def directions(t, mode):
    highway = t.get("highway", "")
    road = highway.removesuffix("_link")
    if road not in ROADS or t.get("area") == "yes" or t.get("construction"):
        return []
    access = permission(t, mode)
    if access in DENY or any(k + ":conditional" in t for k in KEYS[mode]):
        return []
    explicit = any(t.get(k) in {"yes", "designated", "permissive", "official"} for k in KEYS[mode][:-1])
    if not explicit:
        if mode != "driving" and (road == "motorway" or t.get("motorroad") == "yes"):
            return []
        if mode == "driving" and road in {"cycleway", "pedestrian", "footway", "path", "steps", "bridleway"}:
            return []
        if mode == "cycling" and road in {"footway", "pedestrian", "steps", "bridleway"}:
            return []
    default = "yes" if road == "motorway" or t.get("junction") in {"roundabout","circular"} else "no"
    oneway = t.get("oneway", default) if mode != "walking" else "no"
    if mode == "cycling" and any(t.get(k, "").startswith("opposite") for k in ("cycleway","cycleway:left","cycleway:right")):
        oneway = "no"
    for k in KEYS[mode]:
        if "oneway:"+k in t:
            oneway = t["oneway:"+k]
            break
    if oneway in {"reversible","alternating"}:
        return []
    return [sign for sign, suffix in [(1, ":forward"), (-1, ":backward")]
            if permission(t, mode, suffix) not in DENY
            and not (sign == 1 and oneway == "-1")
            and not (sign == -1 and oneway in {"yes", "true", "1"})]


def speed(t, mode):
    road = t["highway"].removesuffix("_link")
    if mode == "walking":
        return 3 if road == "steps" else 4.8
    if mode == "cycling":
        return 8 if road in {"path", "track", "footway", "steps"} else 15
    kmh = {"motorway":65,"trunk":50,"primary":40,"secondary":35,"tertiary":30,
           "service":15,"track":12,"living_street":12}.get(road,25)
    limit = re.fullmatch(r"(\d+(?:\.\d+)?)\s*(mph|km/h|kph)?", t.get("maxspeed",""))
    if limit and float(limit[1]) > 0:
        kmh = min(kmh, float(limit[1]) * (1.609344 if limit[2]=="mph" else 1))
    return kmh


def blocked(t, mode):
    a = permission(t, mode)
    if a in DENY or t.get("locked") == "yes":
        return True
    if a in {"yes","permissive","designated"}:
        return False
    b = t.get("barrier")
    return b in {"wall","fence","block"} or (mode == "driving" and b in
        {"bollard","cycle_barrier","stile","turnstile","kissing_gate","bus_trap"}) or (
        mode == "cycling" and b in {"stile","turnstile"})


class Network:
    def __init__(self):
        raw = json.loads(gzip.decompress(ARCHIVE.read_bytes()))
        self.ids = np.array(sorted(map(int, raw["nodes"])))
        index = dict(zip(self.ids, range(len(self.ids))))
        self.lonlat = np.array([raw["nodes"][str(i)] for i in self.ids])
        self.xy = np.column_stack(PROJECT.transform(*self.lonlat.T))
        self.graph, self.active, self.meta = {}, {}, {}
        self.context = [(t, self.xy[[index[i] for i in refs]]) for _, _, t, refs in raw["ways"]
                        if t.get("railway") == "rail" or t.get("natural") == "water"]
        features = raw["features"]
        n = len(index)
        for mode in CFG["modes"]:
            forbidden = {i for i,_,_,_,t in features if blocked(t, mode)}
            arcs = {}
            for _,_,t,refs in raw["ways"]:
                signs = directions(t, mode)
                if not signs:
                    continue
                ix = np.array([index[i] for i in refs])
                dt = np.linalg.norm(np.diff(self.xy[ix],axis=0),axis=1) * (3.6/speed(t,mode))
                for j, (a,b,sec) in enumerate(zip(ix[:-1], ix[1:], dt)):
                    if sec <= 0 or refs[j] in forbidden or refs[j+1] in forbidden:
                        continue
                    for sign in signs:
                        key = (a,b) if sign == 1 else (b,a)
                        arcs[key] = min(arcs.get(key, np.inf), sec)
            u,v = np.array(list(arcs)).T
            graph = csr_matrix((list(arcs.values()), (u,v)), shape=(n,n))
            active = np.unique(np.r_[u,v])
            self.graph[mode], self.active[mode] = graph, active
            sub = graph[active][:,active]
            meta = {"nodes":len(active),"directed_arcs":len(arcs),
                    "one_direction_only_arcs":int((sub.sign() > sub.T.sign()).nnz)}
            for kind in ("strong","weak"):
                count, labels = connected_components(sub, directed=True, connection=kind)
                meta[kind+"_components"] = int(count)
                meta[kind+"_largest_nodes"] = int(np.bincount(labels).max())
            self.meta[mode] = meta
        candidates = [dict(osm_id=i,version=ver,lon=x,lat=y,category=t["amenity"],name=t["name"])
                      for i,ver,x,y,t in features if inside(x,y) and t.get("amenity") in CFG["categories"]
                      and t.get("name","").strip() and t.get("access") not in DENY]
        venues = pd.DataFrame(candidates).sort_values("osm_id").reset_index(drop=True)
        self.venue_xy = np.column_stack(PROJECT.transform(venues.lon,venues.lat))
        keep = np.ones(len(venues),dtype=bool)
        self.snap = {}
        for m, active in self.active.items():
            ds, ix = cKDTree(self.xy[active]).query(self.venue_xy)
            self.snap[m] = active[ix]
            venues[m+"_node"] = self.ids[active[ix]]
            venues[m+"_snap_m"] = ds
            keep &= ds <= CFG["snap_limit_m"]
        self.venues = venues[keep].reset_index(drop=True)
        self.venue_xy = self.venue_xy[keep]
        self.snap = {m:ix[keep] for m,ix in self.snap.items()}
        self.common = np.array(sorted(set.intersection(*(set(a) for a in self.active.values()))))
        self.common = self.common[[inside(*p) for p in self.lonlat[self.common]]]
        self.origin_tree = cKDTree(self.xy[self.common])
        self.venues.to_csv(DATA/"venues.csv", index=False)
        (DATA/"graphs.json").write_text(json.dumps(self.meta, indent=2))

