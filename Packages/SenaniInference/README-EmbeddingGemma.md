# EmbeddingGemma

`SenaniInference` keeps EmbeddingGemma support split into two layers:

- `EmbeddingGemmaEmbedder` lives in the base target and pins the model contract: `mlx-community/embeddinggemma-300m-4bit`, 768-dimensional vectors, 2,048-token context, and MRL truncation to 512, 256, or 128 dimensions.
- `EmbeddingGemmaMLXEmbedder` lives in the optional `SenaniInferenceEmbeddingGemmaMLX` target and runs the native MLX model through the vendored `MLXEmbedders` package.

Install the optional source dependency:

```sh
Packages/SenaniInference/Scripts/install-embeddinggemma-mlx.sh
```

Verify the native adapter compiles:

```sh
cd Packages/SenaniInference
swift build --target SenaniInferenceEmbeddingGemmaMLX
```

The adapter expects `modelPath` to point at a local EmbeddingGemma MLX model directory containing `config.json`, tokenizer files, and safetensors weights. Model weights stay out of git.

The installer also copies `default.metallib` into the inference package and app directories because MLX Swift looks for that file in the process working directory when using the GPU backend.
