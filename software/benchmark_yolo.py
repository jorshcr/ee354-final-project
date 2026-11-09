"""Reproducible paired 100-image CPU benchmark; JSON, HTML and PNG outputs."""
import hashlib
import html
import json
import platform
import os
import sys
from pathlib import Path
from time import perf_counter

import cv2
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from run_yolo import load_model

ROOT = Path(__file__).resolve().parent
OUT = ROOT / 'outputs' / 'benchmark100'
DATA = ROOT / 'models/coco128-samples/coco128'
VAL2017 = '--val2017' in sys.argv
if VAL2017:
    OUT = ROOT / 'outputs/benchmark-val2017-100'
    DATA = ROOT / 'models/coco-val2017-fixed100'


def iou(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    intersection = max(0, min(ax+aw, bx+bw)-max(ax, bx)) * max(0, min(ay+ah, by+bh)-max(ay, by))
    return intersection / max(aw*ah + bw*bh - intersection, 1e-12)


def match(predictions, truth):
    used = set()
    for p in sorted(predictions, key=lambda p: -p['confidence']):
        candidates = [(iou(p['box'], g['box']), j) for j, g in enumerate(truth)
                      if j not in used and g['class'] == p['class']]
        overlap, j = max(candidates, default=(0, -1))
        p['matched_label'] = j if overlap >= .5 else None
        if overlap >= .5:
            used.add(j)
    return used


def mean(values):
    return float(np.mean(values)) if values else None


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    assert iou([0,0,10,10], [0,0,10,10]) == 1
    assert iou([0,0,10,10], [20,20,10,10]) == 0
    trial = [{'class':0, 'confidence':.9, 'box':[0,0,10,10]},
             {'class':0, 'confidence':.8, 'box':[0,0,10,10]},
             {'class':1, 'confidence':.7, 'box':[0,0,10,10]}]
    assert len(match(trial, [{'class':0,'box':[0,0,10,10]}])) == 1
    cv2.setNumThreads(4)
    cv2.ocl.setUseOpenCL(False)
    official = None
    if VAL2017:
        manifest = json.loads((DATA/'manifest.json').read_text())
        official = json.loads((DATA/'instances_fixed100.json').read_text())
        class_map = {c['id']:i for i,c in enumerate(sorted(official['categories'],key=lambda c:c['id']))}
        files = [DATA/'images'/item['file_name'] for item in manifest['images']]
        assert {int(p.stem) for p in files} == set(manifest['image_ids'])
    else:
        files = sorted((DATA / 'images/train2017').glob('*.jpg'))[:100]
    assert len(files) == 100
    models = {size: load_model(size) for size in (416,256)}
    first = cv2.imread(str(files[0]))
    for model in models.values():
        for _ in range(5):
            model.detect(first, confThreshold=.25, nmsThreshold=.45)
    records = []
    if '--resume' in sys.argv and (OUT/'checkpoint.json').exists():
        records = json.loads((OUT/'checkpoint.json').read_text())
        for record in records:
            record['sizes'] = {int(k):v for k,v in record['sizes'].items()}
        assert [r['image'] for r in records] == [p.name for p in files[:len(records)]]
    names = (ROOT / 'models/tiny-yolov2/coco.names').read_text().splitlines()
    for index, file in enumerate(files):
        if index < len(records):
            continue
        image = cv2.imread(str(file))
        assert image is not None
        h, w = image.shape[:2]
        label = DATA / 'labels/train2017' / (file.stem+'.txt')
        truth = []
        crowd = []
        # YOLO-format datasets omit label files for background images.
        for line in (label.read_text().splitlines() if label.exists() else []):
            c, x, y, bw, bh = map(float, line.split())
            truth.append({'class':int(c), 'box':[(x-bw/2)*w,(y-bh/2)*h,bw*w,bh*h]})
        if official is not None:
            for a in official['annotations']:
                if a['image_id'] == int(file.stem):
                    (crowd if a['iscrowd'] else truth).append({'class':class_map[a['category_id']], 'box':a['bbox'], 'annotation_id':a['id']})
        record = {'image':file.name, 'ground_truth':truth, 'crowd_regions':crowd, 'sizes':{}}
        timings = {416:[], 256:[]}
        predictions = {}
        # Alternate execution order on every repetition and image.
        for rep in range(10):
            order = (416,256) if (rep+index)%2 == 0 else (256,416)
            for size in order:
                start = perf_counter()
                classes, scores, boxes = models[size].detect(image, confThreshold=.25, nmsThreshold=.45)
                timings[size].append((perf_counter()-start)*1000)
                predictions[size] = [{'class':int(c), 'confidence':float(s), 'box':list(map(int,b))}
                                     for c,s,b in zip(classes,scores,boxes)]
        matched = {}
        for size in (416,256):
            preds = predictions[size]
            matched[size] = match(preds, truth)
            tp = len(matched[size])
            for p in preds:
                p['ignored_crowd'] = False
                if p['matched_label'] is None:
                    x,y,pw,ph = p['box']
                    for g in crowd:
                        gx,gy,gw,gh = g['box']
                        intersection = max(0,min(x+pw,gx+gw)-max(x,gx))*max(0,min(y+ph,gy+gh)-max(y,gy))
                        if p['class'] == g['class'] and intersection/max(pw*ph,1e-12) >= .5:
                            p['ignored_crowd'] = True
            ignored = sum(p['ignored_crowd'] for p in preds)
            record['sizes'][size] = {'detections':len(preds), 'mean_confidence':mean([p['confidence'] for p in preds]),
                'median_ms':float(np.median(timings[size])), 'timings_ms':timings[size],
                'tp':tp, 'fp':len(preds)-tp-ignored, 'ignored_crowd':ignored, 'fn':len(truth)-tp, 'predictions':preds}
        common = matched[416] & matched[256]
        record['common_objects'] = [{'label':j, **{str(s):next(p['confidence'] for p in predictions[s] if p['matched_label']==j)
                                                    for s in (416,256)}} for j in sorted(common)]
        records.append(record)
        if (index+1)%10 == 0:
            print(f'Completed {index+1}/100 images', flush=True)
            (OUT/'checkpoint.json').write_text(json.dumps(records))
    summary = {}
    for size in (416,256):
        rows = [r['sizes'][size] for r in records]
        tp, fp, fn = [sum(r[k] for r in rows) for k in ('tp','fp','fn')]
        scores = [p['confidence'] for r in rows for p in r['predictions']]
        correct = [p['confidence'] for r in rows for p in r['predictions'] if p['matched_label'] is not None]
        summary[size] = {'detections':sum(r['detections'] for r in rows), 'tp':tp, 'fp':fp, 'fn':fn,
            'ignored_crowd':sum(r.get('ignored_crowd',0) for r in rows),
            'precision':tp/(tp+fp) if tp+fp else 0, 'recall':tp/(tp+fn),
            'f1':2*tp/(2*tp+fp+fn), 'mean_confidence':mean(scores), 'mean_correct_confidence':mean(correct),
            'mean_image_median_ms':mean([r['median_ms'] for r in rows]),
            'common_object_confidence':mean([p[str(size)] for r in records for p in r['common_objects']])}
    metadata = {'source':'https://github.com/ultralytics/assets/releases/download/v0.0.0/coco128.zip',
        'selection':'First 100 images sorted by filename from COCO128 (COCO train2017 subset). Not held-out validation.',
        'images':100, 'labeled_objects':sum(len(r['ground_truth']) for r in records),
        'background_label_policy':'Absent/empty label files mean zero labeled objects under the YOLO dataset convention.',
        'common_matched_objects':sum(len(r['common_objects']) for r in records),
        'confidence_threshold':.25, 'matching_iou':.5, 'external_nms_iou':.45, 'opencv_region_internal_nms_iou':0,
        'timing':'10 sequential repetitions per size/image, alternating order; 5 initial warmups per model; 4 CPU threads. Includes resize, inference and NMS; excludes disk I/O, model loading and matching.',
        'preprocessing':'Direct square resize (no letterboxing), RGB, divide by 255. Original FP32 weights.',
        'opencv':cv2.__version__, 'python':platform.python_version(), 'processor':platform.processor(),
        'weights_sha256':hashlib.sha256((ROOT/'models/tiny-yolov2/yolov2-tiny.weights').read_bytes()).hexdigest(),
        'caveats':'Precision/recall/F1 at IoU 0.5 and score 0.25, not official COCO mAP. YOLO text labels lack crowd/ignore metadata. Training-set overlap may inflate results. Confidence is not accuracy. Earlier runs had an unintended internal 0.60 threshold; these use corrected 0.25.'}
    if VAL2017:
        metadata.update({
            'source':'http://images.cocodataset.org/annotations/annotations_trainval2017.zip',
            'selection':manifest['selection'], 'dataset':'COCO val2017', 'seed':42,
            'annotations_sha256':manifest['annotations_sha256'],
            'manifest':'../../../models/coco-val2017-fixed100/manifest.json',
            'crowd_annotations':sum(len(r['crowd_regions']) for r in records),
            'background_label_policy':'Official instances_val2017 annotations; non-crowd objects are scored.',
            'caveats':'Precision/recall/F1 at score 0.25 and IoU 0.5, not official COCO mAP. Unmatched same-class predictions with intersection/prediction-area >=0.5 against a crowd region are ignored in precision; crowd regions excluded from recall denominator. No training or tuning on this subset. Original pretrained-weight training provenance not independently audited. Confidence is not accuracy.'})
    result = {'metadata':metadata,'summary':summary,'images':records}
    (OUT/'results.json').write_text(json.dumps(result,indent=2))
    render(result, names)
    print(json.dumps({'metadata':metadata, 'summary':summary},indent=2),flush=True)


def render(result, names):
    summary = result['summary']
    colors = ['#2463a0','#dc7d23']
    fig, axes = plt.subplots(2,2,figsize=(12,8),layout='constrained')
    for ax, key, title, multiplier in [(axes[0,0],'detections','Total detections',1),
            (axes[0,1],'mean_confidence','Mean detection confidence (%)',100),
            (axes[1,0],'mean_image_median_ms','CPU time per image (ms)',1)]:
        values = [summary[s][key]*multiplier for s in (416,256)]
        bars = ax.bar(['416 x 416','256 x 256'],values,color=colors,width=.5)
        ax.bar_label(bars,fmt='%.1f',padding=4)
        ax.set_title(title); ax.set_ylim(0,max(values)*1.2)
        ax.spines[['top','right']].set_visible(False)
    x = np.arange(3)
    for i,size in enumerate((416,256)):
        values = [summary[size][k]*100 for k in ('precision','recall','f1')]
        bars=axes[1,1].bar(x+(i-.5)*.35,values,.35,label=str(size),color=colors[i])
        axes[1,1].bar_label(bars,fmt='%.1f',padding=3)
    axes[1,1].set_xticks(x,['Precision','Recall','F1'])
    axes[1,1].set_ylim(0,100); axes[1,1].legend()
    axes[1,1].set_title('Label-based performance (%) at IoU >= 0.50')
    dataset_name = 'COCO val2017' if VAL2017 else 'COCO'
    fig.suptitle(f'Tiny YOLOv2: 100 {dataset_name} images | FP32 CPU | score >= 25%',fontsize=15)
    fig.savefig(OUT/'comparison.png',dpi=160); plt.close(fig)
    metrics = [('Detections','detections',1),('Correct detections','tp',1),('False detections','fp',1),
        ('Missed labeled objects','fn',1),('Precision (%)','precision',100),('Recall (%)','recall',100),
        ('Ignored crowd detections','ignored_crowd',1),
        ('F1 (%)','f1',100),('Mean confidence (%)','mean_confidence',100),
        ('Confidence on common correct objects (%)','common_object_confidence',100),
        ('Mean image median CPU time (ms)','mean_image_median_ms',1)]
    table=''.join(f'<tr><td>{label}</td><td>{summary[416][key]*scale:.2f}</td><td>{summary[256][key]*scale:.2f}</td></tr>' for label,key,scale in metrics)
    rows=''
    for r in result['images']:
        a,b=r['sizes'][416],r['sizes'][256]
        cells=[r['image'],len(r['ground_truth'])]
        for v in (a,b):
            cells += [v['detections'], '—' if v['mean_confidence'] is None else f"{100*v['mean_confidence']:.1f}%",
                      f"{v['median_ms']:.2f}",v['tp'],v['fp'],v['fn']]
        cells += [b['detections']-a['detections'], f"{a['median_ms']/b['median_ms']:.2f}x"]
        rows+='<tr>'+''.join(f'<td>{html.escape(str(c))}</td>' for c in cells)+'</tr>'
    headers=['Image','Labels']+[f'{size}: {k}' for size in (416,256) for k in ('Count','Confidence','ms','TP','FP','FN')]+['Count delta 256−416','Speedup']
    notes=''.join(f'<li><b>{html.escape(k)}:</b> {html.escape(str(v))}</li>' for k,v in result['metadata'].items())
    document=f'''<!doctype html><html><meta charset="utf-8"><title>Tiny YOLOv2: 100-image comparison</title>
    <style>body{{font:16px system-ui;margin:32px;color:#203044}}table{{border-collapse:collapse;width:100%;margin:24px 0}}th,td{{padding:9px;border-bottom:1px solid #ddd;text-align:right}}th:first-child,td:first-child{{text-align:left}}th{{background:#e9eff6;position:sticky;top:0}}tr:nth-child(even){{background:#f5f7fa}}img{{max-width:1100px;width:100%}}li{{margin:10px 0}}.scroll{{overflow:auto}}</style>
    <h1>Tiny YOLOv2: 100-image {dataset_name} comparison</h1><p>416 × 416 versus 256 × 256. Same FP32 weights and 25% confidence cutoff. Fixed seed 42 for val2017 selection.</p>
    <img src="comparison.png" alt="Comparison charts"><h2>Summary</h2><table><tr><th>Metric</th><th>416 × 416</th><th>256 × 256</th></tr>{table}</table>
    <p><b>Precision:</b> fraction of predictions that correctly match labels. <b>Recall:</b> fraction of labeled objects found. <b>F1:</b> combined precision and recall. A match requires the correct class and box intersection-over-union of at least 50%; each label can match only once.</p>
    <h2>Per-image results</h2><p>TP = correct, FP = false detection, FN = missed label. Confidence is averaged over retained predictions; blank when none.</p><div class="scroll"><table><tr>{''.join('<th>'+h+'</th>' for h in headers)}</tr>{rows}</table></div>
    <h2>Method and limitations</h2><ul>{notes}</ul><p><a href="results.json">Full predictions, labels and all 2,000 timing measurements (JSON)</a> · <a href="https://cocodataset.org/#download">COCO dataset</a></p></html>'''
    (OUT/'report.html').write_text(document,encoding='utf-8')


if __name__ == '__main__':
    main()
