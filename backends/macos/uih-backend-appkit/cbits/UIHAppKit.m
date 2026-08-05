#import "UIHAppKit.h"
#import "compat/UIHAppKitCompatibility.h"

#import <dispatch/dispatch.h>

_Static_assert(sizeof(UIHMacTextStyle) == 120, "UIHMacTextStyle ABI must match its Haskell Storable instance");

typedef NS_ENUM(NSInteger, UIHMacControlKind) {
  UIHMacControlKindLabel,
  UIHMacControlKindButton,
  UIHMacControlKindTextField,
  UIHMacControlKindTextEditor
};

@class UIHMacWindowHandle;
@class UIHMacControlHandle;

@interface UIHMacApplicationState : NSObject
@property(nonatomic, assign) UIHMacEventCallback callback;
@property(nonatomic, assign) void *callbackContext;
@property(nonatomic, strong) NSMenu *fileMenu;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSMenuItem *> *commandItems;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, id> *commandTargets;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, UIHMacWindowHandle *> *windows;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, UIHMacControlHandle *> *controls;
@property(nonatomic, strong) NSOpenPanel *openPanel;
@end

@implementation UIHMacApplicationState
@end

static UIHMacApplicationState *UIHState = nil;
static int32_t UIHLiveWindows = 0;
static int32_t UIHLiveControls = 0;
static int32_t UIHLiveActionTargets = 0;
static int32_t UIHLiveWindowDelegates = 0;
static int32_t UIHQueuedCallbacks = 0;
static int32_t UIHTestFailures = 0;
static NSString *UIHLastTestFailure = nil;

static void UIHAssertMainThread(void) {
  NSCAssert(UIHAppKitIsMainThread(), @"UIH AppKit operation must run on the process main thread");
}

static NSString *UIHString(const char *utf8) {
  if (utf8 == NULL) {
    return @"";
  }
  NSString *value = [NSString stringWithUTF8String:utf8];
  return value == nil ? @"" : value;
}

static NSRect UIHRect(const UIHMacRect *frame) {
  return NSMakeRect(frame->x, frame->y, frame->width, frame->height);
}

static void UIHEmit(int32_t kind, uint64_t identity, NSString *text) {
  NSString *copiedText = text == nil ? @"" : [text copy];
  UIHQueuedCallbacks += 1;
  dispatch_async(dispatch_get_main_queue(), ^{
    UIHMacApplicationState *state = UIHState;
    if (state != nil && state.callback != NULL) {
      state.callback(
          state.callbackContext,
          kind,
          identity,
          [copiedText UTF8String]);
    }
    UIHQueuedCallbacks -= 1;
  });
}

@interface UIHMacActionTarget : NSObject <NSTextFieldDelegate, NSTextViewDelegate>
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, assign) int32_t eventKind;
- (void)performAction:(id)sender;
@end

@implementation UIHMacActionTarget
- (void)performAction:(id)sender {
  (void)sender;
  UIHEmit(self.eventKind, self.identity, @"");
}

- (void)controlTextDidChange:(NSNotification *)notification {
  NSTextField *field = notification.object;
  UIHEmit(UIHMacEventTextChanged, self.identity, field.stringValue);
}

- (void)textDidChange:(NSNotification *)notification {
  NSTextView *editor = notification.object;
  UIHEmit(UIHMacEventTextChanged, self.identity, editor.string);
}
@end

@interface UIHMacWindowDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, assign) uint64_t identity;
@end

@implementation UIHMacWindowDelegate
- (BOOL)windowShouldClose:(NSWindow *)sender {
  (void)sender;
  UIHEmit(UIHMacEventWindowCloseRequested, self.identity, @"");
  return NO;
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
  (void)notification;
  UIHEmit(UIHMacEventWindowActivated, self.identity, @"");
}
@end

@interface UIHMacWindowHandle : NSObject
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) UIHMacWindowDelegate *delegate;
@end

@implementation UIHMacWindowHandle
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    UIHLiveWindows += 1;
  }
  return self;
}

- (void)dealloc {
  UIHLiveWindows -= 1;
}
@end

@interface UIHMacControlHandle : NSObject
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, strong) NSView *view;
@property(nonatomic, strong) NSView *focusView;
@property(nonatomic, strong) UIHMacActionTarget *target;
@property(nonatomic, assign) UIHMacControlKind kind;
@end

@implementation UIHMacControlHandle
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    UIHLiveControls += 1;
  }
  return self;
}

- (void)dealloc {
  UIHLiveControls -= 1;
}
@end

static UIHMacWindowHandle *UIHWindow(UIHMacWindowRef reference) {
  return (__bridge UIHMacWindowHandle *)reference;
}

static UIHMacControlHandle *UIHControl(UIHMacControlRef reference) {
  return (__bridge UIHMacControlHandle *)reference;
}

static void UIHBuildApplicationMenu(NSApplication *application) {
  NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"UIH"];

  NSMenuItem *applicationItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
  NSMenu *applicationMenu = [[NSMenu alloc] initWithTitle:@"UIH"];
  NSMenuItem *quitItem =
      [[NSMenuItem alloc] initWithTitle:@"Quit UIH" action:@selector(stop:) keyEquivalent:@"q"];
  quitItem.target = application;
  [applicationMenu addItem:quitItem];
  applicationItem.submenu = applicationMenu;
  [mainMenu addItem:applicationItem];

  NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
  NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
  fileMenu.autoenablesItems = NO;
  fileItem.submenu = fileMenu;
  [mainMenu addItem:fileItem];

  application.mainMenu = mainMenu;
  UIHState.fileMenu = fileMenu;
}

int32_t uih_macos_initialize(UIHMacEventCallback callback, void *context) {
  UIHAssertMainThread();
  if (callback == NULL || UIHState != nil) {
    return 0;
  }

  UIHState = [[UIHMacApplicationState alloc] init];
  UIHState.callback = callback;
  UIHState.callbackContext = context;
  UIHState.commandItems = [[NSMutableDictionary alloc] init];
  UIHState.commandTargets = [[NSMutableDictionary alloc] init];
  UIHState.windows = [[NSMutableDictionary alloc] init];
  UIHState.controls = [[NSMutableDictionary alloc] init];
  UIHTestFailures = 0;
  UIHLastTestFailure = nil;

  NSApplication *application = NSApplication.sharedApplication;
  application.activationPolicy = NSApplicationActivationPolicyRegular;
  UIHBuildApplicationMenu(application);
  [application finishLaunching];
  return 1;
}

void uih_macos_run(void) {
  UIHAssertMainThread();
  [NSApplication.sharedApplication activateIgnoringOtherApps:YES];
  [NSApplication.sharedApplication run];
}

void uih_macos_stop(void) {
  UIHAssertMainThread();
  NSApplication *application = NSApplication.sharedApplication;
  dispatch_async(dispatch_get_main_queue(), ^{
    [application stop:nil];
    NSEvent *wakeEvent =
        [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                           location:NSZeroPoint
                      modifierFlags:0
                          timestamp:NSProcessInfo.processInfo.systemUptime
                       windowNumber:0
                            context:nil
                            subtype:0
                              data1:0
                              data2:0];
    [application postEvent:wakeEvent atStart:NO];
  });
}

void uih_macos_shutdown(void) {
  UIHAssertMainThread();
  if (UIHState == nil) {
    return;
  }
  UIHState.callback = NULL;
  UIHState.callbackContext = NULL;
  NSApplication.sharedApplication.mainMenu = nil;
  UIHState = nil;
}

int32_t uih_macos_version_major(void) {
  return (int32_t)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
}

int32_t uih_macos_version_minor(void) {
  return (int32_t)NSProcessInfo.processInfo.operatingSystemVersion.minorVersion;
}

int32_t uih_macos_version_patch(void) {
  return (int32_t)NSProcessInfo.processInfo.operatingSystemVersion.patchVersion;
}

UIHMacWindowRef uih_macos_window_create(
    uint64_t identity,
    const char *utf8_title,
    const UIHMacRect *frame) {
  UIHAssertMainThread();
  NSUInteger style =
      NSWindowStyleMaskTitled |
      NSWindowStyleMaskClosable |
      NSWindowStyleMaskMiniaturizable |
      NSWindowStyleMaskResizable;
  NSWindow *window =
      [[NSWindow alloc] initWithContentRect:UIHRect(frame)
                                styleMask:style
                                  backing:NSBackingStoreBuffered
                                    defer:NO];
  window.title = UIHString(utf8_title);
  window.releasedWhenClosed = NO;
  window.identifier = [NSString stringWithFormat:@"uih-window-%llu", identity];
  window.contentView.accessibilityIdentifier =
      [NSString stringWithFormat:@"uih-window-content-%llu", identity];

  UIHMacWindowDelegate *delegate = [[UIHMacWindowDelegate alloc] init];
  delegate.identity = identity;
  window.delegate = delegate;
  UIHLiveWindowDelegates += 1;

  UIHMacWindowHandle *handle = [[UIHMacWindowHandle alloc] init];
  handle.identity = identity;
  handle.window = window;
  handle.delegate = delegate;
  UIHState.windows[@(identity)] = handle;
  return (__bridge_retained void *)handle;
}

void uih_macos_window_set_title(UIHMacWindowRef reference, const char *utf8_title) {
  UIHAssertMainThread();
  UIHWindow(reference).window.title = UIHString(utf8_title);
}

void uih_macos_window_set_frame(UIHMacWindowRef reference, const UIHMacRect *frame) {
  UIHAssertMainThread();
  [UIHWindow(reference).window setFrame:UIHRect(frame) display:YES];
}

void uih_macos_window_show(UIHMacWindowRef reference) {
  UIHAssertMainThread();
  [UIHWindow(reference).window makeKeyAndOrderFront:nil];
}

void uih_macos_window_destroy(UIHMacWindowRef reference) {
  UIHAssertMainThread();
  if (reference == NULL) {
    return;
  }
  UIHMacWindowHandle *handle = (__bridge_transfer UIHMacWindowHandle *)reference;
  [UIHState.windows removeObjectForKey:@(handle.identity)];
  handle.window.delegate = nil;
  [handle.window orderOut:nil];
  [handle.window close];
  if (handle.delegate != nil) {
    handle.delegate = nil;
    UIHLiveWindowDelegates -= 1;
  }
  handle.window = nil;
}

static UIHMacControlRef UIHRetainControl(
    NSView *view,
    NSView *focusView,
    UIHMacActionTarget *target,
    UIHMacControlKind kind,
    uint64_t identity,
    UIHMacWindowRef windowReference) {
  UIHMacControlHandle *handle = [[UIHMacControlHandle alloc] init];
  handle.identity = identity;
  handle.view = view;
  handle.focusView = focusView;
  handle.target = target;
  handle.kind = kind;
  focusView.accessibilityElement = YES;
  focusView.accessibilityIdentifier = [NSString stringWithFormat:@"uih-control-%llu", identity];
  switch (kind) {
    case UIHMacControlKindLabel:
      focusView.accessibilityRole = NSAccessibilityStaticTextRole;
      break;
    case UIHMacControlKindButton:
      focusView.accessibilityRole = NSAccessibilityButtonRole;
      break;
    case UIHMacControlKindTextField:
      focusView.accessibilityRole = NSAccessibilityTextFieldRole;
      break;
    case UIHMacControlKindTextEditor:
      focusView.accessibilityRole = NSAccessibilityTextAreaRole;
      break;
  }
  [UIHWindow(windowReference).window.contentView addSubview:view];
  UIHState.controls[@(identity)] = handle;
  return (__bridge_retained void *)handle;
}

UIHMacControlRef uih_macos_label_create(
    UIHMacWindowRef window,
    uint64_t identity,
    const char *utf8_text,
    const UIHMacRect *frame) {
  UIHAssertMainThread();
  NSTextField *label = [[NSTextField alloc] initWithFrame:UIHRect(frame)];
  label.stringValue = UIHString(utf8_text);
  label.editable = NO;
  label.selectable = NO;
  label.bezeled = NO;
  label.drawsBackground = NO;
  return UIHRetainControl(label, label, nil, UIHMacControlKindLabel, identity, window);
}

UIHMacControlRef uih_macos_button_create(
    UIHMacWindowRef window,
    uint64_t identity,
    const char *utf8_title,
    uint64_t command_identity,
    const UIHMacRect *frame) {
  UIHAssertMainThread();
  UIHMacActionTarget *target = [[UIHMacActionTarget alloc] init];
  UIHLiveActionTargets += 1;
  target.identity = command_identity;
  target.eventKind = UIHMacEventCommand;

  NSButton *button = [[NSButton alloc] initWithFrame:UIHRect(frame)];
  button.title = UIHString(utf8_title);
  button.bezelStyle = NSBezelStyleRounded;
  button.target = target;
  button.action = @selector(performAction:);
  return UIHRetainControl(button, button, target, UIHMacControlKindButton, identity, window);
}

UIHMacControlRef uih_macos_text_field_create(
    UIHMacWindowRef window,
    uint64_t identity,
    const char *utf8_text,
    const char *utf8_placeholder,
    const UIHMacRect *frame) {
  UIHAssertMainThread();
  UIHMacActionTarget *target = [[UIHMacActionTarget alloc] init];
  UIHLiveActionTargets += 1;
  target.identity = identity;
  target.eventKind = UIHMacEventTextChanged;

  NSTextField *field = [[NSTextField alloc] initWithFrame:UIHRect(frame)];
  field.stringValue = UIHString(utf8_text);
  field.placeholderString = UIHString(utf8_placeholder);
  field.delegate = target;
  return UIHRetainControl(field, field, target, UIHMacControlKindTextField, identity, window);
}

UIHMacControlRef uih_macos_text_editor_create(
    UIHMacWindowRef window,
    uint64_t identity,
    const char *utf8_text,
    const UIHMacRect *frame) {
  UIHAssertMainThread();
  UIHMacActionTarget *target = [[UIHMacActionTarget alloc] init];
  UIHLiveActionTargets += 1;
  target.identity = identity;
  target.eventKind = UIHMacEventTextChanged;

  NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:UIHRect(frame)];
  scrollView.borderType = NSBezelBorder;
  scrollView.hasVerticalScroller = YES;
  scrollView.hasHorizontalScroller = NO;
  scrollView.autohidesScrollers = YES;
  scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  NSRect editorFrame = NSMakeRect(0, 0, frame->width, frame->height);
  NSTextView *editor = [[NSTextView alloc] initWithFrame:editorFrame];
  editor.string = UIHString(utf8_text);
  editor.delegate = target;
  editor.richText = NO;
  editor.allowsUndo = YES;
  editor.usesFindBar = YES;
  editor.automaticQuoteSubstitutionEnabled = NO;
  editor.automaticDashSubstitutionEnabled = NO;
  editor.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
  editor.minSize = NSMakeSize(0, frame->height);
  editor.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
  editor.verticallyResizable = YES;
  editor.horizontallyResizable = NO;
  editor.autoresizingMask = NSViewWidthSizable;
  editor.textContainer.containerSize = NSMakeSize(frame->width, CGFLOAT_MAX);
  editor.textContainer.widthTracksTextView = YES;
  scrollView.documentView = editor;

  return UIHRetainControl(
      scrollView,
      editor,
      target,
      UIHMacControlKindTextEditor,
      identity,
      window);
}

void uih_macos_control_set_text(UIHMacControlRef reference, const char *utf8_text) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  NSString *value = UIHString(utf8_text);
  switch (handle.kind) {
    case UIHMacControlKindButton:
      ((NSButton *)handle.view).title = value;
      break;
    case UIHMacControlKindLabel:
    case UIHMacControlKindTextField: {
      NSTextField *field = (NSTextField *)handle.view;
      if (![field.stringValue isEqualToString:value]) {
        field.stringValue = value;
      }
      break;
    }
    case UIHMacControlKindTextEditor: {
      NSTextView *editor = (NSTextView *)handle.focusView;
      if (![editor.string isEqualToString:value]) {
        NSRange selection = editor.selectedRange;
        editor.string = value;
        if (selection.location <= editor.string.length) {
          NSUInteger remaining = editor.string.length - selection.location;
          selection.length = MIN(selection.length, remaining);
          editor.selectedRange = selection;
        }
      }
      break;
    }
  }
}

static CGFloat UIHClampUnit(double value) {
  return (CGFloat)MIN(1.0, MAX(0.0, value));
}

static NSColor *UIHColor(double red, double green, double blue, double alpha) {
  return [NSColor colorWithSRGBRed:UIHClampUnit(red)
                             green:UIHClampUnit(green)
                              blue:UIHClampUnit(blue)
                             alpha:UIHClampUnit(alpha)];
}

static NSFontWeight UIHFontWeight(int32_t weight) {
  switch (weight) {
    case 100: return NSFontWeightThin;
    case 200: return NSFontWeightUltraLight;
    case 300: return NSFontWeightLight;
    case 500: return NSFontWeightMedium;
    case 600: return NSFontWeightSemibold;
    case 700: return NSFontWeightBold;
    case 800: return NSFontWeightHeavy;
    case 900: return NSFontWeightBlack;
    case 400:
    default: return NSFontWeightRegular;
  }
}

static NSFont *UIHFontForStyle(NSTextView *editor, const UIHMacTextStyle *style) {
  uint32_t fontFields =
      UIHMacTextStyleFontFamily |
      UIHMacTextStyleFontSize |
      UIHMacTextStyleFontWeight |
      UIHMacTextStyleFontSlant;
  if ((style->fields & fontFields) == 0) {
    return nil;
  }

  NSFont *existing = editor.font ?: [NSFont systemFontOfSize:13.0];
  CGFloat size =
      (style->fields & UIHMacTextStyleFontSize) != 0
          ? (CGFloat)MAX(1.0, style->font_size)
          : existing.pointSize;
  NSFontWeight weight =
      (style->fields & UIHMacTextStyleFontWeight) != 0
          ? UIHFontWeight(style->font_weight)
          : NSFontWeightRegular;
  NSFont *font = existing;

  if ((style->fields & UIHMacTextStyleFontFamily) != 0) {
    switch (style->font_family_kind) {
      case 1:
        font = [NSFont systemFontOfSize:size weight:weight];
        break;
      case 2:
        font = [NSFont monospacedSystemFontOfSize:size weight:weight];
        break;
      case 3: {
        NSString *name = UIHString(style->utf8_font_family);
        font = [NSFont fontWithName:name size:size] ?: existing;
        break;
      }
      default:
        break;
    }
  } else if ((style->fields & UIHMacTextStyleFontSize) != 0) {
    font = [NSFont fontWithDescriptor:existing.fontDescriptor size:size] ?: existing;
  }

  if ((style->fields & UIHMacTextStyleFontWeight) != 0 &&
      (style->fields & UIHMacTextStyleFontFamily) == 0) {
    NSFontDescriptor *weightedDescriptor =
        [font.fontDescriptor fontDescriptorByAddingAttributes:@{
          NSFontTraitsAttribute: @{NSFontWeightTrait: @(weight)}
        }];
    font = [NSFont fontWithDescriptor:weightedDescriptor size:size] ?: font;
  }

  if ((style->fields & UIHMacTextStyleFontSlant) != 0) {
    NSFontTraitMask trait = style->font_slant == 1 ? 0 : NSItalicFontMask;
    font = trait == 0
        ? [NSFontManager.sharedFontManager convertFont:font toNotHaveTrait:NSItalicFontMask]
        : [NSFontManager.sharedFontManager convertFont:font toHaveTrait:trait];
  }
  return font;
}

static NSUnderlineStyle UIHUnderlineStyle(int32_t style) {
  switch (style) {
    case 0: return (NSUnderlineStyle)0;
    case 2: return NSUnderlineStyleDouble;
    case 3: return NSUnderlineStyleThick;
    case 4: return NSUnderlineStyleSingle | NSUnderlinePatternDot;
    case 5: return NSUnderlineStyleSingle | NSUnderlinePatternDash;
    case 6: return NSUnderlineStyleSingle | NSUnderlinePatternDashDotDot;
    case 1:
    default: return NSUnderlineStyleSingle;
  }
}

void uih_macos_text_editor_begin_presentation(UIHMacControlRef reference) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  if (handle.kind != UIHMacControlKindTextEditor) {
    return;
  }
  NSTextView *editor = (NSTextView *)handle.focusView;
  if (editor.string.length > 0) {
    [editor.layoutManager
        setTemporaryAttributes:@{}
              forCharacterRange:NSMakeRange(0, editor.string.length)];
  }
}

void uih_macos_text_editor_set_base_style(
    UIHMacControlRef reference,
    const UIHMacTextStyle *style) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  if (handle.kind != UIHMacControlKindTextEditor || style == NULL) {
    return;
  }
  NSTextView *editor = (NSTextView *)handle.focusView;
  editor.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
  editor.textColor = NSColor.textColor;
  editor.backgroundColor = NSColor.textBackgroundColor;
  if ((style->fields & UIHMacTextStyleForeground) != 0) {
    editor.textColor =
        UIHColor(
            style->foreground_red,
            style->foreground_green,
            style->foreground_blue,
            style->foreground_alpha);
  }
  if ((style->fields & UIHMacTextStyleBackground) != 0) {
    editor.backgroundColor =
        UIHColor(
            style->background_red,
            style->background_green,
            style->background_blue,
            style->background_alpha);
  }
  NSFont *font = UIHFontForStyle(editor, style);
  if (font != nil) {
    editor.font = font;
  }
}

int32_t uih_macos_text_editor_apply_style(
    UIHMacControlRef reference,
    uint64_t utf16Location,
    uint64_t utf16Length,
    const UIHMacTextStyle *style) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  if (handle.kind != UIHMacControlKindTextEditor || style == NULL ||
      utf16Location > NSUIntegerMax || utf16Length > NSUIntegerMax) {
    return 0;
  }
  NSTextView *editor = (NSTextView *)handle.focusView;
  NSUInteger location = (NSUInteger)utf16Location;
  NSUInteger length = (NSUInteger)utf16Length;
  if (location > editor.string.length || length > editor.string.length - location) {
    return 0;
  }

  NSMutableDictionary<NSAttributedStringKey, id> *attributes =
      [[NSMutableDictionary alloc] init];
  if ((style->fields & UIHMacTextStyleForeground) != 0) {
    attributes[NSForegroundColorAttributeName] =
        UIHColor(
            style->foreground_red,
            style->foreground_green,
            style->foreground_blue,
            style->foreground_alpha);
  }
  if ((style->fields & UIHMacTextStyleBackground) != 0) {
    attributes[NSBackgroundColorAttributeName] =
        UIHColor(
            style->background_red,
            style->background_green,
            style->background_blue,
            style->background_alpha);
  }
  NSFont *font = UIHFontForStyle(editor, style);
  if (font != nil) {
    attributes[NSFontAttributeName] = font;
  }
  if ((style->fields & UIHMacTextStyleUnderline) != 0) {
    attributes[NSUnderlineStyleAttributeName] = @(UIHUnderlineStyle(style->underline_style));
  }
  if ((style->fields & UIHMacTextStyleStrikethrough) != 0) {
    attributes[NSStrikethroughStyleAttributeName] =
        style->strikethrough != 0 ? @(NSUnderlineStyleSingle) : @0;
  }
  if ((style->fields & UIHMacTextStyleLetterSpacing) != 0) {
    attributes[NSKernAttributeName] = @(style->letter_spacing);
  }
  if ((style->fields & UIHMacTextStyleBaselineOffset) != 0) {
    attributes[NSBaselineOffsetAttributeName] = @(style->baseline_offset);
  }

  if (length > 0 && attributes.count > 0) {
    [editor.layoutManager
        addTemporaryAttributes:attributes
              forCharacterRange:NSMakeRange(location, length)];
  }
  return 1;
}

void uih_macos_text_editor_end_presentation(UIHMacControlRef reference) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  if (handle.kind != UIHMacControlKindTextEditor) {
    return;
  }
  NSTextView *editor = (NSTextView *)handle.focusView;
  if (editor.string.length > 0) {
    [editor.layoutManager invalidateDisplayForCharacterRange:NSMakeRange(0, editor.string.length)];
  }
}

void uih_macos_control_set_frame(UIHMacControlRef reference, const UIHMacRect *frame) {
  UIHAssertMainThread();
  UIHControl(reference).view.frame = UIHRect(frame);
}

void uih_macos_control_set_enabled(UIHMacControlRef reference, int32_t enabled) {
  UIHAssertMainThread();
  NSView *view = UIHControl(reference).view;
  if ([view isKindOfClass:NSControl.class]) {
    ((NSControl *)view).enabled = enabled != 0;
  }
}

void uih_macos_control_focus(UIHMacWindowRef window, UIHMacControlRef control) {
  UIHAssertMainThread();
  [UIHWindow(window).window makeFirstResponder:UIHControl(control).focusView];
}

void uih_macos_control_set_next_key(
    UIHMacControlRef reference,
    UIHMacControlRef nextReference) {
  UIHAssertMainThread();
  UIHControl(reference).focusView.nextKeyView = UIHControl(nextReference).focusView;
}

void uih_macos_control_destroy(UIHMacControlRef reference) {
  UIHAssertMainThread();
  if (reference == NULL) {
    return;
  }
  UIHMacControlHandle *handle = (__bridge_transfer UIHMacControlHandle *)reference;
  [UIHState.controls removeObjectForKey:@(handle.identity)];
  if ([handle.view isKindOfClass:NSTextField.class]) {
    ((NSTextField *)handle.view).delegate = nil;
  }
  if ([handle.focusView isKindOfClass:NSTextView.class]) {
    ((NSTextView *)handle.focusView).delegate = nil;
  }
  if ([handle.view isKindOfClass:NSControl.class]) {
    ((NSControl *)handle.view).target = nil;
    ((NSControl *)handle.view).action = nil;
  }
  [handle.view removeFromSuperview];
  if (handle.target != nil) {
    handle.target = nil;
    UIHLiveActionTargets -= 1;
  }
  handle.focusView = nil;
  handle.view = nil;
}

void uih_macos_command_set(
    uint64_t identity,
    const char *utf8_title,
    const char *utf8_key_equivalent,
    int32_t enabled) {
  UIHAssertMainThread();
  NSNumber *key = @(identity);
  NSMenuItem *item = UIHState.commandItems[key];
  if (item == nil) {
    UIHMacActionTarget *target = [[UIHMacActionTarget alloc] init];
    UIHLiveActionTargets += 1;
    target.identity = identity;
    target.eventKind = UIHMacEventCommand;
    item = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(performAction:) keyEquivalent:@""];
    item.target = target;
    UIHState.commandItems[key] = item;
    UIHState.commandTargets[key] = target;
    [UIHState.fileMenu addItem:item];
  }
  item.title = UIHString(utf8_title);
  item.keyEquivalent = [UIHString(utf8_key_equivalent) lowercaseString];
  item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  item.enabled = enabled != 0;
}

void uih_macos_command_remove(uint64_t identity) {
  UIHAssertMainThread();
  NSNumber *key = @(identity);
  NSMenuItem *item = UIHState.commandItems[key];
  if (item == nil) {
    return;
  }
  item.target = nil;
  [UIHState.fileMenu removeItem:item];
  [UIHState.commandItems removeObjectForKey:key];
  if (UIHState.commandTargets[key] != nil) {
    UIHLiveActionTargets -= 1;
  }
  [UIHState.commandTargets removeObjectForKey:key];
}

void uih_macos_open_text_files(void) {
  UIHAssertMainThread();
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = NO;
  panel.allowsMultipleSelection = YES;
  panel.resolvesAliases = YES;
  panel.title = @"Open Text Files";
  panel.prompt = @"Open";
  UIHState.openPanel = panel;
  [panel beginWithCompletionHandler:^(NSModalResponse response) {
    UIHState.openPanel = nil;
    if (response != NSModalResponseOK) {
      return;
    }
    for (NSURL *url in panel.URLs) {
      UIHEmit(UIHMacEventTextFileChosen, 0, url.path);
    }
  }];
}

static void UIHTestFail(NSString *message) {
  UIHTestFailures += 1;
  if (UIHLastTestFailure == nil) {
    UIHLastTestFailure = [message copy];
  }
  NSLog(@"UIH native validation failure: %@", message);
}

static BOOL UIHResponderBelongsToView(NSResponder *responder, NSView *view) {
  if (responder == view) {
    return YES;
  }
  if ([responder isKindOfClass:NSText.class]) {
    return (id)((NSText *)responder).delegate == (id)view;
  }
  return NO;
}

void uih_macos_debug_counters(UIHMacDebugCounters *counters) {
  if (counters == NULL) {
    return;
  }
  counters->windows = UIHLiveWindows;
  counters->controls = UIHLiveControls;
  counters->action_targets = UIHLiveActionTargets;
  counters->window_delegates = UIHLiveWindowDelegates;
  counters->queued_callbacks = UIHQueuedCallbacks;
  counters->test_failures = UIHTestFailures;
}

const char *uih_macos_test_last_failure(void) {
  return UIHLastTestFailure == nil ? NULL : UIHLastTestFailure.UTF8String;
}

static void UIHTestAfter(double seconds, dispatch_block_t block) {
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
      dispatch_get_main_queue(),
      block);
}

void uih_macos_test_schedule_vertical_script(
    uint64_t mainWindowIdentity,
    uint64_t nameFieldIdentity,
    uint64_t greetingLabelIdentity,
    uint64_t saveCommandIdentity) {
  UIHAssertMainThread();

  UIHTestAfter(0.10, ^{
        UIHMacWindowHandle *mainWindow = UIHState.windows[@(mainWindowIdentity)];
        UIHMacControlHandle *nameField = UIHState.controls[@(nameFieldIdentity)];
        UIHMacControlHandle *greetingLabel = UIHState.controls[@(greetingLabelIdentity)];
        NSMenuItem *saveItem = UIHState.commandItems[@(saveCommandIdentity)];
        if (mainWindow == nil || nameField == nil || greetingLabel == nil || saveItem == nil) {
          UIHTestFail(@"initial native window, controls, or Save command were not registered");
          [NSApplication.sharedApplication stop:nil];
          return;
        }

        NSTextField *field = (NSTextField *)nameField.view;
        NSString *expectedIdentifier =
            [NSString stringWithFormat:@"uih-control-%llu", nameFieldIdentity];
        if (![field.accessibilityIdentifier isEqualToString:expectedIdentifier]) {
          UIHTestFail(@"text field does not expose its stable UIH accessibility identifier");
        }
        NSString *role = field.accessibilityRole;
        if (![role isEqualToString:NSAccessibilityTextFieldRole]) {
          UIHTestFail([NSString stringWithFormat:
              @"text field exposes accessibility role %@ instead of %@",
              role,
              NSAccessibilityTextFieldRole]);
        }

        [mainWindow.window makeKeyAndOrderFront:nil];
        if (![mainWindow.window makeFirstResponder:field] ||
            !UIHResponderBelongsToView(mainWindow.window.firstResponder, field)) {
          UIHTestFail(@"text field could not become the native first responder");
        }
        NSView *nextKeyView = field.nextKeyView;
        if (nextKeyView == nil || nextKeyView == field) {
          UIHTestFail(@"explicit key-view traversal was not installed");
        } else {
          if (![mainWindow.window makeFirstResponder:nextKeyView] ||
              !UIHResponderBelongsToView(mainWindow.window.firstResponder, nextKeyView)) {
            UIHTestFail(@"next key-view control could not become the native first responder");
          }
          [mainWindow.window makeFirstResponder:field];
        }

        [mainWindow.window performClose:nil];

        UIHTestAfter(0.12, ^{
          UIHMacWindowHandle *retainedMainWindow = UIHState.windows[@(mainWindowIdentity)];
          UIHMacControlHandle *retainedNameField = UIHState.controls[@(nameFieldIdentity)];
          if (retainedMainWindow == nil) {
            UIHTestFail(@"dirty main window was not retained after its close veto");
            [NSApplication.sharedApplication stop:nil];
            return;
          }
          if (retainedNameField == nil || retainedNameField.kind != UIHMacControlKindTextField) {
            UIHTestFail(@"name text field disappeared after close veto");
            [NSApplication.sharedApplication stop:nil];
            return;
          }
          NSTextField *retainedField = (NSTextField *)retainedNameField.view;
          retainedField.stringValue = @"Ada";
          [retainedField.delegate controlTextDidChange:
              [NSNotification
                  notificationWithName:NSControlTextDidChangeNotification
                                object:retainedField]];

          UIHTestAfter(0.12, ^{
            UIHMacWindowHandle *editedMainWindow = UIHState.windows[@(mainWindowIdentity)];
            UIHMacControlHandle *editedGreeting = UIHState.controls[@(greetingLabelIdentity)];
            NSMenuItem *enabledSaveItem = UIHState.commandItems[@(saveCommandIdentity)];
            if (editedMainWindow == nil || editedGreeting == nil || enabledSaveItem == nil) {
              UIHTestFail(@"native scene disappeared before keyboard-equivalent validation");
              [NSApplication.sharedApplication stop:nil];
              return;
            }
            NSString *greeting = ((NSTextField *)editedGreeting.view).stringValue;
            if (![greeting isEqualToString:@"Hello, Ada!"]) {
              UIHTestFail(@"text delegate callback did not reconcile the greeting label");
            }
            if (!enabledSaveItem.enabled) {
              UIHTestFail(@"Save command unexpectedly disabled before keyboard dispatch");
            }

            NSEvent *commandS =
                [NSEvent keyEventWithType:NSEventTypeKeyDown
                                 location:NSZeroPoint
                            modifierFlags:NSEventModifierFlagCommand
                                timestamp:NSProcessInfo.processInfo.systemUptime
                             windowNumber:editedMainWindow.window.windowNumber
                                  context:nil
                               characters:@"s"
              charactersIgnoringModifiers:@"s"
                                isARepeat:NO
                                  keyCode:1];
            if (![NSApplication.sharedApplication.mainMenu performKeyEquivalent:commandS]) {
              UIHTestFail(@"AppKit main menu did not handle the Command-S key equivalent");
            }

            UIHTestAfter(0.12, ^{
              UIHMacWindowHandle *savedMainWindow = UIHState.windows[@(mainWindowIdentity)];
              NSMenuItem *disabledSaveItem = UIHState.commandItems[@(saveCommandIdentity)];
              if (savedMainWindow == nil || disabledSaveItem == nil) {
                UIHTestFail(@"main window or Save command disappeared after keyboard dispatch");
                [NSApplication.sharedApplication stop:nil];
                return;
              }
              if ([savedMainWindow.window.title containsString:@"Edited"] ||
                  disabledSaveItem.enabled) {
                UIHTestFail(@"Command-S did not reconcile saved state into window and menu");
              }
              [savedMainWindow.window performClose:nil];

              UIHTestAfter(0.50, ^{
                if (UIHState != nil) {
                  UIHTestFail(@"vertical validation timed out before the application stopped");
                  [NSApplication.sharedApplication stop:nil];
                }
              });
            });
          });
        });
      });
}

void uih_macos_test_schedule_text_editor_script(
    uint64_t documentWindowIdentity,
    uint64_t editorIdentity,
    uint64_t saveCommandIdentity) {
  UIHAssertMainThread();

  UIHTestAfter(0.10, ^{
    UIHMacWindowHandle *documentWindow = UIHState.windows[@(documentWindowIdentity)];
    UIHMacControlHandle *editorHandle = UIHState.controls[@(editorIdentity)];
    NSMenuItem *saveItem = UIHState.commandItems[@(saveCommandIdentity)];
    if (documentWindow == nil || editorHandle == nil || saveItem == nil ||
        editorHandle.kind != UIHMacControlKindTextEditor) {
      UIHTestFail(@"native text editor scene was not registered");
      [NSApplication.sharedApplication stop:nil];
      return;
    }

    NSTextView *editor = (NSTextView *)editorHandle.focusView;
    NSString *expectedIdentifier =
        [NSString stringWithFormat:@"uih-control-%llu", editorIdentity];
    if (![editor.accessibilityIdentifier isEqualToString:expectedIdentifier] ||
        ![editor.accessibilityRole isEqualToString:NSAccessibilityTextAreaRole]) {
      UIHTestFail(@"native text editor accessibility identity or role is incorrect");
    }
    if (![editor.string isEqualToString:@"😀 module Initial where\n"]) {
      UIHTestFail(@"native text editor did not retain the Unicode fixture");
    } else {
      NSDictionary<NSAttributedStringKey, id> *baseAttributes =
          [editor.layoutManager temporaryAttributesAtCharacterIndex:2 effectiveRange:NULL];
      NSDictionary<NSAttributedStringKey, id> *keywordAttributes =
          [editor.layoutManager temporaryAttributesAtCharacterIndex:3 effectiveRange:NULL];
      NSColor *baseColor = baseAttributes[NSForegroundColorAttributeName];
      NSColor *keywordColor = keywordAttributes[NSForegroundColorAttributeName];
      if (baseColor == nil || keywordColor == nil || [baseColor isEqual:keywordColor]) {
        UIHTestFail(@"Unicode scalar ranges were not translated to the highlighted AppKit range");
      }
    }
    uih_macos_open_text_files();
    if (UIHState.openPanel == nil || !UIHState.openPanel.visible) {
      UIHTestFail(@"native multi-file Open panel did not become visible");
    }
    [UIHState.openPanel cancel:nil];
    [documentWindow.window makeKeyAndOrderFront:nil];
    if (![documentWindow.window makeFirstResponder:editor] ||
        !UIHResponderBelongsToView(documentWindow.window.firstResponder, editor)) {
      UIHTestFail(@"native text editor could not become first responder");
    }

    editor.string = @"module Saved where\nanswer = 42\n";
    NSRange expectedSelection = NSMakeRange(7, 5);
    editor.selectedRange = expectedSelection;
    [editor.undoManager removeAllActions];
    [editor.delegate textDidChange:
        [NSNotification notificationWithName:NSTextDidChangeNotification object:editor]];

    UIHTestAfter(0.12, ^{
      UIHMacWindowHandle *editedWindow = UIHState.windows[@(documentWindowIdentity)];
      NSMenuItem *enabledSaveItem = UIHState.commandItems[@(saveCommandIdentity)];
      if (editedWindow == nil || enabledSaveItem == nil) {
        UIHTestFail(@"text editor scene disappeared after native edit callback");
        [NSApplication.sharedApplication stop:nil];
        return;
      }
      if (![editedWindow.window.title containsString:@"Edited"] || !enabledSaveItem.enabled) {
        UIHTestFail(@"native text edit did not reconcile dirty document state");
      }
      UIHMacControlHandle *editedEditorHandle = UIHState.controls[@(editorIdentity)];
      NSTextView *editedEditor = (NSTextView *)editedEditorHandle.focusView;
      NSDictionary<NSAttributedStringKey, id> *baseAttributes =
          [editedEditor.layoutManager temporaryAttributesAtCharacterIndex:6 effectiveRange:NULL];
      NSDictionary<NSAttributedStringKey, id> *keywordAttributes =
          [editedEditor.layoutManager temporaryAttributesAtCharacterIndex:0 effectiveRange:NULL];
      NSColor *baseColor = baseAttributes[NSForegroundColorAttributeName];
      NSColor *keywordColor = keywordAttributes[NSForegroundColorAttributeName];
      if (baseColor == nil || keywordColor == nil || [baseColor isEqual:keywordColor]) {
        UIHTestFail(@"syntax presentation was not refreshed after a native edit");
      }
      if (!NSEqualRanges(editedEditor.selectedRange, expectedSelection)) {
        UIHTestFail(@"syntax presentation changed the native selection");
      }
      if (editedEditor.undoManager.canUndo) {
        UIHTestFail(@"syntax presentation created a native undo action");
      }

      NSEvent *commandS =
          [NSEvent keyEventWithType:NSEventTypeKeyDown
                           location:NSZeroPoint
                      modifierFlags:NSEventModifierFlagCommand
                          timestamp:NSProcessInfo.processInfo.systemUptime
                       windowNumber:editedWindow.window.windowNumber
                            context:nil
                         characters:@"s"
        charactersIgnoringModifiers:@"s"
                          isARepeat:NO
                            keyCode:1];
      if (![NSApplication.sharedApplication.mainMenu performKeyEquivalent:commandS]) {
        UIHTestFail(@"text editor Save command did not handle Command-S");
      }

      UIHTestAfter(0.12, ^{
        UIHMacWindowHandle *savedWindow = UIHState.windows[@(documentWindowIdentity)];
        NSMenuItem *disabledSaveItem = UIHState.commandItems[@(saveCommandIdentity)];
        if (savedWindow == nil || disabledSaveItem == nil) {
          UIHTestFail(@"text editor scene disappeared after Save");
          [NSApplication.sharedApplication stop:nil];
          return;
        }
        if ([savedWindow.window.title containsString:@"Edited"] || disabledSaveItem.enabled) {
          UIHTestFail(@"successful file write did not reconcile saved document state");
        }
        [savedWindow.window performClose:nil];

        UIHTestAfter(0.30, ^{
          if (UIHState != nil && UIHState.windows[@(documentWindowIdentity)] != nil) {
            UIHTestFail(@"saved document close request did not remove its native window");
            [NSApplication.sharedApplication stop:nil];
          } else if (UIHState != nil) {
            UIHTestFail(@"last document closed but the application did not stop");
            [NSApplication.sharedApplication stop:nil];
          }
        });
      });
    });
  });
}
