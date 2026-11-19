"""Aggregate scenario checkpoints and estimate matched differences."""
from itertools import combinations
import json
import zipfile

import numpy as np
import pandas as pd
from scipy.stats import binomtest

from experiment import PRIMARY, RES, WORK, manifest, signature

FACTORS = ["pattern","size","rep","mode"]
RNG = 69611
B = 5000


def csv(df,name):
    df.to_csv(RES/name,index=False,compression={"method":"gzip","mtime":0} if name.endswith(".gz") else None)


def paired(frame):
    records = []
    gen = np.random.default_rng(RNG)
    # Resample replicate groups within size x pattern, keeping three modes together.
    groups = frame[FACTORS[:3]].drop_duplicates().sort_values(FACTORS[:3]).reset_index(drop=True)
    strata = groups.groupby(["pattern","size"]).indices.values()
    draw = np.hstack([gen.choice(ids,(B,len(ids))) for ids in strata])
    for outcome in ["max_s","mean_s","sum_s","sd_s","selection_s","failed"]:
        wide = frame.pivot(index=FACTORS,columns="label",values=outcome)
        for a,b in combinations(PRIMARY,2):
            x,y = wide[a],wide[b]
            diff = (y-x).dropna()
            scale = 60 if outcome in ["max_s","mean_s","sum_s","sd_s"] else 1
            d = diff/scale
            agg = d.groupby(level=FACTORS[:3]).agg(["sum","count"]).reindex(pd.MultiIndex.from_frame(groups)).fillna(0)
            tot,n = agg["sum"].to_numpy(),agg["count"].to_numpy()
            den = n[draw].sum(axis=1)
            boots = tot[draw].sum(axis=1)[den>0]/den[den>0]
            valid = n>0
            block = tot[valid]/n[valid]
            nonzero = block[np.abs(block)>1e-10]
            pc = (100*diff / x.reindex(diff.index).replace(0,np.nan)).dropna()
            lo,hi = np.quantile(boots,[.025,.975]) if len(boots) else [np.nan,np.nan]
            records.append(dict(outcome=outcome,reference=a,comparison=b,n_pairs=len(d),
                n_groups=int(valid.sum()),difference=d.mean(),ci_lo=lo,ci_hi=hi,
                pct_mean=pc.mean(),pct_n=len(pc),fraction_improved=(d < -1e-10).mean(),
                fraction_tied=(d.abs()<=1e-10).mean(),unit="min" if scale==60 else ("s" if outcome=="selection_s" else "proportion"),
                sign_p=binomtest(int((nonzero>0).sum()),len(nonzero)).pvalue if len(nonzero) else 1))
    out = pd.DataFrame(records)
    for _,family in out.groupby("outcome"):
        ix = family.sort_values("sign_p").index
        out.loc[ix,"holm_p"] = np.minimum(1,np.maximum.accumulate(out.loc[ix,"sign_p"]*np.arange(len(ix),0,-1)))
    return out


def summarize(folder):
    rows,stages,origins,persons,missing,frontiers = [],[],[],[],[],[]
    archive = zipfile.ZipFile(RES/"venue_matrices.zip","w")
    try:
        for i in manifest():
            directory = folder/i["scenario"]
            path = directory/"result.json"
            if not path.exists():
                missing.append(i)
                continue
            data = json.loads(path.read_text(encoding="utf-8"))
            stages.extend(dict(**i,**s) for s in data["stages"])
            origins.extend(dict(**i,**s) for s in data["origins"])
            for entry in data["rows"]:
                tt = entry.pop("individual_s",[])
                persons.extend(dict(scenario=i["scenario"],label=entry["label"],participant=j,
                    seconds=sec) for j,sec in enumerate(tt))
                rows.append(dict(**i,**entry))
            mat = np.load(directory/"matrix.npz")
            t,ids = mat["seconds"],mat["venue_osm"]
            good = np.isfinite(t).all(axis=0)
            subset = t[:,good]
            if subset.size:
                mu,mx = subset.mean(axis=0),subset.max(axis=0)
                best = np.inf
                for k in np.lexsort((ids[good],mx,mu)):
                    if mx[k] < best:
                        frontiers.append(dict(**i,venue_id=ids[good][k],mean_s=mu[k],max_s=mx[k]))
                        best = mx[k]
            archive.write(directory/"matrix.npz",i["scenario"]+".npz")
    finally:
        archive.close()
    f = pd.DataFrame(rows)
    f["failed"] = (f.solver_status!="ok").astype(float)
    base = f[f.label.isin(PRIMARY)].copy()
    csv(f,"scenarios.csv.gz")
    csv(pd.DataFrame(stages),"stages.csv.gz")
    csv(pd.DataFrame(origins),"origins.csv.gz")
    csv(pd.DataFrame(persons),"participants.csv.gz")
    csv(pd.DataFrame(frontiers),"pareto.csv.gz")
    csv(pd.DataFrame(missing,columns=list(manifest()[0])),"missing.csv")
    csv(f[f.failed==1],"failures.csv")
    for keys,name in [(["label"],"overall"),(["label","mode"],"by_mode"),
          (["label","size"],"by_size"),(["label","pattern"],"by_pattern"),
          (["label","pattern","size","mode"],"by_cell")]:
        result = base.groupby(keys).agg(attempts=("scenario","size"),succeeded=("max_s","count"),
            failure_rate=("failed","mean"),mean_s=("mean_s","mean"),max_s=("max_s","mean"),
            total_s=("sum_s","mean"),sd_s=("sd_s","mean"),selection_s=("selection_s","mean"))
        csv(result.reset_index(),name+".csv")
    csv(paired(base),"paired.csv")
    sens = []
    for label,part in f[~f.label.isin(PRIMARY)].groupby("label"):
        method = part.method.iloc[0] if label!="nearest" else "weiszfeld"
        joined = part.merge(base[base.label==method],on="scenario",suffixes=("","_base"))
        differences = joined.max_s-joined.max_s_base
        groups = differences.groupby([joined.pattern,joined["size"],joined.rep]).mean().dropna()
        # Descriptive over independent sampled group blocks, including modes together.
        g = np.random.default_rng(RNG)
        boot = g.choice(groups.to_numpy(),(B,len(groups))).mean(axis=1)/60 if len(groups) else [np.nan]
        ok = joined.venue_id.notna() & joined.venue_id_base.notna()
        sens.append(dict(label=label,reference=method,attempts=len(joined),pairs=int(ok.sum()),
            failure_rate=joined.failed.mean(),changed_venue_rate=(joined.venue_id[ok]!=joined.venue_id_base[ok]).mean(),
            max_diff_min=differences.mean()/60,ci_lo=np.quantile(boot,.025),ci_hi=np.quantile(boot,.975),
            mean_diff_min=(joined.mean_s-joined.mean_s_base).mean()/60,
            selection_ms=1000*joined.selection_s.mean(),runtime_delta_ms=1000*(joined.selection_s-joined.selection_s_base).mean()))
    csv(pd.DataFrame(sens),"sensitivity.csv")
    return f

