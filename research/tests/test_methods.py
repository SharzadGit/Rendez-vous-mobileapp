import sys
import unittest
from pathlib import Path

import numpy as np
from scipy.sparse import csr_matrix

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"scripts"))
from methods import Grid, choose, median, route_matrix
from network import directions, blocked
from experiment import verify, manifest


class MatchedRouting(unittest.TestCase):
    def test_inbound_optima_and_verified_intersection(self):
        # Origins A,B -> venues X,Y. X has times (1,8); Y has (5,5).
        g = csr_matrix(([1.,8.,5.,5.],([0,1,0,1],[2,2,3,3])),shape=(5,5))
        xy = np.array([[0.,0.],[0.,3.],[1.,1.],[3.,1.],[5.,1.]])
        d,_,settled = route_matrix(g,[0,1])
        grid = Grid(xy,1)
        surface = grid.surfaces(d).max(axis=0)
        self.assertEqual(settled,6)
        for method,want in [("minsum",0),("minmax",1),("isochrone",1)]:
            got,_ = choose(d[:,2:],xy[2:],xy[:2],surface,grid.index[2:],method,precision=.05)
            self.assertEqual(got,want)
            _,paths = verify(g.T.tocsr(),[0,1],2+got,d[:,2+got],True)
            self.assertEqual(paths,[[0,2+got],[1,2+got]])
        _,info = choose(d[:,2:],xy[2:],xy[:2],surface,grid.index[2:],"isochrone",ceiling=4)
        self.assertEqual(info["solver_status"],"no_verified_venue_by_cap")

    def test_polygon_hole_and_island(self):
        xy = np.array([[0.,0.],[5.,5.]])
        grid = Grid(xy,1)
        mask = np.zeros((6,6),bool)
        mask[:3,:3] = True
        mask[1,1] = False
        mask[5,5] = True
        p = grid.polygon(mask)
        self.assertTrue(p.is_valid)
        self.assertEqual(p.geom_type,"MultiPolygon")
        self.assertEqual(p.area,9)
        self.assertEqual(sum(len(g.interiors) for g in p.geoms),1)

    def test_median_and_degeneracy(self):
        np.testing.assert_allclose(median(np.array([[0.,0.]]*3+[[2.,0.]]),1e-8),[0,0],atol=1e-7)
        np.testing.assert_equal(median(np.ones((4,2))),[1,1])
        t = np.ones((2,2))
        xy = np.ones((2,2))
        for a in [0,.25,.5,.75,1]:
            self.assertEqual(choose(t,xy,xy,None,None,"hybrid",alpha=a)[0],0)

    def test_direction_access_and_design(self):
        tag = {"highway":"residential","oneway":"-1","oneway:bicycle":"no"}
        self.assertEqual(directions(tag,"driving"),[-1])
        self.assertEqual(directions(tag,"cycling"),[1,-1])
        self.assertEqual(directions(tag,"walking"),[1,-1])
        self.assertEqual(directions({"highway":"footway","access":"yes"},"driving"),[])
        self.assertTrue(blocked({"barrier":"bollard"},"driving"))
        self.assertEqual(len({x["scenario"] for x in manifest()}),420)

