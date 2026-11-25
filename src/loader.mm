#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <dlfcn.h>

#include <string>
#include <vector>
#include <unordered_map>
#include <mutex>
#include <chrono>
#include <algorithm>
#include <cctype>
#include <cstring>
#include <cstdio>

extern "C" {
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
}

// ============================================================================
// 1. NATIVE GTA SA / SAMP SYMBOL TYPES & RESOLVED POINTERS
// ============================================================================

typedef void (*Fn_AddChatMessage)(void* thisPtr, uint32_t color, const char* text);
typedef void (*Fn_AddDebugMessage)(void* thisPtr, const char* fmt, ...);
typedef void (*Fn_SendCommand)(void* thisPtr, const char* cmd);
typedef void (*Fn_SendChat)(void* thisPtr, const char* msg);
typedef void (*Fn_SetGameClock)(uint8_t hours, uint8_t minutes, uint8_t days);
typedef void (*Fn_ForceWeatherNow)(int16_t weather);

static void** g_ppChatWindow = nullptr;
static Fn_AddChatMessage g_fnAddChatMessage = nullptr;
static Fn_AddChatMessage g_fnAddClientMessage = nullptr;
static Fn_AddDebugMessage g_fnAddDebugMessage = nullptr;

static void** g_ppNetGame = nullptr;
static Fn_SendCommand g_fnSendCommand = nullptr;
static Fn_SendChat g_fnSendChat = nullptr;

static Fn_SetGameClock g_fnSetGameClock = nullptr;
static uint8_t* g_pGameClockHours = nullptr;
static uint8_t* g_pGameClockMinutes = nullptr;
static uint16_t* g_pGameClockSeconds = nullptr;

static Fn_ForceWeatherNow g_fnForceWeatherNow = nullptr;
static int16_t* g_pOldWeatherType = nullptr;
static int16_t* g_pNewWeatherType = nullptr;

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
        if (c < 0x80) out.push_back(static_cast<char>(c));
        else if (c == 0xA8) out.append("\xD0\x81");
        else if (c == 0xB8) out.append("\xD1\x91");
        else if (c >= 0xC0 && c <= 0xEF) {
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
    uint64_t timestampMs = 0;
};

struct LuaScriptInstance {
    std::string filename;
    std::string fullPath;
    lua_State* L = nullptr;
    bool enabled = true;
    bool hasError = false;
    std::string lastError;
    std::vector<LuaCoroutine> threads;
    int renderCallbackRef = LUA_NOREF;
};

static std::recursive_mutex g_EngineMutex;
static std::vector<LuaScriptInstance*> g_Scripts;
static std::unordered_map<std::string, RegisteredCommand> g_ChatCommands;
static std::vector<std::string> g_ConsoleLogs;
static std::vector<ChatHistoryEntry> g_ChatHistory;

static bool g_MenuOpen = false;
static int g_SelectedTab = 0;

static int g_CurrentDialogId = -1;
static int g_CurrentDialogStyle = 0;
static bool g_IsDialogActive = false;
static std::string g_CurrentDialogTitle;
static std::string g_CurrentDialogText;
static std::string g_ChatInputText;
static bool g_IsChatInputActive = false;

static bool g_TimeOverrideActive = false;
static int g_WorldHour = 12;
static int g_WorldMinute = 0;

static bool g_WeatherOverrideActive = false;
static int g_WorldWeather = 1;

static std::string g_LastInterceptedCmd;
static uint64_t g_LastInterceptedMs = 0;
static __weak UIView* g_ActiveInputView = nil;

// Native UIKit views (Menu, Floating Button & SA-MP HUD Chat Overlay)
static UIButton* g_FloatingMenuButton = nil;
static UIView* g_MenuOverlayView = nil;
static UILabel* g_MenuRamLabel = nil;
static UISegmentedControl* g_MenuTabs = nil;
static UIScrollView* g_MenuScrollView = nil;
static UITextField* g_MenuCmdField = nil;
static UIView* g_MenuCmdBar = nil;
static UIButton* g_MenuActionBtn = nil;
static UIView* g_HudChatOverlay = nil;
static CADisplayLink* g_DisplayLink = nil;
static uint64_t g_LastUiRefreshMs = 0;

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
    return (pos != std::string::npos) ? raw.substr(pos + 1) : raw;
}

static float GetLoaderRAM_MB() {
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count) == KERN_SUCCESS) {
        return static_cast<float>(vmInfo.phys_footprint) / (1024.0f * 1024.0f);
    }
    return 0.0f;
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

static void EnsureDirectories() {
    NSFileManager* fm = [NSFileManager defaultManager];
    std::string base = GetBaseDir();
    for (NSString* dir in @[
        [NSString stringWithUTF8String:base.c_str()],
        [NSString stringWithUTF8String:(base + "/scripts").c_str()],
        [NSString stringWithUTF8String:(base + "/config").c_str()],
        [NSString stringWithUTF8String:(base + "/lib").c_str()]
    ]) {
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

// Forward declarations
static void ReloadAllScripts();
static void LoadSingleScript(LuaScriptInstance* inst);
static void UnloadSingleScript(LuaScriptInstance* inst);
static void RefreshMenuContent();
static void ToggleLoaderMenu();
static void RefreshHudChatOverlay();

// ============================================================================
// 4. MACH-O LC_SYMTAB SYMBOL RESOLVER (FINDS NON-EXPORTED C++ SYMBOLS)
// ============================================================================

static void ScanMachOSymbols() {
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t imgIdx = 0; imgIdx < imageCount; imgIdx++) {
        const char* imgName = _dyld_get_image_name(imgIdx);
        if (!imgName) continue;
        // Scan main executable (index 0) and any non-system app frameworks
        if (imgIdx > 0 && strstr(imgName, "/System/") != nullptr) continue;
        if (imgIdx > 0 && strstr(imgName, "/usr/lib/") != nullptr) continue;

        const struct mach_header_64* header = reinterpret_cast<const struct mach_header_64*>(_dyld_get_image_header(imgIdx));
        if (!header || header->magic != MH_MAGIC_64) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(imgIdx);
        const struct segment_command_64* linkeditSeg = nullptr;
        const struct symtab_command* symtabCmd = nullptr;

        const uint8_t* cmdPtr = reinterpret_cast<const uint8_t*>(header + 1);
        for (uint32_t i = 0; i < header->ncmds; i++) {
            const struct load_command* lc = reinterpret_cast<const struct load_command*>(cmdPtr);
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64* seg = reinterpret_cast<const struct segment_command_64*>(cmdPtr);
                if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                    linkeditSeg = seg;
                }
            } else if (lc->cmd == LC_SYMTAB) {
                symtabCmd = reinterpret_cast<const struct symtab_command*>(cmdPtr);
            }
            cmdPtr += lc->cmdsize;
        }

        if (!linkeditSeg || !symtabCmd || symtabCmd->nsyms == 0) continue;

        uintptr_t linkeditBase = static_cast<uintptr_t>(slide) + linkeditSeg->vmaddr - linkeditSeg->fileoff;
        const struct nlist_64* symtab = reinterpret_cast<const struct nlist_64*>(linkeditBase + symtabCmd->symoff);
        const char* strtab = reinterpret_cast<const char*>(linkeditBase + symtabCmd->stroff);

        for (uint32_t s = 0; s < symtabCmd->nsyms; s++) {
            const struct nlist_64& sym = symtab[s];
            if ((sym.n_type & N_STAB) != 0) continue;
            if ((sym.n_type & N_TYPE) != N_SECT || sym.n_value == 0) continue;
            if (sym.n_un.n_strx == 0 || sym.n_un.n_strx >= symtabCmd->strsize) continue;

            const char* name = strtab + sym.n_un.n_strx;
            void* addr = reinterpret_cast<void*>(static_cast<uintptr_t>(sym.n_value) + slide);

            // Chat Window / Chat Instance
            if (!g_ppChatWindow && (strcmp(name, "_pChatWindow") == 0 || strcmp(name, "_g_pChatWindow") == 0 ||
                strcmp(name, "_pChat") == 0 || strcmp(name, "_g_pChat") == 0 ||
                strstr(name, "CChatWindow11m_pInstance") != nullptr || strstr(name, "CChat11m_pInstance") != nullptr)) {
                g_ppChatWindow = reinterpret_cast<void**>(addr);
            }
            if (!g_fnAddChatMessage && (strstr(name, "CChatWindow14AddChatMessage") != nullptr ||
                                        strstr(name, "CChat14AddChatMessage") != nullptr ||
                                        strstr(name, "CChat10AddMessage") != nullptr)) {
                g_fnAddChatMessage = reinterpret_cast<Fn_AddChatMessage>(addr);
            }
            if (!g_fnAddClientMessage && (strstr(name, "CChatWindow16AddClientMessage") != nullptr ||
                                          strstr(name, "CChat16AddClientMessage") != nullptr)) {
                g_fnAddClientMessage = reinterpret_cast<Fn_AddChatMessage>(addr);
            }
            if (!g_fnAddDebugMessage && (strstr(name, "CChatWindow15AddDebugMessage") != nullptr ||
                                         strstr(name, "CChat15AddDebugMessage") != nullptr)) {
                g_fnAddDebugMessage = reinterpret_cast<Fn_AddDebugMessage>(addr);
            }

            // NetGame
            if (!g_ppNetGame && (strcmp(name, "_pNetGame") == 0 || strcmp(name, "_g_pNetGame") == 0)) {
                g_ppNetGame = reinterpret_cast<void**>(addr);
            }
            if (!g_fnSendCommand && strstr(name, "CNetGame11SendCommand") != nullptr) {
                g_fnSendCommand = reinterpret_cast<Fn_SendCommand>(addr);
            }
            if (!g_fnSendChat && strstr(name, "CNetGame8SendChat") != nullptr) {
                g_fnSendChat = reinterpret_cast<Fn_SendChat>(addr);
            }

            // CClock (World Time)
            if (!g_fnSetGameClock && strstr(name, "CClock12SetGameClock") != nullptr) {
                g_fnSetGameClock = reinterpret_cast<Fn_SetGameClock>(addr);
            }
            if (!g_pGameClockHours && strstr(name, "CClock19ms_nGameClockHours") != nullptr) {
                g_pGameClockHours = reinterpret_cast<uint8_t*>(addr);
            }
            if (!g_pGameClockMinutes && strstr(name, "CClock21ms_nGameClockMinutes") != nullptr) {
                g_pGameClockMinutes = reinterpret_cast<uint8_t*>(addr);
            }
            if (!g_pGameClockSeconds && strstr(name, "CClock21ms_nGameClockSeconds") != nullptr) {
                g_pGameClockSeconds = reinterpret_cast<uint16_t*>(addr);
            }

            // CWeather (World Weather)
            if (!g_fnForceWeatherNow && strstr(name, "CWeather15ForceWeatherNow") != nullptr) {
                g_fnForceWeatherNow = reinterpret_cast<Fn_ForceWeatherNow>(addr);
            }
            if (!g_pOldWeatherType && strstr(name, "CWeather14OldWeatherType") != nullptr) {
                g_pOldWeatherType = reinterpret_cast<int16_t*>(addr);
            }
            if (!g_pNewWeatherType && strstr(name, "CWeather14NewWeatherType") != nullptr) {
                g_pNewWeatherType = reinterpret_cast<int16_t*>(addr);
            }
        }
    }

    // Fallback to dlsym if any symbol is dynamically exported
    if (!g_ppChatWindow) g_ppChatWindow = reinterpret_cast<void**>(dlsym(RTLD_DEFAULT, "pChatWindow"));
    if (!g_fnAddChatMessage) g_fnAddChatMessage = reinterpret_cast<Fn_AddChatMessage>(dlsym(RTLD_DEFAULT, "_ZN11CChatWindow14AddChatMessageEjPKc"));
    if (!g_fnAddClientMessage) g_fnAddClientMessage = reinterpret_cast<Fn_AddChatMessage>(dlsym(RTLD_DEFAULT, "_ZN11CChatWindow16AddClientMessageEjPKc"));
    if (!g_fnSetGameClock) g_fnSetGameClock = reinterpret_cast<Fn_SetGameClock>(dlsym(RTLD_DEFAULT, "_ZN6CClock12SetGameClockEhhh"));
    if (!g_pGameClockHours) g_pGameClockHours = reinterpret_cast<uint8_t*>(dlsym(RTLD_DEFAULT, "_ZN6CClock19ms_nGameClockHoursE"));
    if (!g_pGameClockMinutes) g_pGameClockMinutes = reinterpret_cast<uint8_t*>(dlsym(RTLD_DEFAULT, "_ZN6CClock21ms_nGameClockMinutesE"));
    if (!g_fnForceWeatherNow) g_fnForceWeatherNow = reinterpret_cast<Fn_ForceWeatherNow>(dlsym(RTLD_DEFAULT, "_ZN8CWeather15ForceWeatherNowEs"));

    bool hasNativeChat = (g_ppChatWindow != nullptr) && (g_fnAddChatMessage != nullptr || g_fnAddClientMessage != nullptr || g_fnAddDebugMessage != nullptr);
    bool hasNativeClock = (g_fnSetGameClock != nullptr) || (g_pGameClockHours != nullptr && g_pGameClockMinutes != nullptr);

    LogConsole(std::string("[SymScan] CChatWindow: ") + (hasNativeChat ? "НАЙДЕН" : "НЕ НАЙДЕН (вкл. SA-MP HUD чат)"));
    LogConsole(std::string("[SymScan] CClock (время): ") + (hasNativeClock ? "НАЙДЕН" : "НЕ НАЙДЕН (символы вырезаны)"));
}

static void ApplyWorldOverridesToEngine() {
    if (g_TimeOverrideActive) {
        uint8_t h = static_cast<uint8_t>(g_WorldHour % 24);
        uint8_t m = static_cast<uint8_t>(g_WorldMinute % 60);
        if (g_pGameClockHours && g_pGameClockMinutes) {
            *g_pGameClockHours = h;
            *g_pGameClockMinutes = m;
            if (g_pGameClockSeconds) *g_pGameClockSeconds = 0;
        } else if (g_fnSetGameClock) {
            g_fnSetGameClock(h, m, 1);
        }
    }
    if (g_WeatherOverrideActive) {
        int16_t w = static_cast<int16_t>(g_WorldWeather);
        if (g_pOldWeatherType && g_pNewWeatherType) {
            *g_pOldWeatherType = w;
            *g_pNewWeatherType = w;
        } else if (g_fnForceWeatherNow) {
            g_fnForceWeatherNow(w);
        }
    }
}

// ============================================================================
// 5. IN-GAME CHAT OUTPUT (NATIVE CChatWindow + SA-MP HUD OVERLAY FALLBACK)
// ============================================================================

static NSAttributedString* ParseSampColoredString(const std::string& utf8Text, uint32_t baseColor) {
    NSString* nsStr = [NSString stringWithUTF8String:utf8Text.c_str()];
    if (!nsStr) nsStr = @"";

    CGFloat r = ((baseColor >> 16) & 0xFF) / 255.0;
    CGFloat g = ((baseColor >> 8) & 0xFF) / 255.0;
    CGFloat b = (baseColor & 0xFF) / 255.0;
    if (r == 0 && g == 0 && b == 0) { r = 1.0; g = 1.0; b = 1.0; }
    UIColor* currentColor = [UIColor colorWithRed:r green:g blue:b alpha:1.0];

    NSShadow* shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.95];
    shadow.shadowOffset = CGSizeMake(1.0, 1.0);
    shadow.shadowBlurRadius = 1.0;

    UIFont* font = [UIFont boldSystemFontOfSize:13.0];
    NSMutableAttributedString* result = [[NSMutableAttributedString alloc] init];

    NSUInteger len = nsStr.length;
    NSUInteger idx = 0;
    NSUInteger chunkStart = 0;

    while (idx < len) {
        if ([nsStr characterAtIndex:idx] == '{' && idx + 7 < len && [nsStr characterAtIndex:idx + 7] == '}') {
            NSString* hexPart = [nsStr substringWithRange:NSMakeRange(idx + 1, 6)];
            unsigned int hexVal = 0;
            NSScanner* scanner = [NSScanner scannerWithString:hexPart];
            if ([scanner scanHexInt:&hexVal] && scanner.atEnd) {
                if (idx > chunkStart) {
                    NSString* seg = [nsStr substringWithRange:NSMakeRange(chunkStart, idx - chunkStart)];
                    [result appendAttributedString:[[NSAttributedString alloc] initWithString:seg attributes:@{
                        NSForegroundColorAttributeName: currentColor,
                        NSFontAttributeName: font,
                        NSShadowAttributeName: shadow
                    }]];
                }
                currentColor = [UIColor colorWithRed:((hexVal >> 16) & 0xFF) / 255.0
                                               green:((hexVal >> 8) & 0xFF) / 255.0
                                                blue:(hexVal & 0xFF) / 255.0
                                               alpha:1.0];
                idx += 8;
                chunkStart = idx;
                continue;
            }
        }
        idx++;
    }

    if (chunkStart < len) {
        NSString* seg = [nsStr substringFromIndex:chunkStart];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:seg attributes:@{
            NSForegroundColorAttributeName: currentColor,
            NSFontAttributeName: font,
            NSShadowAttributeName: shadow
        }]];
    }

    return result;
}

static void RefreshHudChatOverlay() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow* win = GetActiveKeyWindow();
        if (!win) return;

        if (!g_HudChatOverlay) {
            UIView* v = [[UIView alloc] initWithFrame:CGRectMake(14.0, 106.0, MIN(win.bounds.size.width - 28.0, 480.0), 150.0)];
            v.tag = 424299;
            v.backgroundColor = [UIColor clearColor];
            v.userInteractionEnabled = NO;
            g_HudChatOverlay = v;
        }
        if (g_HudChatOverlay.superview != win) {
            [win addSubview:g_HudChatOverlay];
        }
        [win bringSubviewToFront:g_HudChatOverlay];
        if (g_FloatingMenuButton) [win bringSubviewToFront:g_FloatingMenuButton];
        if (g_MenuOverlayView && !g_MenuOverlayView.hidden) [win bringSubviewToFront:g_MenuOverlayView];

        for (UIView* sub in g_HudChatOverlay.subviews) {
            [sub removeFromSuperview];
        }

        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        uint64_t now = NowMs();

        // Collect recent messages from the last 10 seconds (up to 7 lines)
        std::vector<ChatHistoryEntry> recent;
        for (int i = static_cast<int>(g_ChatHistory.size()) - 1; i >= 0 && recent.size() < 7; i--) {
            if (now - g_ChatHistory[i].timestampMs <= 10000) {
                recent.push_back(g_ChatHistory[i]);
            }
        }
        std::reverse(recent.begin(), recent.end());

        CGFloat y = 0.0;
        CGFloat maxW = g_HudChatOverlay.bounds.size.width;
        for (const auto& entry : recent) {
            UILabel* lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, y, maxW, 20.0)];
            lbl.numberOfLines = 2;
            lbl.attributedText = ParseSampColoredString(entry.text, entry.color);
            uint64_t age = now - entry.timestampMs;
            lbl.alpha = (age > 8000) ? MAX(0.0, 1.0 - (age - 8000) / 2000.0) : 1.0;
            [lbl sizeToFit];
            [g_HudChatOverlay addSubview:lbl];
            y += lbl.bounds.size.height + 2.0;
        }
    });
}

static void WriteToInGameChat(const std::string& utf8Text, uint32_t color) {
    if ((color & 0xFF000000) == 0) {
        color |= 0xFF000000;
    }

    {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        g_ChatHistory.push_back({utf8Text, "", color, color, NowMs()});
        if (g_ChatHistory.size() > 100) g_ChatHistory.erase(g_ChatHistory.begin());
    }

    bool wroteNative = false;
    void* chatWindowPtr = (g_ppChatWindow && *g_ppChatWindow) ? *g_ppChatWindow : nullptr;
    if (chatWindowPtr) {
        std::string cpText = Utf8ToCp1251(utf8Text);
        if (g_fnAddChatMessage) {
            g_fnAddChatMessage(chatWindowPtr, color, cpText.c_str());
            wroteNative = true;
        } else if (g_fnAddClientMessage) {
            g_fnAddClientMessage(chatWindowPtr, color, cpText.c_str());
            wroteNative = true;
        } else if (g_fnAddDebugMessage) {
            g_fnAddDebugMessage(chatWindowPtr, "%s", cpText.c_str());
            wroteNative = true;
        }
    }

    if (!wroteNative) {
        RefreshHudChatOverlay();
    }
}

static void SendToInGameServer(const std::string& utf8Text) {
    std::string cpText = Utf8ToCp1251(utf8Text);
    if (cpText.empty()) return;

    void* netGamePtr = (g_ppNetGame && *g_ppNetGame) ? *g_ppNetGame : nullptr;
    if (netGamePtr) {
        if (cpText[0] == '/' && g_fnSendCommand) {
            g_fnSendCommand(netGamePtr, cpText.c_str());
            return;
        }
        if (g_fnSendChat) {
            g_fnSendChat(netGamePtr, cpText.c_str());
            return;
        }
    }
}

static void ShowStartupBanner(NSString* message, BOOL isError) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow* win = GetActiveKeyWindow();
        if (!win) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ShowStartupBanner(message, isError);
            });
            return;
        }

        UIView* old = [win viewWithTag:424242];
        if (old) [old removeFromSuperview];

        CGFloat screenW = win.bounds.size.width;
        CGFloat bannerW = MIN(screenW - 32.0, 440.0);
        CGFloat bannerH = 42.0;

        UIView* banner = [[UIView alloc] initWithFrame:CGRectMake((screenW - bannerW) * 0.5, -60.0, bannerW, bannerH)];
        banner.tag = 424242;
        banner.backgroundColor = [UIColor colorWithRed:0.12 green:0.09 blue:0.20 alpha:0.95];
        banner.layer.cornerRadius = 14.0;
        banner.layer.borderWidth = 1.5;
        banner.layer.borderColor = isError
            ? [UIColor colorWithRed:0.90 green:0.25 blue:0.25 alpha:0.95].CGColor
            : [UIColor colorWithRed:0.62 green:0.38 blue:0.95 alpha:0.95].CGColor;
        banner.userInteractionEnabled = NO;

        UILabel* lbl = [[UILabel alloc] initWithFrame:CGRectInset(banner.bounds, 14.0, 4.0)];
        lbl.text = message;
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont boldSystemFontOfSize:13.0];
        lbl.textAlignment = NSTextAlignmentCenter;
        lbl.adjustsFontSizeToFitWidth = YES;
        lbl.minimumScaleFactor = 0.75;
        [banner addSubview:lbl];

        [win addSubview:banner];
        [win bringSubviewToFront:banner];

        CGFloat topInset = 16.0;
        if (@available(iOS 11.0, *)) {
            topInset = MAX(16.0, win.safeAreaInsets.top + 6.0);
        }

        [UIView animateWithDuration:0.30 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
            banner.frame = CGRectMake((screenW - bannerW) * 0.5, topInset, bannerW, bannerH);
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.25 delay:3.2 options:UIViewAnimationOptionCurveEaseIn animations:^{
                banner.alpha = 0.0;
                banner.frame = CGRectMake((screenW - bannerW) * 0.5, -60.0, bannerW, bannerH);
            } completion:^(BOOL done) {
                [banner removeFromSuperview];
            }];
        }];
    });
}

// ============================================================================
// 6. CHAT COMMAND EXECUTION ENGINE
// ============================================================================

static bool TryExecuteChatCommand(const std::string& rawInput, const char* sourceTag = "unknown") {
    std::string utf8 = Cp1251ToUtf8(rawInput);

    while (!utf8.empty() && (utf8.back() == '\n' || utf8.back() == '\r' || utf8.back() == ' ')) {
        utf8.pop_back();
    }
    size_t start = utf8.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) return false;
    utf8 = utf8.substr(start);

    if (utf8.empty() || utf8[0] != '/') return false;

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
    } else {
        cmdName = withoutSlash.substr(0, spacePos);
        size_t argStart = withoutSlash.find_first_not_of(' ', spacePos);
        if (argStart != std::string::npos) cmdArgs = withoutSlash.substr(argStart);
    }

    std::string key = ToLowerASCII(cmdName);
    if (key.empty()) return false;

    if (key == "42" || key == "42loader" || key == "luasettings") {
        g_LastInterceptedCmd = utf8;
        g_LastInterceptedMs = now;
        LogConsole(std::string("[HookDiag:") + sourceTag + "] Меню переключено командой /" + key);
        ToggleLoaderMenu();
        return true;
    }

    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    auto it = g_ChatCommands.find(key);
    if (it == g_ChatCommands.end()) {
        return false; // Server command -> allow game to send it
    }

    g_LastInterceptedCmd = utf8;
    g_LastInterceptedMs = now;
    LogConsole(std::string("[HookDiag:") + sourceTag + "] Выполнена команда /" + key + (cmdArgs.empty() ? "" : (" " + cmdArgs)));

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

// ============================================================================
// 7. NATIVE UIKIT MENU & FLOATING BUTTON "42"
// ============================================================================

@interface LoaderUIHandler : NSObject <UITextFieldDelegate>
+ (instancetype)shared;
- (void)onFloatingBtnTap:(UIButton*)sender;
- (void)onFloatingBtnPan:(UIPanGestureRecognizer*)pan;
- (void)onCloseMenu:(UIButton*)sender;
- (void)onTabChanged:(UISegmentedControl*)seg;
- (void)onActionBtnTap:(UIButton*)sender;
- (void)onScriptSwitchChanged:(UISwitch*)sw;
- (void)onScriptReloadTap:(UIButton*)btn;
- (void)onDisplayLink:(CADisplayLink*)link;
@end

static void BuildNativeMenuIfNeeded() {
    UIWindow* win = GetActiveKeyWindow();
    if (!win) return;

    if (!g_MenuOverlayView) {
        CGFloat sw = win.bounds.size.width;
        CGFloat sh = win.bounds.size.height;
        CGFloat mw = MIN(sw - 28.0, 540.0);
        CGFloat mh = MIN(sh - 44.0, 340.0);

        UIView* card = [[UIView alloc] initWithFrame:CGRectMake((sw - mw) * 0.5, (sh - mh) * 0.5, mw, mh)];
        card.tag = 424201;
        card.backgroundColor = [UIColor colorWithRed:0.09 green:0.08 blue:0.13 alpha:0.96];
        card.layer.cornerRadius = 16.0;
        card.layer.borderWidth = 1.5;
        card.layer.borderColor = [UIColor colorWithRed:0.55 green:0.35 blue:0.88 alpha:0.90].CGColor;
        card.hidden = YES;

        UIView* header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, mw, 42.0)];
        header.backgroundColor = [UIColor colorWithRed:0.24 green:0.14 blue:0.40 alpha:1.0];
        header.layer.cornerRadius = 16.0;
        header.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        [card addSubview:header];

        UILabel* title = [[UILabel alloc] initWithFrame:CGRectMake(14.0, 0, mw - 180.0, 42.0)];
        title.text = @"Arizona 42Loader  |  Lua 5.4";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:14.0];
        [header addSubview:title];

        g_MenuRamLabel = [[UILabel alloc] initWithFrame:CGRectMake(mw - 175.0, 0, 130.0, 42.0)];
        g_MenuRamLabel.textColor = [UIColor colorWithWhite:0.85 alpha:0.9];
        g_MenuRamLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightMedium];
        g_MenuRamLabel.textAlignment = NSTextAlignmentRight;
        [header addSubview:g_MenuRamLabel];

        UIButton* closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(mw - 40.0, 4.0, 34.0, 34.0);
        [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16.0];
        [closeBtn addTarget:[LoaderUIHandler shared] action:@selector(onCloseMenu:) forControlEvents:UIControlEventTouchUpInside];
        [header addSubview:closeBtn];

        g_MenuTabs = [[UISegmentedControl alloc] initWithItems:@[@"Scripts", @"Commands", @"Console", @"Settings"]];
        g_MenuTabs.frame = CGRectMake(12.0, 48.0, mw - 24.0, 30.0);
        g_MenuTabs.selectedSegmentIndex = 0;
        g_MenuTabs.backgroundColor = [UIColor colorWithRed:0.16 green:0.14 blue:0.22 alpha:1.0];
        if (@available(iOS 13.0, *)) {
            g_MenuTabs.selectedSegmentTintColor = [UIColor colorWithRed:0.48 green:0.26 blue:0.82 alpha:1.0];
        }
        [g_MenuTabs setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateNormal];
        [g_MenuTabs addTarget:[LoaderUIHandler shared] action:@selector(onTabChanged:) forControlEvents:UIControlEventValueChanged];
        [card addSubview:g_MenuTabs];

        g_MenuCmdBar = [[UIView alloc] initWithFrame:CGRectMake(12.0, 84.0, mw - 24.0, 34.0)];
        [card addSubview:g_MenuCmdBar];

        g_MenuCmdField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, mw - 134.0, 34.0)];
        g_MenuCmdField.backgroundColor = [UIColor colorWithRed:0.16 green:0.15 blue:0.22 alpha:1.0];
        g_MenuCmdField.textColor = [UIColor whiteColor];
        g_MenuCmdField.font = [UIFont systemFontOfSize:13.0];
        g_MenuCmdField.layer.cornerRadius = 8.0;
        g_MenuCmdField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 34)];
        g_MenuCmdField.leftViewMode = UITextFieldViewModeAlways;
        g_MenuCmdField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Введите команду (/st 12)..."
                                                                              attributes:@{NSForegroundColorAttributeName: [UIColor lightGrayColor]}];
        g_MenuCmdField.delegate = [LoaderUIHandler shared];
        g_MenuCmdField.returnKeyType = UIReturnKeyDone;
        [g_MenuCmdBar addSubview:g_MenuCmdField];

        g_MenuActionBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        g_MenuActionBtn.frame = CGRectMake(0, 0, 150.0, 34.0);
        g_MenuActionBtn.backgroundColor = [UIColor colorWithRed:0.45 green:0.24 blue:0.78 alpha:1.0];
        g_MenuActionBtn.layer.cornerRadius = 8.0;
        [g_MenuActionBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        g_MenuActionBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
        [g_MenuActionBtn addTarget:[LoaderUIHandler shared] action:@selector(onActionBtnTap:) forControlEvents:UIControlEventTouchUpInside];
        [g_MenuCmdBar addSubview:g_MenuActionBtn];

        g_MenuScrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(12.0, 124.0, mw - 24.0, mh - 134.0)];
        g_MenuScrollView.backgroundColor = [UIColor colorWithRed:0.06 green:0.06 blue:0.09 alpha:0.90];
        g_MenuScrollView.layer.cornerRadius = 10.0;
        [card addSubview:g_MenuScrollView];

        g_MenuOverlayView = card;
    }

    if (g_MenuOverlayView.superview != win) {
        [win addSubview:g_MenuOverlayView];
    }
    [win bringSubviewToFront:g_MenuOverlayView];
}

static void RefreshMenuContent() {
    dispatch_async(dispatch_get_main_queue(), ^{
        BuildNativeMenuIfNeeded();
        if (!g_MenuOverlayView) return;

        g_MenuOverlayView.hidden = !g_MenuOpen;
        if (!g_MenuOpen) return;

        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);

        float totalLuaKB = 0.0f;
        for (auto* s : g_Scripts) {
            if (s->L) totalLuaKB += static_cast<float>(lua_gc(s->L, LUA_GCCOUNT, 0));
        }
        g_MenuRamLabel.text = [NSString stringWithFormat:@"%.1f MB | %.0f KB", GetLoaderRAM_MB(), totalLuaKB];

        for (UIView* sub in g_MenuScrollView.subviews) {
            [sub removeFromSuperview];
        }

        CGFloat w = g_MenuScrollView.bounds.size.width;
        CGFloat y = 8.0;

        if (g_SelectedTab == 0) {
            g_MenuCmdBar.hidden = NO;
            g_MenuCmdField.hidden = YES;
            g_MenuActionBtn.hidden = NO;
            g_MenuActionBtn.frame = CGRectMake(0, 0, 155.0, 34.0);
            [g_MenuActionBtn setTitle:@"Reload All Scripts" forState:UIControlStateNormal];

            UILabel* dirLbl = [[UILabel alloc] initWithFrame:CGRectMake(10.0, y, w - 20.0, 18.0)];
            dirLbl.text = @"Папка: Documents/lua_loader/scripts";
            dirLbl.textColor = [UIColor lightGrayColor];
            dirLbl.font = [UIFont systemFontOfSize:11.0];
            [g_MenuScrollView addSubview:dirLbl];
            y += 24.0;

            if (g_Scripts.empty()) {
                UILabel* emptyLbl = [[UILabel alloc] initWithFrame:CGRectMake(10.0, y, w - 20.0, 24.0)];
                emptyLbl.text = @"Нет загруженных .lua скриптов";
                emptyLbl.textColor = [UIColor grayColor];
                emptyLbl.font = [UIFont systemFontOfSize:13.0];
                [g_MenuScrollView addSubview:emptyLbl];
                y += 30.0;
            }

            for (size_t i = 0; i < g_Scripts.size(); i++) {
                LuaScriptInstance* s = g_Scripts[i];

                UISwitch* sw = [[UISwitch alloc] initWithFrame:CGRectMake(10.0, y + 2.0, 51.0, 31.0)];
                sw.on = s->enabled;
                sw.tag = static_cast<NSInteger>(i);
                sw.transform = CGAffineTransformMakeScale(0.82, 0.82);
                [sw addTarget:[LoaderUIHandler shared] action:@selector(onScriptSwitchChanged:) forControlEvents:UIControlEventValueChanged];
                [g_MenuScrollView addSubview:sw];

                UILabel* nameLbl = [[UILabel alloc] initWithFrame:CGRectMake(62.0, y, w - 195.0, 32.0)];
                nameLbl.text = [NSString stringWithUTF8String:s->filename.c_str()];
                nameLbl.textColor = [UIColor whiteColor];
                nameLbl.font = [UIFont boldSystemFontOfSize:13.0];
                [g_MenuScrollView addSubview:nameLbl];

                UILabel* statusLbl = [[UILabel alloc] initWithFrame:CGRectMake(w - 130.0, y, 56.0, 32.0)];
                if (s->hasError) {
                    statusLbl.text = @"[ERROR]";
                    statusLbl.textColor = [UIColor systemRedColor];
                } else if (s->enabled) {
                    statusLbl.text = @"[OK]";
                    statusLbl.textColor = [UIColor systemGreenColor];
                } else {
                    statusLbl.text = @"[OFF]";
                    statusLbl.textColor = [UIColor grayColor];
                }
                statusLbl.font = [UIFont boldSystemFontOfSize:11.0];
                [g_MenuScrollView addSubview:statusLbl];

                UIButton* relBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                relBtn.frame = CGRectMake(w - 72.0, y + 2.0, 62.0, 28.0);
                relBtn.backgroundColor = [UIColor colorWithRed:0.22 green:0.20 blue:0.30 alpha:1.0];
                relBtn.layer.cornerRadius = 6.0;
                relBtn.tag = static_cast<NSInteger>(i);
                [relBtn setTitle:@"Reload" forState:UIControlStateNormal];
                [relBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                relBtn.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
                [relBtn addTarget:[LoaderUIHandler shared] action:@selector(onScriptReloadTap:) forControlEvents:UIControlEventTouchUpInside];
                [g_MenuScrollView addSubview:relBtn];

                y += 36.0;

                if (s->hasError && !s->lastError.empty()) {
                    NSString* errStr = [NSString stringWithUTF8String:ShortenPathForUI(s->lastError).c_str()];
                    UILabel* errLbl = [[UILabel alloc] initWithFrame:CGRectMake(16.0, y, w - 32.0, 44.0)];
                    errLbl.text = errStr;
                    errLbl.textColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.45 alpha:1.0];
                    errLbl.font = [UIFont systemFontOfSize:11.0];
                    errLbl.numberOfLines = 0;
                    [errLbl sizeToFit];
                    [g_MenuScrollView addSubview:errLbl];
                    y += errLbl.bounds.size.height + 8.0;
                }
            }

        } else if (g_SelectedTab == 1) {
            g_MenuCmdBar.hidden = NO;
            g_MenuCmdField.hidden = NO;
            g_MenuActionBtn.hidden = NO;
            g_MenuCmdField.frame = CGRectMake(0, 0, w - 102.0, 34.0);
            g_MenuActionBtn.frame = CGRectMake(w - 94.0, 0, 94.0, 34.0);
            [g_MenuActionBtn setTitle:@"Выполнить" forState:UIControlStateNormal];

            UILabel* infoLbl = [[UILabel alloc] initWithFrame:CGRectMake(10.0, y, w - 20.0, 34.0)];
            infoLbl.text = @"Меню: /42, /42loader, /luasettings\nКоманды скриптов (выполняются после отправки в чат):";
            infoLbl.textColor = [UIColor lightGrayColor];
            infoLbl.font = [UIFont systemFontOfSize:11.5];
            infoLbl.numberOfLines = 0;
            [g_MenuScrollView addSubview:infoLbl];
            y += 38.0;

            for (const auto& kv : g_ChatCommands) {
                UILabel* cmdLbl = [[UILabel alloc] initWithFrame:CGRectMake(12.0, y, w - 24.0, 22.0)];
                cmdLbl.text = [NSString stringWithFormat:@"• /%s  (%s)", kv.first.c_str(), kv.second.scriptName.c_str()];
                cmdLbl.textColor = [UIColor whiteColor];
                cmdLbl.font = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightMedium];
                [g_MenuScrollView addSubview:cmdLbl];
                y += 24.0;
            }

        } else if (g_SelectedTab == 2) {
            g_MenuCmdBar.hidden = NO;
            g_MenuCmdField.hidden = YES;
            g_MenuActionBtn.hidden = NO;
            g_MenuActionBtn.frame = CGRectMake(0, 0, 130.0, 34.0);
            [g_MenuActionBtn setTitle:@"Clear Console" forState:UIControlStateNormal];

            for (const auto& line : g_ConsoleLogs) {
                NSString* nsLine = [NSString stringWithUTF8String:line.c_str()] ?: @"";
                UILabel* logLbl = [[UILabel alloc] initWithFrame:CGRectMake(10.0, y, w - 20.0, 20.0)];
                logLbl.text = nsLine;
                logLbl.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
                logLbl.numberOfLines = 0;
                if (line.find("ERROR") != std::string::npos || line.find("НЕ НАЙДЕН") != std::string::npos) {
                    logLbl.textColor = [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0];
                } else if (line.find("HookDiag") != std::string::npos || line.find("[OK]") != std::string::npos || line.find("НАЙДЕН") != std::string::npos) {
                    logLbl.textColor = [UIColor colorWithRed:0.45 green:0.95 blue:0.60 alpha:1.0];
                } else {
                    logLbl.textColor = [UIColor colorWithWhite:0.90 alpha:1.0];
                }
                [logLbl sizeToFit];
                [g_MenuScrollView addSubview:logLbl];
                y += logLbl.bounds.size.height + 4.0;
            }

        } else if (g_SelectedTab == 3) {
            g_MenuCmdBar.hidden = YES;

            bool hasNativeChat = (g_ppChatWindow != nullptr) && (g_fnAddChatMessage != nullptr || g_fnAddClientMessage != nullptr);
            bool hasNativeClock = (g_fnSetGameClock != nullptr) || (g_pGameClockHours != nullptr && g_pGameClockMinutes != nullptr);

            UILabel* setLbl = [[UILabel alloc] initWithFrame:CGRectMake(12.0, y, w - 24.0, 150.0)];
            setLbl.text = [NSString stringWithFormat:
                @"Время мира: %02d:%02d (%s)\nПогода ID: %d\nНативный чат: %s\nНативные часы (CClock): %s\nСкриптов: %zu | Команд: %zu",
                g_WorldHour, g_WorldMinute, g_TimeOverrideActive ? "фикс" : "авто",
                g_WorldWeather,
                hasNativeChat ? "Да" : "HUD оверлей",
                hasNativeClock ? "Найдены" : "Вырезаны (stripped)",
                g_Scripts.size(), g_ChatCommands.size()];
            setLbl.textColor = [UIColor whiteColor];
            setLbl.font = [UIFont systemFontOfSize:13.0];
            setLbl.numberOfLines = 0;
            [setLbl sizeToFit];
            [g_MenuScrollView addSubview:setLbl];
            y += setLbl.bounds.size.height + 12.0;
        }

        g_MenuScrollView.contentSize = CGSizeMake(w, MAX(y + 10.0, g_MenuScrollView.bounds.size.height));
        if (g_SelectedTab == 2 && g_MenuScrollView.contentSize.height > g_MenuScrollView.bounds.size.height) {
            CGPoint bottomOffset = CGPointMake(0, g_MenuScrollView.contentSize.height - g_MenuScrollView.bounds.size.height);
            [g_MenuScrollView setContentOffset:bottomOffset animated:NO];
        }
    });
}

static void ToggleLoaderMenu() {
    g_MenuOpen = !g_MenuOpen;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_FloatingMenuButton) {
            g_FloatingMenuButton.backgroundColor = g_MenuOpen
                ? [UIColor colorWithRed:0.52 green:0.26 blue:0.88 alpha:0.95]
                : [UIColor colorWithRed:0.15 green:0.11 blue:0.25 alpha:0.90];
        }
        RefreshMenuContent();
    });
}

static void EnsureFloatingMenuButton() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow* win = GetActiveKeyWindow();
        if (!win) return;

        if (g_FloatingMenuButton) {
            if (g_FloatingMenuButton.superview != win) [win addSubview:g_FloatingMenuButton];
            [win bringSubviewToFront:g_FloatingMenuButton];
            if (g_MenuOverlayView && !g_MenuOverlayView.hidden) {
                [win bringSubviewToFront:g_MenuOverlayView];
            }
            return;
        }

        UIButton* btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = 424200;
        btn.frame = CGRectMake(18.0, 52.0, 48.0, 48.0);
        btn.backgroundColor = [UIColor colorWithRed:0.15 green:0.11 blue:0.25 alpha:0.90];
        btn.layer.cornerRadius = 24.0;
        btn.layer.borderWidth = 1.5;
        btn.layer.borderColor = [UIColor colorWithRed:0.62 green:0.38 blue:0.95 alpha:0.95].CGColor;
        [btn setTitle:@"42" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:16.0];

        [btn addTarget:[LoaderUIHandler shared] action:@selector(onFloatingBtnTap:) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc] initWithTarget:[LoaderUIHandler shared] action:@selector(onFloatingBtnPan:)];
        [btn addGestureRecognizer:pan];

        [win addSubview:btn];
        [win bringSubviewToFront:btn];
        g_FloatingMenuButton = btn;
    });
}

// ============================================================================
// 8. SUBMIT-ONLY CHAT INPUT INTERCEPTION
// ============================================================================

typedef void (*Fn_SetDelegate)(id, SEL, id);
typedef BOOL (*Fn_TextFieldShouldReturn)(id, SEL, UITextField*);
typedef BOOL (*Fn_TFShouldChangeChars)(id, SEL, UITextField*, NSRange, NSString*);
typedef BOOL (*Fn_TVShouldChangeText)(id, SEL, UITextView*, NSRange, NSString*);
typedef BOOL (*Fn_SendAction)(id, SEL, SEL, id, id, UIEvent*);
typedef void (*Fn_InsertText)(id, SEL, NSString*);
typedef BOOL (*Fn_BecomeFirstResponder)(id, SEL);

static Fn_SetDelegate orig_TFSetDelegate = nullptr;
static Fn_SetDelegate orig_TVSetDelegate = nullptr;
static Fn_SendAction orig_SendAction = nullptr;
static Fn_BecomeFirstResponder orig_BecomeFirstResponder = nullptr;

static std::unordered_map<Class, IMP> g_OrigShouldReturnMap;
static std::unordered_map<Class, IMP> g_OrigTFShouldChangeMap;
static std::unordered_map<Class, IMP> g_OrigTVShouldChangeMap;
static std::unordered_map<Class, IMP> g_OrigInsertTextMap;

static void HookMethodOnClass(Class cls, SEL sel, IMP replacement, std::unordered_map<Class, IMP>& origMap) {
    if (!cls || origMap.find(cls) != origMap.end()) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP currentImp = method_getImplementation(m);
    if (currentImp == replacement) return;

    const char* types = method_getTypeEncoding(m);
    if (class_addMethod(cls, sel, replacement, types)) {
        origMap[cls] = currentImp;
    } else {
        origMap[cls] = method_setImplementation(m, replacement);
    }
}

static BOOL swizzled_textFieldShouldReturn(id self, SEL _cmd, UITextField* textField) {
    if (textField && textField != g_MenuCmdField && textField.text.length > 0) {
        std::string txt([textField.text UTF8String]);
        if (TryExecuteChatCommand(txt, "TF-ShouldReturn")) {
            textField.text = @"";
            [textField resignFirstResponder];
            return NO;
        }
    }
    Class cls = object_getClass(self);
    auto it = g_OrigShouldReturnMap.find(cls);
    if (it != g_OrigShouldReturnMap.end() && it->second) {
        return ((Fn_TextFieldShouldReturn)it->second)(self, _cmd, textField);
    }
    return YES;
}

static BOOL swizzled_tfShouldChangeChars(id self, SEL _cmd, UITextField* textField, NSRange range, NSString* string) {
    if (string && ([string rangeOfString:@"\n"].location != NSNotFound || [string rangeOfString:@"\r"].location != NSNotFound)) {
        if (textField && textField != g_MenuCmdField && textField.text.length > 0) {
            std::string txt([textField.text UTF8String]);
            if (TryExecuteChatCommand(txt, "TF-Newline")) {
                textField.text = @"";
                [textField resignFirstResponder];
                return NO;
            }
        }
    }
    Class cls = object_getClass(self);
    auto it = g_OrigTFShouldChangeMap.find(cls);
    if (it != g_OrigTFShouldChangeMap.end() && it->second) {
        return ((Fn_TFShouldChangeChars)it->second)(self, _cmd, textField, range, string);
    }
    return YES;
}

static BOOL swizzled_tvShouldChangeText(id self, SEL _cmd, UITextView* textView, NSRange range, NSString* text) {
    if (text && ([text rangeOfString:@"\n"].location != NSNotFound || [text rangeOfString:@"\r"].location != NSNotFound)) {
        if (textView && textView.text.length > 0) {
            std::string txt([textView.text UTF8String]);
            if (TryExecuteChatCommand(txt, "TV-Newline")) {
                textView.text = @"";
                [textView resignFirstResponder];
                return NO;
            }
        }
    }
    Class cls = object_getClass(self);
    auto it = g_OrigTVShouldChangeMap.find(cls);
    if (it != g_OrigTVShouldChangeMap.end() && it->second) {
        return ((Fn_TVShouldChangeText)it->second)(self, _cmd, textView, range, text);
    }
    return YES;
}

static void HookDelegateObject(id delegate) {
    if (!delegate || delegate == [LoaderUIHandler shared]) return;
    Class cls = object_getClass(delegate);
    if (!cls) return;
    const char* name = class_getName(cls);
    if (!name || strncmp(name, "_UI", 3) == 0 || strncmp(name, "UI", 2) == 0) return;

    HookMethodOnClass(cls, @selector(textFieldShouldReturn:), (IMP)swizzled_textFieldShouldReturn, g_OrigShouldReturnMap);
    HookMethodOnClass(cls, @selector(textField:shouldChangeCharactersInRange:replacementString:), (IMP)swizzled_tfShouldChangeChars, g_OrigTFShouldChangeMap);
    HookMethodOnClass(cls, @selector(textView:shouldChangeTextInRange:replacementText:), (IMP)swizzled_tvShouldChangeText, g_OrigTVShouldChangeMap);
}

static void swizzled_TFSetDelegate(id self, SEL _cmd, id delegate) {
    HookDelegateObject(delegate);
    if (orig_TFSetDelegate) orig_TFSetDelegate(self, _cmd, delegate);
}

static void swizzled_TVSetDelegate(id self, SEL _cmd, id delegate) {
    HookDelegateObject(delegate);
    if (orig_TVSetDelegate) orig_TVSetDelegate(self, _cmd, delegate);
}

static void swizzled_insertText(id self, SEL _cmd, NSString* text) {
    if (text && ([text rangeOfString:@"\n"].location != NSNotFound || [text rangeOfString:@"\r"].location != NSNotFound)) {
        NSString* current = nil;
        if ([self respondsToSelector:@selector(text)]) {
            current = [(id)self performSelector:@selector(text)];
        }
        if ([current isKindOfClass:[NSString class]] && current.length > 0) {
            std::string txt([current UTF8String]);
            if (TryExecuteChatCommand(txt, "KeyInput-InsertNewline")) {
                if ([self respondsToSelector:@selector(setText:)]) {
                    [(id)self performSelector:@selector(setText:) withObject:@""];
                }
                if ([self respondsToSelector:@selector(resignFirstResponder)]) {
                    [(id)self resignFirstResponder];
                }
                return;
            }
        }
    }
    Class cls = object_getClass(self);
    auto it = g_OrigInsertTextMap.find(cls);
    if (it != g_OrigInsertTextMap.end() && it->second) {
        ((Fn_InsertText)it->second)(self, _cmd, text);
    }
}

static BOOL swizzled_becomeFirstResponder(id self, SEL _cmd) {
    BOOL res = orig_BecomeFirstResponder ? orig_BecomeFirstResponder(self, _cmd) : YES;
    if (res && [self conformsToProtocol:@protocol(UIKeyInput)]) {
        g_ActiveInputView = (UIView*)self;
        if ([self respondsToSelector:@selector(delegate)]) {
            HookDelegateObject([(id)self performSelector:@selector(delegate)]);
        }
        Class cls = object_getClass(self);
        const char* name = cls ? class_getName(cls) : nullptr;
        if (name && strncmp(name, "_UI", 3) != 0 && strncmp(name, "UI", 2) != 0) {
            HookMethodOnClass(cls, @selector(insertText:), (IMP)swizzled_insertText, g_OrigInsertTextMap);
        }
    }
    return res;
}

static BOOL swizzled_sendAction(id self, SEL _cmd, SEL action, id target, id sender, UIEvent* event) {
    if ([sender isKindOfClass:[UITextField class]]) {
        UITextField* tf = (UITextField*)sender;
        if (tf != g_MenuCmdField && tf.text.length > 0 && action && target) {
            NSArray<NSString*>* exitActions = [tf actionsForTarget:target forControlEvent:UIControlEventEditingDidEndOnExit];
            if ([exitActions containsObject:NSStringFromSelector(action)]) {
                std::string txt([tf.text UTF8String]);
                if (TryExecuteChatCommand(txt, "TF-DidEndOnExit")) {
                    tf.text = @"";
                    [tf resignFirstResponder];
                    return NO;
                }
            }
        }
        return orig_SendAction ? orig_SendAction(self, _cmd, action, target, sender, event) : NO;
    }

    if ([sender isKindOfClass:[UIButton class]] && sender != g_MenuActionBtn && sender != g_FloatingMenuButton) {
        UIView* active = g_ActiveInputView;
        if (active && active != g_MenuCmdField && active.isFirstResponder && [active respondsToSelector:@selector(text)]) {
            NSString* cur = [(id)active performSelector:@selector(text)];
            if ([cur isKindOfClass:[NSString class]] && cur.length > 0) {
                std::string txt([cur UTF8String]);
                if (TryExecuteChatCommand(txt, "SendBtn-Tap")) {
                    if ([active respondsToSelector:@selector(setText:)]) {
                        [(id)active performSelector:@selector(setText:) withObject:@""];
                    }
                    [active resignFirstResponder];
                    return NO;
                }
            }
        }
    }

    return orig_SendAction ? orig_SendAction(self, _cmd, action, target, sender, event) : NO;
}

static void ScanExistingViews(UIView* root) {
    if (!root) return;
    if ([root isKindOfClass:[UITextField class]]) {
        UITextField* tf = (UITextField*)root;
        if (tf != g_MenuCmdField) {
            HookDelegateObject(tf.delegate);
            if (tf.isFirstResponder) g_ActiveInputView = tf;
        }
    } else if ([root isKindOfClass:[UITextView class]]) {
        UITextView* tv = (UITextView*)root;
        HookDelegateObject(tv.delegate);
        if (tv.isFirstResponder) g_ActiveInputView = tv;
    }
    for (UIView* sub in root.subviews) {
        ScanExistingViews(sub);
    }
}

static void InstallSafeUIKitChatHooks() {
    Method mTFDel = class_getInstanceMethod([UITextField class], @selector(setDelegate:));
    if (mTFDel && method_getImplementation(mTFDel) != (IMP)swizzled_TFSetDelegate) {
        orig_TFSetDelegate = (Fn_SetDelegate)method_setImplementation(mTFDel, (IMP)swizzled_TFSetDelegate);
    }

    Method mTVDel = class_getInstanceMethod([UITextView class], @selector(setDelegate:));
    if (mTVDel && method_getImplementation(mTVDel) != (IMP)swizzled_TVSetDelegate) {
        orig_TVSetDelegate = (Fn_SetDelegate)method_setImplementation(mTVDel, (IMP)swizzled_TVSetDelegate);
    }

    Method mAct = class_getInstanceMethod([UIApplication class], @selector(sendAction:to:from:forEvent:));
    if (mAct && method_getImplementation(mAct) != (IMP)swizzled_sendAction) {
        orig_SendAction = (Fn_SendAction)method_setImplementation(mAct, (IMP)swizzled_sendAction);
    }

    Method mBfr = class_getInstanceMethod([UIView class], @selector(becomeFirstResponder));
    if (mBfr && method_getImplementation(mBfr) != (IMP)swizzled_becomeFirstResponder) {
        orig_BecomeFirstResponder = (Fn_BecomeFirstResponder)method_setImplementation(mBfr, (IMP)swizzled_becomeFirstResponder);
    }

    UIWindow* win = GetActiveKeyWindow();
    if (win) ScanExistingViews(win);

    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];

    [nc addObserverForName:UITextFieldTextDidBeginEditingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification* note) {
        UITextField* tf = note.object;
        if ([tf isKindOfClass:[UITextField class]] && tf != g_MenuCmdField) {
            g_ActiveInputView = tf;
            g_IsChatInputActive = true;
            HookDelegateObject(tf.delegate);
        }
    }];

    [nc addObserverForName:UITextFieldTextDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification* note) {
        UITextField* tf = note.object;
        if ([tf isKindOfClass:[UITextField class]] && tf != g_MenuCmdField) {
            g_ActiveInputView = tf;
            g_ChatInputText = tf.text ? [tf.text UTF8String] : "";
            g_IsChatInputActive = true;
        }
    }];

    [nc addObserverForName:UITextFieldTextDidEndEditingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification* note) {
        g_IsChatInputActive = false;
        UITextField* tf = note.object;
        NSNumber* reason = note.userInfo[UITextFieldDidEndEditingReasonKey];
        BOOL committed = (reason != nil && [reason integerValue] == UITextFieldDidEndEditingReasonCommitted);
        if (committed && [tf isKindOfClass:[UITextField class]] && tf != g_MenuCmdField && tf.text.length > 0) {
            std::string txt([tf.text UTF8String]);
            if (TryExecuteChatCommand(txt, "TF-Committed")) {
                tf.text = @"";
            }
        }
    }];

    [nc addObserverForName:UITextViewTextDidBeginEditingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification* note) {
        UITextView* tv = note.object;
        if ([tv isKindOfClass:[UITextView class]]) {
            g_ActiveInputView = tv;
            g_IsChatInputActive = true;
            HookDelegateObject(tv.delegate);
        }
    }];

    [nc addObserverForName:UITextViewTextDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification* note) {
        UITextView* tv = note.object;
        if ([tv isKindOfClass:[UITextView class]]) {
            g_ActiveInputView = tv;
            g_ChatInputText = tv.text ? [tv.text UTF8String] : "";
            g_IsChatInputActive = true;
        }
    }];
}

// ============================================================================
// 9. LUA 5.4 C++ API FUNCTIONS (MOONLOADER + AZ + SAMP)
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

    inst->threads.push_back({co, ref, NowMs(), suspended, false});

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
    uint32_t color = static_cast<uint32_t>(luaL_optinteger(L, 2, 0xFF9B59B6));
    std::string utf8 = Cp1251ToUtf8(text);

    LogConsole("[Chat] " + utf8);
    WriteToInGameChat(utf8, color);
    return 0;
}

static int l_sampSendChat(lua_State* L) {
    std::string utf8 = Cp1251ToUtf8(luaL_checkstring(L, 1));
    LogConsole("[ChatOut] " + utf8);
    SendToInGameServer(utf8);
    return 0;
}

static int l_sampProcessChatInput(lua_State* L) {
    std::string utf8 = Cp1251ToUtf8(luaL_checkstring(L, 1));
    if (!TryExecuteChatCommand(utf8, "sampProcessChatInput")) {
        LogConsole("[ChatOut] " + utf8);
        SendToInGameServer(utf8);
    }
    return 0;
}

static int l_sampShowDialog(lua_State* L) {
    int id = static_cast<int>(luaL_checkinteger(L, 1));
    std::string uTitle = Cp1251ToUtf8(luaL_optstring(L, 2, ""));
    std::string uText = Cp1251ToUtf8(luaL_optstring(L, 3, ""));
    std::string uBtn1 = Cp1251ToUtf8(luaL_optstring(L, 4, "OK"));
    std::string uBtn2 = Cp1251ToUtf8(luaL_optstring(L, 5, ""));
    int style = static_cast<int>(luaL_optinteger(L, 6, 0));

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
                                                handler:^(UIAlertAction* _Nonnull) { g_IsDialogActive = false; }]];
        if (!uBtn2.empty()) {
            [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithUTF8String:uBtn2.c_str()]
                                                      style:UIAlertActionStyleCancel
                                                    handler:^(UIAlertAction* _Nonnull) { g_IsDialogActive = false; }]];
        }
        UIWindow* win = GetActiveKeyWindow();
        UIViewController* topVC = win.rootViewController;
        while (topVC.presentedViewController) topVC = topVC.presentedViewController;
        [topVC presentViewController:alert animated:YES completion:nil];
    });
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
    int h = static_cast<int>(luaL_checkinteger(L, 1));
    int m = static_cast<int>(luaL_optinteger(L, 2, 0));
    if (h < 0) {
        g_TimeOverrideActive = false;
        LogConsole("[World] Фиксация времени отключена");
        return 0;
    }
    g_WorldHour = h % 24;
    g_WorldMinute = (m < 0 ? 0 : m) % 60;
    g_TimeOverrideActive = true;
    ApplyWorldOverridesToEngine();
    LogConsole("[World] Установлено время: " + std::to_string(g_WorldHour) + ":" + (g_WorldMinute < 10 ? "0" : "") + std::to_string(g_WorldMinute));
    return 0;
}

static int l_getTimeOfDay(lua_State* L) {
    if (g_pGameClockHours && g_pGameClockMinutes) {
        lua_pushinteger(L, *g_pGameClockHours);
        lua_pushinteger(L, *g_pGameClockMinutes);
    } else {
        lua_pushinteger(L, g_WorldHour);
        lua_pushinteger(L, g_WorldMinute);
    }
    return 2;
}

static int l_forceWeatherNow(lua_State* L) {
    int w = static_cast<int>(luaL_checkinteger(L, 1));
    if (w < 0) {
        g_WeatherOverrideActive = false;
        return 0;
    }
    g_WorldWeather = w;
    g_WeatherOverrideActive = true;
    ApplyWorldOverridesToEngine();
    LogConsole("[World] Установлена погода ID: " + std::to_string(g_WorldWeather));
    return 0;
}

static int l_getScreenResolution(lua_State* L) {
    CGRect bounds = [[UIScreen mainScreen] nativeBounds];
    lua_pushinteger(L, static_cast<lua_Integer>(bounds.size.width));
    lua_pushinteger(L, static_cast<lua_Integer>(bounds.size.height));
    return 2;
}
static int l_getWorkingDirectory(lua_State* L) { lua_pushstring(L, GetBaseDir().c_str()); return 1; }
static int l_doesFileExist(lua_State* L) {
    BOOL isDir = NO;
    BOOL ex = [[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithUTF8String:luaL_checkstring(L, 1)] isDirectory:&isDir];
    lua_pushboolean(L, ex && !isDir);
    return 1;
}
static int l_doesDirectoryExist(lua_State* L) {
    BOOL isDir = NO;
    BOOL ex = [[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithUTF8String:luaL_checkstring(L, 1)] isDirectory:&isDir];
    lua_pushboolean(L, ex && isDir);
    return 1;
}
static int l_createDirectory(lua_State* L) {
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:luaL_checkstring(L, 1)]
                                        withIntermediateDirectories:YES attributes:nil error:nil];
    lua_pushboolean(L, ok);
    return 1;
}

static int l_az_vibrate(lua_State* L) {
    int style = static_cast<int>(luaL_optinteger(L, 1, 1));
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImpactFeedbackStyle s = (style == 0) ? UIImpactFeedbackStyleLight : (style >= 2 ? UIImpactFeedbackStyleHeavy : UIImpactFeedbackStyleMedium);
        UIImpactFeedbackGenerator* gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:s];
        [gen prepare];
        [gen impactOccurred];
    });
    return 0;
}
static int l_az_setClipboard(lua_State* L) {
    NSString* str = [NSString stringWithUTF8String:luaL_checkstring(L, 1)];
    dispatch_async(dispatch_get_main_queue(), ^{ [UIPasteboard generalPasteboard].string = str; });
    return 0;
}
static int l_az_getClipboard(lua_State* L) {
    NSString* str = [UIPasteboard generalPasteboard].string;
    lua_pushstring(L, str ? [str UTF8String] : "");
    return 1;
}
static int l_az_notify(lua_State* L) {
    std::string title = Cp1251ToUtf8(luaL_checkstring(L, 1));
    std::string msg = Cp1251ToUtf8(luaL_checkstring(L, 2));
    WriteToInGameChat("[" + title + "] " + msg, 0xFF9B59B6);
    return 0;
}
static int l_az_banner(lua_State* L) {
    ShowStartupBanner([NSString stringWithUTF8String:Cp1251ToUtf8(luaL_checkstring(L, 1)).c_str()], NO);
    return 0;
}
static int l_az_openURL(lua_State* L) {
    NSURL* nsurl = [NSURL URLWithString:[NSString stringWithUTF8String:luaL_checkstring(L, 1)]];
    if (nsurl) dispatch_async(dispatch_get_main_queue(), ^{ [[UIApplication sharedApplication] openURL:nsurl options:@{} completionHandler:nil]; });
    return 0;
}
static int l_az_getLoaderRAM(lua_State* L) { lua_pushnumber(L, GetLoaderRAM_MB()); return 1; }

static int l_asyncHttpRequest(lua_State* L) {
    const char* method = luaL_checkstring(L, 1);
    const char* url = luaL_checkstring(L, 2);
    const char* body = lua_isstring(L, 3) ? lua_tostring(L, 3) : nullptr;
    int okRef = lua_isfunction(L, 4) ? (lua_pushvalue(L, 4), luaL_ref(L, LUA_REGISTRYINDEX)) : LUA_NOREF;
    int errRef = lua_isfunction(L, 5) ? (lua_pushvalue(L, 5), luaL_ref(L, LUA_REGISTRYINDEX)) : LUA_NOREF;

    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithUTF8String:url]]];
    req.HTTPMethod = [NSString stringWithUTF8String:method];
    if (body) req.HTTPBody = [[NSString stringWithUTF8String:body] dataUsingEncoding:NSUTF8StringEncoding];

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

// Safe no-op stubs for imgui.* (Test UI removed)
static int l_imgui_Begin(lua_State* L) {
    bool hasClose = lua_isboolean(L, 2);
    lua_pushboolean(L, 0);
    if (hasClose) { lua_pushboolean(L, 0); return 2; }
    return 1;
}
static int l_imgui_Button(lua_State* L) { lua_pushboolean(L, 0); return 1; }
static int l_imgui_Noop(lua_State* L) { return 0; }

// ============================================================================
// 10. MOONLOADER BUILT-IN RUNTIME & LIBRARIES
// ============================================================================

static const char* kMoonLoaderBootstrapLua = R"lua(
_SCRIPT_META = { name = "", filename = "", path = "", directory = getWorkingDirectory(), authors = {}, version = "", version_num = 0, description = "", dependencies = {}, url = "", properties = {} }
function script_name(n) _SCRIPT_META.name = tostring(n or "") end
function script_author(...) _SCRIPT_META.authors = {...} end
function script_version(v) _SCRIPT_META.version = tostring(v or "") end
function script_version_number(n) _SCRIPT_META.version_num = tonumber(n) or 0 end
function script_description(d) _SCRIPT_META.description = tostring(d or "") end
function script_dependencies(...) _SCRIPT_META.dependencies = {...} end
function script_url(u) _SCRIPT_META.url = tostring(u or "") end
function script_properties(...) _SCRIPT_META.properties = {...} end
function thisScript()
    local t = {}
    for k, v in pairs(_SCRIPT_META) do t[k] = v end
    t.unload = function() end; t.reload = function() end; t.pause = function() end; t.resume = function() end
    return t
end

PLAYER_PED = 1; PLAYER_HANDLE = 0
function isCharInAnyCar() return false end
function storeCarCharIsInNoSave() return 0 end
function getCharCoordinates() return 0.0, 0.0, 0.0 end
function setCharCoordinates() end
function getCharHealth() return 100 end
function setCharHealth() end
function getCharArmour() return 0 end
function getCharHeading() return 0.0 end
function setCharHeading() end
function addOneOffSound() if az and az.vibrate then az.vibrate(0) end end
function printStringNow(text, time) sampAddChatMessage(tostring(text), 0xFFFFFFFF) end
function printString(text, time) printStringNow(text, time) end
function isKeyDown() return false end
function wasKeyPressed() return false end
function isKeyJustPressed() return false end
function convert3DCoordsToScreen() return 0, 0 end
function convert3DCoordsToScreenEx() return false, 0, 0, 0, 0, 0 end

function sampGetCurrentServerName() return "Arizona RP Mobile" end
function sampGetCurrentServerAddress() return "127.0.0.1", 7777 end
function sampGetPlayerNickname(id) return "Player_" .. tostring(id or 0) end
function sampGetPlayerScore() return 1 end
function sampGetPlayerPing() return 20 end
function sampGetPlayerColor() return 0xFFFFFFFF end
function sampGetPlayerHealth() return 100 end
function sampGetPlayerArmor() return 0 end
function sampIsPlayerConnected() return true end
function sampIsPlayerNpc() return false end
function sampGetMaxPlayerId() return 1000 end
function sampGetPlayerIdByCharHandle() return true, 0 end
function sampGetCharHandleBySampPlayerId() return false, 0 end
function sampSendDialogResponse() end
function sampCloseCurrentDialogWithButton() end
function sampSendClickTextdraw() end
function sampTextdrawIsExists() return false end
function sampTextdrawGetString() return "" end
function sampCreate3dText() return 1 end
function sampDestroy3dText() end
function sampIs3dTextDefined() return false end

local _sampev = {}
package.preload["samp.events"] = function() return _sampev end
package.preload["lib.samp.events"] = function() return _sampev end
function _DISPATCH_SAMP_EVENT(name, ...)
    if type(_sampev[name]) == "function" then return _sampev[name](...) end
end

package.preload["inicfg"] = function()
    local inicfg = {}
    local cfgDir = getWorkingDirectory() .. "/config/"
    local function resolvePath(fn)
        if not fn then fn = "default.ini" end
        if fn:find("^/") then return fn end
        if not fn:match("%.ini$") then fn = fn .. ".ini" end
        return cfgDir .. fn
    end
    local function deepCopy(t)
        local r = {}
        for k, v in pairs(t or {}) do r[k] = type(v) == "table" and deepCopy(v) or v end
        return r
    end
    function inicfg.load(def, fn)
        local data = deepCopy(def)
        local f = io.open(resolvePath(fn), "r")
        if not f then return data end
        local sec = nil
        for line in f:lines() do
            line = line:gsub("\r$", "")
            local s = line:match("^%s*%[([^%]]+)%]%s*$")
            if s then sec = s; data[sec] = data[sec] or {}
            else
                local k, v = line:match("^%s*([^=;#]+)%s*=%s*(.-)%s*$")
                if k and v then
                    local tgt = sec and data[sec] or data
                    if v == "true" then tgt[k] = true
                    elseif v == "false" then tgt[k] = false
                    elseif tonumber(v) then tgt[k] = tonumber(v)
                    else tgt[k] = v end
                end
            end
        end
        f:close()
        return data
    end
    function inicfg.save(data, fn)
        local f = io.open(resolvePath(fn), "w")
        if not f then return false end
        for k, v in pairs(data or {}) do
            if type(v) == "table" then
                f:write("[" .. tostring(k) .. "]\n")
                for sk, sv in pairs(v) do f:write(tostring(sk) .. "=" .. tostring(sv) .. "\n") end
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
    local obj = setmetatable({}, { __call = function(_, s) return tostring(s or "") end })
    function obj:decode(s) return tostring(s or "") end
    function obj:encode(s) return tostring(s or "") end
    return { default = "CP1251", UTF8 = obj, CP1251 = obj }
end

local function _json_encode(val)
    local t = type(val)
    if val == nil then return "null"
    elseif t == "boolean" then return val and "true" or "false"
    elseif t == "number" then return tostring(val)
    elseif t == "string" then return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r') .. '"'
    elseif t == "table" then
        local parts = {}
        if #val > 0 then
            for i = 1, #val do parts[#parts + 1] = _json_encode(val[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(val) do parts[#parts + 1] = _json_encode(tostring(k)) .. ":" .. _json_encode(v) end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

local function _json_decode(str)
    if type(str) ~= "string" then return nil end
    local expr = str:gsub('"%s*:%s*', '"]='):gsub('{%s*"', '{["'):gsub(',%s*"', ',["'):gsub('%[', '{'):gsub('%]', '}'):gsub(':%s*true', '=true'):gsub(':%s*false', '=false'):gsub(':%s*null', '=nil')
    local fn = load("return " .. expr)
    if fn then local ok, res = pcall(fn); if ok then return res end end
    return nil
end

encodeJson = _json_encode; decodeJson = _json_decode
local _jmod = { encode = _json_encode, decode = _json_decode }
package.preload["cjson"] = function() return _jmod end
package.preload["json"] = function() return _jmod end

package.preload["vkeys"] = function()
    return { VK_RETURN = 0x0D, VK_ESCAPE = 0x1B, VK_SPACE = 0x20, VK_F1 = 0x70, VK_F2 = 0x71, VK_F3 = 0x72, VK_F4 = 0x73, VK_F5 = 0x74 }
end
package.preload["ffi"] = function()
    return { cdef = function() end, new = function(_, init) return { _val = init or "" } end, cast = function(_, v) return v end, string = function(p) return type(p) == "table" and tostring(p._val or "") or tostring(p or "") end, sizeof = function() return 4 end }
end
package.preload["memory"] = function()
    return { read = function() return 0 end, write = function() end, fill = function() end, tostring = function() return "" end, hex2bin = function(h) return h end, bin2hex = function(b) return b end }
end
package.preload["lfs"] = function()
    return { currentdir = getWorkingDirectory, mkdir = createDirectory, attributes = function(p) return doesFileExist(p) and { mode = "file" } or (doesDirectoryExist(p) and { mode = "directory" } or nil) end }
end
package.preload["mimgui"] = function()
    local m = setmetatable({}, { __index = imgui })
    m.new = { bool = function(v) return { [0] = v or false } end, int = function(v) return { [0] = v or 0 } end, float = function(v) return { [0] = v or 0.0 } end, char = setmetatable({}, { __index = function() return function(s) return { _val = s or "" } end end }) }
    m.StrCopy = function(dst, src) if type(dst) == "table" then dst._val = tostring(src or "") end end
    m.OnInitialize = function(fn) if type(fn) == "function" then fn() end end
    return m
end
)lua";

static void RegisterAllLuaAPI(lua_State* L, const std::string& filename, const std::string& fullPath) {
    luaL_openlibs(L);
    std::string base = GetBaseDir();
    luaL_dostring(L, ("package.path = package.path .. ';" + base + "/lib/?.lua;" + base + "/lib/?/init.lua'").c_str());

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
    lua_pushcfunction(L, l_imgui_Noop); lua_setfield(L, -2, "End");
    lua_pushcfunction(L, l_imgui_Noop); lua_setfield(L, -2, "Text");
    lua_pushcfunction(L, l_imgui_Noop); lua_setfield(L, -2, "TextWrapped");
    lua_pushcfunction(L, l_imgui_Button); lua_setfield(L, -2, "Button");
    lua_pushcfunction(L, l_imgui_Noop); lua_setfield(L, -2, "SameLine");
    lua_pushcfunction(L, l_imgui_Noop); lua_setfield(L, -2, "Separator");
    lua_pushcfunction(L, l_imgui_Noop); lua_setfield(L, -2, "OnFrame");
    lua_setglobal(L, "imgui");

    if (luaL_dostring(L, kMoonLoaderBootstrapLua) != LUA_OK) {
        LogConsole("[Bootstrap ERROR] " + std::string(lua_tostring(L, -1) ?: "unknown"));
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
// 11. SCRIPT LOADING, RELOADING & TICKING
// ============================================================================

static void UnloadSingleScript(LuaScriptInstance* inst) {
    if (!inst) return;
    for (auto it = g_ChatCommands.begin(); it != g_ChatCommands.end(); ) {
        if (it->second.L == inst->L) it = g_ChatCommands.erase(it);
        else ++it;
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

    if (code.size() >= 3 && (unsigned char)code[0] == 0xEF && (unsigned char)code[1] == 0xBB && (unsigned char)code[2] == 0xBF) {
        code.erase(0, 3);
    }

    lua_State* L = luaL_newstate();
    inst->L = L;
    RegisterAllLuaAPI(L, inst->filename, inst->fullPath);

    std::string chunkName = "@" + ShortenPathForUI(inst->fullPath);
    if (luaL_loadbuffer(L, code.c_str(), code.size(), chunkName.c_str()) != LUA_OK || lua_pcall(L, 0, 0, 0) != LUA_OK) {
        inst->hasError = true;
        inst->lastError = lua_tostring(L, -1) ?: "Lua error";
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
        inst->threads.push_back({co, ref, NowMs(), false, false});
    } else {
        lua_pop(L, 1);
    }

    LogConsole("[OK] Загружен скрипт: " + inst->filename);
}

static void ReloadAllScripts() {
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    EnsureDirectories();

    for (auto* s : g_Scripts) { UnloadSingleScript(s); delete s; }
    g_Scripts.clear();
    g_ChatCommands.clear();

    std::string scriptsDir = GetBaseDir() + "/scripts";
    NSArray* files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[NSString stringWithUTF8String:scriptsDir.c_str()] error:nil];

    int okCount = 0, errCount = 0;
    for (NSString* file in files) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"lua"]) continue;
        auto* inst = new LuaScriptInstance();
        inst->filename = [file UTF8String];
        inst->fullPath = scriptsDir + "/" + inst->filename;
        g_Scripts.push_back(inst);
        LoadSingleScript(inst);
        if (inst->hasError) errCount++; else okCount++;
    }

    NSString* bannerMsg = (errCount > 0)
        ? [NSString stringWithFormat:@"42Loader: Загружено %d | Ошибок: %d", okCount, errCount]
        : (okCount > 0
            ? [NSString stringWithFormat:@"42Loader: Загружено скриптов: %d (команд: %zu)", okCount, g_ChatCommands.size()]
            : @"42Loader: Активен (скриптов не найдено)");
    ShowStartupBanner(bannerMsg, errCount > 0);
    RefreshMenuContent();
}

static void TickScripts() {
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    uint64_t now = NowMs();

    // Keep overridden world time & weather locked against server sync
    ApplyWorldOverridesToEngine();

    for (auto* s : g_Scripts) {
        if (!s->enabled || !s->L || s->hasError) continue;

        for (size_t i = 0; i < s->threads.size(); ) {
            LuaCoroutine& t = s->threads[i];
            if (t.finished || t.suspended || now < t.wakeTimeMs) { i++; continue; }

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
                s->hasError = true;
                s->lastError = lua_tostring(t.co, -1) ?: "Coroutine error";
                LogConsole("[ERROR] " + s->lastError);
                luaL_unref(s->L, LUA_REGISTRYINDEX, t.ref);
                s->threads.erase(s->threads.begin() + i);
            }
        }
    }
}

// ============================================================================
// 12. UIKIT HANDLER IMPLEMENTATION & ENTRY POINT
// ============================================================================

@implementation LoaderUIHandler

+ (instancetype)shared {
    static LoaderUIHandler* inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ inst = [[LoaderUIHandler alloc] init]; });
    return inst;
}

- (void)onFloatingBtnTap:(UIButton*)sender {
    ToggleLoaderMenu();
}

- (void)onFloatingBtnPan:(UIPanGestureRecognizer*)pan {
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

- (void)onCloseMenu:(UIButton*)sender {
    if (g_MenuOpen) ToggleLoaderMenu();
}

- (void)onTabChanged:(UISegmentedControl*)seg {
    g_SelectedTab = static_cast<int>(seg.selectedSegmentIndex);
    RefreshMenuContent();
}

- (void)onActionBtnTap:(UIButton*)sender {
    if (g_SelectedTab == 0) {
        ReloadAllScripts();
    } else if (g_SelectedTab == 1) {
        if (g_MenuCmdField.text.length > 0) {
            std::string cmd([g_MenuCmdField.text UTF8String]);
            g_MenuCmdField.text = @"";
            [g_MenuCmdField resignFirstResponder];
            TryExecuteChatCommand(cmd, "MenuInput");
            RefreshMenuContent();
        }
    } else if (g_SelectedTab == 2) {
        std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
        g_ConsoleLogs.clear();
        RefreshMenuContent();
    }
}

- (BOOL)textFieldShouldReturn:(UITextField*)textField {
    if (textField == g_MenuCmdField && textField.text.length > 0) {
        std::string cmd([textField.text UTF8String]);
        textField.text = @"";
        [textField resignFirstResponder];
        TryExecuteChatCommand(cmd, "MenuInput");
        RefreshMenuContent();
        return NO;
    }
    return YES;
}

- (void)onScriptSwitchChanged:(UISwitch*)sw {
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    size_t idx = static_cast<size_t>(sw.tag);
    if (idx < g_Scripts.size()) {
        g_Scripts[idx]->enabled = sw.on;
        if (sw.on) LoadSingleScript(g_Scripts[idx]);
        else UnloadSingleScript(g_Scripts[idx]);
    }
    RefreshMenuContent();
}

- (void)onScriptReloadTap:(UIButton*)btn {
    std::lock_guard<std::recursive_mutex> lock(g_EngineMutex);
    size_t idx = static_cast<size_t>(btn.tag);
    if (idx < g_Scripts.size()) {
        g_Scripts[idx]->enabled = true;
        LoadSingleScript(g_Scripts[idx]);
    }
    RefreshMenuContent();
}

- (void)onDisplayLink:(CADisplayLink*)link {
    TickScripts();

    uint64_t now = NowMs();
    if (now - g_LastUiRefreshMs > 500) {
        g_LastUiRefreshMs = now;
        EnsureFloatingMenuButton();
        if (g_HudChatOverlay) {
            RefreshHudChatOverlay();
        }
        if (g_MenuOpen && g_SelectedTab == 2) {
            RefreshMenuContent();
        }
    }
}

@end

__attribute__((constructor))
static void LoaderEntry() {
    EnsureDirectories();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ScanMachOSymbols();
        InstallSafeUIKitChatHooks();
        EnsureFloatingMenuButton();
        ReloadAllScripts();

        g_DisplayLink = [CADisplayLink displayLinkWithTarget:[LoaderUIHandler shared] selector:@selector(onDisplayLink:)];
        [g_DisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

        LogConsole("Arizona 42Loader готов");
    });
}
