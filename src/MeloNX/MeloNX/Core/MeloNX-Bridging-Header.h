//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//


#ifndef MeloNX_BridgingHeader_h
#define MeloNX_BridgingHeader_h

#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <Foundation/Foundation.h>
#include <setjmp.h>
#include <stdbool.h>
#include <signal.h>
#include <stdint.h>
#include "Models/Options/NativeOptions.h" 
#include "Memory/MLXRamDonor.h"
#include <IOKit/IOKitLib.h>

struct GameInfoC {
    long FileSize;
    char TitleName[512];
    char TitleId[32];
    char Developer[256];
    char Version[16];
    unsigned char* ImageData;
    unsigned int ImageSize;
};

struct DlcNcaListItemC {
    char Path[256];
    unsigned long long TitleId;
};

struct DlcNcaListC {
    bool success;
    unsigned int size;
    struct DlcNcaListItemC* items;
};

struct SaveDataPathC {
    bool success;
    char* value;
};

struct AvatarArrayC {
    int Count;
    struct AvatarInfoC* Avatars;
};

struct AvatarInfoC {
    unsigned char* ImageData;
    int ImageSize;
    char* FileName;
};



typedef void (*DataCallbackFn)(const void* data, void* userData);

typedef struct {
    void*   ptr;
    int32_t len;
} CallbackData;

void RegisterCallback(const char* name, DataCallbackFn callback, void* userData);
void UnregisterCallback(const char* name);

uint8_t InvokeCallback(const char* name, const void* data, int32_t len);

uint64_t execute_function_pointer(void* functionPtr);

void report_memory_pressure(uint8_t critical);

void offer_donated_memory(void* baseAddress, uint64_t size);

void withdraw_donated_memory(void);

uint8_t offer_donated_gpu_memory(void* baseAddress, uint64_t size);
uint8_t withdraw_donated_gpu_memory(void);
uint64_t execute_guest_function_pointer(void* functionPtr, void* nativeContextPtr);

#endif /* MeloNX_BridgingHeader_h */
