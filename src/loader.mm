#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>

extern "C" {
    #include "lua.h"
    #include "lauxlib.h"
    #include "lualib.h"
}

static lua_State* g_L = nullptr;
static bool g_LoaderWelcomeShown = false;

bool IsSampReady() {
    void** pChatWindow = (void**)dlsym(RTLD_DEFAULT, "pChatWindow");
    void** pNetGame = (void**)dlsym(RTLD_DEFAULT, "pNetGame");
    return (pChatWindow && *pChatWindow && pNetGame && *pNetGame);
}

void AddLocalChatMessage(const char* text, uint32_t color) {
    void** pChatWindow = (void**)dlsym(RTLD_DEFAULT, "pChatWindow");
    typedef void (*AddMsgFn)(void* thisPtr, uint32_t color, const char* text);
    AddMsgFn addMsg = (AddMsgFn)dlsym(RTLD_DEFAULT, "_ZN5CChat10AddMessageEjPKc");
    if (pChatWindow && *pChatWindow && addMsg) {
        addMsg(*pChatWindow, color, text);
    }
}

void SendServerChatMessage(const char* text) {
    void** pNetGame = (void**)dlsym(RTLD_DEFAULT, "pNetGame");
    typedef void (*SendChatFn)(void* thisPtr, const char* text);
    SendChatFn sendChat = (SendChatFn)dlsym(RTLD_DEFAULT, "_ZN8CNetGame8SendChatEPKc");
    if (pNetGame && *pNetGame && sendChat) {
        sendChat(*pNetGame, text);
    }
}

int lua_isSampLoaded(lua_State* L) {
    lua_pushboolean(L, IsSampReady());
    return 1;
}

int lua_sampAddChatMessage(lua_State* L) {
    const char* text = luaL_checkstring(L, 1);
    uint32_t color = (uint32_t)luaL_optinteger(L, 2, 0xFFFFFFFF);
    AddLocalChatMessage(text, color);
    return 0;
}

int lua_sampSendChat(lua_State* L) {
    const char* text = luaL_checkstring(L, 1);
    SendServerChatMessage(text);
    return 0;
}

void ShowLauncherToast(NSString *message) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) {
                        window = w;
                        break;
                    }
                }
            }
        }
        if (!window) return;

        CGFloat width = 380.0;
        UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(window.bounds.size.width / 2 - width / 2, -50, width, 40)];
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        toast.textColor = [UIColor whiteColor];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.font = [UIFont boldSystemFontOfSize:13];
        toast.text = message;
        toast.layer.cornerRadius = 12;
        toast.clipsToBounds = YES;
        toast.layer.borderWidth = 1.0;
        toast.layer.borderColor = [UIColor colorWithRed:0.61 green:0.35 blue:0.71 alpha:1.0].CGColor;
        [window addSubview:toast];

        [UIView animateWithDuration:0.4 animations:^{
            toast.frame = CGRectMake(window.bounds.size.width / 2 - width / 2, 20, width, 40);
        } completion:^(BOOL finished) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.4 animations:^{
                    toast.alpha = 0;
                } completion:^(BOOL finished) {
                    [toast removeFromSuperview];
                }];
            });
        }];
    });
}

NSString* EnsureLoaderDirectory() {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docsDir = [paths firstObject];
    NSString *loaderDir = [docsDir stringByAppendingPathComponent:@"arizonaloader"];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:loaderDir]) {
        [fm createDirectoryAtPath:loaderDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return loaderDir;
}

void StartLuaEngine() {
    NSString *dirPath = EnsureLoaderDirectory();
    
    g_L = luaL_newstate();
    luaL_openlibs(g_L);
    
    lua_register(g_L, "isSampLoaded", lua_isSampLoaded);
    lua_register(g_L, "sampAddChatMessage", lua_sampAddChatMessage);
    lua_register(g_L, "sampSendChat", lua_sampSendChat);
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:dirPath error:nil];
    int loadedCount = 0;
    
    for (NSString *file in files) {
        if ([[file pathExtension] isEqualToString:@"lua"]) {
            NSString *fullPath = [dirPath stringByAppendingPathComponent:file];
            if (luaL_dofile(g_L, [fullPath UTF8String]) == LUA_OK) {
                loadedCount++;
            } else {
                lua_pop(g_L, 1);
            }
        }
    }
    
    bool hasChatSym = (dlsym(RTLD_DEFAULT, "_ZN5CChat10AddMessageEjPKc") != nullptr);
    NSString *toastText = [NSString stringWithFormat:@"42loader: загружено %d скриптов | Chat: %@",
                           loadedCount, hasChatSym ? @"OK" : @"NO SYM"];
    ShowLauncherToast(toastText);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
            if (!g_LoaderWelcomeShown && IsSampReady()) {
                AddLocalChatMessage("{9B59B6}[42loader] {FFFFFF}42loader loaded. Have fun! By {9B59B6}bloggervat {FFFFFF}t.me/bedrockarzrp", 0xFFFFFFFF);
                g_LoaderWelcomeShown = true;
            }
            
            if (g_L) {
                lua_getglobal(g_L, "onUpdate");
                if (lua_isfunction(g_L, -1)) {
                    if (lua_pcall(g_L, 0, 0, 0) != LUA_OK) {
                        lua_pop(g_L, 1);
                    }
                } else {
                    lua_pop(g_L, 1);
                }
            }
        }];
    });
}

__attribute__((constructor))
static void OnDylibLoaded() {
    StartLuaEngine();
}
