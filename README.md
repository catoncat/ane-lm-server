# ane-lm-server

OpenAI-compatible API server for [ANE-LM](https://github.com/johnmai-dev/ANE-LM) — run LLM inference on Apple Neural Engine with a standard HTTP API.

## What is this?

This project wraps ANE-LM into an HTTP server that speaks the OpenAI API protocol. Any client that supports the OpenAI API (ChatBox, Open WebUI, Cursor, custom apps, etc.) can connect directly.

All inference runs on the **Apple Neural Engine (ANE)**, not CPU or GPU.
<img width="712" height="398" alt="image" src="https://github.com/user-attachments/assets/9dfd0377-55a5-433f-a98e-4a14eab3b9ea" />

<img width="828" height="846" alt="image" src="https://github.com/user-attachments/assets/4728ae16-55ef-4762-b4cc-229dd534e170" />


## Requirements

- macOS 13.0+
- Apple Silicon (M1/M2/M3/M4/M5)
- CMake 3.20+
- A supported model in safetensors format (e.g. Qwen3.5-0.8B)

## Quick Start

```bash
# Clone with submodules
git clone --recursive https://github.com/catoncat/ane-lm-server.git
cd ane-lm-server

# Build
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(sysctl -n hw.ncpu)

# Download a model
huggingface-cli download Qwen/Qwen3.5-0.8B --local-dir ~/models/Qwen3.5-0.8B

# Run
./build/ane-lm-server --model ~/models/Qwen3.5-0.8B --port 8080
```

## API

### `POST /v1/chat/completions`

OpenAI-compatible chat completions. Supports both streaming (SSE) and non-streaming responses.

```bash
# Non-streaming
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3.5-0.8B",
    "messages": [{"role": "user", "content": "Hello!"}],
    "temperature": 0.7,
    "max_tokens": 100
  }'

# Streaming
curl -N http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3.5-0.8B",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'
```


### `GET /v1/models`

List available models.

### `GET /health`

Health check endpoint.

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `messages` | array | required | Chat messages `[{role, content}]` |
| `stream` | bool | false | Enable SSE streaming |
| `max_tokens` | int | 0 (unlimited) | Max tokens to generate |
| `temperature` | float | 0.6 | Sampling temperature |
| `repetition_penalty` | float | 1.2 | Repetition penalty (1.0 = off) |
| `frequency_penalty` | float | 0.1 | Frequency penalty |
| `enable_thinking` | bool | false | Enable reasoning mode |

## CLI Options

```
--model <path>     Path to model directory (required)
--host <addr>      Listen address (default: 127.0.0.1)
--port <port>      Listen port (default: 8080)
--no-ane-cache     Disable persistent ANE compile cache
-v, --verbose      Show detailed initialization info
```

## Run as macOS Service

Install as a `launchd` user agent for auto-restart on crash:

```bash
# Edit the plist to set your model path
cp service/com.ane-lm.server.plist ~/Library/LaunchAgents/

# Load & start
launchctl load ~/Library/LaunchAgents/com.ane-lm.server.plist
launchctl start com.ane-lm.server

# Stop & unload
launchctl stop com.ane-lm.server
launchctl unload ~/Library/LaunchAgents/com.ane-lm.server.plist
```

## Use with Clients

Set the API Base URL in your client to:

```
http://127.0.0.1:8080/v1
```

No API key is required (any value works).

## Supported Models

- Qwen3.5 (dense, text-only) — see [ANE-LM](https://github.com/johnmai-dev/ANE-LM) for updates

## Acknowledgments

- [ANE-LM](https://github.com/johnmai-dev/ANE-LM) by John Mai — LLM inference on Apple Neural Engine
- [cpp-httplib](https://github.com/yhirose/cpp-httplib) — Header-only C++ HTTP server
- [llama.cpp](https://github.com/ggml-org/llama.cpp) — Inspiration for the server design

## License

MIT — see [LICENSE](LICENSE)

This project uses [ANE-LM](https://github.com/johnmai-dev/ANE-LM) (MIT) as a submodule.
