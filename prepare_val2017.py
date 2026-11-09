"""Freeze 100 COCO val2017 images with seed 42 and official annotations."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import random
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent
DEST = ROOT / 'models/coco-val2017-fixed100'
DEST.mkdir(exist_ok=True)
with zipfile.ZipFile(ROOT/'models/annotations_trainval2017.zip') as z:
    raw = z.read('annotations/instances_val2017.json')
data = json.loads(raw)
selected = sorted(random.Random(42).sample(sorted(data['images'], key=lambda x:x['id']),100),key=lambda x:x['id'])
ids = {x['id'] for x in selected}
subset = {**data,'images':selected,'annotations':[a for a in data['annotations'] if a['image_id'] in ids]}
(DEST/'instances_fixed100.json').write_text(json.dumps(subset))
manifest = {'dataset':'COCO val2017','seed':42,'selection':'Python random.Random(42).sample of image-ID-sorted official val2017 image list; 100 without replacement; then sort selected IDs.',
            'annotations_sha256':hashlib.sha256(raw).hexdigest(),'image_ids':sorted(ids),'images':selected}
(DEST/'manifest.json').write_text(json.dumps(manifest,indent=2))
(DEST/'images').mkdir(exist_ok=True)

def download(item):
    target = DEST/'images'/item['file_name']
    if not target.exists():
        for attempt in range(3):
            try:
                urllib.request.urlretrieve('http://images.cocodataset.org/val2017/'+item['file_name'],target)
                break
            except Exception:
                if attempt == 2:
                    raise
                time.sleep(1)
    return {'file':item['file_name'],'sha256':hashlib.sha256(target.read_bytes()).hexdigest()}

with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    hashes = list(pool.map(download,selected))
manifest['image_hashes'] = hashes
(DEST/'manifest.json').write_text(json.dumps(manifest,indent=2))
print(f"Prepared {len(selected)} fixed val2017 images; {len(subset['annotations'])} annotations.")
