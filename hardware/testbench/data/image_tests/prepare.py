from pathlib import Path
import json
root = Path(__file__).resolve().parent
heart = ['BBBBBBBBB','BRRBBBRRB','RRRRBRRRR','RRRRRRRRR','BRRRRRRRB','BBRRRRRBB','BBBRRRBBB','BBBBRBBBB','BBBBBBBBB']
stairs = [''.join('RGB'[min(2,(y+x)//6)] for x in range(9)) for y in range(9)]
images = []
weights = [[[[0 for ch in range(3)] for x in range(3)] for y in range(3)] for f in range(3)]
for y in range(3):
 for x in range(3):
  for ch in range(3):
   weights[0][y][x][ch]=1
   weights[1][y][x][ch]=x-1
weights[2][1][1][0]=1
weights[2][1][1][2]=-1
(root/'weights.mem').write_text('\n'.join(f'{weights[f][y][x][ch]&255:02x}' for f in range(3) for y in range(3) for x in range(3) for ch in range(3))+'\n')
for name, rows in [('heart',heart),('staircase',stairs)]:
 im = [[[8 if 'RGB'[ch]==rows[y][x] else 0 for ch in range(3)] for x in range(9)] for y in range(9)]
 images.append(dict(name=name, pixels=im, rows=rows))
 (root/f'{name}.mem').write_text('\n'.join(f'{v:02x}' for row in im for px in row for v in px)+'\n')
 expected = [sum(im[y+ky][x+kx][ch]*weights[f][ky][kx][ch] for ky in range(3) for kx in range(3) for ch in range(3)) for y in range(7) for x in range(7) for f in range(3)]
 (root/f'{name}_expected.mem').write_text('\n'.join(f'{v&0xffffffff:08x}' for v in expected)+'\n')
(root/'images.json').write_text(json.dumps(images))
print('Generated heart and diagonal RGB bands; independent direct convolution references.')
