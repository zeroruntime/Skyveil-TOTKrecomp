// runtime/gamepad_layout.h: which controllers map their face buttons by position, and the resulting Switch buttons.
#include <stdio.h>
#include "gamepad_layout.h"
#include "controller_map.h"

static int failures, checked;
static void check(int ok, const char *what) { checked++; if (!ok) { failures++; fprintf(stderr, "FAIL: %s\n", what); } }

static uint64_t switch_face_for(int type, const char *category, const char *vendor, int a, int b, int x, int y) {
    uint64_t physical = gamepad_face_positions(a, b, x, y,
        gamepad_type_face_by_position(type, category, vendor));
    if (gamepad_face_layout_swap_from_environment()) physical = gamepad_invert_face_layout(physical);
    uint16_t map[CONTROLLER_BUTTONS]; uint8_t modes[CONTROLLER_BUTTONS];
    controller_map_default(map, modes);
    return controller_map_apply(map, physical) & 0x0f;
}

int main(void) {
    unsetenv("TOTK_FACE_BUTTONS");
    check(gamepad_face_by_position("DualSense", "DualSense Wireless Controller"), "DualSense by position");
    check(gamepad_face_by_position("DualShock 4", "Wireless Controller"), "DualShock 4 by position");
    check(gamepad_face_by_position("Xbox One", "Xbox Wireless Controller"), "Xbox by position");
    check(gamepad_face_by_position("MFi", "8BitDo SN30 Pro"), "an MFi (Xbox-style) controller by position");
    check(!gamepad_face_by_position("Switch Pro Controller", "Pro Controller"), "Switch Pro Controller by label");
    check(!gamepad_face_by_position("Nintendo Switch Joy-Con (L/R)", "Joy-Con (L/R)"), "Joy-Con by label");
    check(gamepad_face_by_position(NULL, NULL), "an unnamed controller by position");
    // by position: Circle / Xbox B (right) is A, Cross / Xbox A (bottom) is B, Triangle / Y (top) is X, Square / X (left) is Y
    check(gamepad_face_bits(0, 1, 0, 0, 1) == GAMEPAD_SWITCH_A, "right button is Switch A");
    check(gamepad_face_bits(1, 0, 0, 0, 1) == GAMEPAD_SWITCH_B, "bottom button is Switch B");
    check(gamepad_face_bits(0, 0, 0, 1, 1) == GAMEPAD_SWITCH_X, "top button is Switch X");
    check(gamepad_face_bits(0, 0, 1, 0, 1) == GAMEPAD_SWITCH_Y, "left button is Switch Y");
    check(gamepad_face_bits(1, 1, 1, 1, 1) == 15 && gamepad_face_bits(0, 0, 0, 0, 1) == 0, "all and none");
    // by label: GameController's buttonA..Y straight to A..Y
    check(gamepad_face_bits(1, 0, 0, 0, 0) == GAMEPAD_SWITCH_A && gamepad_face_bits(0, 1, 0, 0, 0) == GAMEPAD_SWITCH_B &&
          gamepad_face_bits(0, 0, 1, 0, 0) == GAMEPAD_SWITCH_X && gamepad_face_bits(0, 0, 0, 1, 0) == GAMEPAD_SWITCH_Y, "by label");
    setenv("TOTK_FACE_BUTTONS", "label", 1);
    check(!gamepad_face_by_position("DualSense", "DualSense Wireless Controller"), "TOTK_FACE_BUTTONS=label");
    setenv("TOTK_FACE_BUTTONS", "position", 1);
    check(gamepad_face_by_position("Switch Pro Controller", "Pro Controller"), "TOTK_FACE_BUTTONS=position");
    // the settings panel's controller type (auto, Xbox, PlayStation, Switch), saved as one word
    unsetenv("TOTK_FACE_BUTTONS");
    for (int t = 0; t < GAMEPAD_TYPE_COUNT; t++) check(gamepad_type_parse(gamepad_type_name(t)) == t, "every type name parses back");
    check(gamepad_type_parse("  switch\n") == GAMEPAD_TYPE_SWITCH && gamepad_type_parse("xbox\r\n") == GAMEPAD_TYPE_XBOX, "the saved word may end in a newline");
    check(gamepad_type_parse("ps5") < 0 && gamepad_type_parse("") < 0 && gamepad_type_parse(NULL) < 0 && gamepad_type_parse("switchx") < 0,
          "anything else is not a type");
    check(gamepad_type_detect("DualSense", "DualSense Wireless Controller") == GAMEPAD_TYPE_PLAYSTATION, "DualSense is detected as PlayStation");
    check(gamepad_type_detect("DualShock 4", "Wireless Controller") == GAMEPAD_TYPE_PLAYSTATION, "DualShock 4 is detected as PlayStation");
    check(gamepad_type_detect("Switch Pro Controller", "Pro Controller") == GAMEPAD_TYPE_SWITCH, "Switch Pro is detected as Switch");
    check(gamepad_type_detect("Xbox One", "Xbox Wireless Controller") == GAMEPAD_TYPE_XBOX, "Xbox is detected as Xbox");
    check(gamepad_type_detect("MFi", "8BitDo SN30 Pro") == GAMEPAD_TYPE_XBOX && gamepad_type_detect(NULL, NULL) == GAMEPAD_TYPE_XBOX,
          "other controllers count as Xbox (GameController names their buttons that way)");
    check(gamepad_type_face_by_position(GAMEPAD_TYPE_XBOX, "Switch Pro Controller", "Pro Controller"), "type Xbox: by position, whatever the name");
    check(gamepad_type_face_by_position(GAMEPAD_TYPE_PLAYSTATION, "Switch Pro Controller", "Pro Controller"), "type PlayStation: by position");
    check(!gamepad_type_face_by_position(GAMEPAD_TYPE_SWITCH, "Xbox One", "Xbox Wireless Controller"), "type Switch: by label, whatever the name");
    check(gamepad_type_face_by_position(GAMEPAD_TYPE_AUTO, "Xbox One", "Xbox Wireless Controller") &&
          !gamepad_type_face_by_position(GAMEPAD_TYPE_AUTO, "Switch Pro Controller", "Pro Controller"), "type auto: as detected");
    setenv("TOTK_FACE_BUTTONS", "label", 1);
    check(!gamepad_type_face_by_position(GAMEPAD_TYPE_AUTO, "Xbox One", "Xbox Wireless Controller"), "type auto keeps TOTK_FACE_BUTTONS");
    check(gamepad_type_face_by_position(GAMEPAD_TYPE_XBOX, "Xbox One", "Xbox Wireless Controller"), "a picked type wins over TOTK_FACE_BUTTONS");
    unsetenv("TOTK_FACE_BUTTONS");

    /* The optional final layout swap is an exact opt-in and leaves all non-face bits alone. */
    unsetenv("TOTK_SWAP_CONTROLLER_LAYOUT");
    check(!gamepad_face_layout_swap_from_environment(), "the face layout swap defaults off");
    setenv("TOTK_SWAP_CONTROLLER_LAYOUT", "0", 1);
    check(!gamepad_face_layout_swap_from_environment(), "TOTK_SWAP_CONTROLLER_LAYOUT=0 is off");
    setenv("TOTK_SWAP_CONTROLLER_LAYOUT", "1", 1);
    check(gamepad_face_layout_swap_from_environment(), "TOTK_SWAP_CONTROLLER_LAYOUT=1 is on");
    check(!gamepad_face_layout_swap_enabled("true") && !gamepad_face_layout_swap_enabled("01") &&
          !gamepad_face_layout_swap_enabled(NULL), "only the exact value 1 enables the swap");
    const uint64_t nonface = (1ULL << 4) | (1ULL << 8) | (1ULL << 16) | (1ULL << 31) | (1ULL << 63);
    for (uint64_t faces = 0; faces < 16; faces++) {
        uint64_t physical = nonface | faces;
        uint64_t expected = ((faces & 1) << 1) | ((faces & 2) >> 1) | ((faces & 4) << 1) | ((faces & 8) >> 1);
        uint64_t swapped = gamepad_invert_face_layout(physical);
        check((swapped & 0x0f) == expected, "all face-button combinations swap A/B and X/Y");
        check((swapped & ~0x0f) == nonface, "face swap leaves all non-face buttons unchanged");
        check(gamepad_invert_face_layout(swapped) == physical, "face swap is an involution");
    }

    /* Verify the final swap after the existing Auto/type/label-vs-position choice and default physical layout. */
    unsetenv("TOTK_SWAP_CONTROLLER_LAYOUT");
    check(switch_face_for(GAMEPAD_TYPE_AUTO, "DualSense", "DualSense Wireless Controller", 1, 0, 0, 0) == GAMEPAD_SWITCH_B,
          "Sony Auto keeps its existing position mapping when swap is off");
    check(switch_face_for(GAMEPAD_TYPE_AUTO, "Switch Pro Controller", "Pro Controller", 1, 0, 0, 0) == GAMEPAD_SWITCH_A,
          "Nintendo Auto keeps its existing label mapping when swap is off");
    setenv("TOTK_SWAP_CONTROLLER_LAYOUT", "0", 1);
    check(switch_face_for(GAMEPAD_TYPE_AUTO, "DualSense", "DualSense Wireless Controller", 1, 0, 0, 0) == GAMEPAD_SWITCH_B,
          "an explicit zero preserves the existing position mapping");
    setenv("TOTK_SWAP_CONTROLLER_LAYOUT", "1", 1);
    check(switch_face_for(GAMEPAD_TYPE_AUTO, "DualSense", "DualSense Wireless Controller", 1, 0, 0, 0) == GAMEPAD_SWITCH_A,
          "Sony Auto swaps its mapped A/B result");
    check(switch_face_for(GAMEPAD_TYPE_AUTO, "Switch Pro Controller", "Pro Controller", 1, 0, 0, 0) == GAMEPAD_SWITCH_B,
          "Nintendo Auto keeps label mapping before the final swap");
    check(switch_face_for(GAMEPAD_TYPE_SWITCH, "DualSense", "DualSense Wireless Controller", 1, 0, 0, 0) == GAMEPAD_SWITCH_B,
          "explicit Switch type keeps label mapping before the final swap");
    check(switch_face_for(GAMEPAD_TYPE_XBOX, "Switch Pro Controller", "Pro Controller", 1, 0, 0, 0) == GAMEPAD_SWITCH_A,
          "explicit Xbox type keeps position mapping before the final swap");

    setenv("TOTK_FACE_BUTTONS", "label", 1);
    check(switch_face_for(GAMEPAD_TYPE_AUTO, "DualSense", "DualSense Wireless Controller", 1, 0, 0, 0) == GAMEPAD_SWITCH_B,
          "the final swap follows the existing TOTK_FACE_BUTTONS=label override");
    setenv("TOTK_FACE_BUTTONS", "position", 1);
    check(switch_face_for(GAMEPAD_TYPE_AUTO, "Switch Pro Controller", "Pro Controller", 1, 0, 0, 0) == GAMEPAD_SWITCH_A,
          "the final swap follows the existing TOTK_FACE_BUTTONS=position override");
    unsetenv("TOTK_FACE_BUTTONS");
    unsetenv("TOTK_SWAP_CONTROLLER_LAYOUT");
    printf("{\"status\":\"%s\",\"probe\":\"gamepad-layout\",\"checked\":%d,\"failures\":%d}\n", failures ? "fail" : "pass", checked, failures);
    return failures != 0;
}
