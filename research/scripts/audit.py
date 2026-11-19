"""Recompute optima from all exported matrices, including failed scenarios."""
import io
import json
import platform
import zipfile
from collections import Counter

import numpy as np
import pandas as pd
from experiment import PRIMARY,RES


def audit():
    data = pd.read_csv(RES/"scenarios.csv.gz")
    base = data[data.label.isin(PRIMARY)]
    stages = pd.read_csv(RES/"stages.csv.gz").query("jitter == False")
    independent = Counter()
    gaps = []
    with zipfile.ZipFile(RES/"venue_matrices.zip") as z:
        for sid,grp in base.groupby("scenario"):
            with np.load(io.BytesIO(z.read(sid+".npz"))) as mm:
                t,ids = mm["seconds"],mm["venue_osm"]
            eligible = np.isfinite(t).all(axis=0)
            if not eligible.any():
                assert grp.failed.sum()==5
                reason = "participant_reaches_no_venue" if np.any(~np.isfinite(t).any(axis=1)) else "disjoint_reachable_venue_sets"
                independent[reason] += 1
                continue
            independent["feasible"] += 1
            assert (grp.failed==0).all()
            finite = t[:,eligible]
            records = grp.set_index("label")
            for label in PRIMARY:
                row = records.loc[label]
                ix = int(np.flatnonzero(ids==int(row.venue_id))[0])
                ts = t[:,ix]
                np.testing.assert_allclose([row.mean_s,row.max_s,row.sd_s,row.sum_s],
                                           [np.mean(ts),np.max(ts),np.std(ts),np.sum(ts)])
            np.testing.assert_allclose(records.loc["minsum","sum_s"],finite.sum(axis=0).min())
            np.testing.assert_allclose(records.loc["minmax","max_s"],finite.max(axis=0).min())
            gap = records.loc["isochrone","max_s"]-records.loc["minmax","max_s"]
            assert -1e-8 <= gap <= 30+1e-8
            gaps.append(gap)
    rankings = []
    for setting in ["halfvenues","jitter","speed80"]:
        alt = data[data.label.str.startswith(setting+"_")].pivot(index="scenario",columns="method",values="max_s")
        original = base.pivot(index="scenario",columns="method",values="max_s").reindex(alt.index)
        mask = alt.notna().all(axis=1) & original.notna().all(axis=1)
        a,b = alt[mask].round(8).rank(axis=1,method="min"),original[mask].round(8).rank(axis=1,method="min")
        rankings.append(dict(setting=setting,paired=len(a),any_rank_change=int((a!=b).any(axis=1).sum())))
    pd.DataFrame(rankings).to_csv(RES/"rank_changes.csv",index=False)
    summary = dict(host_system=platform.system(),python=platform.python_version(),machine=platform.machine(),
        counts=dict(independent),matrix_pairs=int((base[base.label=="minmax"]["size"]*len(pd.read_csv(RES.parent/"data/venues.csv"))).sum()),
        gap_max_s=float(max(gaps)),equal_worst=int(np.count_nonzero(np.isclose(gaps,0,rtol=0,atol=1e-8))),
        forward_searches=int(stages.graph_searches.sum()),forward_visits=int(stages.settled_vertex_visits.sum()),
        forward_total_s=stages.graph_search_s.sum(),surface_total_s=stages.surface_s.sum(),
        rss_sample_range_mib=(stages.rss_bytes.agg(["min","max"])/2**20).tolist(),
        verify_searches_primary=int(base.verification_searches.sum()),
        verify_cache_hits_primary=int(base.verification_cache_hits.sum()),
        verify_total_s_primary=base.verification_s.sum(),provider_requests=int(stages.provider_requests.sum()))
    (RES/"audit.json").write_text(json.dumps(summary,indent=2))
    print(json.dumps(summary,indent=2))


if __name__ == "__main__":
    audit()

