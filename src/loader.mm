#include <dlfcn.h>
#include <stdint.h>

typedef const char* (*GetStringUTFChars_t)(void* env, void* str, uint8_t* isCopy);
typedef void (*ReleaseStringUTFChars_t)(void* env, void* str, const char* chars);
typedef void (*OnInputEnd_t)(void* env, void* thiz, void* text);

static uintptr_t DummyJniStub(void) { return 0; }

static const char* FakeGetStringUTFChars(void* env, void* str, uint8_t* isCopy) {
    if (isCopy) *isCopy = 0;
    return (const char*)str;
}

static void FakeReleaseStringUTFChars(void* env, void* str, const char* chars) {}

static void* GetSafeJniEnv() {
    static void* vtable[256];
    static void* envPtr = nullptr;
    if (!envPtr) {
        for (int i = 0; i < 256; i++) {
            vtable[i] = (void*)&DummyJniStub;
        }
        vtable[169] = (void*)&FakeGetStringUTFChars;      // 0x548: GetStringUTFChars
        vtable[170] = (void*)&FakeReleaseStringUTFChars;  // 0x550: ReleaseStringUTFChars
        envPtr = (void*)vtable;
    }
    return envPtr;
}

void NativeSendChat(const char* utf8Text) {
    if (!utf8Text || !utf8Text[0]) return;
    static OnInputEnd_t fnOnInputEnd = nullptr;
    if (!fnOnInputEnd) {
        fnOnInputEnd = (OnInputEnd_t)dlsym(RTLD_DEFAULT, "Java_com_arizona_game_GTASA_OnInputEnd");
    }
    if (!fnOnInputEnd) return;

    NSString* copyStr = [NSString stringWithUTF8String:utf8Text];
    dispatch_async(dispatch_get_main_queue(), ^{
        fnOnInputEnd(GetSafeJniEnv(), nullptr, (void*)[copyStr UTF8String]);
    });
}
