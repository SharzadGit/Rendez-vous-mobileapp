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

10.1177/2399808318802941
10.1109/MPRV.2008.80
10.1109/TKDE.2005.87
10.1177/03611981231169280""".split()


HOLM = dict(authors=["Sture Holm"],title="A simple sequentially rejective multiple test procedure",
    journal="Scandinavian Journal of Statistics",year=1979,volume="6",pages="65–70",
    url="https://www.jstor.org/stable/4615733")
WEISZFELD = dict(authors=["E. Weiszfeld"],title="Sur le point pour lequel la somme des distances de n points donnés est minimum",
    journal="Tohoku Mathematical Journal, First Series",year=1937,volume="43",pages="355–386",
    url="https://www.jstage.jst.go.jp/article/tmj1911/43/0/43_0_355/_article/-char/en")

def fetch():
    refs = []
    import time
    for doi in DOIS:
        time.sleep(1.0)
        request = urllib.request.Request("https://api.crossref.org/works/"+doi,
                                         headers={"User-Agent":"RendezvousScholar/1.0"})
        with urllib.request.urlopen(request,timeout=40) as response:
            r = json.load(response)["message"]
        refs.append(dict(doi=r["DOI"],title=r["title"][0],authors=[
            (a.get("given","")+" "+a.get("family",a.get("name",""))).strip() for a in r["author"]],
            journal=r["container-title"][0],year=r["published"]["date-parts"][0][0],
            volume=r.get("volume",""),pages=r.get("page",r.get("article-number","")),url=r["URL"]))
    refs.insert(13, HOLM)
    refs.append(WEISZFELD)
    out = Path(__file__).resolve().parents[1]/"reports/references.json"
    out.write_text(json.dumps(refs,indent=2,ensure_ascii=False),encoding="utf-8")


if __name__ == "__main__":
    fetch()

