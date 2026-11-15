from pathlib import Path
from PIL import Image
import numpy as np
root=Path(__file__).resolve().parent
source=Image.open(root/'candidates_source.png').convert('RGB')
print('Contact sheet dimensions:',source.size)
# Extract candidate B only, excluding its border and caption.
im=source.crop((647,8,1238,555)).resize((256,256),Image.Resampling.LANCZOS)
im.save(root/'street_256.png')
a=np.asarray(im,dtype=np.int32)//2
w=np.zeros((8,3,3,3),dtype=np.int32)
kernels=[[[1,1,1],[1,1,1],[1,1,1]],
         [[-1,0,1],[-2,0,2],[-1,0,1]],
         [[-1,-2,-1],[0,0,0],[1,2,1]],
         [[0,-1,0],[-1,4,-1],[0,-1,0]]]
for f,kernel in enumerate(kernels): w[f]=np.array(kernel)[:,:,None]
w[4,1,1]=[1,-1,0]; w[5,1,1]=[0,1,-1]; w[6,1,1]=[-1,0,1]; w[7,1,1]=[1,1,1]
padded=np.pad(a,((1,1),(1,1),(0,0)))
expected=np.zeros((256,256,8),dtype=np.int32)
for ky in range(3):
 for kx in range(3):
  for ch in range(3):
   expected+=padded[ky:ky+256,kx:kx+256,ch,None]*w[:,ky,kx,ch]
(root/'pixels.mem').write_text('\n'.join(f'{int(v):02x}' for v in a.flat)+'\n')
(root/'weights.mem').write_text('\n'.join(f'{int(v)&255:02x}' for v in w.flat)+'\n')
(root/'expected.mem').write_text('\n'.join(f'{int(v)&0xffffffff:08x}' for v in expected.flat)+'\n')
np.save(root/'expected.npy',expected)
print('Prepared 196608 input bytes, 216 weights, 524288 reference outputs.')
