cmake_minimum_required(VERSION 3.20)
project(ane-lm-server VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum macOS deployment target")
add_compile_definitions(ACCELERATE_NEW_LAPACK)

# --- Dependencies (fetched, same as ANE-LM upstream) ---
include(FetchContent)

FetchContent_Declare(
    json
    URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
)

FetchContent_Declare(
    tokenizers_cpp
    GIT_REPOSITORY https://github.com/mlc-ai/tokenizers-cpp.git
    GIT_TAG        main
    GIT_SHALLOW    TRUE
)

# cpp-httplib — disable SSL to avoid Homebrew dylib deps (brotli, openssl)
# The server only listens on localhost, HTTPS is not needed.
set(HTTPLIB_USE_OPENSSL_IF_AVAILABLE OFF CACHE BOOL "" FORCE)
set(HTTPLIB_USE_BROTLI_IF_AVAILABLE OFF CACHE BOOL "" FORCE)
set(HTTPLIB_USE_ZLIB_IF_AVAILABLE OFF CACHE BOOL "" FORCE)

FetchContent_Declare(
    httplib
    GIT_REPOSITORY https://github.com/yhirose/cpp-httplib.git
    GIT_TAG        v0.18.7
    GIT_SHALLOW    TRUE
)

FetchContent_MakeAvailable(json tokenizers_cpp httplib)

# --- ANE-LM sources (from submodule, no add_subdirectory) ---
set(ANE_LM_DIR ${CMAKE_SOURCE_DIR}/vendor/ANE-LM)

set(VENDOR_SOURCES
    ${ANE_LM_DIR}/vendor/jinja/value.cpp
    ${ANE_LM_DIR}/vendor/jinja/string.cpp
    ${ANE_LM_DIR}/vendor/jinja/lexer.cpp
    ${ANE_LM_DIR}/vendor/jinja/parser.cpp
    ${ANE_LM_DIR}/vendor/jinja/runtime.cpp
    ${ANE_LM_DIR}/vendor/jinja/caps.cpp
)

set(CORE_SOURCES
    ${ANE_LM_DIR}/common.cpp
    ${ANE_LM_DIR}/core/safetensors.cpp
    ${ANE_LM_DIR}/core/tokenizer.cpp
    ${ANE_LM_DIR}/core/cpu_ops.cpp
    ${ANE_LM_DIR}/core/sampling.cpp
    ${ANE_LM_DIR}/core/ane_runtime.cpp
    ${ANE_LM_DIR}/utils.cpp
    ${ANE_LM_DIR}/generate.cpp
)

set(MODEL_SOURCES
    ${ANE_LM_DIR}/models/llm/qwen3_5.cpp
)

# --- Server executable ---
add_executable(ane-lm-server
    ${VENDOR_SOURCES}
    ${CORE_SOURCES}
    ${MODEL_SOURCES}
    src/server.cpp
)

target_include_directories(ane-lm-server PRIVATE
    ${ANE_LM_DIR}/include
    ${ANE_LM_DIR}
)

target_link_libraries(ane-lm-server PRIVATE
    nlohmann_json::nlohmann_json
    tokenizers_cpp
    httplib::httplib
    "-framework Foundation"
    "-framework IOSurface"
    "-framework Accelerate"
    "-lobjc"
)

target_compile_options(ane-lm-server PRIVATE
    $<$<CONFIG:Release>:-O3>
    $<$<CONFIG:RelWithDebInfo>:-O2 -g>
)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()
