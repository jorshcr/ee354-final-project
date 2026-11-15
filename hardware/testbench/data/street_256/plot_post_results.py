from pathlib import Path
import numpy as np
from PIL import Image
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
root=Path(__file__).resolve().parent
csv=root.parents[2]/'sim'/'street_post_outputs.csv'
out=root.parents[3]/'reports'/'2026-11-15-street-256-postprocessing'
out.mkdir(parents=True,exist_ok=True)
data=np.loadtxt(csv,delimiter=',',skiprows=1,usecols=(1,2,3,4),dtype=np.int32)
assert data.shape==(524288,4),data.shape
indices=(data[:,0]*256+data[:,1])*8+data[:,2]
assert np.array_equal(np.sort(indices),np.arange(524288))
actual=np.empty((256,256,8),np.int32)
actual[data[:,0],data[:,1],data[:,2]]=data[:,3]
raw=np.load(root/'expected.npy').astype(np.int64)
product=np.abs(raw)*np.where(raw<0,104858,1048576)
q,rem=np.divmod(product,1<<27)
q+=((rem>(1<<26))|((rem==(1<<26))&((q&1)==1)))
reference=np.clip(np.where(raw<0,-q,q),-128,127)
assert np.array_equal(actual,reference)

np.save(out/'rtl-outputs.npy',actual)
fig,axes=plt.subplots(3,3,figsize=(13,13),layout='constrained')
fig.suptitle('Street scene · 256×256 · RTL outputs after bias / leaky ReLU / requantization',fontsize=18)
axes.flat[0].imshow(Image.open(root/'street_256.png'))
axes.flat[0].set_title('Input RGB\nQuantized to 0–127 for computation')
names=['Box sum','Sobel X · vertical edges','Sobel Y · horizontal edges','Laplacian','Red − green','Green − blue','Blue − red','Center RGB sum']
stats=[]
for f,name in enumerate(names):
 ax=axes.flat[f+1]; a=actual[:,:,f]; lo=int(a.min()); hi=int(a.max())
 if f in (0,7):
  im=ax.imshow(a,cmap='gray',vmin=0,vmax=max(1,hi))
 else:
  limit=max(abs(lo),abs(hi),1)
  im=ax.imshow(a,cmap='RdBu_r',vmin=-limit,vmax=limit)
 ax.set_title(f'{name}\nINT8 range: {lo} … {hi}',fontsize=11)
 fig.colorbar(im,ax=ax,shrink=.8,pad=.02)
 stats.append(f'{f}: {name}: [{lo}, {hi}]')
for ax in axes.flat:
 ax.set_xticks([]); ax.set_yticks([])
fig.savefig(out/'input-and-outputs.png',dpi=160,bbox_inches='tight')
(out/'ranges.txt').write_text('\n'.join(stats)+'\n',encoding='utf-8')
print('\n'.join(stats).replace('−','-'))
print('All 524288 exported RTL values independently rechecked; plot saved.')

