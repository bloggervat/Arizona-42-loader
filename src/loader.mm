#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <string.h>
#import <stdlib.h>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}

#if LUA_VERSION_NUM >= 504
#define AZ_LUA_RESUME(co, from, nargs, nres) lua_resume((co), (from), (nargs), (nres))
#else
#define AZ_LUA_RESUME(co, from, nargs, nres) lua_resume((co), (from), (nargs))
#endif

#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
typedef struct nlist_64 nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct section section_t;
typedef struct nlist nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif

struct Rebinding {
    const char *name;
    void *replacement;
    void **replaced;
};

static NSMutableArray<NSValue *> *gRebindings = nil;

static void perform_rebinding_with_section(section_t *data_sect, intptr_t slide, nlist_t *symtab, char *strtab, uint32_t *indirect_symtab) {
    uint32_t *indirect_symbol_indices = indirect_symtab + data_sect->reserved1;
    void **indirect_symbol_bindings = (void **)((uintptr_t)slide + data_sect->addr);
    size_t count = data_sect->size / sizeof(void *);
    for (size_t i = 0; i < count; i++) {
        uint32_t symtab_index = indirect_symbol_indices[i];
        if (symtab_index == INDIRECT_SYMBOL_ABS || symtab_index == INDIRECT_SYMBOL_LOCAL ||
            symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
            continue;
        }
        uint32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
        char *symbol_name = strtab + strtab_offset;
        if (strnlen(symbol_name, 2) < 2) continue;
        for (NSValue *val in gRebindings) {
            struct Rebinding rb;
            [val getValue:&rb];
            if (strcmp(&symbol_name[1], rb.name) == 0) {
                if (rb.replaced != NULL && *rb.replaced == NULL) {
                    *rb.replaced = indirect_symbol_bindings[i];
                }
                indirect_symbol_bindings[i] = rb.replacement;
                break;
            }
        }
    }
}

static void rebind_symbols_for_image(const struct mach_header *header, intptr_t slide) {
    if (!gRebindings || gRebindings.count == 0) return;
    Dl_info info;
    if (dladdr(header, &info) == 0) return;

    segment_command_t *cur_seg_cmd;
    segment_command_t *linkedit_segment = NULL;
    struct symtab_command *symtab_cmd = NULL;
    struct dysymtab_command *dysymtab_cmd = NULL;

    uintptr_t cur = (uintptr_t)header + sizeof(mach_header_t);
    for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
        cur_seg_cmd = (segment_command_t *)cur;
        if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
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
    nlist_t *symtab = (nlist_t *)(linkedit_base + symtab_cmd->symoff);
    char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
    uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

    cur = (uintptr_t)header + sizeof(mach_header_t);
    for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
        cur_seg_cmd = (segment_command_t *)cur;
        if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
            if (strcmp(cur_seg_cmd->segname, SEG_DATA) != 0 &&
                strcmp(cur_seg_cmd->segname, "__DATA_CONST") != 0) {
                continue;
            }
            for (uint j = 0; j < cur_seg_cmd->nsects; j++) {
                section_t *sect = (section_t *)(cur + sizeof(segment_command_t)) + j;
                if ((sect->flags & SECTION_TYPE) == S_LAZY_SYMBOL_POINTERS ||
                    (sect->flags & SECTION_TYPE) == S_NON_LAZY_SYMBOL_POINTERS) {
                    perform_rebinding_with_section(sect, slide, symtab, strtab, indirect_symtab);
                }
            }
        }
    }
}

static void register_rebinding(const char *name, void *replacement, void **replaced) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gRebindings = [NSMutableArray new];
        _dyld_register_func_for_add_image(rebind_symbols_for_image);
    });
    struct Rebinding rb = {name, replacement, replaced};
    [gRebindings addObject:[NSValue valueWithBytes:&rb objCType:@encode(struct Rebinding)]];
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++) {
        rebind_symbols_for_image(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
    }
}

static NSString *StripSampColors(NSString *input) {
    if (!input || input.length == 0) return @"";
    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"\\{[0-9A-Fa-f]{6}\\}" options:0 error:nil];
    });
    return [regex stringByReplacingMatchesInString:input options:0 range:NSMakeRange(0, input.length) withTemplate:@""];
}

@interface LuaCoroutineItem : NSObject
@property (nonatomic, assign) lua_State *co;
@property (nonatomic, assign) int ref;
@property (nonatomic, assign) NSTimeInterval wakeTime;
@property (nonatomic, copy) NSString *scriptName;
@end

@implementation LuaCoroutineItem
@end

@interface LuaCommandItem : NSObject
@property (nonatomic, copy) NSString *cmd;
@property (nonatomic, assign) int callbackRef;
@property (nonatomic, copy) NSString *scriptName;
@property (nonatomic, assign) BOOL overrideServer;
@end

@implementation LuaCommandItem
@end

@interface PendingCommandItem : NSObject
@property (nonatomic, copy) NSString *cmd;
@property (nonatomic, copy) NSString *args;
@property (nonatomic, assign) NSTimeInterval sentTime;
@end

@implementation PendingCommandItem
@end

@interface LuaEventItem : NSObject
@property (nonatomic, copy) NSString *eventName;
@property (nonatomic, assign) int callbackRef;
@property (nonatomic, copy) NSString *scriptName;
@end

@implementation LuaEventItem
@end

@interface LoaderSettingsVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@end

@interface LoaderEngine : NSObject <UNUserNotificationCenterDelegate>
@property (nonatomic, assign) lua_State *L;
@property (nonatomic, copy) NSString *baseDir;
@property (nonatomic, copy) NSString *configDir;
@property (nonatomic, copy) NSString *statePath;
@property (nonatomic, copy) NSString *serverCmdCachePath;
@property (nonatomic, assign) BOOL gameStarted;
@property (nonatomic, assign) BOOL inGameSession;
@property (nonatomic, copy) NSString *currentLoadingScript;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *enabledScripts;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *scriptStatuses;
@property (nonatomic, strong) NSMutableArray<NSString *> *discoveredScripts;
@property (nonatomic, strong) NSMutableArray<LuaCoroutineItem *> *coroutines;
@property (nonatomic, strong) NSMutableDictionary<NSString *, LuaCommandItem *> *commands;
@property (nonatomic, strong) NSMutableArray<LuaEventItem *> *eventHooks;

@property (nonatomic, strong) NSMutableSet<NSString *> *knownServerCommands;
@property (nonatomic, strong) NSMutableSet<NSString *> *confirmedLocalCommands;
@property (nonatomic, strong) NSMutableArray<PendingCommandItem *> *pendingCommands;

@property (nonatomic, strong) NSTimer *tickTimer;
@property (nonatomic, assign) NSTimeInterval lastTick;

@property (nonatomic, copy) NSString *accentHex;
@property (nonatomic, assign) CGFloat uiAlpha;
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign) BOOL showFloatingBtn;
@property (nonatomic, assign) BOOL showStartupBanner;

@property (nonatomic, strong) UIView *statusBanner;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, weak) LoaderSettingsVC *settingsVC;

+ (instancetype)shared;
- (void)bootStageOne;
- (void)triggerStageTwoIfNeeded;
- (void)scanScriptsOnly;
- (void)loadAllEnabledScripts;
- (void)reloadSingleScript:(NSString *)scriptName;
- (void)unloadScriptResources:(NSString *)scriptName;
- (void)setScript:(NSString *)scriptName enabled:(BOOL)enabled;
- (void)saveState;
- (void)registerKnownServerCommand:(NSString *)rawCmd persist:(BOOL)persist;
- (void)resetServerCommandsCache;
- (BOOL)handleOutgoingInput:(NSString *)text;
- (void)executeLuaCommand:(LuaCommandItem *)item args:(NSString *)args;
- (BOOL)dispatchServerMessage:(uint32_t)color text:(NSString *)text outColor:(uint32_t *)outColor outText:(NSString **)outText;
- (BOOL)dispatchShowDialog:(int)dialogId style:(int)style title:(NSString *)title btn1:(NSString *)btn1 btn2:(NSString *)btn2 text:(NSString *)text;
- (void)showSettingsWindow;
- (void)applyThemeToOverlay;
- (UIColor *)currentAccentColor;
@end

static void (*orig_AddChatMessage)(uint32_t, const char *) = NULL;
static void (*orig_ShowDialog)(int, int, const char *, const char *, const char *, const char *) = NULL;
static void (*orig_AddClientCommand)(const char *, void *) = NULL;

static void hooked_AddClientCommand(const char *cmd, void *handler) {
    if (cmd) {
        NSString *nsCmd = [NSString stringWithUTF8String:cmd];
        if (nsCmd.length > 0) {
            [[LoaderEngine shared] registerKnownServerCommand:nsCmd persist:NO];
        }
    }
    if (orig_AddClientCommand) {
        orig_AddClientCommand(cmd, handler);
    }
}

static void hooked_AddChatMessage(uint32_t color, const char *text) {
    if (!text) return;
    NSString *nsText = [NSString stringWithUTF8String:text] ?: @"";
    uint32_t newColor = color;
    NSString *newText = nsText;
    BOOL allow = [[LoaderEngine shared] dispatchServerMessage:color text:nsText outColor:&newColor outText:&newText];
    if (!allow) return;
    if (orig_AddChatMessage) {
        orig_AddChatMessage(newColor, [newText UTF8String]);
    }
}

static void hooked_ShowDialog(int dialogId, int style, const char *title, const char *btn1, const char *btn2, const char *text) {
    NSString *nsTitle = title ? ([NSString stringWithUTF8String:title] ?: @"") : @"";
    NSString *nsB1 = btn1 ? ([NSString stringWithUTF8String:btn1] ?: @"") : @"";
    NSString *nsB2 = btn2 ? ([NSString stringWithUTF8String:btn2] ?: @"") : @"";
    NSString *nsText = text ? ([NSString stringWithUTF8String:text] ?: @"") : @"";
    BOOL allow = [[LoaderEngine shared] dispatchShowDialog:dialogId style:style title:nsTitle btn1:nsB1 btn2:nsB2 text:nsText];
    if (!allow) return;
    if (orig_ShowDialog) {
        orig_ShowDialog(dialogId, style, title, btn1, btn2, text);
    }
}

static id NSObjectFromLua(lua_State *L, int idx) {
    idx = lua_absindex(L, idx);
    int t = lua_type(L, idx);
    if (t == LUA_TNIL || t == LUA_TNONE) return [NSNull null];
    if (t == LUA_TBOOLEAN) return @(lua_toboolean(L, idx) ? YES : NO);
    if (t == LUA_TNUMBER) {
        if (lua_isinteger(L, idx)) return @(lua_tointeger(L, idx));
        return @(lua_tonumber(L, idx));
    }
    if (t == LUA_TSTRING) {
        const char *s = lua_tostring(L, idx);
        return [NSString stringWithUTF8String:s] ?: @"";
    }
    if (t == LUA_TTABLE) {
        lua_Integer len = luaL_len(L, idx);
        BOOL isArray = (len > 0);
        lua_Integer count = 0;
        lua_pushnil(L);
        while (lua_next(L, idx) != 0) {
            count++;
            if (!lua_isinteger(L, -2)) {
                isArray = NO;
            } else {
                lua_Integer k = lua_tointeger(L, -2);
                if (k < 1 || k > len) isArray = NO;
            }
            lua_pop(L, 1);
        }
        if (count == 0) return @{};
        if (isArray && count == len) {
            NSMutableArray *arr = [NSMutableArray arrayWithCapacity:(NSUInteger)len];
            for (lua_Integer i = 1; i <= len; i++) {
                lua_geti(L, idx, i);
                [arr addObject:NSObjectFromLua(L, -1)];
                lua_pop(L, 1);
            }
            return arr;
        } else {
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            lua_pushnil(L);
            while (lua_next(L, idx) != 0) {
                NSString *key = nil;
                if (lua_type(L, -2) == LUA_TSTRING) {
                    key = [NSString stringWithUTF8String:lua_tostring(L, -2)];
                } else if (lua_isinteger(L, -2)) {
                    key = [NSString stringWithFormat:@"%lld", lua_tointeger(L, -2)];
                } else if (lua_type(L, -2) == LUA_TNUMBER) {
                    key = [NSString stringWithFormat:@"%g", lua_tonumber(L, -2)];
                }
                if (key) {
                    dict[key] = NSObjectFromLua(L, -1);
                }
                lua_pop(L, 1);
            }
            return dict;
        }
    }
    return [NSNull null];
}

static void PushNSObjectToLua(lua_State *L, id obj) {
    if (!obj || obj == [NSNull null]) {
        lua_pushnil(L);
    } else if ([obj isKindOfClass:[NSNumber class]]) {
        NSNumber *num = (NSNumber *)obj;
        if (strcmp([num objCType], @encode(BOOL)) == 0 || strcmp([num objCType], "c") == 0) {
            lua_pushboolean(L, [num boolValue]);
        } else if (CFNumberIsFloatType((CFNumberRef)num)) {
            lua_pushnumber(L, [num doubleValue]);
        } else {
            lua_pushinteger(L, [num longLongValue]);
        }
    } else if ([obj isKindOfClass:[NSString class]]) {
        lua_pushstring(L, [(NSString *)obj UTF8String]);
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)obj;
        lua_createtable(L, (int)arr.count, 0);
        for (NSUInteger i = 0; i < arr.count; i++) {
            PushNSObjectToLua(L, arr[i]);
            lua_seti(L, -2, (lua_Integer)(i + 1));
        }
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        lua_createtable(L, 0, (int)dict.count);
        for (id key in dict) {
            NSString *kStr = [key description];
            lua_pushstring(L, [kStr UTF8String]);
            PushNSObjectToLua(L, dict[key]);
            lua_settable(L, -3);
        }
    } else {
        lua_pushstring(L, [[obj description] UTF8String]);
    }
}

static int l_json_encode(lua_State *L) {
    luaL_checkany(L, 1);
    id obj = NSObjectFromLua(L, 1);
    if (![NSJSONSerialization isValidJSONObject:obj]) {
        return luaL_error(L, "invalid table for json.encode");
    }
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&err];
    if (!data || err) {
        return luaL_error(L, "json.encode failed");
    }
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    lua_pushstring(L, [str UTF8String]);
    return 1;
}

static int l_json_decode(lua_State *L) {
    size_t len = 0;
    const char *s = luaL_checklstring(L, 1, &len);
    NSData *data = [NSData dataWithBytes:s length:len];
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:&err];
    if (err) {
        lua_pushnil(L);
        lua_pushstring(L, [[err localizedDescription] UTF8String]);
        return 2;
    }
    PushNSObjectToLua(L, obj);
    return 1;
}

static int l_inicfg_load(lua_State *L) {
    id defObj = lua_istable(L, 1) ? NSObjectFromLua(L, 1) : @{};
    const char *rawName = luaL_checkstring(L, 2);
    NSString *fileName = [NSString stringWithUTF8String:rawName];
    if (![fileName.pathExtension isEqualToString:@"json"]) {
        fileName = [fileName stringByAppendingString:@".json"];
    }
    NSString *fullPath = [[LoaderEngine shared].configDir stringByAppendingPathComponent:fileName];
    NSMutableDictionary *merged = [defObj isKindOfClass:[NSDictionary class]] ? [defObj mutableCopy] : [NSMutableDictionary dictionary];
    NSData *data = [NSData dataWithContentsOfFile:fullPath];
    if (data) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            [merged addEntriesFromDictionary:parsed];
        }
    } else {
        NSData *outData = [NSJSONSerialization dataWithJSONObject:merged options:NSJSONWritingPrettyPrinted error:nil];
        [outData writeToFile:fullPath atomically:YES];
    }
    PushNSObjectToLua(L, merged);
    return 1;
}

static int l_inicfg_save(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    const char *rawName = luaL_checkstring(L, 2);
    NSString *fileName = [NSString stringWithUTF8String:rawName];
    if (![fileName.pathExtension isEqualToString:@"json"]) {
        fileName = [fileName stringByAppendingString:@".json"];
    }
    NSString *fullPath = [[LoaderEngine shared].configDir stringByAppendingPathComponent:fileName];
    id obj = NSObjectFromLua(L, 1);
    if (![NSJSONSerialization isValidJSONObject:obj]) {
        lua_pushboolean(L, 0);
        return 1;
    }
    NSData *outData = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted error:nil];
    BOOL ok = [outData writeToFile:fullPath atomically:YES];
    lua_pushboolean(L, ok ? 1 : 0);
    return 1;
}

static int l_wait(lua_State *L) {
    double ms = luaL_checknumber(L, 1);
    int isMain = lua_pushthread(L);
    lua_pop(L, 1);
    if (isMain == 1) {
        return luaL_error(L, "wait() must be called inside lua_thread.create");
    }
    lua_pushnumber(L, ms);
    return lua_yield(L, 1);
}

static int l_lua_thread_create(lua_State *L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    int nargs = lua_gettop(L) - 1;
    LoaderEngine *eng = [LoaderEngine shared];
    lua_State *mainL = eng.L;

    lua_State *co = lua_newthread(mainL);
    int ref = luaL_ref(mainL, LUA_REGISTRYINDEX);

    lua_pushvalue(L, 1);
    for (int i = 0; i < nargs; i++) {
        lua_pushvalue(L, 2 + i);
    }
    lua_xmove(L, co, nargs + 1);

    int nres = 0;
    int status = AZ_LUA_RESUME(co, mainL, nargs, &nres);
    if (status == LUA_YIELD) {
        double ms = lua_gettop(co) > 0 ? lua_tonumber(co, -1) : 0.0;
        lua_settop(co, 0);
        LuaCoroutineItem *item = [LuaCoroutineItem new];
        item.co = co;
        item.ref = ref;
        item.wakeTime = CACurrentMediaTime() + (ms / 1000.0);
        item.scriptName = eng.currentLoadingScript ?: @"global";
        [eng.coroutines addObject:item];
    } else {
        if (status != LUA_OK) {
            const char *err = lua_tostring(co, -1);
            NSLog(@"[42Loader] Coroutine error: %s", err ? err : "unknown");
        }
        luaL_unref(mainL, LUA_REGISTRYINDEX, ref);
    }
    return 0;
}

static int l_sampRegisterChatCommand(lua_State *L) {
    const char *rawCmd = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    BOOL overrideServer = lua_toboolean(L, 3) ? YES : NO;

    NSString *cmd = [[NSString stringWithUTF8String:rawCmd] lowercaseString];
    if ([cmd hasPrefix:@"/"]) {
        cmd = [cmd substringFromIndex:1];
    }
    LoaderEngine *eng = [LoaderEngine shared];
    LuaCommandItem *existing = eng.commands[cmd];
    if (existing) {
        luaL_unref(eng.L, LUA_REGISTRYINDEX, existing.callbackRef);
    }
    lua_pushvalue(L, 2);
    int ref = luaL_ref(eng.L, LUA_REGISTRYINDEX);
    LuaCommandItem *item = [LuaCommandItem new];
    item.cmd = cmd;
    item.callbackRef = ref;
    item.scriptName = eng.currentLoadingScript ?: @"global";
    item.overrideServer = overrideServer;
    eng.commands[cmd] = item;
    return 0;
}

static int l_sampUnregisterChatCommand(lua_State *L) {
    const char *rawCmd = luaL_checkstring(L, 1);
    NSString *cmd = [[NSString stringWithUTF8String:rawCmd] lowercaseString];
    if ([cmd hasPrefix:@"/"]) {
        cmd = [cmd substringFromIndex:1];
    }
    LoaderEngine *eng = [LoaderEngine shared];
    LuaCommandItem *existing = eng.commands[cmd];
    if (existing) {
        luaL_unref(eng.L, LUA_REGISTRYINDEX, existing.callbackRef);
        [eng.commands removeObjectForKey:cmd];
    }
    return 0;
}

static int l_isServerCommand(lua_State *L) {
    const char *rawCmd = luaL_checkstring(L, 1);
    NSString *cmd = [[NSString stringWithUTF8String:rawCmd] lowercaseString];
    if ([cmd hasPrefix:@"/"]) {
        cmd = [cmd substringFromIndex:1];
    }
    BOOL known = [[LoaderEngine shared].knownServerCommands containsObject:cmd];
    lua_pushboolean(L, known ? 1 : 0);
    return 1;
}

static int l_registerServerCommand(lua_State *L) {
    const char *rawCmd = luaL_checkstring(L, 1);
    NSString *cmd = [NSString stringWithUTF8String:rawCmd];
    [[LoaderEngine shared] registerKnownServerCommand:cmd persist:YES];
    return 0;
}

static int l_registerEvent(lua_State *L) {
    const char *ev = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    LoaderEngine *eng = [LoaderEngine shared];
    lua_pushvalue(L, 2);
    int ref = luaL_ref(eng.L, LUA_REGISTRYINDEX);
    LuaEventItem *item = [LuaEventItem new];
    item.eventName = [NSString stringWithUTF8String:ev];
    item.callbackRef = ref;
    item.scriptName = eng.currentLoadingScript ?: @"global";
    [eng.eventHooks addObject:item];
    return 0;
}

static int l_sampAddChatMessage(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    uint32_t color = (uint32_t)luaL_optinteger(L, 2, 0xA855F7FF);
    if (orig_AddChatMessage) {
        orig_AddChatMessage(color, text);
    } else {
        NSString *msg = [NSString stringWithUTF8String:text] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            LoaderEngine *eng = [LoaderEngine shared];
            eng.statusLabel.text = [NSString stringWithFormat:@"42 • %@", msg];
            eng.statusBanner.hidden = NO;
        });
    }
    return 0;
}

static int l_sampSendChat(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    void *sym = dlsym(RTLD_DEFAULT, "Java_com_arizona_game_GTASA_SendChatMessage");
    if (sym) {
        typedef void (*SendChatFn)(const char *);
        ((SendChatFn)sym)(text);
    }
    return 0;
}

static int l_sampSendDialogResponse(lua_State *L) {
    int dialogId = (int)luaL_checkinteger(L, 1);
    int button = (int)luaL_checkinteger(L, 2);
    int listitem = (int)luaL_optinteger(L, 3, 0);
    const char *input = luaL_optstring(L, 4, "");
    void *sym = dlsym(RTLD_DEFAULT, "SendDialogResponse");
    if (!sym) sym = dlsym(RTLD_DEFAULT, "Java_com_arizona_game_GTASA_SendDialogResponse");
    if (sym) {
        typedef void (*DialogRespFn)(int, int, int, const char *);
        ((DialogRespFn)sym)(dialogId, button, listitem, input);
    }
    return 0;
}

static int l_asyncHttpRequest(lua_State *L) {
    const char *methodC = luaL_checkstring(L, 1);
    const char *urlC = luaL_checkstring(L, 2);
    NSDictionary *args = lua_istable(L, 3) ? (NSDictionary *)NSObjectFromLua(L, 3) : @{};

    LoaderEngine *eng = [LoaderEngine shared];
    int okRef = LUA_NOREF;
    int errRef = LUA_NOREF;

    if (lua_isfunction(L, 4)) {
        lua_pushvalue(L, 4);
        okRef = luaL_ref(eng.L, LUA_REGISTRYINDEX);
    }
    if (lua_isfunction(L, 5)) {
        lua_pushvalue(L, 5);
        errRef = luaL_ref(eng.L, LUA_REGISTRYINDEX);
    }

    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:urlC]];
    if (!url) {
        if (okRef != LUA_NOREF) luaL_unref(eng.L, LUA_REGISTRYINDEX, okRef);
        if (errRef != LUA_NOREF) luaL_unref(eng.L, LUA_REGISTRYINDEX, errRef);
        return luaL_error(L, "invalid URL");
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = [[NSString stringWithUTF8String:methodC] uppercaseString];
    req.timeoutInterval = args[@"timeout"] ? [args[@"timeout"] doubleValue] : 15.0;

    NSDictionary *headers = args[@"headers"];
    if ([headers isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in headers) {
            [req setValue:[headers[k] description] forHTTPHeaderField:k];
        }
    }

    id bodyObj = args[@"data"];
    if (bodyObj) {
        if ([bodyObj isKindOfClass:[NSString class]]) {
            req.HTTPBody = [(NSString *)bodyObj dataUsingEncoding:NSUTF8StringEncoding];
        } else if ([NSJSONSerialization isValidJSONObject:bodyObj]) {
            req.HTTPBody = [NSJSONSerialization dataWithJSONObject:bodyObj options:0 error:nil];
            if (![req valueForHTTPHeaderField:@"Content-Type"]) {
                [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            }
        }
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            lua_State *mainL = [LoaderEngine shared].L;
            if (!mainL) return;
            if (error) {
                if (errRef != LUA_NOREF) {
                    lua_rawgeti(mainL, LUA_REGISTRYINDEX, errRef);
                    lua_pushstring(mainL, [[error localizedDescription] UTF8String]);
                    lua_pcall(mainL, 1, 0, 0);
                }
            } else if (okRef != LUA_NOREF) {
                NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
                NSString *text = data ? ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"") : @"";
                lua_rawgeti(mainL, LUA_REGISTRYINDEX, okRef);
                lua_createtable(mainL, 0, 2);
                lua_pushinteger(mainL, statusCode);
                lua_setfield(mainL, -2, "status_code");
                lua_pushstring(mainL, [text UTF8String]);
                lua_setfield(mainL, -2, "text");
                lua_pcall(mainL, 1, 0, 0);
            }
            if (okRef != LUA_NOREF) luaL_unref(mainL, LUA_REGISTRYINDEX, okRef);
            if (errRef != LUA_NOREF) luaL_unref(mainL, LUA_REGISTRYINDEX, errRef);
        });
    }] resume];

    return 0;
}

static int l_setClipboardText(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    NSString *str = [NSString stringWithUTF8String:text] ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIPasteboard generalPasteboard].string = str;
    });
    lua_pushboolean(L, 1);
    return 1;
}

static int l_getClipboardText(lua_State *L) {
    NSString *str = [UIPasteboard generalPasteboard].string ?: @"";
    lua_pushstring(L, [str UTF8String]);
    return 1;
}

static int l_vibrate(lua_State *L) {
    const char *styleC = luaL_optstring(L, 1, "medium");
    NSString *style = [[NSString stringWithUTF8String:styleC] lowercaseString];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIImpactFeedbackStyle fbStyle = UIImpactFeedbackStyleMedium;
        if ([style isEqualToString:@"light"]) fbStyle = UIImpactFeedbackStyleLight;
        else if ([style isEqualToString:@"heavy"]) fbStyle = UIImpactFeedbackStyleHeavy;
        else if (@available(iOS 13.0, *)) {
            if ([style isEqualToString:@"soft"]) fbStyle = UIImpactFeedbackStyleSoft;
            else if ([style isEqualToString:@"rigid"]) fbStyle = UIImpactFeedbackStyleRigid;
        }
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:fbStyle];
        [gen prepare];
        [gen impactOccurred];
    });
    return 0;
}

static int l_sendLocalNotification(lua_State *L) {
    const char *titleC = luaL_checkstring(L, 1);
    const char *bodyC = luaL_checkstring(L, 2);
    double delay = luaL_optnumber(L, 3, 0.2);
    if (delay < 0.1) delay = 0.1;

    NSString *title = [NSString stringWithUTF8String:titleC] ?: @"42Loader";
    NSString *body = [NSString stringWithUTF8String:bodyC] ?: @"";

    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = title;
    content.body = body;
    content.sound = [UNNotificationSound defaultSound];

    UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:delay repeats:NO];
    NSString *identifier = [[NSUUID UUID] UUIDString];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
    return 0;
}

static int l_getScreenResolution(lua_State *L) {
    CGRect bounds = [UIScreen mainScreen].bounds;
    lua_pushnumber(L, bounds.size.width);
    lua_pushnumber(L, bounds.size.height);
    return 2;
}

static int l_getScriptsCount(lua_State *L) {
    LoaderEngine *eng = [LoaderEngine shared];
    NSInteger active = 0;
    for (NSString *name in eng.discoveredScripts) {
        if ([eng.enabledScripts[name] boolValue]) active++;
    }
    lua_pushinteger(L, eng.discoveredScripts.count);
    lua_pushinteger(L, active);
    return 2;
}

static int l_openLoaderSettings(lua_State *L) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[LoaderEngine shared] showSettingsWindow];
    });
    return 0;
}

static int luaopen_cjson_shim(lua_State *L) {
    lua_createtable(L, 0, 2);
    lua_pushcfunction(L, l_json_encode);
    lua_setfield(L, -2, "encode");
    lua_pushcfunction(L, l_json_decode);
    lua_setfield(L, -2, "decode");
    return 1;
}

static int luaopen_inicfg_shim(lua_State *L) {
    lua_createtable(L, 0, 2);
    lua_pushcfunction(L, l_inicfg_load);
    lua_setfield(L, -2, "load");
    lua_pushcfunction(L, l_inicfg_save);
    lua_setfield(L, -2, "save");
    return 1;
}

@implementation LoaderSettingsVC {
    UISegmentedControl *_tabs;
    UITableView *_tableView;
    UIView *_appearanceView;
    UITextField *_cmdInput;
    UISlider *_alphaSlider;
    UISlider *_radiusSlider;
    UISwitch *_floatBtnSwitch;
    UISwitch *_bannerSwitch;
    UIButton *_resetCmdCacheBtn;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    LoaderEngine *eng = [LoaderEngine shared];
    UIColor *accent = [eng currentAccentColor];

    self.view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [[UIColor colorWithRed:0.07 green:0.04 blue:0.12 alpha:1.0] colorWithAlphaComponent:eng.uiAlpha];
    card.layer.cornerRadius = eng.cornerRadius;
    card.layer.borderWidth = 1.2;
    card.layer.borderColor = [accent colorWithAlphaComponent:0.65].CGColor;
    card.clipsToBounds = YES;
    [self.view addSubview:card];

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:440],
        [card.heightAnchor constraintEqualToConstant:325]
    ]];

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    titleLbl.text = @"42Loader • Arizona iOS";
    titleLbl.font = [UIFont boldSystemFontOfSize:16];
    titleLbl.textColor = [UIColor whiteColor];
    [card addSubview:titleLbl];

    UIButton *reloadAllBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    reloadAllBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [reloadAllBtn setTitle:@"Reload All" forState:UIControlStateNormal];
    [reloadAllBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    reloadAllBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    reloadAllBtn.backgroundColor = accent;
    reloadAllBtn.layer.cornerRadius = 8;
    [reloadAllBtn addTarget:self action:@selector(onReloadAll) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:reloadAllBtn];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [closeBtn addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:closeBtn];

    _tabs = [[UISegmentedControl alloc] initWithItems:@[@"Скрипты", @"Интерфейс"]];
    _tabs.translatesAutoresizingMaskIntoConstraints = NO;
    _tabs.selectedSegmentIndex = 0;
    _tabs.selectedSegmentTintColor = accent;
    [_tabs setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor]} forState:UIControlStateNormal];
    [_tabs addTarget:self action:@selector(onTabChanged) forControlEvents:UIControlEventValueChanged];
    [card addSubview:_tabs];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.separatorColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    [card addSubview:_tableView];

    _cmdInput = [[UITextField alloc] init];
    _cmdInput.translatesAutoresizingMaskIntoConstraints = NO;
    _cmdInput.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    _cmdInput.textColor = [UIColor whiteColor];
    _cmdInput.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _cmdInput.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Выполнить команду (например /luahelp)..." attributes:@{NSForegroundColorAttributeName: [UIColor grayColor]}];
    _cmdInput.layer.cornerRadius = 8;
    _cmdInput.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 30)];
    _cmdInput.leftViewMode = UITextFieldViewModeAlways;
    _cmdInput.returnKeyType = UIReturnKeySend;
    _cmdInput.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _cmdInput.autocorrectionType = UITextAutocorrectionTypeNo;
    _cmdInput.delegate = self;
    [card addSubview:_cmdInput];

    _appearanceView = [[UIView alloc] init];
    _appearanceView.translatesAutoresizingMaskIntoConstraints = NO;
    _appearanceView.hidden = YES;
    [card addSubview:_appearanceView];

    [NSLayoutConstraint activateConstraints:@[
        [titleLbl.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [titleLbl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],

        [closeBtn.centerYAnchor constraintEqualToAnchor:titleLbl.centerYAnchor],
        [closeBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [closeBtn.widthAnchor constraintEqualToConstant:30],

        [reloadAllBtn.centerYAnchor constraintEqualToAnchor:titleLbl.centerYAnchor],
        [reloadAllBtn.trailingAnchor constraintEqualToAnchor:closeBtn.leadingAnchor constant:-8],
        [reloadAllBtn.widthAnchor constraintEqualToConstant:82],
        [reloadAllBtn.heightAnchor constraintEqualToConstant:26],

        [_tabs.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:10],
        [_tabs.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [_tabs.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [_tabs.heightAnchor constraintEqualToConstant:28],

        [_cmdInput.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [_cmdInput.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [_cmdInput.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [_cmdInput.heightAnchor constraintEqualToConstant:32],

        [_tableView.topAnchor constraintEqualToAnchor:_tabs.bottomAnchor constant:8],
        [_tableView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8],
        [_tableView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8],
        [_tableView.bottomAnchor constraintEqualToAnchor:_cmdInput.topAnchor constant:-8],

        [_appearanceView.topAnchor constraintEqualToAnchor:_tabs.bottomAnchor constant:8],
        [_appearanceView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [_appearanceView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [_appearanceView.bottomAnchor constraintEqualToAnchor:_cmdInput.topAnchor constant:-8]
    ]];

    [self buildAppearanceControls];
}

- (void)buildAppearanceControls {
    LoaderEngine *eng = [LoaderEngine shared];
    NSArray<NSString *> *palette = @[@"#8B5CF6", @"#C026D3", @"#6366F1", @"#EC4899"];
    UILabel *colorLbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 2, 140, 24)];
    colorLbl.text = @"Цвет акцента:";
    colorLbl.textColor = [UIColor whiteColor];
    colorLbl.font = [UIFont systemFontOfSize:13];
    [_appearanceView addSubview:colorLbl];

    for (NSUInteger i = 0; i < palette.count; i++) {
        UIButton *swatch = [UIButton buttonWithType:UIButtonTypeCustom];
        swatch.frame = CGRectMake(150 + i * 36, 0, 26, 26);
        swatch.layer.cornerRadius = 13;
        swatch.backgroundColor = [self colorFromHex:palette[i]];
        swatch.layer.borderWidth = [eng.accentHex isEqualToString:palette[i]] ? 2.5 : 0.0;
        swatch.layer.borderColor = [UIColor whiteColor].CGColor;
        swatch.tag = (NSInteger)i;
        [swatch addTarget:self action:@selector(onSelectAccent:) forControlEvents:UIControlEventTouchUpInside];
        [_appearanceView addSubview:swatch];
    }

    UILabel *alphaLbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 34, 140, 24)];
    alphaLbl.text = @"Прозрачность:";
    alphaLbl.textColor = [UIColor whiteColor];
    alphaLbl.font = [UIFont systemFontOfSize:13];
    [_appearanceView addSubview:alphaLbl];

    _alphaSlider = [[UISlider alloc] initWithFrame:CGRectMake(150, 32, 240, 26)];
    _alphaSlider.minimumValue = 0.65f;
    _alphaSlider.maximumValue = 1.0f;
    _alphaSlider.value = (float)eng.uiAlpha;
    _alphaSlider.tintColor = [eng currentAccentColor];
    [_alphaSlider addTarget:self action:@selector(onAppearanceChanged) forControlEvents:UIControlEventValueChanged];
    [_appearanceView addSubview:_alphaSlider];

    UILabel *radLbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 66, 140, 24)];
    radLbl.text = @"Скругление углов:";
    radLbl.textColor = [UIColor whiteColor];
    radLbl.font = [UIFont systemFontOfSize:13];
    [_appearanceView addSubview:radLbl];

    _radiusSlider = [[UISlider alloc] initWithFrame:CGRectMake(150, 64, 240, 26)];
    _radiusSlider.minimumValue = 6.0f;
    _radiusSlider.maximumValue = 24.0f;
    _radiusSlider.value = (float)eng.cornerRadius;
    _radiusSlider.tintColor = [eng currentAccentColor];
    [_radiusSlider addTarget:self action:@selector(onAppearanceChanged) forControlEvents:UIControlEventValueChanged];
    [_appearanceView addSubview:_radiusSlider];

    UILabel *btnLbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 100, 220, 24)];
    btnLbl.text = @"Кнопка 42 поверх экрана:";
    btnLbl.textColor = [UIColor whiteColor];
    btnLbl.font = [UIFont systemFontOfSize:13];
    [_appearanceView addSubview:btnLbl];

    _floatBtnSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(340, 96, 51, 31)];
    _floatBtnSwitch.on = eng.showFloatingBtn;
    _floatBtnSwitch.onTintColor = [eng currentAccentColor];
    [_floatBtnSwitch addTarget:self action:@selector(onAppearanceChanged) forControlEvents:UIControlEventValueChanged];
    [_appearanceView addSubview:_floatBtnSwitch];

    UILabel *banLbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 134, 240, 24)];
    banLbl.text = @"Баннер статуса при запуске:";
    banLbl.textColor = [UIColor whiteColor];
    banLbl.font = [UIFont systemFontOfSize:13];
    [_appearanceView addSubview:banLbl];

    _bannerSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(340, 130, 51, 31)];
    _bannerSwitch.on = eng.showStartupBanner;
    _bannerSwitch.onTintColor = [eng currentAccentColor];
    [_bannerSwitch addTarget:self action:@selector(onAppearanceChanged) forControlEvents:UIControlEventValueChanged];
    [_appearanceView addSubview:_bannerSwitch];

    _resetCmdCacheBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _resetCmdCacheBtn.frame = CGRectMake(0, 170, 392, 28);
    [_resetCmdCacheBtn setTitle:@"Сбросить кэш команд сервера" forState:UIControlStateNormal];
    [_resetCmdCacheBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _resetCmdCacheBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    _resetCmdCacheBtn.backgroundColor = [[eng currentAccentColor] colorWithAlphaComponent:0.35];
    _resetCmdCacheBtn.layer.cornerRadius = 8;
    [_resetCmdCacheBtn addTarget:self action:@selector(onResetServerCommands) forControlEvents:UIControlEventTouchUpInside];
    [_appearanceView addSubview:_resetCmdCacheBtn];
}

- (void)onResetServerCommands {
    [[LoaderEngine shared] resetServerCommandsCache];
    [_resetCmdCacheBtn setTitle:@"Кэш команд сервера сброшен ✓" forState:UIControlStateNormal];
}

- (UIColor *)colorFromHex:(NSString *)hex {
    unsigned rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    if ([hex hasPrefix:@"#"]) [scanner setScanLocation:1];
    [scanner scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

- (void)onSelectAccent:(UIButton *)sender {
    NSArray<NSString *> *palette = @[@"#8B5CF6", @"#C026D3", @"#6366F1", @"#EC4899"];
    LoaderEngine *eng = [LoaderEngine shared];
    eng.accentHex = palette[(NSUInteger)sender.tag];
    [eng saveState];
    [eng applyThemeToOverlay];
    [self dismissViewControllerAnimated:NO completion:^{
        [[LoaderEngine shared] showSettingsWindow];
    }];
}

- (void)onAppearanceChanged {
    LoaderEngine *eng = [LoaderEngine shared];
    eng.uiAlpha = _alphaSlider.value;
    eng.cornerRadius = _radiusSlider.value;
    eng.showFloatingBtn = _floatBtnSwitch.on;
    eng.showStartupBanner = _bannerSwitch.on;
    [eng saveState];
    [eng applyThemeToOverlay];
}

- (void)onTabChanged {
    BOOL isScripts = (_tabs.selectedSegmentIndex == 0);
    _tableView.hidden = !isScripts;
    _appearanceView.hidden = isScripts;
}

- (void)onReloadAll {
    LoaderEngine *eng = [LoaderEngine shared];
    [eng scanScriptsOnly];
    [eng loadAllEnabledScripts];
    [_tableView reloadData];
}

- (void)onClose {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    NSString *txt = textField.text;
    textField.text = @"";
    [textField resignFirstResponder];
    if (txt.length > 0) {
        BOOL handled = [[LoaderEngine shared] handleOutgoingInput:txt];
        if (!handled) {
            void *sym = dlsym(RTLD_DEFAULT, "Java_com_arizona_game_GTASA_SendChatMessage");
            if (sym) {
                typedef void (*SendChatFn)(const char *);
                ((SendChatFn)sym)([txt UTF8String]);
            }
        }
        [_tableView reloadData];
    }
    return YES;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[LoaderEngine shared].discoveredScripts.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 44.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    LoaderEngine *eng = [LoaderEngine shared];
    NSString *scriptName = eng.discoveredScripts[(NSUInteger)indexPath.row];
    BOOL enabled = [eng.enabledScripts[scriptName] boolValue];
    NSString *st = eng.scriptStatuses[scriptName] ?: (enabled ? @"Ready" : @"Off");

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = scriptName;
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:13];
    cell.detailTextLabel.text = st;
    cell.detailTextLabel.textColor = [st hasPrefix:@"Err"] ? [UIColor systemRedColor] : [UIColor lightGrayColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11];

    UIView *accessory = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 120, 34)];

    UIButton *reloadBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    reloadBtn.frame = CGRectMake(0, 3, 56, 28);
    [reloadBtn setTitle:@"Reload" forState:UIControlStateNormal];
    [reloadBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    reloadBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    reloadBtn.backgroundColor = [[eng currentAccentColor] colorWithAlphaComponent:0.45];
    reloadBtn.layer.cornerRadius = 6;
    reloadBtn.tag = indexPath.row;
    [reloadBtn addTarget:self action:@selector(onReloadRow:) forControlEvents:UIControlEventTouchUpInside];
    [accessory addSubview:reloadBtn];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(64, 1, 51, 31)];
    sw.on = enabled;
    sw.onTintColor = [eng currentAccentColor];
    sw.tag = indexPath.row;
    [sw addTarget:self action:@selector(onToggleRow:) forControlEvents:UIControlEventValueChanged];
    [accessory addSubview:sw];

    cell.accessoryView = accessory;
    return cell;
}

- (void)onReloadRow:(UIButton *)sender {
    LoaderEngine *eng = [LoaderEngine shared];
    NSString *scriptName = eng.discoveredScripts[(NSUInteger)sender.tag];
    [eng reloadSingleScript:scriptName];
    [_tableView reloadData];
}

- (void)onToggleRow:(UISwitch *)sender {
    LoaderEngine *eng = [LoaderEngine shared];
    NSString *scriptName = eng.discoveredScripts[(NSUInteger)sender.tag];
    [eng setScript:scriptName enabled:sender.on];
    [_tableView reloadData];
}

@end

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
    self = [super init];
    if (self) {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        _baseDir = [docs stringByAppendingPathComponent:@"arizonaloader"];
        _configDir = [_baseDir stringByAppendingPathComponent:@"config"];
        _statePath = [_baseDir stringByAppendingPathComponent:@"loader_state.json"];
        _serverCmdCachePath = [_configDir stringByAppendingPathComponent:@"server_commands.json"];

        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:_baseDir withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:_configDir withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:[_baseDir stringByAppendingPathComponent:@"lib"] withIntermediateDirectories:YES attributes:nil error:nil];

        _enabledScripts = [NSMutableDictionary dictionary];
        _scriptStatuses = [NSMutableDictionary dictionary];
        _discoveredScripts = [NSMutableArray array];
        _coroutines = [NSMutableArray array];
        _commands = [NSMutableDictionary dictionary];
        _eventHooks = [NSMutableArray array];

        _knownServerCommands = [NSMutableSet set];
        _confirmedLocalCommands = [NSMutableSet set];
        _pendingCommands = [NSMutableArray array];

        _accentHex = @"#8B5CF6";
        _uiAlpha = 0.94;
        _cornerRadius = 16.0;
        _showFloatingBtn = YES;
        _showStartupBanner = YES;

        [self seedDefaultServerCommands];
        [self loadServerCommandsCache];
        [self loadState];
    }
    return self;
}

- (void)seedDefaultServerCommands {
    NSArray<NSString *> *builtins = @[
        @"q", @"quit", @"save", @"rs", @"interior", @"fpslimit",
        @"pagesize", @"timestamp", @"headmove", @"dl", @"mem",
        @"audiomsg", @"nametagstatus", @"ctd", @"rcon"
    ];
    [_knownServerCommands addObjectsFromArray:builtins];
}

- (void)loadServerCommandsCache {
    NSData *data = [NSData dataWithContentsOfFile:_serverCmdCachePath];
    if (!data) return;
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([arr isKindOfClass:[NSArray class]]) {
        for (id item in arr) {
            if ([item isKindOfClass:[NSString class]]) {
                [_knownServerCommands addObject:[(NSString *)item lowercaseString]];
            }
        }
    }
}

- (void)saveServerCommandsCache {
    NSArray *sorted = [[_knownServerCommands allObjects] sortedArrayUsingSelector:@selector(compare:)];
    NSData *data = [NSJSONSerialization dataWithJSONObject:sorted options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:_serverCmdCachePath atomically:YES];
}

- (void)registerKnownServerCommand:(NSString *)rawCmd persist:(BOOL)persist {
    if (!rawCmd || rawCmd.length == 0) return;
    NSString *cmd = [rawCmd lowercaseString];
    if ([cmd hasPrefix:@"/"]) cmd = [cmd substringFromIndex:1];
    if (cmd.length == 0) return;

    [_knownServerCommands addObject:cmd];
    [_confirmedLocalCommands removeObject:cmd];
    if (persist) {
        [self saveServerCommandsCache];
    }
}

- (void)resetServerCommandsCache {
    [_knownServerCommands removeAllObjects];
    [_confirmedLocalCommands removeAllObjects];
    [_pendingCommands removeAllObjects];
    [self seedDefaultServerCommands];
    [self saveServerCommandsCache];
}

- (void)loadState {
    NSData *data = [NSData dataWithContentsOfFile:_statePath];
    if (!data) return;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![dict isKindOfClass:[NSDictionary class]]) return;
    if ([dict[@"scripts"] isKindOfClass:[NSDictionary class]]) {
        [_enabledScripts addEntriesFromDictionary:dict[@"scripts"]];
    }
    if ([dict[@"accentHex"] isKindOfClass:[NSString class]]) _accentHex = dict[@"accentHex"];
    if (dict[@"uiAlpha"]) _uiAlpha = [dict[@"uiAlpha"] doubleValue];
    if (dict[@"cornerRadius"]) _cornerRadius = [dict[@"cornerRadius"] doubleValue];
    if (dict[@"showFloatingBtn"]) _showFloatingBtn = [dict[@"showFloatingBtn"] boolValue];
    if (dict[@"showStartupBanner"]) _showStartupBanner = [dict[@"showStartupBanner"] boolValue];
}

- (void)saveState {
    NSDictionary *dict = @{
        @"scripts": _enabledScripts,
        @"accentHex": _accentHex,
        @"uiAlpha": @(_uiAlpha),
        @"cornerRadius": @(_cornerRadius),
        @"showFloatingBtn": @(_showFloatingBtn),
        @"showStartupBanner": @(_showStartupBanner)
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:_statePath atomically:YES];
}

- (UIColor *)currentAccentColor {
    unsigned rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:_accentHex];
    if ([_accentHex hasPrefix:@"#"]) [scanner setScanLocation:1];
    [scanner scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

- (void)initLuaVM {
    if (_L) lua_close(_L);
    _L = luaL_newstate();
    luaL_openlibs(_L);

    NSString *pkgPaths = [NSString stringWithFormat:@"%@/?.lua;%@/lib/?.lua", _baseDir, _baseDir];
    lua_getglobal(_L, "package");
    lua_pushstring(_L, [pkgPaths UTF8String]);
    lua_setfield(_L, -2, "path");
    lua_getfield(_L, -1, "preload");
    lua_pushcfunction(_L, luaopen_cjson_shim);
    lua_setfield(_L, -2, "cjson");
    lua_pushcfunction(_L, luaopen_cjson_shim);
    lua_setfield(_L, -2, "json");
    lua_pushcfunction(_L, luaopen_inicfg_shim);
    lua_setfield(_L, -2, "inicfg");
    lua_pop(_L, 2);

    luaopen_cjson_shim(_L);
    lua_setglobal(_L, "json");

    luaopen_inicfg_shim(_L);
    lua_setglobal(_L, "inicfg");

    lua_createtable(_L, 0, 1);
    lua_pushcfunction(_L, l_lua_thread_create);
    lua_setfield(_L, -2, "create");
    lua_setglobal(_L, "lua_thread");

    lua_register(_L, "wait", l_wait);
    lua_register(_L, "sampRegisterChatCommand", l_sampRegisterChatCommand);
    lua_register(_L, "sampUnregisterChatCommand", l_sampUnregisterChatCommand);
    lua_register(_L, "isServerCommand", l_isServerCommand);
    lua_register(_L, "registerServerCommand", l_registerServerCommand);
    lua_register(_L, "registerEvent", l_registerEvent);
    lua_register(_L, "sampAddChatMessage", l_sampAddChatMessage);
    lua_register(_L, "sampSendChat", l_sampSendChat);
    lua_register(_L, "sampSendDialogResponse", l_sampSendDialogResponse);
    lua_register(_L, "asyncHttpRequest", l_asyncHttpRequest);
    lua_register(_L, "setClipboardText", l_setClipboardText);
    lua_register(_L, "getClipboardText", l_getClipboardText);
    lua_register(_L, "vibrate", l_vibrate);
    lua_register(_L, "sendLocalNotification", l_sendLocalNotification);
    lua_register(_L, "getScreenResolution", l_getScreenResolution);
    lua_register(_L, "getScriptsCount", l_getScriptsCount);
    lua_register(_L, "openLoaderSettings", l_openLoaderSettings);

    const char *bootstrap =
        "function httpRequest(method, url, args)\n"
        "  local done, res, err = false, nil, nil\n"
        "  asyncHttpRequest(method, url, args or {},\n"
        "    function(r) res = r; done = true end,\n"
        "    function(e) err = e; done = true end)\n"
        "  while not done do wait(10) end\n"
        "  return res, err\n"
        "end\n";
    luaL_dostring(_L, bootstrap);
}

- (void)scanScriptsOnly {
    [_discoveredScripts removeAllObjects];
    NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_baseDir error:nil];
    NSArray<NSString *> *sorted = [items sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *file in sorted) {
        if ([file.pathExtension.lowercaseString isEqualToString:@"lua"]) {
            [_discoveredScripts addObject:file];
            if (_enabledScripts[file] == nil) {
                _enabledScripts[file] = @YES;
            }
            if (!_gameStarted) {
                _scriptStatuses[file] = [_enabledScripts[file] boolValue] ? @"Ожидает запуска игры" : @"Отключён";
            }
        }
    }
    [self saveState];
}

- (void)bootStageOne {
    [self scanScriptsOnly];
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge) completionHandler:^(BOOL granted, NSError *error) {}];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self setupOverlayUI];
        NSInteger active = 0;
        for (NSString *s in self.discoveredScripts) {
            if ([self.enabledScripts[s] boolValue]) active++;
        }
        self.statusLabel.text = [NSString stringWithFormat:@"42Loader • Найдено скриптов: %lu (активно: %ld)",
                                 (unsigned long)self.discoveredScripts.count, (long)active];
        self.statusBanner.hidden = !self.showStartupBanner;
    });
}

- (void)triggerStageTwoIfNeeded {
    if (_gameStarted) return;
    _gameStarted = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = @"42Loader • Загрузка скриптов...";
        self.statusBanner.hidden = !self.showStartupBanner;
        [self loadAllEnabledScripts];
    });
}

- (void)unloadScriptResources:(NSString *)scriptName {
    if (!_L) return;
    NSMutableArray *keepCo = [NSMutableArray array];
    for (LuaCoroutineItem *item in _coroutines) {
        if ([item.scriptName isEqualToString:scriptName]) {
            luaL_unref(_L, LUA_REGISTRYINDEX, item.ref);
        } else {
            [keepCo addObject:item];
        }
    }
    _coroutines = keepCo;

    NSArray<NSString *> *cmdKeys = [_commands allKeys];
    for (NSString *k in cmdKeys) {
        LuaCommandItem *c = _commands[k];
        if ([c.scriptName isEqualToString:scriptName]) {
            luaL_unref(_L, LUA_REGISTRYINDEX, c.callbackRef);
            [_commands removeObjectForKey:k];
        }
    }

    NSMutableArray *keepEv = [NSMutableArray array];
    for (LuaEventItem *ev in _eventHooks) {
        if ([ev.scriptName isEqualToString:scriptName]) {
            luaL_unref(_L, LUA_REGISTRYINDEX, ev.callbackRef);
        } else {
            [keepEv addObject:ev];
        }
    }
    _eventHooks = keepEv;
}

- (void)executeSingleScript:(NSString *)scriptName {
    if (!_L) [self initLuaVM];
    [self unloadScriptResources:scriptName];

    if (![_enabledScripts[scriptName] boolValue]) {
        _scriptStatuses[scriptName] = @"Отключён";
        return;
    }

    NSString *path = [_baseDir stringByAppendingPathComponent:scriptName];
    _currentLoadingScript = scriptName;
    int err = luaL_loadfile(_L, [path UTF8String]);
    if (err != LUA_OK) {
        const char *msg = lua_tostring(_L, -1);
        _scriptStatuses[scriptName] = [NSString stringWithFormat:@"Error: %s", msg ? msg : "syntax"];
        lua_pop(_L, 1);
        _currentLoadingScript = nil;
        return;
    }

    if (lua_pcall(_L, 0, 0, 0) != LUA_OK) {
        const char *msg = lua_tostring(_L, -1);
        _scriptStatuses[scriptName] = [NSString stringWithFormat:@"Error: %s", msg ? msg : "runtime"];
        lua_pop(_L, 1);
    } else {
        _scriptStatuses[scriptName] = @"Загружен";
    }
    _currentLoadingScript = nil;
}

- (void)loadAllEnabledScripts {
    [self initLuaVM];
    [_coroutines removeAllObjects];
    [_commands removeAllObjects];
    [_eventHooks removeAllObjects];
    [_confirmedLocalCommands removeAllObjects];
    [_pendingCommands removeAllObjects];

    NSInteger loadedCount = 0;
    for (NSString *scriptName in _discoveredScripts) {
        [self executeSingleScript:scriptName];
        if ([_scriptStatuses[scriptName] isEqualToString:@"Загружен"]) {
            loadedCount++;
        }
    }

    [self startTickTimer];
    _statusLabel.text = [NSString stringWithFormat:@"42Loader • Загружено скриптов: %ld/%lu",
                         (long)loadedCount, (unsigned long)_discoveredScripts.count];
    if (self.showStartupBanner) {
        self.statusBanner.hidden = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.statusBanner.hidden = YES;
        });
    }
}

- (void)reloadSingleScript:(NSString *)scriptName {
    if (!_gameStarted) {
        _gameStarted = YES;
        [self initLuaVM];
        [self startTickTimer];
    }
    [self executeSingleScript:scriptName];
}

- (void)setScript:(NSString *)scriptName enabled:(BOOL)enabled {
    _enabledScripts[scriptName] = @(enabled);
    [self saveState];
    if (_gameStarted) {
        if (enabled) {
            [self executeSingleScript:scriptName];
        } else {
            [self unloadScriptResources:scriptName];
            _scriptStatuses[scriptName] = @"Отключён";
        }
    } else {
        _scriptStatuses[scriptName] = enabled ? @"Ожидает запуска игры" : @"Отключён";
    }
}

- (void)startTickTimer {
    if (_tickTimer) return;
    _lastTick = CACurrentMediaTime();
    _tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(onTick) userInfo:nil repeats:YES];
}

- (void)onTick {
    if (!_L) return;
    NSTimeInterval now = CACurrentMediaTime();
    double dt = now - _lastTick;
    _lastTick = now;

    if (_pendingCommands.count > 0) {
        NSMutableArray<PendingCommandItem *> *stillPending = [NSMutableArray array];
        for (PendingCommandItem *p in _pendingCommands) {
            if (now - p.sentTime >= 1.5) {
                [self registerKnownServerCommand:p.cmd persist:YES];
            } else {
                [stillPending addObject:p];
            }
        }
        _pendingCommands = stillPending;
    }

    if (_coroutines.count > 0) {
        NSArray<LuaCoroutineItem *> *snapshot = [_coroutines copy];
        for (LuaCoroutineItem *item in snapshot) {
            if (now >= item.wakeTime) {
                int nres = 0;
                int status = AZ_LUA_RESUME(item.co, _L, 0, &nres);
                if (status == LUA_YIELD) {
                    double ms = lua_gettop(item.co) > 0 ? lua_tonumber(item.co, -1) : 0.0;
                    lua_settop(item.co, 0);
                    item.wakeTime = now + (ms / 1000.0);
                } else {
                    if (status != LUA_OK) {
                        const char *err = lua_tostring(item.co, -1);
                        NSLog(@"[42Loader] Thread error (%@): %s", item.scriptName, err ? err : "unknown");
                    }
                    luaL_unref(_L, LUA_REGISTRYINDEX, item.ref);
                    [_coroutines removeObject:item];
                }
            }
        }
    }

    lua_getglobal(_L, "onUpdate");
    if (lua_isfunction(_L, -1)) {
        lua_pushnumber(_L, dt);
        if (lua_pcall(_L, 1, 0, 0) != LUA_OK) {
            lua_pop(_L, 1);
        }
    } else {
        lua_pop(_L, 1);
    }
}

- (void)executeLuaCommand:(LuaCommandItem *)item args:(NSString *)args {
    if (!item || !_L) return;
    lua_rawgeti(_L, LUA_REGISTRYINDEX, item.callbackRef);
    lua_pushstring(_L, [args UTF8String]);
    if (lua_pcall(_L, 1, 0, 0) != LUA_OK) {
        const char *err = lua_tostring(_L, -1);
        NSLog(@"[42Loader] Command /%@ error: %s", item.cmd, err ? err : "unknown");
        lua_pop(_L, 1);
    }
}

- (BOOL)handleOutgoingInput:(NSString *)text {
    if (!text || text.length == 0) return NO;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![trimmed hasPrefix:@"/"]) return NO;

    NSString *withoutSlash = [trimmed substringFromIndex:1];
    NSRange spaceRange = [withoutSlash rangeOfString:@" "];
    NSString *cmd = (spaceRange.location == NSNotFound)
        ? [withoutSlash lowercaseString]
        : [[withoutSlash substringToIndex:spaceRange.location] lowercaseString];
    NSString *args = (spaceRange.location == NSNotFound)
        ? @""
        : [withoutSlash substringFromIndex:spaceRange.location + 1];

    if ([cmd isEqualToString:@"luasettings"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showSettingsWindow];
        });
        return YES;
    }

    LuaCommandItem *item = _commands[cmd];
    if (!item || !_L) {
        return NO;
    }

    if (item.overrideServer || !_inGameSession) {
        [self executeLuaCommand:item args:args];
        return YES;
    }

    if ([_knownServerCommands containsObject:cmd]) {
        return NO;
    }

    if ([_confirmedLocalCommands containsObject:cmd]) {
        [self executeLuaCommand:item args:args];
        return YES;
    }

    PendingCommandItem *pending = [PendingCommandItem new];
    pending.cmd = cmd;
    pending.args = args;
    pending.sentTime = CACurrentMediaTime();
    [_pendingCommands addObject:pending];
    return NO;
}

- (BOOL)isUnknownCommandServerReply:(NSString *)rawText {
    NSString *clean = [StripSampColors(rawText) lowercaseString];
    if (clean.length == 0) return NO;
    return [clean containsString:@"unknown command"] ||
           [clean containsString:@"неизвестная команда"] ||
           [clean containsString:@"команда не найдена"] ||
           [clean containsString:@"такой команды не существует"] ||
           [clean containsString:@"такой команды нет"];
}

- (BOOL)dispatchServerMessage:(uint32_t)color text:(NSString *)text outColor:(uint32_t *)outColor outText:(NSString **)outText {
    _inGameSession = YES;
    if (!_L) return YES;

    if (_pendingCommands.count > 0 && [self isUnknownCommandServerReply:text]) {
        PendingCommandItem *matched = _pendingCommands.firstObject;
        [_pendingCommands removeObjectAtIndex:0];
        [_confirmedLocalCommands addObject:matched.cmd];
        LuaCommandItem *item = _commands[matched.cmd];
        if (item) {
            [self executeLuaCommand:item args:matched.args];
        }
        return NO;
    }

    BOOL allow = YES;
    auto invokeHandler = ^() {
        lua_pushinteger(_L, color);
        lua_pushstring(_L, [text UTF8String]);
        if (lua_pcall(_L, 2, 1, 0) == LUA_OK) {
            if (lua_isboolean(_L, -1) && !lua_toboolean(_L, -1)) {
                allow = NO;
            } else if (lua_istable(_L, -1)) {
                lua_geti(_L, -1, 1);
                if (lua_isinteger(_L, -1)) *outColor = (uint32_t)lua_tointeger(_L, -1);
                lua_pop(_L, 1);
                lua_geti(_L, -1, 2);
                if (lua_isstring(_L, -1)) *outText = [NSString stringWithUTF8String:lua_tostring(_L, -1)] ?: text;
                lua_pop(_L, 1);
            }
        }
        lua_pop(_L, 1);
    };

    lua_getglobal(_L, "onServerMessage");
    if (lua_isfunction(_L, -1)) {
        invokeHandler();
    } else {
        lua_pop(_L, 1);
    }

    for (LuaEventItem *ev in [_eventHooks copy]) {
        if ([ev.eventName isEqualToString:@"onServerMessage"]) {
            lua_rawgeti(_L, LUA_REGISTRYINDEX, ev.callbackRef);
            invokeHandler();
        }
    }
    return allow;
}

- (BOOL)dispatchShowDialog:(int)dialogId style:(int)style title:(NSString *)title btn1:(NSString *)btn1 btn2:(NSString *)btn2 text:(NSString *)text {
    _inGameSession = YES;
    if (!_L) return YES;
    BOOL allow = YES;

    auto invokeDialog = ^() {
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
        }
        lua_pop(_L, 1);
    };

    lua_getglobal(_L, "onShowDialog");
    if (lua_isfunction(_L, -1)) {
        invokeDialog();
    } else {
        lua_pop(_L, 1);
    }

    for (LuaEventItem *ev in [_eventHooks copy]) {
        if ([ev.eventName isEqualToString:@"onShowDialog"]) {
            lua_rawgeti(_L, LUA_REGISTRYINDEX, ev.callbackRef);
            invokeDialog();
        }
    }
    return allow;
}

- (UIWindow *)keyWindow {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (ws.windows.firstObject) return ws.windows.firstObject;
        }
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

- (void)setupOverlayUI {
    UIWindow *win = [self keyWindow];
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self setupOverlayUI];
        });
        return;
    }

    if (!_statusBanner) {
        _statusBanner = [[UIView alloc] init];
        _statusBanner.translatesAutoresizingMaskIntoConstraints = NO;
        _statusBanner.userInteractionEnabled = YES;
        [win addSubview:_statusBanner];

        _statusLabel = [[UILabel alloc] init];
        _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _statusLabel.textColor = [UIColor whiteColor];
        _statusLabel.font = [UIFont boldSystemFontOfSize:12];
        _statusLabel.textAlignment = NSTextAlignmentCenter;
        [_statusBanner addSubview:_statusLabel];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showSettingsWindow)];
        [_statusBanner addGestureRecognizer:tap];

        [NSLayoutConstraint activateConstraints:@[
            [_statusBanner.topAnchor constraintEqualToAnchor:win.safeAreaLayoutGuide.topAnchor constant:8],
            [_statusBanner.centerXAnchor constraintEqualToAnchor:win.centerXAnchor],
            [_statusBanner.heightAnchor constraintEqualToConstant:28],

            [_statusLabel.leadingAnchor constraintEqualToAnchor:_statusBanner.leadingAnchor constant:14],
            [_statusLabel.trailingAnchor constraintEqualToAnchor:_statusBanner.trailingAnchor constant:-14],
            [_statusLabel.centerYAnchor constraintEqualToAnchor:_statusBanner.centerYAnchor]
        ]];
    }

    if (!_floatingButton) {
        _floatingButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _floatingButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_floatingButton setTitle:@"42" forState:UIControlStateNormal];
        [_floatingButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _floatingButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [_floatingButton addTarget:self action:@selector(showSettingsWindow) forControlEvents:UIControlEventTouchUpInside];
        [win addSubview:_floatingButton];

        [NSLayoutConstraint activateConstraints:@[
            [_floatingButton.topAnchor constraintEqualToAnchor:win.safeAreaLayoutGuide.topAnchor constant:8],
            [_floatingButton.trailingAnchor constraintEqualToAnchor:win.safeAreaLayoutGuide.trailingAnchor constant:-12],
            [_floatingButton.widthAnchor constraintEqualToConstant:34],
            [_floatingButton.heightAnchor constraintEqualToConstant:28]
        ]];
    }

    [self applyThemeToOverlay];
}

- (void)applyThemeToOverlay {
    UIColor *accent = [self currentAccentColor];
    UIColor *bg = [[UIColor colorWithRed:0.08 green:0.04 blue:0.15 alpha:1.0] colorWithAlphaComponent:_uiAlpha];

    _statusBanner.backgroundColor = bg;
    _statusBanner.layer.cornerRadius = MIN(_cornerRadius, 14.0);
    _statusBanner.layer.borderWidth = 1.0;
    _statusBanner.layer.borderColor = [accent colorWithAlphaComponent:0.8].CGColor;

    _floatingButton.backgroundColor = bg;
    _floatingButton.layer.cornerRadius = MIN(_cornerRadius, 14.0);
    _floatingButton.layer.borderWidth = 1.0;
    _floatingButton.layer.borderColor = [accent colorWithAlphaComponent:0.8].CGColor;
    _floatingButton.hidden = !_showFloatingBtn;
}

- (void)showSettingsWindow {
    if (_settingsVC) return;
    [self scanScriptsOnly];
    UIWindow *win = [self keyWindow];
    UIViewController *root = win.rootViewController;
    while (root.presentedViewController) {
        root = root.presentedViewController;
    }
    LoaderSettingsVC *vc = [[LoaderSettingsVC alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    _settingsVC = vc;
    [root presentViewController:vc animated:YES completion:nil];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    if (@available(iOS 14.0, *)) {
        completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
    } else {
        completionHandler(UNNotificationPresentationOptionAlert | UNNotificationPresentationOptionSound);
    }
}

@end

static IMP orig_sendAction = NULL;
static void swizzled_sendAction(id self, SEL _cmd, SEL action, id target, UIEvent *event) {
    if ([self isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)self;
        NSString *title = [btn currentTitle] ?: btn.titleLabel.text ?: @"";
        NSString *lower = [title lowercaseString];
        if ([lower containsString:@"играть"] || [lower containsString:@"play"]) {
            [[LoaderEngine shared] triggerStageTwoIfNeeded];
        }
    }
    ((void (*)(id, SEL, SEL, id, UIEvent *))orig_sendAction)(self, _cmd, action, target, event);
}

static IMP orig_textFieldShouldReturn = NULL;
static BOOL swizzled_textFieldShouldReturn(id self, SEL _cmd, UITextField *textField) {
    if (textField.text.length > 0 && [[LoaderEngine shared] handleOutgoingInput:textField.text]) {
        textField.text = @"";
        [textField resignFirstResponder];
        return NO;
    }
    if (orig_textFieldShouldReturn) {
        return ((BOOL (*)(id, SEL, UITextField *))orig_textFieldShouldReturn)(self, _cmd, textField);
    }
    return YES;
}

static void on_dyld_image_added(const struct mach_header *header, intptr_t slide) {
    Dl_info info;
    if (dladdr(header, &info) && info.dli_fname) {
        if (strstr(info.dli_fname, "libag-client") != NULL) {
            [[LoaderEngine shared] triggerStageTwoIfNeeded];
        }
    }
}

__attribute__((constructor))
static void initializer() {
    Method mSend = class_getInstanceMethod([UIControl class], @selector(sendAction:to:forEvent:));
    if (mSend) {
        orig_sendAction = method_setImplementation(mSend, (IMP)swizzled_sendAction);
    }

    register_rebinding("AddClientCommand", (void *)hooked_AddClientCommand, (void **)&orig_AddClientCommand);
    register_rebinding("_Z16AddClientCommandPKcPFvPcE", (void *)hooked_AddClientCommand, (void **)&orig_AddClientCommand);
    register_rebinding("AddChatMessage", (void *)hooked_AddChatMessage, (void **)&orig_AddChatMessage);
    register_rebinding("_Z14AddChatMessagejPKc", (void *)hooked_AddChatMessage, (void **)&orig_AddChatMessage);
    register_rebinding("ShowDialog", (void *)hooked_ShowDialog, (void **)&orig_ShowDialog);

    _dyld_register_func_for_add_image(on_dyld_image_added);

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        [[LoaderEngine shared] bootStageOne];
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:UITextFieldTextDidBeginEditingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        UITextField *tf = note.object;
        id del = tf.delegate;
        if (del && !orig_textFieldShouldReturn) {
            Method mRet = class_getInstanceMethod([del class], @selector(textFieldShouldReturn:));
            if (mRet) {
                orig_textFieldShouldReturn = method_setImplementation(mRet, (IMP)swizzled_textFieldShouldReturn);
            }
        }
    }];
}
