#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <sys/mman.h>
#import <pthread.h>

#include <string>
#include <vector>
#include <unordered_map>
#include <mutex>
#include <atomic>
#include <cmath>
#include <algorithm>
#include <cstring>

#include "lua.hpp"
#include "imgui.h"
#include "imgui_internal.h"
#include "imgui_impl_metal.h"

// ============================================================================
// 1. Встроенный 64-bit Mach-O fishhook для перехвата C/C++ символов в iOS
// ============================================================================
namespace Fishhook {

struct Rebinding {
    const char *name;
    void *replacement;
    void **replaced;
};

struct RebindingEntry {
    Rebinding *rebindings;
    size_t count;
    RebindingEntry *next;
};

static RebindingEntry *g_rebindings_head = nullptr;

static void perform_rebinding_with_section(RebindingEntry *rebindings,
                                           struct section_64 *section,
                                           intptr_t slide,
                                           struct nlist_64 *symtab,
                                           char *strtab,
                                           uint32_t *indirect_symtab) {
    uint32_t *indirect_symbol_indices = indirect_symtab + section->reserved1;
    void **indirect_symbol_bindings = (void **)((uintptr_t)slide + section->addr);

    for (uint i = 0; i < section->size / sizeof(void *); i++) {
        uint32_t symtab_index = indirect_symbol_indices[i];
        if (symtab_index == INDIRECT_SYMBOL_ABS || symtab_index == INDIRECT_SYMBOL_LOCAL ||
            symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
            continue;
        }
        uint32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
        char *symbol_name = strtab + strtab_offset;
        if (strnlen(symbol_name, 2) < 2) continue;

        for (RebindingEntry *cur = rebindings; cur != nullptr; cur = cur->next) {
            for (size_t j = 0; j < cur->count; j++) {
                if (strcmp(&symbol_name[1], cur->rebindings[j].name) == 0) {
                    if (cur->rebindings[j].replaced != nullptr &&
                        indirect_symbol_bindings[i] != cur->rebindings[j].replacement) {
                        *(cur->rebindings[j].replaced) = indirect_symbol_bindings[i];
                    }
                    vm_protect(mach_task_self(), (uintptr_t)indirect_symbol_bindings, section->size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                    indirect_symbol_bindings[i] = cur->rebindings[j].replacement;
                    break;
                }
            }
        }
    }
}

static void rebind_symbols_for_image(RebindingEntry *rebindings, const struct mach_header *header, intptr_t slide) {
    Dl_info info;
    if (dladdr(header, &info) == 0) return;

    struct segment_command_64 *cur_seg_cmd = nullptr;
    struct segment_command_64 *linkedit_segment = nullptr;
    struct symtab_command *symtab_cmd = nullptr;
    struct dysymtab_command *dysymtab_cmd = nullptr;

    uintptr_t cur = (uintptr_t)header + sizeof(struct mach_header_64);
    for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
        cur_seg_cmd = (struct segment_command_64 *)cur;
        if (cur_seg_cmd->cmd == LC_SEGMENT_64) {
            if (strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0) {
                linkedit_segment = cur_seg_cmd;
            }
        } else if (cur_seg_cmd->cmd == LC_SYMTAB) {
            symtab_cmd = (struct symtab_command *)cur_seg_cmd;
        } else if (cur_seg_cmd->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (struct dysymtab_command *)cur_seg_cmd;
        }
    }

    if (!symtab_cmd || !dysymtab_cmd || !linkedit_segment || !dysymtab_cmd->nindirectsyms) return;

    uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
    struct nlist_64 *symtab = (struct nlist_64 *)(linkedit_base + symtab_cmd->symoff);
    char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
    uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

    cur = (uintptr_t)header + sizeof(struct mach_header_64);
    for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
        cur_seg_cmd = (struct segment_command_64 *)cur;
        if (cur_seg_cmd->cmd == LC_SEGMENT_64) {
            if (strcmp(cur_seg_cmd->segname, SEG_DATA) != 0 &&
                strcmp(cur_seg_cmd->segname, "__DATA_CONST") != 0) {
                continue;
            }
            for (uint j = 0; j < cur_seg_cmd->nsects; j++) {
                struct section_64 *sect = (struct section_64 *)(cur + sizeof(struct segment_command_64)) + j;
                uint32_t flags = sect->flags & SECTION_TYPE;
                if (flags == S_LAZY_SYMBOL_POINTERS || flags == S_NON_LAZY_SYMBOL_POINTERS) {
                    perform_rebinding_with_section(rebindings, sect, slide, symtab, strtab, indirect_symtab);
                }
            }
        }
    }
}

static void _rebind_image_callback(const struct mach_header *header, intptr_t slide) {
    rebind_symbols_for_image(g_rebindings_head, header, slide);
}

static int rebind_symbols(Rebinding rebindings[], size_t count) {
    auto *entry = (RebindingEntry *)malloc(sizeof(RebindingEntry));
    if (!entry) return -1;
    entry->rebindings = (Rebinding *)malloc(sizeof(Rebinding) * count);
    if (!entry->rebindings) {
        free(entry);
        return -1;
    }
    memcpy(entry->rebindings, rebindings, sizeof(Rebinding) * count);
    entry->count = count;
    entry->next = g_rebindings_head;

    bool first = (g_rebindings_head == nullptr);
    g_rebindings_head = entry;

    if (first) {
        _dyld_register_func_for_add_image(_rebind_image_callback);
    } else {
        uint32_t c = _dyld_image_count();
        for (uint32_t i = 0; i < c; i++) {
            _rebind_image_callback(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
        }
    }
    return 0;
}

} // namespace Fishhook

// ============================================================================
// 2. Вспомогательные структуры данных, RAM-монитор, Трейсеры и Очереди рендера
// ============================================================================
static std::recursive_mutex g_luaMutex;
static std::mutex g_logMutex;
static std::mutex g_renderMutex;

struct ScriptEntry {
    std::string filename;
    std::string fullPath;
    bool enabled = true;
    bool loaded = false;
    std::string lastError;
};

struct LuaThreadTask {
    int threadRef = LUA_NOREF;
    lua_State *co = nullptr;
    double wakeTime = 0.0;
    bool finished = false;
};

struct TracerItem {
    std::string id;
    bool is3D = true;
    float x1 = 0.0f, y1 = 0.0f, z1 = 0.0f;
    float x2 = 0.0f, y2 = 0.0f;
    uint32_t color = 0xFF9B59B6; // ARGB
    float thickness = 1.6f;
    std::string label;
};

enum class DrawCmdType {
    Line,
    Box,
    BoxFilled,
    Circle,
    CircleFilled,
    Text
};

struct DrawCmd {
    DrawCmdType type;
    float x1 = 0, y1 = 0, x2 = 0, y2 = 0;
    float radius = 0;
    int segments = 24;
    uint32_t color = 0xFFFFFFFF;
    std::string text;
};

struct CameraState {
    float camX = 0.0f, camY = 0.0f, camZ = 10.0f;
    float lookX = 0.0f, lookY = 10.0f, lookZ = 10.0f;
    float fovDeg = 70.0f;
    bool valid = false;
};

static std::vector<std::string> g_consoleLogs;
static std::vector<DrawCmd> g_luaDrawQueue;
static std::unordered_map<std::string, TracerItem> g_tracers;
static CameraState g_camera;

// Настройки встроенного ImGui интерфейса и HUD
static bool g_showImGuiMenu = false;
static bool g_showFloatingBtn = true;
static bool g_showRamHud = true;
static bool g_renderEnabled = true;
static bool g_drawCrosshair = false;
static bool g_drawDemoTracers = false;
static bool g_tracerFromCenter = false; // false = снизу по центру, true = из центра экрана
static float g_tracerThickness = 1.6f;
static float g_tracerColor[4] = { 0.65f, 0.35f, 0.98f, 0.90f };
static float g_crosshairSize = 8.0f;
static float g_crosshairColor[4] = { 0.30f, 0.95f, 0.55f, 0.90f };

// Статистика памяти именно лоадера
struct LoaderRamStats {
    size_t dylibImageBytes = 0;
    size_t luaHeapBytes = 0;
    size_t buffersBytes = 0;
    size_t totalBytes = 0;
};
static LoaderRamStats g_ramStats;
static CFTimeInterval g_lastRamUpdate = 0;

static void AppendConsoleLog(const std::string &line) {
    std::lock_guard<std::mutex> lock(g_logMutex);
    g_consoleLogs.push_back(line);
    if (g_consoleLogs.size() > 300) {
        g_consoleLogs.erase(g_consoleLogs.begin(), g_consoleLogs.begin() + 50);
    }
    NSLog(@"[42Loader] %s", line.c_str());
}

static NSString *SafeNSString(const char *str) {
    if (!str) return @"";
    NSString *s = [NSString stringWithUTF8String:str];
    if (s) return s;
    s = [[NSString alloc] initWithCString:str encoding:NSWindowsCP1251StringEncoding];
    if (s) return s;
    return [[NSString alloc] initWithCString:str encoding:NSISOLatin1StringEncoding] ?: @"";
}

static UIWindow *GetActiveKeyWindow() {
    UIWindow *found = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *win in ws.windows) {
            if (win.isKeyWindow) return win;
            if (!found && win.windowLevel == UIWindowLevelNormal && !win.hidden) {
                found = win;
            }
        }
    }
    return found;
}

static ImU32 ARGBToImU32(uint32_t argb) {
    uint8_t a = (argb >> 24) & 0xFF;
    uint8_t r = (argb >> 16) & 0xFF;
    uint8_t g = (argb >> 8) & 0xFF;
    uint8_t b = argb & 0xFF;
    if (a == 0) a = 0xFF;
    return IM_COL32(r, g, b, a);
}

static ImU32 Float4ToImU32(const float c[4]) {
    return IM_COL32((uint8_t)(c[0] * 255.0f),
                    (uint8_t)(c[1] * 255.0f),
                    (uint8_t)(c[2] * 255.0f),
                    (uint8_t)(c[3] * 255.0f));
}

// Подсчет размера сегментов самого LuaLoader.dylib в памяти процесса
static size_t ComputeLoaderMachOBytes() {
    static size_t cachedSize = 0;
    if (cachedSize > 0) return cachedSize;

    Dl_info info;
    if (dladdr((void *)&ComputeLoaderMachOBytes, &info) == 0 || !info.dli_fbase) {
        return 0;
    }
    const auto *header = (const struct mach_header_64 *)info.dli_fbase;
    uintptr_t cur = (uintptr_t)header + sizeof(struct mach_header_64);
    size_t total = 0;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const auto *cmd = (const struct load_command *)cur;
        if (cmd->cmd == LC_SEGMENT_64) {
            const auto *seg = (const struct segment_command_64 *)cur;
            if (strcmp(seg->segname, SEG_PAGEZERO) != 0) {
                total += (size_t)seg->vmsize;
            }
        }
        cur += cmd->cmdsize;
    }
    cachedSize = total;
    return cachedSize;
}

static void UpdateLoaderRamStats(lua_State *L) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - g_lastRamUpdate < 0.5 && g_ramStats.totalBytes > 0) return;
    g_lastRamUpdate = now;

    size_t luaBytes = 0;
    if (L) {
        std::lock_guard<std::recursive_mutex> lock(g_luaMutex);
        int kb = lua_gc(L, LUA_GCCOUNT, 0);
        int rem = lua_gc(L, LUA_GCCOUNTB, 0);
        luaBytes = (size_t)kb * 1024 + (size_t)rem;
    }

    size_t dylibBytes = ComputeLoaderMachOBytes();

    size_t bufBytes = 0;
    {
        std::lock_guard<std::mutex> lock(g_logMutex);
        for (const auto &s : g_consoleLogs) bufBytes += s.capacity() + sizeof(std::string);
    }
    {
        std::lock_guard<std::mutex> lock(g_renderMutex);
        bufBytes += g_luaDrawQueue.capacity() * sizeof(DrawCmd);
        bufBytes += g_tracers.size() * (sizeof(TracerItem) + 48);
    }
    if (ImGui::GetCurrentContext()) {
        ImGuiIO &io = ImGui::GetIO();
        // Атлас шрифтов ImGui (RGBA32) + вершинные буферы
        if (io.Fonts && io.Fonts->TexWidth > 0 && io.Fonts->TexHeight > 0) {
            bufBytes += (size_t)io.Fonts->TexWidth * (size_t)io.Fonts->TexHeight * 4;
        }
        bufBytes += (size_t)io.MetricsRenderVertices * sizeof(ImDrawVert);
        bufBytes += (size_t)io.MetricsRenderIndices * sizeof(ImDrawIdx);
    }

    g_ramStats.dylibImageBytes = dylibBytes;
    g_ramStats.luaHeapBytes = luaBytes;
    g_ramStats.buffersBytes = bufBytes;
    g_ramStats.totalBytes = dylibBytes + luaBytes + bufBytes;
}

// Проекция 3D мировых координат в 2D координаты экрана
static bool ProjectWorldToScreen(float wx, float wy, float wz, float screenW, float screenH, float &outX, float &outY) {
    if (!g_camera.valid) {
        // Fallback проекция относительно центра мира, если камера не задана скриптом
        float dx = wx - g_camera.camX;
        float dy = wy - g_camera.camY;
        float dz = wz - g_camera.camZ;
        if (dy <= 0.5f) return false;
        float aspect = (screenH > 0) ? (screenW / screenH) : 1.77f;
        float fovRad = g_camera.fovDeg * (float)M_PI / 180.0f;
        float f = 1.0f / tanf(fovRad * 0.5f);
        float ndcX = (dx * f / aspect) / dy;
        float ndcY = (dz * f) / dy;
        outX = (ndcX + 1.0f) * 0.5f * screenW;
        outY = (1.0f - ndcY) * 0.5f * screenH;
        return (outX >= -200.0f && outX <= screenW + 200.0f && outY >= -200.0f && outY <= screenH + 200.0f);
    }

    // Вектор взгляда forward = normalize(look - cam)
    float fx = g_camera.lookX - g_camera.camX;
    float fy = g_camera.lookY - g_camera.camY;
    float fz = g_camera.lookZ - g_camera.camZ;
    float flen = sqrtf(fx * fx + fy * fy + fz * fz);
    if (flen < 1e-4f) return false;
    fx /= flen; fy /= flen; fz /= flen;

    // right = normalize(forward x up(0,0,1))
    float rx = fy * 1.0f - fz * 0.0f;
    float ry = fz * 0.0f - fx * 1.0f;
    float rz = fx * 0.0f - fy * 0.0f;
    float rlen = sqrtf(rx * rx + ry * ry + rz * rz);
    if (rlen < 1e-4f) { rx = 1.0f; ry = 0.0f; rz = 0.0f; }
    else { rx /= rlen; ry /= rlen; rz /= rlen; }

    // up = right x forward
    float ux = ry * fz - rz * fy;
    float uy = rz * fx - rx * fz;
    float uz = rx * fy - ry * fx;

    float dx = wx - g_camera.camX;
    float dy = wy - g_camera.camY;
    float dz = wz - g_camera.camZ;

    float camSpaceZ = dx * fx + dy * fy + dz * fz;
    if (camSpaceZ <= 0.1f) return false;

    float camSpaceX = dx * rx + dy * ry + dz * rz;
    float camSpaceY = dx * ux + dy * uy + dz * uz;

    float aspect = (screenH > 0) ? (screenW / screenH) : 1.77f;
    float fovRad = g_camera.fovDeg * (float)M_PI / 180.0f;
    float tanHalfFov = tanf(fovRad * 0.5f);

    float ndcX = camSpaceX / (camSpaceZ * tanHalfFov * aspect);
    float ndcY = camSpaceY / (camSpaceZ * tanHalfFov);

    outX = (ndcX + 1.0f) * 0.5f * screenW;
    outY = (1.0f - ndcY) * 0.5f * screenH;
    return true;
}

// ============================================================================
// 3. Объявление главного класса движка лоадера
// ============================================================================
@interface LoaderEngine : NSObject <UNUserNotificationCenterDelegate>
@property (nonatomic, assign) lua_State *L;
@property (nonatomic, assign) BOOL inGameSession;
@property (nonatomic, strong) NSString *baseDir;
@property (nonatomic, strong) NSString *scriptsDir;
@property (nonatomic, strong) NSString *configDir;
@property (nonatomic, strong) NSString *libDir;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *commandRefs;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *frameCallbackRefs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *disabledScripts;
@property (nonatomic, assign) int currentDialogId;
@property (nonatomic, assign) BOOL dialogActive;
@property (nonatomic, strong) NSString *chatInputText;
@property (nonatomic, assign) BOOL chatInputActive;

+ (instancetype)shared;
- (void)boot;
- (void)reloadAllScripts;
- (BOOL)loadSingleScript:(NSString *)filename;
- (void)setScript:(NSString *)filename enabled:(BOOL)enabled;
- (std::vector<ScriptEntry>)allScriptsStatus;
- (void)tickUpdate;
- (void)tickRender;
- (BOOL)dispatchServerMessage:(uint32_t)color text:(NSString *)text outColor:(uint32_t *)outColor outText:(NSString **)outText;
- (BOOL)dispatchShowDialog:(int)dialogId style:(int)style title:(NSString *)title btn1:(NSString *)btn1 btn2:(NSString *)btn2 text:(NSString *)text;
- (BOOL)dispatchOutgoingText:(NSString *)text;
- (void)sendChatToGame:(NSString *)text;
- (void)addChatMessageLocal:(NSString *)text color:(uint32_t)color;
- (void)executeLuaString:(NSString *)code;
@end

static std::vector<LuaThreadTask> g_luaThreads;

// ============================================================================
// 4. Хуки игры (fishhook + dlsym + UIKit swizzling)
// ============================================================================
typedef void (*AddChatMessage_t)(uint32_t color, const char *text);
typedef void (*ShowDialog_t)(int dialogId, int style, const char *title, const char *btn1, const char *btn2, const char *text);
typedef void (*SendChatMessage_t)(void *env, void *thiz, void *jstr);

static AddChatMessage_t orig_AddChatMessage = nullptr;
static ShowDialog_t orig_ShowDialog = nullptr;

static void hooked_AddChatMessage(uint32_t color, const char *text) {
    NSString *nsText = SafeNSString(text);
    uint32_t outColor = color;
    NSString *outText = nil;

    BOOL allow = [[LoaderEngine shared] dispatchServerMessage:color text:nsText outColor:&outColor outText:&outText];
    if (!allow) return;

    if (orig_AddChatMessage) {
        const char *finalCStr = outText ? [outText UTF8String] : text;
        orig_AddChatMessage(outColor, finalCStr);
    }
}

static void hooked_ShowDialog(int dialogId, int style, const char *title, const char *btn1, const char *btn2, const char *text) {
    [LoaderEngine shared].currentDialogId = dialogId;
    [LoaderEngine shared].dialogActive = YES;

    BOOL allow = [[LoaderEngine shared] dispatchShowDialog:dialogId
                                                     style:style
                                                     title:SafeNSString(title)
                                                      btn1:SafeNSString(btn1)
                                                      btn2:SafeNSString(btn2)
                                                      text:SafeNSString(text)];
    if (!allow) {
        [LoaderEngine shared].dialogActive = NO;
        return;
    }
    if (orig_ShowDialog) {
        orig_ShowDialog(dialogId, style, title, btn1, btn2, text);
    }
}

// ============================================================================
// 5. Lua C-API функции (MoonLoader / Arizona / ImGui / Render / Tracers)
// ============================================================================

// --- print(...) -> в консоль ImGui и NSLog ---
static int l_print(lua_State *L) {
    int n = lua_gettop(L);
    std::string out;
    for (int i = 1; i <= n; i++) {
        size_t len = 0;
        const char *s = luaL_tolstring(L, i, &len);
        if (i > 1) out += "\t";
        if (s) out += std::string(s, len);
        lua_pop(L, 1);
    }
    AppendConsoleLog(out);
    return 0;
}

// --- Корутины: wait(ms) и lua_thread.create(fn, ...) ---
static int l_wait(lua_State *L) {
    double ms = luaL_checknumber(L, 1);
    if (!lua_isyieldable(L)) {
        return luaL_error(L, "wait() can only be called inside lua_thread.create()");
    }
    double wake = CACurrentMediaTime() + (ms / 1000.0);
    for (auto &t : g_luaThreads) {
        if (t.co == L) {
            t.wakeTime = wake;
            break;
        }
    }
    return lua_yield(L, 0);
}

static int l_lua_thread_create(lua_State *L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    int nargs = lua_gettop(L) - 1;

    lua_State *co = lua_newthread(L);
    int threadRef = luaL_ref(L, LUA_REGISTRYINDEX);

    lua_pushvalue(L, 1);
    for (int i = 0; i < nargs; i++) {
        lua_pushvalue(L, 2 + i);
    }
    lua_xmove(L, co, 1 + nargs);

    LuaThreadTask task;
    task.threadRef = threadRef;
    task.co = co;
    task.wakeTime = 0.0;
    task.finished = false;

    int nres = 0;
    int status = lua_resume(co, L, nargs, &nres);
    if (status == LUA_OK) {
        task.finished = true;
        luaL_unref(L, LUA_REGISTRYINDEX, threadRef);
    } else if (status == LUA_YIELD) {
        if (nres > 0) lua_pop(co, nres);
        g_luaThreads.push_back(task);
    } else {
        const char *err = lua_tostring(co, -1);
        AppendConsoleLog(std::string("[lua_thread error] ") + (err ? err : "unknown"));
        luaL_unref(L, LUA_REGISTRYINDEX, threadRef);
    }
    return 0;
}

// --- SA-MP / Arizona функции ---
static int l_sampAddChatMessage(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    uint32_t color = (uint32_t)luaL_optinteger(L, 2, 0xFFFFFFFF);
    [[LoaderEngine shared] addChatMessageLocal:SafeNSString(text) color:color];
    return 0;
}

static int l_sampSendChat(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    [[LoaderEngine shared] sendChatToGame:SafeNSString(text)];
    return 0;
}

static int l_sampRegisterChatCommand(lua_State *L) {
    const char *cmd = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    NSString *key = [SafeNSString(cmd) lowercaseString];
    if ([key hasPrefix:@"/"]) key = [key substringFromIndex:1];

    LoaderEngine *eng = [LoaderEngine shared];
    NSNumber *oldRef = eng.commandRefs[key];
    if (oldRef) {
        luaL_unref(L, LUA_REGISTRYINDEX, [oldRef intValue]);
    }
    lua_pushvalue(L, 2);
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);
    eng.commandRefs[key] = @(ref);
    lua_pushboolean(L, 1);
    return 1;
}

static int l_sampUnregisterChatCommand(lua_State *L) {
    const char *cmd = luaL_checkstring(L, 1);
    NSString *key = [SafeNSString(cmd) lowercaseString];
    if ([key hasPrefix:@"/"]) key = [key substringFromIndex:1];

    LoaderEngine *eng = [LoaderEngine shared];
    NSNumber *oldRef = eng.commandRefs[key];
    if (oldRef) {
        luaL_unref(L, LUA_REGISTRYINDEX, [oldRef intValue]);
        [eng.commandRefs removeObjectForKey:key];
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

static int l_sampShowDialog(lua_State *L) {
    int dialogId = (int)luaL_checkinteger(L, 1);
    const char *caption = luaL_checkstring(L, 2);
    const char *text = luaL_checkstring(L, 3);
    const char *btn1 = luaL_checkstring(L, 4);
    const char *btn2 = luaL_optstring(L, 5, "");
    int style = (int)luaL_optinteger(L, 6, 0);

    [LoaderEngine shared].currentDialogId = dialogId;
    [LoaderEngine shared].dialogActive = YES;

    if (orig_ShowDialog) {
        orig_ShowDialog(dialogId, style, caption, btn1, btn2, text);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *win = GetActiveKeyWindow();
            UIViewController *vc = win.rootViewController;
            while (vc.presentedViewController) vc = vc.presentedViewController;
            if (!vc) return;

            UIAlertController *ac = [UIAlertController alertControllerWithTitle:SafeNSString(caption)
                                                                        message:SafeNSString(text)
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:SafeNSString(btn1) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                [LoaderEngine shared].dialogActive = NO;
            }]];
            if (strlen(btn2) > 0) {
                [ac addAction:[UIAlertAction actionWithTitle:SafeNSString(btn2) style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
                    [LoaderEngine shared].dialogActive = NO;
                }]];
            }
            [vc presentViewController:ac animated:YES completion:nil];
        });
    }
    return 0;
}

static int l_sampGetCurrentDialogId(lua_State *L) {
    lua_pushinteger(L, [LoaderEngine shared].currentDialogId);
    return 1;
}

static int l_sampIsDialogActive(lua_State *L) {
    lua_pushboolean(L, [LoaderEngine shared].dialogActive ? 1 : 0);
    return 1;
}

static int l_sampIsChatInputActive(lua_State *L) {
    lua_pushboolean(L, [LoaderEngine shared].chatInputActive ? 1 : 0);
    return 1;
}

static int l_sampGetChatInputText(lua_State *L) {
    NSString *t = [LoaderEngine shared].chatInputText ?: @"";
    lua_pushstring(L, [t UTF8String]);
    return 1;
}

static int l_isSampAvailable(lua_State *L) {
    lua_pushboolean(L, 1);
    return 1;
}

static int l_sampGetGamestate(lua_State *L) {
    lua_pushinteger(L, [LoaderEngine shared].inGameSession ? 3 : 1);
    return 1;
}

// --- az.* Native iOS & Tracers API ---
static int l_az_notify(lua_State *L) {
    NSString *title = SafeNSString(luaL_checkstring(L, 1));
    NSString *body = SafeNSString(luaL_checkstring(L, 2));
    double delay = luaL_optnumber(L, 3, 0.1);
    if (delay < 0.05) delay = 0.05;

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = body;
    content.sound = [UNNotificationSound defaultSound];

    UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:delay repeats:NO];
    NSString *ident = [[NSUUID UUID] UUIDString];
    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:ident content:content trigger:trigger];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:req withCompletionHandler:nil];
    return 0;
}

static int l_az_vibrate(lua_State *L) {
    const char *styleStr = luaL_optstring(L, 1, "medium");
    std::string st(styleStr);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (st == "success" || st == "warning" || st == "error") {
            UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
            [gen prepare];
            UINotificationFeedbackType t = UINotificationFeedbackTypeSuccess;
            if (st == "warning") t = UINotificationFeedbackTypeWarning;
            else if (st == "error") t = UINotificationFeedbackTypeError;
            [gen notificationOccurred:t];
        } else {
            UIImpactFeedbackStyle style = UIImpactFeedbackStyleMedium;
            if (st == "light") style = UIImpactFeedbackStyleLight;
            else if (st == "heavy") style = UIImpactFeedbackStyleHeavy;
            UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
            [gen prepare];
            [gen impactOccurred];
        }
    });
    return 0;
}

static int l_az_setClipboard(lua_State *L) {
    NSString *s = SafeNSString(luaL_checkstring(L, 1));
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIPasteboard generalPasteboard].string = s;
    });
    return 0;
}

static int l_az_getClipboard(lua_State *L) {
    __block NSString *res = @"";
    if ([NSThread isMainThread]) {
        res = [UIPasteboard generalPasteboard].string ?: @"";
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            res = [UIPasteboard generalPasteboard].string ?: @"";
        });
    }
    lua_pushstring(L, [res UTF8String]);
    return 1;
}

static int l_az_openURL(lua_State *L) {
    NSString *urlStr = SafeNSString(luaL_checkstring(L, 1));
    NSURL *url = [NSURL URLWithString:urlStr];
    if (url) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        });
    }
    return 0;
}

static int l_az_getLoaderRAM(lua_State *L) {
    UpdateLoaderRamStats(L);
    lua_pushnumber(L, (double)g_ramStats.totalBytes / (1024.0 * 1024.0));
    lua_pushinteger(L, (lua_Integer)g_ramStats.totalBytes);
    lua_pushinteger(L, (lua_Integer)g_ramStats.luaHeapBytes);
    return 3;
}

static int l_az_setCamera(lua_State *L) {
    g_camera.camX = (float)luaL_checknumber(L, 1);
    g_camera.camY = (float)luaL_checknumber(L, 2);
    g_camera.camZ = (float)luaL_checknumber(L, 3);
    g_camera.lookX = (float)luaL_checknumber(L, 4);
    g_camera.lookY = (float)luaL_checknumber(L, 5);
    g_camera.lookZ = (float)luaL_checknumber(L, 6);
    g_camera.fovDeg = (float)luaL_optnumber(L, 7, 70.0);
    g_camera.valid = true;
    return 0;
}

// az.addTracer(id, x, y, z, color, label)
static int l_az_addTracer(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    TracerItem item;
    item.id = id;
    item.is3D = true;
    item.x1 = (float)luaL_checknumber(L, 2);
    item.y1 = (float)luaL_checknumber(L, 3);
    item.z1 = (float)luaL_checknumber(L, 4);
    item.color = (uint32_t)luaL_optinteger(L, 5, 0xFF9B59B6);
    item.label = luaL_optstring(L, 6, "");
    item.thickness = (float)luaL_optnumber(L, 7, 1.6);

    std::lock_guard<std::mutex> lock(g_renderMutex);
    g_tracers[item.id] = item;
    return 0;
}

// az.addScreenTracer(id, x1, y1, x2, y2, color, thickness, label)
static int l_az_addScreenTracer(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    TracerItem item;
    item.id = id;
    item.is3D = false;
    item.x1 = (float)luaL_checknumber(L, 2);
    item.y1 = (float)luaL_checknumber(L, 3);
    item.x2 = (float)luaL_checknumber(L, 4);
    item.y2 = (float)luaL_checknumber(L, 5);
    item.color = (uint32_t)luaL_optinteger(L, 6, 0xFF9B59B6);
    item.thickness = (float)luaL_optnumber(L, 7, 1.6);
    item.label = luaL_optstring(L, 8, "");

    std::lock_guard<std::mutex> lock(g_renderMutex);
    g_tracers[item.id] = item;
    return 0;
}

static int l_az_removeTracer(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    std::lock_guard<std::mutex> lock(g_renderMutex);
    g_tracers.erase(id);
    return 0;
}

static int l_az_clearTracers(lua_State *L) {
    std::lock_guard<std::mutex> lock(g_renderMutex);
    g_tracers.clear();
    return 0;
}

// --- 2D Render API (MoonLoader-совместимый) ---
static int l_getScreenResolution(lua_State *L) {
    CGSize sz = [UIScreen mainScreen].bounds.size;
    lua_pushnumber(L, sz.width);
    lua_pushnumber(L, sz.height);
    return 2;
}

static int l_convert3DCoordsToScreen(lua_State *L) {
    float wx = (float)luaL_checknumber(L, 1);
    float wy = (float)luaL_checknumber(L, 2);
    float wz = (float)luaL_checknumber(L, 3);
    CGSize sz = [UIScreen mainScreen].bounds.size;
    float sx = 0, sy = 0;
    bool vis = ProjectWorldToScreen(wx, wy, wz, (float)sz.width, (float)sz.height, sx, sy);
    lua_pushboolean(L, vis ? 1 : 0);
    lua_pushnumber(L, sx);
    lua_pushnumber(L, sy);
    return 3;
}

static int l_renderDrawLine(lua_State *L) {
    DrawCmd c;
    c.type = DrawCmdType::Line;
    c.x1 = (float)luaL_checknumber(L, 1);
    c.y1 = (float)luaL_checknumber(L, 2);
    c.x2 = (float)luaL_checknumber(L, 3);
    c.y2 = (float)luaL_checknumber(L, 4);
    c.radius = (float)luaL_optnumber(L, 5, 1.0); // width
    c.color = (uint32_t)luaL_optinteger(L, 6, 0xFFFFFFFF);
    std::lock_guard<std::mutex> lock(g_renderMutex);
    g_luaDrawQueue.push_back(c);
    return 0;
}

static int l_renderDrawBox(lua_State *L) {
    DrawCmd c;
    c.type = DrawCmdType::BoxFilled;
    c.x1 = (float)luaL_checknumber(L, 1);
    c.y1 = (float)luaL_checknumber(L, 2);
    c.x2 = (float)luaL_checknumber(L, 3); // w
    c.y2 = (float)luaL_checknumber(L, 4); // h
    c.color = (uint32_t)luaL_optinteger(L, 5, 0x80000000);
    std::lock_guard<std::mutex> lock(g_renderMutex);
    g_luaDrawQueue.push_back(c);
    return 0;
}

static int l_renderDrawCircle(lua_State *L) {
    DrawCmd c;
    c.type = DrawCmdType::Circle;
    c.x1 = (float)luaL_checknumber(L, 1);
    c.y1 = (float)luaL_checknumber(L, 2);
    c.radius = (float)luaL_checknumber(L, 3);
    c.segments = (int)luaL_optinteger(L, 4, 24);
    c.color = (uint32_t)luaL_optinteger(L, 5, 0xFFFFFFFF);
    std::lock_guard<std::mutex> lock(g_renderMutex);
    g_luaDrawQueue.push_back(c);
    return 0;
}

static int l_renderDrawText(lua_State *L) {
    DrawCmd c;
    c.type = DrawCmdType::Text;
    c.text = luaL_checkstring(L, 1);
    c.x1 = (float)luaL_checknumber(L, 2);
    c.y1 = (float)luaL_checknumber(L, 3);
    c.color = (uint32_t)luaL_optinteger(L, 4, 0xFFFFFFFF);
    c.radius = (float)luaL_optnumber(L, 5, 13.0);
    std::lock_guard<std::mutex> lock(g_renderMutex);
    g_luaDrawQueue.push_back(c);
    return 0;
}

// --- Async HTTP Request (NSURLSession) ---
static int l_asyncHttpRequest(lua_State *L) {
    NSString *method = [SafeNSString(luaL_checkstring(L, 1)) uppercaseString];
    NSString *urlStr = SafeNSString(luaL_checkstring(L, 2));

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = method;
    req.timeoutInterval = 15.0;

    if (lua_istable(L, 3)) {
        lua_getfield(L, 3, "headers");
        if (lua_istable(L, -1)) {
            lua_pushnil(L);
            while (lua_next(L, -2) != 0) {
                if (lua_isstring(L, -2) && lua_isstring(L, -1)) {
                    [req setValue:SafeNSString(lua_tostring(L, -1))
               forHTTPHeaderField:SafeNSString(lua_tostring(L, -2))];
                }
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);

        lua_getfield(L, 3, "data");
        if (lua_isstring(L, -1)) {
            size_t len = 0;
            const char *data = lua_tolstring(L, -1, &len);
            req.HTTPBody = [NSData dataWithBytes:data length:len];
        }
        lua_pop(L, 1);
    }

    int resolveRef = LUA_NOREF;
    int rejectRef = LUA_NOREF;
    if (lua_isfunction(L, 4)) {
        lua_pushvalue(L, 4);
        resolveRef = luaL_ref(L, LUA_REGISTRYINDEX);
    }
    if (lua_isfunction(L, 5)) {
        lua_pushvalue(L, 5);
        rejectRef = luaL_ref(L, LUA_REGISTRYINDEX);
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            std::lock_guard<std::recursive_mutex> lock(g_luaMutex);
            lua_State *mainL = [LoaderEngine shared].L;
            if (!mainL) return;

            if (error) {
                if (rejectRef != LUA_NOREF) {
                    lua_rawgeti(mainL, LUA_REGISTRYINDEX, rejectRef);
                    lua_pushstring(mainL, [[error localizedDescription] UTF8String]);
                    if (lua_pcall(mainL, 1, 0, 0) != LUA_OK) {
                        AppendConsoleLog(std::string("[HTTP reject err] ") + (lua_tostring(mainL, -1) ?: ""));
                        lua_pop(mainL, 1);
                    }
                }
            } else if (resolveRef != LUA_NOREF) {
                lua_rawgeti(mainL, LUA_REGISTRYINDEX, resolveRef);
                lua_newtable(mainL);

                NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                lua_pushinteger(mainL, httpResp ? httpResp.statusCode : 200);
                lua_setfield(mainL, -2, "status_code");

                if (data && data.length > 0) {
                    lua_pushlstring(mainL, (const char *)data.bytes, data.length);
                } else {
                    lua_pushstring(mainL, "");
                }
                lua_setfield(mainL, -2, "text");

                if (lua_pcall(mainL, 1, 0, 0) != LUA_OK) {
                    AppendConsoleLog(std::string("[HTTP resolve err] ") + (lua_tostring(mainL, -1) ?: ""));
                    lua_pop(mainL, 1);
                }
            }

            if (resolveRef != LUA_NOREF) luaL_unref(mainL, LUA_REGISTRYINDEX, resolveRef);
            if (rejectRef != LUA_NOREF) luaL_unref(mainL, LUA_REGISTRYINDEX, rejectRef);
        });
    }];
    [task resume];
    return 0;
}

// ============================================================================
// 6. Dear ImGui Lua 5.4 Bindings (imgui / mimgui API для скриптов)
// ============================================================================
static int l_imgui_Begin(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    bool *p_open = nullptr;
    bool openVal = true;
    if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "v");
        openVal = lua_toboolean(L, -1);
        lua_pop(L, 1);
        p_open = &openVal;
    }
    ImGuiWindowFlags flags = (ImGuiWindowFlags)luaL_optinteger(L, 3, 0);
    bool shown = ImGui::Begin(name, p_open, flags);
    if (p_open && lua_istable(L, 2)) {
        lua_pushboolean(L, openVal ? 1 : 0);
        lua_setfield(L, 2, "v");
    }
    lua_pushboolean(L, shown ? 1 : 0);
    return 1;
}

static int l_imgui_End(lua_State *L) {
    ImGui::End();
    return 0;
}

static int l_imgui_BeginChild(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    float w = 0, h = 0;
    if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "x"); w = (float)lua_tonumber(L, -1); lua_pop(L, 1);
        lua_getfield(L, 2, "y"); h = (float)lua_tonumber(L, -1); lua_pop(L, 1);
    }
    bool border = lua_toboolean(L, 3);
    ImGuiWindowFlags flags = (ImGuiWindowFlags)luaL_optinteger(L, 4, 0);
    lua_pushboolean(L, ImGui::BeginChild(id, ImVec2(w, h), border, flags) ? 1 : 0);
    return 1;
}

static int l_imgui_EndChild(lua_State *L) {
    ImGui::EndChild();
    return 0;
}

static int l_imgui_Text(lua_State *L) {
    const char *txt = luaL_checkstring(L, 1);
    ImGui::TextUnformatted(txt);
    return 0;
}

static int l_imgui_TextColored(lua_State *L) {
    ImVec4 col(1, 1, 1, 1);
    if (lua_istable(L, 1)) {
        lua_getfield(L, 1, "x"); col.x = (float)lua_tonumber(L, -1); lua_pop(L, 1);
        lua_getfield(L, 1, "y"); col.y = (float)lua_tonumber(L, -1); lua_pop(L, 1);
        lua_getfield(L, 1, "z"); col.z = (float)lua_tonumber(L, -1); lua_pop(L, 1);
        lua_getfield(L, 1, "w"); col.w = (float)lua_tonumber(L, -1); lua_pop(L, 1);
    }
    const char *txt = luaL_checkstring(L, 2);
    ImGui::TextColored(col, "%s", txt);
    return 0;
}

static int l_imgui_Button(lua_State *L) {
    const char *label = luaL_checkstring(L, 1);
    float w = 0, h = 0;
    if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "x"); w = (float)lua_tonumber(L, -1); lua_pop(L, 1);
        lua_getfield(L, 2, "y"); h = (float)lua_tonumber(L, -1); lua_pop(L, 1);
    }
    lua_pushboolean(L, ImGui::Button(label, ImVec2(w, h)) ? 1 : 0);
    return 1;
}

static int l_imgui_Checkbox(lua_State *L) {
    const char *label = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_getfield(L, 2, "v");
    bool val = lua_toboolean(L, -1);
    lua_pop(L, 1);

    bool changed = ImGui::Checkbox(label, &val);
    if (changed) {
        lua_pushboolean(L, val ? 1 : 0);
        lua_setfield(L, 2, "v");
    }
    lua_pushboolean(L, changed ? 1 : 0);
    return 1;
}

static int l_imgui_SliderFloat(lua_State *L) {
    const char *label = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    float v_min = (float)luaL_checknumber(L, 3);
    float v_max = (float)luaL_checknumber(L, 4);
    const char *fmt = luaL_optstring(L, 5, "%.2f");

    lua_getfield(L, 2, "v");
    float val = (float)lua_tonumber(L, -1);
    lua_pop(L, 1);

    bool changed = ImGui::SliderFloat(label, &val, v_min, v_max, fmt);
    if (changed) {
        lua_pushnumber(L, val);
        lua_setfield(L, 2, "v");
    }
    lua_pushboolean(L, changed ? 1 : 0);
    return 1;
}

static int l_imgui_SliderInt(lua_State *L) {
    const char *label = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    int v_min = (int)luaL_checkinteger(L, 3);
    int v_max = (int)luaL_checkinteger(L, 4);

    lua_getfield(L, 2, "v");
    int val = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);

    bool changed = ImGui::SliderInt(label, &val, v_min, v_max);
    if (changed) {
        lua_pushinteger(L, val);
        lua_setfield(L, 2, "v");
    }
    lua_pushboolean(L, changed ? 1 : 0);
    return 1;
}

static int l_imgui_InputText(lua_State *L) {
    const char *label = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    ImGuiInputTextFlags flags = (ImGuiInputTextFlags)luaL_optinteger(L, 3, 0);

    lua_getfield(L, 2, "v");
    const char *cur = lua_tostring(L, -1);
    char buf[1024] = {0};
    if (cur) strncpy(buf, cur, sizeof(buf) - 1);
    lua_pop(L, 1);

    bool changed = ImGui::InputText(label, buf, sizeof(buf), flags);
    if (changed) {
        lua_pushstring(L, buf);
        lua_setfield(L, 2, "v");
    }
    lua_pushboolean(L, changed ? 1 : 0);
    return 1;
}

static int l_imgui_CollapsingHeader(lua_State *L) {
    const char *label = luaL_checkstring(L, 1);
    ImGuiTreeNodeFlags flags = (ImGuiTreeNodeFlags)luaL_optinteger(L, 2, 0);
    lua_pushboolean(L, ImGui::CollapsingHeader(label, flags) ? 1 : 0);
    return 1;
}

static int l_imgui_Separator(lua_State *L) { ImGui::Separator(); return 0; }
static int l_imgui_Spacing(lua_State *L) { ImGui::Spacing(); return 0; }
static int l_imgui_SameLine(lua_State *L) {
    ImGui::SameLine((float)luaL_optnumber(L, 1, 0.0), (float)luaL_optnumber(L, 2, -1.0));
    return 0;
}

static int l_imgui_SetNextWindowSize(lua_State *L) {
    float w = 300, h = 200;
    if (lua_istable(L, 1)) {
        lua_getfield(L, 1, "x"); w = (float)lua_tonumber(L, -1); lua_pop(L, 1);
        lua_getfield(L, 1, "y"); h = (float)lua_tonumber(L, -1); lua_pop(L, 1);
    }
    ImGuiCond cond = (ImGuiCond)luaL_optinteger(L, 2, ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSize(ImVec2(w, h), cond);
    return 0;
}

static int l_imgui_SetNextWindowPos(lua_State *L) {
    float x = 100, y = 100;
    if (lua_istable(L, 1)) {
        lua_getfield(L, 1, "x"); x = (float)lua_tonumber(L, -1); lua_pop(L, 1);
        lua_getfield(L, 1, "y"); y = (float)lua_tonumber(L, -1); lua_pop(L, 1);
    }
    ImGuiCond cond = (ImGuiCond)luaL_optinteger(L, 2, ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(x, y), cond);
    return 0;
}

static int l_imgui_OnFrame(lua_State *L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    luaL_checktype(L, 2, LUA_TFUNCTION);

    lua_newtable(L);
    lua_pushvalue(L, 1);
    lua_setfield(L, -2, "cond");
    lua_pushvalue(L, 2);
    lua_setfield(L, -2, "draw");
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);
    [[LoaderEngine shared].frameCallbackRefs addObject:@(ref)];
    return 0;
}

static void RegisterImGuiModule(lua_State *L) {
    lua_newtable(L);

    lua_pushcfunction(L, l_imgui_Begin); lua_setfield(L, -2, "Begin");
    lua_pushcfunction(L, l_imgui_End); lua_setfield(L, -2, "End");
    lua_pushcfunction(L, l_imgui_BeginChild); lua_setfield(L, -2, "BeginChild");
    lua_pushcfunction(L, l_imgui_EndChild); lua_setfield(L, -2, "EndChild");
    lua_pushcfunction(L, l_imgui_Text); lua_setfield(L, -2, "Text");
    lua_pushcfunction(L, l_imgui_TextColored); lua_setfield(L, -2, "TextColored");
    lua_pushcfunction(L, l_imgui_Button); lua_setfield(L, -2, "Button");
    lua_pushcfunction(L, l_imgui_Checkbox); lua_setfield(L, -2, "Checkbox");
    lua_pushcfunction(L, l_imgui_SliderFloat); lua_setfield(L, -2, "SliderFloat");
    lua_pushcfunction(L, l_imgui_SliderInt); lua_setfield(L, -2, "SliderInt");
    lua_pushcfunction(L, l_imgui_InputText); lua_setfield(L, -2, "InputText");
    lua_pushcfunction(L, l_imgui_CollapsingHeader); lua_setfield(L, -2, "CollapsingHeader");
    lua_pushcfunction(L, l_imgui_Separator); lua_setfield(L, -2, "Separator");
    lua_pushcfunction(L, l_imgui_Spacing); lua_setfield(L, -2, "Spacing");
    lua_pushcfunction(L, l_imgui_SameLine); lua_setfield(L, -2, "SameLine");
    lua_pushcfunction(L, l_imgui_SetNextWindowSize); lua_setfield(L, -2, "SetNextWindowSize");
    lua_pushcfunction(L, l_imgui_SetNextWindowPos); lua_setfield(L, -2, "SetNextWindowPos");
    lua_pushcfunction(L, l_imgui_OnFrame); lua_setfield(L, -2, "OnFrame");

    lua_pushboolean(L, 0);
    lua_setfield(L, -2, "Process");

    // Хелперы ImVec2, ImVec4, ImBool, ImFloat, ImInt, ImBuffer в Lua
    const char *helpers = R"lua(
        local M = ...
        function M.ImVec2(x, y) return { x = x or 0, y = y or 0 } end
        function M.ImVec4(x, y, z, w) return { x = x or 0, y = y or 0, z = z or 0, w = w or 1 } end
        function M.ImBool(v) return { v = v and true or false } end
        function M.ImFloat(v) return { v = tonumber(v) or 0.0 } end
        function M.ImInt(v) return { v = math.floor(tonumber(v) or 0) } end
        function M.ImBuffer(size) return { v = "", size = size or 256 } end
        M.new = {
            bool = M.ImBool,
            float = M.ImFloat,
            int = M.ImInt,
            char = M.ImBuffer
        }
        M.Cond = { Always = 1, Once = 2, FirstUseEver = 4, Appearing = 8 }
        M.WindowFlags = {
            None = 0, NoTitleBar = 1, NoResize = 2, NoMove = 4,
            NoScrollbar = 8, NoCollapse = 32, AlwaysAutoResize = 64,
            NoBackground = 128, NoSavedSettings = 256, NoInputs = 197120
        }
    )lua";

    if (luaL_loadstring(L, helpers) == LUA_OK) {
        lua_pushvalue(L, -2);
        if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
            lua_pop(L, 1);
        }
    } else {
        lua_pop(L, 1);
    }

    lua_pushvalue(L, -1);
    lua_setglobal(L, "imgui");

    lua_getglobal(L, "package");
    lua_getfield(L, -1, "loaded");
    lua_pushvalue(L, -3);
    lua_setfield(L, -2, "imgui");
    lua_pushvalue(L, -3);
    lua_setfield(L, -2, "mimgui");
    lua_pop(L, 3);
}

// ============================================================================
// 7. Встроенный Metal + Dear ImGui Overlay View (HUD + Трейсеры + Меню)
// ============================================================================
@interface LoaderMetalOverlayView : MTKView <MTKViewDelegate>
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, assign) CGRect floatingBtnRect;
@property (nonatomic, assign) BOOL draggingFloatingBtn;
@property (nonatomic, assign) CGPoint dragStartTouch;
@property (nonatomic, assign) CGPoint dragStartOrigin;
@property (nonatomic, assign) BOOL movedDuringTouch;
@end

@implementation LoaderMetalOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    self = [super initWithFrame:frame device:dev];
    if (self) {
        self.delegate = self;
        self.commandQueue = [dev newCommandQueue];
        self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        self.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.framebufferOnly = NO;
        self.preferredFramesPerSecond = 60;
        self.multipleTouchEnabled = NO;

        // Позиция плавающей кнопки "42" по умолчанию (левый верхний угол под челкой)
        self.floatingBtnRect = CGRectMake(18.0, 62.0, 42.0, 42.0);

        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        ImGuiIO &io = ImGui::GetIO();
        io.IniFilename = nullptr;
        io.ConfigFlags |= ImGuiConfigFlags_IsTouchScreen;

        // Тёмно-фиолетовая минималистичная тема
        ImGui::StyleColorsDark();
        ImGuiStyle &style = ImGui::GetStyle();
        style.WindowRounding = 10.0f;
        style.FrameRounding = 6.0f;
        style.GrabRounding = 6.0f;
        style.TabRounding = 6.0f;
        style.WindowBorderSize = 1.0f;
        style.Colors[ImGuiCol_WindowBg] = ImVec4(0.08f, 0.07f, 0.12f, 0.94f);
        style.Colors[ImGuiCol_Border] = ImVec4(0.55f, 0.32f, 0.92f, 0.45f);
        style.Colors[ImGuiCol_TitleBg] = ImVec4(0.13f, 0.09f, 0.22f, 1.00f);
        style.Colors[ImGuiCol_TitleBgActive] = ImVec4(0.32f, 0.18f, 0.56f, 1.00f);
        style.Colors[ImGuiCol_Button] = ImVec4(0.36f, 0.20f, 0.62f, 0.85f);
        style.Colors[ImGuiCol_ButtonHovered] = ImVec4(0.48f, 0.28f, 0.78f, 1.00f);
        style.Colors[ImGuiCol_ButtonActive] = ImVec4(0.58f, 0.35f, 0.90f, 1.00f);
        style.Colors[ImGuiCol_FrameBg] = ImVec4(0.15f, 0.13f, 0.22f, 0.90f);
        style.Colors[ImGuiCol_CheckMark] = ImVec4(0.72f, 0.45f, 1.00f, 1.00f);
        style.Colors[ImGuiCol_SliderGrab] = ImVec4(0.65f, 0.38f, 0.96f, 1.00f);
        style.Colors[ImGuiCol_Tab] = ImVec4(0.18f, 0.13f, 0.28f, 0.90f);
        style.Colors[ImGuiCol_TabHovered] = ImVec4(0.45f, 0.25f, 0.74f, 0.95f);
        style.Colors[ImGuiCol_TabActive] = ImVec4(0.38f, 0.21f, 0.65f, 1.00f);

        ImGui_ImplMetal_Init(dev);
    }
    return self;
}

// Сквозной hitTest: пропускаем все тапы в игру, если палец не попал по кнопке 42 или активному окну ImGui
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (g_showFloatingBtn && CGRectContainsPoint(CGRectInset(self.floatingBtnRect, -6, -6), point)) {
        return self;
    }

    ImGuiContext *ctx = ImGui::GetCurrentContext();
    if (ctx) {
        for (int i = 0; i < ctx->Windows.Size; i++) {
            ImGuiWindow *win = ctx->Windows[i];
            if (!win || !win->Active || win->Hidden) continue;
            if (win->Flags & ImGuiWindowFlags_NoInputs) continue;
            CGRect r = CGRectMake(win->Pos.x, win->Pos.y, win->Size.x, win->Size.y);
            if (CGRectContainsPoint(r, point)) {
                return self;
            }
        }
    }
    return nil;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    if (!t) return;
    CGPoint pt = [t locationInView:self];

    if (g_showFloatingBtn && CGRectContainsPoint(CGRectInset(self.floatingBtnRect, -6, -6), pt)) {
        self.draggingFloatingBtn = YES;
        self.dragStartTouch = pt;
        self.dragStartOrigin = self.floatingBtnRect.origin;
        self.movedDuringTouch = NO;
        return;
    }

    ImGuiIO &io = ImGui::GetIO();
    io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
    io.AddMousePosEvent((float)pt.x, (float)pt.y);
    io.AddMouseButtonEvent(0, true);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    if (!t) return;
    CGPoint pt = [t locationInView:self];

    if (self.draggingFloatingBtn) {
        CGFloat dx = pt.x - self.dragStartTouch.x;
        CGFloat dy = pt.y - self.dragStartTouch.y;
        if (fabs(dx) > 5.0 || fabs(dy) > 5.0) self.movedDuringTouch = YES;
        CGFloat nx = MAX(6.0, MIN(self.bounds.size.width - self.floatingBtnRect.size.width - 6.0, self.dragStartOrigin.x + dx));
        CGFloat ny = MAX(24.0, MIN(self.bounds.size.height - self.floatingBtnRect.size.height - 6.0, self.dragStartOrigin.y + dy));
        self.floatingBtnRect = CGRectMake(nx, ny, self.floatingBtnRect.size.width, self.floatingBtnRect.size.height);
        return;
    }

    ImGuiIO &io = ImGui::GetIO();
    io.AddMousePosEvent((float)pt.x, (float)pt.y);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    CGPoint pt = t ? [t locationInView:self] : CGPointZero;

    if (self.draggingFloatingBtn) {
        self.draggingFloatingBtn = NO;
        if (!self.movedDuringTouch) {
            g_showImGuiMenu = !g_showImGuiMenu;
        }
        return;
    }

    ImGuiIO &io = ImGui::GetIO();
    io.AddMousePosEvent((float)pt.x, (float)pt.y);
    io.AddMouseButtonEvent(0, false);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.draggingFloatingBtn = NO;
    ImGuiIO &io = ImGui::GetIO();
    io.AddMouseButtonEvent(0, false);
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

- (void)drawInMTKView:(MTKView *)view {
    // Тикаем логику и рендер Lua
    LoaderEngine *eng = [LoaderEngine shared];
    [eng tickUpdate];
    UpdateLoaderRamStats(eng.L);

    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!rpd || !drawable) return;

    id<MTLCommandBuffer> cmdBuf = [self.commandQueue commandBuffer];
    ImGui_ImplMetal_NewFrame(rpd);

    ImGuiIO &io = ImGui::GetIO();
    CGFloat scale = self.contentScaleFactor > 0 ? self.contentScaleFactor : [UIScreen mainScreen].scale;
    io.DisplaySize = ImVec2((float)self.bounds.size.width, (float)self.bounds.size.height);
    io.DisplayFramebufferScale = ImVec2((float)scale, (float)scale);

    ImGui::NewFrame();

    // Выполняем Lua onRender / imgui.OnFrame
    [eng tickRender];

    ImDrawList *fg = ImGui::GetForegroundDrawList();
    ImDrawList *bg = ImGui::GetBackgroundDrawList();
    float sw = io.DisplaySize.x;
    float sh = io.DisplaySize.y;

    // ------------------------------------------------------------------------
    // A. Отрисовка 2D-примитивов и Трейсеров
    // ------------------------------------------------------------------------
    if (g_renderEnabled) {
        // 1) Прицел по центру экрана
        if (g_drawCrosshair) {
            ImVec2 c(sw * 0.5f, sh * 0.5f);
            ImU32 col = Float4ToImU32(g_crosshairColor);
            bg->AddLine(ImVec2(c.x - g_crosshairSize, c.y), ImVec2(c.x + g_crosshairSize, c.y), col, 1.5f);
            bg->AddLine(ImVec2(c.x, c.y - g_crosshairSize), ImVec2(c.x, c.y + g_crosshairSize), col, 1.5f);
            bg->AddCircle(c, g_crosshairSize * 0.55f, col, 20, 1.2f);
        }

        // 2) Демо-трейсеры (если включены в меню для проверки)
        if (g_drawDemoTracers) {
            float t = (float)ImGui::GetTime();
            ImVec2 origin = g_tracerFromCenter ? ImVec2(sw * 0.5f, sh * 0.5f) : ImVec2(sw * 0.5f, sh - 12.0f);
            ImU32 tCol = Float4ToImU32(g_tracerColor);
            for (int i = 0; i < 3; i++) {
                float angle = t * 1.1f + i * 2.094f;
                ImVec2 target(sw * 0.5f + cosf(angle) * (sw * 0.25f),
                              sh * 0.42f + sinf(angle) * (sh * 0.18f));
                bg->AddLine(origin, target, tCol, g_tracerThickness);
                bg->AddCircleFilled(target, 4.0f, tCol);
                char tag[48];
                snprintf(tag, sizeof(tag), "Target #%d [%.0fm]", i + 1, 25.0f + i * 18.0f);
                bg->AddText(ImVec2(target.x + 7.0f, target.y - 7.0f), IM_COL32(255, 255, 255, 230), tag);
            }
        }

        // 3) Пользовательские трейсеры из Lua (az.addTracer / az.addScreenTracer)
        {
            std::lock_guard<std::mutex> lock(g_renderMutex);
            ImVec2 origin = g_tracerFromCenter ? ImVec2(sw * 0.5f, sh * 0.5f) : ImVec2(sw * 0.5f, sh - 10.0f);
            for (const auto &kv : g_tracers) {
                const TracerItem &tr = kv.second;
                ImU32 col = ARGBToImU32(tr.color);
                if (tr.is3D) {
                    float sx = 0, sy = 0;
                    if (ProjectWorldToScreen(tr.x1, tr.y1, tr.z1, sw, sh, sx, sy)) {
                        ImVec2 dst(sx, sy);
                        bg->AddLine(origin, dst, col, tr.thickness);
                        bg->AddCircleFilled(dst, 3.8f, col);
                        if (!tr.label.empty()) {
                            bg->AddText(ImVec2(dst.x + 6.0f, dst.y - 7.0f), IM_COL32(255, 255, 255, 235), tr.label.c_str());
                        }
                    }
                } else {
                    ImVec2 p1(tr.x1, tr.y1);
                    ImVec2 p2(tr.x2, tr.y2);
                    bg->AddLine(p1, p2, col, tr.thickness);
                    bg->AddCircleFilled(p2, 3.5f, col);
                    if (!tr.label.empty()) {
                        bg->AddText(ImVec2(p2.x + 6.0f, p2.y - 7.0f), IM_COL32(255, 255, 255, 235), tr.label.c_str());
                    }
                }
            }

            // 4) Очередь 2D-примитивов из Lua (renderDrawLine/Box/Circle/Text)
            for (const auto &c : g_luaDrawQueue) {
                ImU32 col = ARGBToImU32(c.color);
                switch (c.type) {
                    case DrawCmdType::Line:
                        bg->AddLine(ImVec2(c.x1, c.y1), ImVec2(c.x2, c.y2), col, c.radius);
                        break;
                    case DrawCmdType::Box:
                        bg->AddRect(ImVec2(c.x1, c.y1), ImVec2(c.x1 + c.x2, c.y1 + c.y2), col, 0.0f, 0, c.radius > 0 ? c.radius : 1.0f);
                        break;
                    case DrawCmdType::BoxFilled:
                        bg->AddRectFilled(ImVec2(c.x1, c.y1), ImVec2(c.x1 + c.x2, c.y1 + c.y2), col);
                        break;
                    case DrawCmdType::Circle:
                        bg->AddCircle(ImVec2(c.x1, c.y1), c.radius, col, c.segments, 1.5f);
                        break;
                    case DrawCmdType::CircleFilled:
                        bg->AddCircleFilled(ImVec2(c.x1, c.y1), c.radius, col, c.segments);
                        break;
                    case DrawCmdType::Text:
                        bg->AddText(ImVec2(c.x1, c.y1), col, c.text.c_str());
                        break;
                }
            }
            g_luaDrawQueue.clear();
        }
    }

    // ------------------------------------------------------------------------
    // B. Маленький текст СПРАВА ПО СЕРЕДИНЕ: сколько RAM жрёт именно лоадер
    // ------------------------------------------------------------------------
    if (g_showRamHud && sw > 0 && sh > 0) {
        char ramText[96];
        double totalMB = (double)g_ramStats.totalBytes / (1024.0 * 1024.0);
        double luaKB = (double)g_ramStats.luaHeapBytes / 1024.0;
        snprintf(ramText, sizeof(ramText), "Loader RAM: %.2f MB (Lua: %.0f KB)", totalMB, luaKB);

        const float fontSize = 11.0f;
        ImFont *font = ImGui::GetFont();
        ImVec2 txtSize = font->CalcTextSizeA(fontSize, FLT_MAX, 0.0f, ramText);

        float posX = sw - txtSize.x - 10.0f;
        float posY = (sh - txtSize.y) * 0.5f;

        // Чёткая тень/обводка, чтобы мелкий текст легко читался на любом фоне в игре
        ImU32 shadowCol = IM_COL32(0, 0, 0, 210);
        ImU32 textCol = IM_COL32(228, 218, 255, 225);
        fg->AddText(font, fontSize, ImVec2(posX + 1.0f, posY + 1.0f), shadowCol, ramText);
        fg->AddText(font, fontSize, ImVec2(posX - 1.0f, posY), shadowCol, ramText);
        fg->AddText(font, fontSize, ImVec2(posX, posY), textCol, ramText);
    }

    // ------------------------------------------------------------------------
    // C. Плавающая круглая кнопка "42" для быстрого открытия ImGui меню
    // ------------------------------------------------------------------------
    if (g_showFloatingBtn) {
        ImVec2 center((float)CGRectGetMidX(self.floatingBtnRect), (float)CGRectGetMidY(self.floatingBtnRect));
        float r = (float)self.floatingBtnRect.size.width * 0.5f;
        fg->AddCircleFilled(center, r, IM_COL32(24, 18, 38, 220), 32);
        fg->AddCircle(center, r, g_showImGuiMenu ? IM_COL32(180, 110, 255, 255) : IM_COL32(130, 80, 220, 190), 32, 1.8f);
        ImVec2 labelSz = ImGui::CalcTextSize("42");
        fg->AddText(ImVec2(center.x - labelSz.x * 0.5f, center.y - labelSz.y * 0.5f),
                    IM_COL32(245, 240, 255, 245), "42");
    }

    // ------------------------------------------------------------------------
    // D. Главное окно ImGui интерфейса (Scripts / Render & Tracers / Console / Settings)
    // ------------------------------------------------------------------------
    if (g_showImGuiMenu) {
        ImGui::SetNextWindowSize(ImVec2(460.0f, 320.0f), ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowPos(ImVec2((sw - 460.0f) * 0.5f, (sh - 320.0f) * 0.5f), ImGuiCond_FirstUseEver);

        if (ImGui::Begin("Arizona 42Loader  |  Lua 5.4 + ImGui", &g_showImGuiMenu, ImGuiWindowFlags_NoCollapse)) {
            if (ImGui::BeginTabBar("LoaderTabs")) {
                // --- Вкладка 1: Скрипты ---
                if (ImGui::BeginTabItem("Scripts")) {
                    if (ImGui::Button("Reload All Scripts")) {
                        [eng reloadAllScripts];
                    }
                    ImGui::SameLine();
                    ImGui::TextDisabled("Dir: Documents/lua_loader/scripts");
                    ImGui::Separator();

                    auto scripts = [eng allScriptsStatus];
                    if (scripts.empty()) {
                        ImGui::TextWrapped("No .lua scripts found in Documents/lua_loader/scripts/");
                    } else {
                        ImGui::BeginChild("ScriptsScroll", ImVec2(0, 0), false);
                        for (size_t i = 0; i < scripts.size(); i++) {
                            auto &sc = scripts[i];
                            ImGui::PushID((int)i);
                            bool en = sc.enabled;
                            if (ImGui::Checkbox("##en", &en)) {
                                [eng setScript:SafeNSString(sc.filename.c_str()) enabled:en];
                            }
                            ImGui::SameLine();
                            ImGui::Text("%s", sc.filename.c_str());
                            ImGui::SameLine();
                            if (sc.loaded) {
                                ImGui::TextColored(ImVec4(0.35f, 0.95f, 0.55f, 1.0f), "[ACTIVE]");
                            } else if (!sc.enabled) {
                                ImGui::TextDisabled("[DISABLED]");
                            } else {
                                ImGui::TextColored(ImVec4(0.95f, 0.35f, 0.35f, 1.0f), "[ERROR]");
                            }
                            ImGui::SameLine();
                            if (ImGui::SmallButton("Reload")) {
                                [eng loadSingleScript:SafeNSString(sc.filename.c_str())];
                            }
                            if (!sc.lastError.empty()) {
                                ImGui::TextColored(ImVec4(1.0f, 0.4f, 0.4f, 1.0f), "  %s", sc.lastError.c_str());
                            }
                            ImGui::PopID();
                        }
                        ImGui::EndChild();
                    }
                    ImGui::EndTabItem();
                }

                // --- Вкладка 2: Render & Tracers ---
                if (ImGui::BeginTabItem("Render & Tracers")) {
                    ImGui::Checkbox("Enable Render & Tracers", &g_renderEnabled);
                    ImGui::Separator();

                    ImGui::Checkbox("Demo / Test Tracers (Preview)", &g_drawDemoTracers);
                    ImGui::Checkbox("Origin: Screen Center (off = Bottom)", &g_tracerFromCenter);
                    ImGui::SliderFloat("Tracer Thickness", &g_tracerThickness, 0.8f, 5.0f, "%.1f px");
                    ImGui::ColorEdit4("Tracer Color", g_tracerColor);

                    ImGui::Separator();
                    ImGui::Checkbox("Center Crosshair", &g_drawCrosshair);
                    if (g_drawCrosshair) {
                        ImGui::SliderFloat("Crosshair Size", &g_crosshairSize, 3.0f, 25.0f, "%.0f px");
                        ImGui::ColorEdit4("Crosshair Color", g_crosshairColor);
                    }

                    ImGui::Separator();
                    size_t activeCount = 0;
                    {
                        std::lock_guard<std::mutex> lock(g_renderMutex);
                        activeCount = g_tracers.size();
                    }
                    ImGui::Text("Active Lua Tracers: %zu", activeCount);
                    ImGui::SameLine();
                    if (ImGui::SmallButton("Clear Tracers")) {
                        std::lock_guard<std::mutex> lock(g_renderMutex);
                        g_tracers.clear();
                    }
                    ImGui::EndTabItem();
                }

                // --- Вкладка 3: Console & Lua Exec ---
                if (ImGui::BeginTabItem("Console")) {
                    static char luaCmdBuf[512] = "";
                    ImGui::SetNextItemWidth(-70.0f);
                    bool enterPressed = ImGui::InputText("##luacmd", luaCmdBuf, sizeof(luaCmdBuf), ImGuiInputTextFlags_EnterReturnsTrue);
                    ImGui::SameLine();
                    if (ImGui::Button("Run", ImVec2(60.0f, 0)) || enterPressed) {
                        if (strlen(luaCmdBuf) > 0) {
                            [eng executeLuaString:SafeNSString(luaCmdBuf)];
                            luaCmdBuf[0] = '\0';
                        }
                    }
                    ImGui::Separator();

                    ImGui::BeginChild("ConsoleScroll", ImVec2(0, 0), true);
                    {
                        std::lock_guard<std::mutex> lock(g_logMutex);
                        for (const auto &line : g_consoleLogs) {
                            ImGui::TextUnformatted(line.c_str());
                        }
                    }
                    if (ImGui::GetScrollY() >= ImGui::GetScrollMaxY() - 10.0f) {
                        ImGui::SetScrollHereY(1.0f);
                    }
                    ImGui::EndChild();
                    ImGui::EndTabItem();
                }

                // --- Вкладка 4: Settings & RAM Breakdown ---
                if (ImGui::BeginTabItem("Settings")) {
                    ImGui::Checkbox("Show Loader RAM HUD (Right-Middle)", &g_showRamHud);
                    ImGui::Checkbox("Show Floating '42' Button", &g_showFloatingBtn);
                    ImGui::Separator();

                    ImGui::Text("Loader Memory Footprint:");
                    ImGui::BulletText("Total Loader RAM: %.2f MB", (double)g_ramStats.totalBytes / (1024.0 * 1024.0));
                    ImGui::BulletText("Lua 5.4 VM Heap:  %.1f KB", (double)g_ramStats.luaHeapBytes / 1024.0);
                    ImGui::BulletText("Mach-O Image:     %.2f MB", (double)g_ramStats.dylibImageBytes / (1024.0 * 1024.0));
                    ImGui::BulletText("ImGui & Buffers:  %.1f KB", (double)g_ramStats.buffersBytes / 1024.0);

                    ImGui::Separator();
                    if (ImGui::Button("Trigger Lua GC")) {
                        std::lock_guard<std::recursive_mutex> lock(g_luaMutex);
                        if (eng.L) lua_gc(eng.L, LUA_GCCOLLECT, 0);
                        g_lastRamUpdate = 0;
                        UpdateLoaderRamStats(eng.L);
                    }
                    ImGui::EndTabItem();
                }

                ImGui::EndTabBar();
            }
        }
        ImGui::End();
    }

    ImGui::Render();
    ImDrawData *drawData = ImGui::GetDrawData();

    id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
    ImGui_ImplMetal_RenderDrawData(drawData, cmdBuf, enc);
    [enc endEncoding];

    [cmdBuf presentDrawable:drawable];
    [cmdBuf commit];
}

@end

// ============================================================================
// 8. Реализация LoaderEngine
// ============================================================================
@implementation LoaderEngine {
    std::vector<ScriptEntry> _scripts;
    LoaderMetalOverlayView *_overlayView;
}

+ (instancetype)shared {
    static LoaderEngine *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LoaderEngine alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _commandRefs = [NSMutableDictionary dictionary];
        _frameCallbackRefs = [NSMutableArray array];
        _disabledScripts = [NSMutableDictionary dictionary];
        _currentDialogId = -1;
        _chatInputText = @"";

        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        _baseDir = [docs stringByAppendingPathComponent:@"lua_loader"];
        _scriptsDir = [_baseDir stringByAppendingPathComponent:@"scripts"];
        _configDir = [_baseDir stringByAppendingPathComponent:@"config"];
        _libDir = [_baseDir stringByAppendingPathComponent:@"lib"];
    }
    return self;
}

- (void)ensureDirectories {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in @[self.baseDir, self.scriptsDir, self.configDir, self.libDir]) {
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }
}

- (void)loadConfig {
    NSString *cfgPath = [self.configDir stringByAppendingPathComponent:@"loader_config.json"];
    NSData *data = [NSData dataWithContentsOfFile:cfgPath];
    if (!data) return;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *disabled = dict[@"disabledScripts"];
    if ([disabled isKindOfClass:[NSDictionary class]]) {
        [self.disabledScripts setDictionary:disabled];
    }
    if (dict[@"showRamHud"]) g_showRamHud = [dict[@"showRamHud"] boolValue];
    if (dict[@"showFloatingBtn"]) g_showFloatingBtn = [dict[@"showFloatingBtn"] boolValue];
    if (dict[@"renderEnabled"]) g_renderEnabled = [dict[@"renderEnabled"] boolValue];
}

- (void)saveConfig {
    NSString *cfgPath = [self.configDir stringByAppendingPathComponent:@"loader_config.json"];
    NSDictionary *dict = @{
        @"disabledScripts": self.disabledScripts ?: @{},
        @"showRamHud": @(g_showRamHud),
        @"showFloatingBtn": @(g_showFloatingBtn),
        @"renderEnabled": @(g_renderEnabled)
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:nil];
    if (data) [data writeToFile:cfgPath atomically:YES];
}

- (void)setupLuaState {
    std::lock_guard<std::recursive_mutex> lock(g_luaMutex);

    if (_L) {
        lua_close(_L);
        _L = nullptr;
    }
    g_luaThreads.clear();
    [self.commandRefs removeAllObjects];
    [self.frameCallbackRefs removeAllObjects];

    _L = luaL_newstate();
    luaL_openlibs(_L);

    // Настройка package.path под Documents/lua_loader/lib/?.lua и scripts/?.lua
    NSString *pkgPath = [NSString stringWithFormat:@"%@/?.lua;%@/?.lua", self.libDir, self.scriptsDir];
    lua_getglobal(_L, "package");
    lua_pushstring(_L, [pkgPath UTF8String]);
    lua_setfield(_L, -2, "path");
    lua_pop(_L, 1);

    // Глобальные функции
    lua_pushcfunction(_L, l_print); lua_setglobal(_L, "print");
    lua_pushcfunction(_L, l_wait); lua_setglobal(_L, "wait");
    lua_pushcfunction(_L, l_asyncHttpRequest); lua_setglobal(_L, "asyncHttpRequest");

    // lua_thread таблица
    lua_newtable(_L);
    lua_pushcfunction(_L, l_lua_thread_create);
    lua_setfield(_L, -2, "create");
    lua_setglobal(_L, "lua_thread");

    // SA-MP / MoonLoader API
    lua_pushcfunction(_L, l_sampAddChatMessage); lua_setglobal(_L, "sampAddChatMessage");
    lua_pushcfunction(_L, l_sampSendChat); lua_setglobal(_L, "sampSendChat");
    lua_pushcfunction(_L, l_sampRegisterChatCommand); lua_setglobal(_L, "sampRegisterChatCommand");
    lua_pushcfunction(_L, l_sampUnregisterChatCommand); lua_setglobal(_L, "sampUnregisterChatCommand");
    lua_pushcfunction(_L, l_sampShowDialog); lua_setglobal(_L, "sampShowDialog");
    lua_pushcfunction(_L, l_sampGetCurrentDialogId); lua_setglobal(_L, "sampGetCurrentDialogId");
    lua_pushcfunction(_L, l_sampIsDialogActive); lua_setglobal(_L, "sampIsDialogActive");
    lua_pushcfunction(_L, l_sampIsChatInputActive); lua_setglobal(_L, "sampIsChatInputActive");
    lua_pushcfunction(_L, l_sampGetChatInputText); lua_setglobal(_L, "sampGetChatInputText");
    lua_pushcfunction(_L, l_isSampAvailable); lua_setglobal(_L, "isSampAvailable");
    lua_pushcfunction(_L, l_sampGetGamestate); lua_setglobal(_L, "sampGetGamestate");

    // Render & 3D->2D API
    lua_pushcfunction(_L, l_getScreenResolution); lua_setglobal(_L, "getScreenResolution");
    lua_pushcfunction(_L, l_convert3DCoordsToScreen); lua_setglobal(_L, "convert3DCoordsToScreen");
    lua_pushcfunction(_L, l_renderDrawLine); lua_setglobal(_L, "renderDrawLine");
    lua_pushcfunction(_L, l_renderDrawBox); lua_setglobal(_L, "renderDrawBox");
    lua_pushcfunction(_L, l_renderDrawCircle); lua_setglobal(_L, "renderDrawCircle");
    lua_pushcfunction(_L, l_renderDrawText); lua_setglobal(_L, "renderDrawText");

    // az.* namespace
    lua_newtable(_L);
    lua_pushcfunction(_L, l_sampAddChatMessage); lua_setfield(_L, -2, "chat");
    lua_pushcfunction(_L, l_sampSendChat); lua_setfield(_L, -2, "send");
    lua_pushcfunction(_L, l_az_notify); lua_setfield(_L, -2, "notify");
    lua_pushcfunction(_L, l_az_vibrate); lua_setfield(_L, -2, "vibrate");
    lua_pushcfunction(_L, l_az_setClipboard); lua_setfield(_L, -2, "setClipboard");
    lua_pushcfunction(_L, l_az_getClipboard); lua_setfield(_L, -2, "getClipboard");
    lua_pushcfunction(_L, l_az_openURL); lua_setfield(_L, -2, "openURL");
    lua_pushcfunction(_L, l_az_getLoaderRAM); lua_setfield(_L, -2, "getLoaderRAM");
    lua_pushcfunction(_L, l_az_setCamera); lua_setfield(_L, -2, "setCamera");
    lua_pushcfunction(_L, l_az_addTracer); lua_setfield(_L, -2, "addTracer");
    lua_pushcfunction(_L, l_az_addScreenTracer); lua_setfield(_L, -2, "addScreenTracer");
    lua_pushcfunction(_L, l_az_removeTracer); lua_setfield(_L, -2, "removeTracer");
    lua_pushcfunction(_L, l_az_clearTracers); lua_setfield(_L, -2, "clearTracers");
    lua_setglobal(_L, "az");

    // Dear ImGui Lua bindings
    RegisterImGuiModule(_L);

    // Встроенные модули json и inicfg
    const char *builtinLibs = R"lua(
        json = {}
        function json.encode(val)
            local t = type(val)
            if t == "nil" then return "null"
            elseif t == "boolean" then return val and "true" or "false"
            elseif t == "number" then return tostring(val)
            elseif t == "string" then
                return string.format("%q", val):gsub("\n", "\\n")
            elseif t == "table" then
                local isArr = (#val > 0)
                local parts = {}
                if isArr then
                    for i = 1, #val do parts[#parts + 1] = json.encode(val[i]) end
                    return "[" .. table.concat(parts, ",") .. "]"
                else
                    for k, v in pairs(val) do
                        parts[#parts + 1] = json.encode(tostring(k)) .. ":" .. json.encode(v)
                    end
                    return "{" .. table.concat(parts, ",") .. "}"
                end
            end
            return "null"
        end
        package.loaded["json"] = json

        inicfg = {}
        function inicfg.load(defaultTbl, filename)
            local res = {}
            if type(defaultTbl) == "table" then
                for sec, kv in pairs(defaultTbl) do
                    res[sec] = {}
                    for k, v in pairs(kv) do res[sec][k] = v end
                end
            end
            local f = io.open(filename, "r")
            if not f then return res end
            local curSec = "main"
            for line in f:lines() do
                local s = line:match("^%s*%[([^%]]+)%]%s*$")
                if s then
                    curSec = s
                    res[curSec] = res[curSec] or {}
                else
                    local k, v = line:match("^%s*([^=;#]+)%s*=%s*(.-)%s*$")
                    if k and v then
                        res[curSec] = res[curSec] or {}
                        if v == "true" then v = true
                        elseif v == "false" then v = false
                        elseif tonumber(v) then v = tonumber(v) end
                        res[curSec][k] = v
                    end
                end
            end
            f:close()
            return res
        end
        function inicfg.save(data, filename)
            local f = io.open(filename, "w")
            if not f then return false end
            for sec, kv in pairs(data) do
                f:write("[" .. tostring(sec) .. "]\n")
                for k, v in pairs(kv) do
                    f:write(tostring(k) .. "=" .. tostring(v) .. "\n")
                end
                f:write("\n")
            end
            f:close()
            return true
        end
        package.loaded["inicfg"] = inicfg
    )lua";

    if (luaL_dostring(_L, builtinLibs) != LUA_OK) {
        AppendConsoleLog(std::string("[builtinLibs err] ") + (lua_tostring(_L, -1) ?: ""));
        lua_pop(_L, 1);
    }
}

- (void)reloadAllScripts {
    std::lock_guard<std::recursive_mutex> lock(g_luaMutex);
    [self ensureDirectories];
    [self setupLuaState];
    _scripts.clear();

    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.scriptsDir error:nil];
    NSArray<NSString *> *sorted = [files sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    for (NSString *file in sorted) {
        if (![[file pathExtension].lowercaseString isEqualToString:@"lua"]) continue;
        ScriptEntry entry;
        entry.filename = [file UTF8String];
        entry.fullPath = [[self.scriptsDir stringByAppendingPathComponent:file] UTF8String];
        entry.enabled = ![self.disabledScripts[file] boolValue];
        entry.loaded = false;
        _scripts.push_back(entry);

        if (entry.enabled) {
            [self loadSingleScript:file];
        }
    }
    AppendConsoleLog("Scripts reloaded (" + std::to_string(_scripts.size()) + " found)");
}

- (BOOL)loadSingleScript:(NSString *)filename {
    std::lock_guard<std::recursive_mutex> lock(g_luaMutex);
    if (!_L) return NO;

    NSString *path = [self.scriptsDir stringByAppendingPathComponent:filename];
    std::string fnameStr = [filename UTF8String];

    int top = lua_gettop(_L);
    int status = luaL_loadfile(_L, [path UTF8String]);
    if (status == LUA_OK) {
        status = lua_pcall(_L, 0, 0, 0);
    }

    BOOL ok = (status == LUA_OK);
    std::string errMsg;
    if (!ok) {
        const char *e = lua_tostring(_L, -1);
        errMsg = e ? e : "Unknown Lua error";
        AppendConsoleLog("[Script Error] " + fnameStr + ": " + errMsg);
    } else {
        AppendConsoleLog("[Loaded] " + fnameStr);
    }
    lua_settop(_L, top);

    for (auto &sc : _scripts) {
        if (sc.filename == fnameStr) {
            sc.loaded = ok;
            sc.lastError = ok ? "" : errMsg;
            break;
        }
    }
    return ok;
}

- (void)setScript:(NSString *)filename enabled:(BOOL)enabled {
    if (enabled) {
        [self.disabledScripts removeObjectForKey:filename];
    } else {
        self.disabledScripts[filename] = @YES;
    }
    [self saveConfig];
    [self reloadAllScripts];
}

- (std::vector<ScriptEntry>)allScriptsStatus {
    std::lock_guard<std::recursive_mutex> lock(g_luaMutex);
    return _scripts;
}

- (void)executeLuaString:(NSString *)code {
    std::lock_guard<std::recursive_mutex> lock(g_luaMutex);
    if (!_L || !code) return;
    AppendConsoleLog(std::string("> ") + [code UTF8String]);
    int top = lua_gettop(_L);
    if (luaL_dostring(_L, [code UTF8String]) != LUA_OK) {
        const char *e = lua_tostring(_L, -1);
        AppendConsoleLog(std::string("[Exec Error] ") + (e ? e : "error"));
    }
    lua_settop(_L, top);
}

// ============================================================================
// 9. Тики, события, хуки и вызовы Lua коллбэков (без утечек стека!)
// ============================================================================
- (void)tickUpdate {
    std::lock_guard<std::recursive_mutex> lock(g_luaMutex);
    if (!_L) return;

    double now = CACurrentMediaTime();

    // 1. Планировщик lua_thread корутин
    for (size_t i = 0; i < g_luaThreads.size(); ) {
        LuaThreadTask &t = g_luaThreads[i];
        if (t.finished || !t.co) {
            if (t.threadRef != LUA_NOREF) luaL_unref(_L, LUA_REGISTRYINDEX, t.threadRef);
            g_luaThreads.erase(g_luaThreads.begin() + i);
            continue;
        }
        if (now >= t.wakeTime) {
            int nres = 0;
            int st = lua_resume(t.co, _L, 0, &nres);
            if (st == LUA_OK) {
                t.finished = true;
                luaL_unref(_L, LUA_REGISTRYINDEX, t.threadRef);
                g_luaThreads.erase(g_luaThreads.begin() + i);
                continue;
            } else if (st == LUA_YIELD) {
                if (nres > 0) lua_pop(t.co, nres);
            } else {
                const char *err = lua_tostring(t.co, -1);
                AppendConsoleLog(std::string("[Thread Error] ") + (err ? err : "unknown"));
                luaL_unref(_L, LUA_REGISTRYINDEX, t.threadRef);
                g_luaThreads.erase(g_luaThreads.begin() + i);
                continue;
            }
        }
        i++;
    }

    // 2. Глобальный коллбэк onUpdate()
    int top = lua_gettop(_L);
    lua_getglobal(_L, "onUpdate");
    if (lua_isfunction(_L, -1)) {
        if (lua_pcall(_L, 0, 0, 0) != LUA_OK) {
            const char *err = lua_tostring(_L, -1);
            AppendConsoleLog(std::string("[onUpdate Error] ") + (err ? err : "unknown"));
        }
    }
    lua_settop(_L, top);
}

- (void)tickRender {
    std::lock_guard<std::recursive_mutex> lock(g_luaMutex);
    if (!_L) return;

    int top = lua_gettop(_L);

    // 1. Классический onRender / onDrawFrame
    for (const char *cbName : {"onRender", "onDrawFrame"}) {
        lua_getglobal(_L, cbName);
        if (lua_isfunction(_L, -1)) {
            if (lua_pcall(_L, 0, 0, 0) != LUA_OK) {
                const char *err = lua_tostring(_L, -1);
                AppendConsoleLog(std::string("[") + cbName + " Error] " + (err ? err : "unknown"));
            }
        }
        lua_settop(_L, top);
    }

    // 2. mimgui-стиль: imgui.OnFrame(condFn, drawFn)
    for (NSNumber *refNum in self.frameCallbackRefs) {
        int ref = [refNum intValue];
        lua_rawgeti(_L, LUA_REGISTRYINDEX, ref);
        if (lua_istable(_L, -1)) {
            lua_getfield(_L, -1, "cond");
            bool shouldDraw = false;
            if (lua_isfunction(_L, -1)) {
                if (lua_pcall(_L, 0, 1, 0) == LUA_OK) {
                    shouldDraw = lua_toboolean(_L, -1);
                }
            }
            lua_settop(_L, top + 1); // оставляем только таблицу фрейма на стеке

            if (shouldDraw) {
                lua_getfield(_L, -1, "draw");
                if (lua_isfunction(_L, -1)) {
                    if (lua_pcall(_L, 0, 0, 0) != LUA_OK) {
                        const char *err = lua_tostring(_L, -1);
                        AppendConsoleLog(std::string("[imgui.OnFrame Error] ") + (err ? err : "unknown"));
                    }
                }
            }
        }
        lua_settop(_L, top);
    }
}

// Исправленный метод без capture autoreleasing outText и без утечек стека Lua
- (BOOL)dispatchServerMessage:(uint32_t)color text:(NSString *)text outColor:(uint32_t *)outColor outText:(NSString **)outText {
    _inGameSession = YES;
    std::lock_guard<std::recursive_mutex> lock(g_luaMutex);
    if (!_L) return YES;

    __block BOOL allow = YES;
    __block uint32_t modColor = color;
    __block BOOL hasModColor = NO;
    __block NSString *modText = nil;

    int top = lua_gettop(_L);
    lua_getglobal(_L, "onServerMessage");
    if (lua_isfunction(_L, -1)) {
        lua_pushinteger(_L, (lua_Integer)color);
        lua_pushstring(_L, [text UTF8String]);
        if (lua_pcall(_L, 2, 1, 0) == LUA_OK) {
            if (lua_isboolean(_L, -1) && !lua_toboolean(_L, -1)) {
                allow = NO;
            } else if (lua_istable(_L, -1)) {
                lua_geti(_L, -1, 1);
                if (lua_isnumber(_L, -1)) {
                    modColor = (uint32_t)lua_tonumber(_L, -1);
                    hasModColor = YES;
                }
                lua_pop(_L, 1);

                lua_geti(_L, -1, 2);
                if (lua_isstring(_L, -1)) {
                    modText = SafeNSString(lua_tostring(_L, -1));
                }
                lua_pop(_L, 1);
            }
        } else {
            const char *err = lua_tostring(_L, -1);
            AppendConsoleLog(std::string("[onServerMessage Error] ") + (err ? err : "unknown"));
        }
    }
    lua_settop(_L, top);

    if (outColor && hasModColor) *outColor = modColor;
    if (outText && modText) *outText = modText;
    return allow;
}

- (BOOL)dispatchShowDialog:(int)dialogId style:(int)style title:(NSString *)title btn1:(NSString *)btn1 btn2:(NSString *)btn2 text:(NSString *)text {
    _inGameSession = YES;
    std::lock_guard<std::recursive_mutex> lock(g_luaMutex);
    if (!_L) return YES;

    __block BOOL allow = YES;
    int top = lua_gettop(_L);
    lua_getglobal(_L, "onShowDialog");
    if (lua_isfunction(_L, -1)) {
        lua_pushinteger(_L, dialogId);
        lua_pushinteger(_L, style);
        lua_pushstring(_L, [title UTF8String]);
        lua_pushstring(_L, [btn1 UTF8String]);
        lua_pushstring(_L, [btn2 UTF8String]);
        lua_pushstring(_L, [text UTF8String]);
        if (lua_pcall(_L, 6, 1, 0) == LUA_OK) {
            if (lua_isboolean(_L, -1) && !lua_toboolean(_L, -1)) {
                allow = NO;
            }
        } else {
            const char *err = lua_tostring(_L, -1);
            AppendConsoleLog(std::string("[onShowDialog Error] ") + (err ? err : "unknown"));
        }
    }
    lua_settop(_L, top);
    return allow;
}

- (BOOL)dispatchOutgoingText:(NSString *)text {
    if (!text || text.length == 0) return YES;

    // Встроенная команда /luasettings открывает/закрывает ImGui меню
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([[trimmed lowercaseString] isEqualToString:@"/luasettings"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            g_showImGuiMenu = !g_showImGuiMenu;
        });
        return NO;
    }

    std::lock_guard<std::recursive_mutex> lock(g_luaMutex);
    if (!_L) return YES;

    // Проверка кастомных команд sampRegisterChatCommand
    if ([trimmed hasPrefix:@"/"]) {
        NSString *withoutSlash = [trimmed substringFromIndex:1];
        NSRange sp = [withoutSlash rangeOfString:@" "];
        NSString *cmdName = (sp.location == NSNotFound) ? withoutSlash : [withoutSlash substringToIndex:sp.location];
        NSString *args = (sp.location == NSNotFound) ? @"" : [[withoutSlash substringFromIndex:sp.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *key = [cmdName lowercaseString];

        NSNumber *cmdRef = self.commandRefs[key];
        if (cmdRef) {
            int top = lua_gettop(_L);
            lua_rawgeti(_L, LUA_REGISTRYINDEX, [cmdRef intValue]);
            if (lua_isfunction(_L, -1)) {
                lua_pushstring(_L, [args UTF8String]);
                if (lua_pcall(_L, 1, 0, 0) != LUA_OK) {
                    const char *err = lua_tostring(_L, -1);
                    AppendConsoleLog(std::string("[Command /") + [key UTF8String] + " Error] " + (err ? err : "unknown"));
                }
            }
            lua_settop(_L, top);
            return NO;
        }

        // Коллбэк onSendCommand(cmd)
        int top = lua_gettop(_L);
        lua_getglobal(_L, "onSendCommand");
        if (lua_isfunction(_L, -1)) {
            lua_pushstring(_L, [trimmed UTF8String]);
            if (lua_pcall(_L, 1, 1, 0) == LUA_OK) {
                if (lua_isboolean(_L, -1) && !lua_toboolean(_L, -1)) {
                    lua_settop(_L, top);
                    return NO;
                }
            }
        }
        lua_settop(_L, top);
    } else {
        // Коллбэк onSendChat(text)
        int top = lua_gettop(_L);
        lua_getglobal(_L, "onSendChat");
        if (lua_isfunction(_L, -1)) {
            lua_pushstring(_L, [trimmed UTF8String]);
            if (lua_pcall(_L, 1, 1, 0) == LUA_OK) {
                if (lua_isboolean(_L, -1) && !lua_toboolean(_L, -1)) {
                    lua_settop(_L, top);
                    return NO;
                }
            }
        }
        lua_settop(_L, top);
    }

    return YES;
}

- (void)addChatMessageLocal:(NSString *)text color:(uint32_t)color {
    if (orig_AddChatMessage) {
        orig_AddChatMessage(color, [text UTF8String]);
    } else {
        AppendConsoleLog(std::string("[Chat] ") + [text UTF8String]);
    }
}

- (void)sendChatToGame:(NSString *)text {
    if (!text) return;
    if (![self dispatchOutgoingText:text]) return;
    AppendConsoleLog(std::string("[SendChat] ") + [text UTF8String]);
}

// ============================================================================
// 10. UNUserNotificationCenterDelegate (iOS 14+ без deprecated флагов)
// ============================================================================
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner |
                      UNNotificationPresentationOptionList |
                      UNNotificationPresentationOptionSound);
}

// ============================================================================
// 11. Установка оверлея, уведомлений и перехватчиков
// ============================================================================
- (void)attachOverlayIfNeeded {
    if (_overlayView && _overlayView.superview) return;
    UIWindow *win = GetActiveKeyWindow();
    if (!win) return;

    _overlayView = [[LoaderMetalOverlayView alloc] initWithFrame:win.bounds];
    _overlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [win addSubview:_overlayView];
    AppendConsoleLog("ImGui Metal Overlay attached");
}

- (void)installHooks {
    Fishhook::Rebinding rebs[] = {
        {"AddChatMessage", (void *)hooked_AddChatMessage, (void **)&orig_AddChatMessage},
        {"ShowDialog", (void *)hooked_ShowDialog, (void **)&orig_ShowDialog}
    };
    Fishhook::rebind_symbols(rebs, 2);
}

- (void)boot {
    [self ensureDirectories];
    [self loadConfig];
    [self installHooks];
    [self reloadAllScripts];

    UNUserNotificationCenter *unc = [UNUserNotificationCenter currentNotificationCenter];
    unc.delegate = self;
    [unc requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound) completionHandler:^(BOOL granted, NSError * _Nullable error) {}];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self attachOverlayIfNeeded];
        // Повторная проверка через 1.5с на случай, если игровое окно создаётся с задержкой
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self attachOverlayIfNeeded];
        });
    });
}

@end

// ============================================================================
// 12. Swizzling UITextField для перехвата ввода /luasettings и Lua-команд
// ============================================================================
static BOOL (*orig_textFieldShouldReturn)(id, SEL, UITextField *) = nullptr;

static BOOL swizzled_textFieldShouldReturn(id self, SEL _cmd, UITextField *textField) {
    NSString *txt = textField.text;
    if (txt.length > 0) {
        if (![[LoaderEngine shared] dispatchOutgoingText:txt]) {
            textField.text = @"";
            [textField resignFirstResponder];
            return NO;
        }
    }
    if (orig_textFieldShouldReturn) {
        return orig_textFieldShouldReturn(self, _cmd, textField);
    }
    return YES;
}

static void HookUITextFieldDelegates() {
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    numClasses = objc_getClassList(classes, numClasses);
    Protocol *proto = @protocol(UITextFieldDelegate);
    SEL sel = @selector(textFieldShouldReturn:);

    for (int i = 0; i < numClasses; i++) {
        Class cls = classes[i];
        if (class_conformsToProtocol(cls, proto)) {
            Method m = class_getInstanceMethod(cls, sel);
            if (m && !orig_textFieldShouldReturn) {
                orig_textFieldShouldReturn = (BOOL (*)(id, SEL, UITextField *))method_getImplementation(m);
                method_setImplementation(m, (IMP)swizzled_textFieldShouldReturn);
                break;
            }
        }
    }
    free(classes);
}

// ============================================================================
// 13. Точка входа dylib при инъекции в Arizona Mobile
// ============================================================================
__attribute__((constructor))
static void LoaderEntryPoint() {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            HookUITextFieldDelegates();
            [[LoaderEngine shared] boot];
        });
    }
}
