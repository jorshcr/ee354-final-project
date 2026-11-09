"""Simulate the exported INT8 weights and activation rounding on a CPU image.

Uses FP32 convolution arithmetic and host decoding, not native integer inference.
"""
import argparse
import json
from pathlib import Path

import cv2
import numpy as np
from quantize_int8 import DEST, SOURCE, build_stages, dequantize, forward, detect, net_from_parts


def load_export(size):
    manifest=json.loads((DEST/'manifest.json').read_text())
    formats=manifest['sizes'][str(size)]
    weights=np.fromfile(DEST/'weights.int8.bin',dtype='i1')
    biases=np.fromfile(DEST/f'biases-{size}.int64.bin',dtype='<i8')
    layers=[]
    for spec,fmt in zip(manifest['layers'],formats['layers']):
        start=spec['offset_bytes']; count=spec['bytes']
        w=weights[start:start+count].reshape(spec['shape'])
        start=fmt['bias_offset_bytes']//8
        b=biases[start:start+fmt['bias_count']]
        layers.append({'conv':spec['convolution_config'],'pool':spec['pool'],
                       'weights':dequantize(w,spec['weight_fractional_bits']),
                       'bias':dequantize(b,fmt['bias_fractional_bits'])})
    region=dict(manifest['region_decoder_config']); region['thresh']='0.25'
    decoder=net_from_parts([{'type':'net','batch':1,'channels':425,'width':size//32,'height':size//32},region])
    cv2.dnn_DetectionModel(decoder)  # Match the FP32 baseline's disabled internal NMS.
    return build_stages(layers,size),decoder,formats


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image',type=Path)
    parser.add_argument('--size',type=int,choices=[416,256],default=416)
    parser.add_argument('--output',type=Path,default=Path('outputs/int8-detections.jpg'))
    args=parser.parse_args()
    image=cv2.imread(str(args.image))
    if image is None: parser.error(f'Cannot read {args.image}')
    cv2.setNumThreads(4)
    stages,decoder,formats=load_export(args.size)
    logits,_,clipping=forward(stages,image,args.size,formats)
    decoder.setInput(logits); predictions=detect(decoder.forward(),image)
    labels=(SOURCE/'coco.names').read_text().splitlines()
    for p in predictions:
        x,y,w,h=p['box']; label=f"{labels[p['class']]}: {p['confidence']:.0%}"
        cv2.rectangle(image,(x,y),(x+w,y+h),(0,255,0),2)
        cv2.putText(image,label,(x,max(20,y-8)),cv2.FONT_HERSHEY_SIMPLEX,.6,(0,255,0),2)
        print(label)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    assert cv2.imwrite(str(args.output),image)
    print(f"INT8 precision simulation, FP32 arithmetic. Clipped activations: {sum(x['clipped'] for x in clipping)}")
    print(f'Saved {args.output.resolve()}')


if __name__=='__main__':
    main()
