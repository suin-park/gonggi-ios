import json,glob
for a in ('const','decay'):
    try: L=json.load(open(f'out_best/log_{a}.json'))
    except Exception: continue
    for d in L: print(a,d['it'],round(d.get('opt_wall_s',0)),'early %.2f front %.2f late %.2f rec %.3f eye %.2f hf %.2f ghost %.4f'%(d['psnr_early'],d['psnr_front'],d['psnr_late'],d['recovery_front'],d['eye_psnr_front'],d['smooth_hf_ratio'],d['ghost_alpha_far']))
