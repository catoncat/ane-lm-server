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
#include <regex>
#include <sstream>

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

static std::string make_tool_call_id() {
    static std::mt19937 rng(std::random_device{}());
    static const char chars[] = "abcdefghijklmnopqrstuvwxyz0123456789";
    std::string id = "call_";
    for (int i = 0; i < 24; i++) {
        id += chars[rng() % (sizeof(chars) - 1)];
    }
    return id;
}

static int64_t now_unix() {
    return std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
}

// --- Tool call parsing ---
// Qwen3.5 outputs tool calls in this format:
//   <tool_call>
//   <function=func_name>
//   <parameter=param_name>
//   value
//   </parameter>
//   </function>
//   </tool_call>

struct ParsedToolCall {
    std::string name;
    json arguments;
};

static std::vector<ParsedToolCall> parse_tool_calls(const std::string& text) {
    std::vector<ParsedToolCall> calls;

    // Find all <tool_call>...</tool_call> blocks
    size_t pos = 0;
    while (true) {
        size_t start = text.find("<tool_call>", pos);
        if (start == std::string::npos) break;
        size_t end = text.find("</tool_call>", start);
        if (end == std::string::npos) break;

        std::string block = text.substr(start + 11, end - start - 11);
        pos = end + 12;

        // Extract function name: <function=NAME>
        size_t fn_start = block.find("<function=");
        if (fn_start == std::string::npos) continue;
        size_t fn_name_start = fn_start + 10;
        size_t fn_name_end = block.find(">", fn_name_start);
        if (fn_name_end == std::string::npos) continue;
        std::string func_name = block.substr(fn_name_start, fn_name_end - fn_name_start);

        size_t fn_close = block.find("</function>", fn_name_end);
        if (fn_close == std::string::npos) fn_close = block.size();
        std::string fn_body = block.substr(fn_name_end + 1, fn_close - fn_name_end - 1);

        // Extract parameters: <parameter=NAME>VALUE</parameter>
        json args = json::object();
        size_t p = 0;
        while (true) {
            size_t pstart = fn_body.find("<parameter=", p);
            if (pstart == std::string::npos) break;
            size_t pname_start = pstart + 11;
            size_t pname_end = fn_body.find(">", pname_start);
            if (pname_end == std::string::npos) break;
            std::string param_name = fn_body.substr(pname_start, pname_end - pname_start);

            size_t pval_start = pname_end + 1;
            size_t pval_end = fn_body.find("</parameter>", pval_start);
            if (pval_end == std::string::npos) break;
            std::string param_val = fn_body.substr(pval_start, pval_end - pval_start);

            // Trim whitespace
            while (!param_val.empty() && (param_val.front() == '\n' || param_val.front() == ' '))
                param_val.erase(param_val.begin());
            while (!param_val.empty() && (param_val.back() == '\n' || param_val.back() == ' '))
                param_val.pop_back();

            // Try to parse as JSON, otherwise store as string
            try {
                args[param_name] = json::parse(param_val);
            } catch (...) {
                args[param_name] = param_val;
            }

            p = pval_end + 12;
        }

        calls.push_back({func_name, args});
    }

    return calls;
}

// Extract text content before any <tool_call> block
static std::string extract_text_before_tool_calls(const std::string& text) {
    size_t pos = text.find("<tool_call>");
    if (pos == std::string::npos) return text;
    std::string before = text.substr(0, pos);
    // Trim trailing whitespace
    while (!before.empty() && (before.back() == '\n' || before.back() == ' '))
        before.pop_back();
    return before;
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

    // Log request summary
    int msg_count = (int)body["messages"].size();
    bool has_tools_field = body.contains("tools") && body["tools"].is_array();
    fprintf(stderr, "[req] %d messages, stream=%s, tools=%s\n",
            msg_count,
            body.value("stream", false) ? "true" : "false",
            has_tools_field ? std::to_string(body["tools"].size()).c_str() : "none");

    // Parse messages
    std::vector<std::pair<std::string, std::string>> messages;
    for (auto& m : body["messages"]) {
        std::string role = m.value("role", "user");
        std::string content;
        // Handle content as string or array (multimodal format — extract text parts)
        if (m.contains("content")) {
            if (m["content"].is_string()) {
                content = m["content"].get<std::string>();
            } else if (m["content"].is_array()) {
                for (auto& part : m["content"]) {
                    if (part.value("type", "") == "text") {
                        if (!content.empty()) content += "\n";
                        content += part.value("text", "");
                    }
                }
            } else if (m["content"].is_null()) {
                content = "";
            }
        }
        messages.push_back({role, content});
    }

    // Parse parameters — accept all standard OpenAI fields
    int max_tokens = body.value("max_tokens", 0);
    if (max_tokens == 0) max_tokens = body.value("max_completion_tokens", 0);
    if (max_tokens <= 0) max_tokens = 512; // sensible default for small models
    float temperature = body.value("temperature", 0.6f);
    float rep_penalty = body.value("repetition_penalty", 1.2f);
    float freq_penalty = body.value("frequency_penalty", 0.1f);
    bool stream = body.value("stream", false);
    bool enable_thinking = body.value("enable_thinking", false);
    bool include_usage = false;
    if (stream && body.contains("stream_options") && body["stream_options"].is_object()) {
        include_usage = body["stream_options"].value("include_usage", false);
    }
    // Accept but note: top_p, presence_penalty, seed, logit_bias, n are parsed
    // but not all are supported by the ANE-LM sampler
    // (they won't cause errors, just won't have effect)

    // Tools support
    std::string tools_json;
    bool has_tools = false;
    if (body.contains("tools") && body["tools"].is_array() && !body["tools"].empty()) {
        tools_json = body["tools"].dump();
        has_tools = true;
    }

    // response_format: json_object mode — inject instruction into system message
    if (body.contains("response_format") && body["response_format"].is_object()) {
        std::string fmt_type = body["response_format"].value("type", "text");
        if (fmt_type == "json_object" || fmt_type == "json_schema") {
            // Append JSON instruction to first system message, or prepend one
            std::string json_instruction = "\n\nYou must respond with valid JSON only. No other text.";
            if (fmt_type == "json_schema" && body["response_format"].contains("json_schema")) {
                auto& schema = body["response_format"]["json_schema"];
                if (schema.contains("schema")) {
                    json_instruction += "\nThe response must conform to this JSON schema: " + schema["schema"].dump();
                }
            }
            bool found_system = false;
            for (auto& [role, content] : messages) {
                if (role == "system") {
                    content += json_instruction;
                    found_system = true;
                    break;
                }
            }
            if (!found_system) {
                messages.insert(messages.begin(), {"system", "You are a helpful assistant." + json_instruction});
            }
        }
    }

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
             sampling, completion_id, created, tools_json, has_tools, include_usage]
            (size_t, httplib::DataSink& sink) {
                std::lock_guard<std::mutex> lock(g_model_mutex);

                void* pool = objc_autoreleasePoolPush();
                g_model->reset();

                // For tool call detection in streaming, accumulate full text
                std::string accumulated_text;
                bool tool_call_detected = false;
                bool first_chunk = true;

                // Send initial chunk with role (OpenAI spec: first chunk carries role)
                {
                    json chunk = {
                        {"id", completion_id},
                        {"object", "chat.completion.chunk"},
                        {"created", created},
                        {"model", g_model_id},
                        {"choices", json::array({
                            {{"index", 0}, {"delta", {{"role", "assistant"}, {"content", ""}}}, {"finish_reason", nullptr}}
                        })}
                    };
                    std::string data = "data: " + chunk.dump() + "\n\n";
                    sink.write(data.c_str(), data.size());
                }

                stream_generate(*g_model, g_tokenizer, messages,
                    max_tokens, enable_thinking, sampling,
                    [&sink, &completion_id, &created, &accumulated_text,
                     &tool_call_detected, &first_chunk, has_tools, include_usage]
                    (const GenerationResponse& r) {
                        if (r.token == -1) {
                            // End of generation
                            if (has_tools && !tool_call_detected) {
                                // Check if accumulated text contains tool calls
                                auto calls = parse_tool_calls(accumulated_text);
                                if (!calls.empty()) {
                                    tool_call_detected = true;
                                    // Send tool call chunks
                                    for (size_t i = 0; i < calls.size(); i++) {
                                        json tc = {
                                            {"index", (int)i},
                                            {"id", make_tool_call_id()},
                                            {"type", "function"},
                                            {"function", {
                                                {"name", calls[i].name},
                                                {"arguments", calls[i].arguments.dump()}
                                            }}
                                        };
                                        json delta = {{"tool_calls", json::array({tc})}};
                                        json chunk = {
                                            {"id", completion_id},
                                            {"object", "chat.completion.chunk"},
                                            {"created", created},
                                            {"model", g_model_id},
                                            {"choices", json::array({
                                                {{"index", 0}, {"delta", delta}, {"finish_reason", nullptr}}
                                            })}
                                        };
                                        std::string data = "data: " + chunk.dump() + "\n\n";
                                        sink.write(data.c_str(), data.size());
                                    }
                                }
                            }

                            // Final chunk with finish_reason
                            std::string finish = tool_call_detected ? "tool_calls" : "stop";
                            json chunk = {
                                {"id", completion_id},
                                {"object", "chat.completion.chunk"},
                                {"created", created},
                                {"model", g_model_id},
                                {"choices", json::array({
                                    {{"index", 0}, {"delta", json::object()}, {"finish_reason", finish}}
                                })}
                            };
                            std::string data = "data: " + chunk.dump() + "\n\n";
                            sink.write(data.c_str(), data.size());

                            // Usage chunk (only when stream_options.include_usage is true)
                            if (include_usage) {
                                json usage_chunk = {
                                    {"id", completion_id},
                                    {"object", "chat.completion.chunk"},
                                    {"created", created},
                                    {"model", g_model_id},
                                    {"choices", json::array()},
                                    {"usage", {
                                        {"prompt_tokens", r.prompt_tokens},
                                        {"completion_tokens", r.generation_tokens},
                                        {"total_tokens", r.prompt_tokens + r.generation_tokens}
                                    }}
                                };
                                std::string udata = "data: " + usage_chunk.dump() + "\n\n";
                                sink.write(udata.c_str(), udata.size());
                            }

                            sink.write("data: [DONE]\n\n", 14);
                            return;
                        }

                        if (!r.text.empty()) {
                            accumulated_text += r.text;

                            // If tools are present, buffer output (don't stream raw tool_call XML)
                            if (has_tools && accumulated_text.find("<tool_call>") != std::string::npos) {
                                return;
                            }

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
                    },
                    tools_json);

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
            },
            tools_json);

        objc_autoreleasePoolPop(pool);

        // Check for tool calls in output
        json resp;
        if (has_tools) {
            auto calls = parse_tool_calls(full_text);
            if (!calls.empty()) {
                std::string content_before = extract_text_before_tool_calls(full_text);
                json tool_calls_arr = json::array();
                for (auto& tc : calls) {
                    tool_calls_arr.push_back({
                        {"id", make_tool_call_id()},
                        {"type", "function"},
                        {"function", {
                            {"name", tc.name},
                            {"arguments", tc.arguments.dump()}
                        }}
                    });
                }
                json msg = {{"role", "assistant"}, {"tool_calls", tool_calls_arr}};
                if (!content_before.empty()) {
                    msg["content"] = content_before;
                } else {
                    msg["content"] = nullptr;
                }
                resp = {
                    {"id", completion_id},
                    {"object", "chat.completion"},
                    {"created", created},
                    {"model", g_model_id},
                    {"choices", json::array({
                        {
                            {"index", 0},
                            {"message", msg},
                            {"finish_reason", "tool_calls"}
                        }
                    })},
                    {"usage", {
                        {"prompt_tokens", last.prompt_tokens},
                        {"completion_tokens", last.generation_tokens},
                        {"total_tokens", last.prompt_tokens + last.generation_tokens}
                    }}
                };
                res.set_content(resp.dump(), "application/json");
                return;
            }
        }

        resp = {
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
