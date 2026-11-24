#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <dlfcn.h>

#include <string>
#include <vector>
#include <map>
#include <unordered_map>
#include <mutex>
#include <chrono>
#include <algorithm>
#include <cctype>
#include <cstring>
#include <cstdio>
#include <cmath>

extern "C" {
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
}

#include "imgui.h"
#include "imgui_impl_metal.h"

// ============================================================================
// 1. JNI / SAMP / DYSYM HOOK TYPES
// ============================================================================

typedef void* JNIEnv;
typedef void* jobject;
typedef void* jbyteArray;

typedef void* (*Fn_dlsym)(void* handle, const char* symbol);
typedef void (*Fn_OnInputEnd)(JNIEnv* env, jobject thiz, jbyteArray array);
typedef void (*Fn_SendCommand)(void* thisPtr, const char* cmd);
typedef void (*Fn_SendChat)(void* thisPtr, const char* msg);
typedef void (*Fn_AddChatMessage)(void* thisPtr, uint32_t color, const char* text);
typedef void (*Fn_ShowDialog)(void* thisPtr, int id, int style, const char* title, const char* text, const char* btn1, const char* btn2, bool b);

static Fn_dlsym orig_dlsym = nullptr;
static Fn_OnInputEnd orig_OnInputEnd = nullptr;
static Fn_SendCommand orig_SendCommand = nullptr;
static Fn_SendChat orig_SendChat = nullptr;
static Fn_AddChatMessage orig_AddChatMessage = nullptr;
static Fn_ShowDialog orig_ShowDialog = nullptr;

static JNIEnv* g_LastJNIEnv = nullptr;
static jobject g_LastJObject = nullptr;
static void* g_LastNetGamePtr = nullptr;

// ============================================================================
// 2. ENCODING HELPERS (CP1251 <-> UTF-8)
// ============================================================================

static std::string ToLowerASCII(const std::string& s) {
    std::string out = s;
    for (char& c : out) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return out;
}

static std::string Cp1251ToUtf8(const std::string& str) {
    bool validUtf8 = true;
    size_t i = 0;
    while (i < str.size()) {
        unsigned char c = static_cast<unsigned char>(str[i]);
        if (c < 0x80) { i++; }
        else if ((c >> 5) == 0x6 && i + 1 < str.size() && (static_cast<unsigned char>(str[i+1]) >> 6) == 0x2) { i += 2; }
        else if ((c >> 4) == 0xE && i + 2 < str.size() && (static_cast<unsigned char>(str[i+1]) >> 6) == 0x2 && (static_cast<unsigned char>(str[i+2]) >> 6) == 0x2) { i += 3; }
        else if ((c >> 3) == 0x1E && i + 3 < str.size()) { i += 4; }
        else { validUtf8 = false; break; }
    }
    if (validUtf8) return str;

    std::string out;
    out.reserve(str.size() * 2);
    for (unsigned char c : str) {
        if (c < 0x80) {
            out.push_back(static_cast<char>(c));
        } else if (c == 0xA8) {
            out.append("\xD0\x81");
        } else if (c == 0xB8) {
            out.append("\xD1\x91");
        } else if (c >= 0xC0 && c <= 0xEF) {
            uint16_t cp = 0x0410 + (c - 0xC0);
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (c >= 0xF0) {
            uint16_t cp = 0x0440 + (c - 0xF0);
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back('?');
        }
    }
    return out;
}

static std::string Utf8ToCp1251(const std::string& str) {
    std::string out;
    out.reserve(str.size());
    size_t i = 0;
    while (i < str.size()) {
        unsigned char c = static_cast<unsigned char>(str[i]);
        if (c < 0x80) {
            out.push_back(static_cast<char>(c));
            i++;
        } else if ((c >> 5) == 0x6 && i + 1 < str.size()) {
            uint16_t cp = ((c & 0x1F) << 6) | (static_cast<unsigned char>(str[i + 1]) & 0x3F);
            if (cp == 0x0401) out.push_back(static_cast<char>(0xA8));
            else if (cp == 0x0451) out.push_back(static_cast<char>(0xB8));
            else if (cp >= 0x0410 && cp <= 0x044F) out.push_back(static_cast<char>(0xC0 + (cp - 0x0410)));
            else out.push_back('?');
            i += 2;
        } else {
            out.push_back('?');
            i++;
        }
    }
    return out;
}

// ============================================================================
// 3. DATA STRUCTURES & GLOBAL STATE
// ============================================================================

struct LuaCoroutine {
    lua_State* co = nullptr;
    int ref = LUA_NOREF;
    uint64_t wakeTimeMs = 0;
    bool suspended = false;
    bool finished = false;
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
    std::string filename;
    std::string fullPath;
    std::string displayName;
    lua_State* L = nullptr;
    bool enabled = true;
    bool hasError = false;
    std::string lastError;
    std::vector<LuaCoroutine> threads;
    int renderCallbackRef = LUA_NOREF;
};

struct OverlayNotification {
    std::string title;
    std::string message;
    uint64_t expireMs;
};

static std::recursive_mutex g_EngineMutex;
static std::vector<LuaScriptInstance*> g_Scripts;
static std::unordered_map<std::string, RegisteredCommand> g_ChatCommands;
static std::vector<std::string> g_ConsoleLogs;
static std::vector<ChatHistoryEntry> g_ChatHistory;
static std::vector<OverlayNotification> g_Notifications;

static bool g_MenuOpen = false;
static int g_SelectedTab = 0;
static char g_CmdInputBuf[256] = {0};

static int g_CurrentDialogId = -1;
static int g_CurrentDialogStyle = 0;
static bool g_IsDialogActive = false;
static std::string g_CurrentDialogTitle;
static std::string g_CurrentDialogText;
static std::string g_ChatInputText;
static bool g_IsChatInputActive = false;
static int g_WorldHour = 12;
static int g_WorldMinute = 0;
static int g_WorldWeather = 1;

static std::string g_LiveKeyboardBuffer;
static std::string g_LastInterceptedCmd;
static uint64_t g_LastInterceptedMs = 0;

static UIButton* g_FloatingMenuButton = nullptr;

static uint64_t NowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

static std::string GetBaseDir() {
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString* docs = [paths firstObject];
    return std::string([docs UTF8String]) + "/lua_loader";
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
    g_MenuOpen = !g_MenuOpen;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_FloatingMenuButton) {
            g_FloatingMenuButton.backgroundColor = g_MenuOpen
                ? [UIColor colorWithRed:0.52 green:0.26 blue:0.88 alpha:0.95]
                : [UIColor colorWithRed:0.15 green:0.11 blue:0.25 alpha:0.90];
        }
    });
}

// ============================================================================
// 4. FLOATING UIKIT TEST BUTTON & LAUNCHER BANNER
// ============================================================================

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
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow* win = GetActiveKeyWindow();
        if (!win) return;

        if (g_FloatingMenuButton) {
            if (g_FloatingMenuButton.superview != win) {
                [win addSubview:g_FloatingMenuButton];
            }
            [win bringSubviewToFront:g_FloatingMenuButton];
            return;
        }

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
    });
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

// ============================================================================
// 5. OUTGOING CHAT & COMMAND INTERCEPTION
// ============================================================================

static void SendRawToGameChat(const std::string& utf8Text) {
    std::string cpText = Utf8ToCp1251(utf8Text);

    if (!cpText.empty() && cpText[0] == '/' && orig_SendCommand && g_LastNetGamePtr) {
        orig_SendCommand(g_LastNetGamePtr, cpText.c_str());
        return;
    }
    if (orig_SendChat && g_LastNetGamePtr) {
        orig_SendChat(g_LastNetGamePtr, cpText.c_str());
        return;
    }

    Fn_SendCommand dynSendCmd = orig_dlsym
        ? (Fn_SendCommand)orig_dlsym(RTLD_DEFAULT, "_ZN4CNetGame11SendCommandEPKc")
        : (Fn_SendCommand)dlsym(RTLD_DEFAULT, "_ZN4CNetGame11SendCommandEPKc");
    Fn_SendChat dynSendChat = orig_dlsym
        ? (Fn_SendChat)orig_dlsym(RTLD_DEFAULT, "_ZN4CNetGame8SendChatEPKc")
        : (Fn_SendChat)dlsym(RTLD_DEFAULT, "_ZN4CNetGame8SendChatEPKc");

    if (!cpText.empty() && cpText[0] == '/' && dynSendCmd && g_LastNetGamePtr) {
        dynSendCmd(g_LastNetGamePtr, cpText.c_str());
        return;
    }
    if (dynSendChat && g_LastNetGamePtr) {
        dynSendChat(g_LastNetGamePtr, cpText.c_str());
        return;
    }

    LogConsole("[ChatOut -> Server] " + utf8Text);
}

static bool TryExecuteChatCommand(const std::string& rawInput, const char* sourceTag = "unknown") {
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
        LogConsole(std::string("[HookDiag:") + sourceTag + "] Меню переключено через /" + key);
        return true;
    }

    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    auto it = g_ChatCommands.find(key);
    if (it == g_ChatCommands.end()) {
        return false;
    }

    g_LastInterceptedCmd = utf8;
    g_LastInterceptedMs = now;
    LogConsole(std::string("[HookDiag:") + sourceTag + "] Перехвачено /" + key + " (" + cmdArgs + ")");

    RegisteredCommand reg = it->second;
    if (reg.L && reg.funcRef != LUA_NOREF) {
        lua_State* L = reg.L;
        lua_rawgeti(L, LUA_REGISTRYINDEX, reg.funcRef);
        lua_pushstring(L, cmdArgs.c_str());
        if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
            const char* err = lua_tostring(L, -1);
            std::string errMsg = err ? err : "unknown command error";
            LogConsole("[CMD /" + key + " ERROR] " + errMsg);
            LuaScriptInstance* inst = FindScriptByState(L);
            if (inst) {
                inst->hasError = true;
                inst->lastError = errMsg;
            }
            lua_pop(L, 1);
        }
    }
    return true;
}

static void hooked_OnInputEnd(JNIEnv* env, jobject thiz, jbyteArray array) {
    g_LastJNIEnv = env;
    g_LastJObject = thiz;

    if (env && array) {
        void** vtable = *reinterpret_cast<void***>(env);
        typedef int (*Fn_GetArrayLength)(JNIEnv*, jbyteArray);
        typedef int8_t* (*Fn_GetByteArrayElements)(JNIEnv*, jbyteArray, uint8_t*);
        typedef void (*Fn_ReleaseByteArrayElements)(JNIEnv*, jbyteArray, int8_t*, int);

        auto getLen = reinterpret_cast<Fn_GetArrayLength>(vtable[171]);
        auto getBytes = reinterpret_cast<Fn_GetByteArrayElements>(vtable[184]);
        auto relBytes = reinterpret_cast<Fn_ReleaseByteArrayElements>(vtable[192]);

        if (getLen && getBytes && relBytes) {
            int len = getLen(env, array);
            if (len > 0 && len < 4096) {
                int8_t* ptr = getBytes(env, array, nullptr);
                if (ptr) {
                    std::string text(reinterpret_cast<const char*>(ptr), len);
                    relBytes(env, array, ptr, 2);

                    if (TryExecuteChatCommand(text, "JNI-OnInputEnd")) {
                        return;
                    }
                }
            }
        }
    }

    if (orig_OnInputEnd) {
        orig_OnInputEnd(env, thiz, array);
    }
}

static void hooked_SendCommand(void* thisPtr, const char* cmd) {
    g_LastNetGamePtr = thisPtr;
    if (cmd && TryExecuteChatCommand(cmd, "SendCommand")) {
        return;
    }
    if (orig_SendCommand) {
        orig_SendCommand(thisPtr, cmd);
    }
}

static void hooked_SendChat(void* thisPtr, const char* msg) {
    g_LastNetGamePtr = thisPtr;
    if (msg && TryExecuteChatCommand(msg, "SendChat")) {
        return;
    }
    if (orig_SendChat) {
        orig_SendChat(thisPtr, msg);
    }
}

// ============================================================================
// 6. INCOMING CHAT & DIALOG HOOKS -> samp.events
// ============================================================================

static void DispatchSampEvent(const char* eventName, uint32_t color, const std::string& text) {
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    for (auto* s : g_Scripts) {
        if (!s->enabled || !s->L || s->hasError) continue;
        lua_State* L = s->L;
        lua_getglobal(L, "_DISPATCH_SAMP_EVENT");
        if (lua_isfunction(L, -1)) {
            lua_pushstring(L, eventName);
            lua_pushinteger(L, color);
            lua_pushstring(L, text.c_str());
            if (lua_pcall(L, 3, 0, 0) != LUA_OK) {
                const char* err = lua_tostring(L, -1);
                LogConsole("[Event " + std::string(eventName) + " ERROR] " + (err ? err : ""));
                lua_pop(L, 1);
            }
        } else {
            lua_pop(L, 1);
        }
    }
}

static void hooked_AddChatMessage(void* thisPtr, uint32_t color, const char* text) {
    if (text) {
        std::string utf8 = Cp1251ToUtf8(text);
        {
            std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
            g_ChatHistory.push_back({utf8, "", color, color});
            if (g_ChatHistory.size() > 100) {
                g_ChatHistory.erase(g_ChatHistory.begin());
            }
        }
        DispatchSampEvent("onServerMessage", color, utf8);
    }
    if (orig_AddChatMessage) {
        orig_AddChatMessage(thisPtr, color, text);
    }
}

static void hooked_ShowDialog(void* thisPtr, int id, int style, const char* title, const char* text, const char* btn1, const char* btn2, bool b) {
    {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        g_CurrentDialogId = id;
        g_CurrentDialogStyle = style;
        g_IsDialogActive = true;
        g_CurrentDialogTitle = title ? Cp1251ToUtf8(title) : "";
        g_CurrentDialogText = text ? Cp1251ToUtf8(text) : "";
    }
    if (orig_ShowDialog) {
        orig_ShowDialog(thisPtr, id, style, title, text, btn1, btn2, b);
    }
}

// ============================================================================
// 7. FISHHOOK (INCLUDING dlsym) + OBJECTIVE-C KEYBOARD SWIZZLING
// ============================================================================

static void* hooked_dlsym(void* handle, const char* symbol) {
    void* addr = orig_dlsym ? orig_dlsym(handle, symbol) : nullptr;
    if (!symbol || !addr) return addr;

    if (strcmp(symbol, "Java_com_arizona_game_GTASA_OnInputEnd") == 0) {
        if (!orig_OnInputEnd) orig_OnInputEnd = (Fn_OnInputEnd)addr;
        LogConsole("[HookDiag:dlsym] Перехвачен резолв Java_com_arizona_game_GTASA_OnInputEnd");
        return (void*)hooked_OnInputEnd;
    }
    if (strcmp(symbol, "_ZN4CNetGame11SendCommandEPKc") == 0) {
        if (!orig_SendCommand) orig_SendCommand = (Fn_SendCommand)addr;
        return (void*)hooked_SendCommand;
    }
    if (strcmp(symbol, "_ZN4CNetGame8SendChatEPKc") == 0) {
        if (!orig_SendChat) orig_SendChat = (Fn_SendChat)addr;
        return (void*)hooked_SendChat;
    }
    if (strcmp(symbol, "_ZN11CChatWindow14AddChatMessageEjPKc") == 0) {
        if (!orig_AddChatMessage) orig_AddChatMessage = (Fn_AddChatMessage)addr;
        return (void*)hooked_AddChatMessage;
    }
    if (strcmp(symbol, "_ZN7CDialog4ShowEiiPKcS1_S1_S1_b") == 0) {
        if (!orig_ShowDialog) orig_ShowDialog = (Fn_ShowDialog)addr;
        return (void*)hooked_ShowDialog;
    }
    return addr;
}

struct Rebinding {
    const char* name;
    void* replacement;
    void** replaced;
};

static void RebindSymbolsForImage(const struct mach_header* header, intptr_t slide) {
    if (!header || header->magic != MH_MAGIC_64) return;
    const auto* header64 = reinterpret_cast<const struct mach_header_64*>(header);

    Dl_info info;
    if (dladdr((const void*)header, &info) && info.dli_fname && strstr(info.dli_fname, "LuaLoader") != nullptr) {
        return;
    }

    std::vector<Rebinding> rebindings = {
        {"dlsym", (void*)hooked_dlsym, (void**)&orig_dlsym},
        {"Java_com_arizona_game_GTASA_OnInputEnd", (void*)hooked_OnInputEnd, (void**)&orig_OnInputEnd},
        {"_ZN4CNetGame11SendCommandEPKc", (void*)hooked_SendCommand, (void**)&orig_SendCommand},
        {"_ZN4CNetGame8SendChatEPKc", (void*)hooked_SendChat, (void**)&orig_SendChat},
        {"_ZN11CChatWindow14AddChatMessageEjPKc", (void*)hooked_AddChatMessage, (void**)&orig_AddChatMessage},
        {"_ZN7CDialog4ShowEiiPKcS1_S1_S1_b", (void*)hooked_ShowDialog, (void**)&orig_ShowDialog}
    };

    const struct segment_command_64* linkeditSeg = nullptr;
    const struct symtab_command* symtabCmd = nullptr;
    const struct dysymtab_command* dysymtabCmd = nullptr;

    uintptr_t cur = reinterpret_cast<uintptr_t>(header64) + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header64->ncmds; i++) {
        const auto* cmd = reinterpret_cast<const struct load_command*>(cur);
        if (cmd->cmd == LC_SEGMENT_64) {
            const auto* seg = reinterpret_cast<const struct segment_command_64*>(cmd);
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) linkeditSeg = seg;
        } else if (cmd->cmd == LC_SYMTAB) {
            symtabCmd = reinterpret_cast<const struct symtab_command*>(cmd);
        } else if (cmd->cmd == LC_DYSYMTAB) {
            dysymtabCmd = reinterpret_cast<const struct dysymtab_command*>(cmd);
        }
        cur += cmd->cmdsize;
    }

    if (!linkeditSeg || !symtabCmd || !dysymtabCmd || dysymtabCmd->nindirectsyms == 0) return;

    uintptr_t linkeditBase = static_cast<uintptr_t>(slide) + linkeditSeg->vmaddr - linkeditSeg->fileoff;
    const auto* symtab = reinterpret_cast<const struct nlist_64*>(linkeditBase + symtabCmd->symoff);
    const char* strtab = reinterpret_cast<const char*>(linkeditBase + symtabCmd->stroff);
    const uint32_t* indirectSymtab = reinterpret_cast<const uint32_t*>(linkeditBase + dysymtabCmd->indirectsymoff);

    cur = reinterpret_cast<uintptr_t>(header64) + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header64->ncmds; i++) {
        const auto* cmd = reinterpret_cast<const struct load_command*>(cur);
        if (cmd->cmd == LC_SEGMENT_64) {
            const auto* seg = reinterpret_cast<const struct segment_command_64*>(cmd);
            if (strcmp(seg->segname, SEG_DATA) == 0 || strcmp(seg->segname, "__DATA_CONST") == 0) {
                const auto* sects = reinterpret_cast<const struct section_64*>(cur + sizeof(struct segment_command_64));
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    uint32_t type = sects[j].flags & SECTION_TYPE;
                    if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;

                    uint32_t indirectOffset = sects[j].reserved1;
                    size_t count = sects[j].size / sizeof(void*);
                    void** bindings = reinterpret_cast<void**>(static_cast<uintptr_t>(slide) + sects[j].addr);

                    for (size_t k = 0; k < count; k++) {
                        uint32_t symIdx = indirectSymtab[indirectOffset + k];
                        if (symIdx == INDIRECT_SYMBOL_ABS || symIdx == INDIRECT_SYMBOL_LOCAL || symIdx == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
                        uint32_t strOffset = symtab[symIdx].n_un.n_strx;
                        if (strOffset == 0) continue;
                        const char* symName = strtab + strOffset;
                        if (symName[0] == '_') symName++;

                        for (const auto& reb : rebindings) {
                            if (strcmp(symName, reb.name) == 0) {
                                if (reb.replaced && *reb.replaced == nullptr && bindings[k] != reb.replacement) {
                                    *reb.replaced = bindings[k];
                                }
                                bindings[k] = reb.replacement;
                            }
                        }
                    }
                }
            }
        }
        cur += cmd->cmdsize;
    }
}

typedef BOOL (*Fn_TextFieldShouldReturn)(id, SEL, UITextField*);
typedef void (*Fn_InsertText)(id, SEL, NSString*);

static std::unordered_map<Class, Fn_TextFieldShouldReturn> g_OrigShouldReturnMap;
static std::unordered_map<Class, Fn_InsertText> g_OrigInsertTextMap;

static BOOL swizzled_textFieldShouldReturn(id self, SEL _cmd, UITextField* textField) {
    if (textField && textField.text.length > 0) {
        std::string txt([textField.text UTF8String]);
        if (TryExecuteChatCommand(txt, "UIKit-ShouldReturn")) {
            textField.text = @"";
            g_LiveKeyboardBuffer.clear();
            [textField resignFirstResponder];
            return NO;
        }
    }
    g_LiveKeyboardBuffer.clear();
    Class cls = object_getClass(self);
    auto it = g_OrigShouldReturnMap.find(cls);
    if (it != g_OrigShouldReturnMap.end() && it->second) {
        return it->second(self, _cmd, textField);
    }
    return YES;
}

static void swizzled_insertText(id self, SEL _cmd, NSString* text) {
    if (text && text.length > 0) {
        std::string utf8([text UTF8String]);
        if (utf8.find('\n') != std::string::npos || utf8.find('\r') != std::string::npos) {
            std::string candidate = g_LiveKeyboardBuffer;
            if ([self respondsToSelector:@selector(text)]) {
                NSString* cur = [(id)self performSelector:@selector(text)];
                if ([cur isKindOfClass:[NSString class]] && cur.length > 0) {
                    candidate = [cur UTF8String];
                }
            }
            g_LiveKeyboardBuffer.clear();

            if (!candidate.empty() && TryExecuteChatCommand(candidate, "UIKit-InsertReturn")) {
                if ([self respondsToSelector:@selector(setText:)]) {
                    [(id)self performSelector:@selector(setText:) withObject:@""];
                }
                if ([self respondsToSelector:@selector(resignFirstResponder)]) {
                    [(id)self resignFirstResponder];
                }
                return;
            }
        } else {
            g_LiveKeyboardBuffer += utf8;
        }
    }

    Class cls = object_getClass(self);
    auto it = g_OrigInsertTextMap.find(cls);
    if (it != g_OrigInsertTextMap.end() && it->second) {
        it->second(self, _cmd, text);
    }
}

static void SwizzleAppInputClasses() {
    NSString* mainBundlePath = [[NSBundle mainBundle] bundlePath];
    unsigned int numClasses = 0;
    Class* classes = objc_copyClassList(&numClasses);
    if (!classes) return;

    for (unsigned int i = 0; i < numClasses; i++) {
        Class cls = classes[i];
        const char* img = class_getImageName(cls);
        if (!img || strncmp(img, [mainBundlePath UTF8String], mainBundlePath.length) != 0) {
            continue;
        }

        Method mRet = class_getInstanceMethod(cls, @selector(textFieldShouldReturn:));
        if (mRet && method_getImplementation(mRet) != (IMP)swizzled_textFieldShouldReturn) {
            g_OrigShouldReturnMap[cls] = (Fn_TextFieldShouldReturn)method_getImplementation(mRet);
            method_setImplementation(mRet, (IMP)swizzled_textFieldShouldReturn);
        }

        Method mIns = class_getInstanceMethod(cls, @selector(insertText:));
        if (mIns && method_getImplementation(mIns) != (IMP)swizzled_insertText) {
            g_OrigInsertTextMap[cls] = (Fn_InsertText)method_getImplementation(mIns);
            method_setImplementation(mIns, (IMP)swizzled_insertText);
        }
    }
    free(classes);
}

static void InstallNativeHooks() {
    _dyld_register_func_for_add_image(RebindSymbolsForImage);
    SwizzleAppInputClasses();

    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];

    [nc addObserverForName:UITextFieldTextDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification* note) {
        UITextField* tf = note.object;
        if ([tf isKindOfClass:[UITextField class]]) {
            g_ChatInputText = tf.text ? [tf.text UTF8String] : "";
            g_IsChatInputActive = true;
            g_LiveKeyboardBuffer = g_ChatInputText;
        }
    }];

    [nc addObserverForName:UITextViewTextDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification* note) {
        UITextView* tv = note.object;
        if ([tv isKindOfClass:[UITextView class]]) {
            g_ChatInputText = tv.text ? [tv.text UTF8String] : "";
            g_IsChatInputActive = true;
            g_LiveKeyboardBuffer = g_ChatInputText;
        }
    }];

    [nc addObserverForName:UITextFieldTextDidEndEditingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification* note) {
        g_IsChatInputActive = false;
        UITextField* tf = note.object;
        if ([tf isKindOfClass:[UITextField class]] && tf.text.length > 0) {
            std::string txt([tf.text UTF8String]);
            if (TryExecuteChatCommand(txt, "UIKit-DidEndEditing")) {
                tf.text = @"";
                g_LiveKeyboardBuffer.clear();
            }
        }
    }];

    [nc addObserverForName:UIKeyboardWillHideNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification* note) {
        g_IsChatInputActive = false;
        if (!g_LiveKeyboardBuffer.empty()) {
            if (TryExecuteChatCommand(g_LiveKeyboardBuffer, "UIKit-KeyboardHide")) {
                g_LiveKeyboardBuffer.clear();
            }
        }
    }];
}

// ============================================================================
// 8. LUA 5.4 C++ API FUNCTIONS (MOONLOADER + AZ + SAMP)
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
    lua_pushinteger(L, ms);
    return lua_yield(L, 1);
}

static int l_lua_thread_create(lua_State* L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    bool suspended = lua_toboolean(L, 2);

    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    LuaScriptInstance* inst = FindScriptByState(L);
    if (!inst) return 0;

    lua_State* co = lua_newthread(inst->L);
    int ref = luaL_ref(inst->L, LUA_REGISTRYINDEX);

    lua_pushvalue(L, 1);
    lua_xmove(L, co, 1);

    LuaCoroutine lc;
    lc.co = co;
    lc.ref = ref;
    lc.wakeTimeMs = NowMs();
    lc.suspended = suspended;
    lc.finished = false;
    inst->threads.push_back(lc);

    lua_newtable(L);
    lua_pushinteger(L, ref);
    lua_setfield(L, -2, "_ref");
    return 1;
}

static int l_sampRegisterChatCommand(lua_State* L) {
    const char* rawCmd = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);

    std::string cmd = rawCmd;
    if (!cmd.empty() && cmd[0] == '/') cmd = cmd.substr(1);
    cmd = ToLowerASCII(cmd);

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

    LogConsole("[CMD] Зарегистрирована команда /" + cmd);
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
    if (it != g_ChatCommands.end()) {
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
        g_Notifications.push_back({"42Loader", utf8, NowMs() + 4500});
    }

    if (orig_AddChatMessage) {
        std::string cp = Utf8ToCp1251(utf8);
        orig_AddChatMessage(nullptr, color, cp.c_str());
    }
    LogConsole("[Chat] " + utf8);
    return 0;
}

static int l_sampSendChat(lua_State* L) {
    const char* text = luaL_checkstring(L, 1);
    SendRawToGameChat(Cp1251ToUtf8(text));
    return 0;
}

static int l_sampProcessChatInput(lua_State* L) {
    const char* text = luaL_checkstring(L, 1);
    std::string utf8 = Cp1251ToUtf8(text);
    if (!TryExecuteChatCommand(utf8, "sampProcessChatInput")) {
        SendRawToGameChat(utf8);
    }
    return 0;
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

    if (orig_ShowDialog) {
        orig_ShowDialog(nullptr, id, style,
                        Utf8ToCp1251(uTitle).c_str(),
                        Utf8ToCp1251(uText).c_str(),
                        Utf8ToCp1251(uBtn1).c_str(),
                        Utf8ToCp1251(uBtn2).c_str(), false);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController* alert = [UIAlertController alertControllerWithTitle:[NSString stringWithUTF8String:uTitle.c_str()]
                                                                           message:[NSString stringWithUTF8String:uText.c_str()]
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithUTF8String:uBtn1.c_str()]
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction* _Nonnull) { g_IsDialogActive = false; }]];
            if (!uBtn2.empty()) {
                [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithUTF8String:uBtn2.c_str()]
                                                          style:UIAlertActionStyleCancel
                                                        handler:^(UIAlertAction* _Nonnull) { g_IsDialogActive = false; }]];
            }
            UIWindow* win = GetActiveKeyWindow();
            [win.rootViewController presentViewController:alert animated:YES completion:nil];
        });
    }
    return 0;
}

static int l_sampGetCurrentDialogId(lua_State* L) { lua_pushinteger(L, g_CurrentDialogId); return 1; }
static int l_sampGetCurrentDialogStyle(lua_State* L) { lua_pushinteger(L, g_CurrentDialogStyle); return 1; }
static int l_sampIsDialogActive(lua_State* L) { lua_pushboolean(L, g_IsDialogActive); return 1; }
static int l_sampGetDialogText(lua_State* L) { lua_pushstring(L, g_CurrentDialogText.c_str()); return 1; }
static int l_sampGetDialogCaption(lua_State* L) { lua_pushstring(L, g_CurrentDialogTitle.c_str()); return 1; }
static int l_sampIsChatInputActive(lua_State* L) { lua_pushboolean(L, g_IsChatInputActive); return 1; }
static int l_sampGetChatInputText(lua_State* L) { lua_pushstring(L, g_ChatInputText.c_str()); return 1; }
static int l_sampSetChatInputText(lua_State* L) { g_ChatInputText = luaL_optstring(L, 1, ""); return 0; }
static int l_sampSetChatInputEnabled(lua_State* L) { g_IsChatInputActive = lua_toboolean(L, 1); return 0; }
static int l_isSampAvailable(lua_State* L) { lua_pushboolean(L, 1); return 1; }
static int l_isSampfuncsLoaded(lua_State* L) { lua_pushboolean(L, 1); return 1; }
static int l_sampGetGamestate(lua_State* L) { lua_pushinteger(L, 3); return 1; }

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
    g_WorldHour = static_cast<int>(luaL_checkinteger(L, 1)) % 24;
    g_WorldMinute = static_cast<int>(luaL_optinteger(L, 2, 0)) % 60;
    LogConsole("[World] Установлено время: " + std::to_string(g_WorldHour) + ":" + (g_WorldMinute < 10 ? "0" : "") + std::to_string(g_WorldMinute));
    return 0;
}

static int l_getTimeOfDay(lua_State* L) {
    lua_pushinteger(L, g_WorldHour);
    lua_pushinteger(L, g_WorldMinute);
    return 2;
}

static int l_forceWeatherNow(lua_State* L) {
    g_WorldWeather = static_cast<int>(luaL_checkinteger(L, 1));
    LogConsole("[World] Установлена погода ID: " + std::to_string(g_WorldWeather));
    return 0;
}

static int l_getScreenResolution(lua_State* L) {
    CGRect bounds = [[UIScreen mainScreen] nativeBounds];
    lua_pushinteger(L, static_cast<lua_Integer>(bounds.size.width));
    lua_pushinteger(L, static_cast<lua_Integer>(bounds.size.height));
    return 2;
}

static int l_getWorkingDirectory(lua_State* L) {
    lua_pushstring(L, GetBaseDir().c_str());
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
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIPasteboard generalPasteboard].string = str;
    });
    return 0;
}

static int l_az_getClipboard(lua_State* L) {
    NSString* str = [UIPasteboard generalPasteboard].string;
    lua_pushstring(L, str ? [str UTF8String] : "");
    return 1;
}

static int l_az_notify(lua_State* L) {
    const char* title = luaL_checkstring(L, 1);
    const char* msg = luaL_checkstring(L, 2);
    double sec = luaL_optnumber(L, 3, 3.0);
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    g_Notifications.push_back({Cp1251ToUtf8(title), Cp1251ToUtf8(msg), NowMs() + static_cast<uint64_t>(sec * 1000.0)});
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
    if (nsurl) {
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

static int l_az_getLoaderRAM(lua_State* L) {
    lua_pushnumber(L, GetLoaderRAM_MB());
    return 1;
}

static int l_asyncHttpRequest(lua_State* L) {
    const char* method = luaL_checkstring(L, 1);
    const char* url = luaL_checkstring(L, 2);
    const char* body = lua_isstring(L, 3) ? lua_tostring(L, 3) : nullptr;
    int okRef = lua_isfunction(L, 4) ? (lua_pushvalue(L, 4), luaL_ref(L, LUA_REGISTRYINDEX)) : LUA_NOREF;
    int errRef = lua_isfunction(L, 5) ? (lua_pushvalue(L, 5), luaL_ref(L, LUA_REGISTRYINDEX)) : LUA_NOREF;

    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithUTF8String:url]]];
    req.HTTPMethod = [NSString stringWithUTF8String:method];
    if (body) {
        req.HTTPBody = [[NSString stringWithUTF8String:body] dataUsingEncoding:NSUTF8StringEncoding];
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        if (!FindScriptByState(L)) return;

        if (error) {
            if (errRef != LUA_NOREF) {
                lua_rawgeti(L, LUA_REGISTRYINDEX, errRef);
                lua_pushstring(L, [[error localizedDescription] UTF8String]);
                lua_pcall(L, 1, 0, 0);
            }
        } else if (okRef != LUA_NOREF) {
            NSHTTPURLResponse* httpResp = (NSHTTPURLResponse*)response;
            NSString* text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            lua_rawgeti(L, LUA_REGISTRYINDEX, okRef);
            lua_newtable(L);
            lua_pushinteger(L, httpResp ? httpResp.statusCode : 200);
            lua_setfield(L, -2, "status_code");
            lua_pushstring(L, text ? [text UTF8String] : "");
            lua_setfield(L, -2, "text");
            lua_pcall(L, 1, 0, 0);
        }
        if (okRef != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, okRef);
        if (errRef != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, errRef);
    }] resume];

    return 0;
}

// ============================================================================
// 9. FULL MOONLOADER BUILT-IN RUNTIME & LIBRARIES
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
        unload = function() end,
        reload = function() end,
        pause = function() end,
        resume = function() end
    }
end

PLAYER_PED = 1
PLAYER_HANDLE = 0
function isCharInAnyCar(ped) return false end
function storeCarCharIsInNoSave(ped) return 0 end
function getCharCoordinates(ped) return 0.0, 0.0, 0.0 end
function setCharCoordinates(ped, x, y, z) end
function getCharHealth(ped) return 100 end
function setCharHealth(ped, hp) end
function getCharArmour(ped) return 0 end
function getCharHeading(ped) return 0.0 end
function setCharHeading(ped, angle) end
function addOneOffSound(x, y, z, id) if az and az.vibrate then az.vibrate(0) end end
function printStringNow(text, time) if az and az.notify then az.notify("GTA", tostring(text), (time or 2000)/1000.0) end end
function printString(text, time) printStringNow(text, time) end
function isKeyDown(vk) return false end
function wasKeyPressed(vk) return false end
function isKeyJustPressed(vk) return false end
function convert3DCoordsToScreen(x, y, z) return 0, 0 end
function convert3DCoordsToScreenEx(x, y, z) return false, 0, 0, 0, 0, 0 end

function sampGetCurrentServerName() return "Arizona RP Mobile" end
function sampGetCurrentServerAddress() return "127.0.0.1", 7777 end
function sampGetPlayerNickname(id) return "Player_" .. tostring(id or 0) end
function sampGetPlayerScore(id) return 1 end
function sampGetPlayerPing(id) return 20 end
function sampGetPlayerColor(id) return 0xFFFFFFFF end
function sampGetPlayerHealth(id) return 100 end
function sampGetPlayerArmor(id) return 0 end
function sampIsPlayerConnected(id) return true end
function sampIsPlayerNpc(id) return false end
function sampGetMaxPlayerId(streamed) return 1000 end
function sampGetPlayerIdByCharHandle(ped) return true, 0 end
function sampGetCharHandleBySampPlayerId(id) return false, 0 end
function sampSendDialogResponse(id, btn, item, input) end
function sampCloseCurrentDialogWithButton(btn) end
function sampSendClickTextdraw(id) end
function sampTextdrawIsExists(id) return false end
function sampTextdrawGetString(id) return "" end
function sampCreate3dText(...) return 1 end
function sampDestroy3dText(id) end
function sampIs3dTextDefined(id) return false end

local _sampev = {}
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
    local utf8Obj = setmetatable({}, { __call = function(_, s) return tostring(s or "") end })
    function utf8Obj:decode(s) return tostring(s or "") end
    function utf8Obj:encode(s) return tostring(s or "") end
    encoding.UTF8 = utf8Obj
    encoding.CP1251 = utf8Obj
    return encoding
end

local function _json_encode(val)
    local t = type(val)
    if val == nil then return "null"
    elseif t == "boolean" then return val and "true" or "false"
    elseif t == "number" then return tostring(val)
    elseif t == "string" then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r') .. '"'
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
    return "null"
end

local function _json_decode(str)
    if type(str) ~= "string" then return nil end
    local luaExpr = str
        :gsub('"%s*:%s*', '"]=')
        :gsub('{%s*"', '{["')
        :gsub(',%s*"', ',["')
        :gsub('%[', '{')
        :gsub('%]', '}')
        :gsub(':%s*true', '=true')
        :gsub(':%s*false', '=false')
        :gsub(':%s*null', '=nil')
    local fn = load("return " .. luaExpr)
    if fn then
        local ok, res = pcall(fn)
        if ok then return res end
    end
    return nil
end

encodeJson = _json_encode
decodeJson = _json_decode
local _json_mod = { encode = _json_encode, decode = _json_decode }
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

package.preload["ffi"] = function()
    return {
        cdef = function() end,
        new = function(ct, init) return { _val = init or "" } end,
        cast = function(ct, val) return val end,
        string = function(ptr) return type(ptr) == "table" and tostring(ptr._val or "") or tostring(ptr or "") end,
        sizeof = function() return 4 end
    }
end

package.preload["memory"] = function()
    return {
        read = function() return 0 end,
        write = function() end,
        fill = function() end,
        tostring = function() return "" end,
        hex2bin = function(h) return h end,
        bin2hex = function(b) return b end
    }
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
)lua";

static int l_imgui_Begin(lua_State* L) {
    const char* name = luaL_checkstring(L, 1);
    bool open = true;
    bool hasClose = lua_isboolean(L, 2);
    if (hasClose) open = lua_toboolean(L, 2);
    bool visible = ImGui::Begin(name, hasClose ? &open : nullptr);
    lua_pushboolean(L, visible);
    if (hasClose) {
        lua_pushboolean(L, open);
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
        inst->renderCallbackRef = luaL_ref(inst->L, LUA_REGISTRYINDEX);
    }
    return 0;
}

static void RegisterAllLuaAPI(lua_State* L, const std::string& filename, const std::string& fullPath) {
    luaL_openlibs(L);

    std::string base = GetBaseDir();
    std::string pkgCode = "package.path = package.path .. ';" + base + "/lib/?.lua;" + base + "/lib/?/init.lua'";
    luaL_dostring(L, pkgCode.c_str());

    lua_register(L, "print", l_print);
    lua_register(L, "wait", l_wait);

    lua_newtable(L);
    lua_pushcfunction(L, l_lua_thread_create); lua_setfield(L, -2, "create");
    lua_pushcfunction(L, l_lua_thread_create); lua_setfield(L, -2, "create_suspended");
    lua_setglobal(L, "lua_thread");

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
    lua_register(L, "getGameDirectory", l_getWorkingDirectory);
    lua_register(L, "doesFileExist", l_doesFileExist);
    lua_register(L, "doesDirectoryExist", l_doesDirectoryExist);
    lua_register(L, "createDirectory", l_createDirectory);
    lua_register(L, "asyncHttpRequest", l_asyncHttpRequest);

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
// 10. SCRIPT LOADING, RELOADING & TICKING
// ============================================================================

static void UnloadSingleScript(LuaScriptInstance* inst) {
    if (!inst) return;
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
        inst->lastError = "Не удалось открыть файл: " + ShortenPathForUI(inst->fullPath);
        return;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::string code(sz > 0 ? sz : 0, '\0');
    if (sz > 0) fread(&code[0], 1, sz, f);
    fclose(f);

    if (code.size() >= 3 &&
        static_cast<unsigned char>(code[0]) == 0xEF &&
        static_cast<unsigned char>(code[1]) == 0xBB &&
        static_cast<unsigned char>(code[2]) == 0xBF) {
        code.erase(0, 3);
    }

    lua_State* L = luaL_newstate();
    inst->L = L;
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

    if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
        const char* err = lua_tostring(L, -1);
        inst->hasError = true;
        inst->lastError = err ? err : "Runtime error";
        LogConsole("[ERROR] " + inst->lastError);
        lua_pop(L, 1);
        return;
    }

    lua_getglobal(L, "onScriptLoad");
    if (lua_isfunction(L, -1)) {
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
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

    LogConsole("[OK] Загружен скрипт: " + inst->filename);
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
        bannerMsg = [NSString stringWithFormat:@"42Loader: Загружено %d | Ошибок: %d", okCount, errCount];
    } else if (okCount > 0) {
        bannerMsg = [NSString stringWithFormat:@"42Loader: Загружено скриптов: %d (команд: %zu)", okCount, g_ChatCommands.size()];
    } else {
        bannerMsg = @"42Loader: Активен (скриптов не найдено)";
    }
    ShowLauncherBanner(bannerMsg, errCount > 0);
}

static void TickScripts() {
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    uint64_t now = NowMs();

    for (auto* s : g_Scripts) {
        if (!s->enabled || !s->L || s->hasError) continue;

        for (size_t i = 0; i < s->threads.size(); ) {
            LuaCoroutine& t = s->threads[i];
            if (t.finished || t.suspended || now < t.wakeTimeMs) {
                i++;
                continue;
            }

            int nres = 0;
            int status = lua_resume(t.co, s->L, 0, &nres);
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
                luaL_unref(s->L, LUA_REGISTRYINDEX, t.ref);
                s->threads.erase(s->threads.begin() + i);
            }
        }
    }
}

// ============================================================================
// 11. DEAR IMGUI OVERLAY (WITH TEXT WRAPPING)
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
                lua_rawgeti(s->L, LUA_REGISTRYINDEX, s->renderCallbackRef);
                if (lua_pcall(s->L, 0, 0, 0) != LUA_OK) {
                    s->hasError = true;
                    s->lastError = lua_tostring(s->L, -1) ?: "ImGui render error";
                    lua_pop(s->L, 1);
                }
            }
        }
    }

    if (!g_MenuOpen) return;

    ImGui::SetNextWindowPos(ImVec2(screenW * 0.5f - 260.0f, 36.0f), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSize(ImVec2(520.0f, 310.0f), ImGuiCond_FirstUseEver);
    ImGui::PushStyleColor(ImGuiCol_TitleBgActive, ImVec4(0.32f, 0.18f, 0.52f, 1.0f));
    ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0.10f, 0.09f, 0.14f, 0.95f));

    if (ImGui::Begin("Arizona 42Loader  |  Lua 5.4 + MoonLoader API", &g_MenuOpen)) {
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
            ImGui::TextUnformatted("Открытие меню: кнопка '42' или команды /42, /42loader, /luasettings в чате. Команды скриптов:");
            ImGui::PopTextWrapPos();
            ImGui::Separator();

            for (const auto& kv : g_ChatCommands) {
                ImGui::BulletText("/%s  (%s)", kv.first.c_str(), kv.second.scriptName.c_str());
            }

            ImGui::Separator();
            ImGui::InputText("##TestCmd", g_CmdInputBuf, sizeof(g_CmdInputBuf));
            ImGui::SameLine();
            if (ImGui::Button("Выполнить")) {
                if (strlen(g_CmdInputBuf) > 0) {
                    TryExecuteChatCommand(g_CmdInputBuf, "MenuInput");
                    g_CmdInputBuf[0] = '\0';
                }
            }

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
            ImGui::Text("Время мира: %02d:%02d | Погода ID: %d", g_WorldHour, g_WorldMinute, g_WorldWeather);
            ImGui::Text("Активных скриптов: %zu | Команд в чате: %zu", g_Scripts.size(), g_ChatCommands.size());
            ImGui::PopTextWrapPos();
        }
    }
    ImGui::End();
    ImGui::PopStyleColor(2);
}

// ============================================================================
// 12. METAL RENDER HOOK & ENTRY POINT
// ============================================================================

static bool g_ImGuiInitialized = false;

static void SetupImGuiWithDevice(id<MTLDevice> device) {
    if (g_ImGuiInitialized || !device) return;
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::StyleColorsDark();
    ImGui_ImplMetal_Init(device);
    g_ImGuiInitialized = true;
}

static void (*orig_presentDrawable)(id, SEL, id<MTLDrawable>) = nullptr;
static void swizzled_presentDrawable(id self, SEL _cmd, id<MTLDrawable> drawable) {
    EnsureFloatingMenuButton();

    if (g_ImGuiInitialized) {
        UIWindow* keyWin = GetActiveKeyWindow();
        if (keyWin) {
            ImGuiIO& io = ImGui::GetIO();
            CGFloat scale = [UIScreen mainScreen].scale;
            io.DisplaySize = ImVec2(keyWin.bounds.size.width, keyWin.bounds.size.height);
            io.DisplayFramebufferScale = ImVec2(scale, scale);

            MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            if ([drawable respondsToSelector:@selector(texture)]) {
                rpd.colorAttachments[0].texture = [(id)drawable texture];
                rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
                rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

                id<MTLCommandBuffer> cmdBuf = (id<MTLCommandBuffer>)self;
                id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
                ImGui_ImplMetal_NewFrame(rpd);
                ImGui::NewFrame();
                RenderLoaderUI();
                ImGui::Render();
                ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cmdBuf, enc);
                [enc endEncoding];
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
    InstallNativeHooks();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        EnsureFloatingMenuButton();
        ReloadAllScripts();

        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        SetupImGuiWithDevice(dev);

        id<MTLCommandQueue> queue = [dev newCommandQueue];
        id<MTLCommandBuffer> buf = [queue commandBuffer];
        Class cmdBufClass = [buf class];
        Method m = class_getInstanceMethod(cmdBufClass, @selector(presentDrawable:));
        if (m) {
            orig_presentDrawable = (void (*)(id, SEL, id<MTLDrawable>))method_getImplementation(m);
            method_setImplementation(m, (IMP)swizzled_presentDrawable);
        }
        LogConsole("Arizona 42Loader инициализирован (Кнопка '42' + Команды чата + Баннер активны)");
    });
}
