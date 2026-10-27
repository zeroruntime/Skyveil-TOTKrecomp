/* Host-native, export-only driver for the existing version-specific patchers.
   This process treats ARM64 instructions as bytes; it never calls into game code. */
#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200112L
#include "runtime.h"
#include "game_patches.h"
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

pthread_key_t runtime_keys[8];

_Noreturn void runtime_fail(const char *message) {
    fprintf(stderr, "[ios-export] FAIL: %s\n", message);
    exit(1);
}

/* Survey setup is a test-profile runtime feature. The iOS exporter only emits
   guarded game-code patches and never creates a live game session. */
void runtime_survey_init(Module *module) { (void)module; }

/* The export-only driver has no relocated symbol table. iOS does not emit the
   optional Vert+ stubs, so the shared aspect patcher treats these lookups as
   unavailable and keeps the supported screen-fit path. */
void *runtime_symbol(const char *name) { (void)name; return NULL; }

/* These services are used by runtime settings after the game starts. The
   export path only calls runtime_game_patches(), whose patch creation does not
   call them; keep the patcher translation unit linkable without the runtime. */
void runtime_oe_push_message(uint32_t message) { (void)message; }
void dm_gfx_set_flag(const char *name, int value) { (void)name; (void)value; }
int mfxup_output_enabled(void) { return 0; }
int mfxup_enabled(void) { return 0; }

static uint64_t number(const char *text, const char *field) {
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno || end == text || *end) {
        fprintf(stderr, "[ios-export] invalid %s: %s\n", field, text);
        exit(2);
    }
    return (uint64_t)value;
}

static void need(int condition, const char *message) {
    if (!condition) runtime_fail(message);
}

int main(int argc, char **argv) {
    need(argc == 9, "usage: export-ios-helper IMAGE OUTPUT FILE_SIZE TEXT_END RO_OFF DATA_OFF PATCH_OFF KEY_OFF");
    const uint64_t file_size = number(argv[3], "file size");
    const uint64_t text_end = number(argv[4], "text end");
    const uint64_t ro_off = number(argv[5], "read-only offset");
    const uint64_t data_off = number(argv[6], "data offset");
    const uint64_t patch_off = number(argv[7], "patch offset");
    const uint64_t key_off = number(argv[8], "key offset");
    need(file_size > 0 && file_size < SIZE_MAX - 0x8000, "main image size");
    const size_t padded_file_size = (size_t)((file_size + 0x3fff) & ~0x3fffULL);
    const size_t text_size = (size_t)((text_end + 0x3fff) & ~0x3fffULL);
    const size_t module_size = padded_file_size + 0x4000;
    need(text_end <= file_size && text_size <= patch_off && patch_off <= padded_file_size,
         "main embedded module layout");
    need(!(key_off & 0x3fff) && key_off + 0x4000 <= patch_off && patch_off < module_size,
         "main key and patch layout");

    FILE *input = fopen(argv[1], "rb");
    need(input != NULL, "open verified main image");
    struct stat status;
    need(fstat(fileno(input), &status) == 0 && (uint64_t)status.st_size == file_size,
         "verified main image size changed");
    uint8_t *base = NULL;
    need(posix_memalign((void **)&base, 0x4000, module_size) == 0,
         "16 KB aligned main image memory");
    memset(base, 0, module_size);
    need(((uintptr_t)base & 0x3fff) == 0, "main image is not 16 KB aligned");
    need(fread(base, 1, (size_t)file_size, input) == file_size && fclose(input) == 0,
         "read verified main image");

    Module main_module = {
        .name = "main",
        .file_size = (size_t)file_size,
        .size = module_size,
        .text_end = text_end,
        .ro_off = ro_off,
        .data_off = data_off,
        .patch_off = patch_off,
        .key_off = key_off,
        .base = base,
    };
    runtime_game_patches(&main_module);

    FILE *output = fopen(argv[2], "wb");
    need(output != NULL, "create patched main image");
    need(fwrite(base, 1, (size_t)file_size, output) == file_size && fclose(output) == 0,
         "write patched main image");
    free(base);
    return 0;
}
