"""Camera-ready figures, drawn only from observed routes and paired outputs."""
import json

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from matplotlib.lines import Line2D
from matplotlib.patches import Patch
import numpy as np
import pandas as pd

from experiment import PRIMARY, ROOT, RES
from network import PROJECT

FIG = ROOT/"figures"
COLORS = ["#136d84","#c45b17","#2c8050","#874587","#343e51"]
NAMES = ["Geometric median","Isochrone","Min-sum","Min-max","Hybrid"]
LABELS = dict(zip(PRIMARY,NAMES))
plt.rcParams.update({"font.size":9,"axes.spines.top":False,"axes.spines.right":False,
                     "axes.titlesize":10,"figure.dpi":130,"savefig.dpi":220})


def save(fig,name):
    fig.savefig(FIG/(name+".png"),bbox_inches="tight",facecolor="white")
    plt.close(fig)


def figures(net,grid,folder,f):
    graph = net.graph["walking"]
    u,v = graph.nonzero()
    segments = net.xy[np.column_stack([u,v])]
    def roads(ax):
        ax.add_collection(LineCollection(segments,colors="#aebbc1",linewidths=.25,rasterized=True))
        for t,coords in net.context:
            if t.get("natural")=="water" and np.array_equal(coords[0],coords[-1]):
                ax.fill(*coords.T,color="#a1d5eb",zorder=1)
            elif t.get("railway")=="rail":
                ax.plot(*coords.T,color="#6a5d66",lw=.45)
        ax.set_aspect("equal")
        ax.ticklabel_format(useOffset=False,style="plain")
        ax.set_xlabel("UTM easting (m)")
        ax.set_ylabel("UTM northing (m)")
        ax.tick_params(axis="x",labelrotation=20)
    attribution = "Map data © OpenStreetMap contributors · ODbL 1.0 · www.openstreetmap.org/copyright"
    fig,ax = plt.subplots(figsize=(7.5,5.0),layout="constrained")
    roads(ax)
    ax.scatter(*net.venue_xy.T,s=6,c="#a84714",label="Eligible venue",zorder=3)
    from snapshot import CFG
    w,s,e,n = CFG["bbox"]
    outline = np.array([PROJECT.transform(x,y) for x,y in [(w,s),(e,s),(e,n),(w,n),(w,s)]])
    ax.plot(*outline.T,"k--",lw=1,label="Origin and venue extent")
    ax.autoscale()
    ax.legend(loc="upper left")
    ax.set_title("Bengaluru study area and routing halo")
    fig.supxlabel(attribution,fontsize=7)
    save(fig,"01-study-area")

    item = "barrier-separated_3_0_walking"
    d = folder/item
    data = json.loads((d/"result.json").read_text())
    contours = np.load(d/"contours.npz")
    origins = contours["origins"]
    fig,axes = plt.subplots(1,2,figsize=(10,4.7),layout="constrained")
    points = [origins]
    for label,c,style in [("weiszfeld",COLORS[0],"-"),("isochrone",COLORS[1],"--")]:
        sel = next(row for row in data["rows"] if row["label"]==label)
        routes = np.load(d/(label+"_paths.npz"))
        for key in routes:
            coords = routes[key]
            axes[0].plot(*coords.T,ls=style,color=c,lw=1.8,zorder=4)
            points.append(coords)
        axes[0].scatter(*PROJECT.transform(sel["lon"],sel["lat"]),s=58,marker="D",c=c,zorder=5)
    pts = np.concatenate(points)
    for ax in axes:
        roads(ax)
        ax.scatter(*origins.T,color="black",marker="^",s=36,zorder=5)
        ax.set_xlim(pts[:,0].min()-350,pts[:,0].max()+350)
        ax.set_ylim(pts[:,1].min()-350,pts[:,1].max()+350)
    axes[0].legend(handles=[Line2D([],[],color=COLORS[0],label="Geometric median"),Line2D([],[],color=COLORS[1],ls="--",label="Isochrone"),Line2D([],[],ls="",marker="^",color="k",label="Origins")],fontsize=7)
    axes[0].set_title("Verified walking paths and selected venues")
    extent = [grid.base[0],grid.base[0]+grid.width*grid.res,grid.base[1],grid.base[1]+grid.height*grid.res]
    masks = contours["masks"].reshape(-1,grid.height,grid.width)
    from matplotlib.colors import ListedColormap
    for k,color in enumerate(["#2583ac","#e4a732","#8258ac"]):
        axes[1].imshow(np.ma.masked_where(~masks[k],masks[k]),cmap=ListedColormap([color]),origin="lower",extent=extent,alpha=.38,zorder=2,interpolation="nearest")
    common = contours["common"].reshape(grid.height,grid.width)
    axes[1].imshow(np.ma.masked_where(~common,common),cmap=ListedColormap(["#134e43"]),origin="lower",extent=extent,zorder=3,interpolation="nearest")
    snap = net.snap["walking"]
    mat = np.load(d/"matrix.npz")["seconds"]
    verified = (mat.max(axis=0)<=float(contours["threshold"])) & common.ravel()[grid.index[snap]]
    axes[1].scatter(*net.xy[snap[verified]].T,marker="D",s=28,facecolor="white",edgecolor="black",zorder=5)
    axes[1].set_xlim(axes[0].get_xlim())
    axes[1].set_ylim(axes[0].get_ylim())
    axes[1].set_title(f"Reachable cells at {float(contours['threshold'])/60:.2f} min")
    axes[1].legend(handles=[Patch(color=c,label=f"Origin {i+1}") for i,c in enumerate(["#2583ac","#e4a732","#8258ac"])]+[Patch(color="#134e43",label="All three"),Line2D([],[],marker="D",mfc="white",color="k",ls="",label="Verified venue")],fontsize=7)
    fig.supxlabel(attribution,fontsize=7)
    save(fig,"02-routes-isochrones")

    fig,ax = plt.subplots(2,2,figsize=(10,7),layout="constrained")
    modes = ["walking","cycling","driving"]
    base = f[f.label.isin(PRIMARY)]
    for m,c in zip(PRIMARY,COLORS):
        sel = base[base.label==m]
        v = sel.groupby("mode")[["mean_s","max_s"]].mean().loc[modes]/60
        for (mode,r),marker in zip(v.iterrows(),["o","s","^"]):
            ax[0,0].scatter(r.mean_s,r.max_s,color=c,marker=marker,s=48,alpha=.8)
        s = sel.groupby("size").max_s.mean()/60
        ax[0,1].plot(s.index,s,marker="o",color=c,label=LABELS[m])
        s = sel.groupby("pattern").max_s.mean()/60
        ax[1,0].plot(range(len(s)),s,marker=".",color=c)
    ax[0,0].set(xlabel="Mean travel time (min)",ylabel="Maximum travel time (min)",title="Mode averages by method")
    ax[0,0].legend(handles=[Line2D([],[],marker=mk,color="black",ls="",label=m) for mk,m in zip(["o","s","^"],modes)],fontsize=7)
    ax[0,1].set(xlabel="Participants",ylabel="Mean maximum (min)",xticks=[3,5,10,20],title="Group size")
    ax[0,1].legend(fontsize=7)
    ax[1,0].set_xticks(range(len(s)),s.index,rotation=30,ha="right",fontsize=8)
    ax[1,0].set(ylabel="Mean maximum (min)",title="Spatial pattern")
    a = f[f.label.str.startswith("alpha_")].copy()
    a["alpha"] = a.label.str[6:].astype(float)
    avg = a.groupby("alpha")[["mean_s","sd_s","max_s"]].mean()/60
    ax[1,1].plot(avg.index,avg,"o-")
    ax[1,1].legend(["Mean","Population SD","Maximum"],fontsize=7)
    ax[1,1].set(xlabel="Efficiency weight",ylabel="Travel time (min)",title="Hybrid weighting")
    save(fig,"03-outcomes")

    stages = pd.read_csv(RES/"stages.csv.gz").query("jitter == False")
    fig,axes = plt.subplots(1,3,figsize=(10.5,3.4),layout="constrained")
    for mode,c in zip(modes,COLORS):
        by = stages[stages["mode"]==mode].groupby("size").mean(numeric_only=True)
        axes[0].plot(by.index,by.graph_search_s*1000,"o-",c=c,label=mode)
        axes[1].plot(by.index,by.settled_vertex_visits/1e6,"o-",c=c)
    axes[0].set(xlabel="Participants",ylabel="Forward search (ms)",title="Shared routing cost",xticks=[3,5,10,20])
    axes[0].legend(fontsize=7)
    axes[1].set(xlabel="Participants",ylabel="Settled visits (millions)",title="Graph exploration",xticks=[3,5,10,20])
    paired = pd.read_csv(RES/"paired.csv").query("outcome == 'max_s' and reference == 'weiszfeld'")
    y = np.arange(len(paired))
    axes[2].hlines(y,paired.ci_lo,paired.ci_hi,color=COLORS[0])
    axes[2].scatter(paired.difference,y,s=20,color=COLORS[0])
    axes[2].axvline(0,lw=.7,c="grey")
    axes[2].set_yticks(y,[LABELS[x] for x in paired.comparison],fontsize=8)
    axes[2].set(xlabel="Difference from median (min)",title="Worst trip: paired 95% CI")
    save(fig,"04-cost-and-effects")

