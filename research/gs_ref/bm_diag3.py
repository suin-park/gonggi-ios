import sys, numpy as np
src = open('bm_smooth.py', encoding='utf-8').read().split('# ---------------------------------------------------------------- 1)')[0]
sys.argv = ['x', 'out_best/map_decay_it12000.npz', 'out_bm_diag']; exec(src)

FR=(37,40,43,46,49,52,55,110,117)
def ev(name, fn):
    R=[]
    for f in FR:
        ct=P.cam(f); gt=P.gt[f]; m=P.mask[f]; me=cv2.erode(m.astype(np.uint8),np.ones((9,9),np.uint8))>0; im,al=fn(ct,f)
        psnr=lambda mm: float(-10*np.log10(((im-gt)**2)[mm].mean())); lap=lambda x: float(np.abs(cv2.Laplacian(cv2.cvtColor(u8(x),cv2.COLOR_RGB2GRAY),cv2.CV_32F))[me].mean())
        R.append((psnr(m),psnr(me),float(1-(al[me]>0.95).mean()),lap(im)/lap(gt)))
    R=np.array(R).mean(0); print(name,'PSNR mask %.2f | PSNR interior %.2f | interior holes %.3f | laplacian/gt %.2f'%tuple(R),flush=True)
ev('hard',lambda ct,f:(lambda r:(r[0],r[1]))(bm_hard(ct,exclude=(f,))))
for nm,kw in (('K5p3',dict(K=5,power=3.0)),('K6p6',dict(K=6,power=6.0)),('K6p6+consist.08',dict(K=6,power=6.0,consist=0.08)),('K5p3+consist.08',dict(K=5,power=3.0,consist=0.08))):
    ev(nm,lambda ct,f,kw=kw:(lambda r:(r[0],r[1]))(bm_smooth(ct,exclude=(f,),**kw)))
