"""Independent heap-based checks of the three shore-to-venue pilot scenarios."""
import heapq
import json
import numpy as np
from shapely import intersection_all
from experiment import RES
from snapshot import CFG


def shortest(graph, start, end):
    distance = {start:0.}
    queue = [(0.,start)]
    while queue:
        sec,node = heapq.heappop(queue)
        if sec != distance[node]:
            continue
        if node == end:
            return sec
        for i in range(graph.indptr[node],graph.indptr[node+1]):
            nxt = int(graph.indices[i])
            new = sec+graph.data[i]
            if new < distance.get(nxt,float("inf")):
                distance[nxt] = new
                heapq.heappush(queue,(new,nxt))
    return float("inf")


def audit_pilot(net,grid,folder):
    report = []
    for m in CFG["modes"]:
        d = folder/f"barrier-separated_3_0_{m}"
        record = json.loads((d/"result.json").read_text())
        counts = np.load(d/"contours.npz")
        polys = [grid.polygon(mask) for mask in counts["masks"]]
        common = grid.polygon(counts["common"])
        intersection = intersection_all(polys)
        area_error = common.symmetric_difference(intersection).area
        if area_error > 1e-5 or not common.is_valid:
            raise ValueError("Vector intersection disagrees with raster intersection")
        mat = np.load(d/"matrix.npz")
        nodes = {osm:int(ix) for ix,osm in enumerate(net.ids)}
        for row in record["rows"][:5]:
            if row["solver_status"] != "ok":
                raise ValueError("Pilot method failed: "+str(row))
            vi = int(np.flatnonzero(mat["venue_osm"]==row["venue_id"])[0])
            times = [shortest(net.graph[m],nodes[o],net.snap[m][vi]) for o in mat["origin_osm"]]
            np.testing.assert_allclose(times,row["individual_s"],rtol=1e-10,atol=1e-8)
            paths = np.load(d/(row["label"]+"_paths.npz"))
            report.append(dict(mode=m,method=row["label"],osm_id=row["venue_id"],
                name=net.venues.iloc[vi]["name"],times_s=times,path_vertices=[len(paths[k]) for k in paths],
                max_independent_error_s=max(abs(np.array(times)-row["individual_s"])),
                raster_vector_area_difference_m2=area_error,common_area_m2=common.area))
    (RES/"pilot.json").write_text(json.dumps(report,indent=2,ensure_ascii=False),encoding="utf-8")
    print("Pilot audited:",len(report),"method/mode decisions",flush=True)

