import pickle, numpy as np, cv2, json
from PIL import Image, ImageDraw, ImageFont
D='C:/Users/emili/Downloads/best_3d_quality_before_friday/early_fur_trace/'
S=pickle.load(open(D+'snapshots.pkl','rb')); gt=np.load(D+'fixed_photo.npy'); M=json.load(open(D+'trace_metrics.json')); x0,y0,w,h=M['crops']['face']; sx,sy,_,_=M['crops']['seat']
AB=pickle.load(open(D+'ab_imgs.pkl','rb')); abm=json.load(open(D+'ab_metrics.json'))
u8=lambda x:(np.clip(x,0,1)*255).astype(np.uint8)
F=ImageFont.truetype('C:/Windows/Fonts/malgun.ttf',15)
def txt(im,t,xy=(4,2)):
    p=Image.fromarray(np.ascontiguousarray(im)); ImageDraw.Draw(p).text(xy,t,font=F,fill=(255,255,0),stroke_width=2,stroke_fill=(0,0,0)); return np.array(p)
def crop(im,x,y): return cv2.resize(u8(im[y:y+h,x:x+w]),None,fx=3,fy=3,interpolation=cv2.INTER_NEAREST)
rows={(r['kf_index'],r['op']):r for r in M['rows']}
# 00 video
vw=cv2.VideoWriter(D+'00_처음생성부터_질감변화.mp4' if False else D+'_tmp.mp4',cv2.VideoWriter_fourcc(*'mp4v'),3,(1280,360+60)) 
for k,op,im,al,born,col,mp,rr in S:
    if rr.get('gaussians',0)==0: continue
    a=crop(im,x0,y0); b=crop(im,sx,sy)
    a=txt(a,'눈·코 확대'); b=txt(b,'매끈한 면 확대'); c=cv2.resize(u8(np.repeat(al[y0:y0+h,x0:x0+w][...,None],3,2)),None,fx=1,fy=1)
    c=cv2.resize(c,(320,360),interpolation=cv2.INTER_NEAREST); c=txt(c,'누적 알파(눈·코 영역)')
    row=np.concatenate([a,b,c],1)[:360]; bar=np.zeros((60,1280,3),np.uint8)
    bar=txt(bar,f"고정 카메라(프레임4) | 키프레임 idx {k} (기기 id {k+1}) | 연산 {op} | 가우시안 {rr['gaussians']} | 고주파비 {rr.get('hp_ratio_render_over_photo',0):.2f} | 알파구멍 {rr.get('alpha_pinhole_frac',0):.2f}",(6,18))
    vw.write(cv2.cvtColor(np.concatenate([row,bar],0),cv2.COLOR_RGB2BGR))
vw.release()
import subprocess,os
subprocess.run(['ffmpeg','-y','-loglevel','error','-i',D+'_tmp.mp4','-c:v','libx264','-pix_fmt','yuv420p',D+'00_처음생성부터_질감변화.mp4'])
if os.path.exists(D+'00_처음생성부터_질감변화.mp4'): os.remove(D+'_tmp.mp4')
else: os.replace(D+'_tmp.mp4',D+'00_처음생성부터_질감변화.mp4')
# 01 before/after first rough op (2I) + first re-roughening op (9R)
def find(k,op): return next(s for s in S if s[0]==k and s[1]==op)
black=np.zeros((480,640,3),np.float32)
def pair(lbl,before,after,k):
    ps=[(gt,'원본 사진(같은 카메라)'),(before,'연산 전'),(after,'연산 후')]
    return np.concatenate([txt(crop(p,x0,y0),f'{lbl} {t}') for p,t in ps],1)
r1=pair('① 첫 삽입 2I',black,find(2,'I')[2],2); r2=pair('② 2O 최적화 후',find(2,'I')[2],find(2,'O')[2],2); r3=pair('③ 9R 창 정제',find(9,'O')[2],find(9,'R')[2],9)
cv2.imencode('.png',cv2.cvtColor(np.concatenate([r1,r2,r3],0),cv2.COLOR_RGB2BGR))[1].tofile(D+'01_첫열화연산_전후.png')
# 02 A/B
A=AB['A'][-1]; B=AB['B'][-1]
row=np.concatenate([txt(crop(gt,x0,y0),'원본 사진'),txt(crop(A,x0,y0),'A 삽입 허용 (kf13)'),txt(crop(B,x0,y0),'B 삽입 차단 (kf13)')],1)
cv2.imencode('.png',cv2.cvtColor(row,cv2.COLOR_RGB2BGR))[1].tofile(D+'02_삽입허용대비_삽입차단.png')
os.remove(D+'_sheet.png') if os.path.exists(D+'_sheet.png') else None
print(os.listdir(D))
