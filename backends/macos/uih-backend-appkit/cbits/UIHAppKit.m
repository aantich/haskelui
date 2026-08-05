#import "UIHAppKit.h"
#import "compat/UIHAppKitCompatibility.h"

#import <dispatch/dispatch.h>

typedef NS_ENUM(NSInteger, UIHMacControlKind) {
  UIHMacControlKindLabel,
  UIHMacControlKindButton,
  UIHMacControlKindTextField
};

@interface UIHMacApplicationState : NSObject
@property(nonatomic, assign) UIHMacEventCallback callback;
@property(nonatomic, assign) void *callbackContext;
@property(nonatomic, strong) NSMenu *fileMenu;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSMenuItem *> *commandItems;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, id> *commandTargets;
@end

@implementation UIHMacApplicationState
@end

static UIHMacApplicationState *UIHState = nil;

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
  dispatch_async(dispatch_get_main_queue(), ^{
    UIHMacApplicationState *state = UIHState;
    if (state == nil || state.callback == NULL) {
      return;
    }
    @autoreleasepool {
      state.callback(
          state.callbackContext,
          kind,
          identity,
          [copiedText UTF8String]);
    }
  });
}

@interface UIHMacActionTarget : NSObject <NSTextFieldDelegate>
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
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) UIHMacWindowDelegate *delegate;
@end

@implementation UIHMacWindowHandle
@end

@interface UIHMacControlHandle : NSObject
@property(nonatomic, strong) NSView *view;
@property(nonatomic, strong) UIHMacActionTarget *target;
@property(nonatomic, assign) UIHMacControlKind kind;
@end

@implementation UIHMacControlHandle
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

  UIHMacWindowDelegate *delegate = [[UIHMacWindowDelegate alloc] init];
  delegate.identity = identity;
  window.delegate = delegate;

  UIHMacWindowHandle *handle = [[UIHMacWindowHandle alloc] init];
  handle.window = window;
  handle.delegate = delegate;
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
  handle.window.delegate = nil;
  [handle.window orderOut:nil];
  [handle.window close];
  handle.delegate = nil;
  handle.window = nil;
}

static UIHMacControlRef UIHRetainControl(
    NSView *view,
    UIHMacActionTarget *target,
    UIHMacControlKind kind,
    UIHMacWindowRef windowReference) {
  UIHMacControlHandle *handle = [[UIHMacControlHandle alloc] init];
  handle.view = view;
  handle.target = target;
  handle.kind = kind;
  [UIHWindow(windowReference).window.contentView addSubview:view];
  return (__bridge_retained void *)handle;
}

UIHMacControlRef uih_macos_label_create(
    UIHMacWindowRef window,
    uint64_t identity,
    const char *utf8_text,
    const UIHMacRect *frame) {
  UIHAssertMainThread();
  (void)identity;
  NSTextField *label = [[NSTextField alloc] initWithFrame:UIHRect(frame)];
  label.stringValue = UIHString(utf8_text);
  label.editable = NO;
  label.selectable = NO;
  label.bezeled = NO;
  label.drawsBackground = NO;
  return UIHRetainControl(label, nil, UIHMacControlKindLabel, window);
}

UIHMacControlRef uih_macos_button_create(
    UIHMacWindowRef window,
    uint64_t identity,
    const char *utf8_title,
    uint64_t command_identity,
    const UIHMacRect *frame) {
  UIHAssertMainThread();
  (void)identity;
  UIHMacActionTarget *target = [[UIHMacActionTarget alloc] init];
  target.identity = command_identity;
  target.eventKind = UIHMacEventCommand;

  NSButton *button = [[NSButton alloc] initWithFrame:UIHRect(frame)];
  button.title = UIHString(utf8_title);
  button.bezelStyle = NSBezelStyleRounded;
  button.target = target;
  button.action = @selector(performAction:);
  return UIHRetainControl(button, target, UIHMacControlKindButton, window);
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
  return UIHRetainControl(field, target, UIHMacControlKindTextField, window);
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

void uih_macos_control_destroy(UIHMacControlRef reference) {
  UIHAssertMainThread();
  if (reference == NULL) {
    return;
  }
  UIHMacControlHandle *handle = (__bridge_transfer UIHMacControlHandle *)reference;
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
