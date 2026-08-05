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
  UIHMacEventWindowCloseRequested = 3
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
void uih_macos_control_set_text(
    UIHMacControlRef control,
    const char *utf8_text);
void uih_macos_control_set_frame(UIHMacControlRef control, const UIHMacRect *frame);
void uih_macos_control_set_enabled(UIHMacControlRef control, int32_t enabled);
void uih_macos_control_focus(UIHMacWindowRef window, UIHMacControlRef control);
void uih_macos_control_destroy(UIHMacControlRef control);

void uih_macos_command_set(
    uint64_t identity,
    const char *utf8_title,
    const char *utf8_key_equivalent,
    int32_t enabled);
void uih_macos_command_remove(uint64_t identity);

#ifdef __cplusplus
}
#endif

#endif
