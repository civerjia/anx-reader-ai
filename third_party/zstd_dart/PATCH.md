# zstd_dart, vendored

Copied from pub.dev `zstd_dart` 1.1.0 (MIT; bundles zstd 1.5.7 C sources under
`third_party/zstd/`, compiled by `hook/build.dart`).

Changed only `pubspec.yaml` dependency constraints:

- `hooks: ^1.0.2` -> `^2.0.0`
- `code_assets: ^1.0.0` -> `^1.2.1`
- `native_toolchain_c: ^0.17.6` -> `0.19.2` (0.17.x needs hooks ^1; 0.19.4 needs code_assets ^2,
  which llm_llamacpp does not allow)

Why: the app also depends on `third_party/llm_llamacpp`, which requires
`hooks ^2.0.0`, so the published package could not be resolved alongside it.
The build hook itself is unchanged. Used for the zstd-compressed clusters of Kiwix
ZIM files (lib/service/knowledge/zim_archive.dart).
