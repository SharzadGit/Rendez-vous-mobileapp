"""Refresh the verified bibliographic metadata (Crossref DOI registrations)."""
import json
import urllib.request
from pathlib import Path

DOIS = """10.1073/pnas.97.4.1423
10.1007/BF01386390
10.1287/opre.12.3.450
10.1287/opre.13.3.462
10.1007/s11227-021-03776-7
10.3138/cart.53.4.2018-0013
10.1016/j.compenvurbsys.2017.05.004
10.1111/gean.70009
10.1007/s42489-024-00167-9
10.2478/rgg-2024-0014
10.5194/isprs-archives-L-4-W1-2026-57-2026
10.1371/journal.pone.0180698
10.1214/aos/1176344552
10.2202/1544-6115.1585
10.1177/2399808318802941
10.1109/MPRV.2008.80""".split()


def fetch():
    refs = []
    for doi in DOIS:
        request = urllib.request.Request("https://api.crossref.org/works/"+doi,
                                         headers={"User-Agent":"RendezvousScholar/1.0"})
        with urllib.request.urlopen(request,timeout=40) as response:
            r = json.load(response)["message"]
        refs.append(dict(doi=r["DOI"],title=r["title"][0],authors=[
            (a.get("given","")+" "+a.get("family",a.get("name",""))).strip() for a in r["author"]],
            journal=r["container-title"][0],year=r["published"]["date-parts"][0][0],
            volume=r.get("volume",""),pages=r.get("page",r.get("article-number","")),url=r["URL"]))
    out = Path(__file__).resolve().parents[1]/"reports/references.json"
    out.write_text(json.dumps(refs,indent=2,ensure_ascii=False),encoding="utf-8")


if __name__ == "__main__":
    fetch()

