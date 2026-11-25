# LoaderLib

This folder is bundled inside Arizona.app beside Frameworks. Lua searches it
before the user's Documents/lua_loader/lib folder, so built-in modules remain
available even when the app is installed from a newly packed IPA.

## Included modules

- imgui.lua exposes the loader's existing native Dear ImGui table.
- mimgui/init.lua adapts the supported ImGui calls to the familiar mimgui
  frame subscription shape. Its before-frame callback runs in the loader's
  ImGui frame because the existing Metal hook owns frame creation.
- inicfg.lua stores INI files under Documents/lua_loader/config.
- json.lua and cjson.lua provide the loader's pure Lua JSON implementation.
- encoding.lua wraps the loader's CP1251 conversion functions.
- monetloader.lua provides MonetLoader's touch event numeric constants only.
- ImGui text entry is not exposed: the current overlay has no iOS keyboard bridge.

Dear ImGui and its Metal backend remain compiled into LuaLoader.dylib. They
share one native context and render loop; copying a separate Android or
standalone ImGui binary into this folder would not connect it to that context.

Android game bridges, FFI, arbitrary process memory, D3D rendering, and live
Arizona chat/event hooks are not included. No game chat bridge is bundled.
