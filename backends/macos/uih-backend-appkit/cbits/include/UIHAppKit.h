#ifndef UIH_APPKIT_H
#define UIH_APPKIT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *UIHMacWindowRef;
typedef void *UIHMacControlRef;

typedef enum UIHMacEventKind {
  UIHMacEventCommand = 1,
  UIHMacEventTextChanged = 2,
  UIHMacEventWindowCloseRequested = 3,
  UIHMacEventWindowActivated = 4,
  UIHMacEventTextFileChosen = 5
} UIHMacEventKind;

typedef void (*UIHMacEventCallback)(
    void *context,
    int32_t event_kind,
    uint64_t identity,
    const char *utf8_text);

typedef struct UIHMacRect {
  double x;
  double y;
  double width;
  double height;
} UIHMacRect;

typedef enum UIHMacTextStyleField {
  UIHMacTextStyleForeground = 1u << 0,
  UIHMacTextStyleBackground = 1u << 1,
  UIHMacTextStyleFontFamily = 1u << 2,
  UIHMacTextStyleFontSize = 1u << 3,
  UIHMacTextStyleFontWeight = 1u << 4,
  UIHMacTextStyleFontSlant = 1u << 5,
  UIHMacTextStyleUnderline = 1u << 6,
  UIHMacTextStyleStrikethrough = 1u << 7,
  UIHMacTextStyleLetterSpacing = 1u << 8,
  UIHMacTextStyleBaselineOffset = 1u << 9
} UIHMacTextStyleField;

typedef struct UIHMacTextStyle {
  uint32_t fields;
  int32_t font_family_kind;
  int32_t font_weight;
  int32_t font_slant;
  int32_t underline_style;
  int32_t strikethrough;
  double foreground_red;
  double foreground_green;
  double foreground_blue;
  double foreground_alpha;
  double background_red;
  double background_green;
  double background_blue;
  double background_alpha;
  double font_size;
  double letter_spacing;
  double baseline_offset;
  const char *utf8_font_family;
} UIHMacTextStyle;

typedef struct UIHMacDebugCounters {
  int32_t windows;
  int32_t controls;
  int32_t action_targets;
  int32_t window_delegates;
  int32_t queued_callbacks;
  int32_t test_failures;
} UIHMacDebugCounters;

int32_t uih_macos_initialize(UIHMacEventCallback callback, void *context);
void uih_macos_run(void);
void uih_macos_stop(void);
void uih_macos_shutdown(void);

int32_t uih_macos_version_major(void);
int32_t uih_macos_version_minor(void);
int32_t uih_macos_version_patch(void);

UIHMacWindowRef uih_macos_window_create(
    uint64_t identity,
    const char *utf8_title,
    const UIHMacRect *frame);
void uih_macos_window_set_title(
    UIHMacWindowRef window,
    const char *utf8_title);
void uih_macos_window_set_frame(UIHMacWindowRef window, const UIHMacRect *frame);
void uih_macos_window_show(UIHMacWindowRef window);
void uih_macos_window_destroy(UIHMacWindowRef window);

UIHMacControlRef uih_macos_label_create(
    UIHMacWindowRef window,
    uint64_t identity,
    const char *utf8_text,
    const UIHMacRect *frame);
UIHMacControlRef uih_macos_button_create(
    UIHMacWindowRef window,
    uint64_t identity,
    const char *utf8_title,
    uint64_t command_identity,
    const UIHMacRect *frame);
UIHMacControlRef uih_macos_text_field_create(
    UIHMacWindowRef window,
    uint64_t identity,
    const char *utf8_text,
    const char *utf8_placeholder,
    const UIHMacRect *frame);
UIHMacControlRef uih_macos_text_editor_create(
    UIHMacWindowRef window,
    uint64_t identity,
    const char *utf8_text,
    const UIHMacRect *frame);
void uih_macos_control_set_text(
    UIHMacControlRef control,
    const char *utf8_text);
void uih_macos_text_editor_begin_presentation(UIHMacControlRef control);
void uih_macos_text_editor_set_base_style(
    UIHMacControlRef control,
    const UIHMacTextStyle *style);
int32_t uih_macos_text_editor_apply_style(
    UIHMacControlRef control,
    uint64_t utf16_location,
    uint64_t utf16_length,
    const UIHMacTextStyle *style);
void uih_macos_text_editor_end_presentation(UIHMacControlRef control);
void uih_macos_control_set_frame(UIHMacControlRef control, const UIHMacRect *frame);
void uih_macos_control_set_enabled(UIHMacControlRef control, int32_t enabled);
void uih_macos_control_focus(UIHMacWindowRef window, UIHMacControlRef control);
void uih_macos_control_set_next_key(
    UIHMacControlRef control,
    UIHMacControlRef next_control);
void uih_macos_control_destroy(UIHMacControlRef control);

void uih_macos_command_set(
    uint64_t identity,
    const char *utf8_title,
    const char *utf8_key_equivalent,
    int32_t enabled);
void uih_macos_command_remove(uint64_t identity);
void uih_macos_open_text_files(void);

/* Diagnostic API used by the native backend's deterministic integration test. */
void uih_macos_debug_counters(UIHMacDebugCounters *counters);
const char *uih_macos_test_last_failure(void);
void uih_macos_test_schedule_vertical_script(
    uint64_t main_window_identity,
    uint64_t name_field_identity,
    uint64_t greeting_label_identity,
    uint64_t save_command_identity);
void uih_macos_test_schedule_text_editor_script(
    uint64_t document_window_identity,
    uint64_t editor_identity,
    uint64_t save_command_identity);

#ifdef __cplusplus
}
#endif

#endif
