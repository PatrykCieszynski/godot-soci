# Upstream provenance

This repository follows the general layout and C++ registration pattern of **godotengine/godot-cpp-template**, revision `d36f9d03e9e02dad22829f1faf4e03a347616df5` (MIT). It does not copy template source files verbatim beyond conventional GDExtension boilerplate.

Build-time dependencies fetched via CMake:

- `godotengine/godot-cpp`, revision `b8530af7546a3fcae80cef2477526569fd42ffc2`, MIT, https://github.com/godotengine/godot-cpp
- `SOCI/soci`, revision `a9e51707d565baa6e02634453d5e81b84062c94a`, Boost Software License 1.0, https://github.com/SOCI/soci/blob/master/LICENSE_1_0.txt
- SOCI's `fmt` third-party dependency is fetched by the upstream SOCI build unless a compatible system package is found. Preserve its included license.

**Avoid vendoring** upstream source in this repository without retaining notices. Pin dependency hashes and keep the license provenance in release artifacts.
