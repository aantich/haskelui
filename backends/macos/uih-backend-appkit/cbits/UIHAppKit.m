#import "UIHAppKit.h"
#import "compat/UIHAppKitCompatibility.h"

#import <dispatch/dispatch.h>

typedef NS_ENUM(NSInteger, UIHMacControlKind) {
  UIHMacControlKindLabel,
  UIHMacControlKindButton,
  UIHMacControlKindTextField
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

@interface UIHMacActionTarget : NSObject <NSTextFieldDelegate>
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, assign) int32_t eventKind;
- (void)performAction:(id)sender;
@end

@implementation UIHMacActionTarget
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    UIHLiveActionTargets += 1;
  }
  return self;
}

- (void)dealloc {
  UIHLiveActionTargets -= 1;
}

- (void)performAction:(id)sender {
  (void)sender;
  UIHEmit(self.eventKind, self.identity, @"");
}

- (void)controlTextDidChange:(NSNotification *)notification {
  NSTextField *field = notification.object;
  UIHEmit(UIHMacEventTextChanged, self.identity, field.stringValue);
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
  [NSApplication.sharedApplication stop:nil];
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
    UIHMacActionTarget *target,
    UIHMacControlKind kind,
    uint64_t identity,
    UIHMacWindowRef windowReference) {
  UIHMacControlHandle *handle = [[UIHMacControlHandle alloc] init];
  handle.identity = identity;
  handle.view = view;
  handle.target = target;
  handle.kind = kind;
  view.accessibilityElement = YES;
  view.accessibilityIdentifier = [NSString stringWithFormat:@"uih-control-%llu", identity];
  switch (kind) {
    case UIHMacControlKindLabel:
      view.accessibilityRole = NSAccessibilityStaticTextRole;
      break;
    case UIHMacControlKindButton:
      view.accessibilityRole = NSAccessibilityButtonRole;
      break;
    case UIHMacControlKindTextField:
      view.accessibilityRole = NSAccessibilityTextFieldRole;
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
  return UIHRetainControl(label, nil, UIHMacControlKindLabel, identity, window);
}

UIHMacControlRef uih_macos_button_create(
    UIHMacWindowRef window,
    uint64_t identity,
    const char *utf8_title,
    uint64_t command_identity,
    const UIHMacRect *frame) {
  UIHAssertMainThread();
  UIHMacActionTarget *target = [[UIHMacActionTarget alloc] init];
  target.identity = command_identity;
  target.eventKind = UIHMacEventCommand;

  NSButton *button = [[NSButton alloc] initWithFrame:UIHRect(frame)];
  button.title = UIHString(utf8_title);
  button.bezelStyle = NSBezelStyleRounded;
  button.target = target;
  button.action = @selector(performAction:);
  return UIHRetainControl(button, target, UIHMacControlKindButton, identity, window);
}

UIHMacControlRef uih_macos_text_field_create(
    UIHMacWindowRef window,
    uint64_t identity,
    const char *utf8_text,
    const char *utf8_placeholder,
    const UIHMacRect *frame) {
  UIHAssertMainThread();
  UIHMacActionTarget *target = [[UIHMacActionTarget alloc] init];
  target.identity = identity;
  target.eventKind = UIHMacEventTextChanged;

  NSTextField *field = [[NSTextField alloc] initWithFrame:UIHRect(frame)];
  field.stringValue = UIHString(utf8_text);
  field.placeholderString = UIHString(utf8_placeholder);
  field.delegate = target;
  return UIHRetainControl(field, target, UIHMacControlKindTextField, identity, window);
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
  [UIHWindow(window).window makeFirstResponder:UIHControl(control).view];
}

void uih_macos_control_set_next_key(
    UIHMacControlRef reference,
    UIHMacControlRef nextReference) {
  UIHAssertMainThread();
  UIHControl(reference).view.nextKeyView = UIHControl(nextReference).view;
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
  if ([handle.view isKindOfClass:NSControl.class]) {
    ((NSControl *)handle.view).target = nil;
    ((NSControl *)handle.view).action = nil;
  }
  [handle.view removeFromSuperview];
  handle.target = nil;
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
  [UIHState.commandTargets removeObjectForKey:key];
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
