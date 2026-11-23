#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include "lua.hpp"

static lua_State* g_L = nullptr;
static bool g_LoaderWelcomeShown = false;

// Локальный вывод в чат (видишь только ты)
void AddLocalChatMessage(const char* text, uint32_t color) {
    void** pChatWindow = (void**)dlsym(RTLD_DEFAULT, "pChatWindow");
    typedef void (*AddMsgFn)(void* thisPtr, uint32_t color, const char* text);
    AddMsgFn addMsg = (AddMsgFn)dlsym(RTLD_DEFAULT, "_ZN5CChat10AddMessageEjPKc");
    
    if (pChatWindow && *pChatWindow && addMsg) {
        addMsg(*pChatWindow, color, text);
    }
}

// Отправка сообщения в общий чат сервера от лица персонажа
void SendServerChatMessage(const char* text) {
    void** pNetGame = (void**)dlsym(RTLD_DEFAULT, "pNetGame");
    typedef void (*SendChatFn)(void* thisPtr, const char* text);
    SendChatFn sendChat = (SendChatFn)dlsym(RTLD_DEFAULT, "_ZN8CNetGame8SendChatEPKc");
    
    if (pNetGame && *pNetGame && sendChat) {
        sendChat(*pNetGame, text);
    }
}

bool IsSampReady() {
    void** pChatWindow = (void**)dlsym(RTLD_DEFAULT, "pChatWindow");
    void** pNetGame = (void**)dlsym(RTLD_DEFAULT, "pNetGame");
    return (pChatWindow && *pChatWindow && pNetGame && *pNetGame);
}

// API для Lua-скриптов
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

// Создание папки Documents/arizonaloader
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
    
    // Подгружаем все .lua скрипты из папки arizonaloader
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:dirPath error:nil];
    
    for (NSString *file in files) {
        if ([[file pathExtension] isEqualToString:@"lua"]) {
            NSString *fullPath = [dirPath stringByAppendingPathComponent:file];
            if (luaL_dofile(g_L, [fullPath UTF8String]) != LUA_OK) {
                NSLog(@"[42loader] Lua Error (%@): %s", file, lua_tostring(g_L, -1));
                lua_pop(g_L, 1);
            }
        }
    }
    
    // Главный тик раз в 0.5 сек
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
            // Системное сообщение самого лоадера (не зависит от скриптов)
            if (!g_LoaderWelcomeShown && IsSampReady()) {
                AddLocalChatMessage("{9B59B6}[42loader] {FFFFFF}42loader loaded. Have fun! By {9B59B6}bloggervat {FFFFFF}t.me/bedrockarzrp", 0xFFFFFFFF);
                g_LoaderWelcomeShown = true;
            }
            
            // Тик для загруженных скриптов
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
