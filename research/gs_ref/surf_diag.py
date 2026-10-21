import os,sys,numpy as np,cv2
from surf_lib import *
S=Study('P1');P=S.P
m=o3d.io.read_triangle_mesh('out_surf/mesh_P1_C.ply');sc=S.mesh_scene(m)
rel=[];cov=[]
for i in S.train[::6]:
    zb=S.depth_pc(i);zc=S.mesh_depth(sc,P.cam(i),S.md[i]);mk=P.mask[i]&(zb>0)
    ok=mk&(zc>0);cov.append(ok.sum()/max(mk.sum(),1));d=(zc-zb)[ok]/zb[ok];rel.append((np.median(d),np.percentile(np.abs(d),75),np.percentile(np.abs(d),95)))
r=np.array(rel);print('coverage of product px by mesh',np.mean(cov));print('rel depth diff median/|p75|/|p95| mean over frames',r.mean(0),'median signed spread',r[:,0].std())
