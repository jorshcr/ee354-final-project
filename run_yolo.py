"""Run the downloaded, full-precision Tiny YOLOv2 on one image."""
import argparse
from pathlib import Path
from time import perf_counter

import cv2
import numpy as np
import re


def load_model(size, confidence=0.25):
    folder = Path(__file__).resolve().parent / "models" / "tiny-yolov2"
    # OpenCV honors the region-layer threshold before DetectionModel filtering.
    config = re.sub(r"(?m)^thresh\s*=.*$", f"thresh={confidence}",
                    (folder / "yolov2-tiny.cfg").read_text())
    net = cv2.dnn.readNetFromDarknet(
        np.frombuffer(config.encode(), dtype=np.uint8),
        np.fromfile(folder / "yolov2-tiny.weights", dtype=np.uint8))
    net.setPreferableBackend(cv2.dnn.DNN_BACKEND_OPENCV)
    net.setPreferableTarget(cv2.dnn.DNN_TARGET_CPU)
    model = cv2.dnn_DetectionModel(net)
    model.setInputParams(size=(size, size), scale=1 / 255, swapRB=True)
    return model


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("--size", type=int, choices=(256, 416), default=416)
    parser.add_argument("--output", type=Path, default=Path("detections.jpg"))
    parser.add_argument("--confidence", type=float, default=0.25)
    args = parser.parse_args()
    image = cv2.imread(str(args.image))
    if image is None:
        parser.error(f"Cannot read image: {args.image}")
    folder = Path(__file__).resolve().parent / "models" / "tiny-yolov2"
    labels = (folder / "coco.names").read_text().splitlines()
    model = load_model(args.size, args.confidence)
    start = perf_counter()
    classes, scores, boxes = model.detect(
        image, confThreshold=args.confidence, nmsThreshold=0.45
    )
    elapsed = perf_counter() - start
    for class_id, score, box in zip(classes, scores, boxes):
        x, y, w, h = map(int, box)
        label = f"{labels[int(class_id)]}: {float(score):.0%}"
        print(label)
        cv2.rectangle(image, (x, y), (x + w, y + h), (0, 255, 0), 2)
        cv2.putText(image, label, (max(0, x), max(20, y - 8)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not cv2.imwrite(str(args.output), image):
        raise RuntimeError(f"Could not save {args.output}")
    print(f"CPU detection: {elapsed:.3f} s (single run, includes startup effects)")
    print(f"Found {len(classes)} objects. Saved {args.output.resolve()}")


if __name__ == "__main__":
    main()
