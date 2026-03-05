# ane-lm-server

OpenAI-compatible local API server for [ANE-LM](https://github.com/johnmai-dev/ANE-LM), packaged as a macOS menu bar app.

## What Is This?

`ANE-LM Server.app` runs a local OpenAI-compatible endpoint backed by Apple Neural Engine (ANE).  
You can connect ChatBox, Open WebUI, Cursor, or custom OpenAI clients to it.

All inference runs on **ANE** (Apple Silicon only).

<img width="712" height="398" alt="image" src="https://github.com/user-attachments/assets/9dfd0377-55a5-433f-a98e-4a14eab3b9ea" />

<img width="828" height="846" alt="image" src="https://github.com/user-attachments/assets/4728ae16-55ef-4762-b4cc-229dd534e170" />

## Requirements (App Usage)

- macOS 13.0+
- Apple Silicon (M1/M2/M3/M4/M5)
- Internet access for first model download
- A few GB of free disk space for model files

If you build from source, also install:

- Xcode Command Line Tools (`xcode-select --install`)
- CMake 3.20+

## Quick Start (App-First)

```bash
# 1) Clone (submodule required)
git clone --recursive https://github.com/catoncat/ane-lm-server.git
cd ane-lm-server

# 2) Build macOS app bundle
./build-app.sh

# 3) Launch app
open "build/ANE-LM Server.app"
```

Then use the menu bar app:

1. Select model preset (`Qwen3.5-0.8B` or `Qwen3-0.6B`) and mirror source.
2. Download one or both models (parallel downloads are supported).
3. Click `Start Server`, or switch model in app and click switch/restart.
4. For next launches, if a model already exists, the app auto-starts.
5. Copy API URL from the app UI (`http://127.0.0.1:8080/v1`).

Default local model root used by the app:

`~/Library/Application Support/ANELMServer/models/`

## Client Setup

Set your OpenAI-compatible client to:

- Base URL: `http://127.0.0.1:8080/v1`
- Model: selected app model (for example `Qwen3.5-0.8B` or `Qwen3-0.6B`)
- API key: any value (or empty, depending on client)

## API Compatibility

Endpoints:

- `POST /v1/chat/completions`
- `GET /v1/models`
- `GET /health`

Example:

```bash
curl -N http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3.5-0.8B",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'
```

## Optional: Run CLI Server Manually (Developer)

If you want to bypass the app and run the binary directly:

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target ane-lm-server -j"$(sysctl -n hw.ncpu)"

./build/ane-lm-server \
  --model "$HOME/Library/Application Support/ANELMServer/models/Qwen3.5-0.8B" \
  --host 127.0.0.1 \
  --port 8080
```

CLI flags:

```
--model <path>     Path to model directory (required)
--host <addr>      Listen address (default: 127.0.0.1)
--port <port>      Listen port (default: 8080)
--no-ane-cache     Disable persistent ANE compile cache
-v, --verbose      Show detailed initialization info
```

## Supported Models

- Qwen3 (dense)
- Qwen3.5 (dense, text-only)
  See [ANE-LM](https://github.com/johnmai-dev/ANE-LM) for upstream model support updates.

## Acknowledgments

- [ANE-LM](https://github.com/johnmai-dev/ANE-LM) by John Mai
- [cpp-httplib](https://github.com/yhirose/cpp-httplib)
- [llama.cpp](https://github.com/ggml-org/llama.cpp)

## License

MIT — see [LICENSE](LICENSE)

This project uses [ANE-LM](https://github.com/johnmai-dev/ANE-LM) (MIT) as a submodule.
