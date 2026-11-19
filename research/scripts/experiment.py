"""Run and checkpoint the fixed design. Units: seconds and UTM metres."""
import hashlib
import json
import os
import platform
from pathlib import Path
from time import perf_counter

import numpy as np
import pandas as pd
import psutil
from scipy.sparse.csgraph import dijkstra

from snapshot import ROOT, CFG, ARCHIVE, digest, build
from network import Network
from methods import Grid, origins, choose, route_matrix

RES = ROOT/"results"
WORK = ROOT/"work"
PRIMARY = ["weiszfeld","isochrone","minsum","minmax","hybrid"]


def manifest():
    return [dict(scenario=f"{p}_{n}_{r}_{m}",pattern=p,size=n,rep=r,mode=m)
            for p in CFG["patterns"] for n in CFG["sizes"] for r in CFG["seeds"] for m in CFG["modes"]]


def signature():
    h = hashlib.sha256()
    for path in [ARCHIVE, ROOT/"configs/design.json", *(ROOT/"scripts"/s for s in
                 ["snapshot.py","network.py","methods.py","experiment.py"]), ROOT/"requirements.lock"]:
        h.update(bytes.fromhex(digest(path)))
    return h.hexdigest()


def variants(rep):
    yield from ((m,m,{}) for m in PRIMARY)
    for a in CFG["alphas"]:
        yield f"alpha_{a:g}","hybrid",dict(alpha=a)
    if rep == 0:
        yield "nearest","nearest",{}
        yield "radius150","weiszfeld",dict(radius=150)
        yield "radius1200","weiszfeld",dict(radius=1200)
        yield "tolerance2m","weiszfeld",dict(tol=2.)
        yield "precision5","isochrone",dict(precision=5)
        yield "precision300","isochrone",dict(precision=300)
        yield "threshold1800","isochrone",dict(ceiling=1800)
        for m in PRIMARY:
            yield "halfvenues_"+m,m,{}
            yield "speed80_"+m,m,{}
            yield "jitter_"+m,m,{}
        yield "cap1800","hybrid",{}


def verify(graph_t, orig, dest, expected, capture):
    dist, pred = dijkstra(graph_t, indices=dest, directed=True, return_predecessors=True)
    np.testing.assert_allclose(dist[orig],expected,rtol=1e-10,atol=1e-8)
    paths = []
    if capture:
        for start, duration in zip(orig,expected):
            path = [start]
            while path[-1] != dest:
                nxt = int(pred[path[-1]])
                if nxt < 0 or len(path) > len(dist):
                    raise ValueError("Broken predecessor chain")
                path.append(nxt)
            measured = sum(float(graph_t[b,a]) for a,b in zip(path,path[1:]))
            np.testing.assert_allclose(measured, duration)
            paths.append(path)
    return int(np.isfinite(dist).sum()), paths


def run_one(net, grid, item, folder, capture=False):
    p,n,r,m = (item[k] for k in ("pattern","size","rep","mode"))
    graph = net.graph[m]
    reverse = graph.T.tocsr()
    snap = net.snap[m]
    directory = folder/item["scenario"]
    directory.mkdir(parents=True,exist_ok=True)
    rows, stages, inputs = [], [], []
    rng = np.random.default_rng(917)
    subset = np.zeros(len(snap),bool)
    subset[rng.permutation(len(snap))[:max(1,len(snap)//2)]] = True
    for perturbed in ([False,True] if r==0 else [False]):
        orig = origins(net,p,n,r,perturbed)
        inputs.extend(dict(jitter=perturbed,participant=i,origin_id=int(net.ids[o]),
                           longitude=net.lonlat[o,0],latitude=net.lonlat[o,1]) for i,o in enumerate(orig))
        dist, search_s, explored = route_matrix(graph,orig)
        times = dist[:,snap]
        tick = perf_counter()
        surfaces = grid.surfaces(dist)
        common = surfaces.max(axis=0)
        surface_s = perf_counter()-tick
        del dist
        stages.append(dict(jitter=perturbed,graph_search_s=search_s,settled_vertex_visits=explored,
                           graph_searches=n,surface_s=surface_s,rss_bytes=psutil.Process().memory_info().rss,
                           provider_requests=0,service_wait_s=0,origin_cache_hits=0))
        verification = {}
        if not perturbed:
            np.savez_compressed(directory/"matrix.npz",seconds=times,origin_osm=net.ids[orig],
                                venue_osm=net.venues.osm_id.to_numpy())
        for label, method, opts in variants(r):
            if perturbed != label.startswith("jitter_"):
                continue
            multiplier = 1.25 if label.startswith("speed80_") else 1
            t = times if multiplier==1 else times*multiplier
            limit = None
            if label.startswith("halfvenues"):
                limit = subset
            if label == "cap1800":
                limit = t.max(axis=0)<=1800
            index,info = choose(t,net.venue_xy,net.xy[orig],
                common if multiplier==1 else common*multiplier,grid.index[snap], method,
                allowed=limit,**opts)
            row = dict(label=label,method=method,**info,verification_s=0.,verification_searches=0,
                       verification_visits=0,verification_cache_hits=0,unreachable_pairs=int(np.isinf(t).sum()))
            if index is not None:
                v = net.venues.iloc[index]
                dest = int(snap[index])
                route_capture = capture and not perturbed and label in PRIMARY
                key = dest
                if key not in verification:
                    start = perf_counter()
                    count,paths = verify(reverse,orig,dest,times[:,index],route_capture)
                    row.update(verification_s=perf_counter()-start,verification_searches=1,verification_visits=count)
                    verification[key] = paths
                else:
                    row["verification_cache_hits"] = 1
                ts = t[:,index]
                row.update(venue_id=int(v.osm_id),lon=v.lon,lat=v.lat,individual_s=ts.tolist(),
                           sum_s=ts.sum(),mean_s=ts.mean(),max_s=ts.max(),sd_s=ts.std())
                if label == "weiszfeld":
                    baseline_xy = net.venue_xy[index]
                if route_capture:
                    np.savez_compressed(directory/(label+"_paths.npz"),
                        **{str(i):net.xy[path] for i,path in enumerate(verification[key])})
                if route_capture and label == "isochrone":
                    threshold = info["threshold_s"]
                    np.savez_compressed(directory/"contours.npz", masks=surfaces<=threshold,
                                        common=common<=threshold,threshold=threshold,origins=net.xy[orig])
            rows.append(row)
        if not perturbed:
            ref = next((x for x in rows if x["label"]=="weiszfeld" and "venue_id" in x),None)
            if ref:
                for row in rows:
                    if "venue_id" in row:
                        ix = int(net.venues.index[net.venues.osm_id==row["venue_id"]][0])
                        row["displacement_from_weiszfeld_m"] = float(np.linalg.norm(net.venue_xy[ix]-baseline_xy))
    payload = dict(**item,rows=rows,stages=stages,origins=inputs)
    tmp = directory/"result.tmp"
    tmp.write_text(json.dumps(payload,allow_nan=False),encoding="utf-8")
    os.replace(tmp,directory/"result.json")


def run(pilot=False):
    build()
    net = Network()
    grid = Grid(net.xy,CFG["cell_m"])
    folder = WORK/signature()
    folder.mkdir(parents=True,exist_ok=True)
    items = manifest()
    pd.DataFrame(items).to_csv(RES/"manifest.csv",index=False)
    # Barrier pilot across all three modes before the balanced run.
    pilot_ids = {i["scenario"] for i in items if i["pattern"]=="barrier-separated" and i["size"]==3 and i["rep"]==0}
    for i in items:
        if pilot and i["scenario"] not in pilot_ids:
            continue
        if (folder/i["scenario"]/"result.json").is_file():
            continue
        run_one(net,grid,i,folder,i["scenario"] in pilot_ids)
        if i["rep"]==0 and i["mode"]=="driving":
            print("Completed",i["scenario"],flush=True)
    return net, grid, folder

