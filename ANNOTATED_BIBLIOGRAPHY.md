# Annotated Bibliography

Papers referenced or learned from during the FPGA Tiny YOLOv2 project.
Each entry includes a citation followed by a paragraph describing its findings and relevance to this project.

## Entry template

Author(s). “Paper Title.” Conference or Journal, Year. [Paper](https://example.com)

Summarize what the paper demonstrates, what was learned, and how it could inform this project. Include relevant limitations when comparing results.

## Papers

Jeon, Wootae, Kyungtae Kang, and Jong-Chan Kim. “End-to-End Delay Analysis and Optimization of Object Detection Module for Autonomous Driving.” Machine Learning for Autonomous Driving Workshop, NeurIPS, 2019. [Paper](https://ml4ad.github.io/files/papers/End-to-End%20Delay%20Analysis%20and%20Optimization%20of%20Object%20Detection%20Module%20for%20Autonomous%20Driving.pdf)

This study compares Darknet YOLO camera pipelines on NVIDIA GPU platforms. Tiny YOLOv2 achieved 21.1 FPS on Jetson TX2, 29.7 FPS on Jetson AGX Xavier, and 31 FPS on Drive PX2; full YOLOv2 achieved 3.22, 8.33, and 10 FPS, respectively. These are system measurements with a 30 FPS camera, not isolated GPU throughput limits. The paper distinguishes throughput from end-to-end latency: a pipeline can process many frames per second while individual frames experience substantial buffering delays. Its detailed optimization uses YOLOv3, reducing latency from 1,335 ms to 229 ms without changing the network. For this project, the paper motivates measuring both FPGA inference time and the complete image-input-to-result delay, including host processing and data transfers.

Wai, Yap June, Zulkalnain bin Mohd Yussof, Sani Irwan bin Salim, and Lim Kim Chuan. “Fixed Point Implementation of Tiny-Yolo-v2 using OpenCL on FPGA.” International Journal of Advanced Computer Science and Applications, vol. 9, no. 10, 2018, pp. 506–512. [Paper](https://thesai.org/Downloads/Volume9No10/Paper_62-Fixed_Point_Implementation_of_Tiny_Yolo_v2.pdf)

This study implements Tiny YOLOv2 using 16-bit fixed-point arithmetic on a Cyclone V PCIe FPGA development board with OpenCL high-level synthesis. It reports peak computational performance of approximately 21 billion operations per second at 100 MHz; this figure is not an end-to-end frame rate. The design folds batch normalization into convolution and uses tiled matrix multiplication and on-the-fly input rearrangement to manage computation and memory traffic. For the Nexys A7 project, it provides a concrete example of quantization, normalization folding, and data reuse in an FPGA detector. Its performance cannot be directly transferred to the Artix-7 implementation because the FPGA resources, memory interface, and accelerator design differ.
