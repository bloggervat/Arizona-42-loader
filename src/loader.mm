#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <string.h>
#include <vector>

extern "C" {
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
}

typedef const char* (*GetStringUTFChars_t)(void* env, void* str, uint8_t* isCopy);
typedef void (*ReleaseStringUTFChars_t)(void* env, void* str, const char* chars);
typedef void (*OnInputEnd_t)(void* env, void* thiz, void* text);

static std::vector<lua_State*> g_luaStates;
static NSString* g_loaderDir = nil;
static NSTimeInterval g_agLoadedAt = 0;
static bool g_welcomeShown = false;

static void WriteLog(NSString* line) {
    if (!g_loaderDir) return;
    NSString* logPath = [g_loaderDir stringByAppendingPathComponent:@"loader.log"];
    NSString* entry = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], line];
    NSData* data = [entry dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:data];
        [fh closeFile];
    } else {
        [data writeToFile:logPath atomically:YES];
    }
}

static void ShowToastBanner(NSString* text) {
    if (!text || text.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow* targetWindow = nil;
        for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene* ws = (UIWindowScene*)scene;
                for (UIWindow* w in ws.windows) {
                    if (w.isKeyWindow) {
                        targetWindow = w;
                        break;
                    }
                }
                if (!targetWindow && ws.windows.count > 0) {
                    targetWindow = ws.windows.firstObject;
                }
            }
            if (targetWindow) break;
        }
        if (!targetWindow) return;

        UILabel* banner = [[UILabel alloc] init];
        banner.text = text;
        banner.textColor = [UIColor whiteColor];
        banner.backgroundColor = [[UIColor colorWithRed:0.12 green:0.08 blue:0.20 alpha:0.92] colorWithAlphaComponent:0.92];
        banner.font = [UIFont boldSystemFontOfSize:13.0];
        banner.textAlignment = NSTextAlignmentCenter;
        banner.numberOfLines = 0;
        banner.layer.cornerRadius = 10.0;
        banner.layer.masksToBounds = YES;
        banner.layer.borderWidth = 1.0;
        banner.layer.borderColor = [UIColor colorWithRed:0.55 green:0.30 blue:0.95 alpha:0.85].CGColor;

        CGFloat width = MIN(targetWindow.bounds.size.width - 32.0, 520.0);
        CGSize fit = [banner sizeThatFits:CGSizeMake(width - 24.0, 120.0)];
        CGFloat height = fit.height + 16.0;
        CGFloat topInset = targetWindow.safeAreaInsets.top + 8.0;
        banner.frame = CGRectMake((targetWindow.bounds.size.width - width) * 0.5, topInset, width, height);
        banner.alpha = 0.0;

        [targetWindow addSubview:banner];
        [UIView animateWithDuration:0.25 animations:^{
            banner.alpha = 1.0;
        } completion:^(BOOL finished) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.35 animations:^{
                    banner.alpha = 0.0;
                } completion:^(BOOL done) {
                    [banner removeFromSuperview];
                }];
            });
        }];
    });
}

static uintptr_t DummyJniStub(void) { return 0; }

static const char* FakeGetStringUTFChars(void* env, void* str, uint8_t* isCopy) {
    if (isCopy) *isCopy = 0;
    return (const char*)str;
}

static void FakeReleaseStringUTFChars(void* env, void* str, const char* chars) {}

static void* GetSafeJniEnv() {
    static void* vtable[256];
    static void* tablePtr = nullptr;
    static void** envPtr = nullptr;
    if (!envPtr) {
        for (int i = 0; i < 256; i++) {
            vtable[i] = (void*)&DummyJniStub;
        }
        vtable[169] = (void*)&FakeGetStringUTFChars;      // 0x548: GetStringUTFChars
        vtable[170] = (void*)&FakeReleaseStringUTFChars;  // 0x550: ReleaseStringUTFChars
        tablePtr = (void*)vtable;
        envPtr = &tablePtr;
    }
    return (void*)envPtr;
}

static void* GetAgClientHandle() {
    static void* handle = nullptr;
    if (handle) return handle;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char* name = _dyld_get_image_name(i);
        if (name && strstr(name, "libag-client.dylib") != nullptr) {
            handle = dlopen(name, RTLD_NOLOAD);
            if (!handle) handle = RTLD_DEFAULT;
            if (g_agLoadedAt == 0) {
                g_agLoadedAt = [[NSDate date] timeIntervalSince1970];
                WriteLog(@"libag-client.dylib detected in memory");
            }
            break;
        }
    }
    return handle;
}

static bool IsSampReady() {
    if (!GetAgClientHandle()) return false;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    return (now - g_agLoadedAt) >= 8.0;
}

static void NativeSendChat(const char* utf8Text) {
    if (!utf8Text || !utf8Text[0]) return;
    static OnInputEnd_t fnOnInputEnd = nullptr;
    if (!fnOnInputEnd) {
        void* h = GetAgClientHandle();
        if (h) {
            fnOnInputEnd = (OnInputEnd_t)dlsym(h, "Java_com_arizona_game_GTASA_OnInputEnd");
        }
        if (!fnOnInputEnd) {
            fnOnInputEnd = (OnInputEnd_t)dlsym(RTLD_DEFAULT, "Java_com_arizona_game_GTASA_OnInputEnd");
        }
    }
    if (!fnOnInputEnd) {
        WriteLog(@"OnInputEnd symbol not found");
        return;
    }

    NSString* copyStr = [NSString stringWithUTF8String:utf8Text];
    WriteLog([NSString stringWithFormat:@"sampSendChat: %@", copyStr]);
    dispatch_async(dispatch_get_main_queue(), ^{
        fnOnInputEnd(GetSafeJniEnv(), nullptr, (void*)[copyStr UTF8String]);
    });
}

static int l_isSampLoaded(lua_State* L) {
    lua_pushboolean(L, IsSampReady() ? 1 : 0);
    return 1;
}

static int l_sampAddChatMessage(lua_State* L) {
    const char* msg = luaL_checkstring(L, 1);
    NSString* text = [NSString stringWithUTF8String:msg];
    WriteLog([NSString stringWithFormat:@"sampAddChatMessage: %@", text]);
    ShowToastBanner(text);
    return 0;
}

static int l_sampSendChat(lua_State* L) {
    const char* msg = luaL_checkstring(L, 1);
    NativeSendChat(msg);
    return 0;
}

static void LoadLuaScripts() {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSArray<NSString*>* files = [fm contentsOfDirectoryAtPath:g_loaderDir error:nil];
    int loadedCount = 0;

    for (NSString* file in files) {
        if (![[file.pathExtension lowercaseString] isEqualToString:@"lua"]) continue;
        NSString* fullPath = [g_loaderDir stringByAppendingPathComponent:file];

        lua_State* L = luaL_newstate();
        luaL_openlibs(L);

        lua_register(L, "isSampLoaded", l_isSampLoaded);
        lua_register(L, "sampAddChatMessage", l_sampAddChatMessage);
        lua_register(L, "sampSendChat", l_sampSendChat);

        if (luaL_dofile(L, [fullPath UTF8String]) != LUA_OK) {
            const char* err = lua_tostring(L, -1);
            WriteLog([NSString stringWithFormat:@"Lua error in %@: %s", file, err ? err : "unknown"]);
            lua_close(L);
            continue;
        }

        g_luaStates.push_back(L);
        loadedCount++;
        WriteLog([NSString stringWithFormat:@"Loaded script: %@", file]);
    }

    NSString* statusMsg = [NSString stringWithFormat:@"42loader loaded. Have fun! By bloggervat t.me/bedrockarzrp\nЗагружено скриптов: %d", loadedCount];
    WriteLog(statusMsg);
    ShowToastBanner(statusMsg);
}

static void TickLuaScripts() {
    if (!g_welcomeShown && [UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        g_welcomeShown = true;
        LoadLuaScripts();
    }

    GetAgClientHandle();

    for (lua_State* L : g_luaStates) {
        lua_getglobal(L, "onUpdate");
        if (lua_isfunction(L, -1)) {
            if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                const char* err = lua_tostring(L, -1);
                WriteLog([NSString stringWithFormat:@"onUpdate error: %s", err ? err : "unknown"]);
                lua_pop(L, 1);
            }
        } else {
            lua_pop(L, 1);
        }
    }
}

__attribute__((constructor))
static void Init42Loader() {
    @autoreleasepool {
        NSArray<NSString*>* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString* docsDir = paths.firstObject;
        g_loaderDir = [docsDir stringByAppendingPathComponent:@"arizonaloader"];

        NSFileManager* fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:g_loaderDir]) {
            [fm createDirectoryAtPath:g_loaderDir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        WriteLog(@"42loader dylib constructor initialized");

        dispatch_async(dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer* _Nonnull timer) {
                TickLuaScripts();
            }];
        });
    }
}
