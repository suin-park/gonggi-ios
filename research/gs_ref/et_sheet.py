import pickle, numpy as np, cv2, json, sys
D='C:/Users/emili/Downloads/best_3d_quality_before_friday/early_fur_trace/'
S=pickle.load(open(D+'snapshots.pkl','rb')); gt=np.load(D+'fixed_photo.npy'); m=json.load(open(D+'trace_metrics.json')); x0,y0,w,h=m['crops']['face']
u8=lambda x:(np.clip(x,0,1)*255).astype(np.uint8)
want=[(2,'I'),(2,'O'),(2,'R'),(3,'R'),(4,'R'),(7,'R'),(9,'R'),(11,'R'),(13,'R')]
tiles=[u8(gt[y0:y0+h,x0:x0+w])]
for k,op in want:
    for s in S:
        if s[0]==k and s[1]==op: t=u8(s[2][y0:y0+h,x0:x0+w]).copy(); cv2.putText(t,f'{k}{op}',(2,12),0,0.4,(255,255,0),1); tiles.append(t)
tiles=[cv2.resize(t,None,fx=2,fy=2,interpolation=cv2.INTER_NEAREST) for t in tiles]
sheet=np.concatenate([np.concatenate(tiles[:5],1),np.concatenate(tiles[5:10],1)],0)
cv2.imencode('.png',cv2.cvtColor(sheet,cv2.COLOR_RGB2BGR))[1].tofile(D+'_sheet.png')
