#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern "C" {
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
}

static lua_State *g_L = nullptr;
static NSInteger g_loadedCount = 0;
static bool g_bannerShown = false;

static NSString *GetLoaderDirectory(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docsDir = paths.firstObject;
    NSString *loaderDir = [docsDir stringByAppendingPathComponent:@"lua_loader"];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:loaderDir]) {
        [fm createDirectoryAtPath:loaderDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return loaderDir;
}

static void WriteLoaderLog(NSString *message) {
    NSString *logPath = [GetLoaderDirectory() stringByAppendingPathComponent:@"loader.log"];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!handle) {
        [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    }
}

static int lua_custom_print(lua_State *L) {
    int nargs = lua_gettop(L);
    NSMutableArray *parts = [NSMutableArray array];
    for (int i = 1; i <= nargs; i++) {
        const char *str = luaL_tolstring(L, i, nullptr);
        if (str) {
            [parts addObject:[NSString stringWithUTF8String:str]];
        }
        lua_pop(L, 1);
    }
    WriteLoaderLog([parts componentsJoinedByString:@"\t"]);
    return 0;
}

static void InitAndLoadLuaScripts(void) {
    NSString *loaderDir = GetLoaderDirectory();
    NSString *logPath = [loaderDir stringByAppendingPathComponent:@"loader.log"];
    [@"" writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

    g_L = luaL_newstate();
    if (!g_L) return;
    luaL_openlibs(g_L);

    lua_pushcfunction(g_L, lua_custom_print);
    lua_setglobal(g_L, "print");

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:loaderDir error:nil];
    
    NSInteger count = 0;
    for (NSString *file in files) {
        if ([[file.pathExtension lowercaseString] isEqualToString:@"lua"]) {
            NSString *fullPath = [loaderDir stringByAppendingPathComponent:file];
            if (luaL_dofile(g_L, [fullPath UTF8String]) == LUA_OK) {
                count++;
                WriteLoaderLog([NSString stringWithFormat:@"Loaded: %@", file]);
            } else {
                const char *err = lua_tostring(g_L, -1);
                WriteLoaderLog([NSString stringWithFormat:@"Error in %@: %s", file, err ? err : "unknown"]);
                lua_pop(g_L, 1);
            }
        }
    }
    g_loadedCount = count;
}

static UIWindow *FindKeyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive &&
            [scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) {
                    return window;
                }
            }
        }
    }
    return nil;
}

static void ShowStartupToast(void) {
    if (g_bannerShown) return;
    UIWindow *window = FindKeyWindow();
    if (!window) return;
    g_bannerShown = true;

    NSString *text = [NSString stringWithFormat:@"Загружено: %ld скриптов. Приятной игры!", (long)g_loadedCount];

    UILabel *banner = [[UILabel alloc] init];
    banner.text = text;
    banner.textColor = [UIColor whiteColor];
    banner.backgroundColor = [[UIColor colorWithRed:0.10 green:0.10 blue:0.13 alpha:0.92] colorWithAlphaComponent:0.92];
    banner.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    banner.textAlignment = NSTextAlignmentCenter;
    banner.layer.cornerRadius = 12.0;
    banner.layer.masksToBounds = YES;
    banner.layer.borderWidth = 1.0;
    banner.layer.borderColor = [UIColor colorWithRed:0.55 green:0.35 blue:0.95 alpha:0.75].CGColor;
    banner.alpha = 0.0;

    CGFloat maxWidth = MIN(window.bounds.size.width - 40.0, 380.0);
    CGFloat height = 40.0;
    CGFloat topInset = window.safeAreaInsets.top > 0 ? window.safeAreaInsets.top + 8.0 : 20.0;
    banner.frame = CGRectMake((window.bounds.size.width - maxWidth) / 2.0, topInset - 20.0, maxWidth, height);

    [window addSubview:banner];

    [UIView animateWithDuration:0.35 animations:^{
        banner.alpha = 1.0;
        banner.frame = CGRectMake((window.bounds.size.width - maxWidth) / 2.0, topInset, maxWidth, height);
    } completion:^(BOOL finished) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.35 animations:^{
                banner.alpha = 0.0;
                banner.frame = CGRectMake((window.bounds.size.width - maxWidth) / 2.0, topInset - 20.0, maxWidth, height);
            } completion:^(BOOL finished) {
                [banner removeFromSuperview];
            }];
        });
    }];
}

__attribute__((constructor))
static void LoaderEntryPoint(void) {
    @autoreleasepool {
        InitAndLoadLuaScripts();

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ShowStartupToast();
            });
        }];
    }
}