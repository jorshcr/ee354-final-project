# Tiny YOLOv2 FPGA Accelerator

Target: Nexys A7-100T, with INT8 weights and activations and INT32 accumulation.
One reusable accelerator processes the network layer by layer.

## Top-level architecture

```text
                      PC
           Image preparation / model loading
           Final box decoding / NMS
                       |
                       v
+-------------------- FPGA ----------------------+
|                                                |
|  Layer controller                              |
|  Dimensions, addresses, scales, start/done      |
|          |                                     |
|          v                                     |
|  +--------- Reusable accelerator ------------+  |
|  | Input buffer         Weight buffer       |  |
|  |       +--------+----------+              |  |
|  |                v                         |  |
|  |       Convolution MAC engine             |  |
|  |                v                         |  |
|  |      Bias / activation / rescaling       |  |
|  |                v                         |  |
|  |        Optional max pooling              |  |
|  |                v                         |  |
|  |          Output buffer                   |  |
|  +------------------------------------------+  |
|                ^                               |
|                |                               |
|                v                               |
|  Memory transfer logic + DDR2 controller        |
+----------------^-------------------------------+
                 |
                 v
          External DDR2 memory
         Weights + feature maps
```

For each layer, the controller loads input and weight tiles into BRAM,
runs convolution and the required output operations, then writes results
to DDR2 for the next layer. The engine supports 3x3 and 1x1 convolutions;
activation and pooling are enabled or bypassed according to the model.
The final prediction convolution is linear.

On the Nexys A7, an FPGA state machine sequences the layers; the PC handles
preparation and final detection processing. This is the planned architecture,
not a claim of completed hardware.
