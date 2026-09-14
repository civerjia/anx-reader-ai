#!/bin/sh
# Builds llama.cpp for the app's own native bundles, used by hook/build.dart in
# place of the 0.5.0 release prebuilts (which predate Spark-X2.5's `spark2_5`
# architecture). Run from the package root:
#
#   sh tool/build_llamacpp_apple.sh [tag]
#
# iOS gets the same static archives the release asset ships, collected into
# .native-build/ios-arm64-bundle/ where the hook links them into libllama.dylib.
# macOS gets shared libraries in .native-build/macos-arm64/bin/, for
# LLM_LLAMACPP_LIB_DIR in local end-to-end tests.
#
# After changing the tag, copy llamacpp/include/*.h and
# llamacpp/ggml/include/*.h into src/include/ and regenerate the bindings
# (ffigen refuses to run inside this workspace package; run it from a scratch
# project with ffigen.yaml's paths made absolute).
set -e
TAG="${1:-b10950}"
if [ ! -d llamacpp ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp.git llamacpp
fi
COMMON="-DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_BLAS=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_COMMON=OFF \
  -DLLAMA_BUILD_UI=OFF -DLLAMA_CURL=OFF"

cmake -S llamacpp -B .native-build/ios-arm64 -G Ninja -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DBUILD_SHARED_LIBS=OFF $COMMON
cmake --build .native-build/ios-arm64 -j"$(sysctl -n hw.ncpu)"
rm -rf .native-build/ios-arm64-bundle && mkdir -p .native-build/ios-arm64-bundle
find .native-build/ios-arm64 -name '*.a' -exec cp {} .native-build/ios-arm64-bundle/ \;

cmake -S llamacpp -B .native-build/macos-arm64 -G Ninja \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DBUILD_SHARED_LIBS=ON $COMMON
cmake --build .native-build/macos-arm64 -j"$(sysctl -n hw.ncpu)"
