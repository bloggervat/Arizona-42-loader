# Arizona 42Loader

This repository contains the iOS ARM64 Lua loader source, Lua compatibility
modules, diagnostics, and the GitHub Actions build workflow.

GitHub Actions builds `LuaLoader.dylib` and a package containing the dylib and
`LoaderLib/`. Install those side by side as `Arizona.app/Frameworks/` and
`Arizona.app/LoaderLib/` respectively.

The original Arizona app bundle is not included. To create a local IPA with
`compil.bat`, provide the extracted app under `Payload/Arizona.app`, place the
built dylib in its `Frameworks/` folder and `LoaderLib/` beside it, and install
Python with the `lief` package.

Dear ImGui and its Metal backend are compiled into the dylib so they use one
native context. The bundled Lua modules do not contain Android binaries.