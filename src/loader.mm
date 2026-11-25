#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach/mach.h>

#include <string>
#include <utility>
#include <vector>
#include <deque>
#include <map>
#include <unordered_map>
#include <mutex>
#include <chrono>
#include <algorithm>
#include <cctype>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <cmath>

extern "C" {
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
}

#include "imgui.h"
#include "imgui_impl_metal.h"

// ============================================================================
// 1. ENCODING HELPERS (CP1251 <-> UTF-8)
// ============================================================================

static std::string ToLowerASCII(const std::string& s) {
    std::string out = s;
    for (char& c : out) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return out;
}

static std::string Cp1251ToUtf8(const std::string& str) {
    NSString* decoded = [[NSString alloc] initWithBytes:str.data()
                                                length:str.size()
                                              encoding:NSUTF8StringEncoding];
    if (decoded) {
        NSData* roundTrip = [decoded dataUsingEncoding:NSUTF8StringEncoding];
        if (roundTrip.length == str.size() &&
            (str.empty() || memcmp(roundTrip.bytes, str.data(), str.size()) == 0)) return str;
    }
    decoded = [[NSString alloc] initWithBytes:str.data()
                                      length:str.size()
                                    encoding:NSWindowsCP1251StringEncoding];
    if (!decoded) return std::string(str.size(), '?');
    const char* utf8 = decoded.UTF8String;
    return utf8 ? std::string(utf8) : std::string();
}

static std::string Utf8ToCp1251(const std::string& str) {
    NSString* decoded = [[NSString alloc] initWithBytes:str.data()
                                                length:str.size()
                                              encoding:NSUTF8StringEncoding];
    if (!decoded) return std::string(str.size(), '?');
    NSData* encoded = [decoded dataUsingEncoding:NSWindowsCP1251StringEncoding allowLossyConversion:YES];
    if (!encoded) return std::string(str.size(), '?');
    return encoded.length
        ? std::string(static_cast<const char*>(encoded.bytes), encoded.length)
        : std::string();
}

// ============================================================================
// 2. DATA STRUCTURES & GLOBAL STATE
// ============================================================================

struct LuaCoroutine {
    lua_State* co = nullptr;
    int ref = LUA_NOREF;
    uint64_t handle = 0;
    uint64_t wakeTimeMs = 0;
    bool suspended = false;
    bool finished = false;
};

struct LuaAllocatorState {
    size_t used = 0;
    size_t limit = 24 * 1024 * 1024;
};

struct RegisteredCommand {
    std::string scriptName;
    lua_State* L = nullptr;
    int funcRef = LUA_NOREF;
};

struct ChatHistoryEntry {
    std::string text;
    std::string prefix;
    uint32_t color = 0xFFFFFFFF;
    uint32_t pcolor = 0xFFFFFFFF;
};

struct LuaScriptInstance {
    uint64_t id = 0;
    std::string filename;
    std::string fullPath;
    std::string displayName;
    LuaAllocatorState allocator;
    lua_State* L = nullptr;
    bool enabled = true;
    bool hasError = false;
    std::string lastError;
    std::deque<LuaCoroutine> threads;
    int renderCallbackRef = LUA_NOREF;
};

struct HttpCompletion {
    uint64_t ownerId = 0;
    int successRef = LUA_NOREF;
    int errorRef = LUA_NOREF;
    bool succeeded = false;
    long statusCode = 0;
    std::string text;
    std::string error;
    std::map<std::string, std::string> headers;
};

struct OverlayNotification {
    std::string title;
    std::string message;
    uint64_t expireMs;
};

struct RenderCommand {
    enum Kind { Text, Line, Box, Circle } kind;
    std::string text;
    float x1 = 0, y1 = 0, x2 = 0, y2 = 0, thickness = 1;
    int segments = 24;
    uint32_t color = 0xFFFFFFFF;
};

struct ImGuiTouchEvent {
    float x = 0;
    float y = 0;
    bool down = false;
};

static std::recursive_mutex g_EngineMutex;
static size_t g_TotalLuaBytes = 0;
static const size_t kLuaProcessMemoryLimit = 128 * 1024 * 1024;
static std::vector<LuaScriptInstance*> g_Scripts;
static uint64_t g_NextScriptId = 1;
static uint64_t g_NextThreadHandle = 1;
static std::deque<HttpCompletion> g_HttpCompletions;
static std::unordered_map<std::string, RegisteredCommand> g_ChatCommands;
static std::vector<std::string> g_ConsoleLogs;
static std::vector<ChatHistoryEntry> g_ChatHistory;
static std::vector<OverlayNotification> g_Notifications;
static std::vector<RenderCommand> g_RenderCommands;
static std::vector<ImGuiTouchEvent> g_ImGuiTouchEvents;
static UIView* g_ImGuiTouchView = nil;

static bool g_MenuOpen = false;
static int g_SelectedTab = 0;

static int g_CurrentDialogId = -1;
static int g_CurrentDialogStyle = 0;
static bool g_IsDialogActive = false;
static std::string g_CurrentDialogTitle;
static std::string g_CurrentDialogText;
static std::string g_LastInterceptedCmd;
static uint64_t g_LastInterceptedMs = 0;

static UIButton* g_FloatingMenuButton = nullptr;
static CGFloat g_OverlayDisplayWidth = 0;
static CGFloat g_OverlayDisplayHeight = 0;
static CGFloat g_OverlayScale = 1;

static void* BoundedLuaAllocator(void* userData, void* pointer, size_t oldSize, size_t newSize) {
    LuaAllocatorState* state = static_cast<LuaAllocatorState*>(userData);
    const size_t actualOldSize = pointer ? oldSize : 0;
    if (newSize == 0) {
        std::free(pointer);
        if (state) {
            state->used = actualOldSize <= state->used ? state->used - actualOldSize : 0;
            g_TotalLuaBytes = actualOldSize <= g_TotalLuaBytes ? g_TotalLuaBytes - actualOldSize : 0;
        }
        return nullptr;
    }
    if (!state) return nullptr;
    if (newSize > actualOldSize) {
        const size_t growth = newSize - actualOldSize;
        if (growth > state->limit - std::min(state->used, state->limit) ||
            growth > kLuaProcessMemoryLimit - std::min(g_TotalLuaBytes, kLuaProcessMemoryLimit))
            return nullptr;
    }
    void* resized = std::realloc(pointer, newSize);
    if (!resized) return nullptr;
    state->used = state->used - std::min(state->used, actualOldSize) + newSize;
    g_TotalLuaBytes = g_TotalLuaBytes - std::min(g_TotalLuaBytes, actualOldSize) + newSize;
    return resized;
}

static void QueueImGuiTouchEvent(CGPoint point, bool down) {
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    if (g_ImGuiTouchEvents.size() >= 64) g_ImGuiTouchEvents.erase(g_ImGuiTouchEvents.begin());
    g_ImGuiTouchEvents.push_back({static_cast<float>(point.x), static_cast<float>(point.y), down});
}

static void ApplyQueuedImGuiTouchEvents(ImGuiIO& io) {
    std::vector<ImGuiTouchEvent> events;
    {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        events.swap(g_ImGuiTouchEvents);
    }
    for (const auto& event : events) {
        io.AddMousePosEvent(event.x, event.y);
        io.AddMouseButtonEvent(0, event.down);
    }
}

static uint64_t NowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

static void AddOverlayNotification(std::string title, std::string message, uint64_t lifetimeMs) {
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    if (g_Notifications.size() >= 50) g_Notifications.erase(g_Notifications.begin());
    g_Notifications.push_back({std::move(title), std::move(message), NowMs() + lifetimeMs});
}

static void LuaInstructionLimit(lua_State* L, lua_Debug* debug);
static int ProtectedLuaCall(lua_State* L, int nargs, int nresults, int instructionLimit = 250000);

static std::string GetBaseDir() {
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString* docs = [paths firstObject];
    if (!docs) docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    const char* path = docs.UTF8String;
    return path ? std::string(path) + "/lua_loader" : std::string();
}

static std::string ShortenPathForUI(const std::string& raw) {
    size_t pos = raw.find("/Documents/");
    if (pos != std::string::npos) {
        return raw.substr(pos + 1);
    }
    return raw;
}

static void LogConsole(const std::string& line) {
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    std::string clean = ShortenPathForUI(line);
    g_ConsoleLogs.push_back(clean);
    if (g_ConsoleLogs.size() > 300) {
        g_ConsoleLogs.erase(g_ConsoleLogs.begin());
    }
    NSLog(@"[42Loader] %s", clean.c_str());

    std::string logPath = GetBaseDir() + "/loader.log";
    FILE* f = fopen(logPath.c_str(), "a");
    if (f) {
        fprintf(f, "%s\n", clean.c_str());
        fclose(f);
    }
}

static UIWindow* GetActiveKeyWindow() {
    UIWindow* found = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene* ws = (UIWindowScene*)scene;
                for (UIWindow* w in ws.windows) {
                    if (w.isKeyWindow) return w;
                    if (!found && !w.hidden) found = w;
                }
            }
        }
    }
    if (!found) {
        found = [[UIApplication sharedApplication] keyWindow];
    }
    return found;
}

static void ToggleLoaderMenu() {
    {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        g_MenuOpen = !g_MenuOpen;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        bool isOpen = false;
        {
            std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
            isOpen = g_MenuOpen;
        }
        if (g_FloatingMenuButton) {
            g_FloatingMenuButton.backgroundColor = isOpen
                ? [UIColor colorWithRed:0.52 green:0.26 blue:0.88 alpha:0.95]
                : [UIColor colorWithRed:0.15 green:0.11 blue:0.25 alpha:0.90];
        }
    });
}

// ============================================================================
// 3. FLOATING UIKIT MENU BUTTON, TOUCH INPUT & BANNERS
// ============================================================================

@interface LoaderImGuiTouchView : UIView
@end

@implementation LoaderImGuiTouchView
- (void)layoutSubviews {
    [super layoutSubviews];
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    g_OverlayDisplayWidth = self.bounds.size.width;
    g_OverlayDisplayHeight = self.bounds.size.height;
    g_OverlayScale = self.window.screen.scale ?: 1.0;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
    (void)point; (void)event;
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    return g_MenuOpen;
}
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    UITouch* touch = touches.anyObject;
    if (touch) QueueImGuiTouchEvent([touch locationInView:self], true);
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    UITouch* touch = touches.anyObject;
    if (touch) QueueImGuiTouchEvent([touch locationInView:self], true);
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    UITouch* touch = touches.anyObject;
    if (touch) QueueImGuiTouchEvent([touch locationInView:self], false);
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    (void)event;
    UITouch* touch = touches.anyObject;
    if (touch) QueueImGuiTouchEvent([touch locationInView:self], false);
}
@end

@interface LoaderFloatingBtnHandler : NSObject
+ (void)onTap:(UIButton*)sender;
+ (void)onPan:(UIPanGestureRecognizer*)pan;
@end

@implementation LoaderFloatingBtnHandler
+ (void)onTap:(UIButton*)sender {
    ToggleLoaderMenu();
}

+ (void)onPan:(UIPanGestureRecognizer*)pan {
    UIView* btn = pan.view;
    UIView* parent = btn.superview;
    if (!btn || !parent) return;

    CGPoint delta = [pan translationInView:parent];
    CGPoint center = CGPointMake(btn.center.x + delta.x, btn.center.y + delta.y);
    CGFloat halfW = btn.bounds.size.width * 0.5;
    CGFloat halfH = btn.bounds.size.height * 0.5;
    center.x = MAX(halfW + 6.0, MIN(parent.bounds.size.width - halfW - 6.0, center.x));
    center.y = MAX(halfH + 6.0, MIN(parent.bounds.size.height - halfH - 6.0, center.y));
    btn.center = center;
    [pan setTranslation:CGPointZero inView:parent];
}
@end

static void EnsureFloatingMenuButton() {
    dispatch_block_t ensureButton = ^{
        UIWindow* win = GetActiveKeyWindow();
        if (!win) return;

        if (g_FloatingMenuButton) {
            if (g_ImGuiTouchView && g_ImGuiTouchView.superview != win) {
                g_ImGuiTouchView.frame = win.bounds;
                [win addSubview:g_ImGuiTouchView];
            }
            if (g_FloatingMenuButton.superview != win) {
                [win addSubview:g_FloatingMenuButton];
            }
            [win bringSubviewToFront:g_FloatingMenuButton];
            return;
        }

        if (!g_ImGuiTouchView) {
            g_ImGuiTouchView = [[LoaderImGuiTouchView alloc] initWithFrame:win.bounds];
            g_ImGuiTouchView.backgroundColor = UIColor.clearColor;
            g_ImGuiTouchView.userInteractionEnabled = YES;
            g_ImGuiTouchView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [win addSubview:g_ImGuiTouchView];
        }
        g_OverlayDisplayWidth = win.bounds.size.width;
        g_OverlayDisplayHeight = win.bounds.size.height;
        g_OverlayScale = win.screen.scale ?: 1.0;
        UIButton* btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = 424200;
        btn.frame = CGRectMake(18.0, 52.0, 48.0, 48.0);
        btn.backgroundColor = [UIColor colorWithRed:0.15 green:0.11 blue:0.25 alpha:0.90];
        btn.layer.cornerRadius = 24.0;
        btn.layer.borderWidth = 1.5;
        btn.layer.borderColor = [UIColor colorWithRed:0.62 green:0.38 blue:0.95 alpha:0.95].CGColor;
        btn.layer.shadowColor = [UIColor blackColor].CGColor;
        btn.layer.shadowOpacity = 0.45;
        btn.layer.shadowRadius = 6.0;
        btn.layer.shadowOffset = CGSizeMake(0, 2);
        [btn setTitle:@"42" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:16.0];

        [btn addTarget:[LoaderFloatingBtnHandler class]
                action:@selector(onTap:)
      forControlEvents:UIControlEventTouchUpInside];

        UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc] initWithTarget:[LoaderFloatingBtnHandler class]
                                                                              action:@selector(onPan:)];
        [btn addGestureRecognizer:pan];

        [win addSubview:btn];
        [win bringSubviewToFront:btn];
        g_FloatingMenuButton = btn;
    };
    if ([NSThread isMainThread]) ensureButton();
    else dispatch_async(dispatch_get_main_queue(), ensureButton);
}

static void ShowLauncherBanner(NSString* message, BOOL isError) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow* win = GetActiveKeyWindow();
        if (!win) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ShowLauncherBanner(message, isError);
            });
            return;
        }

        EnsureFloatingMenuButton();

        UIView* old = [win viewWithTag:424242];
        if (old) [old removeFromSuperview];

        CGFloat screenW = win.bounds.size.width;
        CGFloat bannerW = MIN(screenW - 32.0, 420.0);
        CGFloat bannerH = 44.0;

        UIView* banner = [[UIView alloc] initWithFrame:CGRectMake((screenW - bannerW) * 0.5, -60.0, bannerW, bannerH)];
        banner.tag = 424242;
        banner.backgroundColor = isError
            ? [UIColor colorWithRed:0.35 green:0.10 blue:0.14 alpha:0.95]
            : [UIColor colorWithRed:0.14 green:0.10 blue:0.24 alpha:0.95];
        banner.layer.cornerRadius = 14.0;
        banner.layer.borderWidth = 1.5;
        banner.layer.borderColor = isError
            ? [UIColor colorWithRed:0.95 green:0.30 blue:0.35 alpha:0.95].CGColor
            : [UIColor colorWithRed:0.62 green:0.38 blue:0.95 alpha:0.95].CGColor;
        banner.layer.shadowColor = [UIColor blackColor].CGColor;
        banner.layer.shadowOpacity = 0.45;
        banner.layer.shadowRadius = 8.0;
        banner.layer.shadowOffset = CGSizeMake(0, 3);
        banner.userInteractionEnabled = NO;

        UILabel* lbl = [[UILabel alloc] initWithFrame:CGRectInset(banner.bounds, 14.0, 4.0)];
        lbl.text = message;
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont boldSystemFontOfSize:13.0];
        lbl.textAlignment = NSTextAlignmentCenter;
        lbl.numberOfLines = 2;
        lbl.adjustsFontSizeToFitWidth = YES;
        lbl.minimumScaleFactor = 0.75;
        [banner addSubview:lbl];

        [win addSubview:banner];
        [win bringSubviewToFront:banner];

        CGFloat topInset = 18.0;
        if (@available(iOS 11.0, *)) {
            topInset = MAX(18.0, win.safeAreaInsets.top + 6.0);
        }

        [UIView animateWithDuration:0.35
                              delay:0
             usingSpringWithDamping:0.8
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            banner.frame = CGRectMake((screenW - bannerW) * 0.5, topInset, bannerW, bannerH);
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.30
                                  delay:3.8
                                options:UIViewAnimationOptionCurveEaseIn
                             animations:^{
                banner.alpha = 0.0;
                banner.frame = CGRectMake((screenW - bannerW) * 0.5, -60.0, bannerW, bannerH);
            } completion:^(BOOL done) {
                [banner removeFromSuperview];
            }];
        }];
    });
}

static void EnsureDirectories() {
    NSFileManager* fm = [NSFileManager defaultManager];
    std::string base = GetBaseDir();
    NSArray* subdirs = @[
        [NSString stringWithUTF8String:base.c_str()],
        [NSString stringWithUTF8String:(base + "/scripts").c_str()],
        [NSString stringWithUTF8String:(base + "/config").c_str()],
        [NSString stringWithUTF8String:(base + "/lib").c_str()]
    ];
    for (NSString* dir in subdirs) {
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }
}

static LuaScriptInstance* FindScriptByState(lua_State* L) {
    for (auto* s : g_Scripts) {
        if (s->L == L) return s;
        for (auto& t : s->threads) {
            if (t.co == L) return s;
        }
    }
    return nullptr;
}

static void ReleaseScriptThreads(LuaScriptInstance* inst) {
    if (!inst || !inst->L) return;
    for (auto& thread : inst->threads) {
        if (thread.ref != LUA_NOREF && thread.ref != LUA_REFNIL)
            luaL_unref(inst->L, LUA_REGISTRYINDEX, thread.ref);
    }
    inst->threads.clear();
}

static void UnregisterScriptCommands(LuaScriptInstance* inst) {
    if (!inst || !inst->L) return;
    for (auto it = g_ChatCommands.begin(); it != g_ChatCommands.end(); ) {
        if (it->second.L == inst->L) {
            if (it->second.funcRef != LUA_NOREF && it->second.funcRef != LUA_REFNIL)
                luaL_unref(inst->L, LUA_REGISTRYINDEX, it->second.funcRef);
            it = g_ChatCommands.erase(it);
        } else ++it;
    }
}

// ============================================================================
// 4. LOCAL COMMAND DISPATCH
// ============================================================================

static bool TryExecuteChatCommand(const std::string& rawInput, const char* sourceTag = "unknown", lua_State* caller = nullptr) {
    std::string utf8 = Cp1251ToUtf8(rawInput);

    while (!utf8.empty() && (utf8.back() == '\n' || utf8.back() == '\r' || utf8.back() == ' ')) {
        utf8.pop_back();
    }
    size_t start = utf8.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) return false;
    utf8 = utf8.substr(start);

    if (utf8.empty() || utf8[0] != '/') {
        return false;
    }

    uint64_t now = NowMs();
    if (utf8 == g_LastInterceptedCmd && (now - g_LastInterceptedMs) < 350) {
        return true;
    }

    std::string withoutSlash = utf8.substr(1);
    std::string cmdName;
    std::string cmdArgs;

    size_t spacePos = withoutSlash.find(' ');
    if (spacePos == std::string::npos) {
        cmdName = withoutSlash;
        cmdArgs = "";
    } else {
        cmdName = withoutSlash.substr(0, spacePos);
        size_t argStart = withoutSlash.find_first_not_of(' ', spacePos);
        cmdArgs = (argStart != std::string::npos) ? withoutSlash.substr(argStart) : "";
    }

    std::string key = ToLowerASCII(cmdName);
    if (key.empty()) return false;

    // Built-in loader menu commands (/42, /42loader, /luasettings)
    if (key == "42" || key == "42loader" || key == "luasettings") {
        g_LastInterceptedCmd = utf8;
        g_LastInterceptedMs = now;
        ToggleLoaderMenu();
        LogConsole(std::string("[Command:") + sourceTag + "] Loader menu toggled with /" + key);
        return true;
    }

    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    auto it = g_ChatCommands.find(key);
    if (it == g_ChatCommands.end()) {
        return false;
    }

    g_LastInterceptedCmd = utf8;
    g_LastInterceptedMs = now;
    LogConsole(std::string("[Command:") + sourceTag + "] Ran /" + key + " (" + cmdArgs + ")");

    RegisteredCommand reg = it->second;
    if (reg.L && reg.funcRef != LUA_NOREF) {
        lua_State* L = reg.L;
        lua_rawgeti(L, LUA_REGISTRYINDEX, reg.funcRef);
        lua_pushstring(L, cmdArgs.c_str());
        if (ProtectedLuaCall(L, 1, 0) != LUA_OK) {
            const char* err = lua_tostring(L, -1);
            std::string errMsg = err ? err : "unknown command error";
            LogConsole("[CMD /" + key + " ERROR] " + errMsg);
            LuaScriptInstance* inst = FindScriptByState(L);
            if (inst) {
                inst->hasError = true;
                inst->lastError = errMsg;
                UnregisterScriptCommands(inst);
                if (!caller || caller == inst->L) ReleaseScriptThreads(inst);
                else for (auto& thread : inst->threads) thread.finished = true;
            }
            lua_pop(L, 1);
        }
    }
    return true;
}

// ============================================================================
// 5. LUA 5.4 C++ API FUNCTIONS (MOONLOADER + AZ + SAMP)
// ============================================================================

static int l_print(lua_State* L) {
    int n = lua_gettop(L);
    std::string msg;
    for (int i = 1; i <= n; i++) {
        size_t len = 0;
        const char* s = luaL_tolstring(L, i, &len);
        if (i > 1) msg += "\t";
        if (s) msg += std::string(s, len);
        lua_pop(L, 1);
    }
    LogConsole(msg);
    return 0;
}

static int l_wait(lua_State* L) {
    lua_Integer ms = luaL_optinteger(L, 1, 0);
    if (ms < 0) ms = 0;
    if (!lua_isyieldable(L))
        return luaL_error(L, "wait() can only yield from a managed Lua thread; call it inside main or lua_thread.create");
    lua_pushinteger(L, ms);
    return lua_yield(L, 1);
}

static void LuaInstructionLimit(lua_State* L, lua_Debug*) {
    luaL_error(L, "script used too many instructions without yielding; call wait() regularly");
}

static int ProtectedLuaCall(lua_State* L, int nargs, int nresults, int instructionLimit) {
    lua_sethook(L, LuaInstructionLimit, LUA_MASKCOUNT, instructionLimit);
    int status = lua_pcall(L, nargs, nresults, 0);
    lua_sethook(L, nullptr, 0, 0);
    return status;
}

static int l_cp1251ToUtf8(lua_State* L) {
    size_t length = 0;
    const char* value = luaL_checklstring(L, 1, &length);
    std::string converted = Cp1251ToUtf8(std::string(value, length));
    lua_pushlstring(L, converted.data(), converted.size());
    return 1;
}

static int l_utf8ToCp1251(lua_State* L) {
    size_t length = 0;
    const char* value = luaL_checklstring(L, 1, &length);
    std::string converted = Utf8ToCp1251(std::string(value, length));
    lua_pushlstring(L, converted.data(), converted.size());
    return 1;
}

static int l_lua_thread_resume(lua_State* L);
static int l_lua_thread_is_active(lua_State* L);
static int LuaThreadCreate(lua_State* L, bool suspended) {
    luaL_checktype(L, 1, LUA_TFUNCTION);

    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    LuaScriptInstance* inst = FindScriptByState(L);
    if (!inst) return 0;
    if (inst->threads.size() >= 128)
        return luaL_error(L, "script thread limit reached (128)");

    lua_State* co = lua_newthread(inst->L);
    int ref = luaL_ref(inst->L, LUA_REGISTRYINDEX);

    lua_pushvalue(L, 1);
    lua_xmove(L, co, 1);

    LuaCoroutine lc;
    lc.co = co;
    lc.ref = ref;
    lc.handle = g_NextThreadHandle++;
    lc.wakeTimeMs = NowMs();
    lc.suspended = suspended;
    lc.finished = false;
    inst->threads.push_back(lc);

    lua_newtable(L);
    lua_pushinteger(L, static_cast<lua_Integer>(lc.handle));
    lua_setfield(L, -2, "_id");
    lua_pushcfunction(L, l_lua_thread_resume);
    lua_setfield(L, -2, "resume");
    lua_pushcfunction(L, l_lua_thread_resume);
    lua_setfield(L, -2, "run");
    lua_pushcfunction(L, l_lua_thread_is_active);
    lua_setfield(L, -2, "isActive");
    return 1;
}

static int l_lua_thread_create(lua_State* L) { return LuaThreadCreate(L, false); }
static int l_lua_thread_create_suspended(lua_State* L) { return LuaThreadCreate(L, true); }

static int l_lua_thread_resume(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "_id");
    uint64_t handle = static_cast<uint64_t>(luaL_checkinteger(L, -1));
    lua_pop(L, 1);
    LuaScriptInstance* inst = FindScriptByState(L);
    if (!inst) { lua_pushboolean(L, 0); return 1; }
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    for (auto& thread : inst->threads) {
        if (thread.handle == handle && !thread.finished) {
            thread.suspended = false;
            thread.wakeTimeMs = NowMs();
            lua_pushboolean(L, 1);
            return 1;
        }
    }
    lua_pushboolean(L, 0);
    return 1;
}

static int l_lua_thread_is_active(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "_id");
    uint64_t handle = static_cast<uint64_t>(luaL_checkinteger(L, -1));
    lua_pop(L, 1);
    LuaScriptInstance* inst = FindScriptByState(L);
    bool active = false;
    if (inst) {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        for (const auto& thread : inst->threads)
            if (thread.handle == handle && !thread.finished) { active = true; break; }
    }
    lua_pushboolean(L, active);
    return 1;
}

static int l_lua_thread_terminate_all(lua_State* L) {
    LuaScriptInstance* inst = FindScriptByState(L);
    int count = 0;
    if (inst) {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        for (auto& thread : inst->threads) {
            if (!thread.finished) { thread.finished = true; ++count; }
        }
    }
    lua_pushinteger(L, count);
    return 1;
}

static int l_sampRegisterChatCommand(lua_State* L) {
    const char* rawCmd = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);

    std::string cmd = rawCmd;
    if (!cmd.empty() && cmd[0] == '/') cmd = cmd.substr(1);
    cmd = ToLowerASCII(cmd);
    if (cmd.empty() || cmd.size() > 64 ||
        !std::all_of(cmd.begin(), cmd.end(), [](unsigned char c) { return std::isalnum(c) || c == '_'; }))
        return luaL_error(L, "chat command names must contain 1-64 ASCII letters, digits, or underscores");

    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    LuaScriptInstance* inst = FindScriptByState(L);

    auto oldIt = g_ChatCommands.find(cmd);
    if (oldIt != g_ChatCommands.end() && oldIt->second.L && oldIt->second.funcRef != LUA_NOREF) {
        luaL_unref(oldIt->second.L, LUA_REGISTRYINDEX, oldIt->second.funcRef);
    }

    lua_pushvalue(L, 2);
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);

    RegisteredCommand rc;
    rc.scriptName = inst ? inst->filename : "unknown";
    rc.L = inst ? inst->L : L;
    rc.funcRef = ref;
    g_ChatCommands[cmd] = rc;

    LogConsole("[CMD] Registered local command /" + cmd);
    lua_pushboolean(L, 1);
    return 1;
}

static int l_sampUnregisterChatCommand(lua_State* L) {
    const char* rawCmd = luaL_checkstring(L, 1);
    std::string cmd = rawCmd;
    if (!cmd.empty() && cmd[0] == '/') cmd = cmd.substr(1);
    cmd = ToLowerASCII(cmd);

    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    auto it = g_ChatCommands.find(cmd);
    LuaScriptInstance* inst = FindScriptByState(L);
    if (it != g_ChatCommands.end() && inst && it->second.L == inst->L) {
        if (it->second.L && it->second.funcRef != LUA_NOREF) {
            luaL_unref(it->second.L, LUA_REGISTRYINDEX, it->second.funcRef);
        }
        g_ChatCommands.erase(it);
        lua_pushboolean(L, 1);
        return 1;
    }
    lua_pushboolean(L, 0);
    return 1;
}

static int l_sampIsChatCommandDefined(lua_State* L) {
    const char* rawCmd = luaL_checkstring(L, 1);
    std::string cmd = rawCmd;
    if (!cmd.empty() && cmd[0] == '/') cmd = cmd.substr(1);
    cmd = ToLowerASCII(cmd);
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    lua_pushboolean(L, g_ChatCommands.find(cmd) != g_ChatCommands.end());
    return 1;
}

static int l_sampAddChatMessage(lua_State* L) {
    const char* text = luaL_checkstring(L, 1);
    uint32_t color = static_cast<uint32_t>(luaL_optinteger(L, 2, 0xFFFFFFFF));
    std::string utf8 = Cp1251ToUtf8(text);

    {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        g_ChatHistory.push_back({utf8, "", color, color});
        if (g_ChatHistory.size() > 100) g_ChatHistory.erase(g_ChatHistory.begin());
    }
    AddOverlayNotification("42Loader", utf8, 4500);

    // This is shown in the loader UI only; it is not written into the game chat.
    LogConsole("[ChatBridge unavailable] Local message queued for Loader UI only: " + utf8);
    lua_pushboolean(L, 0);
    lua_pushstring(L, "Arizona CChatWindow bridge is not verified");
    return 2;
}

static int l_sampSendChat(lua_State* L) {
    luaL_checkstring(L, 1);
    return luaL_error(L, "sampSendChat is unavailable: the game chat ABI has not been verified");
}

static int l_sampProcessChatInput(lua_State* L) {
    const char* text = luaL_checkstring(L, 1);
    std::string utf8 = Cp1251ToUtf8(text);
    if (TryExecuteChatCommand(utf8, "sampProcessChatInput", L)) return 0;
    return luaL_error(L, "sampProcessChatInput cannot send to the game: the chat ABI is unverified");
}

static int l_sampShowDialog(lua_State* L) {
    int id = static_cast<int>(luaL_checkinteger(L, 1));
    const char* title = luaL_optstring(L, 2, "");
    const char* text = luaL_optstring(L, 3, "");
    const char* btn1 = luaL_optstring(L, 4, "OK");
    const char* btn2 = luaL_optstring(L, 5, "");
    int style = static_cast<int>(luaL_optinteger(L, 6, 0));

    std::string uTitle = Cp1251ToUtf8(title);
    std::string uText = Cp1251ToUtf8(text);
    std::string uBtn1 = Cp1251ToUtf8(btn1);
    std::string uBtn2 = Cp1251ToUtf8(btn2);

    {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        g_CurrentDialogId = id;
        g_CurrentDialogStyle = style;
        g_IsDialogActive = true;
        g_CurrentDialogTitle = uTitle;
        g_CurrentDialogText = uText;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController* alert = [UIAlertController alertControllerWithTitle:[NSString stringWithUTF8String:uTitle.c_str()]
                                                                           message:[NSString stringWithUTF8String:uText.c_str()]
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithUTF8String:uBtn1.c_str()]
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction* _Nonnull) {
                std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
                g_IsDialogActive = false;
            }]];
            if (!uBtn2.empty()) {
                [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithUTF8String:uBtn2.c_str()]
                                                          style:UIAlertActionStyleCancel
                                                        handler:^(UIAlertAction* _Nonnull) {
                    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
                    g_IsDialogActive = false;
                }]];
            }
            UIWindow* win = GetActiveKeyWindow();
            UIViewController* presenter = win.rootViewController;
            while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed)
                presenter = presenter.presentedViewController;
            if (presenter) [presenter presentViewController:alert animated:YES completion:nil];
        });
    return 0;
}

static int l_sampGetCurrentDialogId(lua_State* L) { std::lock_guard<std::recursive_mutex> lock(g_EngineMutex); lua_pushinteger(L, g_CurrentDialogId); return 1; }
static int l_sampGetCurrentDialogStyle(lua_State* L) { std::lock_guard<std::recursive_mutex> lock(g_EngineMutex); lua_pushinteger(L, g_CurrentDialogStyle); return 1; }
static int l_sampIsDialogActive(lua_State* L) { std::lock_guard<std::recursive_mutex> lock(g_EngineMutex); lua_pushboolean(L, g_IsDialogActive); return 1; }
static int l_sampGetDialogText(lua_State* L) { std::lock_guard<std::recursive_mutex> lock(g_EngineMutex); lua_pushstring(L, g_CurrentDialogText.c_str()); return 1; }
static int l_sampGetDialogCaption(lua_State* L) { std::lock_guard<std::recursive_mutex> lock(g_EngineMutex); lua_pushstring(L, g_CurrentDialogTitle.c_str()); return 1; }
static int l_sampIsChatInputActive(lua_State* L) { return luaL_error(L, "chat input state is unavailable: no verified game input bridge"); }
static int l_sampGetChatInputText(lua_State* L) { return luaL_error(L, "chat input text is unavailable: no verified game input bridge"); }
static int l_sampSetChatInputText(lua_State* L) { (void)L; return luaL_error(L, "chat input control is unavailable: no verified game input bridge"); }
static int l_sampSetChatInputEnabled(lua_State* L) { (void)L; return luaL_error(L, "chat input control is unavailable: no verified game input bridge"); }
static int l_isSampAvailable(lua_State* L) { lua_pushboolean(L, 0); return 1; }
static int l_isSampfuncsLoaded(lua_State* L) { lua_pushboolean(L, 0); return 1; }
static int l_sampGetGamestate(lua_State* L) { return luaL_error(L, "sampGetGamestate is unavailable: connection state has no verified source"); }

static int l_sampGetChatString(lua_State* L) {
    int id = static_cast<int>(luaL_checkinteger(L, 1));
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    int idx = static_cast<int>(g_ChatHistory.size()) - 1 - (99 - id);
    if (idx >= 0 && idx < static_cast<int>(g_ChatHistory.size())) {
        const auto& e = g_ChatHistory[idx];
        lua_pushstring(L, e.text.c_str());
        lua_pushstring(L, e.prefix.c_str());
        lua_pushinteger(L, e.color);
        lua_pushinteger(L, e.pcolor);
        return 4;
    }
    lua_pushstring(L, "");
    lua_pushstring(L, "");
    lua_pushinteger(L, 0xFFFFFFFF);
    lua_pushinteger(L, 0xFFFFFFFF);
    return 4;
}

static int l_setTimeOfDay(lua_State* L) {
    luaL_checkinteger(L, 1);
    luaL_optinteger(L, 2, 0);
    return luaL_error(L, "setTimeOfDay is unavailable: Arizona CClock ABI is not verified");
}

static int l_getTimeOfDay(lua_State* L) {
    return luaL_error(L, "getTimeOfDay is unavailable: no verified Arizona CClock reader");
}

static int l_forceWeatherNow(lua_State* L) {
    luaL_checkinteger(L, 1);
    return luaL_error(L, "forceWeatherNow is unavailable: Arizona CWeather ABI is not verified");
}

static int l_getScreenResolution(lua_State* L) {
    CGFloat width, height, scale;
    {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        width = g_OverlayDisplayWidth;
        height = g_OverlayDisplayHeight;
        scale = g_OverlayScale;
    }
    if (width <= 0 || height <= 0 || scale <= 0)
        return luaL_error(L, "screen resolution is unavailable until the app window is ready");
    lua_pushinteger(L, static_cast<lua_Integer>(std::lround(width * scale)));
    lua_pushinteger(L, static_cast<lua_Integer>(std::lround(height * scale)));
    return 2;
}

static int l_getWorkingDirectory(lua_State* L) {
    lua_pushstring(L, GetBaseDir().c_str());
    return 1;
}

static int l_getGameDirectory(lua_State* L) {
    NSString* path = [[NSBundle mainBundle] bundlePath];
    lua_pushstring(L, path ? path.UTF8String : "");
    return 1;
}

static int l_doesFileExist(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    BOOL isDir = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithUTF8String:path] isDirectory:&isDir];
    lua_pushboolean(L, exists && !isDir);
    return 1;
}

static int l_doesDirectoryExist(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    BOOL isDir = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithUTF8String:path] isDirectory:&isDir];
    lua_pushboolean(L, exists && isDir);
    return 1;
}

static int l_createDirectory(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:path]
                                        withIntermediateDirectories:YES
                                                         attributes:nil
                                                              error:nil];
    lua_pushboolean(L, ok);
    return 1;
}

static int l_az_vibrate(lua_State* L) {
    int style = static_cast<int>(luaL_optinteger(L, 1, 1));
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImpactFeedbackStyle s = UIImpactFeedbackStyleMedium;
        if (style == 0) s = UIImpactFeedbackStyleLight;
        else if (style >= 2) s = UIImpactFeedbackStyleHeavy;
        UIImpactFeedbackGenerator* gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:s];
        [gen prepare];
        [gen impactOccurred];
    });
    return 0;
}

static int l_az_setClipboard(lua_State* L) {
    const char* txt = luaL_checkstring(L, 1);
    NSString* str = [NSString stringWithUTF8String:txt];
    if (!str) return luaL_error(L, "clipboard text must be valid UTF-8");
    if ([NSThread isMainThread]) [UIPasteboard generalPasteboard].string = str;
    else dispatch_async(dispatch_get_main_queue(), ^{ [UIPasteboard generalPasteboard].string = str; });
    return 0;
}

static int l_az_getClipboard(lua_State* L) {
    __block NSString* str = nil;
    if ([NSThread isMainThread]) str = [UIPasteboard generalPasteboard].string;
    else dispatch_sync(dispatch_get_main_queue(), ^{ str = [UIPasteboard generalPasteboard].string; });
    lua_pushstring(L, str ? [str UTF8String] : "");
    return 1;
}

static int l_az_notify(lua_State* L) {
    const char* title = luaL_checkstring(L, 1);
    const char* msg = luaL_checkstring(L, 2);
    double sec = luaL_optnumber(L, 3, 3.0);
    if (!std::isfinite(sec)) sec = 3.0;
    sec = std::max(0.1, std::min(sec, 60.0));
    AddOverlayNotification(Cp1251ToUtf8(title), Cp1251ToUtf8(msg), static_cast<uint64_t>(sec * 1000.0));
    return 0;
}

static int l_sendLocalNotification(lua_State* L) {
    const char* title = luaL_checkstring(L, 1);
    const char* message = luaL_checkstring(L, 2);
    double delay = luaL_optnumber(L, 3, 0.0);
    if (!std::isfinite(delay)) return luaL_error(L, "notification delay must be finite");
    delay = std::max(0.0, std::min(delay, 86400.0));
    std::string safeTitle = Cp1251ToUtf8(title);
    std::string safeMessage = Cp1251ToUtf8(message);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AddOverlayNotification(safeTitle, safeMessage, 4500);
    });
    return 0;
}

static int l_az_banner(lua_State* L) {
    const char* msg = luaL_checkstring(L, 1);
    ShowLauncherBanner([NSString stringWithUTF8String:Cp1251ToUtf8(msg).c_str()], NO);
    return 0;
}

static int l_az_openURL(lua_State* L) {
    const char* url = luaL_checkstring(L, 1);
    NSURL* nsurl = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
    if (nsurl && ([nsurl.scheme.lowercaseString isEqualToString:@"https"] ||
                  [nsurl.scheme.lowercaseString isEqualToString:@"http"])) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] openURL:nsurl options:@{} completionHandler:nil];
        });
    }
    return 0;
}

static float GetLoaderRAM_MB() {
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count) == KERN_SUCCESS) {
        return static_cast<float>(vmInfo.phys_footprint) / (1024.0f * 1024.0f);
    }
    return 0.0f;
}

static void OpenSafeLuaLibraries(lua_State* L) {
    struct Library { const char* name; lua_CFunction open; };
    static const Library libraries[] = {
        {"_G", luaopen_base}, {LUA_TABLIBNAME, luaopen_table},
        {LUA_IOLIBNAME, luaopen_io}, {LUA_OSLIBNAME, luaopen_os},
        {LUA_STRLIBNAME, luaopen_string}, {LUA_MATHLIBNAME, luaopen_math},
        {LUA_UTF8LIBNAME, luaopen_utf8}, {LUA_COLIBNAME, luaopen_coroutine},
        {LUA_LOADLIBNAME, luaopen_package}
    };
    for (const Library& library : libraries) {
        luaL_requiref(L, library.name, library.open, 1);
        lua_pop(L, 1);
    }

    // Scripts run in the app process. Keep ordinary persistence APIs while
    // removing shell execution and unbounded OS file management entry points.
    lua_getglobal(L, "os");
    if (lua_istable(L, -1)) {
        lua_pushnil(L); lua_setfield(L, -2, "execute");
        lua_pushnil(L); lua_setfield(L, -2, "exit");
        lua_pushnil(L); lua_setfield(L, -2, "remove");
        lua_pushnil(L); lua_setfield(L, -2, "rename");
        lua_pushnil(L); lua_setfield(L, -2, "tmpname");
    }
    lua_pop(L, 1);
    lua_getglobal(L, "io");
    if (lua_istable(L, -1)) {
        lua_pushnil(L); lua_setfield(L, -2, "popen");
        lua_pushnil(L); lua_setfield(L, -2, "tmpfile");
    }
    lua_pop(L, 1);
    lua_getglobal(L, LUA_LOADLIBNAME);
    if (lua_istable(L, -1)) {
        lua_pushnil(L); lua_setfield(L, -2, "loadlib");
        lua_pushliteral(L, ""); lua_setfield(L, -2, "cpath");
        lua_getfield(L, -1, "searchers");
        if (lua_istable(L, -1)) {
            lua_pushnil(L); lua_seti(L, -2, 3);
            lua_pushnil(L); lua_seti(L, -2, 4);
        }
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
}

static int l_az_getLoaderRAM(lua_State* L) {
    lua_pushnumber(L, GetLoaderRAM_MB());
    return 1;
}

static int l_asyncHttpRequest(lua_State* L) {
    const char* method = luaL_checkstring(L, 1);
    const char* url = luaL_checkstring(L, 2);
    const char* body = lua_isstring(L, 3) ? lua_tostring(L, 3) : nullptr;
    LuaScriptInstance* owner = FindScriptByState(L);
    if (!owner) return luaL_error(L, "asyncHttpRequest must be called by a managed script");

    NSString* urlString = [NSString stringWithUTF8String:url];
    NSURL* nsurl = urlString ? [NSURL URLWithString:urlString] : nil;
    if (!nsurl || !nsurl.scheme || !nsurl.host ||
        !([nsurl.scheme.lowercaseString isEqualToString:@"http"] ||
          [nsurl.scheme.lowercaseString isEqualToString:@"https"]))
        return luaL_error(L, "asyncHttpRequest requires an absolute HTTP or HTTPS URL");

    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:nsurl cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20.0];
    NSString* methodString = [NSString stringWithUTF8String:method];
    if (!([methodString.uppercaseString isEqualToString:@"GET"] ||
          [methodString.uppercaseString isEqualToString:@"POST"]))
        return luaL_error(L, "asyncHttpRequest supports GET and POST only");
    req.HTTPMethod = methodString.uppercaseString;
    if (body) {
        NSString* bodyString = [NSString stringWithUTF8String:body];
        if (!bodyString) return luaL_error(L, "HTTP body must be valid UTF-8");
        req.HTTPBody = [bodyString dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (lua_istable(L, 6)) {
        lua_pushnil(L);
        while (lua_next(L, 6) != 0) {
            const char* key = lua_tostring(L, -2);
            const char* value = lua_tostring(L, -1);
            NSString* headerName = key ? [NSString stringWithUTF8String:key] : nil;
            NSString* headerValue = value ? [NSString stringWithUTF8String:value] : nil;
            if (!headerName || !headerValue) {
                lua_pop(L, 2);
                return luaL_error(L, "HTTP header names and values must be valid UTF-8 strings");
            }
            [req setValue:headerValue forHTTPHeaderField:headerName];
            lua_pop(L, 1);
        }
    }
    NSTimeInterval timeout = lua_isnumber(L, 7) ? lua_tonumber(L, 7) : 20.0;
    if (!std::isfinite(timeout)) timeout = 20.0;
    req.timeoutInterval = std::max(1.0, std::min(timeout, 120.0));
    int okRef = lua_isfunction(L, 4) ? (lua_pushvalue(L, 4), luaL_ref(L, LUA_REGISTRYINDEX)) : LUA_NOREF;
    int errRef = lua_isfunction(L, 5) ? (lua_pushvalue(L, 5), luaL_ref(L, LUA_REGISTRYINDEX)) : LUA_NOREF;
    const uint64_t ownerId = owner->id;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        HttpCompletion completion;
        completion.ownerId = ownerId;
        completion.successRef = okRef;
        completion.errorRef = errRef;
        completion.succeeded = (error == nil);
        if (error) {
            completion.error = [[[error localizedDescription] description] UTF8String] ?: "HTTP request failed";
        } else {
            NSHTTPURLResponse* httpResp = (NSHTTPURLResponse*)response;
            completion.statusCode = httpResp ? httpResp.statusCode : 0;
            NSString* responseText = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            completion.text = responseText ? responseText.UTF8String : "";
            for (id key in httpResp.allHeaderFields) {
                id value = httpResp.allHeaderFields[key];
                if ([key respondsToSelector:@selector(UTF8String)] && [value respondsToSelector:@selector(UTF8String)])
                    completion.headers[[key UTF8String]] = [value UTF8String];
            }
        }
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        const bool scriptStillLoaded = std::any_of(g_Scripts.begin(), g_Scripts.end(), [ownerId](const LuaScriptInstance* script) {
            return script && script->id == ownerId && script->L;
        });
        if (scriptStillLoaded) g_HttpCompletions.push_back(std::move(completion));
    }] resume];

    return 0;
}

// ============================================================================
// 6. MOONLOADER COMPATIBILITY RUNTIME & LIBRARIES
// ============================================================================

static const char* kMoonLoaderBootstrapLua = R"lua(
_SCRIPT_META = {
    name = "",
    filename = "",
    path = "",
    directory = getWorkingDirectory(),
    authors = {},
    version = "",
    version_num = 0,
    description = "",
    dependencies = {},
    url = "",
    properties = {}
}

function script_name(name) _SCRIPT_META.name = tostring(name or "") end
function script_author(...) _SCRIPT_META.authors = {...} end
function script_version(ver) _SCRIPT_META.version = tostring(ver or "") end
function script_version_number(num) _SCRIPT_META.version_num = tonumber(num) or 0 end
function script_description(desc) _SCRIPT_META.description = tostring(desc or "") end
function script_dependencies(...) _SCRIPT_META.dependencies = {...} end
function script_url(url) _SCRIPT_META.url = tostring(url or "") end
function script_properties(...) _SCRIPT_META.properties = {...} end

function thisScript()
    return {
        name = _SCRIPT_META.name,
        filename = _SCRIPT_META.filename,
        path = _SCRIPT_META.path,
        directory = _SCRIPT_META.directory,
        authors = _SCRIPT_META.authors,
        version = _SCRIPT_META.version,
        version_num = _SCRIPT_META.version_num,
        description = _SCRIPT_META.description,
        dependencies = _SCRIPT_META.dependencies,
        url = _SCRIPT_META.url,
        properties = _SCRIPT_META.properties,
        -- Per-script lifecycle controls are handled by the Loader UI. They
        -- are omitted here rather than exposed as no-op compatibility stubs.
    }
end

local function unavailableGameApi(name)
    error(name .. " is unavailable: no verified game-state bridge", 2)
end

function isCharInAnyCar(ped) return unavailableGameApi("isCharInAnyCar") end
function storeCarCharIsInNoSave(ped) return unavailableGameApi("storeCarCharIsInNoSave") end
function getCharCoordinates(ped) return unavailableGameApi("getCharCoordinates") end
function setCharCoordinates(ped, x, y, z) return unavailableGameApi("setCharCoordinates") end
function getCharHealth(ped) return unavailableGameApi("getCharHealth") end
function setCharHealth(ped, hp) return unavailableGameApi("setCharHealth") end
function getCharArmour(ped) return unavailableGameApi("getCharArmour") end
function getCharHeading(ped) return unavailableGameApi("getCharHeading") end
function setCharHeading(ped, angle) return unavailableGameApi("setCharHeading") end
function addOneOffSound(x, y, z, id) return unavailableGameApi("addOneOffSound") end
function printStringNow(text, time) if az and az.notify then az.notify("GTA", tostring(text), (time or 2000)/1000.0) end end
function printString(text, time) printStringNow(text, time) end
function isKeyDown(vk) return unavailableGameApi("isKeyDown") end
function wasKeyPressed(vk) return unavailableGameApi("wasKeyPressed") end
function isKeyJustPressed(vk) return unavailableGameApi("isKeyJustPressed") end
function convert3DCoordsToScreen(x, y, z) return unavailableGameApi("convert3DCoordsToScreen") end
function convert3DCoordsToScreenEx(x, y, z) return unavailableGameApi("convert3DCoordsToScreenEx") end

function sampGetCurrentServerName() return unavailableGameApi("sampGetCurrentServerName") end
function sampGetCurrentServerAddress() return unavailableGameApi("sampGetCurrentServerAddress") end
function sampGetPlayerNickname(id) return unavailableGameApi("sampGetPlayerNickname") end
function sampGetPlayerScore(id) return unavailableGameApi("sampGetPlayerScore") end
function sampGetPlayerPing(id) return unavailableGameApi("sampGetPlayerPing") end
function sampGetPlayerColor(id) return unavailableGameApi("sampGetPlayerColor") end
function sampGetPlayerHealth(id) return unavailableGameApi("sampGetPlayerHealth") end
function sampGetPlayerArmor(id) return unavailableGameApi("sampGetPlayerArmor") end
function sampIsPlayerConnected(id) return unavailableGameApi("sampIsPlayerConnected") end
function sampIsPlayerNpc(id) return unavailableGameApi("sampIsPlayerNpc") end
function sampGetMaxPlayerId(streamed) return unavailableGameApi("sampGetMaxPlayerId") end
function sampGetPlayerIdByCharHandle(ped) return unavailableGameApi("sampGetPlayerIdByCharHandle") end
function sampGetCharHandleBySampPlayerId(id) return unavailableGameApi("sampGetCharHandleBySampPlayerId") end
function sampSendDialogResponse(id, btn, item, input) return unavailableGameApi("sampSendDialogResponse") end
function sampCloseCurrentDialogWithButton(btn) return unavailableGameApi("sampCloseCurrentDialogWithButton") end
function sampSendClickTextdraw(id) return unavailableGameApi("sampSendClickTextdraw") end
function sampTextdrawIsExists(id) return unavailableGameApi("sampTextdrawIsExists") end
function sampTextdrawGetString(id) return unavailableGameApi("sampTextdrawGetString") end
function sampCreate3dText(...) return unavailableGameApi("sampCreate3dText") end
function sampDestroy3dText(id) return unavailableGameApi("sampDestroy3dText") end
function sampIs3dTextDefined(id) return unavailableGameApi("sampIs3dTextDefined") end

local _sampev = {}
_sampev.available = false -- no verified live game event source is installed
package.preload["samp.events"] = function() return _sampev end
package.preload["lib.samp.events"] = function() return _sampev end

function _DISPATCH_SAMP_EVENT(name, ...)
    local fn = _sampev[name]
    if type(fn) == "function" then
        return fn(...)
    end
end

package.preload["inicfg"] = function()
    local inicfg = {}
    local cfgDir = getWorkingDirectory() .. "/config/"

    local function resolvePath(filename)
        if not filename then filename = "default.ini" end
        if filename:find("^/") then return filename end
        if not filename:match("%.ini$") then filename = filename .. ".ini" end
        return cfgDir .. filename
    end

    local function deepCopy(t)
        local r = {}
        for k, v in pairs(t or {}) do
            r[k] = type(v) == "table" and deepCopy(v) or v
        end
        return r
    end

    function inicfg.load(defaultTbl, filename)
        local data = deepCopy(defaultTbl)
        local path = resolvePath(filename)
        local f = io.open(path, "r")
        if not f then return data end
        local section = nil
        for line in f:lines() do
            line = line:gsub("\r$", "")
            local sec = line:match("^%s*%[([^%]]+)%]%s*$")
            if sec then
                section = sec
                data[section] = data[section] or {}
            else
                local k, v = line:match("^%s*([^=;#]+)%s*=%s*(.-)%s*$")
                if k and v then
                    local target = section and (data[section] or {}) or data
                    if section then data[section] = target end
                    if v == "true" then target[k] = true
                    elseif v == "false" then target[k] = false
                    elseif tonumber(v) then target[k] = tonumber(v)
                    else target[k] = v end
                end
            end
        end
        f:close()
        return data
    end

    function inicfg.save(data, filename)
        local path = resolvePath(filename)
        local f = io.open(path, "w")
        if not f then return false end
        for k, v in pairs(data or {}) do
            if type(v) == "table" then
                f:write("[" .. tostring(k) .. "]\n")
                for sk, sv in pairs(v) do
                    f:write(tostring(sk) .. "=" .. tostring(sv) .. "\n")
                end
                f:write("\n")
            else
                f:write(tostring(k) .. "=" .. tostring(v) .. "\n")
            end
        end
        f:close()
        return true
    end

    return inicfg
end

package.preload["encoding"] = function()
    local encoding = { default = "CP1251" }
    local function makeEncoding(convert, reverse)
        return setmetatable({}, {
            __call = function(_, s) return convert(tostring(s or "")) end,
            __index = {
                decode = function(_, s) return convert(tostring(s or "")) end,
                encode = function(_, s) return reverse(tostring(s or "")) end
            }
        })
    end
    encoding.UTF8 = makeEncoding(__az_cp1251_to_utf8, __az_utf8_to_cp1251)
    encoding.CP1251 = makeEncoding(__az_utf8_to_cp1251, __az_cp1251_to_utf8)
    return encoding
end

local _json_null = setmetatable({}, { __tostring = function() return "null" end })
local function _json_encode(val)
    local t = type(val)
    if val == _json_null or val == nil then return "null"
    elseif t == "boolean" then return val and "true" or "false"
    elseif t == "number" then
        if val ~= val or val == math.huge or val == -math.huge then
            error("non-finite numbers are not valid JSON", 2)
        end
        return tostring(val)
    elseif t == "string" then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\b', '\\b'):gsub('\f', '\\f'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t'):gsub('%c', function(c) return string.format('\\u%04x', c:byte()) end) .. '"'
    elseif t == "table" then
        local isArr = (#val > 0)
        local parts = {}
        if isArr then
            for i = 1, #val do parts[#parts + 1] = _json_encode(val[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(val) do
                parts[#parts + 1] = _json_encode(tostring(k)) .. ":" .. _json_encode(v)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    error("unsupported value in JSON encode: " .. t, 2)
end

local function _json_decode(str)
    if type(str) ~= "string" then error("JSON decode expects a string", 2) end
    local i, n = 1, #str
    local function fail(message) error("JSON decode error at byte " .. i .. ": " .. message, 0) end
    local function skipws()
        while i <= n and str:sub(i, i):match("%s") do i = i + 1 end
    end
    local function parseString()
        if str:sub(i, i) ~= '"' then fail("expected string") end
        i = i + 1
        local out, start = {}, i
        while i <= n do
            local c = str:sub(i, i)
            if c == '"' then
                out[#out + 1] = str:sub(start, i - 1)
                i = i + 1
                return table.concat(out)
            elseif c == "\\" then
                out[#out + 1] = str:sub(start, i - 1)
                i = i + 1
                local e = str:sub(i, i)
                local simple = { ['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t' }
                if simple[e] then
                    out[#out + 1] = simple[e]
                    i = i + 1
                elseif e == "u" then
                    local hex = str:sub(i + 1, i + 4)
                    local cp = tonumber(hex, 16)
                    if not cp or #hex ~= 4 then fail("invalid unicode escape") end
                    i = i + 5
                    if cp >= 0xD800 and cp <= 0xDBFF and str:sub(i, i + 1) == "\\u" then
                        local lowHex = str:sub(i + 2, i + 5)
                        local low = tonumber(lowHex, 16)
                        if not low or low < 0xDC00 or low > 0xDFFF then fail("invalid surrogate pair") end
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + low - 0xDC00
                        i = i + 6
                    elseif cp >= 0xD800 and cp <= 0xDFFF then fail("unpaired surrogate") end
                    out[#out + 1] = utf8.char(cp)
                else fail("invalid string escape") end
                start = i
            elseif c:byte() < 32 then fail("control character in string")
            else i = i + 1 end
        end
        fail("unterminated string")
    end
    local parseValue
    parseValue = function()
        skipws()
        local c = str:sub(i, i)
        if c == '"' then return parseString()
        elseif c == "{" then
            i = i + 1; skipws()
            local obj = {}
            if str:sub(i, i) == "}" then i = i + 1; return obj end
            while true do
                skipws(); local key = parseString(); skipws()
                if str:sub(i, i) ~= ":" then fail("expected ':'") end
                i = i + 1; obj[key] = parseValue(); skipws()
                local sep = str:sub(i, i); i = i + 1
                if sep == "}" then return obj elseif sep ~= "," then fail("expected ',' or '}'") end
            end
        elseif c == "[" then
            i = i + 1; skipws()
            local arr = {}
            if str:sub(i, i) == "]" then i = i + 1; return arr end
            while true do
                arr[#arr + 1] = parseValue(); skipws()
                local sep = str:sub(i, i); i = i + 1
                if sep == "]" then return arr elseif sep ~= "," then fail("expected ',' or ']' ") end
            end
        elseif str:sub(i, i + 3) == "true" then i = i + 4; return true
        elseif str:sub(i, i + 4) == "false" then i = i + 5; return false
        elseif str:sub(i, i + 3) == "null" then i = i + 4; return _json_null
        else
            local token = str:sub(i):match("^-?%d+%.?%d*[eE]?[%+%-]?%d*")
            local valid = token and (token:match("^-?%d+$") or token:match("^-?%d+%.%d+$") or token:match("^-?%d+[eE][%+%-]?%d+$") or token:match("^-?%d+%.%d+[eE][%+%-]?%d+$"))
            if valid and not token:match("^-?0%d") and tonumber(token) then i = i + #token; return tonumber(token) end
            fail("expected a JSON value")
        end
    end
    local value = parseValue(); skipws()
    if i <= n then fail("trailing data") end
    return value
end

encodeJson = _json_encode
decodeJson = _json_decode
local _json_mod = { encode = _json_encode, decode = _json_decode, null = _json_null }
package.preload["cjson"] = function() return _json_mod end
package.preload["json"] = function() return _json_mod end

package.preload["vkeys"] = function()
    return {
        VK_LBUTTON = 0x01, VK_RBUTTON = 0x02, VK_BACK = 0x08, VK_TAB = 0x09,
        VK_RETURN = 0x0D, VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12,
        VK_ESCAPE = 0x1B, VK_SPACE = 0x20, VK_LEFT = 0x25, VK_UP = 0x26,
        VK_RIGHT = 0x27, VK_DOWN = 0x28, VK_DELETE = 0x2E,
        VK_0 = 0x30, VK_1 = 0x31, VK_2 = 0x32, VK_3 = 0x33, VK_4 = 0x34,
        VK_5 = 0x35, VK_6 = 0x36, VK_7 = 0x37, VK_8 = 0x38, VK_9 = 0x39,
        VK_A = 0x41, VK_B = 0x42, VK_C = 0x43, VK_D = 0x44, VK_E = 0x45,
        VK_F = 0x46, VK_G = 0x47, VK_H = 0x48, VK_I = 0x49, VK_J = 0x4A,
        VK_K = 0x4B, VK_L = 0x4C, VK_M = 0x4D, VK_N = 0x4E, VK_O = 0x4F,
        VK_P = 0x50, VK_Q = 0x51, VK_R = 0x52, VK_S = 0x53, VK_T = 0x54,
        VK_U = 0x55, VK_V = 0x56, VK_W = 0x57, VK_X = 0x58, VK_Y = 0x59, VK_Z = 0x5A,
        VK_F1 = 0x70, VK_F2 = 0x71, VK_F3 = 0x72, VK_F4 = 0x73, VK_F5 = 0x74,
        VK_F6 = 0x75, VK_F7 = 0x76, VK_F8 = 0x77, VK_F9 = 0x78, VK_F10 = 0x79,
        VK_F11 = 0x7A, VK_F12 = 0x7B
    }
end

local function unsupportedMobileMemoryAPI(name)
    return function()
        error(name .. " is unavailable: arbitrary process memory and native FFI are not exposed on iOS", 2)
    end
end

package.preload["ffi"] = function()
    return setmetatable({}, { __index = function(_, key) return unsupportedMobileMemoryAPI("ffi." .. tostring(key)) end })
end

package.preload["memory"] = function()
    return setmetatable({}, { __index = function(_, key) return unsupportedMobileMemoryAPI("memory." .. tostring(key)) end })
end

package.preload["lfs"] = function()
    return {
        currentdir = function() return getWorkingDirectory() end,
        mkdir = function(p) return createDirectory(p) end,
        attributes = function(p) return doesFileExist(p) and { mode = "file" } or (doesDirectoryExist(p) and { mode = "directory" } or nil) end
    }
end

package.preload["mimgui"] = function()
    local m = setmetatable({}, { __index = imgui })
    m.new = {
        bool = function(v) return { [0] = v or false } end,
        int = function(v) return { [0] = v or 0 } end,
        float = function(v) return { [0] = v or 0.0 } end,
        char = setmetatable({}, { __index = function() return function(s) return { _val = s or "" } end end })
    }
    m.StrCopy = function(dst, src) if type(dst) == "table" then dst._val = tostring(src or "") end end
    m.OnInitialize = function(fn) if type(fn) == "function" then fn() end end
    return m
end

json = _json_mod
cjson = _json_mod
inicfg = require("inicfg")
encoding = require("encoding")
mimgui = require("mimgui")
az.capabilities = {
    haptics = "supported",
    clipboard = "partial",
    notifications = "loader_overlay_only",
    http = "partial_get_post",
    files = "app_container_only",
    imgui = "partial_touch_subset",
    render = "overlay_primitives",
    memory = "24_mib_per_script_128_mib_total",
    samp_events = "unavailable_no_verified_game_hook",
    game_chat = "unavailable_no_verified_abi",
    game_state = "unavailable_no_verified_abi",
    game_clock_weather = "unavailable_no_verified_abi",
    ffi_memory = "unavailable"
}
)lua";

static int l_imgui_Begin(lua_State* L) {
    const char* name = luaL_checkstring(L, 1);
    bool open = true;
    bool hasClose = lua_isboolean(L, 2) || lua_istable(L, 2);
    if (lua_isboolean(L, 2)) open = lua_toboolean(L, 2);
    else if (lua_istable(L, 2)) {
        lua_getfield(L, 2, "v"); open = lua_toboolean(L, -1); lua_pop(L, 1);
    }
    bool visible = ImGui::Begin(name, hasClose ? &open : nullptr);
    lua_pushboolean(L, visible);
    if (hasClose) {
        if (lua_istable(L, 2)) {
            lua_pushboolean(L, open); lua_setfield(L, 2, "v");
            lua_pushvalue(L, 2);
        } else lua_pushboolean(L, open);
        return 2;
    }
    return 1;
}
static int l_imgui_End(lua_State* L) { ImGui::End(); return 0; }
static int l_imgui_Text(lua_State* L) {
    const char* txt = luaL_checkstring(L, 1);
    ImGui::PushTextWrapPos(0.0f);
    ImGui::TextUnformatted(txt);
    ImGui::PopTextWrapPos();
    return 0;
}
static int l_imgui_Button(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    lua_pushboolean(L, ImGui::Button(label));
    return 1;
}
static int l_imgui_SameLine(lua_State* L) { ImGui::SameLine(); return 0; }
static int l_imgui_Separator(lua_State* L) { ImGui::Separator(); return 0; }
static int l_imgui_ImBool(lua_State* L) {
    lua_newtable(L); lua_pushboolean(L, lua_toboolean(L, 1)); lua_setfield(L, -2, "v"); return 1;
}
static int l_imgui_ImFloat(lua_State* L) {
    lua_newtable(L); lua_pushnumber(L, luaL_optnumber(L, 1, 0.0)); lua_setfield(L, -2, "v"); return 1;
}
static int l_imgui_SliderFloat(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    float value = 0.0f;
    lua_getfield(L, 2, "v"); value = static_cast<float>(luaL_optnumber(L, -1, 0.0)); lua_pop(L, 1);
    float minValue = static_cast<float>(luaL_checknumber(L, 3));
    float maxValue = static_cast<float>(luaL_checknumber(L, 4));
    bool changed = ImGui::SliderFloat(label, &value, minValue, maxValue);
    if (changed) { lua_pushnumber(L, value); lua_setfield(L, 2, "v"); }
    lua_pushboolean(L, changed); return 1;
}
static int l_imgui_Slider(lua_State* L) {
    const char* label = luaL_checkstring(L, 1);
    float value = static_cast<float>(luaL_checknumber(L, 2));
    float minValue = static_cast<float>(luaL_checknumber(L, 3));
    float maxValue = static_cast<float>(luaL_checknumber(L, 4));
    ImGui::SliderFloat(label, &value, minValue, maxValue);
    lua_pushnumber(L, value); return 1;
}
static int l_imgui_OnFrame(lua_State* L) {
    int drawIdx = lua_isfunction(L, 2) ? 2 : 1;
    luaL_checktype(L, drawIdx, LUA_TFUNCTION);
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    LuaScriptInstance* inst = FindScriptByState(L);
    if (inst) {
        if (inst->renderCallbackRef != LUA_NOREF) {
            luaL_unref(inst->L, LUA_REGISTRYINDEX, inst->renderCallbackRef);
        }
        lua_pushvalue(L, drawIdx);
        inst->renderCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX);
    }
    return 0;
}

static uint32_t ReadRenderColor(lua_State* L, int index) {
    return static_cast<uint32_t>(luaL_optinteger(L, index, 0xFFFFFFFF));
}

static int l_renderDrawText(lua_State* L) {
    size_t length = 0;
    const char* text = luaL_checklstring(L, 1, &length);
    RenderCommand cmd; cmd.kind = RenderCommand::Text;
    cmd.text.assign(text, length);
    cmd.x1 = static_cast<float>(luaL_checknumber(L, 2));
    cmd.y1 = static_cast<float>(luaL_checknumber(L, 3));
    if (!std::isfinite(cmd.x1) || !std::isfinite(cmd.y1)) return luaL_error(L, "text coordinates must be finite");
    cmd.color = ReadRenderColor(L, 4);
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    if (g_RenderCommands.size() < 2048) g_RenderCommands.push_back(std::move(cmd));
    return 0;
}

static int l_renderDrawLine(lua_State* L) {
    RenderCommand cmd; cmd.kind = RenderCommand::Line;
    cmd.x1 = static_cast<float>(luaL_checknumber(L, 1));
    cmd.y1 = static_cast<float>(luaL_checknumber(L, 2));
    cmd.x2 = static_cast<float>(luaL_checknumber(L, 3));
    cmd.y2 = static_cast<float>(luaL_checknumber(L, 4));
    cmd.thickness = static_cast<float>(luaL_optnumber(L, 5, 1.0));
    cmd.color = ReadRenderColor(L, 6);
    if (!std::isfinite(cmd.x1) || !std::isfinite(cmd.y1) || !std::isfinite(cmd.x2) ||
        !std::isfinite(cmd.y2) || !std::isfinite(cmd.thickness))
        return luaL_error(L, "line coordinates and thickness must be finite");
    cmd.thickness = std::max(0.5f, std::min(cmd.thickness, 20.0f));
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    if (g_RenderCommands.size() < 2048) g_RenderCommands.push_back(std::move(cmd));
    return 0;
}

static int l_renderDrawBox(lua_State* L) {
    RenderCommand cmd; cmd.kind = RenderCommand::Box;
    cmd.x1 = static_cast<float>(luaL_checknumber(L, 1));
    cmd.y1 = static_cast<float>(luaL_checknumber(L, 2));
    float width = static_cast<float>(luaL_checknumber(L, 3));
    float height = static_cast<float>(luaL_checknumber(L, 4));
    cmd.x2 = cmd.x1 + width;
    cmd.y2 = cmd.y1 + height;
    cmd.color = ReadRenderColor(L, 5);
    if (!std::isfinite(cmd.x1) || !std::isfinite(cmd.y1) || !std::isfinite(width) ||
        !std::isfinite(height) || !std::isfinite(cmd.x2) || !std::isfinite(cmd.y2))
        return luaL_error(L, "box coordinates and dimensions must be finite");
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    if (g_RenderCommands.size() < 2048) g_RenderCommands.push_back(std::move(cmd));
    return 0;
}

static int l_renderDrawCircle(lua_State* L) {
    RenderCommand cmd; cmd.kind = RenderCommand::Circle;
    cmd.x1 = static_cast<float>(luaL_checknumber(L, 1));
    cmd.y1 = static_cast<float>(luaL_checknumber(L, 2));
    cmd.x2 = static_cast<float>(luaL_checknumber(L, 3)); // radius
    cmd.segments = static_cast<int>(luaL_optinteger(L, 4, 24));
    cmd.color = ReadRenderColor(L, 5);
    if (!std::isfinite(cmd.x1) || !std::isfinite(cmd.y1) || !std::isfinite(cmd.x2) || cmd.x2 < 0)
        return luaL_error(L, "circle coordinates and radius must be finite and radius non-negative");
    cmd.segments = std::max(3, std::min(cmd.segments, 128));
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    if (g_RenderCommands.size() < 2048) g_RenderCommands.push_back(std::move(cmd));
    return 0;
}

static ImU32 ImColorFromARGB(uint32_t color) {
    return IM_COL32((color >> 16) & 0xFF, (color >> 8) & 0xFF,
                    color & 0xFF, (color >> 24) & 0xFF);
}

static void RenderQueuedPrimitives() {
    std::vector<RenderCommand> commands;
    {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        commands.swap(g_RenderCommands);
    }
    ImDrawList* draw = ImGui::GetForegroundDrawList();
    for (const auto& cmd : commands) {
        const ImU32 color = ImColorFromARGB(cmd.color);
        switch (cmd.kind) {
            case RenderCommand::Text:
                draw->AddText(ImVec2(cmd.x1, cmd.y1), color, cmd.text.c_str()); break;
            case RenderCommand::Line:
                draw->AddLine(ImVec2(cmd.x1, cmd.y1), ImVec2(cmd.x2, cmd.y2), color, cmd.thickness); break;
            case RenderCommand::Box:
                draw->AddRectFilled(ImVec2(cmd.x1, cmd.y1), ImVec2(cmd.x2, cmd.y2), color); break;
            case RenderCommand::Circle:
                draw->AddCircle(ImVec2(cmd.x1, cmd.y1), cmd.x2, color, cmd.segments); break;
        }
    }
}

static void RegisterAllLuaAPI(lua_State* L, const std::string& filename, const std::string& fullPath) {
    OpenSafeLuaLibraries(L);

    std::string base = GetBaseDir();
    std::string pkgCode = "package.path = package.path .. ';" + base + "/lib/?.lua;" + base + "/lib/?/init.lua'";
    if (luaL_dostring(L, pkgCode.c_str()) != LUA_OK) {
        const char* error = lua_tostring(L, -1);
        LogConsole(std::string("[Package path ERROR] ") + (error ? error : "unknown error"));
        lua_pop(L, 1);
    }

    lua_register(L, "print", l_print);
    lua_register(L, "wait", l_wait);
    lua_register(L, "__az_cp1251_to_utf8", l_cp1251ToUtf8);
    lua_register(L, "__az_utf8_to_cp1251", l_utf8ToCp1251);

    lua_newtable(L);
    lua_pushcfunction(L, l_lua_thread_create); lua_setfield(L, -2, "create");
    lua_pushcfunction(L, l_lua_thread_create_suspended); lua_setfield(L, -2, "create_suspended");
    lua_pushcfunction(L, l_lua_thread_resume); lua_setfield(L, -2, "resume");
    lua_pushcfunction(L, l_lua_thread_is_active); lua_setfield(L, -2, "isThreadActive");
    lua_pushcfunction(L, l_lua_thread_terminate_all); lua_setfield(L, -2, "terminateAllThreads");
    lua_setglobal(L, "lua_thread");
    lua_register(L, "isThreadActive", l_lua_thread_is_active);
    lua_register(L, "terminateAllThreads", l_lua_thread_terminate_all);

    lua_register(L, "sampRegisterChatCommand", l_sampRegisterChatCommand);
    lua_register(L, "sampUnregisterChatCommand", l_sampUnregisterChatCommand);
    lua_register(L, "sampIsChatCommandDefined", l_sampIsChatCommandDefined);
    lua_register(L, "sampAddChatMessage", l_sampAddChatMessage);
    lua_register(L, "sampSendChat", l_sampSendChat);
    lua_register(L, "sampProcessChatInput", l_sampProcessChatInput);
    lua_register(L, "sampShowDialog", l_sampShowDialog);
    lua_register(L, "sampGetCurrentDialogId", l_sampGetCurrentDialogId);
    lua_register(L, "sampGetCurrentDialogStyle", l_sampGetCurrentDialogStyle);
    lua_register(L, "sampIsDialogActive", l_sampIsDialogActive);
    lua_register(L, "sampGetDialogText", l_sampGetDialogText);
    lua_register(L, "sampGetDialogCaption", l_sampGetDialogCaption);
    lua_register(L, "sampIsChatInputActive", l_sampIsChatInputActive);
    lua_register(L, "sampGetChatInputText", l_sampGetChatInputText);
    lua_register(L, "sampSetChatInputText", l_sampSetChatInputText);
    lua_register(L, "sampSetChatInputEnabled", l_sampSetChatInputEnabled);
    lua_register(L, "sampGetChatString", l_sampGetChatString);
    lua_register(L, "isSampAvailable", l_isSampAvailable);
    lua_register(L, "isSampfuncsLoaded", l_isSampfuncsLoaded);
    lua_register(L, "sampGetGamestate", l_sampGetGamestate);

    lua_register(L, "setTimeOfDay", l_setTimeOfDay);
    lua_register(L, "getTimeOfDay", l_getTimeOfDay);
    lua_register(L, "forceWeatherNow", l_forceWeatherNow);
    lua_register(L, "getScreenResolution", l_getScreenResolution);
    lua_register(L, "getWorkingDirectory", l_getWorkingDirectory);
    lua_register(L, "getGameDirectory", l_getGameDirectory);
    lua_register(L, "doesFileExist", l_doesFileExist);
    lua_register(L, "doesDirectoryExist", l_doesDirectoryExist);
    lua_register(L, "createDirectory", l_createDirectory);
    lua_register(L, "asyncHttpRequest", l_asyncHttpRequest);
    lua_register(L, "sendLocalNotification", l_sendLocalNotification);
    lua_register(L, "renderDrawText", l_renderDrawText);
    lua_register(L, "renderDrawLine", l_renderDrawLine);
    lua_register(L, "renderDrawBox", l_renderDrawBox);
    lua_register(L, "renderDrawCircle", l_renderDrawCircle);

    lua_newtable(L);
    lua_pushcfunction(L, l_sampAddChatMessage); lua_setfield(L, -2, "chat");
    lua_pushcfunction(L, l_sampSendChat); lua_setfield(L, -2, "send");
    lua_pushcfunction(L, l_az_notify); lua_setfield(L, -2, "notify");
    lua_pushcfunction(L, l_az_banner); lua_setfield(L, -2, "banner");
    lua_pushcfunction(L, l_az_vibrate); lua_setfield(L, -2, "vibrate");
    lua_pushcfunction(L, l_az_setClipboard); lua_setfield(L, -2, "setClipboard");
    lua_pushcfunction(L, l_az_getClipboard); lua_setfield(L, -2, "getClipboard");
    lua_pushcfunction(L, l_az_openURL); lua_setfield(L, -2, "openURL");
    lua_pushcfunction(L, l_az_getLoaderRAM); lua_setfield(L, -2, "getLoaderRAM");
    lua_pushliteral(L, "42Loader/1.0"); lua_setfield(L, -2, "version");
    lua_setglobal(L, "az");

    lua_newtable(L);
    lua_pushcfunction(L, l_imgui_Begin); lua_setfield(L, -2, "Begin");
    lua_pushcfunction(L, l_imgui_End); lua_setfield(L, -2, "End");
    lua_pushcfunction(L, l_imgui_Text); lua_setfield(L, -2, "Text");
    lua_pushcfunction(L, l_imgui_Text); lua_setfield(L, -2, "TextWrapped");
    lua_pushcfunction(L, l_imgui_Button); lua_setfield(L, -2, "Button");
    lua_pushcfunction(L, l_imgui_SameLine); lua_setfield(L, -2, "SameLine");
    lua_pushcfunction(L, l_imgui_Separator); lua_setfield(L, -2, "Separator");
    lua_pushcfunction(L, l_imgui_OnFrame); lua_setfield(L, -2, "OnFrame");
    lua_pushcfunction(L, l_imgui_ImBool); lua_setfield(L, -2, "ImBool");
    lua_pushcfunction(L, l_imgui_ImFloat); lua_setfield(L, -2, "ImFloat");
    lua_pushcfunction(L, l_imgui_SliderFloat); lua_setfield(L, -2, "SliderFloat");
    lua_pushcfunction(L, l_imgui_Slider); lua_setfield(L, -2, "Slider");
    lua_pushboolean(L, 0); lua_setfield(L, -2, "Process");
    lua_setglobal(L, "imgui");

    if (luaL_dostring(L, kMoonLoaderBootstrapLua) != LUA_OK) {
        const char* err = lua_tostring(L, -1);
        LogConsole("[Bootstrap ERROR] " + std::string(err ? err : "unknown"));
        lua_pop(L, 1);
    }

    lua_getglobal(L, "_SCRIPT_META");
    if (lua_istable(L, -1)) {
        lua_pushstring(L, filename.c_str()); lua_setfield(L, -2, "filename");
        lua_pushstring(L, fullPath.c_str()); lua_setfield(L, -2, "path");
    }
    lua_pop(L, 1);
}

// ============================================================================
// 7. SCRIPT LOADING, RELOADING & TICKING
// ============================================================================

static void UnloadSingleScript(LuaScriptInstance* inst) {
    if (!inst) return;
    if (inst->L && inst->id) {
        for (auto it = g_HttpCompletions.begin(); it != g_HttpCompletions.end(); ) {
            if (it->ownerId == inst->id) {
                if (it->successRef != LUA_NOREF) luaL_unref(inst->L, LUA_REGISTRYINDEX, it->successRef);
                if (it->errorRef != LUA_NOREF) luaL_unref(inst->L, LUA_REGISTRYINDEX, it->errorRef);
                it = g_HttpCompletions.erase(it);
            } else {
                ++it;
            }
        }
    }
    for (auto it = g_ChatCommands.begin(); it != g_ChatCommands.end(); ) {
        if (it->second.L == inst->L) {
            it = g_ChatCommands.erase(it);
        } else {
            ++it;
        }
    }
    if (inst->L) {
        lua_close(inst->L);
        inst->L = nullptr;
    }
    inst->threads.clear();
    inst->renderCallbackRef = LUA_NOREF;
}

static void LoadSingleScript(LuaScriptInstance* inst) {
    UnloadSingleScript(inst);
    inst->hasError = false;
    inst->lastError.clear();

    FILE* f = fopen(inst->fullPath.c_str(), "rb");
    if (!f) {
        inst->hasError = true;
        inst->lastError = "Unable to open script: " + ShortenPathForUI(inst->fullPath);
        return;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        inst->hasError = true;
        inst->lastError = "Unable to seek script file";
        return;
    }
    long sz = ftell(f);
    if (sz < 0 || sz > 4 * 1024 * 1024 || fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        inst->hasError = true;
        inst->lastError = "Script file is unreadable or exceeds 4 MiB";
        return;
    }
    std::string code(static_cast<size_t>(sz), '\0');
    if (sz > 0 && fread(&code[0], 1, static_cast<size_t>(sz), f) != static_cast<size_t>(sz)) {
        fclose(f);
        inst->hasError = true;
        inst->lastError = "Unable to read complete script file";
        return;
    }
    fclose(f);

    if (code.size() >= 3 &&
        static_cast<unsigned char>(code[0]) == 0xEF &&
        static_cast<unsigned char>(code[1]) == 0xBB &&
        static_cast<unsigned char>(code[2]) == 0xBF) {
        code.erase(0, 3);
    }

    lua_State* L = lua_newstate(BoundedLuaAllocator, &inst->allocator);
    if (!L) {
        inst->hasError = true;
        inst->lastError = "Unable to create Lua state (out of memory)";
        return;
    }
    inst->L = L;
    inst->id = g_NextScriptId++;
    RegisterAllLuaAPI(L, inst->filename, inst->fullPath);

    std::string chunkName = "@" + ShortenPathForUI(inst->fullPath);
    if (luaL_loadbuffer(L, code.c_str(), code.size(), chunkName.c_str()) != LUA_OK) {
        const char* err = lua_tostring(L, -1);
        inst->hasError = true;
        inst->lastError = err ? err : "Syntax error";
        LogConsole("[ERROR] " + inst->lastError);
        lua_pop(L, 1);
        return;
    }

    if (ProtectedLuaCall(L, 0, 0, 1000000) != LUA_OK) {
        const char* err = lua_tostring(L, -1);
        inst->hasError = true;
        inst->lastError = err ? err : "Runtime error";
        LogConsole("[ERROR] " + inst->lastError);
        lua_pop(L, 1);
        return;
    }

    lua_getglobal(L, "imgui");
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "OnDrawFrame");
        if (lua_isfunction(L, -1)) {
            inst->renderCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX);
        } else lua_pop(L, 1);
    }
    lua_pop(L, 1);

    lua_getglobal(L, "onScriptLoad");
    if (lua_isfunction(L, -1)) {
        if (ProtectedLuaCall(L, 0, 0) != LUA_OK) {
            LogConsole("[onScriptLoad ERROR] " + std::string(lua_tostring(L, -1) ?: ""));
            lua_pop(L, 1);
        }
    } else {
        lua_pop(L, 1);
    }

    lua_getglobal(L, "main");
    if (lua_isfunction(L, -1)) {
        lua_State* co = lua_newthread(L);
        int ref = luaL_ref(L, LUA_REGISTRYINDEX);
        lua_xmove(L, co, 1);

        LuaCoroutine lc;
        lc.co = co;
        lc.ref = ref;
        lc.wakeTimeMs = NowMs();
        inst->threads.push_back(lc);
    } else {
        lua_pop(L, 1);
    }

    LogConsole("[OK] Loaded script: " + inst->filename);
}

static void ReloadAllScripts() {
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    EnsureDirectories();

    for (auto* s : g_Scripts) {
        UnloadSingleScript(s);
        delete s;
    }
    g_Scripts.clear();
    g_ChatCommands.clear();

    std::string scriptsDir = GetBaseDir() + "/scripts";
    NSString* nsDir = [NSString stringWithUTF8String:scriptsDir.c_str()];
    NSArray* files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:nsDir error:nil];

    int okCount = 0;
    int errCount = 0;

    for (NSString* file in files) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"lua"]) continue;
        if (g_Scripts.size() >= 256) {
            LogConsole("[WARN] Script limit reached (256); remaining files skipped");
            break;
        }
        auto* inst = new LuaScriptInstance();
        inst->filename = [file UTF8String];
        inst->fullPath = scriptsDir + "/" + inst->filename;
        inst->displayName = inst->filename;
        g_Scripts.push_back(inst);
        LoadSingleScript(inst);
        if (inst->hasError) errCount++;
        else okCount++;
    }

    NSString* bannerMsg = nil;
    if (errCount > 0) {
        bannerMsg = [NSString stringWithFormat:@"42Loader: loaded %d | errors %d", okCount, errCount];
    } else if (okCount > 0) {
        bannerMsg = [NSString stringWithFormat:@"42Loader: loaded %d scripts (%zu local commands)", okCount, g_ChatCommands.size()];
    } else {
        bannerMsg = @"42Loader active (no scripts found)";
    }
    ShowLauncherBanner(bannerMsg, errCount > 0);
}

static void TickScripts() {
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    uint64_t now = NowMs();

    while (!g_HttpCompletions.empty()) {
        HttpCompletion completion = std::move(g_HttpCompletions.front());
        g_HttpCompletions.pop_front();
        LuaScriptInstance* owner = nullptr;
        for (auto* script : g_Scripts) {
            if (script && script->id == completion.ownerId && script->L) { owner = script; break; }
        }
        if (!owner) continue;

        int callbackRef = completion.succeeded ? completion.successRef : completion.errorRef;
        if (owner->enabled && !owner->hasError && callbackRef != LUA_NOREF) {
            lua_rawgeti(owner->L, LUA_REGISTRYINDEX, callbackRef);
            if (completion.succeeded) {
                lua_newtable(owner->L);
                lua_pushinteger(owner->L, completion.statusCode);
                lua_setfield(owner->L, -2, "status_code");
                lua_pushlstring(owner->L, completion.text.data(), completion.text.size());
                lua_setfield(owner->L, -2, "text");
                lua_newtable(owner->L);
                for (const auto& header : completion.headers) {
                    lua_pushlstring(owner->L, header.second.data(), header.second.size());
                    lua_setfield(owner->L, -2, header.first.c_str());
                }
                lua_setfield(owner->L, -2, "headers");
            } else {
                lua_pushlstring(owner->L, completion.error.data(), completion.error.size());
            }
            if (ProtectedLuaCall(owner->L, 1, 0) != LUA_OK) {
                const char* error = lua_tostring(owner->L, -1);
                LogConsole(std::string("[HTTP callback ERROR] ") + (error ? error : "unknown error"));
                lua_pop(owner->L, 1);
            }
        }
        if (completion.successRef != LUA_NOREF) luaL_unref(owner->L, LUA_REGISTRYINDEX, completion.successRef);
        if (completion.errorRef != LUA_NOREF) luaL_unref(owner->L, LUA_REGISTRYINDEX, completion.errorRef);
    }

    for (auto* s : g_Scripts) {
        if (!s->enabled || !s->L || s->hasError) continue;

        for (size_t i = 0; i < s->threads.size(); ) {
            LuaCoroutine& t = s->threads[i];
            if (t.finished) {
                if (t.ref != LUA_NOREF) luaL_unref(s->L, LUA_REGISTRYINDEX, t.ref);
                s->threads.erase(s->threads.begin() + i);
                continue;
            }
            if (t.suspended || now < t.wakeTimeMs) {
                i++;
                continue;
            }

            int nres = 0;
            // Prevent a single tight Lua loop from monopolizing the render
            // scheduler indefinitely. The hook is refreshed on every resume.
            lua_sethook(t.co, LuaInstructionLimit, LUA_MASKCOUNT, 250000);
            int status = lua_resume(t.co, s->L, 0, &nres);
            lua_sethook(t.co, nullptr, 0, 0);
            if (s->hasError) {
                ReleaseScriptThreads(s);
                break;
            }
            if (status == LUA_YIELD) {
                lua_Integer waitMs = (nres >= 1 && lua_isinteger(t.co, -1)) ? lua_tointeger(t.co, -1) : 0;
                if (nres > 0) lua_pop(t.co, nres);
                t.wakeTimeMs = now + static_cast<uint64_t>(waitMs > 0 ? waitMs : 0);
                i++;
            } else if (status == LUA_OK) {
                if (nres > 0) lua_pop(t.co, nres);
                luaL_unref(s->L, LUA_REGISTRYINDEX, t.ref);
                s->threads.erase(s->threads.begin() + i);
            } else {
                const char* err = lua_tostring(t.co, -1);
                s->hasError = true;
                s->lastError = err ? err : "Coroutine error";
                LogConsole("[ERROR] " + s->lastError);
                UnregisterScriptCommands(s);
                ReleaseScriptThreads(s);
                break;
            }
        }
    }
}

static void ShowCommandPrompt() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow* win = GetActiveKeyWindow();
        UIViewController* presenter = win.rootViewController;
        while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed)
            presenter = presenter.presentedViewController;
        if (!presenter) return;

        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Run Loader command"
                                                                       message:@"Enter a local command such as /t_help"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
            field.placeholder = @"/command arguments";
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Run" style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction* action) {
            NSString* value = alert.textFields.firstObject.text ?: @"";
            const char* utf8 = value.UTF8String;
            if (!utf8 || !*utf8) return;
            std::string input(utf8);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                TryExecuteChatCommand(input, "CommandPrompt");
            });
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

// ============================================================================
// 8. DEAR IMGUI OVERLAY AND RENDER API
// ============================================================================

static void RenderLoaderUI() {
    TickScripts();

    ImGuiIO& io = ImGui::GetIO();
    float screenW = io.DisplaySize.x;
    float screenH = io.DisplaySize.y;

    float totalLuaKB = 0.0f;
    {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        for (auto* s : g_Scripts) {
            if (s->L) totalLuaKB += static_cast<float>(lua_gc(s->L, LUA_GCCOUNT, 0));
        }
    }
    char ramStr[96];
    snprintf(ramStr, sizeof(ramStr), "Loader RAM: %.2f MB (Lua: %.0f KB)", GetLoaderRAM_MB(), totalLuaKB);
    ImGui::GetForegroundDrawList()->AddText(ImVec2(screenW - 245, screenH * 0.48f), IM_COL32(220, 220, 230, 180), ramStr);

    {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        uint64_t now = NowMs();
        float ny = 24.0f;
        for (size_t i = 0; i < g_Notifications.size(); ) {
            if (now > g_Notifications[i].expireMs) {
                g_Notifications.erase(g_Notifications.begin() + i);
                continue;
            }
            ImGui::SetNextWindowPos(ImVec2(screenW * 0.5f - 170.0f, ny), ImGuiCond_Always);
            ImGui::SetNextWindowSize(ImVec2(340.0f, 0.0f), ImGuiCond_Always);
            ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.12f, 0.10f, 0.18f, 0.92f));
            char winName[32];
            snprintf(winName, sizeof(winName), "##Notif_%zu", i);
            if (ImGui::Begin(winName, nullptr, ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoInputs)) {
                ImGui::PushTextWrapPos(0.0f);
                ImGui::TextColored(ImVec4(0.68f, 0.45f, 0.98f, 1.0f), "%s", g_Notifications[i].title.c_str());
                ImGui::TextUnformatted(g_Notifications[i].message.c_str());
                ImGui::PopTextWrapPos();
                ny += ImGui::GetWindowHeight() + 6.0f;
            }
            ImGui::End();
            ImGui::PopStyleColor();
            i++;
        }
    }

    {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        for (auto* s : g_Scripts) {
            if (s->enabled && s->L && !s->hasError && s->renderCallbackRef != LUA_NOREF) {
                lua_getglobal(s->L, "imgui");
                lua_getfield(s->L, -1, "Process");
                bool shouldRender = lua_toboolean(s->L, -1);
                lua_pop(s->L, 2);
                if (!shouldRender) continue;
                lua_rawgeti(s->L, LUA_REGISTRYINDEX, s->renderCallbackRef);
                if (ProtectedLuaCall(s->L, 0, 0) != LUA_OK) {
                    s->hasError = true;
                    s->lastError = lua_tostring(s->L, -1) ?: "ImGui render error";
                    lua_pop(s->L, 1);
                    UnregisterScriptCommands(s);
                    ReleaseScriptThreads(s);
                }
            }
        }
    }

    RenderQueuedPrimitives();

    bool menuOpen = false;
    {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        menuOpen = g_MenuOpen;
    }
    if (!menuOpen) return;

    ImGui::SetNextWindowPos(ImVec2(screenW * 0.5f - 260.0f, 36.0f), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSize(ImVec2(520.0f, 310.0f), ImGuiCond_FirstUseEver);
    ImGui::PushStyleColor(ImGuiCol_TitleBgActive, ImVec4(0.32f, 0.18f, 0.52f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.10f, 0.09f, 0.14f, 0.95f));

    if (ImGui::Begin("Arizona 42Loader  |  Lua 5.4 + MoonLoader API", &menuOpen)) {
        if (ImGui::Button("Scripts")) g_SelectedTab = 0;
        ImGui::SameLine();
        if (ImGui::Button("Commands")) g_SelectedTab = 1;
        ImGui::SameLine();
        if (ImGui::Button("Console")) g_SelectedTab = 2;
        ImGui::SameLine();
        if (ImGui::Button("Settings")) g_SelectedTab = 3;

        ImGui::Separator();

        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);

        if (g_SelectedTab == 0) {
            if (ImGui::Button("Reload All Scripts")) {
                ReloadAllScripts();
            }
            ImGui::SameLine();
            ImGui::TextDisabled("Dir: Documents/lua_loader/scripts");
            ImGui::Separator();

            ImGui::BeginChild("##ScriptsList", ImVec2(0, 0), false);
            for (size_t i = 0; i < g_Scripts.size(); i++) {
                LuaScriptInstance* s = g_Scripts[i];
                ImGui::PushID(static_cast<int>(i));
                bool prev = s->enabled;
                if (ImGui::Checkbox("##en", &s->enabled) && prev != s->enabled) {
                    if (s->enabled) LoadSingleScript(s);
                    else UnloadSingleScript(s);
                }
                ImGui::SameLine();
                ImGui::TextUnformatted(s->filename.c_str());
                ImGui::SameLine();
                if (s->hasError) {
                    ImGui::TextColored(ImVec4(1.0f, 0.35f, 0.35f, 1.0f), "[ERROR]");
                } else if (s->enabled) {
                    ImGui::TextColored(ImVec4(0.35f, 0.95f, 0.55f, 1.0f), "[OK]");
                } else {
                    ImGui::TextDisabled("[OFF]");
                }
                ImGui::SameLine();
                if (ImGui::Button("Reload")) {
                    s->enabled = true;
                    LoadSingleScript(s);
                }

                if (s->hasError && !s->lastError.empty()) {
                    ImGui::Indent(24.0f);
                    ImGui::PushTextWrapPos(0.0f);
                    ImGui::TextColored(ImVec4(1.0f, 0.45f, 0.45f, 1.0f), "%s", ShortenPathForUI(s->lastError).c_str());
                    ImGui::PopTextWrapPos();
                    ImGui::Unindent(24.0f);
                }
                ImGui::PopID();
            }
            ImGui::EndChild();

        } else if (g_SelectedTab == 1) {
            ImGui::PushTextWrapPos(0.0f);
            ImGui::TextUnformatted("Commands are local to the Loader. Enter /name below; game chat commands are not hooked.");
            ImGui::PopTextWrapPos();
            ImGui::Separator();

            std::vector<std::string> commandNames;
            commandNames.reserve(g_ChatCommands.size());
            for (const auto& command : g_ChatCommands) commandNames.push_back(command.first);
            for (const auto& name : commandNames) {
                auto it = g_ChatCommands.find(name);
                if (it == g_ChatCommands.end()) continue;
                ImGui::BulletText("/%s  (%s)", name.c_str(), it->second.scriptName.c_str());
                ImGui::SameLine();
                ImGui::PushID(name.c_str());
                if (ImGui::Button("Run")) TryExecuteChatCommand("/" + name, "CommandTab");
                ImGui::PopID();
            }

            ImGui::Separator();
            if (ImGui::Button("Enter command with keyboard")) ShowCommandPrompt();

        } else if (g_SelectedTab == 2) {
            if (ImGui::Button("Clear Console")) {
                g_ConsoleLogs.clear();
            }
            ImGui::Separator();
            ImGui::BeginChild("##ConsoleScroll", ImVec2(0, 0), true);
            ImGui::PushTextWrapPos(0.0f);
            for (const auto& line : g_ConsoleLogs) {
                if (line.find("ERROR") != std::string::npos) {
                    ImGui::TextColored(ImVec4(1.0f, 0.42f, 0.42f, 1.0f), "%s", line.c_str());
                } else {
                    ImGui::TextUnformatted(line.c_str());
                }
            }
            ImGui::PopTextWrapPos();
            if (ImGui::GetScrollY() >= ImGui::GetScrollMaxY()) {
                ImGui::SetScrollHereY(1.0f);
            }
            ImGui::EndChild();

        } else if (g_SelectedTab == 3) {
            ImGui::PushTextWrapPos(0.0f);
            ImGui::TextUnformatted("Game clock/weather bridge: unavailable (ABI not verified)");
            ImGui::Text("Scripts: %zu | Local commands: %zu", g_Scripts.size(), g_ChatCommands.size());
            ImGui::PopTextWrapPos();
        }
    }
    ImGui::End();
    {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        g_MenuOpen = menuOpen;
    }
    ImGui::PopStyleColor(2);
}

// ============================================================================
// 9. METAL RENDER HOOK & ENTRY POINT
// ============================================================================

static bool g_ImGuiInitialized = false;

static void SetupImGuiWithDevice(id<MTLDevice> device) {
    if (g_ImGuiInitialized || !device) return;
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::StyleColorsDark();
    if (!ImGui_ImplMetal_Init(device)) {
        ImGui::DestroyContext();
        return;
    }
    g_ImGuiInitialized = true;
}

static void (*orig_presentDrawable)(id, SEL, id<MTLDrawable>) = nullptr;
static void swizzled_presentDrawable(id self, SEL _cmd, id<MTLDrawable> drawable) {
    if (g_ImGuiInitialized) {
        ImGuiIO& io = ImGui::GetIO();
        CGFloat width, height, scale;
        {
            std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
            width = g_OverlayDisplayWidth;
            height = g_OverlayDisplayHeight;
            scale = g_OverlayScale;
        }
        if (width > 0 && height > 0) {
            io.DisplaySize = ImVec2(width, height);
            io.DisplayFramebufferScale = ImVec2(scale, scale);

            MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            if ([drawable respondsToSelector:@selector(texture)]) {
                rpd.colorAttachments[0].texture = [(id)drawable texture];
                rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
                rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

                id<MTLCommandBuffer> cmdBuf = (id<MTLCommandBuffer>)self;
                id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
                if (enc) {
                    ImGui_ImplMetal_NewFrame(rpd);
                    ApplyQueuedImGuiTouchEvents(io);
                    ImGui::NewFrame();
                    RenderLoaderUI();
                    ImGui::Render();
                    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cmdBuf, enc);
                    [enc endEncoding];
                }
            }
        }
    }
    if (orig_presentDrawable) {
        orig_presentDrawable(self, _cmd, drawable);
    }
}

__attribute__((constructor))
static void LoaderEntry() {
    EnsureDirectories();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        EnsureFloatingMenuButton();
        ReloadAllScripts();

        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        SetupImGuiWithDevice(dev);

        id<MTLCommandQueue> queue = [dev newCommandQueue];
        id<MTLCommandBuffer> buf = [queue commandBuffer];
        Class cmdBufClass = [buf class];
        SEL presentSelector = @selector(presentDrawable:);
        Method m = class_getInstanceMethod(cmdBufClass, presentSelector);
        if (m) {
            IMP original = method_getImplementation(m);
            if (class_addMethod(cmdBufClass, presentSelector, (IMP)swizzled_presentDrawable, method_getTypeEncoding(m))) {
                orig_presentDrawable = (void (*)(id, SEL, id<MTLDrawable>))original;
            } else {
                original = method_setImplementation(m, (IMP)swizzled_presentDrawable);
                orig_presentDrawable = (void (*)(id, SEL, id<MTLDrawable>))original;
            }
        }
        LogConsole("Arizona 42Loader initialized");
    });
}
