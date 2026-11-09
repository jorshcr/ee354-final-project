"""Export INT16 convolution weights/activations and simulate quantization effects.

CPU convolution and YOLO decoding remain floating point in this simulator.
It is not a bit-exact integer accelerator or an INT16 speed benchmark.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import sys

import cv2
import numpy as np
from run_yolo import load_model
from benchmark_yolo import match

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT/'models/tiny-yolov2'
DEST = ROOT/'models/tiny-yolov2-int16'
REPORT = ROOT/'outputs/int16-validation'


def blocks():
    result = []
    for line in (SOURCE/'yolov2-tiny.cfg').read_text().splitlines():
        line = line.split('#')[0].strip()
        if line.startswith('['):
            result.append({'type':line[1:-1]})
        elif '=' in line:
            k,v=line.split('=',1); result[-1][k.strip()]=v.strip()
    return result


def cfg(items):
    return '\n'.join('['+b['type']+']\n'+'\n'.join(f'{k}={v}' for k,v in b.items() if k!='type') for b in items)+'\n'


def read_folded():
    data=(SOURCE/'yolov2-tiny.weights').read_bytes()
    version=struct.unpack('<3i',data[:12])
    header=20 if version[0]*10+version[1]>=2 else 16
    floats=np.frombuffer(data[header:],dtype='<f4'); offset=0; channels=3; layers=[]
    for b in blocks()[1:]:
        if b['type']=='convolutional':
            count=int(b['filters']); kernel=int(b['size'])
            bias=floats[offset:offset+count].astype(np.float64); offset+=count
            if b.get('batch_normalize')=='1':
                gamma,mu,var=floats[offset:offset+3*count].astype(np.float64).reshape(3,count); offset+=3*count
                factor=gamma/np.sqrt(var+1e-6)
                bias=bias-factor*mu
            else:
                factor=np.ones(count)
            n=count*channels*kernel*kernel
            w=floats[offset:offset+n].reshape(count,channels,kernel,kernel).astype(np.float64)*factor[:,None,None,None]
            offset+=n
            conv={k:v for k,v in b.items() if k!='batch_normalize'}
            layers.append({'conv':conv,'weights':w.astype(np.float32),'bias':bias.astype(np.float32),'pool':None})
            channels=count
        elif b['type']=='maxpool':
            layers[-1]['pool']=b
    assert offset==len(floats), (offset,len(floats))
    return layers


def net_from_parts(parts, weights=None):
    config=np.frombuffer(cfg(parts).encode(),np.uint8)
    if weights is None:
        net=cv2.dnn.readNetFromDarknet(config)
    else:
        raw=struct.pack('<3iQ',0,2,0,0)+weights
        net=cv2.dnn.readNetFromDarknet(config,np.frombuffer(raw,np.uint8))
    net.setPreferableBackend(cv2.dnn.DNN_BACKEND_OPENCV)
    net.setPreferableTarget(cv2.dnn.DNN_TARGET_CPU)
    return net


def build_stages(layers,size):
    stages=[]; width=size
    for layer in layers:
        w,b=layer['weights'],layer['bias']
        parts=[{'type':'net','batch':1,'channels':w.shape[1],'width':width,'height':width},layer['conv']]
        if layer['pool']:
            parts.append(layer['pool'])
        stages.append(net_from_parts(parts,b.astype('<f4').tobytes()+w.astype('<f4').tobytes()))
        if layer['pool'] and layer['pool']['stride']=='2': width//=2
    return stages


def fractional_bits(maximum):
    return int(math.floor(math.log2(32767/maximum))) if maximum>0 else 15


def quantize(a,f):
    scaled=np.rint(a.astype(np.float64)*2.**f)
    clipped=int(np.count_nonzero((scaled < -32768)|(scaled>32767)))
    q=np.clip(scaled,-32768,32767).astype('<i2')
    return q,clipped


def dequantize(q,f):
    return (q.astype(np.float64)*2.**(-f)).astype(np.float32)


def decoder(size):
    region=dict(blocks()[-1]); region['thresh']='0.25'
    net=net_from_parts([{'type':'net','batch':1,'channels':425,'width':size//32,'height':size//32},region])
    # DetectionModel disables internal Region NMS; reproduce that behavior.
    cv2.dnn_DetectionModel(net)
    return net


def detect(raw,image):
    h,w=image.shape[:2]; candidates={}
    for row in raw:
        c=int(np.argmax(row[5:])); score=float(row[5+c])
        if score<.25: continue
        cx,cy,bw,bh=[int(v) for v in row[:4]*np.array([w,h,w,h],np.float32)]
        x=max(0,min(cx-bw//2,w-1)); y=max(0,min(cy-bh//2,h-1))
        box=[x,y,max(1,min(bw,w-x)),max(1,min(bh,h-y))]
        candidates.setdefault(c,[]).append({'class':c,'confidence':score,'box':box})
    predictions=[]
    for c,items in sorted(candidates.items()):
        keep=cv2.dnn.NMSBoxes([p['box'] for p in items],[p['confidence'] for p in items],.25,.45)
        predictions += [items[int(i)] for i in np.asarray(keep).reshape(-1)]
    return predictions


def forward(stages,image,size,formats=None):
    a=cv2.dnn.blobFromImage(image,1/255,(size,size),swapRB=True)
    clipping=[]; ranges=[]
    if formats:
        q,n=quantize(a,formats['input_fractional_bits']); a=dequantize(q,formats['input_fractional_bits'])
    for index,stage in enumerate(stages):
        stage.setInput(a); a=stage.forward()
        ranges.append(float(np.abs(a).max()))
        if formats:
            f=formats['layers'][index]['output_fractional_bits']
            q,n=quantize(a,f); clipping.append({'clipped':n,'values':int(a.size)})
            a=dequantize(q,f)
    return a,ranges,clipping


def evaluate(predictions,truth,crowd):
    used=match(predictions,truth)
    for p in predictions:
        p['ignored_crowd']=False
        if p['matched_label'] is not None: continue
        x,y,w,h=p['box']
        for g in crowd:
            gx,gy,gw,gh=g['box']
            area=max(0,min(x+w,gx+gw)-max(x,gx))*max(0,min(y+h,gy+gh)-max(y,gy))
            if p['class']==g['class'] and area/max(w*h,1e-12)>=.5: p['ignored_crowd']=True
    ignored=sum(p['ignored_crowd'] for p in predictions)
    return {'detections':len(predictions),'tp':len(used),'fp':len(predictions)-len(used)-ignored,
            'fn':len(truth)-len(used),'ignored_crowd':ignored,'predictions':predictions}


def main():
    cv2.setNumThreads(4); cv2.ocl.setUseOpenCL(False)
    DEST.mkdir(exist_ok=True); REPORT.mkdir(parents=True,exist_ok=True)
    layers=read_folded()
    calibration=sorted((ROOT/'models/coco128-samples/coco128/images/train2017').glob('*.jpg'))[:64]
    validation=json.loads((ROOT/'outputs/benchmark-val2017-100/results.json').read_text())
    assert not ({p.name for p in calibration}&{r['image'] for r in validation['images']})
    specs=[]
    with (DEST/'weights.int16.bin').open('wb') as stream:
        for i,l in enumerate(layers):
            f=fractional_bits(float(np.abs(l['weights']).max()))
            q,n=quantize(l['weights'],f); assert n==0
            offset=stream.tell(); stream.write(q.tobytes())
            l['qweights']=q
            specs.append({'layer':i,'shape':list(q.shape),'weight_fractional_bits':f,
                          'convolution_config':l['conv'],
                          'offset_bytes':offset,'bytes':q.nbytes,'kernel':int(l['conv']['size']),
                          'activation':l['conv']['activation'],'pool':l['pool'],
                          'max_weight_error':float(np.abs(l['weights']-dequantize(q,f)).max())})
    manifest={'format':'signed INT16, little endian, power-of-two scaling per convolution layer',
              'decode':'real = stored_integer * 2**(-fractional_bits)',
              'layout':'OIHW: output channel, input channel, kernel row, kernel column; C-contiguous',
              'batchnorm':'Folded into convolution weights and biases; epsilon 1e-6 matches OpenCV Darknet importer.',
              'weights_file':'weights.int16.bin','weights_bytes':(DEST/'weights.int16.bin').stat().st_size,
              'source_weights_sha256':hashlib.sha256((SOURCE/'yolov2-tiny.weights').read_bytes()).hexdigest(),
              'calibration_images':[p.name for p in calibration], 'calibration_dataset':'COCO128 training subset, first 64 sorted filenames',
              'activation_headroom':1.1, 'rounding':'nearest, ties to even; saturate only at INT16 output boundaries',
              'region_decoder_config':blocks()[-1],
              'layers':specs,'sizes':{}}
    for size in (416,256):
        stages=build_stages(layers,size); decode=decoder(size)
        peaks=np.zeros(9)
        for j,file in enumerate(calibration):
            image=cv2.imread(str(file)); assert image is not None
            logits,ranges,_=forward(stages,image,size); peaks=np.maximum(peaks,ranges)
            if j==0:
                # Check folding, stage boundaries and decoder against original OpenCV pipeline.
                decode.setInput(logits); p=detect(decode.forward(),image)
                c,s,b=load_model(size).detect(image,confThreshold=.25,nmsThreshold=.45)
                assert [x['class'] for x in p]==list(map(int,c)), 'FP32 class parity failure'
                assert np.allclose([x['confidence'] for x in p],s,atol=2e-4), 'FP32 score parity failure'
                assert np.array_equal(np.asarray([x['box'] for x in p]),np.asarray(b)), 'FP32 box parity failure'
            if (j+1)%16==0: print(f'{size}: calibrated {j+1}/64',flush=True)
        formats={'input_size':size,'input_fractional_bits':14,'layers':[]}
        input_f=14
        with (DEST/f'biases-{size}.int64.bin').open('wb') as stream:
            for i,l in enumerate(layers):
                f=specs[i]['weight_fractional_bits']; accum_f=input_f+f
                bias=np.rint(l['bias'].astype(np.float64)*2.**accum_f)
                assert np.max(np.abs(bias))<2**63
                bq=bias.astype('<i8'); output_f=fractional_bits(peaks[i]*1.1)
                bound=int(np.max(np.abs(l['qweights'].astype(np.int64)).reshape(len(bq),-1).sum(1)*32768+np.abs(bq)))
                bits=1+bound.bit_length(); assert bits<=64
                formats['layers'].append({'layer':i,'input_fractional_bits':input_f,'weight_fractional_bits':f,
                    'bias_fractional_bits':accum_f,'output_fractional_bits':output_f,
                    'requantization_right_shift':accum_f-output_f,'bias_offset_bytes':stream.tell(),
                    'bias_count':len(bq),'safe_accumulator_bits':bits,'calibration_peak':float(peaks[i])})
                stream.write(bq.tobytes()); input_f=output_f
        manifest['sizes'][str(size)]=formats
        (DEST/f'format-{size}.json').write_text(json.dumps(formats,indent=2))
    (DEST/'manifest.json').write_text(json.dumps(manifest,indent=2))
    (DEST/'README.md').write_text('''# Tiny YOLOv2 INT16 export

Both 416 and 256 inputs share weights.int16.bin. Load the corresponding format-SIZE.json and biases-SIZE.int64.bin. The manifest gives OIHW shapes, byte offsets and binary-point positions. All binaries are little-endian.

Weights and activation buffers are signed INT16. Each layer has its own binary point: real = integer * 2^(-fractional_bits). Biases are INT64 at the input-plus-weight fractional precision. Batch normalization is folded into the convolutions. INT64 is the conservative reference accumulator; the format files contain smaller proven-safe signed accumulator widths using the full INT16 input range and each filter's sum of absolute weights.

Convolution: A = sum(input_int16 * weight_int16) + bias_int64. Apply leaky ReLU to negative A with rational slope 1/10, then convert from the accumulator binary point to the output binary point, rounding nearest ties-to-even and saturating to [-32768,32767]. Combine the divide-by-10 and power-of-two shift before rounding to avoid double rounding. Positive/linear outputs use just the power-of-two shift. Max pooling preserves the binary point and commutes with monotonic rounding/saturation. Odd-size stride-one maxpool uses bottom/right padding (negative infinity).

Input: resize to the selected square resolution, RGB, normalize by 255, round to 14 fractional bits. Output: 425 INT16 logits per grid cell (13x13 or 8x8); use the last output fractional bits to recover real logits before YOLO decoding.

The CPU validation simulator rounds/clamps inputs and layer outputs and uses quantized weights/biases, but performs convolution and leaky ReLU in FP32. It is an approximation of integer arithmetic, not a bit-exact RTL reference. Sigmoid, softmax, exponentials, box decoding and NMS remain floating-point host operations. This is an FPGA parameter export and precision specification, not a synthesized FPGA design or an integer CPU speed benchmark. FPGA overflow, rounding and decoder implementation still require hardware verification.

Activation ranges were calibrated only on 64 COCO128 training images with 10% headroom, separately for each resolution. The fixed 100-image val2017 set was used only for evaluation. Original FP32 files are preserved.
''')
    run_validation(manifest,layers,validation)


def run_validation(manifest,layers,validation):
    results=[]
    for size in (416,256):
        formats=manifest['sizes'][str(size)]; quant_layers=[]
        biases=np.fromfile(DEST/f'biases-{size}.int64.bin',dtype='<i8')
        for i,l in enumerate(layers):
            spec=formats['layers'][i]; offset=spec['bias_offset_bytes']//8
            quant_layers.append({**l,'weights':dequantize(l['qweights'],spec['weight_fractional_bits']),
                'bias':dequantize(biases[offset:offset+spec['bias_count']],spec['bias_fractional_bits'])})
        stages=build_stages(quant_layers,size); decode=decoder(size)
        rows=[]; saturation=[{'clipped':0,'values':0} for _ in layers]
        for j,r in enumerate(validation['images']):
            image=cv2.imread(str(ROOT/'models/coco-val2017-fixed100/images'/r['image']))
            logits,_,clipping=forward(stages,image,size,formats)
            decode.setInput(logits); predictions=detect(decode.forward(),image)
            score=evaluate(predictions,r['ground_truth'],r.get('crowd_regions',[]))
            rows.append({'image':r['image'],**score})
            for a,b in zip(saturation,clipping):
                for k in a: a[k]+=b[k]
            if (j+1)%20==0: print(f'{size}: evaluated {j+1}/100',flush=True)
        tp,fp,fn=[sum(r[k] for r in rows) for k in ('tp','fp','fn')]
        scores=[p['confidence'] for r in rows for p in r['predictions']]
        summary={'detections':sum(r['detections'] for r in rows),'tp':tp,'fp':fp,'fn':fn,
            'ignored_crowd':sum(r['ignored_crowd'] for r in rows),'precision':tp/(tp+fp),
            'recall':tp/(tp+fn),'f1':2*tp/(2*tp+fp+fn),'mean_confidence':float(np.mean(scores))}
        results.append({'size':size,'fp32':validation['summary'][str(size)],'int16_simulated':summary,
                        'activation_saturation':saturation,'images':rows})
    report={'method':'INT16 weights/activations, INT64 biases; FP32 arithmetic simulation, not bit-exact integer execution.',
            'validation':'Fixed 100 COCO val2017 images, seed 42; IoU .5, confidence .25, crowd handling as baseline.',
            'results':results}
    (REPORT/'results.json').write_text(json.dumps(report,indent=2))
    rows=''
    for label,key,factor in [('Detections','detections',1),('Correct','tp',1),('Precision (%)','precision',100),
        ('Recall (%)','recall',100),('F1 (%)','f1',100),('Mean confidence (%)','mean_confidence',100)]:
        values=[r[mode][key]*factor for r in results for mode in ('fp32','int16_simulated')]
        rows+='<tr><td>'+label+'</td>'+''.join(f'<td>{v:.2f}</td>' for v in values)+'</tr>'
    details=''
    for r in results:
        details+=f"<h2>{r['size']} per-image INT16 simulation</h2><table><tr><th>Image</th><th>Detections</th><th>Correct</th><th>False</th><th>Missed</th></tr>"
        for image in r['images']:
            details+='<tr>'+''.join(f'<td>{image[k]}</td>' for k in ('image','detections','tp','fp','fn'))+'</tr>'
        details+='</table>'
    (REPORT/'report.html').write_text(f'''<!doctype html><meta charset="utf-8"><title>INT16 validation</title>
    <style>body{{font:16px system-ui;max-width:1100px;margin:40px auto;color:#203044}}td,th{{padding:10px;text-align:right;border-bottom:1px solid #ddd}}table{{border-collapse:collapse;width:100%}}th{{background:#e9eff6}}td:first-child{{text-align:left}}</style>
    <h1>Tiny YOLOv2: INT16 precision simulation</h1><p>Fixed 100 COCO val2017 images. Original FP32 versus INT16 weights and activation rounding, with FP32 convolution arithmetic.</p>
    <table><tr><th>Metric</th><th>416 FP32</th><th>416 INT16 sim</th><th>256 FP32</th><th>256 INT16 sim</th></tr>{rows}</table>
    <p>25% confidence threshold; class-correct IoU >= 0.5; crowd regions handled separately. No inference-speed claim: this is not integer execution. Calibration uses 64 separate training images.</p>
    <p>Activation clipped counts (416 / 256): {sum(x['clipped'] for x in results[0]['activation_saturation'])} / {sum(x['clipped'] for x in results[1]['activation_saturation'])}. See JSON for per-layer denominators.</p>
    <a href="results.json">Full results and saturation counts</a>{details}''',encoding='utf-8')
    print(json.dumps({str(r['size']):r['int16_simulated'] for r in results},indent=2),flush=True)


if __name__=='__main__':
    main()
