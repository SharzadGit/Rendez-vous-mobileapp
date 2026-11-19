"""From the repository root: python research/run.py [pilot|run|analyse|all]."""
import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parent/"scripts"))
from experiment import run, signature, WORK
from snapshot import build, CFG
from network import Network
from methods import Grid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage",choices=["data","pilot","run","analyse","all"],nargs="?",default="all")
    stage = parser.parse_args().stage
    if stage == "data":
        build()
        Network()
        return
    if stage in ("pilot","all","run"):
        from pilot import audit_pilot
        net,grid,folder = run(pilot=True)
        audit_pilot(net,grid,folder)
        if stage == "pilot":
            return
        net,grid,folder = run()
        if stage == "run":
            return
    else:
        build()
        net = Network()
        grid = Grid(net.xy,CFG["cell_m"])
        folder = WORK/signature()
    from analysis import summarize
    (WORK/'matplotlib').mkdir(parents=True,exist_ok=True)
    os.environ.setdefault('MPLCONFIGDIR',str(WORK/'matplotlib'))
    from figures import figures
    from audit import audit
    f = summarize(folder)
    figures(net,grid,folder,f)
    audit()


if __name__ == "__main__":
    main()

