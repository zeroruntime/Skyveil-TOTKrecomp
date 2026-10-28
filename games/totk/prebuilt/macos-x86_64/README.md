# Intel Mac shader translator

`totk_xlate` prepares shaders on an Intel Mac for an ARM64 iPhone app. It is
built from `vendor/ryujinx`, the patches and service in
`games/totk/tools/totk_xlate`, and the pinned SPIRV-Cross sources.

This local build uses .NET SDK 10.0.403 and NativeAOT's `osx-x64` target.
`build_app.py` verifies the binary against `totk_xlate.sha256` before use.

Rebuild with `games/totk/tools/totk_xlate/publish_native.sh /path/to/dotnet`.
The SDK is needed when rebuilding this tool; the resulting executable runs
without a .NET installation. NativeAOT rebuilds can produce different hashes.
