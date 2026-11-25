local api = rawget(_G, "imgui")
assert(type(api) == "table", "42Loader native ImGui API is unavailable")
return api
