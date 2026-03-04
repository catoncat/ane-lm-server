// SPDX-License-Identifier: MIT
// server.cpp — OpenAI-compatible API server for ANE-LM
// Exposes /v1/chat/completions and /v1/models over HTTP,
// powered by Apple Neural Engine inference via ANE-LM.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <chrono>
#include <mutex>
#include <string>
#include <vector>
#include <utility>
#include <random>

#include <httplib.h>
#include <nlohmann/json.hpp>

#include <ane_lm/common.h>
#include "utils.h"
#include "generate.h"

// ObjC autorelease pool
extern "C" void* objc_autoreleasePoolPush(void);
extern "C" void  objc_autoreleasePoolPop(void*);

using json = nlohmann::json;
using namespace ane_lm;

// --- Globals ---
static std::unique_ptr<LLMModel> g_model;
static Tokenizer g_tokenizer;
static std::mutex g_model_mutex; // model.forward() is not thread-safe
static std::string g_model_id;

static std::string make_completion_id() {
    static std::mt19937 rng(std::random_device{}());
    static const char chars[] = "abcdefghijklmnopqrstuvwxyz0123456789";
    std::string id = "chatcmpl-";
    for (int i = 0; i < 24; i++) {
        id += chars[rng() % (sizeof(chars) - 1)];
    }
    return id;
}

static int64_t now_unix() {
    return std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
}

// --- /v1/models ---
static void handle_models(const httplib::Request&, httplib::Response& res) {
    json resp = {
        {"object", "list"},
        {"data", json::array({
            {
                {"id", g_model_id},
                {"object", "model"},
                {"owned_by", "ane-lm"},
            }
        })}
    };
    res.set_content(resp.dump(), "application/json");
}

// --- /v1/chat/completions ---
static void handle_chat_completions(const httplib::Request& req, httplib::Response& res) {
    json body;
    try {
        body = json::parse(req.body);
    } catch (const std::exception&) {
        res.status = 400;
        res.set_content(R"({"error":{"message":"Invalid JSON","type":"invalid_request_error"}})",
                        "application/json");
        return;
    }

    if (!body.contains("messages") || !body["messages"].is_array()) {
        res.status = 400;
        res.set_content(R"({"error":{"message":"'messages' is required","type":"invalid_request_error"}})",
                        "application/json");
        return;
    }

    std::vector<std::pair<std::string, std::string>> messages;
    for (auto& m : body["messages"]) {
        std::string role = m.value("role", "user");
        std::string content = m.value("content", "");
        messages.push_back({role, content});
    }

    int max_tokens = body.value("max_tokens", 0);
    float temperature = body.value("temperature", 0.6f);
    float rep_penalty = body.value("repetition_penalty", 1.2f);
    float freq_penalty = body.value("frequency_penalty", 0.1f);
    bool stream = body.value("stream", false);
    bool enable_thinking = body.value("enable_thinking", false);

    SamplingParams sampling;
    sampling.temperature = temperature;
    sampling.repetition_penalty = rep_penalty;
    sampling.frequency_penalty = freq_penalty;

    std::string completion_id = make_completion_id();
    int64_t created = now_unix();

    if (stream) {
        // Streaming SSE — callback runs after handler returns,
        // so everything must be captured by value.
        res.set_header("Cache-Control", "no-cache");
        res.set_header("Connection", "keep-alive");

        res.set_chunked_content_provider(
            "text/event-stream",
            [messages = std::move(messages), max_tokens, enable_thinking,
             sampling, completion_id, created]
            (size_t, httplib::DataSink& sink) {
                std::lock_guard<std::mutex> lock(g_model_mutex);

                void* pool = objc_autoreleasePoolPush();
                g_model->reset();

                stream_generate(*g_model, g_tokenizer, messages,
                    max_tokens, enable_thinking, sampling,
                    [&sink, &completion_id, &created](const GenerationResponse& r) {
                        if (r.token == -1) {
                            json chunk = {
                                {"id", completion_id},
                                {"object", "chat.completion.chunk"},
                                {"created", created},
                                {"model", g_model_id},
                                {"choices", json::array({
                                    {{"index", 0}, {"delta", json::object()}, {"finish_reason", "stop"}}
                                })},
                                {"usage", {
                                    {"prompt_tokens", r.prompt_tokens},
                                    {"completion_tokens", r.generation_tokens},
                                    {"total_tokens", r.prompt_tokens + r.generation_tokens}
                                }}
                            };
                            std::string data = "data: " + chunk.dump() + "\n\n";
                            sink.write(data.c_str(), data.size());
                            sink.write("data: [DONE]\n\n", 14);
                            return;
                        }
                        if (!r.text.empty()) {
                            json chunk = {
                                {"id", completion_id},
                                {"object", "chat.completion.chunk"},
                                {"created", created},
                                {"model", g_model_id},
                                {"choices", json::array({
                                    {{"index", 0}, {"delta", {{"content", r.text}}}, {"finish_reason", nullptr}}
                                })}
                            };
                            std::string data = "data: " + chunk.dump() + "\n\n";
                            sink.write(data.c_str(), data.size());
                        }
                    });

                objc_autoreleasePoolPop(pool);
                sink.done();
                return true;
            }
        );
    } else {
        // Non-streaming
        std::lock_guard<std::mutex> lock(g_model_mutex);

        void* pool = objc_autoreleasePoolPush();
        g_model->reset();

        std::string full_text;
        GenerationResponse last{};

        stream_generate(*g_model, g_tokenizer, messages,
            max_tokens, enable_thinking, sampling,
            [&](const GenerationResponse& r) {
                if (r.token == -1) { last = r; return; }
                if (!r.text.empty()) full_text += r.text;
                last = r;
            });

        objc_autoreleasePoolPop(pool);

        json resp = {
            {"id", completion_id},
            {"object", "chat.completion"},
            {"created", created},
            {"model", g_model_id},
            {"choices", json::array({
                {
                    {"index", 0},
                    {"message", {{"role", "assistant"}, {"content", full_text}}},
                    {"finish_reason", "stop"}
                }
            })},
            {"usage", {
                {"prompt_tokens", last.prompt_tokens},
                {"completion_tokens", last.generation_tokens},
                {"total_tokens", last.prompt_tokens + last.generation_tokens}
            }}
        };

        res.set_content(resp.dump(), "application/json");
    }
}

// --- CORS ---
static void add_cors(httplib::Response& res) {
    res.set_header("Access-Control-Allow-Origin", "*");
    res.set_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    res.set_header("Access-Control-Allow-Headers", "Content-Type, Authorization");
}

// --- Main ---
static void print_usage(const char* prog) {
    fprintf(stderr, "Usage: %s --model <path> [options]\n", prog);
    fprintf(stderr, "\nOptions:\n");
    fprintf(stderr, "  --model <path>     Path to model directory (required)\n");
    fprintf(stderr, "  --host <addr>      Listen address (default: 127.0.0.1)\n");
    fprintf(stderr, "  --port <port>      Listen port (default: 8080)\n");
    fprintf(stderr, "  --no-ane-cache     Disable persistent ANE compile cache\n");
    fprintf(stderr, "  -v, --verbose      Show detailed initialization info\n");
}

int main(int argc, char* argv[]) {
    void* pool = objc_autoreleasePoolPush();
    srand48(time(nullptr));

    const char* model_dir = nullptr;
    const char* host = "127.0.0.1";
    int port = 8080;
    bool ane_cache = true;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--model") == 0 && i + 1 < argc) {
            model_dir = argv[++i];
        } else if (strcmp(argv[i], "--host") == 0 && i + 1 < argc) {
            host = argv[++i];
        } else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            port = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--no-ane-cache") == 0) {
            ane_cache = false;
        } else if (strcmp(argv[i], "--verbose") == 0 || strcmp(argv[i], "-v") == 0) {
            g_verbose = true;
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        }
    }

    if (!model_dir) {
        fprintf(stderr, "Error: --model is required\n\n");
        print_usage(argv[0]);
        return 1;
    }

    std::string dir_str(model_dir);
    auto last_slash = dir_str.find_last_of('/');
    g_model_id = (last_slash != std::string::npos) ? dir_str.substr(last_slash + 1) : dir_str;

    fprintf(stderr, "=== ane-lm-server ===\n");
    fprintf(stderr, "Model: %s\n", model_dir);
    fprintf(stderr, "Loading model...\n");

    try {
        auto result = load(model_dir, ane_cache);
        g_model = std::move(result.first);
        g_tokenizer = std::move(result.second);
    } catch (const std::exception& e) {
        fprintf(stderr, "Error loading model: %s\n", e.what());
        objc_autoreleasePoolPop(pool);
        return 1;
    }

    fprintf(stderr, "Model loaded successfully.\n");

    httplib::Server svr;

    svr.Options(".*", [](const httplib::Request&, httplib::Response& res) {
        add_cors(res);
        res.status = 204;
    });

    svr.set_post_routing_handler([](const httplib::Request&, httplib::Response& res) {
        add_cors(res);
    });

    svr.Get("/health", [](const httplib::Request&, httplib::Response& res) {
        res.set_content(R"({"status":"ok"})", "application/json");
    });

    svr.Get("/v1/models", handle_models);
    svr.Post("/v1/chat/completions", handle_chat_completions);

    fprintf(stderr, "\nListening on http://%s:%d\n", host, port);
    fprintf(stderr, "Endpoints:\n");
    fprintf(stderr, "  POST /v1/chat/completions  (streaming & non-streaming)\n");
    fprintf(stderr, "  GET  /v1/models\n");
    fprintf(stderr, "  GET  /health\n");

    if (!svr.listen(host, port)) {
        fprintf(stderr, "Error: failed to listen on %s:%d\n", host, port);
        objc_autoreleasePoolPop(pool);
        return 1;
    }

    objc_autoreleasePoolPop(pool);
    return 0;
}
