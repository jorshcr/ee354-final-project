from pathlib import Path
import csv, json
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
root=Path(__file__).resolve().parent
sim=root.parents[2]/'sim'
images=json.loads((root/'images.json').read_text())
records=list(csv.DictReader((sim/'image_outputs.csv').open()))
assert len(records)==294
for item in images:
 name=item['name']
 maps=np.zeros((3,7,7),dtype=int)
 seen=set()
 for row in records:
  if row['image']==name:
   y,x,f=map(int,[row['y'],row['x'],row['filter']])
   assert (f,y,x) not in seen
   seen.add((f,y,x)); maps[f,y,x]=int(row['value'])
 assert len(seen)==147
 expected=[int(v,16) for v in (root/f'{name}_expected.mem').read_text().split()]
 expected=np.array([v if v<2**31 else v-2**32 for v in expected]).reshape(7,7,3).transpose(2,0,1)
 assert np.array_equal(maps,expected)
 fig,axes=plt.subplots(1,4,figsize=(16,4.6),layout='constrained')
 title='Red heart' if name=='heart' else 'RGB staircase (diagonal bands)'
 fig.suptitle(title+' — actual RTL simulation outputs',fontsize=18)
 axes[0].imshow(np.array(item['pixels'])/8,interpolation='nearest')
 axes[0].set_title('Input · 9×9 RGB\nActive channel = 8 (display scaled)',fontsize=11)
 for y in range(9):
  for x in range(9):
   label=item['rows'][y][x]
   axes[0].text(x,y,label,ha='center',va='center',fontsize=9,color='black' if label=='G' else 'white')
 titles=['Box sum · 7×7\nAll kernel weights = 1','Vertical edge · 7×7\n[-1, 0, 1] across each kernel row','Red minus blue · 7×7\nCenter R − center B']
 for f in range(3):
  ax=axes[f+1]
  if f==0: ax.imshow(maps[f],cmap='Blues',vmin=0,vmax=72,interpolation='nearest')
  else: ax.imshow(maps[f],cmap='RdBu_r',vmin=-8,vmax=8,interpolation='nearest')
  ax.set_title(titles[f],fontsize=11)
  for y in range(7):
   for x in range(7):
    v=maps[f,y,x]
    ax.text(x,y,str(v),ha='center',va='center',fontsize=10,color='white' if (f==0 or abs(v)>=6) else 'black')
 for i,ax in enumerate(axes):
  n=9 if i==0 else 7
  ax.set_xticks(range(n)); ax.set_yticks(range(n))
  ax.set_xlabel('Column'); ax.set_ylabel('Row')
  ax.set_xticks(np.arange(-.5,n,1),minor=True); ax.set_yticks(np.arange(-.5,n,1),minor=True)
  ax.grid(which='minor',color='gray',linewidth=.4); ax.tick_params(which='minor',length=0)
 fig.savefig(root/f'{name}_rtl.png',dpi=170,bbox_inches='tight',pad_inches=0.15)
 plt.close(fig)
 print(root/f'{name}_rtl.png')

