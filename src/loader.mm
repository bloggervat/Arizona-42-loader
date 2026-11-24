#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>

#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}

#include "imgui.h"
#include "imgui_impl_metal.h"

// ============================================================================
// 1. Учёт потребления RAM исключительно самим лоадером
// ============================================================================

static std::atomic<size_t> g_luaTrackedBytes{0};
static std::atomic<size_t> g_loaderExtraBytes{0};

static void *LoaderLuaAlloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    (void)ud;
    if (nsize == 0) {
        if (ptr != nullptr) {
            size_t cur = g_luaTrackedBytes.load(std::memory_order_relaxed);
            g_luaTrackedBytes.store(cur >= osize ? cur - osize : 0, std::memory_order_relaxed);
            free(ptr);
        }
        return nullptr;
    }
    void *newPtr = realloc(ptr, nsize);
    if (newPtr != nullptr) {
        size_t oldSz = (ptr != nullptr) ? osize : 0;
        if (nsize >= oldSz) {
            g_luaTrackedBytes.fetch_add(nsize - oldSz, std::memory_order_relaxed);
        } else {
            size_t diff = oldSz - nsize;
            size_t cur = g_luaTrackedBytes.load(std::memory_order_relaxed);
            g_luaTrackedBytes.store(cur >= diff ? cur - diff : 0, std::memory_order_relaxed);
        }
    }
    return newPtr;
}

static size_t GetLoaderDylibFootprintBytes() {
    Dl_info info;
    if (dladdr((const void *)&LoaderLuaAlloc, &info) == 0 || info.dli_fbase == nullptr) {
        return 0;
    }
    const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;
    if (header->magic != MH_MAGIC_64) return 0;

    size_t totalBytes = 0;
    const uint8_t *cmdPtr = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmdPtr;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cmdPtr;
            if (strcmp(seg->segname, "__TEXT") == 0 ||
                strcmp(seg->segname, "__DATA") == 0 ||
                strcmp(seg->segname, "__DATA_CONST") == 0) {
                totalBytes += (size_t)seg->vmsize;
            }
        }
        cmdPtr += lc->cmdsize;
    }
    return totalBytes;
}

struct LoaderMemoryStats {
    size_t luaBytes;
    size_t extraBytes;
    size_t dylibBytes;
    size_t totalBytes;
};

static LoaderMemoryStats GetLoaderMemoryStats() {
    static size_t cachedDylibBytes = GetLoaderDylibFootprintBytes();
    LoaderMemoryStats st;
    st.luaBytes = g_luaTrackedBytes.load(std::memory_order_relaxed);
    st.extraBytes = g_loaderExtraBytes.load(std::memory_order_relaxed);
    st.dylibBytes = cachedDylibBytes;
    st.totalBytes = st.luaBytes + st.extraBytes + st.dylibBytes;
    return st;
}

// ============================================================================
// 2. Структуры рендера, трейсеров, логов и состояния ImGui
// ============================================================================

struct TracerItem {
    std::string id;
    bool is3D = false;
    float x1 = 0.0f, y1 = 0.0f;
    float x2 = 0.0f, y2 = 0.0f;
    float wx = 0.0f, wy = 0.0f, wz = 0.0f;
    ImU32 color = IM_COL32(168, 85, 247, 230);
    float thickness = 2.0f;
    std::string label;
};

struct DrawCommandItem {
    enum Type { LINE, BOX, BOX_FILLED, CIRCLE, CIRCLE_FILLED, TEXT } type;
    float x1 = 0, y1 = 0, x2 = 0, y2 = 0;
    float radius = 0, thickness = 1.0f, rounding = 0.0f;
    int segments = 24;
    ImU32 color = IM_COL32_WHITE;
    bool shadow = true;
    std::string text;
};

struct LogEntry {
    int level; // 0 = INFO, 1 = LUA, 2 = ERROR
    std::string message;
};

static std::mutex g_renderMutex;
static std::vector<TracerItem> g_tracers;
static std::vector<DrawCommandItem> g_frameDrawCommands;

static std::mutex g_logMutex;
static std::vector<LogEntry> g_logs;
static const size_t kMaxLogs = 300;

static bool g_menuOpen = false;
static bool g_showRamHud = true;
static bool g_tracersEnabled = true;
static bool g_demoTracers = false;
static int g_tracerOriginMode = 0; // 0 = Низ экрана, 1 = Центр, 2 = Верх
static float g_tracerThickness = 2.0f;
static float g_tracerColor[4] = {0.66f, 0.33f, 0.97f, 0.90f};
static char g_luaEvalBuf[512] = "print('Hello from ImGui console!')";

// ============================================================================
// 3. Нативные мосты GTA SA / Arizona Mobile (dlsym + JNI + матрицы)
// ============================================================================

struct CVector {
    float x, y, z;
};

typedef void (*FnNativeSendChat)(const char *text);
typedef void (*FnAddChatMessage)(uint32_t color, const char *text);
typedef void *(*FnFindPlayerPed)(int playerId);
typedef bool (*FnCalcScreenCoors)(const CVector *in, CVector *out, float *outW, float *outH, bool checkMaxVisible, bool checkMinVisible);

static FnNativeSendChat g_fnSendChat = nullptr;
static FnAddChatMessage g_fnAddChatMessage = nullptr;
static FnFindPlayerPed g_fnFindPlayerPed = nullptr;
static FnCalcScreenCoors g_fnCalcScreenCoors = nullptr;

static void ResolveGameSymbols() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = RTLD_DEFAULT;

        const char *sendChatSyms[] = {
            "_Z14NativeSendChatPKc",
            "_ZN4Chat11SendMessageEPKc",
            "NativeSendChat",
            nullptr
        };
        for (int i = 0; sendChatSyms[i]; i++) {
            void *sym = dlsym(handle, sendChatSyms[i]);
            if (sym) { g_fnSendChat = (FnNativeSendChat)sym; break; }
        }

        const char *addChatSyms[] = {
            "_Z14AddChatMessagejPKc",
            "_ZN4Chat10AddMessageEjPKc",
            "AddChatMessage",
            nullptr
        };
        for (int i = 0; addChatSyms[i]; i++) {
            void *sym = dlsym(handle, addChatSyms[i]);
            if (sym) { g_fnAddChatMessage = (FnAddChatMessage)sym; break; }
        }

        g_fnFindPlayerPed = (FnFindPlayerPed)dlsym(handle, "_Z13FindPlayerPedi");
        g_fnCalcScreenCoors = (FnCalcScreenCoors)dlsym(handle, "_ZN7CSprite15CalcScreenCoorsERK7CVectorPS0_PfS4_bb");
    });
}

static bool ProjectWorldToScreen(float wx, float wy, float wz, float screenW, float screenH, float &sx, float &sy) {
    ResolveGameSymbols();
    if (g_fnCalcScreenCoors) {
        CVector inVec{wx, wy, wz};
        CVector outVec{0, 0, 0};
        float w = 0, h = 0;
        if (g_fnCalcScreenCoors(&inVec, &outVec, &w, &h, false, false) && outVec.z > 0.0f) {
            sx = outVec.x;
            sy = outVec.y;
            return true;
        }
    }
    // Безопасный fallback относительно координат игрока, если CSprite недоступен
    if (g_fnFindPlayerPed) {
        uint8_t *ped = (uint8_t *)g_fnFindPlayerPed(-1);
        if (ped) {
            // В RenderWare CEntity matrix обычно по смещению 0x14 (указатель на RwMatrix)
            uintptr_t matrixPtr = *(uintptr_t *)(ped + 0x14);
            if (matrixPtr > 0x100000) {
                float px = *(float *)(matrixPtr + 0x30);
                float py = *(float *)(matrixPtr + 0x34);
                float dx = wx - px;
                float dy = wy - py;
                float dist = sqrtf(dx * dx + dy * dy);
                if (dist > 0.01f) {
                    float angle = atan2f(dy, dx);
                    float radius = fminf(screenW, screenH) * 0.35f;
                    sx = screenW * 0.5f + cosf(angle) * radius;
                    sy = screenH * 0.5f - sinf(angle) * radius;
                    return true;
                }
            }
        }
    }
    return false;
}

static inline const char *SafeUTF8(NSString *s) {
    if (!s) return "";
    const char *c = [s UTF8String];
    return c ? c : "";
}

static inline ImU32 ARGBToImU32(uint32_t argb) {
    uint8_t a = (argb >> 24) & 0xFF;
    uint8_t r = (argb >> 16) & 0xFF;
    uint8_t g = (argb >> 8) & 0xFF;
    uint8_t b = argb & 0xFF;
    if (a == 0 && (r != 0 || g != 0 || b != 0)) a = 255;
    return IM_COL32(r, g, b, a);
}

static UIWindow *GetActiveKeyWindow() {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive &&
            [scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *win in ws.windows) {
                if (win.isKeyWindow) return win;
            }
            if (ws.windows.firstObject) return ws.windows.firstObject;
        }
    }
    return nil;
}

// ============================================================================
// 4. Объявление LoaderEngine
// ============================================================================

@interface LoaderEngine : NSObject <UNUserNotificationCenterDelegate>
@property (nonatomic, assign) lua_State *L;
@property (nonatomic, strong) NSRecursiveLock *luaLock;
@property (nonatomic, assign) BOOL inGameSession;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *commands;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *coroutines;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *imguiFrameCallbacks;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *scriptStates;
@property (nonatomic, strong) NSString *baseDir;
@property (nonatomic, strong) NSString *scriptsDir;
@property (nonatomic, strong) NSString *configDir;
@property (nonatomic, assign) NSTimeInterval lastTickTime;

+ (instancetype)shared;
- (void)boot;
- (void)reloadAllScripts;
- (void)toggleScript:(NSString *)filename enabled:(BOOL)enabled;
- (void)executeLuaString:(NSString *)code;
- (void)appendLog:(int)level message:(NSString *)msg;

- (BOOL)handleOutgoingInput:(NSString *)text;
- (BOOL)dispatchServerMessage:(uint32_t)color
                         text:(NSString *)text
                     outColor:(uint32_t *)outColor
                      outText:(NSString **)outText;
- (BOOL)dispatchShowDialog:(int)dialogId
                     style:(int)style
                     title:(NSString *)title
                      btn1:(NSString *)btn1
                      btn2:(NSString *)btn2
                      text:(NSString *)text;
- (void)tickFrame;
- (void)renderImGuiFrames;
@end

// ============================================================================
// 5. Lua C API функции (SAMP, Async, JSON, INI, ImGui, Render, Tracers)
// ============================================================================

static int l_print(lua_State *L) {
    int n = lua_gettop(L);
    NSMutableArray *parts = [NSMutableArray arrayWithCapacity:n];
    for (int i = 1; i <= n; i++) {
        size_t len = 0;
        const char *s = luaL_tolstring(L, i, &len);
        [parts addObject:(s ? [NSString stringWithUTF8String:s] : @"nil")];
        lua_pop(L, 1);
    }
    NSString *joined = [parts componentsJoinedByString:@"\t"];
    [[LoaderEngine shared] appendLog:1 message:joined];
    return 0;
}

static int l_isSampLoaded(lua_State *L) {
    lua_pushboolean(L, [LoaderEngine shared].inGameSession ? 1 : 0);
    return 1;
}

static int l_sampSendChat(lua_State *L) {
    const char *msg = luaL_checkstring(L, 1);
    ResolveGameSymbols();
    if (g_fnSendChat) {
        g_fnSendChat(msg);
    }
    return 0;
}

static int l_sampAddChatMessage(lua_State *L) {
    const char *msg = luaL_checkstring(L, 1);
    uint32_t color = (uint32_t)luaL_optinteger(L, 2, 0xFFFFFFFF);
    ResolveGameSymbols();
    if (g_fnAddChatMessage) {
        g_fnAddChatMessage(color, msg);
    } else {
        [[LoaderEngine shared] appendLog:1 message:[NSString stringWithFormat:@"[CHAT] %s", msg]];
    }
    return 0;
}

static int l_sampRegisterChatCommand(lua_State *L) {
    const char *cmd = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    NSString *cmdName = [[NSString stringWithUTF8String:cmd] lowercaseString];
    if ([cmdName hasPrefix:@"/"]) {
        cmdName = [cmdName substringFromIndex:1];
    }
    lua_pushvalue(L, 2);
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);
    LoaderEngine *eng = [LoaderEngine shared];
    NSNumber *oldRef = eng.commands[cmdName];
    if (oldRef) {
        luaL_unref(L, LUA_REGISTRYINDEX, [oldRef intValue]);
    }
    eng.commands[cmdName] = @(ref);
    return 0;
}

static int l_getScreenResolution(lua_State *L) {
    CGRect bounds = [UIScreen mainScreen].bounds;
    lua_pushnumber(L, bounds.size.width);
    lua_pushnumber(L, bounds.size.height);
    return 2;
}

static int l_getCharCoordinates(lua_State *L) {
    ResolveGameSymbols();
    if (g_fnFindPlayerPed) {
        uint8_t *ped = (uint8_t *)g_fnFindPlayerPed(-1);
        if (ped) {
            uintptr_t matrixPtr = *(uintptr_t *)(ped + 0x14);
            if (matrixPtr > 0x100000) {
                float x = *(float *)(matrixPtr + 0x30);
                float y = *(float *)(matrixPtr + 0x34);
                float z = *(float *)(matrixPtr + 0x38);
                lua_pushboolean(L, 1);
                lua_pushnumber(L, x);
                lua_pushnumber(L, y);
                lua_pushnumber(L, z);
                return 4;
            }
        }
    }
    lua_pushboolean(L, 0);
    lua_pushnumber(L, 0.0);
    lua_pushnumber(L, 0.0);
    lua_pushnumber(L, 0.0);
    return 4;
}

static int l_convert3DCoordsToScreen(lua_State *L) {
    float wx = (float)luaL_checknumber(L, 1);
    float wy = (float)luaL_checknumber(L, 2);
    float wz = (float)luaL_checknumber(L, 3);
    CGRect bounds = [UIScreen mainScreen].bounds;
    float sx = 0, sy = 0;
    bool ok = ProjectWorldToScreen(wx, wy, wz, bounds.size.width, bounds.size.height, sx, sy);
    lua_pushboolean(L, ok ? 1 : 0);
    lua_pushnumber(L, sx);
    lua_pushnumber(L, sy);
    return 3;
}

// --- Корутины: az.thread.create / lua_thread.create + wait(ms) ---

static int l_wait(lua_State *L) {
    lua_Number ms = luaL_checknumber(L, 1);
    NSTimeInterval wakeTime = CACurrentMediaTime() + (ms / 1000.0);
    lua_pushnumber(L, wakeTime);
    return lua_yield(L, 1);
}

static int l_threadCreate(lua_State *L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    lua_State *co = lua_newthread(L);
    int threadRef = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_pushvalue(L, 1);
    lua_xmove(L, co, 1);

    int status = lua_resume(co, L, 0, nullptr);
    if (status == LUA_YIELD) {
        NSTimeInterval wake = CACurrentMediaTime();
        if (lua_gettop(co) >= 1 && lua_isnumber(co, -1)) {
            wake = lua_tonumber(co, -1);
            lua_pop(co, 1);
        }
        // Сохраняем threadRef и wakeTime в таблицу Registry
        lua_newtable(L);
        lua_pushinteger(L, threadRef);
        lua_setfield(L, -2, "ref");
        lua_pushnumber(L, wake);
        lua_setfield(L, -2, "wake");
        int entryRef = luaL_ref(L, LUA_REGISTRYINDEX);
        [[LoaderEngine shared].coroutines addObject:@(entryRef)];
    } else {
        if (status != LUA_OK) {
            const char *err = lua_tostring(co, -1);
            [[LoaderEngine shared] appendLog:2 message:[NSString stringWithFormat:@"[Thread Error] %s", err ? err : "unknown"]];
        }
        luaL_unref(L, LUA_REGISTRYINDEX, threadRef);
    }
    return 0;
}

// --- Буфер обмена, вибрация, уведомления, HTTP, память ---

static int l_setClipboardText(lua_State *L) {
    const char *txt = luaL_checkstring(L, 1);
    [UIPasteboard generalPasteboard].string = [NSString stringWithUTF8String:txt];
    return 0;
}

static int l_getClipboardText(lua_State *L) {
    NSString *s = [UIPasteboard generalPasteboard].string ?: @"";
    lua_pushstring(L, SafeUTF8(s));
    return 1;
}

static int l_vibrate(lua_State *L) {
    int style = (int)luaL_optinteger(L, 1, 1);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImpactFeedbackStyle fbStyle = UIImpactFeedbackStyleMedium;
        if (style == 0) fbStyle = UIImpactFeedbackStyleLight;
        else if (style >= 2) fbStyle = UIImpactFeedbackStyleHeavy;
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:fbStyle];
        [gen prepare];
        [gen impactOccurred];
    });
    return 0;
}

static int l_notify(lua_State *L) {
    const char *title = luaL_checkstring(L, 1);
    const char *body = luaL_checkstring(L, 2);
    double delay = luaL_optnumber(L, 3, 0.5);
    if (delay < 0.1) delay = 0.1;

    NSString *nsTitle = [NSString stringWithUTF8String:title];
    NSString *nsBody = [NSString stringWithUTF8String:body];

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError * _Nullable error) {
        if (!granted || error) return;
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = nsTitle;
        content.body = nsBody;
        content.sound = [UNNotificationSound defaultSound];

        UNTimeIntervalNotificationTrigger *trigger =
            [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:delay repeats:NO];
        NSString *ident = [[NSUUID UUID] UUIDString];
        UNNotificationRequest *req =
            [UNNotificationRequest requestWithIdentifier:ident content:content trigger:trigger];
        [center addNotificationRequest:req withCompletionHandler:nil];
    }];
    return 0;
}

static int l_getLoaderMemory(lua_State *L) {
    LoaderMemoryStats st = GetLoaderMemoryStats();
    lua_pushinteger(L, (lua_Integer)st.totalBytes);
    lua_pushnumber(L, (double)st.totalBytes / (1024.0 * 1024.0));
    return 2;
}

static int l_asyncHttpRequest(lua_State *L) {
    const char *method = luaL_checkstring(L, 1);
    const char *urlStr = luaL_checkstring(L, 2);
    NSString *nsMethod = [[NSString stringWithUTF8String:method] uppercaseString];
    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:urlStr]];
    if (!url) return 0;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = nsMethod;
    req.timeoutInterval = 15.0;

    if (lua_istable(L, 3)) {
        lua_getfield(L, 3, "data");
        if (lua_isstring(L, -1)) {
            NSString *bodyStr = [NSString stringWithUTF8String:lua_tostring(L, -1)];
            req.HTTPBody = [bodyStr dataUsingEncoding:NSUTF8StringEncoding];
        }
        lua_pop(L, 1);

        lua_getfield(L, 3, "headers");
        if (lua_istable(L, -1)) {
            lua_pushnil(L);
            while (lua_next(L, -2) != 0) {
                if (lua_isstring(L, -2) && lua_isstring(L, -1)) {
                    NSString *k = [NSString stringWithUTF8String:lua_tostring(L, -2)];
                    NSString *v = [NSString stringWithUTF8String:lua_tostring(L, -1)];
                    [req setValue:v forHTTPHeaderField:k];
                }
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);
    }

    int okRef = LUA_NOREF;
    int errRef = LUA_NOREF;
    if (lua_isfunction(L, 4)) {
        lua_pushvalue(L, 4);
        okRef = luaL_ref(L, LUA_REGISTRYINDEX);
    }
    if (lua_isfunction(L, 5)) {
        lua_pushvalue(L, 5);
        errRef = luaL_ref(L, LUA_REGISTRYINDEX);
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData * _Nullable data,
                                                         NSURLResponse * _Nullable response,
                                                         NSError * _Nullable error) {
        LoaderEngine *eng = [LoaderEngine shared];
        [eng.luaLock lock];
        lua_State *LS = eng.L;
        if (LS) {
            int top = lua_gettop(LS);
            if (error) {
                if (errRef != LUA_NOREF) {
                    lua_rawgeti(LS, LUA_REGISTRYINDEX, errRef);
                    lua_pushstring(LS, SafeUTF8(error.localizedDescription));
                    if (lua_pcall(LS, 1, 0, 0) != LUA_OK) {
                        [eng appendLog:2 message:[NSString stringWithFormat:@"[HTTP ErrCb] %s", lua_tostring(LS, -1)]];
                    }
                }
            } else if (okRef != LUA_NOREF) {
                NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
                NSString *respStr = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
                if (!respStr) respStr = @"";
                lua_rawgeti(LS, LUA_REGISTRYINDEX, okRef);
                lua_newtable(LS);
                lua_pushinteger(LS, statusCode);
                lua_setfield(LS, -2, "status_code");
                lua_pushstring(LS, SafeUTF8(respStr));
                lua_setfield(LS, -2, "text");
                if (lua_pcall(LS, 1, 0, 0) != LUA_OK) {
                    [eng appendLog:2 message:[NSString stringWithFormat:@"[HTTP OkCb] %s", lua_tostring(LS, -1)]];
                }
            }
            if (okRef != LUA_NOREF) luaL_unref(LS, LUA_REGISTRYINDEX, okRef);
            if (errRef != LUA_NOREF) luaL_unref(LS, LUA_REGISTRYINDEX, errRef);
            lua_settop(LS, top);
        }
        [eng.luaLock unlock];
    }] resume];

    return 0;
}

// --- JSON (cjson / encodeJson / decodeJson) ---

static id LuaTableToObjC(lua_State *L, int idx) {
    idx = lua_absindex(L, idx);
    int type = lua_type(L, idx);
    if (type == LUA_TBOOLEAN) return @(lua_toboolean(L, idx) != 0);
    if (type == LUA_TNUMBER) return @(lua_tonumber(L, idx));
    if (type == LUA_TSTRING) return [NSString stringWithUTF8String:lua_tostring(L, idx)] ?: @"";
    if (type != LUA_TTABLE) return [NSNull null];

    // Проверяем, является ли таблица массивом 1..N
    lua_Integer maxIdx = 0;
    lua_Integer count = 0;
    bool isArray = true;
    lua_pushnil(L);
    while (lua_next(L, idx) != 0) {
        if (lua_type(L, -2) == LUA_TNUMBER && lua_isinteger(L, -2)) {
            lua_Integer k = lua_tointeger(L, -2);
            if (k > 0) {
                if (k > maxIdx) maxIdx = k;
                count++;
            } else {
                isArray = false;
            }
        } else {
            isArray = false;
        }
        lua_pop(L, 1);
    }

    if (isArray && count > 0 && maxIdx == count) {
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
        for (lua_Integer i = 1; i <= count; i++) {
            lua_geti(L, idx, i);
            [arr addObject:LuaTableToObjC(L, -1)];
            lua_pop(L, 1);
        }
        return arr;
    }

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    lua_pushnil(L);
    while (lua_next(L, idx) != 0) {
        const char *kStr = lua_tostring(L, -2);
        if (kStr) {
            dict[[NSString stringWithUTF8String:kStr]] = LuaTableToObjC(L, -1);
        }
        lua_pop(L, 1);
    }
    return dict;
}

static void PushObjCToLua(lua_State *L, id obj) {
    if (!obj || obj == [NSNull null]) {
        lua_pushnil(L);
    } else if ([obj isKindOfClass:[NSNumber class]]) {
        NSNumber *num = (NSNumber *)obj;
        if (strcmp([num objCType], @encode(BOOL)) == 0 ||
            strcmp([num objCType], @encode(char)) == 0) {
            lua_pushboolean(L, [num boolValue] ? 1 : 0);
        } else {
            lua_pushnumber(L, [num doubleValue]);
        }
    } else if ([obj isKindOfClass:[NSString class]]) {
        lua_pushstring(L, SafeUTF8((NSString *)obj));
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)obj;
        lua_createtable(L, (int)arr.count, 0);
        for (NSUInteger i = 0; i < arr.count; i++) {
            PushObjCToLua(L, arr[i]);
            lua_seti(L, -2, (lua_Integer)(i + 1));
        }
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        lua_createtable(L, 0, (int)dict.count);
        for (id key in dict) {
            PushObjCToLua(L, dict[key]);
            lua_setfield(L, -2, SafeUTF8([key description]));
        }
    } else {
        lua_pushnil(L);
    }
}

static int l_encodeJson(lua_State *L) {
    id obj = LuaTableToObjC(L, 1);
    if (![NSJSONSerialization isValidJSONObject:obj]) {
        lua_pushstring(L, "{}");
        return 1;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    NSString *str = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
    lua_pushstring(L, SafeUTF8(str));
    return 1;
}

static int l_decodeJson(lua_State *L) {
    const char *raw = luaL_checkstring(L, 1);
    NSData *data = [[NSString stringWithUTF8String:raw] dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        lua_pushnil(L);
        return 1;
    }
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];
    PushObjCToLua(L, obj);
    return 1;
}

// --- Render & Tracers Lua API ---

static int l_renderDrawLine(lua_State *L) {
    DrawCommandItem cmd;
    cmd.type = DrawCommandItem::LINE;
    cmd.x1 = (float)luaL_checknumber(L, 1);
    cmd.y1 = (float)luaL_checknumber(L, 2);
    cmd.x2 = (float)luaL_checknumber(L, 3);
    cmd.y2 = (float)luaL_checknumber(L, 4);
    cmd.thickness = (float)luaL_optnumber(L, 5, 1.5);
    cmd.color = ARGBToImU32((uint32_t)luaL_optinteger(L, 6, 0xFFFFFFFF));
    std::lock_guard<std::mutex> lock(g_renderMutex);
    g_frameDrawCommands.push_back(std::move(cmd));
    return 0;
}

static int l_renderDrawBox(lua_State *L) {
    DrawCommandItem cmd;
    cmd.type = DrawCommandItem::BOX_FILLED;
    cmd.x1 = (float)luaL_checknumber(L, 1);
    cmd.y1 = (float)luaL_checknumber(L, 2);
    cmd.x2 = cmd.x1 + (float)luaL_checknumber(L, 3);
    cmd.y2 = cmd.y1 + (float)luaL_checknumber(L, 4);
    cmd.color = ARGBToImU32((uint32_t)luaL_optinteger(L, 5, 0x80000000));
    cmd.rounding = (float)luaL_optnumber(L, 6, 0.0);
    std::lock_guard<std::mutex> lock(g_renderMutex);
    g_frameDrawCommands.push_back(std::move(cmd));
    return 0;
}

static int l_renderDrawBoxBorder(lua_State *L) {
    DrawCommandItem cmd;
    cmd.type = DrawCommandItem::BOX;
    cmd.x1 = (float)luaL_checknumber(L, 1);
    cmd.y1 = (float)luaL_checknumber(L, 2);
    cmd.x2 = cmd.x1 + (float)luaL_checknumber(L, 3);
    cmd.y2 = cmd.y1 + (float)luaL_checknumber(L, 4);
    cmd.color = ARGBToImU32((uint32_t)luaL_optinteger(L, 5, 0xFFFFFFFF));
    cmd.thickness = (float)luaL_optnumber(L, 6, 1.5);
    cmd.rounding = (float)luaL_optnumber(L, 7, 0.0);
    std::lock_guard<std::mutex> lock(g_renderMutex);
    g_frameDrawCommands.push_back(std::move(cmd));
    return 0;
}

static int l_renderDrawCircle(lua_State *L) {
    DrawCommandItem cmd;
    cmd.type = DrawCommandItem::CIRCLE;
    cmd.x1 = (float)luaL_checknumber(L, 1);
    cmd.y1 = (float)luaL_checknumber(L, 2);
    cmd.radius = (float)luaL_checknumber(L, 3);
    cmd.color = ARGBToImU32((uint32_t)luaL_optinteger(L, 4, 0xFFFFFFFF));
    cmd.thickness = (float)luaL_optnumber(L, 5, 1.5);
    cmd.segments = (int)luaL_optinteger(L, 6, 32);
    std::lock_guard<std::mutex> lock(g_renderMutex);
    g_frameDrawCommands.push_back(std::move(cmd));
    return 0;
}

static int l_renderDrawCircleFilled(lua_State *L) {
    DrawCommandItem cmd;
    cmd.type = DrawCommandItem::CIRCLE_FILLED;
    cmd.x1 = (float)luaL_checknumber(L, 1);
    cmd.y1 = (float)luaL_checknumber(L, 2);
    cmd.radius = (float)luaL_checknumber(L, 3);
    cmd.color = ARGBToImU32((uint32_t)luaL_optinteger(L, 4, 0xFFFFFFFF));
    cmd.segments = (int)luaL_optinteger(L, 5, 32);
    std::lock_guard<std::mutex> lock(g_renderMutex);
    g_frameDrawCommands.push_back(std::move(cmd));
    return 0;
}

static int l_renderDrawText(lua_State *L) {
    DrawCommandItem cmd;
    cmd.type = DrawCommandItem::TEXT;
    cmd.x1 = (float)luaL_checknumber(L, 1);
    cmd.y1 = (float)luaL_checknumber(L, 2);
    cmd.text = luaL_checkstring(L, 3);
    cmd.color = ARGBToImU32((uint32_t)luaL_optinteger(L, 4, 0xFFFFFFFF));
    cmd.shadow = lua_isnone(L, 5) ? true : (lua_toboolean(L, 5) != 0);
    std::lock_guard<std::mutex> lock(g_renderMutex);
    g_frameDrawCommands.push_back(std::move(cmd));
    return 0;
}

static int l_renderAddTracer(lua_State *L) {
    std::string id = luaL_checkstring(L, 1);
    TracerItem tr;
    tr.id = id;
    tr.is3D = false;
    tr.x1 = (float)luaL_checknumber(L, 2);
    tr.y1 = (float)luaL_checknumber(L, 3);
    tr.x2 = (float)luaL_checknumber(L, 4);
    tr.y2 = (float)luaL_checknumber(L, 5);
    tr.color = ARGBToImU32((uint32_t)luaL_optinteger(L, 6, 0xFFA855F7));
    tr.thickness = (float)luaL_optnumber(L, 7, 2.0);
    tr.label = luaL_optstring(L, 8, "");

    std::lock_guard<std::mutex> lock(g_renderMutex);
    for (auto &existing : g_tracers) {
        if (existing.id == id) {
            existing = std::move(tr);
            return 0;
        }
    }
    g_tracers.push_back(std::move(tr));
    return 0;
}

static int l_renderAddWorldTracer(lua_State *L) {
    std::string id = luaL_checkstring(L, 1);
    TracerItem tr;
    tr.id = id;
    tr.is3D = true;
    tr.wx = (float)luaL_checknumber(L, 2);
    tr.wy = (float)luaL_checknumber(L, 3);
    tr.wz = (float)luaL_checknumber(L, 4);
    tr.color = ARGBToImU32((uint32_t)luaL_optinteger(L, 5, 0xFFA855F7));
    tr.thickness = (float)luaL_optnumber(L, 6, 2.0);
    tr.label = luaL_optstring(L, 7, "");

    std::lock_guard<std::mutex> lock(g_renderMutex);
    for (auto &existing : g_tracers) {
        if (existing.id == id) {
            existing = std::move(tr);
            return 0;
        }
    }
    g_tracers.push_back(std::move(tr));
    return 0;
}

static int l_renderRemoveTracer(lua_State *L) {
    std::string id = luaL_checkstring(L, 1);
    std::lock_guard<std::mutex> lock(g_renderMutex);
    g_tracers.erase(
        std::remove_if(g_tracers.begin(), g_tracers.end(),
                       [&](const TracerItem &t) { return t.id == id; }),
        g_tracers.end());
    return 0;
}

static int l_renderClearTracers(lua_State *L) {
    (void)L;
    std::lock_guard<std::mutex> lock(g_renderMutex);
    g_tracers.clear();
    return 0;
}

static int l_renderSetTracersEnabled(lua_State *L) {
    g_tracersEnabled = (lua_toboolean(L, 1) != 0);
    return 0;
}

// --- ImGui Lua Bindings (mimgui-совместимый API) ---

static int l_imguiOnFrame(lua_State *L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    luaL_checktype(L, 2, LUA_TFUNCTION);

    lua_newtable(L);
    lua_pushvalue(L, 1);
    lua_setfield(L, -2, "cond");
    lua_pushvalue(L, 2);
    lua_setfield(L, -2, "draw");
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);
    [[LoaderEngine shared].imguiFrameCallbacks addObject:@(ref)];
    return 0;
}

static int l_imguiBegin(lua_State *L) {
    const char *name = luaL_checkstring(L, 1);
    bool hasOpenArg = !lua_isnoneornil(L, 2);
    bool pOpen = hasOpenArg ? (lua_toboolean(L, 2) != 0) : true;
    ImGuiWindowFlags flags = (ImGuiWindowFlags)luaL_optinteger(L, 3, 0);

    bool visible = ImGui::Begin(name, hasOpenArg ? &pOpen : nullptr, flags);
    lua_pushboolean(L, visible ? 1 : 0);
    if (hasOpenArg) {
        lua_pushboolean(L, pOpen ? 1 : 0);
        return 2;
    }
    return 1;
}

static int l_imguiEnd(lua_State *L) {
    (void)L;
    ImGui::End();
    return 0;
}

static int l_imguiText(lua_State *L) {
    const char *txt = luaL_checkstring(L, 1);
    ImGui::TextUnformatted(txt);
    return 0;
}

static int l_imguiTextColored(lua_State *L) {
    float r = (float)luaL_checknumber(L, 1);
    float g = (float)luaL_checknumber(L, 2);
    float b = (float)luaL_checknumber(L, 3);
    float a = (float)luaL_checknumber(L, 4);
    const char *txt = luaL_checkstring(L, 5);
    ImGui::TextColored(ImVec4(r, g, b, a), "%s", txt);
    return 0;
}

static int l_imguiTextWrapped(lua_State *L) {
    const char *txt = luaL_checkstring(L, 1);
    ImGui::TextWrapped("%s", txt);
    return 0;
}

static int l_imguiButton(lua_State *L) {
    const char *label = luaL_checkstring(L, 1);
    float w = (float)luaL_optnumber(L, 2, 0.0);
    float h = (float)luaL_optnumber(L, 3, 0.0);
    lua_pushboolean(L, ImGui::Button(label, ImVec2(w, h)) ? 1 : 0);
    return 1;
}

static int l_imguiCheckbox(lua_State *L) {
    const char *label = luaL_checkstring(L, 1);
    bool val = lua_toboolean(L, 2) != 0;
    bool changed = ImGui::Checkbox(label, &val);
    lua_pushboolean(L, changed ? 1 : 0);
    lua_pushboolean(L, val ? 1 : 0);
    return 2;
}

static int l_imguiSliderFloat(lua_State *L) {
    const char *label = luaL_checkstring(L, 1);
    float val = (float)luaL_checknumber(L, 2);
    float vMin = (float)luaL_checknumber(L, 3);
    float vMax = (float)luaL_checknumber(L, 4);
    const char *fmt = luaL_optstring(L, 5, "%.2f");
    bool changed = ImGui::SliderFloat(label, &val, vMin, vMax, fmt);
    lua_pushboolean(L, changed ? 1 : 0);
    lua_pushnumber(L, val);
    return 2;
}

static int l_imguiSliderInt(lua_State *L) {
    const char *label = luaL_checkstring(L, 1);
    int val = (int)luaL_checkinteger(L, 2);
    int vMin = (int)luaL_checkinteger(L, 3);
    int vMax = (int)luaL_checkinteger(L, 4);
    bool changed = ImGui::SliderInt(label, &val, vMin, vMax);
    lua_pushboolean(L, changed ? 1 : 0);
    lua_pushinteger(L, val);
    return 2;
}

static int l_imguiInputText(lua_State *L) {
    const char *label = luaL_checkstring(L, 1);
    const char *initStr = luaL_optstring(L, 2, "");
    size_t maxLen = (size_t)luaL_optinteger(L, 3, 256);
    if (maxLen < 64) maxLen = 64;
    if (maxLen > 4096) maxLen = 4096;

    std::vector<char> buf(maxLen, '\0');
    strncpy(buf.data(), initStr, maxLen - 1);
    bool changed = ImGui::InputText(label, buf.data(), maxLen);
    lua_pushboolean(L, changed ? 1 : 0);
    lua_pushstring(L, buf.data());
    return 2;
}

static int l_imguiSameLine(lua_State *L) {
    float offset = (float)luaL_optnumber(L, 1, 0.0);
    float spacing = (float)luaL_optnumber(L, 2, -1.0);
    ImGui::SameLine(offset, spacing);
    return 0;
}

static int l_imguiSeparator(lua_State *L) {
    (void)L;
    ImGui::Separator();
    return 0;
}

static int l_imguiSpacing(lua_State *L) {
    (void)L;
    ImGui::Spacing();
    return 0;
}

static int l_imguiSetNextWindowSize(lua_State *L) {
    float w = (float)luaL_checknumber(L, 1);
    float h = (float)luaL_checknumber(L, 2);
    ImGuiCond cond = (ImGuiCond)luaL_optinteger(L, 3, ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSize(ImVec2(w, h), cond);
    return 0;
}

static int l_imguiSetNextWindowPos(lua_State *L) {
    float x = (float)luaL_checknumber(L, 1);
    float y = (float)luaL_checknumber(L, 2);
    ImGuiCond cond = (ImGuiCond)luaL_optinteger(L, 3, ImGuiCond_FirstUseEver);
    float px = (float)luaL_optnumber(L, 4, 0.0);
    float py = (float)luaL_optnumber(L, 5, 0.0);
    ImGui::SetNextWindowPos(ImVec2(x, y), cond, ImVec2(px, py));
    return 0;
}

static int l_imguiBeginChild(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    float w = (float)luaL_optnumber(L, 2, 0.0);
    float h = (float)luaL_optnumber(L, 3, 0.0);
    bool border = lua_toboolean(L, 4) != 0;
    lua_pushboolean(L, ImGui::BeginChild(id, ImVec2(w, h), border) ? 1 : 0);
    return 1;
}

static int l_imguiEndChild(lua_State *L) {
    (void)L;
    ImGui::EndChild();
    return 0;
}

static int l_imguiGetIO(lua_State *L) {
    ImGuiIO &io = ImGui::GetIO();
    lua_newtable(L);
    lua_newtable(L);
    lua_pushnumber(L, io.DisplaySize.x);
    lua_setfield(L, -2, "x");
    lua_pushnumber(L, io.DisplaySize.y);
    lua_setfield(L, -2, "y");
    lua_setfield(L, -2, "DisplaySize");
    lua_pushnumber(L, io.Framerate);
    lua_setfield(L, -2, "Framerate");
    lua_pushboolean(L, io.WantCaptureMouse ? 1 : 0);
    lua_setfield(L, -2, "WantCaptureMouse");
    return 1;
}

// ============================================================================
// 6. Реализация LoaderEngine
// ============================================================================

@implementation LoaderEngine

+ (instancetype)shared {
    static LoaderEngine *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[LoaderEngine alloc] init];
    });
    return inst;
}

- (instancetype)init {
    if (self = [super init]) {
        _luaLock = [[NSRecursiveLock alloc] init];
        _commands = [NSMutableDictionary dictionary];
        _coroutines = [NSMutableArray array];
        _imguiFrameCallbacks = [NSMutableArray array];
        _scriptStates = [NSMutableDictionary dictionary];
        _lastTickTime = CACurrentMediaTime();

        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        _baseDir = [docs stringByAppendingPathComponent:@"arizonaloader"];
        _scriptsDir = [_baseDir stringByAppendingPathComponent:@"scripts"];
        _configDir = [_baseDir stringByAppendingPathComponent:@"config"];

        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:_scriptsDir withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:_configDir withIntermediateDirectories:YES attributes:nil error:nil];

        [self loadScriptStates];
        [UNUserNotificationCenter currentNotificationCenter].delegate = self;
    }
    return self;
}

- (NSString *)stateFilePath {
    return [self.configDir stringByAppendingPathComponent:@"scripts_state.json"];
}

- (void)loadScriptStates {
    NSData *data = [NSData dataWithContentsOfFile:[self stateFilePath]];
    if (!data) return;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) {
        [self.scriptStates addEntriesFromDictionary:obj];
    }
}

- (void)saveScriptStates {
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.scriptStates options:NSJSONWritingPrettyPrinted error:nil];
    if (data) {
        [data writeToFile:[self stateFilePath] atomically:YES];
    }
}

- (void)appendLog:(int)level message:(NSString *)msg {
    if (!msg) return;
    NSLog(@"[ArizonaLoader] %@", msg);
    std::lock_guard<std::mutex> lock(g_logMutex);
    if (g_logs.size() >= kMaxLogs) {
        g_logs.erase(g_logs.begin());
    }
    g_logs.push_back({level, std::string(SafeUTF8(msg))});
}

- (void)boot {
    [self reloadAllScripts];
}

- (void)registerLuaAPI:(lua_State *)L {
    // Базовые глобальные функции
    lua_register(L, "print", l_print);
    lua_register(L, "wait", l_wait);
    lua_register(L, "isSampLoaded", l_isSampLoaded);
    lua_register(L, "isSampAvailable", l_isSampLoaded);
    lua_register(L, "sampSendChat", l_sampSendChat);
    lua_register(L, "sampAddChatMessage", l_sampAddChatMessage);
    lua_register(L, "sampRegisterChatCommand", l_sampRegisterChatCommand);
    lua_register(L, "getScreenResolution", l_getScreenResolution);
    lua_register(L, "getCharCoordinates", l_getCharCoordinates);
    lua_register(L, "convert3DCoordsToScreen", l_convert3DCoordsToScreen);
    lua_register(L, "setClipboardText", l_setClipboardText);
    lua_register(L, "getClipboardText", l_getClipboardText);
    lua_register(L, "asyncHttpRequest", l_asyncHttpRequest);
    lua_register(L, "encodeJson", l_encodeJson);
    lua_register(L, "decodeJson", l_decodeJson);

    // cjson таблица
    lua_newtable(L);
    lua_pushcfunction(L, l_encodeJson);
    lua_setfield(L, -2, "encode");
    lua_pushcfunction(L, l_decodeJson);
    lua_setfield(L, -2, "decode");
    lua_setglobal(L, "cjson");

    // lua_thread таблица
    lua_newtable(L);
    lua_pushcfunction(L, l_threadCreate);
    lua_setfield(L, -2, "create");
    lua_setglobal(L, "lua_thread");

    // az таблица
    lua_newtable(L);
    lua_newtable(L);
    lua_pushcfunction(L, l_threadCreate);
    lua_setfield(L, -2, "create");
    lua_setfield(L, -2, "thread");
    lua_pushcfunction(L, l_vibrate);
    lua_setfield(L, -2, "vibrate");
    lua_pushcfunction(L, l_notify);
    lua_setfield(L, -2, "notify");
    lua_pushcfunction(L, l_getLoaderMemory);
    lua_setfield(L, -2, "getLoaderMemory");
    lua_setglobal(L, "az");

    // render таблица (рендер + трейсеры)
    lua_newtable(L);
    lua_pushcfunction(L, l_renderDrawLine);
    lua_setfield(L, -2, "drawLine");
    lua_pushcfunction(L, l_renderDrawBox);
    lua_setfield(L, -2, "drawBox");
    lua_pushcfunction(L, l_renderDrawBoxBorder);
    lua_setfield(L, -2, "drawBoxBorder");
    lua_pushcfunction(L, l_renderDrawCircle);
    lua_setfield(L, -2, "drawCircle");
    lua_pushcfunction(L, l_renderDrawCircleFilled);
    lua_setfield(L, -2, "drawCircleFilled");
    lua_pushcfunction(L, l_renderDrawText);
    lua_setfield(L, -2, "drawText");
    lua_pushcfunction(L, l_renderAddTracer);
    lua_setfield(L, -2, "addTracer");
    lua_pushcfunction(L, l_renderAddWorldTracer);
    lua_setfield(L, -2, "addWorldTracer");
    lua_pushcfunction(L, l_renderRemoveTracer);
    lua_setfield(L, -2, "removeTracer");
    lua_pushcfunction(L, l_renderClearTracers);
    lua_setfield(L, -2, "clearTracers");
    lua_pushcfunction(L, l_renderSetTracersEnabled);
    lua_setfield(L, -2, "setTracersEnabled");
    lua_setglobal(L, "render");

    // imgui таблица
    lua_newtable(L);
    lua_pushcfunction(L, l_imguiOnFrame);
    lua_setfield(L, -2, "OnFrame");
    lua_pushcfunction(L, l_imguiBegin);
    lua_setfield(L, -2, "Begin");
    lua_pushcfunction(L, l_imguiEnd);
    lua_setfield(L, -2, "End");
    lua_pushcfunction(L, l_imguiText);
    lua_setfield(L, -2, "Text");
    lua_pushcfunction(L, l_imguiTextColored);
    lua_setfield(L, -2, "TextColored");
    lua_pushcfunction(L, l_imguiTextWrapped);
    lua_setfield(L, -2, "TextWrapped");
    lua_pushcfunction(L, l_imguiButton);
    lua_setfield(L, -2, "Button");
    lua_pushcfunction(L, l_imguiCheckbox);
    lua_setfield(L, -2, "Checkbox");
    lua_pushcfunction(L, l_imguiSliderFloat);
    lua_setfield(L, -2, "SliderFloat");
    lua_pushcfunction(L, l_imguiSliderInt);
    lua_setfield(L, -2, "SliderInt");
    lua_pushcfunction(L, l_imguiInputText);
    lua_setfield(L, -2, "InputText");
    lua_pushcfunction(L, l_imguiSameLine);
    lua_setfield(L, -2, "SameLine");
    lua_pushcfunction(L, l_imguiSeparator);
    lua_setfield(L, -2, "Separator");
    lua_pushcfunction(L, l_imguiSpacing);
    lua_setfield(L, -2, "Spacing");
    lua_pushcfunction(L, l_imguiSetNextWindowSize);
    lua_setfield(L, -2, "SetNextWindowSize");
    lua_pushcfunction(L, l_imguiSetNextWindowPos);
    lua_setfield(L, -2, "SetNextWindowPos");
    lua_pushcfunction(L, l_imguiBeginChild);
    lua_setfield(L, -2, "BeginChild");
    lua_pushcfunction(L, l_imguiEndChild);
    lua_setfield(L, -2, "EndChild");
    lua_pushcfunction(L, l_imguiGetIO);
    lua_setfield(L, -2, "GetIO");

    // Флаги ImGuiWindowFlags / ImGuiCond
    lua_newtable(L);
    lua_pushinteger(L, ImGuiWindowFlags_NoTitleBar); lua_setfield(L, -2, "NoTitleBar");
    lua_pushinteger(L, ImGuiWindowFlags_NoResize); lua_setfield(L, -2, "NoResize");
    lua_pushinteger(L, ImGuiWindowFlags_NoMove); lua_setfield(L, -2, "NoMove");
    lua_pushinteger(L, ImGuiWindowFlags_NoCollapse); lua_setfield(L, -2, "NoCollapse");
    lua_pushinteger(L, ImGuiWindowFlags_AlwaysAutoResize); lua_setfield(L, -2, "AlwaysAutoResize");
    lua_pushinteger(L, ImGuiWindowFlags_NoBackground); lua_setfield(L, -2, "NoBackground");
    lua_setfield(L, -2, "WindowFlags");

    lua_newtable(L);
    lua_pushinteger(L, ImGuiCond_Always); lua_setfield(L, -2, "Always");
    lua_pushinteger(L, ImGuiCond_Once); lua_setfield(L, -2, "Once");
    lua_pushinteger(L, ImGuiCond_FirstUseEver); lua_setfield(L, -2, "FirstUseEver");
    lua_setfield(L, -2, "Cond");

    lua_setglobal(L, "imgui");

    // Настраиваем package.path для require(...) в папке scripts/lib
    NSString *pkgSetup = [NSString stringWithFormat:
        @"package.path = '%@/?.lua;%@/lib/?.lua;' .. package.path\n"
         "inicfg = {\n"
         "  load = function(def, fname)\n"
         "    local p = '%@/' .. (fname or 'settings.ini')\n"
         "    local f = io.open(p, 'r')\n"
         "    if not f then return def or {} end\n"
         "    local res = def or {}\n"
         "    local sec = 'main'\n"
         "    for line in f:lines() do\n"
         "      local s = line:match('^%%[(.-)%%]$')\n"
         "      if s then sec = s; res[sec] = res[sec] or {} else\n"
         "        local k, v = line:match('^([^=]+)=(.*)$')\n"
         "        if k and v then\n"
         "          k = k:match('^%%s*(.-)%%s*$'); v = v:match('^%%s*(.-)%%s*$')\n"
         "          if v == 'true' then v = true elseif v == 'false' then v = false elseif tonumber(v) then v = tonumber(v) end\n"
         "          res[sec] = res[sec] or {}; res[sec][k] = v\n"
         "        end\n"
         "      end\n"
         "    end\n"
         "    f:close(); return res\n"
         "  end,\n"
         "  save = function(tbl, fname)\n"
         "    local p = '%@/' .. (fname or 'settings.ini')\n"
         "    local f = io.open(p, 'w')\n"
         "    if not f then return false end\n"
         "    for sec, kv in pairs(tbl) do\n"
         "      if type(kv) == 'table' then\n"
         "        f:write('[' .. tostring(sec) .. ']\\n')\n"
         "        for k, v in pairs(kv) do f:write(tostring(k) .. '=' .. tostring(v) .. '\\n') end\n"
         "      end\n"
         "    end\n"
         "    f:close(); return true\n"
         "  end\n"
         "}",
        self.scriptsDir, self.scriptsDir, self.configDir, self.configDir];

    if (luaL_dostring(L, SafeUTF8(pkgSetup)) != LUA_OK) {
        [self appendLog:2 message:[NSString stringWithFormat:@"[Bootstrap Error] %s", lua_tostring(L, -1)]];
        lua_pop(L, 1);
    }
}

- (void)reloadAllScripts {
    [self.luaLock lock];

    [self.commands removeAllObjects];
    [self.coroutines removeAllObjects];
    [self.imguiFrameCallbacks removeAllObjects];

    if (_L) {
        lua_close(_L);
        _L = nullptr;
        g_luaTrackedBytes.store(0, std::memory_order_relaxed);
    }

    _L = lua_newstate(LoaderLuaAlloc, nullptr);
    luaL_openlibs(_L);
    [self registerLuaAPI:_L];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *files = [[fm contentsOfDirectoryAtPath:self.scriptsDir error:nil]
                                  sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

    int loadedCount = 0;
    for (NSString *file in files) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"lua"]) continue;

        NSNumber *enabledObj = self.scriptStates[file];
        BOOL enabled = (enabledObj == nil) ? YES : [enabledObj boolValue];
        if (!enabled) continue;

        NSString *fullPath = [self.scriptsDir stringByAppendingPathComponent:file];
        int top = lua_gettop(_L);
        if (luaL_dofile(_L, SafeUTF8(fullPath)) != LUA_OK) {
            const char *err = lua_tostring(_L, -1);
            [self appendLog:2 message:[NSString stringWithFormat:@"[%@] %s", file, err ? err : "error"]];
        } else {
            loadedCount++;
            [self appendLog:0 message:[NSString stringWithFormat:@"Загружен скрипт: %@", file]];
        }
        lua_settop(_L, top);
    }

    [self appendLog:0 message:[NSString stringWithFormat:@"Lua VM перезагружена. Активных скриптов: %d", loadedCount]];
    [self.luaLock unlock];
}

- (void)toggleScript:(NSString *)filename enabled:(BOOL)enabled {
    self.scriptStates[filename] = @(enabled);
    [self saveScriptStates];
    [self reloadAllScripts];
}

- (void)executeLuaString:(NSString *)code {
    if (!code || code.length == 0) return;
    [self.luaLock lock];
    if (_L) {
        int top = lua_gettop(_L);
        if (luaL_dostring(_L, SafeUTF8(code)) != LUA_OK) {
            const char *err = lua_tostring(_L, -1);
            [self appendLog:2 message:[NSString stringWithFormat:@"[Console Error] %s", err ? err : "error"]];
        }
        lua_settop(_L, top);
    }
    [self.luaLock unlock];
}

// ============================================================================
// 7. Обработчики событий игры (с исправленными __block и ARC)
// ============================================================================

- (BOOL)handleOutgoingInput:(NSString *)text {
    self.inGameSession = YES;
    if (!text || text.length == 0) return NO;

    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![trimmed hasPrefix:@"/"]) return NO;

    NSString *withoutSlash = [trimmed substringFromIndex:1];
    NSRange spaceRange = [withoutSlash rangeOfString:@" "];
    NSString *cmdName = (spaceRange.location == NSNotFound)
        ? [withoutSlash lowercaseString]
        : [[withoutSlash substringToIndex:spaceRange.location] lowercaseString];
    NSString *args = (spaceRange.location == NSNotFound)
        ? @""
        : [withoutSlash substringFromIndex:spaceRange.location + 1];

    // Встроенная команда /luasettings открывает ImGui-интерфейс
    if ([cmdName isEqualToString:@"luasettings"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            g_menuOpen = !g_menuOpen;
        });
        return YES;
    }

    [self.luaLock lock];
    NSNumber *refNum = self.commands[cmdName];
    if (refNum && _L) {
        int top = lua_gettop(_L);
        lua_rawgeti(_L, LUA_REGISTRYINDEX, [refNum intValue]);
        lua_pushstring(_L, SafeUTF8(args));
        if (lua_pcall(_L, 1, 0, 0) != LUA_OK) {
            const char *err = lua_tostring(_L, -1);
            [self appendLog:2 message:[NSString stringWithFormat:@"[Cmd /%@] %s", cmdName, err ? err : "error"]];
        }
        lua_settop(_L, top);
        [self.luaLock unlock];
        return YES;
    }
    [self.luaLock unlock];
    return NO;
}

- (BOOL)dispatchServerMessage:(uint32_t)color
                         text:(NSString *)text
                     outColor:(uint32_t *)outColor
                      outText:(NSString **)outText {
    self.inGameSession = YES;
    if (!text) return YES;

    [self.luaLock lock];
    if (!_L) {
        [self.luaLock unlock];
        return YES;
    }

    __block BOOL allow = YES;
    __block uint32_t modifiedColor = color;
    __block NSString *modifiedText = nil;

    int top = lua_gettop(_L);
    auto invokeHandler = ^() {
        lua_pushinteger(_L, color);
        lua_pushstring(_L, SafeUTF8(text));
        if (lua_pcall(_L, 2, 1, 0) == LUA_OK) {
            if (lua_isboolean(_L, -1) && !lua_toboolean(_L, -1)) {
                allow = NO;
            } else if (lua_istable(_L, -1)) {
                lua_geti(_L, -1, 1);
                if (lua_isinteger(_L, -1)) {
                    modifiedColor = (uint32_t)lua_tointeger(_L, -1);
                }
                lua_pop(_L, 1);

                lua_geti(_L, -1, 2);
                if (lua_isstring(_L, -1)) {
                    const char *s = lua_tostring(_L, -1);
                    if (s) modifiedText = [NSString stringWithUTF8String:s];
                }
                lua_pop(_L, 1);
            }
        } else {
            const char *err = lua_tostring(_L, -1);
            [self appendLog:2 message:[NSString stringWithFormat:@"[onServerMessage] %s", err ? err : "error"]];
        }
        lua_pop(_L, 1);
    };

    lua_getglobal(_L, "onServerMessage");
    if (lua_isfunction(_L, -1)) {
        invokeHandler();
    } else {
        lua_pop(_L, 1);
    }

    lua_settop(_L, top);
    [self.luaLock unlock];

    if (outColor) *outColor = modifiedColor;
    if (outText && modifiedText) *outText = modifiedText;
    return allow;
}

- (BOOL)dispatchShowDialog:(int)dialogId
                     style:(int)style
                     title:(NSString *)title
                      btn1:(NSString *)btn1
                      btn2:(NSString *)btn2
                      text:(NSString *)text {
    self.inGameSession = YES;

    [self.luaLock lock];
    if (!_L) {
        [self.luaLock unlock];
        return YES;
    }

    __block BOOL allow = YES;
    int top = lua_gettop(_L);

    auto invokeDialog = ^() {
        lua_pushinteger(_L, dialogId);
        lua_pushinteger(_L, style);
        lua_pushstring(_L, SafeUTF8(title));
        lua_pushstring(_L, SafeUTF8(btn1));
        lua_pushstring(_L, SafeUTF8(btn2));
        lua_pushstring(_L, SafeUTF8(text));
        if (lua_pcall(_L, 6, 1, 0) == LUA_OK) {
            if (lua_isboolean(_L, -1) && !lua_toboolean(_L, -1)) {
                allow = NO;
            }
        } else {
            const char *err = lua_tostring(_L, -1);
            [self appendLog:2 message:[NSString stringWithFormat:@"[onShowDialog] %s", err ? err : "error"]];
        }
        lua_pop(_L, 1);
    };

    lua_getglobal(_L, "onShowDialog");
    if (lua_isfunction(_L, -1)) {
        invokeDialog();
    } else {
        lua_pop(_L, 1);
    }

    lua_settop(_L, top);
    [self.luaLock unlock];
    return allow;
}

- (void)tickFrame {
    [self.luaLock lock];
    if (!_L) {
        [self.luaLock unlock];
        return;
    }

    NSTimeInterval now = CACurrentMediaTime();
    NSTimeInterval dt = now - self.lastTickTime;
    self.lastTickTime = now;

    // 1. Планировщик корутин (wait)
    if (self.coroutines.count > 0) {
        NSMutableArray<NSNumber *> *alive = [NSMutableArray array];
        for (NSNumber *entryRefNum in self.coroutines) {
            int entryRef = [entryRefNum intValue];
            int top = lua_gettop(_L);
            lua_rawgeti(_L, LUA_REGISTRYINDEX, entryRef);
            if (!lua_istable(_L, -1)) {
                luaL_unref(_L, LUA_REGISTRYINDEX, entryRef);
                lua_settop(_L, top);
                continue;
            }
            lua_getfield(L, -1, "wake");
            NSTimeInterval wake = lua_tonumber(_L, -1);
            lua_pop(_L, 1);

            if (now < wake) {
                [alive addObject:entryRefNum];
                lua_settop(_L, top);
                continue;
            }

            lua_getfield(_L, -1, "ref");
            int threadRef = (int)lua_tointeger(_L, -1);
            lua_pop(_L, 1);

            lua_rawgeti(_L, LUA_REGISTRYINDEX, threadRef);
            lua_State *co = lua_tothread(_L, -1);
            lua_pop(_L, 1);

            if (co) {
                int status = lua_resume(co, _L, 0, nullptr);
                if (status == LUA_YIELD) {
                    NSTimeInterval nextWake = now;
                    if (lua_gettop(co) >= 1 && lua_isnumber(co, -1)) {
                        nextWake = lua_tonumber(co, -1);
                        lua_pop(co, 1);
                    }
                    lua_pushnumber(_L, nextWake);
                    lua_setfield(_L, -2, "wake");
                    [alive addObject:entryRefNum];
                } else {
                    if (status != LUA_OK) {
                        const char *err = lua_tostring(co, -1);
                        [self appendLog:2 message:[NSString stringWithFormat:@"[Thread Error] %s", err ? err : "error"]];
                    }
                    luaL_unref(_L, LUA_REGISTRYINDEX, threadRef);
                    luaL_unref(_L, LUA_REGISTRYINDEX, entryRef);
                }
            } else {
                luaL_unref(_L, LUA_REGISTRYINDEX, threadRef);
                luaL_unref(_L, LUA_REGISTRYINDEX, entryRef);
            }
            lua_settop(_L, top);
        }
        self.coroutines = alive;
    }

    // 2. Вызов onDraw() в Lua (если определён в скриптах)
    {
        std::lock_guard<std::mutex> lock(g_renderMutex);
        g_frameDrawCommands.clear();
    }
    int top = lua_gettop(_L);
    lua_getglobal(_L, "onDraw");
    if (lua_isfunction(_L, -1)) {
        lua_pushnumber(_L, dt);
        if (lua_pcall(_L, 1, 0, 0) != LUA_OK) {
            const char *err = lua_tostring(_L, -1);
            [self appendLog:2 message:[NSString stringWithFormat:@"[onDraw] %s", err ? err : "error"]];
        }
    }
    lua_settop(_L, top);

    [self.luaLock unlock];
}

- (void)renderImGuiFrames {
    [self.luaLock lock];
    if (!_L || self.imguiFrameCallbacks.count == 0) {
        [self.luaLock unlock];
        return;
    }

    for (NSNumber *refNum in [self.imguiFrameCallbacks copy]) {
        int ref = [refNum intValue];
        int top = lua_gettop(_L);
        lua_rawgeti(_L, LUA_REGISTRYINDEX, ref);
        if (!lua_istable(_L, -1)) {
            lua_settop(_L, top);
            continue;
        }
        lua_getfield(_L, -1, "cond");
        BOOL shouldDraw = NO;
        if (lua_isfunction(_L, -1) && lua_pcall(_L, 0, 1, 0) == LUA_OK) {
            shouldDraw = (lua_toboolean(_L, -1) != 0);
        }
        lua_settop(_L, top);

        if (shouldDraw) {
            lua_rawgeti(_L, LUA_REGISTRYINDEX, ref);
            lua_getfield(_L, -1, "draw");
            if (lua_isfunction(_L, -1)) {
                if (lua_pcall(_L, 0, 0, 0) != LUA_OK) {
                    const char *err = lua_tostring(_L, -1);
                    [self appendLog:2 message:[NSString stringWithFormat:@"[imgui.OnFrame] %s", err ? err : "error"]];
                }
            }
            lua_settop(_L, top);
        }
    }

    [self.luaLock unlock];
}

// iOS 14+ UNUserNotificationCenterDelegate (без устаревшего UNNotificationPresentationOptionAlert)
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    (void)center;
    (void)notification;
    completionHandler(UNNotificationPresentationOptionBanner |
                      UNNotificationPresentationOptionList |
                      UNNotificationPresentationOptionSound);
}

@end

// ============================================================================
// 8. Metal + Dear ImGui Overlay View (с прозрачными касаниями и клавиатурой iOS)
// ============================================================================

@interface LoaderOverlayView : MTKView <MTKViewDelegate, UIKeyInput>
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, assign) CFTimeInterval lastFrameTime;
@property (nonatomic, assign) BOOL keyboardActive;
@end

@implementation LoaderOverlayView

- (instancetype)initWithFrame:(CGRect)frame device:(id<MTLDevice>)device {
    if (self = [super initWithFrame:frame device:device]) {
        self.delegate = self;
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
        self.framebufferOnly = NO;
        self.preferredFramesPerSecond = 60;
        self.multipleTouchEnabled = YES;
        self.userInteractionEnabled = YES;

        _commandQueue = [device newCommandQueue];
        _lastFrameTime = CACurrentMediaTime();

        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        ImGuiIO &io = ImGui::GetIO();
        io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
        io.IniFilename = nullptr; // Не засоряем корень диска

        // Загружаем системный шрифт iOS с поддержкой кириллицы
        NSArray<NSString *> *fontCandidates = @[
            @"/System/Library/Fonts/Core/HelveticaNeue.ttc",
            @"/System/Library/Fonts/CoreAddition/Arial.ttf",
            @"/System/Library/Fonts/CoreUI/SFUI.ttf"
        ];
        bool fontLoaded = false;
        for (NSString *path in fontCandidates) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                ImFontConfig cfg;
                cfg.OversampleH = 2;
                cfg.OversampleV = 2;
                if (io.Fonts->AddFontFromFileTTF(SafeUTF8(path), 15.0f, &cfg, io.Fonts->GetGlyphRangesCyrillic()) != nullptr) {
                    fontLoaded = true;
                    break;
                }
            }
        }
        if (!fontLoaded) {
            io.Fonts->AddFontDefault();
        }

        // Тёмно-фиолетовая тема ImGui
        ImGui::StyleColorsDark();
        ImGuiStyle &style = ImGui::GetStyle();
        style.WindowRounding = 10.0f;
        style.FrameRounding = 6.0f;
        style.GrabRounding = 6.0f;
        style.TabRounding = 6.0f;
        style.WindowBorderSize = 1.0f;
        style.FramePadding = ImVec2(8.0f, 6.0f);
        style.ItemSpacing = ImVec2(8.0f, 7.0f);

        ImVec4 *colors = style.Colors;
        colors[ImGuiCol_WindowBg] = ImVec4(0.08f, 0.08f, 0.11f, 0.94f);
        colors[ImGuiCol_Border] = ImVec4(0.55f, 0.27f, 0.92f, 0.55f);
        colors[ImGuiCol_TitleBg] = ImVec4(0.11f, 0.09f, 0.16f, 1.00f);
        colors[ImGuiCol_TitleBgActive] = ImVec4(0.36f, 0.16f, 0.65f, 1.00f);
        colors[ImGuiCol_FrameBg] = ImVec4(0.14f, 0.14f, 0.19f, 1.00f);
        colors[ImGuiCol_FrameBgHovered] = ImVec4(0.24f, 0.18f, 0.36f, 1.00f);
        colors[ImGuiCol_FrameBgActive] = ImVec4(0.35f, 0.22f, 0.54f, 1.00f);
        colors[ImGuiCol_Button] = ImVec4(0.45f, 0.20f, 0.80f, 0.85f);
        colors[ImGuiCol_ButtonHovered] = ImVec4(0.56f, 0.28f, 0.92f, 1.00f);
        colors[ImGuiCol_ButtonActive] = ImVec4(0.36f, 0.14f, 0.68f, 1.00f);
        colors[ImGuiCol_CheckMark] = ImVec4(0.75f, 0.45f, 1.00f, 1.00f);
        colors[ImGuiCol_SliderGrab] = ImVec4(0.65f, 0.35f, 0.98f, 1.00f);
        colors[ImGuiCol_SliderGrabActive] = ImVec4(0.78f, 0.50f, 1.00f, 1.00f);
        colors[ImGuiCol_Tab] = ImVec4(0.16f, 0.13f, 0.23f, 1.00f);
        colors[ImGuiCol_TabHovered] = ImVec4(0.50f, 0.24f, 0.85f, 0.85f);
        colors[ImGuiCol_TabActive] = ImVec4(0.42f, 0.18f, 0.75f, 1.00f);
        colors[ImGuiCol_Header] = ImVec4(0.42f, 0.18f, 0.75f, 0.75f);
        colors[ImGuiCol_HeaderHovered] = ImVec4(0.52f, 0.25f, 0.88f, 0.90f);

        ImGui_ImplMetal_Init(device);

        // Жест 3 пальцами открывает/закрывает ImGui меню в любой момент
        UITapGestureRecognizer *threeFingerTap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onThreeFingerTap)];
        threeFingerTap.numberOfTouchesRequired = 3;
        threeFingerTap.cancelsTouchesInView = NO;
        [self addGestureRecognizer:threeFingerTap];
    }
    return self;
}

- (void)onThreeFingerTap {
    g_menuOpen = !g_menuOpen;
}

// Пропускаем касания в игру, если палец не попал ни в одно видимое окно ImGui
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    if (!ImGui::GetCurrentContext()) return nil;
    ImGuiIO &io = ImGui::GetIO();
    if (io.WantCaptureMouse || g_menuOpen) {
        if (g_menuOpen) return self;
    }
    // Проверяем попадание в окна, созданные скриптами через imgui.OnFrame
    ImVec2 pt((float)point.x, (float)point.y);
    if (ImGui::IsAnyItemHovered() || io.WantCaptureMouse) {
        return self;
    }
    // Проверяем прямоугольники всех активных окон (кроме Debug)
    ImGuiContext &g = *ImGui::GetCurrentContext();
    for (int i = 0; i < g.Windows.Size; i++) {
        ImGuiWindow *win = g.Windows[i];
        if (!win->Active || win->Hidden) continue;
        if (strcmp(win->Name, "Debug##Default") == 0) continue;
        if (pt.x >= win->Pos.x && pt.x <= win->Pos.x + win->Size.x &&
            pt.y >= win->Pos.y && pt.y <= win->Pos.y + win->Size.y) {
            return self;
        }
    }
    return nil;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    UITouch *touch = [touches anyObject];
    if (!touch) return;
    CGPoint p = [touch locationInView:self];
    ImGuiIO &io = ImGui::GetIO();
    io.AddMousePosEvent((float)p.x, (float)p.y);
    io.AddMouseButtonEvent(0, true);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    UITouch *touch = [touches anyObject];
    if (!touch) return;
    CGPoint p = [touch locationInView:self];
    ImGuiIO &io = ImGui::GetIO();
    io.AddMousePosEvent((float)p.x, (float)p.y);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    UITouch *touch = [touches anyObject];
    if (touch) {
        CGPoint p = [touch locationInView:self];
        ImGui::GetIO().AddMousePosEvent((float)p.x, (float)p.y);
    }
    ImGui::GetIO().AddMouseButtonEvent(0, false);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    ImGui::GetIO().AddMouseButtonEvent(0, false);
}

// Поддержка iOS-клавиатуры для ImGui::InputText
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }

- (void)insertText:(NSString *)text {
    if (!text) return;
    ImGuiIO &io = ImGui::GetIO();
    if ([text isEqualToString:@"\n"]) {
        io.AddKeyEvent(ImGuiKey_Enter, true);
        io.AddKeyEvent(ImGuiKey_Enter, false);
    } else {
        io.AddInputCharactersUTF8(SafeUTF8(text));
    }
}

- (void)deleteBackward {
    ImGuiIO &io = ImGui::GetIO();
    io.AddKeyEvent(ImGuiKey_Backspace, true);
    io.AddKeyEvent(ImGuiKey_Backspace, false);
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    (void)size;
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!rpd || !drawable) return;

    // Тик Lua корутин и onDraw()
    [[LoaderEngine shared] tickFrame];

    CFTimeInterval now = CACurrentMediaTime();
    float dt = (float)(now - self.lastFrameTime);
    self.lastFrameTime = now;
    if (dt <= 0.0f || dt > 0.25f) dt = 1.0f / 60.0f;

    ImGuiIO &io = ImGui::GetIO();
    CGSize boundsSize = view.bounds.size;
    CGFloat scale = view.contentScaleFactor > 0 ? view.contentScaleFactor : [UIScreen mainScreen].scale;
    io.DisplaySize = ImVec2((float)boundsSize.width, (float)boundsSize.height);
    io.DisplayFramebufferScale = ImVec2((float)scale, (float)scale);
    io.DeltaTime = dt;

    // Управление системной клавиатурой iOS при фокусе на InputText
    if (io.WantTextInput && !self.keyboardActive) {
        self.keyboardActive = YES;
        [self becomeFirstResponder];
    } else if (!io.WantTextInput && self.keyboardActive) {
        self.keyboardActive = NO;
        [self resignFirstResponder];
