#ifndef HaskeLUI_APPKIT_H
#define HaskeLUI_APPKIT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *HaskeLUIMacWindowRef;
typedef void *HaskeLUIMacControlRef;

typedef enum HaskeLUIMacEventKind {
  HaskeLUIMacEventCommand = 1,
  HaskeLUIMacEventTextChanged = 2,
  HaskeLUIMacEventWindowCloseRequested = 3,
  HaskeLUIMacEventWindowActivated = 4,
  HaskeLUIMacEventTextFileChosen = 5,
  HaskeLUIMacEventTabSelected = 6,
  HaskeLUIMacEventTabCloseRequested = 7,
  HaskeLUIMacEventControlInvoked = 8,
  HaskeLUIMacEventToggleChanged = 9,
  HaskeLUIMacEventChoiceChanged = 10,
  HaskeLUIMacEventNumberChanged = 11,
  HaskeLUIMacEventDateChanged = 12,
  HaskeLUIMacEventTimeChanged = 13,
  HaskeLUIMacEventColorChanged = 14,
  HaskeLUIMacEventCollectionSelectionChanged = 15,
  HaskeLUIMacEventDisclosureChanged = 16,
  HaskeLUIMacEventPresentationClosed = 17,
  HaskeLUIMacEventCollectionExpansionChanged = 18,
  HaskeLUIMacEventProjectFolderChosen = 19,
  /* Backend-private wakeup; it is never exposed as a HaskeLUI UIEvent. */
  HaskeLUIMacEventRuntimeWake = 20
} HaskeLUIMacEventKind;

typedef enum HaskeLUIMacCatalogControlKind {
  HaskeLUIMacCatalogRichText = 1,
  HaskeLUIMacCatalogImage = 2,
  HaskeLUIMacCatalogIcon = 3,
  HaskeLUIMacCatalogSeparator = 4,
  HaskeLUIMacCatalogRepeatButton = 5,
  HaskeLUIMacCatalogToggleButton = 6,
  HaskeLUIMacCatalogCheckBox = 7,
  HaskeLUIMacCatalogRadioGroup = 8,
  HaskeLUIMacCatalogSwitch = 9,
  HaskeLUIMacCatalogSegmentedChoice = 10,
  HaskeLUIMacCatalogLink = 11,
  HaskeLUIMacCatalogMenuButton = 12,
  HaskeLUIMacCatalogSplitButton = 13,
  HaskeLUIMacCatalogToggleSplitButton = 14,
  HaskeLUIMacCatalogTextArea = 15,
  HaskeLUIMacCatalogRichTextEditor = 16,
  HaskeLUIMacCatalogSecureField = 17,
  HaskeLUIMacCatalogSearchField = 18,
  HaskeLUIMacCatalogSuggestField = 19,
  HaskeLUIMacCatalogChoicePicker = 20,
  HaskeLUIMacCatalogEditableComboBox = 21,
  HaskeLUIMacCatalogNumberField = 22,
  HaskeLUIMacCatalogStepper = 23,
  HaskeLUIMacCatalogSlider = 24,
  HaskeLUIMacCatalogDatePicker = 25,
  HaskeLUIMacCatalogTimePicker = 26,
  HaskeLUIMacCatalogCalendarView = 27,
  HaskeLUIMacCatalogColorPicker = 28,
  HaskeLUIMacCatalogRating = 29,
  HaskeLUIMacCatalogListView = 30,
  HaskeLUIMacCatalogCollectionView = 31,
  HaskeLUIMacCatalogTreeView = 32,
  HaskeLUIMacCatalogTableView = 33,
  HaskeLUIMacCatalogItemRepeater = 34,
  HaskeLUIMacCatalogTabView = 35,
  HaskeLUIMacCatalogBreadcrumb = 36,
  HaskeLUIMacCatalogNavigationSidebar = 37,
  HaskeLUIMacCatalogMenuBar = 38,
  HaskeLUIMacCatalogContextMenu = 39,
  HaskeLUIMacCatalogToolbar = 40,
  HaskeLUIMacCatalogDialog = 41,
  HaskeLUIMacCatalogAlert = 42,
  HaskeLUIMacCatalogPopover = 43,
  HaskeLUIMacCatalogTooltip = 44,
  HaskeLUIMacCatalogProgressBar = 45,
  HaskeLUIMacCatalogActivityIndicator = 46,
  HaskeLUIMacCatalogMeter = 47,
  HaskeLUIMacCatalogBadge = 48,
  HaskeLUIMacCatalogInlineNotice = 49,
  HaskeLUIMacCatalogContainer = 50
} HaskeLUIMacCatalogControlKind;

typedef void (*HaskeLUIMacEventCallback)(
    void *context,
    int32_t event_kind,
    uint64_t identity,
    const char *utf8_text);

typedef struct HaskeLUIMacRect {
  double x;
  double y;
  double width;
  double height;
} HaskeLUIMacRect;

typedef enum HaskeLUIMacTextStyleField {
  HaskeLUIMacTextStyleForeground = 1u << 0,
  HaskeLUIMacTextStyleBackground = 1u << 1,
  HaskeLUIMacTextStyleFontFamily = 1u << 2,
  HaskeLUIMacTextStyleFontSize = 1u << 3,
  HaskeLUIMacTextStyleFontWeight = 1u << 4,
  HaskeLUIMacTextStyleFontSlant = 1u << 5,
  HaskeLUIMacTextStyleUnderline = 1u << 6,
  HaskeLUIMacTextStyleStrikethrough = 1u << 7,
  HaskeLUIMacTextStyleLetterSpacing = 1u << 8,
  HaskeLUIMacTextStyleBaselineOffset = 1u << 9
} HaskeLUIMacTextStyleField;

typedef struct HaskeLUIMacTextStyle {
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
} HaskeLUIMacTextStyle;

typedef struct HaskeLUIMacDebugCounters {
  int32_t windows;
  int32_t controls;
  int32_t action_targets;
  int32_t window_delegates;
  int32_t queued_callbacks;
  int32_t test_failures;
} HaskeLUIMacDebugCounters;

int32_t haskelui_macos_initialize(HaskeLUIMacEventCallback callback, void *context);
void haskelui_macos_run(void);
void haskelui_macos_stop(void);
void haskelui_macos_shutdown(void);
void haskelui_macos_schedule_runtime_wake(void);

int32_t haskelui_macos_version_major(void);
int32_t haskelui_macos_version_minor(void);
int32_t haskelui_macos_version_patch(void);

HaskeLUIMacWindowRef haskelui_macos_window_create(
    uint64_t identity,
    const char *utf8_title,
    const HaskeLUIMacRect *frame);
void haskelui_macos_window_set_title(
    HaskeLUIMacWindowRef window,
    const char *utf8_title);
void haskelui_macos_window_set_frame(HaskeLUIMacWindowRef window, const HaskeLUIMacRect *frame);
void haskelui_macos_window_show(HaskeLUIMacWindowRef window);
void haskelui_macos_window_destroy(HaskeLUIMacWindowRef window);

void haskelui_macos_workspace_begin(
    HaskeLUIMacWindowRef window,
    int32_t side_by_side,
    double status_height);
void haskelui_macos_workspace_pane_set(
    HaskeLUIMacWindowRef window,
    uint64_t pane_identity,
    int32_t pane_role,
    double preferred_extent,
    int32_t collapsed);
void haskelui_macos_workspace_item_set(
    HaskeLUIMacWindowRef window,
    uint64_t pane_identity,
    uint64_t item_identity);
void haskelui_macos_workspace_tab_group_set(
    HaskeLUIMacWindowRef window,
    uint64_t item_identity,
    uint64_t group_identity);
void haskelui_macos_workspace_tab_set(
    HaskeLUIMacWindowRef window,
    uint64_t group_identity,
    uint64_t tab_identity,
    const char *utf8_title,
    int32_t modified,
    int32_t closeable,
    int32_t selected);
void haskelui_macos_workspace_end(HaskeLUIMacWindowRef window);

HaskeLUIMacControlRef haskelui_macos_label_create(
    HaskeLUIMacWindowRef window,
    uint64_t identity,
    const char *utf8_text,
    const HaskeLUIMacRect *frame);
HaskeLUIMacControlRef haskelui_macos_button_create(
    HaskeLUIMacWindowRef window,
    uint64_t identity,
    const char *utf8_title,
    uint64_t command_identity,
    const HaskeLUIMacRect *frame);
HaskeLUIMacControlRef haskelui_macos_text_field_create(
    HaskeLUIMacWindowRef window,
    uint64_t identity,
    const char *utf8_text,
    const char *utf8_placeholder,
    const HaskeLUIMacRect *frame);
HaskeLUIMacControlRef haskelui_macos_text_editor_create(
    HaskeLUIMacWindowRef window,
    uint64_t identity,
    const char *utf8_text,
    const HaskeLUIMacRect *frame);
HaskeLUIMacControlRef haskelui_macos_catalog_control_create(
    HaskeLUIMacWindowRef window,
    uint64_t identity,
    int32_t catalog_kind,
    const HaskeLUIMacRect *frame);
void haskelui_macos_catalog_control_set_primary_text(
    HaskeLUIMacControlRef control,
    const char *utf8_text);
void haskelui_macos_catalog_control_set_secondary_text(
    HaskeLUIMacControlRef control,
    const char *utf8_text);
void haskelui_macos_catalog_control_set_state(
    HaskeLUIMacControlRef control,
    int32_t state);
void haskelui_macos_catalog_control_set_row_sizing(
    HaskeLUIMacControlRef control,
    int32_t sizing,
    double fixed_height);
void haskelui_macos_catalog_control_set_numeric(
    HaskeLUIMacControlRef control,
    double value,
    double minimum,
    double maximum,
    double step);
void haskelui_macos_catalog_control_set_color(
    HaskeLUIMacControlRef control,
    double red,
    double green,
    double blue,
    double alpha);
void haskelui_macos_catalog_control_set_date_time(
    HaskeLUIMacControlRef control,
    int32_t year,
    int32_t month,
    int32_t day,
    int32_t hour,
    int32_t minute,
    int32_t second);
void haskelui_macos_catalog_control_set_command(
    HaskeLUIMacControlRef control,
    uint64_t command_identity);
void haskelui_macos_catalog_control_begin_items(HaskeLUIMacControlRef control);
void haskelui_macos_catalog_control_add_item(
    HaskeLUIMacControlRef control,
    uint64_t item_identity,
    const char *utf8_label,
    const char *utf8_detail,
    const char *utf8_icon,
    int32_t depth,
    int32_t flags,
    uint64_t command_identity);
void haskelui_macos_catalog_control_end_items(HaskeLUIMacControlRef control);
void haskelui_macos_catalog_control_set_tooltip(
    HaskeLUIMacControlRef control,
    const char *utf8_tooltip);
void haskelui_macos_catalog_control_set_presentation(
    HaskeLUIMacControlRef control,
    int32_t visible,
    uint64_t anchor_identity);
void haskelui_macos_control_set_text(
    HaskeLUIMacControlRef control,
    const char *utf8_text);
void haskelui_macos_text_editor_begin_presentation(HaskeLUIMacControlRef control);
void haskelui_macos_text_editor_set_base_style(
    HaskeLUIMacControlRef control,
    const HaskeLUIMacTextStyle *style);
int32_t haskelui_macos_text_editor_apply_style(
    HaskeLUIMacControlRef control,
    uint64_t utf16_location,
    uint64_t utf16_length,
    const HaskeLUIMacTextStyle *style);
void haskelui_macos_text_editor_end_presentation(HaskeLUIMacControlRef control);
void haskelui_macos_control_measure(
    HaskeLUIMacControlRef control,
    double maximum_width,
    double maximum_height,
    HaskeLUIMacRect *result);
void haskelui_macos_control_set_frame(HaskeLUIMacControlRef control, const HaskeLUIMacRect *frame);
void haskelui_macos_control_set_enabled(HaskeLUIMacControlRef control, int32_t enabled);
void haskelui_macos_control_focus(HaskeLUIMacWindowRef window, HaskeLUIMacControlRef control);
void haskelui_macos_control_set_next_key(
    HaskeLUIMacControlRef control,
    HaskeLUIMacControlRef next_control);
void haskelui_macos_control_set_parent_item(
    HaskeLUIMacWindowRef window,
    HaskeLUIMacControlRef control,
    uint64_t item_identity,
    int32_t fill_parent);
void haskelui_macos_control_set_parent_tab(
    HaskeLUIMacWindowRef window,
    HaskeLUIMacControlRef control,
    uint64_t group_identity,
    uint64_t tab_identity,
    int32_t fill_parent);
void haskelui_macos_control_set_parent_status(
    HaskeLUIMacWindowRef window,
    HaskeLUIMacControlRef control,
    int32_t fill_parent);
void haskelui_macos_control_set_parent_control(
    HaskeLUIMacControlRef parent,
    HaskeLUIMacControlRef child,
    uint64_t slot_identity,
    int32_t fill_parent);
void haskelui_macos_control_destroy(HaskeLUIMacControlRef control);

void haskelui_macos_command_set(
    uint64_t identity,
    const char *utf8_title,
    const char *utf8_key_equivalent,
    int32_t enabled);
void haskelui_macos_command_remove(uint64_t identity);
void haskelui_macos_open_text_files(void);
void haskelui_macos_open_project_folder(void);

/* Diagnostic API used by the native backend's deterministic integration test. */
void haskelui_macos_debug_counters(HaskeLUIMacDebugCounters *counters);
const char *haskelui_macos_test_last_failure(void);
void haskelui_macos_test_schedule_vertical_script(
    uint64_t main_window_identity,
    uint64_t name_field_identity,
    uint64_t greeting_label_identity,
    uint64_t save_command_identity);
void haskelui_macos_test_schedule_text_editor_script(
    uint64_t document_window_identity,
    uint64_t editor_identity,
    uint64_t tab_identity,
    uint64_t save_command_identity,
    uint64_t open_folder_command_identity);
void haskelui_macos_test_schedule_control_gallery_script(
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
