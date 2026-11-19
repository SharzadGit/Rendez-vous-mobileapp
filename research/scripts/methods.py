"""Paired finite-venue objectives and cell-based network isochrones."""
from time import perf_counter
import numpy as np
from scipy.sparse.csgraph import dijkstra
from rasterio.features import shapes
from shapely.geometry import shape
from shapely import make_valid, union_all
from affine import Affine

from snapshot import CFG
from network import PROJECT


def median(xy, tol=0.05, limit=2000):
    """Modified Weiszfeld (Vardi-Zhang), in projected metres."""
    x = np.mean(xy, axis=0)
    for _ in range(limit):
        diff = xy - x
        distance = np.linalg.norm(diff, axis=1)
        far = distance > 1e-9
        if not far.any():
            return x
        weight = 1 / distance[far]
        residual = (diff[far] * weight[:,None]).sum(axis=0)
        norm = np.linalg.norm(residual)
        coincident = (~far).sum()
        if norm <= coincident:
            return x
        step = residual * ((1-coincident/norm) / weight.sum())
        x = x + step
        if np.linalg.norm(step) <= tol:
            return x
    raise ArithmeticError("Weiszfeld iteration limit")


def origins(net, pattern, size, rep, perturb=False):
    rng = np.random.default_rng([CFG["seed"], CFG["patterns"].index(pattern),size,rep])
    lo, hi = net.xy[net.common].min(axis=0), net.xy[net.common].max(axis=0)
    span = hi-lo
    center = lo + span*rng.uniform(.25,.75,2)
    offsets = rng.normal(0,1,(size,2))
    if pattern == "compact":
        targets = center + offsets * 350
    elif pattern == "circular":
        phi = rng.uniform(0, 2*np.pi) + np.arange(size)*2*np.pi/size
        targets = center + rng.uniform(900,1900)*np.column_stack([np.cos(phi), np.sin(phi)]) + offsets*65
    elif pattern == "corridor":
        phi = rng.uniform(0, np.pi)
        targets = center + np.outer(np.linspace(-2200,2200,size),[np.cos(phi),np.sin(phi)]) + offsets*140
    elif pattern == "outlier":
        targets = center + offsets*300
        phi = rng.uniform(0, np.pi*2)
        targets[-1] = center + 3500*np.array([np.cos(phi),np.sin(phi)])
    elif pattern == "city-centre":
        targets = PROJECT.transform(77.5946,12.9716) + offsets*800
    elif pattern == "peripheral":
        u = rng.uniform(.05,.95,(size,2))
        axes = rng.integers(0,2,size)
        u[np.arange(size),axes] = rng.choice([.08,.92],size) + rng.uniform(-.035,.035,size)
        targets = lo + span*u
    else:
        # Two shores of Ulsoor Lake, with north/south jitter.
        west, east = PROJECT.transform(77.6148,12.9825), PROJECT.transform(77.6276,12.9825)
        targets = np.where(np.arange(size)[:,None]%2==0,west,east) + offsets*[110,250]
    if perturb:
        targets += np.random.default_rng([4329,size,rep,CFG["patterns"].index(pattern)]).normal(0,75,(size,2))
    used = set()
    selected = []
    for target in targets:
        _, ix = net.origin_tree.query(target,k=size)
        node = next(int(net.common[i]) for i in ix if int(net.common[i]) not in used)
        used.add(node)
        selected.append(node)
    return selected


class Grid:
    """A union of 40 m cells containing reachable original network vertices.

    The half-open projected grid gives unambiguous membership. Common occupied
    cells are an area approximation; exact per-origin route times gate venues.
    """
    def __init__(self, xy, res):
        self.res = res
        self.base = np.floor(xy.min(axis=0)/res)*res
        ix = np.floor((xy-self.base)/res).astype(int)
        self.width,self.height = ix.max(axis=0)+1
        self.index = ix[:,1]*self.width + ix[:,0]

    def surfaces(self, dist):
        # A cell is reached at the earliest arrival at any sampled road vertex.
        output = np.full((len(dist), self.width*self.height), np.inf)
        for row, times in zip(output,dist):
            np.minimum.at(row,self.index,times)
        return output

    def polygon(self, cells):
        mask = cells.reshape(self.height,self.width).astype("uint8")
        transform = Affine.translation(*self.base) * Affine.scale(self.res,self.res)
        return union_all([make_valid(shape(g)) for g,v in shapes(mask, mask=mask.astype(bool),transform=transform)])


def scale(x):
    span = np.ptp(x)
    return (x-x.min())/span if span else np.zeros_like(x)


def choose(times, venue_xy, origin_xy, surface, cells, method, *, allowed=None,
           radius=500, precision=30, ceiling=10800, alpha=.5, tol=.05):
    """Columns are ordered by stable OSM ID. Return original column and diagnostics."""
    start = perf_counter()
    good = np.isfinite(times).all(axis=0)
    if allowed is not None:
        good &= allowed
    idx = np.flatnonzero(good)
    info = dict(candidates=len(idx), threshold_s=None,geometry_s=0.,filter_s=0.,threshold_tests=0,
                overlap_cells=None, shortlist=None, solver_status="ok")
    if not len(idx):
        return None, dict(info,solver_status="no_common_venue", selection_s=perf_counter()-start)
    t = times[:,idx]
    mean, worst, sd = t.mean(axis=0), t.max(axis=0), t.std(axis=0)
    if method == "isochrone":
        # max of earliest arrival surfaces encodes the exact intersection at
        # every threshold on this common raster. Materialize and count each mask.
        def feasible(bound):
            tick = perf_counter()
            mask = surface <= bound
            info["overlap_cells"] = int(np.count_nonzero(mask))
            info["geometry_s"] += perf_counter()-tick
            tick = perf_counter()
            valid = np.flatnonzero(mask[cells[idx]] & (worst <= bound))
            info["filter_s"] += perf_counter()-tick
            info["threshold_tests"] += 1
            return valid
        lo,hi = CFG["threshold_min_s"],ceiling
        valid = feasible(lo)
        if not len(valid):
            valid = feasible(hi)
            if not len(valid):
                return None, dict(info,solver_status="no_verified_venue_by_cap",selection_s=perf_counter()-start)
            while hi-lo > precision:
                mid = (lo+hi)/2
                if len(feasible(mid)):
                    hi = mid
                else:
                    lo = mid
            valid = feasible(hi)
        else:
            hi = lo
        info["threshold_s"],info["shortlist"] = hi,len(valid)
        j = valid[np.lexsort((idx[valid],worst[valid],mean[valid]))[0]]
    elif method in {"weiszfeld","nearest"}:
        try:
            point = median(origin_xy,tol)
        except ArithmeticError:
            return None, dict(info,solver_status="weiszfeld_nonconvergence",selection_s=perf_counter()-start)
        distance = np.linalg.norm(venue_xy[idx]-point,axis=1)
        shortlist = np.flatnonzero(distance <= radius)
        if not len(shortlist) or method == "nearest":
            shortlist = np.flatnonzero(distance == distance.min())
        info["shortlist"] = len(shortlist)
        j = shortlist[np.lexsort((idx[shortlist],worst[shortlist],mean[shortlist]))[0]]
    elif method == "minsum":
        j = np.lexsort((idx,worst,mean))[0]
    elif method == "minmax":
        j = np.lexsort((idx,mean,worst))[0]
    elif method == "hybrid":
        j = np.lexsort((idx,worst,mean,alpha*scale(mean)+(1-alpha)*scale(sd)))[0]
    else:
        raise ValueError(method)
    return int(idx[j]), dict(info,selection_s=perf_counter()-start)


def route_matrix(graph, orig):
    start = perf_counter()
    dist = dijkstra(graph,directed=True,indices=orig)
    return dist, perf_counter()-start, int(np.isfinite(dist).sum())

