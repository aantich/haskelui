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
  UIHMacEventTextFileChosen = 5,
  UIHMacEventTabSelected = 6,
  UIHMacEventTabCloseRequested = 7,
  UIHMacEventControlInvoked = 8,
  UIHMacEventToggleChanged = 9,
  UIHMacEventChoiceChanged = 10,
  UIHMacEventNumberChanged = 11,
  UIHMacEventDateChanged = 12,
  UIHMacEventTimeChanged = 13,
  UIHMacEventColorChanged = 14,
  UIHMacEventCollectionSelectionChanged = 15,
  UIHMacEventDisclosureChanged = 16,
  UIHMacEventPresentationClosed = 17,
  UIHMacEventCollectionExpansionChanged = 18
} UIHMacEventKind;

typedef enum UIHMacCatalogControlKind {
  UIHMacCatalogRichText = 1,
  UIHMacCatalogImage = 2,
  UIHMacCatalogIcon = 3,
  UIHMacCatalogSeparator = 4,
  UIHMacCatalogRepeatButton = 5,
  UIHMacCatalogToggleButton = 6,
  UIHMacCatalogCheckBox = 7,
  UIHMacCatalogRadioGroup = 8,
  UIHMacCatalogSwitch = 9,
  UIHMacCatalogSegmentedChoice = 10,
  UIHMacCatalogLink = 11,
  UIHMacCatalogMenuButton = 12,
  UIHMacCatalogSplitButton = 13,
  UIHMacCatalogToggleSplitButton = 14,
  UIHMacCatalogTextArea = 15,
  UIHMacCatalogRichTextEditor = 16,
  UIHMacCatalogSecureField = 17,
  UIHMacCatalogSearchField = 18,
  UIHMacCatalogSuggestField = 19,
  UIHMacCatalogChoicePicker = 20,
  UIHMacCatalogEditableComboBox = 21,
  UIHMacCatalogNumberField = 22,
  UIHMacCatalogStepper = 23,
  UIHMacCatalogSlider = 24,
  UIHMacCatalogDatePicker = 25,
  UIHMacCatalogTimePicker = 26,
  UIHMacCatalogCalendarView = 27,
  UIHMacCatalogColorPicker = 28,
  UIHMacCatalogRating = 29,
  UIHMacCatalogListView = 30,
  UIHMacCatalogCollectionView = 31,
  UIHMacCatalogTreeView = 32,
  UIHMacCatalogTableView = 33,
  UIHMacCatalogItemRepeater = 34,
  UIHMacCatalogTabView = 35,
  UIHMacCatalogBreadcrumb = 36,
  UIHMacCatalogNavigationSidebar = 37,
  UIHMacCatalogMenuBar = 38,
  UIHMacCatalogContextMenu = 39,
  UIHMacCatalogToolbar = 40,
  UIHMacCatalogDialog = 41,
  UIHMacCatalogAlert = 42,
  UIHMacCatalogPopover = 43,
  UIHMacCatalogTooltip = 44,
  UIHMacCatalogProgressBar = 45,
  UIHMacCatalogActivityIndicator = 46,
  UIHMacCatalogMeter = 47,
  UIHMacCatalogBadge = 48,
  UIHMacCatalogInlineNotice = 49,
  UIHMacCatalogContainer = 50
} UIHMacCatalogControlKind;

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

void uih_macos_workspace_begin(
    UIHMacWindowRef window,
    int32_t side_by_side,
    double status_height);
void uih_macos_workspace_pane_set(
    UIHMacWindowRef window,
    uint64_t pane_identity,
    int32_t pane_role,
    double preferred_extent,
    int32_t collapsed);
void uih_macos_workspace_item_set(
    UIHMacWindowRef window,
    uint64_t pane_identity,
    uint64_t item_identity);
void uih_macos_workspace_tab_group_set(
    UIHMacWindowRef window,
    uint64_t item_identity,
    uint64_t group_identity);
void uih_macos_workspace_tab_set(
    UIHMacWindowRef window,
    uint64_t group_identity,
    uint64_t tab_identity,
    const char *utf8_title,
    int32_t modified,
    int32_t closeable,
    int32_t selected);
void uih_macos_workspace_end(UIHMacWindowRef window);

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
UIHMacControlRef uih_macos_catalog_control_create(
    UIHMacWindowRef window,
    uint64_t identity,
    int32_t catalog_kind,
    const UIHMacRect *frame);
void uih_macos_catalog_control_set_primary_text(
    UIHMacControlRef control,
    const char *utf8_text);
void uih_macos_catalog_control_set_secondary_text(
    UIHMacControlRef control,
    const char *utf8_text);
void uih_macos_catalog_control_set_state(
    UIHMacControlRef control,
    int32_t state);
void uih_macos_catalog_control_set_numeric(
    UIHMacControlRef control,
    double value,
    double minimum,
    double maximum,
    double step);
void uih_macos_catalog_control_set_color(
    UIHMacControlRef control,
    double red,
    double green,
    double blue,
    double alpha);
void uih_macos_catalog_control_set_date_time(
    UIHMacControlRef control,
    int32_t year,
    int32_t month,
    int32_t day,
    int32_t hour,
    int32_t minute,
    int32_t second);
void uih_macos_catalog_control_set_command(
    UIHMacControlRef control,
    uint64_t command_identity);
void uih_macos_catalog_control_begin_items(UIHMacControlRef control);
void uih_macos_catalog_control_add_item(
    UIHMacControlRef control,
    uint64_t item_identity,
    const char *utf8_label,
    const char *utf8_detail,
    int32_t depth,
    int32_t flags,
    uint64_t command_identity);
void uih_macos_catalog_control_end_items(UIHMacControlRef control);
void uih_macos_catalog_control_set_tooltip(
    UIHMacControlRef control,
    const char *utf8_tooltip);
void uih_macos_catalog_control_set_presentation(
    UIHMacControlRef control,
    int32_t visible,
    uint64_t anchor_identity);
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
void uih_macos_control_set_parent_item(
    UIHMacWindowRef window,
    UIHMacControlRef control,
    uint64_t item_identity,
    int32_t fill_parent);
void uih_macos_control_set_parent_tab(
    UIHMacWindowRef window,
    UIHMacControlRef control,
    uint64_t group_identity,
    uint64_t tab_identity,
    int32_t fill_parent);
void uih_macos_control_set_parent_status(
    UIHMacWindowRef window,
    UIHMacControlRef control,
    int32_t fill_parent);
void uih_macos_control_set_parent_control(
    UIHMacControlRef parent,
    UIHMacControlRef child,
    uint64_t slot_identity,
    int32_t fill_parent);
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
    uint64_t tab_identity,
    uint64_t save_command_identity);
void uih_macos_test_schedule_control_gallery_script(
    uint64_t window_identity,
    uint64_t root_tab_identity,
    uint64_t text_input_identity,
    uint64_t text_mirror_identity,
    uint64_t toggle_identity,
    uint64_t choice_identity,
    uint64_t numeric_identity,
    uint64_t collection_identity,
    uint64_t dialog_button_identity,
    uint64_t dialog_identity,
    uint64_t popover_button_identity,
    uint64_t popover_identity,
    uint64_t container_identity,
    uint64_t nested_child_identity);

#ifdef __cplusplus
}
#endif

#endif
