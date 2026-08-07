#import "HaskeLUIAppKit.h"
#import "compat/HaskeLUIAppKitCompatibility.h"

#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <sys/file.h>
#import <unistd.h>

_Static_assert(sizeof(HaskeLUIMacTextStyle) == 152, "HaskeLUIMacTextStyle ABI must match its Haskell Storable instance");
_Static_assert(sizeof(HaskeLUIMacDrawingInput) == 64, "HaskeLUIMacDrawingInput ABI must match its Haskell Storable instance");

typedef NS_ENUM(NSInteger, HaskeLUIMacControlKind) {
  HaskeLUIMacControlKindLabel,
  HaskeLUIMacControlKindButton,
  HaskeLUIMacControlKindTextField,
  HaskeLUIMacControlKindTextEditor,
  HaskeLUIMacControlKindDrawing,
  HaskeLUIMacControlKindCatalog
};

@class HaskeLUIMacWindowHandle;
@class HaskeLUIMacControlHandle;
@class HaskeLUIMacTabGroupHandle;
@class HaskeLUIMacTabHandle;
@class HaskeLUIMacSplitViewDelegate;

static void HaskeLUIEmit(int32_t kind, uint64_t identity, NSString *text);
static void HaskeLUIEmitDrawingInput(uint64_t identity, HaskeLUIMacDrawingInput input);
static NSString *HaskeLUISystemColorScheme(void);
static void *HaskeLUIEffectiveAppearanceContext = &HaskeLUIEffectiveAppearanceContext;

@interface HaskeLUIMacApplicationState : NSObject
@property(nonatomic, assign) HaskeLUIMacEventCallback callback;
@property(nonatomic, assign) void *callbackContext;
@property(nonatomic, assign) HaskeLUIMacDrawingInputCallback drawingInputCallback;
@property(nonatomic, assign) void *drawingInputCallbackContext;
@property(nonatomic, strong) NSMenu *fileMenu;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSMenuItem *> *commandItems;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, id> *commandTargets;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, HaskeLUIMacWindowHandle *> *windows;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, HaskeLUIMacControlHandle *> *controls;
@property(nonatomic, strong) NSOpenPanel *openPanel;
@property(nonatomic, assign) BOOL observingEffectiveAppearance;
@end

@implementation HaskeLUIMacApplicationState
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
  (void)keyPath;
  (void)object;
  (void)change;
  if (context == HaskeLUIEffectiveAppearanceContext) {
    HaskeLUIEmit(
        HaskeLUIMacEventSystemColorSchemeChanged,
        0,
        HaskeLUISystemColorScheme());
    return;
  }
  [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}
@end

static HaskeLUIMacApplicationState *HaskeLUIState = nil;
static int32_t HaskeLUILiveWindows = 0;
static int32_t HaskeLUILiveControls = 0;
static int32_t HaskeLUILiveActionTargets = 0;
static int32_t HaskeLUILiveWindowDelegates = 0;
static int32_t HaskeLUIQueuedCallbacks = 0;
static int32_t HaskeLUITestFailures = 0;
static NSString *HaskeLUILastTestFailure = nil;
static BOOL HaskeLUIControlGalleryTestActive = NO;
static int HaskeLUITestProcessLockDescriptor = -1;
static const double HaskeLUIPaneResizeCommitDelaySeconds = 0.05;

static NSColor *HaskeLUIColor(double red, double green, double blue, double alpha);
static NSFont *HaskeLUIFontForStyle(NSFont *existingFont, const HaskeLUIMacTextStyle *style);
static NSUnderlineStyle HaskeLUIUnderlineStyle(int32_t style);

static void HaskeLUIAssertMainThread(void) {
  NSCAssert(HaskeLUIAppKitIsMainThread(), @"HaskeLUI AppKit operation must run on the process main thread");
}

static NSString *HaskeLUIString(const char *utf8) {
  if (utf8 == NULL) {
    return @"";
  }
  NSString *value = [NSString stringWithUTF8String:utf8];
  return value == nil ? @"" : value;
}

static NSRect HaskeLUIRect(const HaskeLUIMacRect *frame) {
  return NSMakeRect(frame->x, frame->y, frame->width, frame->height);
}

static void HaskeLUIEmit(int32_t kind, uint64_t identity, NSString *text) {
  NSString *copiedText = text == nil ? @"" : [text copy];
  __sync_add_and_fetch(&HaskeLUIQueuedCallbacks, 1);
  dispatch_async(dispatch_get_main_queue(), ^{
    HaskeLUIMacApplicationState *state = HaskeLUIState;
    if (state != nil && state.callback != NULL) {
      state.callback(
          state.callbackContext,
          kind,
          identity,
          [copiedText UTF8String]);
    }
    __sync_sub_and_fetch(&HaskeLUIQueuedCallbacks, 1);
  });
}

static void HaskeLUIEmitDrawingInput(uint64_t identity, HaskeLUIMacDrawingInput input) {
  __sync_add_and_fetch(&HaskeLUIQueuedCallbacks, 1);
  dispatch_async(dispatch_get_main_queue(), ^{
    HaskeLUIMacApplicationState *state = HaskeLUIState;
    if (state != nil && state.drawingInputCallback != NULL) {
      state.drawingInputCallback(
          state.drawingInputCallbackContext,
          identity,
          &input);
    }
    __sync_sub_and_fetch(&HaskeLUIQueuedCallbacks, 1);
  });
}

static NSString *HaskeLUISystemColorScheme(void) {
  NSAppearanceName match =
      [NSApplication.sharedApplication.effectiveAppearance
          bestMatchFromAppearancesWithNames:@[
            NSAppearanceNameAqua,
            NSAppearanceNameDarkAqua
          ]];
  return [match isEqualToString:NSAppearanceNameDarkAqua] ? @"dark" : @"light";
}

@interface HaskeLUIContainerHostView : NSView
@property(nonatomic, assign) BOOL usesTopLeftCoordinates;
@end

@implementation HaskeLUIContainerHostView
- (BOOL)isFlipped {
  return self.usesTopLeftCoordinates;
}
@end

typedef NS_ENUM(NSInteger, HaskeLUIDrawingCommandKind) {
  HaskeLUIDrawingPushState,
  HaskeLUIDrawingPopState,
  HaskeLUIDrawingTransform,
  HaskeLUIDrawingBeginOpacity,
  HaskeLUIDrawingEndOpacity,
  HaskeLUIDrawingClip,
  HaskeLUIDrawingFill,
  HaskeLUIDrawingStroke,
  HaskeLUIDrawingText
};

@interface HaskeLUIDrawingView : NSView
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, assign) BOOL drawingInputEnabled;
@property(nonatomic, assign) NSInteger drawingCursor;
@property(nonatomic, assign) uint64_t drawingPresentationGeneration;
@property(nonatomic, strong) NSTrackingArea *drawingTrackingArea;
@property(nonatomic, copy) NSArray<NSDictionary *> *drawingCommands;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *pendingCommands;
@property(nonatomic, strong) NSBezierPath *pendingPath;
@end

@implementation HaskeLUIDrawingView
- (BOOL)isFlipped {
  return YES;
}

- (BOOL)isOpaque {
  return NO;
}

- (BOOL)acceptsFirstResponder {
  return self.drawingInputEnabled;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  (void)event;
  return self.drawingInputEnabled;
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (self.drawingTrackingArea != nil) {
    [self removeTrackingArea:self.drawingTrackingArea];
    self.drawingTrackingArea = nil;
  }
  if (self.drawingInputEnabled) {
    self.drawingTrackingArea =
        [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:NSTrackingMouseEnteredAndExited |
                         NSTrackingMouseMoved |
                         NSTrackingActiveInKeyWindow |
                         NSTrackingInVisibleRect
                   owner:self
                userInfo:nil];
    [self addTrackingArea:self.drawingTrackingArea];
  }
}

- (void)resetCursorRects {
  [super resetCursorRects];
  if (!self.drawingInputEnabled) {
    return;
  }
  NSCursor *cursor = NSCursor.arrowCursor;
  switch (self.drawingCursor) {
    case 1: cursor = NSCursor.pointingHandCursor; break;
    case 2: cursor = NSCursor.crosshairCursor; break;
    case 3: cursor = NSCursor.openHandCursor; break;
    case 4: cursor = NSCursor.closedHandCursor; break;
    case 5: cursor = NSCursor.IBeamCursor; break;
    case 6: cursor = NSCursor.resizeLeftRightCursor; break;
    case 7: cursor = NSCursor.resizeUpDownCursor; break;
    default: break;
  }
  [self addCursorRect:self.bounds cursor:cursor];
}

- (uint32_t)portableButtons {
  NSUInteger pressed = NSEvent.pressedMouseButtons;
  uint32_t result = 0;
  if ((pressed & (1u << 0)) != 0) result |= 1u << 0;
  if ((pressed & (1u << 1)) != 0) result |= 1u << 1;
  if ((pressed & (1u << 2)) != 0) result |= 1u << 2;
  if ((pressed & (1u << 3)) != 0) result |= 1u << 3;
  if ((pressed & (1u << 4)) != 0) result |= 1u << 4;
  return result;
}

- (uint32_t)portableButtonsForEvent:(NSEvent *)event {
  uint32_t buttons = [self portableButtons];
  switch (event.type) {
    case NSEventTypeLeftMouseDown:
    case NSEventTypeLeftMouseDragged: buttons |= 1u << 0; break;
    case NSEventTypeRightMouseDown:
    case NSEventTypeRightMouseDragged: buttons |= 1u << 1; break;
    case NSEventTypeOtherMouseDown:
    case NSEventTypeOtherMouseDragged:
      if (event.buttonNumber >= 2 && event.buttonNumber <= 4) {
        buttons |= 1u << event.buttonNumber;
      }
      break;
    case NSEventTypeLeftMouseUp: buttons &= ~(1u << 0); break;
    case NSEventTypeRightMouseUp: buttons &= ~(1u << 1); break;
    case NSEventTypeOtherMouseUp:
      if (event.buttonNumber >= 2 && event.buttonNumber <= 4) {
        buttons &= ~(1u << event.buttonNumber);
      }
      break;
    default: break;
  }
  return buttons;
}

- (uint32_t)portableModifiers:(NSEventModifierFlags)flags {
  uint32_t result = 0;
  if ((flags & NSEventModifierFlagShift) != 0) result |= 1u << 0;
  if ((flags & NSEventModifierFlagControl) != 0) result |= 1u << 1;
  if ((flags & NSEventModifierFlagOption) != 0) result |= 1u << 2;
  if ((flags & NSEventModifierFlagCommand) != 0) result |= 1u << 3;
  return result;
}

- (int32_t)portableButton:(NSInteger)buttonNumber {
  return buttonNumber >= 0 && buttonNumber <= 4 ? (int32_t)buttonNumber : -1;
}

- (void)emitPointerEvent:(NSEvent *)event
                    kind:(HaskeLUIMacDrawingInputKind)kind
           changedButton:(int32_t)changedButton {
  if (!self.drawingInputEnabled) {
    return;
  }
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  HaskeLUIMacDrawingInput input = {
    .kind = kind,
    .changed_button = changedButton,
    .pointer_identity = 1,
    .x = point.x,
    .y = point.y,
    .delta_x = event.deltaX,
    .delta_y = event.deltaY,
    .buttons = [self portableButtonsForEvent:event],
    .modifiers = [self portableModifiers:event.modifierFlags],
    .click_count = (int32_t)event.clickCount,
    .precise = 0
  };
  HaskeLUIEmitDrawingInput(self.identity, input);
}

- (void)mouseDown:(NSEvent *)event {
  [self.window makeFirstResponder:self];
  [self emitPointerEvent:event kind:HaskeLUIMacDrawingPointerDown changedButton:0];
}
- (void)rightMouseDown:(NSEvent *)event { [self emitPointerEvent:event kind:HaskeLUIMacDrawingPointerDown changedButton:1]; }
- (void)otherMouseDown:(NSEvent *)event { [self emitPointerEvent:event kind:HaskeLUIMacDrawingPointerDown changedButton:[self portableButton:event.buttonNumber]]; }
- (void)mouseDragged:(NSEvent *)event { [self emitPointerEvent:event kind:HaskeLUIMacDrawingPointerMoved changedButton:-1]; }
- (void)rightMouseDragged:(NSEvent *)event { [self emitPointerEvent:event kind:HaskeLUIMacDrawingPointerMoved changedButton:-1]; }
- (void)otherMouseDragged:(NSEvent *)event { [self emitPointerEvent:event kind:HaskeLUIMacDrawingPointerMoved changedButton:-1]; }
- (void)mouseUp:(NSEvent *)event { [self emitPointerEvent:event kind:HaskeLUIMacDrawingPointerUp changedButton:0]; }
- (void)rightMouseUp:(NSEvent *)event { [self emitPointerEvent:event kind:HaskeLUIMacDrawingPointerUp changedButton:1]; }
- (void)otherMouseUp:(NSEvent *)event { [self emitPointerEvent:event kind:HaskeLUIMacDrawingPointerUp changedButton:[self portableButton:event.buttonNumber]]; }
- (void)mouseMoved:(NSEvent *)event { [self emitPointerEvent:event kind:HaskeLUIMacDrawingPointerMoved changedButton:-1]; }
- (void)mouseEntered:(NSEvent *)event { [self emitPointerEvent:event kind:HaskeLUIMacDrawingPointerEntered changedButton:-1]; }
- (void)mouseExited:(NSEvent *)event { [self emitPointerEvent:event kind:HaskeLUIMacDrawingPointerExited changedButton:-1]; }

- (void)scrollWheel:(NSEvent *)event {
  if (!self.drawingInputEnabled) {
    return;
  }
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  HaskeLUIMacDrawingInput input = {
    .kind = HaskeLUIMacDrawingScroll,
    .changed_button = -1,
    .pointer_identity = 1,
    .x = point.x,
    .y = point.y,
    .delta_x = event.scrollingDeltaX,
    .delta_y = -event.scrollingDeltaY,
    .buttons = [self portableButtons],
    .modifiers = [self portableModifiers:event.modifierFlags],
    .click_count = 0,
    .precise = event.hasPreciseScrollingDeltas ? 1 : 0
  };
  HaskeLUIEmitDrawingInput(self.identity, input);
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  CGContextRef context = NSGraphicsContext.currentContext.CGContext;
  for (NSDictionary *command in self.drawingCommands ?: @[]) {
    switch ((HaskeLUIDrawingCommandKind)[command[@"kind"] integerValue]) {
      case HaskeLUIDrawingPushState:
        [NSGraphicsContext saveGraphicsState];
        break;
      case HaskeLUIDrawingPopState:
        [NSGraphicsContext restoreGraphicsState];
        break;
      case HaskeLUIDrawingTransform: {
        NSAffineTransform *transform = [NSAffineTransform transform];
        NSAffineTransformStruct matrix = {
          [command[@"a"] doubleValue],
          [command[@"b"] doubleValue],
          [command[@"c"] doubleValue],
          [command[@"d"] doubleValue],
          [command[@"tx"] doubleValue],
          [command[@"ty"] doubleValue]
        };
        transform.transformStruct = matrix;
        [transform concat];
        break;
      }
      case HaskeLUIDrawingBeginOpacity:
        CGContextSaveGState(context);
        CGContextSetAlpha(context, [command[@"alpha"] doubleValue]);
        CGContextBeginTransparencyLayer(context, NULL);
        break;
      case HaskeLUIDrawingEndOpacity:
        CGContextEndTransparencyLayer(context);
        CGContextRestoreGState(context);
        break;
      case HaskeLUIDrawingClip: {
        NSBezierPath *path = command[@"path"];
        path.windingRule = [command[@"evenOdd"] boolValue]
            ? NSWindingRuleEvenOdd
            : NSWindingRuleNonZero;
        [path addClip];
        break;
      }
      case HaskeLUIDrawingFill: {
        NSBezierPath *path = command[@"path"];
        path.windingRule = [command[@"evenOdd"] boolValue]
            ? NSWindingRuleEvenOdd
            : NSWindingRuleNonZero;
        [(NSColor *)command[@"color"] setFill];
        [path fill];
        break;
      }
      case HaskeLUIDrawingStroke: {
        NSBezierPath *path = [command[@"path"] copy];
        path.lineWidth = [command[@"width"] doubleValue];
        path.lineCapStyle = (NSLineCapStyle)[command[@"cap"] integerValue];
        path.lineJoinStyle = (NSLineJoinStyle)[command[@"join"] integerValue];
        path.miterLimit = [command[@"miter"] doubleValue];
        NSArray<NSNumber *> *dash = command[@"dash"];
        if (dash.count > 0) {
          CGFloat pattern[dash.count];
          for (NSUInteger index = 0; index < dash.count; index += 1) {
            pattern[index] = dash[index].doubleValue;
          }
          [path setLineDash:pattern
                      count:(NSInteger)dash.count
                      phase:[command[@"phase"] doubleValue]];
        }
        [(NSColor *)command[@"color"] setStroke];
        [path stroke];
        break;
      }
      case HaskeLUIDrawingText: {
        NSString *text = command[@"text"];
        NSDictionary *attributes = command[@"attributes"];
        NSRect rect = [command[@"rect"] rectValue];
        NSStringDrawingOptions options = [command[@"wrap"] integerValue] == 0
            ? 0
            : NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading;
        NSRect bounds = [text boundingRectWithSize:rect.size options:options attributes:attributes];
        switch ([command[@"vertical"] integerValue]) {
          case 1:
            rect.origin.y += MAX(0, (rect.size.height - NSHeight(bounds)) / 2.0);
            break;
          case 2:
            rect.origin.y += MAX(0, rect.size.height - NSHeight(bounds));
            break;
          default:
            break;
        }
        [text drawWithRect:rect options:options attributes:attributes];
        break;
      }
    }
  }
}
@end

@interface HaskeLUIMacActionTarget : NSObject <NSTextFieldDelegate, NSTextViewDelegate>
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, assign) int32_t eventKind;
@property(nonatomic, copy) NSString *fixedPayload;
@property(nonatomic, assign) uint64_t secondaryIdentity;
@property(nonatomic, assign) int32_t secondaryEventKind;
- (void)performAction:(id)sender;
@end

@implementation HaskeLUIMacActionTarget
- (void)performAction:(id)sender {
  NSString *payload = self.fixedPayload ?: @"";
  if (self.fixedPayload == nil) {
    if (self.eventKind == HaskeLUIMacEventToggleChanged ||
        self.eventKind == HaskeLUIMacEventDisclosureChanged) {
      payload = [NSString stringWithFormat:@"%ld", (long)((NSControl *)sender).integerValue];
    } else if (self.eventKind == HaskeLUIMacEventNumberChanged) {
      payload = [NSString stringWithFormat:@"%.17g", ((NSControl *)sender).doubleValue];
    } else if (self.eventKind == HaskeLUIMacEventChoiceChanged) {
      NSNumber *choice = nil;
      if ([sender isKindOfClass:NSPopUpButton.class]) {
        choice = ((NSPopUpButton *)sender).selectedItem.representedObject;
      } else if ([sender isKindOfClass:NSSegmentedControl.class]) {
        NSSegmentedControl *segments = sender;
        NSInteger selected = segments.selectedSegment;
        choice = selected >= 0 ? @([segments tagForSegment:selected]) : nil;
      } else if ([sender isKindOfClass:NSButton.class]) {
        choice = @(((NSButton *)sender).tag);
      }
      payload = choice == nil ? @"" : choice.stringValue;
    } else if (self.eventKind == HaskeLUIMacEventDateChanged ||
               self.eventKind == HaskeLUIMacEventTimeChanged) {
      NSDatePicker *picker = sender;
      NSDateComponents *parts = [[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian]
          components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                      NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond)
          fromDate:picker.dateValue];
      payload = [NSString stringWithFormat:@"%04ld-%02ld-%02ldT%02ld:%02ld:%02ld",
          (long)parts.year, (long)parts.month, (long)parts.day,
          (long)parts.hour, (long)parts.minute, (long)parts.second];
    } else if (self.eventKind == HaskeLUIMacEventColorChanged) {
      NSColor *color = [((NSColorWell *)sender).color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
      payload = [NSString stringWithFormat:@"%.17g,%.17g,%.17g,%.17g",
          color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent];
    }
  }
  HaskeLUIEmit(self.eventKind, self.identity, payload);
  if (self.secondaryEventKind != 0) {
    HaskeLUIEmit(self.secondaryEventKind, self.secondaryIdentity, @"");
  }
}

- (void)controlTextDidChange:(NSNotification *)notification {
  NSTextField *field = notification.object;
  HaskeLUIEmit(HaskeLUIMacEventTextChanged, self.identity, field.stringValue);
}

- (void)textDidChange:(NSNotification *)notification {
  NSTextView *editor = notification.object;
  HaskeLUIEmit(HaskeLUIMacEventTextChanged, self.identity, editor.string);
}
@end

static NSImage *HaskeLUIImageSource(NSString *source);

@interface HaskeLUICenteredTableCellView : NSTableCellView
@property(nonatomic, strong) NSTextField *centeredLabel;
- (instancetype)initWithText:(NSString *)text
                  imageSource:(NSString *)imageSource
                 contentSized:(BOOL)contentSized;
@end

@implementation HaskeLUICenteredTableCellView
- (instancetype)initWithText:(NSString *)text
                  imageSource:(NSString *)imageSource
                 contentSized:(BOOL)contentSized {
  self = [super initWithFrame:NSZeroRect];
  if (self != nil) {
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:label];
    NSImage *image = HaskeLUIImageSource(imageSource);
    NSImageView *imageView = nil;
    if (image != nil) {
      imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
      imageView.translatesAutoresizingMaskIntoConstraints = NO;
      imageView.image = image;
      imageView.imageScaling = NSImageScaleProportionallyDown;
      [self addSubview:imageView];
      self.imageView = imageView;
    }
    NSLayoutXAxisAnchor *leadingAnchor = imageView == nil
        ? self.leadingAnchor
        : imageView.trailingAnchor;
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
      [label.leadingAnchor constraintEqualToSystemSpacingAfterAnchor:leadingAnchor
                                                          multiplier:1],
      [self.trailingAnchor constraintGreaterThanOrEqualToSystemSpacingAfterAnchor:label.trailingAnchor
                                                                        multiplier:1]
    ]];
    if (imageView != nil) {
      [constraints addObjectsFromArray:@[
        [imageView.leadingAnchor constraintEqualToSystemSpacingAfterAnchor:self.leadingAnchor
                                                                 multiplier:1],
        [imageView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [imageView.widthAnchor constraintEqualToConstant:16],
        [imageView.heightAnchor constraintEqualToConstant:16]
      ]];
    }
    if (contentSized) {
      [constraints addObjectsFromArray:@[
        [label.topAnchor constraintEqualToSystemSpacingBelowAnchor:self.topAnchor
                                                        multiplier:0.5],
        [self.bottomAnchor constraintEqualToSystemSpacingBelowAnchor:label.bottomAnchor
                                                          multiplier:0.5]
      ]];
    } else {
      [constraints addObject:
          [label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    self.textField = label;
    self.centeredLabel = label;
  }
  return self;
}
@end

@interface HaskeLUIMacCollectionAdapter : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *items;
@property(nonatomic, weak) NSTableView *table;
@property(nonatomic, assign) BOOL suppressSelectionEvent;
@property(nonatomic, assign) BOOL showsDepth;
@property(nonatomic, assign) BOOL navigationStyle;
@property(nonatomic, assign) BOOL contentSizedRows;
@end

@implementation HaskeLUIMacCollectionAdapter
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
  (void)tableView;
  return self.items.count;
}

- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)column
                   row:(NSInteger)row {
  (void)tableView;
  NSDictionary *item = self.items[(NSUInteger)row];
  NSString *identifier = column.identifier;
  NSString *value = [identifier isEqualToString:@"detail"] ? item[@"detail"] : item[@"label"];
  if (self.showsDepth && [identifier isEqualToString:@"label"]) {
    NSInteger depth = [item[@"depth"] integerValue];
    if (depth > 0) {
      value = [[@"  " stringByPaddingToLength:(NSUInteger)depth * 2
                                    withString:@"  "
                               startingAtIndex:0] stringByAppendingString:value];
    }
  }
  HaskeLUICenteredTableCellView *cell =
      [[HaskeLUICenteredTableCellView alloc] initWithText:value ?: @""
                                         imageSource:[identifier isEqualToString:@"label"]
                                             ? item[@"icon"] : @""
                                        contentSized:self.contentSizedRows];
  cell.centeredLabel.textColor = [item[@"enabled"] boolValue]
      ? NSColor.labelColor
      : NSColor.disabledControlTextColor;
  return cell;
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row {
  (void)tableView;
  return self.navigationStyle &&
      row >= 0 && (NSUInteger)row < self.items.count &&
      [self.items[(NSUInteger)row][@"depth"] integerValue] == 0;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
  (void)tableView;
  return row >= 0 && (NSUInteger)row < self.items.count &&
      [self.items[(NSUInteger)row][@"enabled"] boolValue];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
  if (self.suppressSelectionEvent) {
    return;
  }
  NSTableView *table = notification.object;
  NSMutableArray<NSString *> *keys = [[NSMutableArray alloc] init];
  [table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
    (void)stop;
    if (row < self.items.count) {
      [keys addObject:[self.items[row][@"identity"] stringValue]];
    }
  }];
  HaskeLUIEmit(HaskeLUIMacEventCollectionSelectionChanged, self.identity,
          [keys componentsJoinedByString:@","]);
}
@end

@interface HaskeLUIMacGridItem : NSCollectionViewItem
@property(nonatomic, strong) NSBox *card;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *detailLabel;
@end

@implementation HaskeLUIMacGridItem
- (void)layoutTextLabels {
  NSRect bounds = self.card.contentView.bounds;
  CGFloat inset = 10;
  CGFloat titleHeight = 18;
  CGFloat detailHeight = 16;
  CGFloat gap = NSHeight(bounds) >= 52 ? 4 : 1;
  CGFloat stackHeight = titleHeight + gap + detailHeight;
  CGFloat stackY = MAX(0, floor((NSHeight(bounds) - stackHeight) / 2));
  CGFloat width = MAX(0, NSWidth(bounds) - inset * 2);
  if (self.card.contentView.isFlipped) {
    self.titleLabel.frame = NSMakeRect(inset, stackY, width, titleHeight);
    self.detailLabel.frame = NSMakeRect(
        inset, stackY + titleHeight + gap, width, detailHeight);
  } else {
    self.detailLabel.frame = NSMakeRect(inset, stackY, width, detailHeight);
    self.titleLabel.frame = NSMakeRect(
        inset, stackY + detailHeight + gap, width, titleHeight);
  }
}

- (void)loadView {
  NSBox *card = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 150, 66)];
  card.boxType = NSBoxCustom;
  card.titlePosition = NSNoTitle;
  card.borderWidth = 1;
  card.cornerRadius = 7;
  card.fillColor = NSColor.controlBackgroundColor;
  NSTextField *title = [NSTextField labelWithString:@""];
  title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
  title.lineBreakMode = NSLineBreakByTruncatingTail;
  NSTextField *detail = [NSTextField labelWithString:@""];
  detail.textColor = NSColor.secondaryLabelColor;
  detail.font = [NSFont systemFontOfSize:11];
  detail.lineBreakMode = NSLineBreakByTruncatingTail;
  [card.contentView addSubview:title];
  [card.contentView addSubview:detail];
  self.card = card;
  self.titleLabel = title;
  self.detailLabel = detail;
  self.view = card;
  [self layoutTextLabels];
}

- (void)viewDidLayout {
  [super viewDidLayout];
  [self layoutTextLabels];
}

- (void)setSelected:(BOOL)selected {
  [super setSelected:selected];
  self.card.fillColor = selected
      ? NSColor.selectedContentBackgroundColor
      : NSColor.controlBackgroundColor;
  self.titleLabel.textColor = selected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor;
  self.detailLabel.textColor = selected ? NSColor.alternateSelectedControlTextColor : NSColor.secondaryLabelColor;
}
@end

@interface HaskeLUIMacGridAdapter : NSObject <NSCollectionViewDataSource, NSCollectionViewDelegate>
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *items;
@property(nonatomic, weak) NSCollectionView *collection;
@property(nonatomic, assign) BOOL suppressSelectionEvent;
@property(nonatomic, assign) BOOL repeater;
@end

@implementation HaskeLUIMacGridAdapter
- (NSInteger)collectionView:(NSCollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section {
  (void)collectionView;
  (void)section;
  return self.items.count;
}

- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView
    itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath {
  HaskeLUIMacGridItem *item = (HaskeLUIMacGridItem *)[collectionView
      makeItemWithIdentifier:@"HaskeLUIGridItem"
                forIndexPath:indexPath];
  NSDictionary *value = self.items[(NSUInteger)indexPath.item];
  item.titleLabel.stringValue = value[@"label"] ?: @"";
  item.detailLabel.stringValue = value[@"detail"] ?: @"";
  item.card.borderWidth = self.repeater ? 0 : 1;
  item.card.cornerRadius = self.repeater ? 0 : 7;
  return item;
}

- (NSSet<NSIndexPath *> *)collectionView:(NSCollectionView *)collectionView
    shouldSelectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
  (void)collectionView;
  NSMutableSet<NSIndexPath *> *allowed = [[NSMutableSet alloc] init];
  for (NSIndexPath *path in indexPaths) {
    if ((NSUInteger)path.item < self.items.count &&
        [self.items[(NSUInteger)path.item][@"enabled"] boolValue]) {
      [allowed addObject:path];
    }
  }
  return allowed;
}

- (void)emitSelection {
  if (self.suppressSelectionEvent) {
    return;
  }
  NSMutableArray<NSString *> *keys = [[NSMutableArray alloc] init];
  NSArray<NSIndexPath *> *paths = [self.collection.selectionIndexPaths.allObjects
      sortedArrayUsingComparator:^NSComparisonResult(NSIndexPath *left, NSIndexPath *right) {
        return left.item < right.item ? NSOrderedAscending
             : left.item > right.item ? NSOrderedDescending
             : NSOrderedSame;
      }];
  for (NSIndexPath *path in paths) {
    if ((NSUInteger)path.item < self.items.count) {
      [keys addObject:[self.items[(NSUInteger)path.item][@"identity"] stringValue]];
    }
  }
  HaskeLUIEmit(HaskeLUIMacEventCollectionSelectionChanged, self.identity,
          [keys componentsJoinedByString:@","]);
}

- (void)collectionView:(NSCollectionView *)collectionView
    didSelectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
  (void)collectionView;
  (void)indexPaths;
  [self emitSelection];
}

- (void)collectionView:(NSCollectionView *)collectionView
    didDeselectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
  (void)collectionView;
  (void)indexPaths;
  [self emitSelection];
}
@end

@interface HaskeLUIMacOutlineNode : NSObject
@property(nonatomic, strong) NSDictionary *value;
@property(nonatomic, strong) NSMutableArray<HaskeLUIMacOutlineNode *> *children;
@end

@implementation HaskeLUIMacOutlineNode
@end

@interface HaskeLUIMacOutlineAdapter : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *items;
@property(nonatomic, strong) NSMutableArray<HaskeLUIMacOutlineNode *> *roots;
@property(nonatomic, weak) NSOutlineView *outline;
@property(nonatomic, assign) BOOL suppressEvents;
@property(nonatomic, assign) BOOL contentSizedRows;
- (void)reload;
- (void)activateSelectedItem:(id)sender;
@end

@implementation HaskeLUIMacOutlineAdapter
- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
  (void)outlineView;
  return item == nil ? self.roots.count : ((HaskeLUIMacOutlineNode *)item).children.count;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
  (void)outlineView;
  return item == nil ? self.roots[(NSUInteger)index]
                     : ((HaskeLUIMacOutlineNode *)item).children[(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
  (void)outlineView;
  return [((HaskeLUIMacOutlineNode *)item).value[@"expandable"] boolValue];
}

- (NSView *)outlineView:(NSOutlineView *)outlineView
    viewForTableColumn:(NSTableColumn *)tableColumn
                  item:(id)item {
  (void)outlineView;
  (void)tableColumn;
  HaskeLUIMacOutlineNode *node = item;
  return [[HaskeLUICenteredTableCellView alloc]
      initWithText:node.value[@"label"] ?: @""
      imageSource:node.value[@"icon"] ?: @""
      contentSized:self.contentSizedRows];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldSelectItem:(id)item {
  (void)outlineView;
  return [((HaskeLUIMacOutlineNode *)item).value[@"enabled"] boolValue];
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
  if (self.suppressEvents) {
    return;
  }
  NSOutlineView *outline = notification.object;
  NSMutableArray<NSString *> *keys = [[NSMutableArray alloc] init];
  [outline.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
    (void)stop;
    HaskeLUIMacOutlineNode *node = [outline itemAtRow:(NSInteger)row];
    if (node != nil) {
      [keys addObject:[node.value[@"identity"] stringValue]];
    }
  }];
  HaskeLUIEmit(HaskeLUIMacEventCollectionSelectionChanged, self.identity,
          [keys componentsJoinedByString:@","]);
}

- (void)activateSelectedItem:(id)sender {
  (void)sender;
  if (self.suppressEvents) {
    return;
  }
  NSInteger row = self.outline.clickedRow;
  if (row < 0) {
    row = self.outline.selectedRow;
  }
  if (row < 0) {
    return;
  }
  HaskeLUIMacOutlineNode *node = [self.outline itemAtRow:row];
  // Selection-change already delivers newly selected rows. The action path is
  // only for activating the row that the declarative model already selected,
  // which AppKit otherwise reports as no change at all.
  if (node != nil && [node.value[@"selected"] boolValue]) {
    HaskeLUIEmit(
        HaskeLUIMacEventCollectionSelectionChanged,
        self.identity,
        [node.value[@"identity"] stringValue]);
  }
}

- (void)emitExpansion:(NSNotification *)notification expanded:(BOOL)expanded {
  if (self.suppressEvents) {
    return;
  }
  HaskeLUIMacOutlineNode *node = notification.userInfo[@"NSObject"] ?: notification.object;
  if (![node isKindOfClass:HaskeLUIMacOutlineNode.class]) {
    return;
  }
  NSString *payload = [NSString stringWithFormat:@"%@,%d",
      [node.value[@"identity"] stringValue], expanded ? 1 : 0];
  HaskeLUIEmit(HaskeLUIMacEventCollectionExpansionChanged, self.identity, payload);
}

- (void)outlineViewItemDidExpand:(NSNotification *)notification {
  [self emitExpansion:notification expanded:YES];
}

- (void)outlineViewItemDidCollapse:(NSNotification *)notification {
  [self emitExpansion:notification expanded:NO];
}

- (void)expandNodes:(NSArray<HaskeLUIMacOutlineNode *> *)nodes {
  for (HaskeLUIMacOutlineNode *node in nodes) {
    if ([node.value[@"expanded"] boolValue]) {
      [self.outline expandItem:node];
    }
    [self expandNodes:node.children];
  }
}

- (void)reload {
  [self.roots removeAllObjects];
  NSMutableArray<HaskeLUIMacOutlineNode *> *stack = [[NSMutableArray alloc] init];
  for (NSDictionary *value in self.items) {
    HaskeLUIMacOutlineNode *node = [[HaskeLUIMacOutlineNode alloc] init];
    node.value = value;
    node.children = [[NSMutableArray alloc] init];
    NSInteger depth = MAX(0, [value[@"depth"] integerValue]);
    while (stack.count > (NSUInteger)depth) {
      [stack removeLastObject];
    }
    if (depth > 0 && stack.count > 0) {
      [stack.lastObject.children addObject:node];
    } else {
      [self.roots addObject:node];
    }
    [stack addObject:node];
  }
  self.suppressEvents = YES;
  [self.outline reloadData];
  [self expandNodes:self.roots];
  NSMutableIndexSet *selected = [[NSMutableIndexSet alloc] init];
  for (NSInteger row = 0; row < self.outline.numberOfRows; row += 1) {
    HaskeLUIMacOutlineNode *node = [self.outline itemAtRow:row];
    if ([node.value[@"selected"] boolValue]) {
      [selected addIndex:(NSUInteger)row];
    }
  }
  [self.outline selectRowIndexes:selected byExtendingSelection:NO];
  self.suppressEvents = NO;
}
@end

@interface HaskeLUIMacWindowDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, assign) uint64_t identity;
@end

@implementation HaskeLUIMacWindowDelegate
- (BOOL)windowShouldClose:(NSWindow *)sender {
  (void)sender;
  HaskeLUIEmit(HaskeLUIMacEventWindowCloseRequested, self.identity, @"");
  return NO;
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
  (void)notification;
  HaskeLUIEmit(HaskeLUIMacEventWindowActivated, self.identity, @"");
}
@end

@interface HaskeLUIMacWindowHandle : NSObject
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) HaskeLUIMacWindowDelegate *delegate;
@property(nonatomic, strong) NSView *workspaceRoot;
@property(nonatomic, strong) NSSplitView *workspaceSplit;
@property(nonatomic, strong) HaskeLUIMacSplitViewDelegate *workspaceSplitDelegate;
@property(nonatomic, strong) NSView *workspaceStatus;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSView *> *workspacePanes;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *workspacePaneRoles;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *workspacePaneExtents;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *workspacePaneMinimumExtents;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *workspacePaneMaximumExtents;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *workspacePaneStretchWeights;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *workspacePaneCollapsedStates;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *workspacePendingPaneEvents;
@property(nonatomic, assign) uint64_t workspacePaneEventGeneration;
@property(nonatomic, assign) BOOL workspacePaneEventsAwaitMouseRelease;
@property(nonatomic, assign) BOOL workspaceApplyingLayout;
@property(nonatomic, assign) BOOL workspaceTestingPaneResize;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSView *> *workspaceItems;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, HaskeLUIMacTabGroupHandle *> *tabGroups;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *seenPanes;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *seenItems;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *seenTabGroups;
@end

@implementation HaskeLUIMacWindowHandle
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    HaskeLUILiveWindows += 1;
  }
  return self;
}

- (void)dealloc {
  HaskeLUILiveWindows -= 1;
}
@end

@interface HaskeLUIMacSplitViewDelegate : NSObject <NSSplitViewDelegate>
@property(nonatomic, weak) HaskeLUIMacWindowHandle *windowHandle;
@end

@implementation HaskeLUIMacSplitViewDelegate

- (NSNumber *)paneKeyForView:(NSView *)view {
  return [self.windowHandle.workspacePanes allKeysForObject:view].firstObject;
}

- (BOOL)isTrackingDividerInSplitView:(NSSplitView *)splitView {
  NSEvent *event = NSApp.currentEvent;
  if (event == nil || event.window != splitView.window ||
      event.type != NSEventTypeLeftMouseDragged) {
    return NO;
  }
  NSPoint point = [splitView convertPoint:event.locationInWindow fromView:nil];
  CGFloat dividerThickness = splitView.dividerThickness;
  for (NSUInteger index = 0; index + 1 < splitView.subviews.count; index += 1) {
    NSView *before = splitView.subviews[index];
    NSRect divider = splitView.vertical
        ? NSMakeRect(NSMaxX(before.frame), NSMinY(splitView.bounds),
                     dividerThickness, NSHeight(splitView.bounds))
        : NSMakeRect(NSMinX(splitView.bounds), NSMaxY(before.frame),
                     NSWidth(splitView.bounds), dividerThickness);
    /* AppKit permits a small grab area around thin dividers. Match it so the
       callback remains classified as a divider drag while tracking. */
    if (NSPointInRect(point, NSInsetRect(divider, -4.0, -4.0))) {
      return YES;
    }
  }
  return NO;
}

- (CGFloat)splitView:(NSSplitView *)splitView
    constrainMinCoordinate:(CGFloat)proposedMinimumPosition
               ofSubviewAt:(NSInteger)dividerIndex {
  HaskeLUIMacWindowHandle *handle = self.windowHandle;
  if (handle == nil || dividerIndex < 0 ||
      dividerIndex + 1 >= (NSInteger)splitView.subviews.count) {
    return proposedMinimumPosition;
  }
  NSView *before = splitView.subviews[(NSUInteger)dividerIndex];
  NSView *after = splitView.subviews[(NSUInteger)dividerIndex + 1];
  NSNumber *beforeKey = [self paneKeyForView:before];
  NSNumber *afterKey = [self paneKeyForView:after];
  CGFloat constrained = proposedMinimumPosition;
  double beforeMinimum = handle.workspacePaneMinimumExtents[beforeKey].doubleValue;
  double afterMaximum = handle.workspacePaneMaximumExtents[afterKey].doubleValue;
  if (beforeMinimum >= 0) {
    constrained = MAX(
        constrained,
        (splitView.vertical ? NSMinX(before.frame) : NSMinY(before.frame)) + beforeMinimum);
  }
  if (afterMaximum >= 0) {
    constrained = MAX(
        constrained,
        (splitView.vertical ? NSMaxX(after.frame) : NSMaxY(after.frame)) - afterMaximum);
  }
  return constrained;
}

- (CGFloat)splitView:(NSSplitView *)splitView
    constrainMaxCoordinate:(CGFloat)proposedMaximumPosition
               ofSubviewAt:(NSInteger)dividerIndex {
  HaskeLUIMacWindowHandle *handle = self.windowHandle;
  if (handle == nil || dividerIndex < 0 ||
      dividerIndex + 1 >= (NSInteger)splitView.subviews.count) {
    return proposedMaximumPosition;
  }
  NSView *before = splitView.subviews[(NSUInteger)dividerIndex];
  NSView *after = splitView.subviews[(NSUInteger)dividerIndex + 1];
  NSNumber *beforeKey = [self paneKeyForView:before];
  NSNumber *afterKey = [self paneKeyForView:after];
  CGFloat constrained = proposedMaximumPosition;
  double beforeMaximum = handle.workspacePaneMaximumExtents[beforeKey].doubleValue;
  double afterMinimum = handle.workspacePaneMinimumExtents[afterKey].doubleValue;
  if (beforeMaximum >= 0) {
    constrained = MIN(
        constrained,
        (splitView.vertical ? NSMinX(before.frame) : NSMinY(before.frame)) + beforeMaximum);
  }
  if (afterMinimum >= 0) {
    constrained = MIN(
        constrained,
        (splitView.vertical ? NSMaxX(after.frame) : NSMaxY(after.frame)) - afterMinimum);
  }
  return constrained;
}

- (BOOL)splitView:(NSSplitView *)splitView shouldAdjustSizeOfSubview:(NSView *)view {
  (void)splitView;
  HaskeLUIMacWindowHandle *handle = self.windowHandle;
  NSNumber *paneKey = [self paneKeyForView:view];
  if (handle == nil || paneKey == nil) {
    return YES;
  }
  BOOL hasStretchingPane = NO;
  for (NSNumber *weight in handle.workspacePaneStretchWeights.allValues) {
    if (weight.doubleValue > 0) {
      hasStretchingPane = YES;
      break;
    }
  }
  return !hasStretchingPane || handle.workspacePaneStretchWeights[paneKey].doubleValue > 0;
}

- (void)schedulePendingPaneEvents {
  HaskeLUIMacWindowHandle *handle = self.windowHandle;
  if (handle == nil || handle.workspacePendingPaneEvents.count == 0) {
    return;
  }
  handle.workspacePaneEventGeneration += 1;
  uint64_t generation = handle.workspacePaneEventGeneration;
  __weak HaskeLUIMacWindowHandle *weakHandle = handle;
  /* NSSplitView reports continuously while its divider is tracked. Debounce
     those native notifications into one model commit after the gesture's last
     movement; the generation also invalidates stale scheduled commits. */
  dispatch_after(
      dispatch_time(
          DISPATCH_TIME_NOW,
          (int64_t)(HaskeLUIPaneResizeCommitDelaySeconds * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
    HaskeLUIMacWindowHandle *strongHandle = weakHandle;
    if (strongHandle == nil || strongHandle.workspacePaneEventGeneration != generation) {
      return;
    }
    if (strongHandle.workspacePaneEventsAwaitMouseRelease &&
        (NSEvent.pressedMouseButtons & 1) != 0) {
      [strongHandle.workspaceSplitDelegate schedulePendingPaneEvents];
      return;
    }
    NSDictionary<NSNumber *, NSString *> *pending =
        [strongHandle.workspacePendingPaneEvents copy];
    [strongHandle.workspacePendingPaneEvents removeAllObjects];
    strongHandle.workspacePaneEventsAwaitMouseRelease = NO;
    NSArray<NSNumber *> *paneKeys =
        [pending.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *paneKey in paneKeys) {
      HaskeLUIEmit(
          HaskeLUIMacEventPaneStateChanged,
          paneKey.unsignedLongLongValue,
          pending[paneKey]);
    }
  });
}

- (void)splitViewDidResizeSubviews:(NSNotification *)notification {
  HaskeLUIMacWindowHandle *handle = self.windowHandle;
  NSSplitView *splitView = notification.object;
  if (handle == nil || splitView != handle.workspaceSplit || handle.workspaceApplyingLayout) {
    return;
  }
  BOOL testingResize = handle.workspaceTestingPaneResize;
  if (!testingResize && ![self isTrackingDividerInSplitView:splitView]) {
    return;
  }
  handle.workspacePaneEventsAwaitMouseRelease |= !testingResize;
  for (NSNumber *paneKey in handle.workspacePanes) {
    NSView *pane = handle.workspacePanes[paneKey];
    BOOL collapsed = pane.hidden || [splitView isSubviewCollapsed:pane];
    BOOL wasCollapsed = handle.workspacePaneCollapsedStates[paneKey].boolValue;
    CGFloat extent = collapsed
        ? handle.workspacePaneExtents[paneKey].doubleValue
        : (splitView.vertical ? NSWidth(pane.frame) : NSHeight(pane.frame));
    CGFloat previousExtent = handle.workspacePaneExtents[paneKey].doubleValue;
    if (!collapsed) {
      handle.workspacePaneExtents[paneKey] = @(MAX(0.0, extent));
    }
    handle.workspacePaneCollapsedStates[paneKey] = @(collapsed);
    if (collapsed == wasCollapsed && fabs(extent - previousExtent) <= 0.25) {
      continue;
    }
    handle.workspacePendingPaneEvents[paneKey] =
        [NSString stringWithFormat:
            @"%@|%.17g",
            collapsed ? @"collapsed" : @"visible",
            (double)MAX(0.0, extent)];
  }
  [self schedulePendingPaneEvents];
}

@end

@interface HaskeLUIMacTabHandle : NSObject
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, strong) NSStackView *tabHeader;
@property(nonatomic, strong) NSButton *selectButton;
@property(nonatomic, strong) NSButton *closeButton;
@property(nonatomic, strong) NSView *contentView;
@property(nonatomic, strong) HaskeLUIMacActionTarget *selectTarget;
@property(nonatomic, strong) HaskeLUIMacActionTarget *closeTarget;
@end

@implementation HaskeLUIMacTabHandle
@end

@interface HaskeLUIMacTabGroupHandle : NSObject
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, strong) NSView *rootView;
@property(nonatomic, strong) NSScrollView *tabScrollView;
@property(nonatomic, strong) NSStackView *tabBar;
@property(nonatomic, strong) NSView *contentHost;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, HaskeLUIMacTabHandle *> *tabs;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *seenTabs;
@property(nonatomic, strong) NSNumber *selectedTab;
@end

@implementation HaskeLUIMacTabGroupHandle
@end

@interface HaskeLUIMacControlHandle : NSObject <NSPopoverDelegate>
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, strong) NSView *view;
@property(nonatomic, strong) NSView *focusView;
@property(nonatomic, assign) NSRect desiredFrame;
@property(nonatomic, strong) HaskeLUIMacActionTarget *target;
@property(nonatomic, assign) HaskeLUIMacControlKind kind;
@property(nonatomic, assign) int32_t catalogKind;
@property(nonatomic, strong) NSView *contentView;
@property(nonatomic, strong) NSView *normalContentView;
@property(nonatomic, strong) NSScrollView *containerScrollView;
@property(nonatomic, strong) NSView *containerScrollDocument;
@property(nonatomic, assign) BOOL containerScrollInitialized;
@property(nonatomic, strong) NSButton *disclosureButton;
@property(nonatomic, strong) NSTextField *disclosureLabel;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSView *> *slots;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *items;
@property(nonatomic, strong) NSMutableArray<HaskeLUIMacActionTarget *> *itemTargets;
@property(nonatomic, strong) HaskeLUIMacCollectionAdapter *collectionAdapter;
@property(nonatomic, strong) HaskeLUIMacGridAdapter *gridAdapter;
@property(nonatomic, strong) HaskeLUIMacOutlineAdapter *outlineAdapter;
@property(nonatomic, strong) NSWindow *presentationWindow;
@property(nonatomic, strong) NSPopover *popover;
@property(nonatomic, assign) BOOL presentationVisible;
@property(nonatomic, assign) uint64_t commandIdentity;
@property(nonatomic, assign) int32_t collectionSelectionMode;
@property(nonatomic, assign) int32_t containerState;
@property(nonatomic, copy) NSString *primaryText;
@property(nonatomic, copy) NSString *secondaryText;
@end

@implementation HaskeLUIMacControlHandle
- (instancetype)init {
  self = [super init];
  if (self != nil) {
    HaskeLUILiveControls += 1;
  }
  return self;
}

- (void)dealloc {
  HaskeLUILiveControls -= 1;
}

- (void)finishPopoverDismissal {
  BOOL wasPresented = self.presentationVisible;
  self.presentationVisible = NO;
  self.popover = nil;
  if (wasPresented) {
    HaskeLUIEmit(HaskeLUIMacEventPresentationClosed, self.identity, @"dismissed");
  }
}

- (void)popoverWillClose:(NSNotification *)notification {
  (void)notification;
  [self finishPopoverDismissal];
}

- (void)popoverDidClose:(NSNotification *)notification {
  (void)notification;
  [self finishPopoverDismissal];
}
@end

static HaskeLUIMacWindowHandle *HaskeLUIWindow(HaskeLUIMacWindowRef reference) {
  return (__bridge HaskeLUIMacWindowHandle *)reference;
}

static HaskeLUIMacControlHandle *HaskeLUIControl(HaskeLUIMacControlRef reference) {
  return (__bridge HaskeLUIMacControlHandle *)reference;
}

static void HaskeLUIBuildApplicationMenu(NSApplication *application) {
  NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"HaskeLUI"];

  NSMenuItem *applicationItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
  NSMenu *applicationMenu = [[NSMenu alloc] initWithTitle:@"HaskeLUI"];
  NSMenuItem *quitItem =
      [[NSMenuItem alloc] initWithTitle:@"Quit HaskeLUI" action:@selector(stop:) keyEquivalent:@"q"];
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
  HaskeLUIState.fileMenu = fileMenu;
}

int32_t haskelui_macos_initialize(HaskeLUIMacEventCallback callback, void *context) {
  HaskeLUIAssertMainThread();
  if (callback == NULL || HaskeLUIState != nil) {
    return 0;
  }

  HaskeLUIState = [[HaskeLUIMacApplicationState alloc] init];
  HaskeLUIState.callback = callback;
  HaskeLUIState.callbackContext = context;
  HaskeLUIState.commandItems = [[NSMutableDictionary alloc] init];
  HaskeLUIState.commandTargets = [[NSMutableDictionary alloc] init];
  HaskeLUIState.windows = [[NSMutableDictionary alloc] init];
  HaskeLUIState.controls = [[NSMutableDictionary alloc] init];
  HaskeLUITestFailures = 0;
  HaskeLUILastTestFailure = nil;

  NSApplication *application = NSApplication.sharedApplication;
  application.activationPolicy = NSApplicationActivationPolicyRegular;
  HaskeLUIBuildApplicationMenu(application);
  [application finishLaunching];
  return 1;
}

void haskelui_macos_set_drawing_input_callback(
    HaskeLUIMacDrawingInputCallback callback,
    void *context) {
  HaskeLUIAssertMainThread();
  if (HaskeLUIState != nil) {
    HaskeLUIState.drawingInputCallback = callback;
    HaskeLUIState.drawingInputCallbackContext = context;
  }
}

void haskelui_macos_run(void) {
  HaskeLUIAssertMainThread();
  NSApplication *application = NSApplication.sharedApplication;
  [application activateIgnoringOtherApps:YES];
  /* Before activation AppKit may report Aqua even when the active system
     appearance is Dark Aqua. Start observing only after activation, then
     publish exactly one authoritative initial event. Later changes continue
     through KVO. */
  if (!HaskeLUIState.observingEffectiveAppearance) {
    [application addObserver:HaskeLUIState
                  forKeyPath:@"effectiveAppearance"
                     options:NSKeyValueObservingOptionNew
                     context:HaskeLUIEffectiveAppearanceContext];
    HaskeLUIState.observingEffectiveAppearance = YES;
  }
  HaskeLUIEmit(
      HaskeLUIMacEventSystemColorSchemeChanged,
      0,
      HaskeLUISystemColorScheme());
  [application run];
}

void haskelui_macos_stop(void) {
  HaskeLUIAssertMainThread();
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

void haskelui_macos_schedule_runtime_wake(void) {
  /* Runtime wakeups are implementation scheduling, not retained native event
     callbacks. They deliberately do not participate in the leak counter. */
  dispatch_async(dispatch_get_main_queue(), ^{
    HaskeLUIMacApplicationState *state = HaskeLUIState;
    if (state != nil && state.callback != NULL) {
      state.callback(
          state.callbackContext,
          HaskeLUIMacEventRuntimeWake,
          0,
          "");
    }
  });
}

void haskelui_macos_shutdown(void) {
  HaskeLUIAssertMainThread();
  if (HaskeLUIState == nil) {
    return;
  }
  if (HaskeLUIState.observingEffectiveAppearance) {
    [NSApplication.sharedApplication
        removeObserver:HaskeLUIState
            forKeyPath:@"effectiveAppearance"
               context:HaskeLUIEffectiveAppearanceContext];
    HaskeLUIState.observingEffectiveAppearance = NO;
  }
  HaskeLUIState.callback = NULL;
  HaskeLUIState.callbackContext = NULL;
  HaskeLUIState.drawingInputCallback = NULL;
  HaskeLUIState.drawingInputCallbackContext = NULL;
  NSApplication.sharedApplication.mainMenu = nil;
  HaskeLUIState = nil;
  HaskeLUIControlGalleryTestActive = NO;
}

int32_t haskelui_macos_version_major(void) {
  return (int32_t)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
}

int32_t haskelui_macos_version_minor(void) {
  return (int32_t)NSProcessInfo.processInfo.operatingSystemVersion.minorVersion;
}

int32_t haskelui_macos_version_patch(void) {
  return (int32_t)NSProcessInfo.processInfo.operatingSystemVersion.patchVersion;
}

HaskeLUIMacWindowRef haskelui_macos_window_create(
    uint64_t identity,
    const char *utf8_title,
    const HaskeLUIMacRect *frame) {
  HaskeLUIAssertMainThread();
  NSUInteger style =
      NSWindowStyleMaskTitled |
      NSWindowStyleMaskClosable |
      NSWindowStyleMaskMiniaturizable |
      NSWindowStyleMaskResizable;
  NSWindow *window =
      [[NSWindow alloc] initWithContentRect:HaskeLUIRect(frame)
                                styleMask:style
                                  backing:NSBackingStoreBuffered
                                    defer:NO];
  window.title = HaskeLUIString(utf8_title);
  window.releasedWhenClosed = NO;
  window.identifier = [NSString stringWithFormat:@"haskelui-window-%llu", identity];
  window.contentView.accessibilityIdentifier =
      [NSString stringWithFormat:@"haskelui-window-content-%llu", identity];

  HaskeLUIMacWindowDelegate *delegate = [[HaskeLUIMacWindowDelegate alloc] init];
  delegate.identity = identity;
  window.delegate = delegate;
  HaskeLUILiveWindowDelegates += 1;

  HaskeLUIMacWindowHandle *handle = [[HaskeLUIMacWindowHandle alloc] init];
  handle.identity = identity;
  handle.window = window;
  handle.delegate = delegate;
  handle.workspacePanes = [[NSMutableDictionary alloc] init];
  handle.workspacePaneRoles = [[NSMutableDictionary alloc] init];
  handle.workspacePaneExtents = [[NSMutableDictionary alloc] init];
  handle.workspacePaneMinimumExtents = [[NSMutableDictionary alloc] init];
  handle.workspacePaneMaximumExtents = [[NSMutableDictionary alloc] init];
  handle.workspacePaneStretchWeights = [[NSMutableDictionary alloc] init];
  handle.workspacePaneCollapsedStates = [[NSMutableDictionary alloc] init];
  handle.workspacePendingPaneEvents = [[NSMutableDictionary alloc] init];
  handle.workspaceItems = [[NSMutableDictionary alloc] init];
  handle.tabGroups = [[NSMutableDictionary alloc] init];
  handle.seenPanes = [[NSMutableSet alloc] init];
  handle.seenItems = [[NSMutableSet alloc] init];
  handle.seenTabGroups = [[NSMutableSet alloc] init];
  HaskeLUIState.windows[@(identity)] = handle;
  return (__bridge_retained void *)handle;
}

void haskelui_macos_window_set_title(HaskeLUIMacWindowRef reference, const char *utf8_title) {
  HaskeLUIAssertMainThread();
  HaskeLUIWindow(reference).window.title = HaskeLUIString(utf8_title);
}

void haskelui_macos_window_set_frame(HaskeLUIMacWindowRef reference, const HaskeLUIMacRect *frame) {
  HaskeLUIAssertMainThread();
  [HaskeLUIWindow(reference).window setFrame:HaskeLUIRect(frame) display:YES];
}

void haskelui_macos_window_show(HaskeLUIMacWindowRef reference) {
  HaskeLUIAssertMainThread();
  [HaskeLUIWindow(reference).window makeKeyAndOrderFront:nil];
}

static void HaskeLUIReleaseTab(HaskeLUIMacTabHandle *tab) {
  [tab.tabHeader removeFromSuperview];
  [tab.contentView removeFromSuperview];
  if (tab.selectTarget != nil) {
    tab.selectButton.target = nil;
    tab.selectTarget = nil;
    HaskeLUILiveActionTargets -= 1;
  }
  if (tab.closeTarget != nil) {
    tab.closeButton.target = nil;
    tab.closeTarget = nil;
    HaskeLUILiveActionTargets -= 1;
  }
}

static void HaskeLUIReleaseTabGroup(HaskeLUIMacTabGroupHandle *group) {
  for (HaskeLUIMacTabHandle *tab in group.tabs.allValues) {
    HaskeLUIReleaseTab(tab);
  }
  [group.tabs removeAllObjects];
  [group.rootView removeFromSuperview];
}

void haskelui_macos_window_destroy(HaskeLUIMacWindowRef reference) {
  HaskeLUIAssertMainThread();
  if (reference == NULL) {
    return;
  }
  HaskeLUIMacWindowHandle *handle = (__bridge_transfer HaskeLUIMacWindowHandle *)reference;
  [HaskeLUIState.windows removeObjectForKey:@(handle.identity)];
  for (HaskeLUIMacTabGroupHandle *group in handle.tabGroups.allValues) {
    HaskeLUIReleaseTabGroup(group);
  }
  [handle.tabGroups removeAllObjects];
  handle.workspaceApplyingLayout = YES;
  handle.workspaceSplit.delegate = nil;
  handle.workspaceSplitDelegate.windowHandle = nil;
  handle.workspaceSplitDelegate = nil;
  [handle.workspacePendingPaneEvents removeAllObjects];
  handle.workspacePaneEventsAwaitMouseRelease = NO;
  [handle.workspaceRoot removeFromSuperview];
  handle.window.delegate = nil;
  [handle.window orderOut:nil];
  [handle.window close];
  if (handle.delegate != nil) {
    handle.delegate = nil;
    HaskeLUILiveWindowDelegates -= 1;
  }
  handle.window = nil;
}

static NSView *HaskeLUIWorkspacePaneView(int32_t role) {
  if (role == 0 || role == 2) {
    NSVisualEffectView *view = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    view.material = role == 0 ? NSVisualEffectMaterialSidebar : NSVisualEffectMaterialContentBackground;
    view.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    view.state = NSVisualEffectStateFollowsWindowActiveState;
    return view;
  }
  return [[NSView alloc] initWithFrame:NSZeroRect];
}

static void HaskeLUIFillView(NSView *view, NSView *parent) {
  if (view.superview != parent) {
    [view removeFromSuperview];
    [parent addSubview:view];
  }
  view.frame = parent.bounds;
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}

void haskelui_macos_workspace_begin(
    HaskeLUIMacWindowRef reference,
    int32_t sideBySide,
    double statusHeight) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacWindowHandle *handle = HaskeLUIWindow(reference);
  handle.workspaceApplyingLayout = YES;
  NSView *content = handle.window.contentView;
  CGFloat safeStatusHeight = (CGFloat)MAX(0.0, statusHeight);
  if (handle.workspaceRoot == nil) {
    NSView *root = [[NSView alloc] initWithFrame:content.bounds];
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    root.accessibilityElement = YES;
    root.accessibilityRole = NSAccessibilityGroupRole;
    root.accessibilityIdentifier =
        [NSString stringWithFormat:@"haskelui-workspace-%llu", handle.identity];

    NSSplitView *split = [[NSSplitView alloc] initWithFrame:NSZeroRect];
    split.dividerStyle = NSSplitViewDividerStyleThin;
    split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    HaskeLUIMacSplitViewDelegate *splitDelegate =
        [[HaskeLUIMacSplitViewDelegate alloc] init];
    splitDelegate.windowHandle = handle;
    split.delegate = splitDelegate;

    NSVisualEffectView *status = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    status.material = NSVisualEffectMaterialHeaderView;
    status.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    status.state = NSVisualEffectStateFollowsWindowActiveState;
    status.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    status.accessibilityElement = YES;
    status.accessibilityRole = NSAccessibilityGroupRole;
    status.accessibilityIdentifier =
        [NSString stringWithFormat:@"haskelui-workspace-status-%llu", handle.identity];

    NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, content.bounds.size.width, 1)];
    separator.boxType = NSBoxSeparator;
    separator.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [status addSubview:separator];

    [root addSubview:split];
    [root addSubview:status];
    [content addSubview:root];
    handle.workspaceRoot = root;
    handle.workspaceSplit = split;
    handle.workspaceSplitDelegate = splitDelegate;
    handle.workspaceStatus = status;
  }

  handle.workspaceSplit.vertical = sideBySide != 0;
  handle.workspaceStatus.frame = NSMakeRect(0, 0, content.bounds.size.width, safeStatusHeight);
  handle.workspaceSplit.frame =
      NSMakeRect(0, safeStatusHeight, content.bounds.size.width,
                 MAX(0, content.bounds.size.height - safeStatusHeight));
  [handle.seenPanes removeAllObjects];
  [handle.seenItems removeAllObjects];
  [handle.seenTabGroups removeAllObjects];
  for (HaskeLUIMacTabGroupHandle *group in handle.tabGroups.allValues) {
    [group.seenTabs removeAllObjects];
    group.selectedTab = nil;
  }
}

void haskelui_macos_workspace_pane_set(
    HaskeLUIMacWindowRef reference,
    uint64_t paneIdentity,
    int32_t paneRole,
    double minimumExtent,
    double preferredExtent,
    double maximumExtent,
    double stretchWeight,
    int32_t collapsed) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacWindowHandle *handle = HaskeLUIWindow(reference);
  NSNumber *key = @(paneIdentity);
  NSView *pane = handle.workspacePanes[key];
  NSNumber *oldRole = handle.workspacePaneRoles[key];
  if (pane == nil || oldRole.intValue != paneRole) {
    NSView *oldPane = pane;
    pane = HaskeLUIWorkspacePaneView(paneRole);
    pane.accessibilityElement = YES;
    pane.accessibilityRole = NSAccessibilityGroupRole;
    pane.accessibilityIdentifier =
        [NSString stringWithFormat:@"haskelui-workspace-pane-%llu", paneIdentity];
    for (NSView *child in oldPane.subviews.copy) {
      HaskeLUIFillView(child, pane);
    }
    [oldPane removeFromSuperview];
    handle.workspacePanes[key] = pane;
  }
  handle.workspacePaneRoles[key] = @(paneRole);
  handle.workspacePaneExtents[key] = @(MAX(0.0, preferredExtent));
  handle.workspacePaneMinimumExtents[key] = @(minimumExtent >= 0 ? minimumExtent : -1);
  handle.workspacePaneMaximumExtents[key] = @(maximumExtent >= 0 ? maximumExtent : -1);
  handle.workspacePaneStretchWeights[key] = @(MAX(0.0, stretchWeight));
  handle.workspacePaneCollapsedStates[key] = @(collapsed != 0);
  pane.hidden = collapsed != 0;
  if (pane.superview != handle.workspaceSplit) {
    [handle.workspaceSplit addSubview:pane];
  }
  [handle.seenPanes addObject:key];
}

void haskelui_macos_workspace_item_set(
    HaskeLUIMacWindowRef reference,
    uint64_t paneIdentity,
    uint64_t itemIdentity) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacWindowHandle *handle = HaskeLUIWindow(reference);
  NSNumber *paneKey = @(paneIdentity);
  NSNumber *itemKey = @(itemIdentity);
  NSView *pane = handle.workspacePanes[paneKey];
  if (pane == nil) {
    return;
  }
  NSView *item = handle.workspaceItems[itemKey];
  if (item == nil) {
    item = [[NSView alloc] initWithFrame:pane.bounds];
    item.accessibilityElement = YES;
    item.accessibilityRole = NSAccessibilityGroupRole;
    item.accessibilityIdentifier =
        [NSString stringWithFormat:@"haskelui-workspace-item-%llu", itemIdentity];
    handle.workspaceItems[itemKey] = item;
  }
  HaskeLUIFillView(item, pane);
  [handle.seenItems addObject:itemKey];
}

static HaskeLUIMacTabGroupHandle *HaskeLUIEnsureTabGroup(
    HaskeLUIMacWindowHandle *window,
    uint64_t identity) {
  NSNumber *key = @(identity);
  HaskeLUIMacTabGroupHandle *group = window.tabGroups[key];
  if (group != nil) {
    return group;
  }
  group = [[HaskeLUIMacTabGroupHandle alloc] init];
  group.identity = identity;
  group.tabs = [[NSMutableDictionary alloc] init];
  group.seenTabs = [[NSMutableSet alloc] init];

  NSView *root = [[NSView alloc] initWithFrame:NSZeroRect];
  root.accessibilityElement = YES;
  root.accessibilityRole = NSAccessibilityGroupRole;
  root.accessibilityIdentifier = [NSString stringWithFormat:@"haskelui-tab-group-%llu", identity];
  NSStackView *bar = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 100, 32)];
  bar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  bar.alignment = NSLayoutAttributeCenterY;
  bar.distribution = NSStackViewDistributionFill;
  bar.spacing = 2;
  bar.edgeInsets = NSEdgeInsetsMake(3, 6, 3, 6);
  NSScrollView *tabScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  tabScroll.drawsBackground = NO;
  tabScroll.borderType = NSNoBorder;
  tabScroll.hasHorizontalScroller = NO;
  tabScroll.hasVerticalScroller = NO;
  tabScroll.horizontalScrollElasticity = NSScrollElasticityAutomatic;
  tabScroll.verticalScrollElasticity = NSScrollElasticityNone;
  tabScroll.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  tabScroll.documentView = bar;
  NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
  content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [root addSubview:tabScroll];
  [root addSubview:content];
  group.rootView = root;
  group.tabScrollView = tabScroll;
  group.tabBar = bar;
  group.contentHost = content;
  window.tabGroups[key] = group;
  return group;
}

static void HaskeLUILayoutTabGroup(HaskeLUIMacTabGroupHandle *group) {
  CGFloat barHeight = 34;
  NSRect bounds = group.rootView.bounds;
  group.tabScrollView.frame =
      NSMakeRect(0, MAX(0, bounds.size.height - barHeight), bounds.size.width, barHeight);
  CGFloat tabWidth = group.tabBar.edgeInsets.left + group.tabBar.edgeInsets.right;
  NSArray<NSView *> *headers = group.tabBar.arrangedSubviews;
  for (NSView *header in headers) {
    tabWidth += ceil(header.fittingSize.width);
  }
  if (headers.count > 1) {
    tabWidth += group.tabBar.spacing * (headers.count - 1);
  }
  group.tabBar.frame = NSMakeRect(0, 0, MAX(1, tabWidth), barHeight);
  [group.tabBar layoutSubtreeIfNeeded];
  group.contentHost.frame = NSMakeRect(0, 0, bounds.size.width, MAX(0, bounds.size.height - barHeight));
  for (HaskeLUIMacTabHandle *tab in group.tabs.allValues) {
    tab.contentView.frame = group.contentHost.bounds;
  }
  HaskeLUIMacTabHandle *selected = group.tabs[group.selectedTab];
  if (selected != nil && selected.tabHeader.superview == group.tabBar) {
    [selected.tabHeader scrollRectToVisible:selected.tabHeader.bounds];
  }
}

void haskelui_macos_workspace_tab_group_set(
    HaskeLUIMacWindowRef reference,
    uint64_t itemIdentity,
    uint64_t groupIdentity) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacWindowHandle *handle = HaskeLUIWindow(reference);
  NSView *item = handle.workspaceItems[@(itemIdentity)];
  if (item == nil) {
    return;
  }
  HaskeLUIMacTabGroupHandle *group = HaskeLUIEnsureTabGroup(handle, groupIdentity);
  HaskeLUIFillView(group.rootView, item);
  HaskeLUILayoutTabGroup(group);
  for (HaskeLUIMacTabHandle *tab in group.tabs.allValues) {
    [group.tabBar removeArrangedSubview:tab.tabHeader];
    [tab.tabHeader removeFromSuperview];
  }
  [handle.seenTabGroups addObject:@(groupIdentity)];
}

static HaskeLUIMacTabHandle *HaskeLUIEnsureTab(
    HaskeLUIMacTabGroupHandle *group,
    uint64_t identity) {
  NSNumber *key = @(identity);
  HaskeLUIMacTabHandle *tab = group.tabs[key];
  if (tab != nil) {
    return tab;
  }
  tab = [[HaskeLUIMacTabHandle alloc] init];
  tab.identity = identity;

  HaskeLUIMacActionTarget *selectTarget = [[HaskeLUIMacActionTarget alloc] init];
  HaskeLUILiveActionTargets += 1;
  selectTarget.identity = identity;
  selectTarget.eventKind = HaskeLUIMacEventTabSelected;
  NSButton *selectButton = [NSButton buttonWithTitle:@"" target:selectTarget action:@selector(performAction:)];
  selectButton.bezelStyle = NSBezelStyleTexturedRounded;

  HaskeLUIMacActionTarget *closeTarget = [[HaskeLUIMacActionTarget alloc] init];
  HaskeLUILiveActionTargets += 1;
  closeTarget.identity = identity;
  closeTarget.eventKind = HaskeLUIMacEventTabCloseRequested;
  NSButton *closeButton = [NSButton buttonWithTitle:@"×" target:closeTarget action:@selector(performAction:)];
  closeButton.bezelStyle = NSBezelStyleInline;
  closeButton.toolTip = @"Close";

  NSStackView *header = [NSStackView stackViewWithViews:@[selectButton, closeButton]];
  header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  header.alignment = NSLayoutAttributeCenterY;
  header.distribution = NSStackViewDistributionFill;
  header.spacing = 1;
  [selectButton setContentHuggingPriority:NSLayoutPriorityRequired
                          forOrientation:NSLayoutConstraintOrientationHorizontal];
  [closeButton setContentHuggingPriority:NSLayoutPriorityRequired
                         forOrientation:NSLayoutConstraintOrientationHorizontal];
  [header setContentHuggingPriority:NSLayoutPriorityRequired
                    forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSView *content = [[NSView alloc] initWithFrame:group.contentHost.bounds];
  content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  content.accessibilityElement = YES;
  content.accessibilityRole = NSAccessibilityGroupRole;
  content.accessibilityIdentifier = [NSString stringWithFormat:@"haskelui-tab-content-%llu", identity];
  [group.tabBar addArrangedSubview:header];
  [group.contentHost addSubview:content];

  tab.tabHeader = header;
  tab.selectButton = selectButton;
  tab.closeButton = closeButton;
  tab.contentView = content;
  tab.selectTarget = selectTarget;
  tab.closeTarget = closeTarget;
  group.tabs[key] = tab;
  return tab;
}

void haskelui_macos_workspace_tab_set(
    HaskeLUIMacWindowRef reference,
    uint64_t groupIdentity,
    uint64_t tabIdentity,
    const char *utf8Title,
    int32_t modified,
    int32_t closeable,
    int32_t selected) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacWindowHandle *handle = HaskeLUIWindow(reference);
  HaskeLUIMacTabGroupHandle *group = handle.tabGroups[@(groupIdentity)];
  if (group == nil) {
    return;
  }
  HaskeLUIMacTabHandle *tab = HaskeLUIEnsureTab(group, tabIdentity);
  if (tab.tabHeader.superview != group.tabBar) {
    [group.tabBar addArrangedSubview:tab.tabHeader];
  }
  NSString *title = HaskeLUIString(utf8Title);
  tab.selectButton.title = modified != 0 ? [@"● " stringByAppendingString:title] : title;
  tab.selectButton.toolTip = title;
  tab.closeButton.hidden = closeable == 0;
  tab.selectButton.state = selected != 0 ? NSControlStateValueOn : NSControlStateValueOff;
  tab.contentView.hidden = selected == 0;
  if (selected != 0) {
    group.selectedTab = @(tabIdentity);
  }
  [group.seenTabs addObject:@(tabIdentity)];
}

void haskelui_macos_workspace_end(HaskeLUIMacWindowRef reference) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacWindowHandle *handle = HaskeLUIWindow(reference);

  for (NSNumber *groupKey in handle.tabGroups.allKeys.copy) {
    HaskeLUIMacTabGroupHandle *group = handle.tabGroups[groupKey];
    if (![handle.seenTabGroups containsObject:groupKey]) {
      HaskeLUIReleaseTabGroup(group);
      [handle.tabGroups removeObjectForKey:groupKey];
      continue;
    }
    for (NSNumber *tabKey in group.tabs.allKeys.copy) {
      if (![group.seenTabs containsObject:tabKey]) {
        HaskeLUIReleaseTab(group.tabs[tabKey]);
        [group.tabs removeObjectForKey:tabKey];
      }
    }
    HaskeLUILayoutTabGroup(group);
  }
  for (NSNumber *itemKey in handle.workspaceItems.allKeys.copy) {
    if (![handle.seenItems containsObject:itemKey]) {
      [handle.workspaceItems[itemKey] removeFromSuperview];
      [handle.workspaceItems removeObjectForKey:itemKey];
    }
  }
  for (NSNumber *paneKey in handle.workspacePanes.allKeys.copy) {
    if (![handle.seenPanes containsObject:paneKey]) {
      [handle.workspacePanes[paneKey] removeFromSuperview];
      [handle.workspacePanes removeObjectForKey:paneKey];
      [handle.workspacePaneRoles removeObjectForKey:paneKey];
      [handle.workspacePaneExtents removeObjectForKey:paneKey];
      [handle.workspacePaneMinimumExtents removeObjectForKey:paneKey];
      [handle.workspacePaneMaximumExtents removeObjectForKey:paneKey];
      [handle.workspacePaneStretchWeights removeObjectForKey:paneKey];
      [handle.workspacePaneCollapsedStates removeObjectForKey:paneKey];
      [handle.workspacePendingPaneEvents removeObjectForKey:paneKey];
    }
  }

  [handle.workspaceSplit adjustSubviews];
  NSArray<NSView *> *visiblePanes =
      [handle.workspaceSplit.subviews filteredArrayUsingPredicate:
          [NSPredicate predicateWithBlock:^BOOL(NSView *pane, NSDictionary *bindings) {
            (void)bindings;
            return !pane.hidden;
          }]];
  if (handle.workspaceSplit.vertical && visiblePanes.count >= 2) {
    NSView *first = visiblePanes.firstObject;
    NSNumber *firstKey = [handle.workspacePanes allKeysForObject:first].firstObject;
    CGFloat firstExtent = handle.workspacePaneExtents[firstKey].doubleValue;
    if (firstExtent > 0) {
      [handle.workspaceSplit setPosition:firstExtent ofDividerAtIndex:0];
    }
    if (visiblePanes.count >= 3) {
      NSView *last = visiblePanes.lastObject;
      NSNumber *lastKey = [handle.workspacePanes allKeysForObject:last].firstObject;
      CGFloat lastExtent = handle.workspacePaneExtents[lastKey].doubleValue;
      if (lastExtent > 0) {
        CGFloat position = MAX(firstExtent, handle.workspaceSplit.bounds.size.width - lastExtent);
        [handle.workspaceSplit setPosition:position ofDividerAtIndex:visiblePanes.count - 2];
      }
    }
  }
  handle.workspaceApplyingLayout = NO;
}

static HaskeLUIMacControlRef HaskeLUIRetainControl(
    NSView *view,
    NSView *focusView,
    HaskeLUIMacActionTarget *target,
    HaskeLUIMacControlKind kind,
    uint64_t identity,
    HaskeLUIMacWindowRef windowReference) {
  HaskeLUIMacControlHandle *handle = [[HaskeLUIMacControlHandle alloc] init];
  handle.identity = identity;
  handle.view = view;
  handle.focusView = focusView;
  handle.desiredFrame = view.frame;
  handle.target = target;
  handle.kind = kind;
  handle.contentView = view;
  handle.slots = [[NSMutableDictionary alloc] init];
  handle.items = [[NSMutableArray alloc] init];
  handle.itemTargets = [[NSMutableArray alloc] init];
  focusView.accessibilityElement = YES;
  focusView.accessibilityIdentifier = [NSString stringWithFormat:@"haskelui-control-%llu", identity];
  switch (kind) {
    case HaskeLUIMacControlKindLabel:
      focusView.accessibilityRole = NSAccessibilityStaticTextRole;
      break;
    case HaskeLUIMacControlKindButton:
      focusView.accessibilityRole = NSAccessibilityButtonRole;
      break;
    case HaskeLUIMacControlKindTextField:
      focusView.accessibilityRole = NSAccessibilityTextFieldRole;
      break;
    case HaskeLUIMacControlKindTextEditor:
      focusView.accessibilityRole = NSAccessibilityTextAreaRole;
      break;
    case HaskeLUIMacControlKindDrawing:
      focusView.accessibilityRole = NSAccessibilityImageRole;
      break;
    case HaskeLUIMacControlKindCatalog:
      focusView.accessibilityRole = NSAccessibilityGroupRole;
      break;
  }
  [HaskeLUIWindow(windowReference).window.contentView addSubview:view];
  HaskeLUIState.controls[@(identity)] = handle;
  return (__bridge_retained void *)handle;
}

HaskeLUIMacControlRef haskelui_macos_label_create(
    HaskeLUIMacWindowRef window,
    uint64_t identity,
    const char *utf8_text,
    const HaskeLUIMacRect *frame) {
  HaskeLUIAssertMainThread();
  NSTextField *label = [[NSTextField alloc] initWithFrame:HaskeLUIRect(frame)];
  label.stringValue = HaskeLUIString(utf8_text);
  label.editable = NO;
  label.selectable = NO;
  label.bezeled = NO;
  label.drawsBackground = NO;
  return HaskeLUIRetainControl(label, label, nil, HaskeLUIMacControlKindLabel, identity, window);
}

HaskeLUIMacControlRef haskelui_macos_button_create(
    HaskeLUIMacWindowRef window,
    uint64_t identity,
    const char *utf8_title,
    uint64_t command_identity,
    const HaskeLUIMacRect *frame) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacActionTarget *target = [[HaskeLUIMacActionTarget alloc] init];
  HaskeLUILiveActionTargets += 1;
  target.identity = command_identity;
  target.eventKind = HaskeLUIMacEventCommand;

  NSButton *button = [[NSButton alloc] initWithFrame:HaskeLUIRect(frame)];
  button.title = HaskeLUIString(utf8_title);
  button.bezelStyle = NSBezelStyleRounded;
  button.target = target;
  button.action = @selector(performAction:);
  return HaskeLUIRetainControl(button, button, target, HaskeLUIMacControlKindButton, identity, window);
}

HaskeLUIMacControlRef haskelui_macos_text_field_create(
    HaskeLUIMacWindowRef window,
    uint64_t identity,
    const char *utf8_text,
    const char *utf8_placeholder,
    const HaskeLUIMacRect *frame) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacActionTarget *target = [[HaskeLUIMacActionTarget alloc] init];
  HaskeLUILiveActionTargets += 1;
  target.identity = identity;
  target.eventKind = HaskeLUIMacEventTextChanged;

  NSTextField *field = [[NSTextField alloc] initWithFrame:HaskeLUIRect(frame)];
  field.stringValue = HaskeLUIString(utf8_text);
  field.placeholderString = HaskeLUIString(utf8_placeholder);
  field.delegate = target;
  return HaskeLUIRetainControl(field, field, target, HaskeLUIMacControlKindTextField, identity, window);
}

HaskeLUIMacControlRef haskelui_macos_text_editor_create(
    HaskeLUIMacWindowRef window,
    uint64_t identity,
    const char *utf8_text,
    const HaskeLUIMacRect *frame) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacActionTarget *target = [[HaskeLUIMacActionTarget alloc] init];
  HaskeLUILiveActionTargets += 1;
  target.identity = identity;
  target.eventKind = HaskeLUIMacEventTextChanged;

  NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:HaskeLUIRect(frame)];
  scrollView.borderType = NSBezelBorder;
  scrollView.hasVerticalScroller = YES;
  scrollView.hasHorizontalScroller = NO;
  scrollView.autohidesScrollers = YES;
  scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  NSRect editorFrame = NSMakeRect(0, 0, frame->width, frame->height);
  NSTextView *editor = [[NSTextView alloc] initWithFrame:editorFrame];
  editor.string = HaskeLUIString(utf8_text);
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

  return HaskeLUIRetainControl(
      scrollView,
      editor,
      target,
      HaskeLUIMacControlKindTextEditor,
      identity,
      window);
}

static HaskeLUIDrawingView *HaskeLUIDrawing(HaskeLUIMacControlRef reference) {
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  if (handle.kind != HaskeLUIMacControlKindDrawing ||
      ![handle.view isKindOfClass:HaskeLUIDrawingView.class]) {
    return nil;
  }
  return (HaskeLUIDrawingView *)handle.view;
}

static void HaskeLUIAppendDrawingCommand(
    HaskeLUIDrawingView *view,
    NSDictionary *command) {
  if (view.pendingCommands != nil && command != nil) {
    [view.pendingCommands addObject:command];
  }
}

HaskeLUIMacControlRef haskelui_macos_drawing_surface_create(
    HaskeLUIMacWindowRef window,
    uint64_t identity,
    const char *utf8AccessibleLabel,
    const HaskeLUIMacRect *frame) {
  HaskeLUIAssertMainThread();
  HaskeLUIDrawingView *view = [[HaskeLUIDrawingView alloc] initWithFrame:HaskeLUIRect(frame)];
  view.identity = identity;
  view.drawingInputEnabled = NO;
  view.drawingCursor = 0;
  view.drawingCommands = @[];
  view.accessibilityLabel = HaskeLUIString(utf8AccessibleLabel);
  return HaskeLUIRetainControl(
      view,
      view,
      nil,
      HaskeLUIMacControlKindDrawing,
      identity,
      window);
}

void haskelui_macos_drawing_set_accessible_label(
    HaskeLUIMacControlRef reference,
    const char *utf8AccessibleLabel) {
  HaskeLUIDrawingView *view = HaskeLUIDrawing(reference);
  view.accessibilityLabel = HaskeLUIString(utf8AccessibleLabel);
}

void haskelui_macos_drawing_set_input_enabled(
    HaskeLUIMacControlRef reference,
    int32_t enabled) {
  HaskeLUIAssertMainThread();
  HaskeLUIDrawingView *view = HaskeLUIDrawing(reference);
  if (view == nil) {
    return;
  }
  view.drawingInputEnabled = enabled != 0;
  [view updateTrackingAreas];
  [view.window invalidateCursorRectsForView:view];
}

void haskelui_macos_drawing_set_cursor(
    HaskeLUIMacControlRef reference,
    int32_t cursor) {
  HaskeLUIAssertMainThread();
  HaskeLUIDrawingView *view = HaskeLUIDrawing(reference);
  if (view == nil) {
    return;
  }
  view.drawingCursor = cursor;
  [view.window invalidateCursorRectsForView:view];
}

void haskelui_macos_drawing_begin(HaskeLUIMacControlRef reference) {
  HaskeLUIAssertMainThread();
  HaskeLUIDrawingView *view = HaskeLUIDrawing(reference);
  view.pendingCommands = [[NSMutableArray alloc] init];
  view.pendingPath = nil;
}

void haskelui_macos_drawing_push_state(HaskeLUIMacControlRef reference) {
  HaskeLUIAppendDrawingCommand(
      HaskeLUIDrawing(reference),
      @{@"kind": @(HaskeLUIDrawingPushState)});
}

void haskelui_macos_drawing_pop_state(HaskeLUIMacControlRef reference) {
  HaskeLUIAppendDrawingCommand(
      HaskeLUIDrawing(reference),
      @{@"kind": @(HaskeLUIDrawingPopState)});
}

void haskelui_macos_drawing_concat_transform(
    HaskeLUIMacControlRef reference,
    double a, double b, double c, double d, double tx, double ty) {
  HaskeLUIAppendDrawingCommand(
      HaskeLUIDrawing(reference),
      @{
        @"kind": @(HaskeLUIDrawingTransform),
        @"a": @(a), @"b": @(b), @"c": @(c), @"d": @(d),
        @"tx": @(tx), @"ty": @(ty)
      });
}

void haskelui_macos_drawing_begin_opacity(
    HaskeLUIMacControlRef reference,
    double opacity) {
  HaskeLUIAppendDrawingCommand(
      HaskeLUIDrawing(reference),
      @{@"kind": @(HaskeLUIDrawingBeginOpacity), @"alpha": @(opacity)});
}

void haskelui_macos_drawing_end_opacity(HaskeLUIMacControlRef reference) {
  HaskeLUIAppendDrawingCommand(
      HaskeLUIDrawing(reference),
      @{@"kind": @(HaskeLUIDrawingEndOpacity)});
}

void haskelui_macos_drawing_path_begin(HaskeLUIMacControlRef reference) {
  HaskeLUIDrawing(reference).pendingPath = [NSBezierPath bezierPath];
}

void haskelui_macos_drawing_path_move_to(
    HaskeLUIMacControlRef reference,
    double x,
    double y) {
  [HaskeLUIDrawing(reference).pendingPath moveToPoint:NSMakePoint(x, y)];
}

void haskelui_macos_drawing_path_line_to(
    HaskeLUIMacControlRef reference,
    double x,
    double y) {
  [HaskeLUIDrawing(reference).pendingPath lineToPoint:NSMakePoint(x, y)];
}

void haskelui_macos_drawing_path_quadratic_to(
    HaskeLUIMacControlRef reference,
    double controlX,
    double controlY,
    double x,
    double y) {
  NSBezierPath *path = HaskeLUIDrawing(reference).pendingPath;
  NSPoint start = path.currentPoint;
  NSPoint control = NSMakePoint(controlX, controlY);
  NSPoint end = NSMakePoint(x, y);
  NSPoint first = NSMakePoint(
      start.x + (2.0 / 3.0) * (control.x - start.x),
      start.y + (2.0 / 3.0) * (control.y - start.y));
  NSPoint second = NSMakePoint(
      end.x + (2.0 / 3.0) * (control.x - end.x),
      end.y + (2.0 / 3.0) * (control.y - end.y));
  [path curveToPoint:end controlPoint1:first controlPoint2:second];
}

void haskelui_macos_drawing_path_cubic_to(
    HaskeLUIMacControlRef reference,
    double control1X,
    double control1Y,
    double control2X,
    double control2Y,
    double x,
    double y) {
  [HaskeLUIDrawing(reference).pendingPath
      curveToPoint:NSMakePoint(x, y)
      controlPoint1:NSMakePoint(control1X, control1Y)
      controlPoint2:NSMakePoint(control2X, control2Y)];
}

void haskelui_macos_drawing_path_close(HaskeLUIMacControlRef reference) {
  [HaskeLUIDrawing(reference).pendingPath closePath];
}

void haskelui_macos_drawing_path_add_rect(
    HaskeLUIMacControlRef reference,
    const HaskeLUIMacRect *rect) {
  [HaskeLUIDrawing(reference).pendingPath appendBezierPathWithRect:HaskeLUIRect(rect)];
}

void haskelui_macos_drawing_path_add_rounded_rect(
    HaskeLUIMacControlRef reference,
    const HaskeLUIMacRect *rect,
    double radiusX,
    double radiusY) {
  NSBezierPath *rounded = [NSBezierPath
      bezierPathWithRoundedRect:HaskeLUIRect(rect)
      xRadius:radiusX
      yRadius:radiusY];
  [HaskeLUIDrawing(reference).pendingPath appendBezierPath:rounded];
}

void haskelui_macos_drawing_path_add_ellipse(
    HaskeLUIMacControlRef reference,
    const HaskeLUIMacRect *rect) {
  [HaskeLUIDrawing(reference).pendingPath
      appendBezierPathWithOvalInRect:HaskeLUIRect(rect)];
}

static NSBezierPath *HaskeLUITakeDrawingPath(HaskeLUIDrawingView *view) {
  NSBezierPath *path = [view.pendingPath copy] ?: [NSBezierPath bezierPath];
  view.pendingPath = nil;
  return path;
}

void haskelui_macos_drawing_clip_path(
    HaskeLUIMacControlRef reference,
    int32_t evenOdd) {
  HaskeLUIDrawingView *view = HaskeLUIDrawing(reference);
  HaskeLUIAppendDrawingCommand(
      view,
      @{
        @"kind": @(HaskeLUIDrawingClip),
        @"path": HaskeLUITakeDrawingPath(view),
        @"evenOdd": @(evenOdd != 0)
      });
}

void haskelui_macos_drawing_fill_path(
    HaskeLUIMacControlRef reference,
    int32_t evenOdd,
    double red,
    double green,
    double blue,
    double alpha) {
  HaskeLUIDrawingView *view = HaskeLUIDrawing(reference);
  HaskeLUIAppendDrawingCommand(
      view,
      @{
        @"kind": @(HaskeLUIDrawingFill),
        @"path": HaskeLUITakeDrawingPath(view),
        @"evenOdd": @(evenOdd != 0),
        @"color": HaskeLUIColor(red, green, blue, alpha)
      });
}

void haskelui_macos_drawing_stroke_path(
    HaskeLUIMacControlRef reference,
    double width,
    int32_t lineCap,
    int32_t lineJoin,
    double miterLimit,
    const double *dashPattern,
    uint64_t dashCount,
    double dashPhase,
    double red,
    double green,
    double blue,
    double alpha) {
  HaskeLUIDrawingView *view = HaskeLUIDrawing(reference);
  NSMutableArray<NSNumber *> *dash = [[NSMutableArray alloc] init];
  for (uint64_t index = 0; index < dashCount; index += 1) {
    [dash addObject:@(dashPattern[index])];
  }
  HaskeLUIAppendDrawingCommand(
      view,
      @{
        @"kind": @(HaskeLUIDrawingStroke),
        @"path": HaskeLUITakeDrawingPath(view),
        @"width": @(width),
        @"cap": @(lineCap),
        @"join": @(lineJoin),
        @"miter": @(miterLimit),
        @"dash": dash,
        @"phase": @(dashPhase),
        @"color": HaskeLUIColor(red, green, blue, alpha)
      });
}

void haskelui_macos_drawing_text(
    HaskeLUIMacControlRef reference,
    const char *utf8Text,
    const HaskeLUIMacRect *rect,
    const HaskeLUIMacTextStyle *style,
    int32_t horizontalAlignment,
    int32_t verticalAlignment,
    int32_t wrapping) {
  HaskeLUIDrawingView *view = HaskeLUIDrawing(reference);
  NSMutableDictionary<NSAttributedStringKey, id> *attributes =
      [[NSMutableDictionary alloc] init];
  attributes[NSForegroundColorAttributeName] = NSColor.labelColor;
  attributes[NSFontAttributeName] = [NSFont systemFontOfSize:13.0];
  if (style != NULL) {
    if ((style->fields & HaskeLUIMacTextStyleForeground) != 0) {
      attributes[NSForegroundColorAttributeName] = HaskeLUIColor(
          style->foreground_red,
          style->foreground_green,
          style->foreground_blue,
          style->foreground_alpha);
    }
    if ((style->fields & HaskeLUIMacTextStyleBackground) != 0) {
      attributes[NSBackgroundColorAttributeName] = HaskeLUIColor(
          style->background_red,
          style->background_green,
          style->background_blue,
          style->background_alpha);
    }
    NSFont *font = HaskeLUIFontForStyle(attributes[NSFontAttributeName], style);
    if (font != nil) {
      attributes[NSFontAttributeName] = font;
    }
    if ((style->fields & HaskeLUIMacTextStyleUnderline) != 0) {
      attributes[NSUnderlineStyleAttributeName] =
          @(HaskeLUIUnderlineStyle(style->underline_style));
    }
    if ((style->fields & HaskeLUIMacTextStyleUnderlineColor) != 0) {
      attributes[NSUnderlineColorAttributeName] = HaskeLUIColor(
          style->underline_red,
          style->underline_green,
          style->underline_blue,
          style->underline_alpha);
    }
    if ((style->fields & HaskeLUIMacTextStyleStrikethrough) != 0) {
      attributes[NSStrikethroughStyleAttributeName] =
          style->strikethrough != 0 ? @(NSUnderlineStyleSingle) : @0;
    }
    if ((style->fields & HaskeLUIMacTextStyleLetterSpacing) != 0) {
      attributes[NSKernAttributeName] = @(style->letter_spacing);
    }
    if ((style->fields & HaskeLUIMacTextStyleBaselineOffset) != 0) {
      attributes[NSBaselineOffsetAttributeName] = @(style->baseline_offset);
    }
  }
  NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
  paragraph.alignment = horizontalAlignment == 1
      ? NSTextAlignmentCenter
      : horizontalAlignment == 2 ? NSTextAlignmentRight : NSTextAlignmentLeft;
  paragraph.lineBreakMode = wrapping == 2
      ? NSLineBreakByCharWrapping
      : wrapping == 1 ? NSLineBreakByWordWrapping : NSLineBreakByClipping;
  attributes[NSParagraphStyleAttributeName] = paragraph;
  HaskeLUIAppendDrawingCommand(
      view,
      @{
        @"kind": @(HaskeLUIDrawingText),
        @"text": HaskeLUIString(utf8Text),
        @"rect": [NSValue valueWithRect:HaskeLUIRect(rect)],
        @"attributes": attributes,
        @"vertical": @(verticalAlignment),
        @"wrap": @(wrapping)
      });
}

void haskelui_macos_drawing_end(HaskeLUIMacControlRef reference) {
  HaskeLUIAssertMainThread();
  HaskeLUIDrawingView *view = HaskeLUIDrawing(reference);
  if (view.pendingCommands != nil) {
    view.drawingCommands = [view.pendingCommands copy];
    view.pendingCommands = nil;
    view.pendingPath = nil;
    view.drawingPresentationGeneration += 1;
    [view setNeedsDisplay:YES];
  }
}

static HaskeLUIMacActionTarget *HaskeLUINewTarget(uint64_t identity, int32_t eventKind) {
  HaskeLUIMacActionTarget *target = [[HaskeLUIMacActionTarget alloc] init];
  HaskeLUILiveActionTargets += 1;
  target.identity = identity;
  target.eventKind = eventKind;
  return target;
}

static NSScrollView *HaskeLUITextArea(
    const HaskeLUIMacRect *frame,
    HaskeLUIMacActionTarget *target,
    BOOL rich,
    NSTextView **editorResult) {
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:HaskeLUIRect(frame)];
  scroll.borderType = NSBezelBorder;
  scroll.hasVerticalScroller = YES;
  scroll.autohidesScrollers = YES;
  NSTextView *editor = [[NSTextView alloc] initWithFrame:scroll.bounds];
  editor.delegate = target;
  editor.richText = rich;
  editor.allowsUndo = YES;
  editor.verticallyResizable = YES;
  editor.horizontallyResizable = NO;
  editor.autoresizingMask = NSViewWidthSizable;
  editor.textContainer.containerSize = NSMakeSize(frame->width, CGFLOAT_MAX);
  editor.textContainer.widthTracksTextView = YES;
  scroll.documentView = editor;
  *editorResult = editor;
  return scroll;
}

static NSScrollView *HaskeLUICollectionView(
    const HaskeLUIMacRect *frame,
    uint64_t identity,
    BOOL tableColumns,
    HaskeLUIMacCollectionAdapter **adapterResult,
    NSTableView **tableResult) {
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:HaskeLUIRect(frame)];
  scroll.borderType = NSBezelBorder;
  scroll.hasVerticalScroller = YES;
  NSTableView *table = [[NSTableView alloc] initWithFrame:scroll.bounds];
  table.usesAlternatingRowBackgroundColors = YES;
  table.allowsEmptySelection = YES;
  if (!tableColumns) {
    table.headerView = nil;
  }
  NSTableColumn *label = [[NSTableColumn alloc] initWithIdentifier:@"label"];
  label.title = tableColumns ? @"Item" : @"";
  label.width = tableColumns ? frame->width * 0.55 : frame->width;
  [table addTableColumn:label];
  if (tableColumns) {
    NSTableColumn *detail = [[NSTableColumn alloc] initWithIdentifier:@"detail"];
    detail.title = @"Value";
    detail.width = frame->width * 0.4;
    [table addTableColumn:detail];
  }
  HaskeLUIMacCollectionAdapter *adapter = [[HaskeLUIMacCollectionAdapter alloc] init];
  adapter.identity = identity;
  adapter.items = [[NSMutableArray alloc] init];
  adapter.table = table;
  table.dataSource = adapter;
  table.delegate = adapter;
  scroll.documentView = table;
  *adapterResult = adapter;
  *tableResult = table;
  return scroll;
}

static NSScrollView *HaskeLUIGridCollectionView(
    const HaskeLUIMacRect *frame,
    uint64_t identity,
    BOOL repeater,
    HaskeLUIMacGridAdapter **adapterResult,
    NSCollectionView **collectionResult) {
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:HaskeLUIRect(frame)];
  scroll.borderType = repeater ? NSNoBorder : NSBezelBorder;
  scroll.hasVerticalScroller = YES;
  scroll.autohidesScrollers = YES;
  NSCollectionViewFlowLayout *layout = [[NSCollectionViewFlowLayout alloc] init];
  layout.itemSize = repeater
      ? NSMakeSize(MAX(120, frame->width - 24), 42)
      : NSMakeSize(128, 66);
  layout.minimumInteritemSpacing = 10;
  layout.minimumLineSpacing = repeater ? 2 : 10;
  layout.sectionInset = repeater
      ? NSEdgeInsetsMake(6, 6, 6, 6)
      : NSEdgeInsetsMake(12, 12, 12, 12);
  NSCollectionView *collection = [[NSCollectionView alloc] initWithFrame:scroll.bounds];
  collection.collectionViewLayout = layout;
  collection.selectable = YES;
  collection.backgroundColors = @[repeater ? NSColor.clearColor : NSColor.controlBackgroundColor];
  [collection registerClass:HaskeLUIMacGridItem.class forItemWithIdentifier:@"HaskeLUIGridItem"];
  HaskeLUIMacGridAdapter *adapter = [[HaskeLUIMacGridAdapter alloc] init];
  adapter.identity = identity;
  adapter.items = [[NSMutableArray alloc] init];
  adapter.collection = collection;
  adapter.repeater = repeater;
  collection.dataSource = adapter;
  collection.delegate = adapter;
  scroll.documentView = collection;
  *adapterResult = adapter;
  *collectionResult = collection;
  return scroll;
}

static NSScrollView *HaskeLUIOutlineCollectionView(
    const HaskeLUIMacRect *frame,
    uint64_t identity,
    HaskeLUIMacOutlineAdapter **adapterResult,
    NSOutlineView **outlineResult) {
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:HaskeLUIRect(frame)];
  scroll.borderType = NSBezelBorder;
  scroll.hasVerticalScroller = YES;
  NSOutlineView *outline = [[NSOutlineView alloc] initWithFrame:scroll.bounds];
  outline.headerView = nil;
  outline.indentationPerLevel = 16;
  outline.allowsEmptySelection = YES;
  NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"outline"];
  column.width = frame->width;
  [outline addTableColumn:column];
  outline.outlineTableColumn = column;
  HaskeLUIMacOutlineAdapter *adapter = [[HaskeLUIMacOutlineAdapter alloc] init];
  adapter.identity = identity;
  adapter.items = [[NSMutableArray alloc] init];
  adapter.roots = [[NSMutableArray alloc] init];
  adapter.outline = outline;
  outline.dataSource = adapter;
  outline.delegate = adapter;
  outline.target = adapter;
  outline.action = @selector(activateSelectedItem:);
  scroll.documentView = outline;
  *adapterResult = adapter;
  *outlineResult = outline;
  return scroll;
}

HaskeLUIMacControlRef haskelui_macos_catalog_control_create(
    HaskeLUIMacWindowRef window,
    uint64_t identity,
    int32_t catalogKind,
    const HaskeLUIMacRect *frame) {
  HaskeLUIAssertMainThread();
  NSView *view = nil;
  NSView *focusView = nil;
  HaskeLUIMacActionTarget *target = nil;
  HaskeLUIMacCollectionAdapter *collectionAdapter = nil;
  HaskeLUIMacGridAdapter *gridAdapter = nil;
  HaskeLUIMacOutlineAdapter *outlineAdapter = nil;

  switch (catalogKind) {
    case HaskeLUIMacCatalogRichText: {
      NSTextView *text = nil;
      NSScrollView *scroll = HaskeLUITextArea(frame, nil, YES, &text);
      scroll.borderType = NSNoBorder;
      scroll.hasVerticalScroller = NO;
      text.editable = NO;
      text.selectable = YES;
      text.drawsBackground = NO;
      text.allowsUndo = NO;
      view = scroll;
      focusView = text;
      break;
    }
    case HaskeLUIMacCatalogImage:
    case HaskeLUIMacCatalogIcon: {
      NSImageView *image = [[NSImageView alloc] initWithFrame:HaskeLUIRect(frame)];
      image.imageScaling = NSImageScaleProportionallyUpOrDown;
      view = image;
      focusView = image;
      break;
    }
    case HaskeLUIMacCatalogSeparator: {
      NSBox *separator = [[NSBox alloc] initWithFrame:HaskeLUIRect(frame)];
      separator.boxType = NSBoxSeparator;
      view = separator;
      focusView = separator;
      break;
    }
    case HaskeLUIMacCatalogRepeatButton:
    case HaskeLUIMacCatalogToggleButton:
    case HaskeLUIMacCatalogCheckBox:
    case HaskeLUIMacCatalogLink: {
      int32_t eventKind = catalogKind == HaskeLUIMacCatalogRepeatButton || catalogKind == HaskeLUIMacCatalogLink
          ? HaskeLUIMacEventControlInvoked
          : HaskeLUIMacEventToggleChanged;
      target = HaskeLUINewTarget(identity, eventKind);
      NSButton *button = catalogKind == HaskeLUIMacCatalogCheckBox
          ? [NSButton checkboxWithTitle:@"" target:target action:@selector(performAction:)]
          : [NSButton buttonWithTitle:@"" target:target action:@selector(performAction:)];
      button.frame = HaskeLUIRect(frame);
      if (catalogKind == HaskeLUIMacCatalogToggleButton) {
        button.buttonType = NSButtonTypePushOnPushOff;
      } else if (catalogKind == HaskeLUIMacCatalogCheckBox) {
        button.allowsMixedState = YES;
      } else if (catalogKind == HaskeLUIMacCatalogLink) {
        button.bordered = NO;
        button.bezelStyle = NSBezelStyleInline;
        button.contentTintColor = NSColor.linkColor;
        button.alignment = NSTextAlignmentLeft;
      }
      if (catalogKind == HaskeLUIMacCatalogRepeatButton) {
        button.continuous = YES;
        [button setPeriodicDelay:0.35 interval:0.08];
      }
      view = button;
      focusView = button;
      break;
    }
    case HaskeLUIMacCatalogSwitch: {
      target = HaskeLUINewTarget(identity, HaskeLUIMacEventToggleChanged);
      NSSwitch *toggle = [[NSSwitch alloc] initWithFrame:NSZeroRect];
      toggle.target = target;
      toggle.action = @selector(performAction:);
      toggle.identifier = @"switch";
      NSTextField *label = [NSTextField labelWithString:@""];
      label.identifier = @"switchLabel";
      NSStackView *stack = [NSStackView stackViewWithViews:@[toggle, label]];
      stack.frame = HaskeLUIRect(frame);
      stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
      stack.alignment = NSLayoutAttributeCenterY;
      stack.spacing = 8;
      view = stack;
      focusView = toggle;
      break;
    }
    case HaskeLUIMacCatalogRadioGroup:
    case HaskeLUIMacCatalogMenuBar:
    case HaskeLUIMacCatalogToolbar: {
      NSStackView *stack = [[NSStackView alloc] initWithFrame:HaskeLUIRect(frame)];
      stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
      stack.alignment = NSLayoutAttributeCenterY;
      stack.spacing = 6;
      view = stack;
      focusView = stack;
      break;
    }
    case HaskeLUIMacCatalogSegmentedChoice:
    case HaskeLUIMacCatalogBreadcrumb: {
      target = HaskeLUINewTarget(identity, HaskeLUIMacEventChoiceChanged);
      NSSegmentedControl *segments = [[NSSegmentedControl alloc] initWithFrame:HaskeLUIRect(frame)];
      segments.target = target;
      segments.action = @selector(performAction:);
      segments.segmentStyle = catalogKind == HaskeLUIMacCatalogBreadcrumb
          ? NSSegmentStyleTexturedRounded
          : NSSegmentStyleRounded;
      view = segments;
      focusView = segments;
      break;
    }
    case HaskeLUIMacCatalogMenuButton:
    case HaskeLUIMacCatalogChoicePicker:
    case HaskeLUIMacCatalogContextMenu: {
      target = HaskeLUINewTarget(identity, HaskeLUIMacEventChoiceChanged);
      NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:HaskeLUIRect(frame) pullsDown:NO];
      popup.target = target;
      popup.action = @selector(performAction:);
      view = popup;
      focusView = popup;
      break;
    }
    case HaskeLUIMacCatalogSplitButton:
    case HaskeLUIMacCatalogToggleSplitButton: {
      target = HaskeLUINewTarget(identity,
          catalogKind == HaskeLUIMacCatalogToggleSplitButton
              ? HaskeLUIMacEventToggleChanged
              : HaskeLUIMacEventControlInvoked);
      NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
      button.target = target;
      button.action = @selector(performAction:);
      button.bezelStyle = NSBezelStyleRounded;
      if (catalogKind == HaskeLUIMacCatalogToggleSplitButton) {
        button.buttonType = NSButtonTypePushOnPushOff;
      }
      NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
      NSStackView *stack = [NSStackView stackViewWithViews:@[button, popup]];
      stack.frame = HaskeLUIRect(frame);
      stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
      stack.spacing = 1;
      button.identifier = @"primary";
      popup.identifier = @"menu";
      view = stack;
      focusView = button;
      break;
    }
    case HaskeLUIMacCatalogTextArea:
    case HaskeLUIMacCatalogRichTextEditor: {
      target = HaskeLUINewTarget(identity, HaskeLUIMacEventTextChanged);
      NSTextView *editor = nil;
      view = HaskeLUITextArea(frame, target, catalogKind == HaskeLUIMacCatalogRichTextEditor, &editor);
      focusView = editor;
      break;
    }
    case HaskeLUIMacCatalogSecureField:
    case HaskeLUIMacCatalogSearchField:
    case HaskeLUIMacCatalogSuggestField:
    case HaskeLUIMacCatalogEditableComboBox: {
      target = HaskeLUINewTarget(identity, HaskeLUIMacEventTextChanged);
      NSTextField *field = nil;
      if (catalogKind == HaskeLUIMacCatalogSecureField) {
        field = [[NSSecureTextField alloc] initWithFrame:HaskeLUIRect(frame)];
      } else if (catalogKind == HaskeLUIMacCatalogSearchField) {
        field = [[NSSearchField alloc] initWithFrame:HaskeLUIRect(frame)];
      } else {
        field = [[NSComboBox alloc] initWithFrame:HaskeLUIRect(frame)];
      }
      field.delegate = target;
      view = field;
      focusView = field;
      break;
    }
    case HaskeLUIMacCatalogNumberField: {
      target = HaskeLUINewTarget(identity, HaskeLUIMacEventNumberChanged);
      NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];
      field.target = target;
      field.action = @selector(performAction:);
      NSStepper *stepper = [[NSStepper alloc] initWithFrame:NSZeroRect];
      stepper.target = target;
      stepper.action = @selector(performAction:);
      NSStackView *stack = [NSStackView stackViewWithViews:@[field, stepper]];
      stack.frame = HaskeLUIRect(frame);
      stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
      stack.spacing = 4;
      [field.widthAnchor constraintGreaterThanOrEqualToConstant:MAX(60, frame->width - 34)].active = YES;
      field.identifier = @"numberField";
      stepper.identifier = @"numberStepper";
      view = stack;
      focusView = field;
      break;
    }
    case HaskeLUIMacCatalogStepper:
    case HaskeLUIMacCatalogSlider:
    case HaskeLUIMacCatalogRating: {
      target = HaskeLUINewTarget(identity, HaskeLUIMacEventNumberChanged);
      NSControl *control = nil;
      if (catalogKind == HaskeLUIMacCatalogStepper) {
        control = [[NSStepper alloc] initWithFrame:HaskeLUIRect(frame)];
      } else if (catalogKind == HaskeLUIMacCatalogSlider) {
        control = [[NSSlider alloc] initWithFrame:HaskeLUIRect(frame)];
      } else {
        NSLevelIndicator *rating = [[NSLevelIndicator alloc] initWithFrame:HaskeLUIRect(frame)];
        rating.levelIndicatorStyle = NSLevelIndicatorStyleRating;
        rating.editable = YES;
        control = rating;
      }
      control.target = target;
      control.action = @selector(performAction:);
      view = control;
      focusView = control;
      break;
    }
    case HaskeLUIMacCatalogDatePicker:
    case HaskeLUIMacCatalogTimePicker:
    case HaskeLUIMacCatalogCalendarView: {
      int32_t eventKind = catalogKind == HaskeLUIMacCatalogTimePicker
          ? HaskeLUIMacEventTimeChanged
          : HaskeLUIMacEventDateChanged;
      target = HaskeLUINewTarget(identity, eventKind);
      NSDatePicker *picker = [[NSDatePicker alloc] initWithFrame:HaskeLUIRect(frame)];
      picker.target = target;
      picker.action = @selector(performAction:);
      picker.datePickerElements = catalogKind == HaskeLUIMacCatalogTimePicker
          ? (NSDatePickerElementFlagHourMinuteSecond)
          : (NSDatePickerElementFlagYearMonthDay);
      picker.datePickerStyle = catalogKind == HaskeLUIMacCatalogCalendarView
          ? NSDatePickerStyleClockAndCalendar
          : NSDatePickerStyleTextFieldAndStepper;
      view = picker;
      focusView = picker;
      break;
    }
    case HaskeLUIMacCatalogColorPicker: {
      target = HaskeLUINewTarget(identity, HaskeLUIMacEventColorChanged);
      NSColorWell *well = [[NSColorWell alloc] initWithFrame:HaskeLUIRect(frame)];
      well.target = target;
      well.action = @selector(performAction:);
      view = well;
      focusView = well;
      break;
    }
    case HaskeLUIMacCatalogListView:
    case HaskeLUIMacCatalogTableView:
    case HaskeLUIMacCatalogNavigationSidebar: {
      NSTableView *table = nil;
      view = HaskeLUICollectionView(frame, identity, catalogKind == HaskeLUIMacCatalogTableView,
                               &collectionAdapter, &table);
      if (catalogKind == HaskeLUIMacCatalogNavigationSidebar) {
        table.style = NSTableViewStyleSourceList;
        table.usesAlternatingRowBackgroundColors = NO;
        collectionAdapter.showsDepth = YES;
        collectionAdapter.navigationStyle = YES;
      } else if (catalogKind == HaskeLUIMacCatalogListView) {
        table.usesAlternatingRowBackgroundColors = NO;
      }
      focusView = table;
      break;
    }
    case HaskeLUIMacCatalogCollectionView:
    case HaskeLUIMacCatalogItemRepeater: {
      NSCollectionView *collection = nil;
      view = HaskeLUIGridCollectionView(
          frame, identity, catalogKind == HaskeLUIMacCatalogItemRepeater,
          &gridAdapter, &collection);
      focusView = collection;
      break;
    }
    case HaskeLUIMacCatalogTreeView: {
      NSOutlineView *outline = nil;
      view = HaskeLUIOutlineCollectionView(frame, identity, &outlineAdapter, &outline);
      focusView = outline;
      break;
    }
    case HaskeLUIMacCatalogTabView: {
      target = HaskeLUINewTarget(identity, HaskeLUIMacEventChoiceChanged);
      NSSegmentedControl *segments = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
      segments.target = target;
      segments.action = @selector(performAction:);
      segments.identifier = @"tabs";
      NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
      content.identifier = @"content";
      NSView *root = [[NSView alloc] initWithFrame:HaskeLUIRect(frame)];
      [root addSubview:segments];
      [root addSubview:content];
      segments.frame = NSMakeRect(0, MAX(0, frame->height - 30), frame->width, 28);
      content.frame = NSMakeRect(0, 0, frame->width, MAX(0, frame->height - 32));
      view = root;
      focusView = segments;
      break;
    }
    case HaskeLUIMacCatalogProgressBar:
    case HaskeLUIMacCatalogActivityIndicator:
    case HaskeLUIMacCatalogMeter: {
      NSProgressIndicator *progress = [[NSProgressIndicator alloc] initWithFrame:HaskeLUIRect(frame)];
      progress.style = catalogKind == HaskeLUIMacCatalogActivityIndicator
          ? NSProgressIndicatorStyleSpinning
          : NSProgressIndicatorStyleBar;
      progress.indeterminate = catalogKind == HaskeLUIMacCatalogActivityIndicator;
      if (catalogKind == HaskeLUIMacCatalogActivityIndicator) {
        [progress startAnimation:nil];
      }
      view = progress;
      focusView = progress;
      break;
    }
    case HaskeLUIMacCatalogTooltip:
    case HaskeLUIMacCatalogBadge:
    case HaskeLUIMacCatalogInlineNotice: {
      NSBox *box = [[NSBox alloc] initWithFrame:HaskeLUIRect(frame)];
      box.boxType = NSBoxCustom;
      box.titlePosition = NSNoTitle;
      box.borderWidth = catalogKind == HaskeLUIMacCatalogBadge ? 1.0 : 0.75;
      box.cornerRadius = catalogKind == HaskeLUIMacCatalogBadge ? 10.0 : 7.0;
      box.fillColor = catalogKind == HaskeLUIMacCatalogBadge
          ? NSColor.controlBackgroundColor
          : NSColor.windowBackgroundColor;
      NSTextField *title = [NSTextField wrappingLabelWithString:@""];
      title.identifier = @"messageTitle";
      title.font = catalogKind == HaskeLUIMacCatalogBadge
          ? [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]
          : [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
      NSTextField *detail = [NSTextField wrappingLabelWithString:@""];
      detail.identifier = @"messageDetail";
      detail.font = [NSFont systemFontOfSize:11];
      detail.textColor = NSColor.secondaryLabelColor;
      if (catalogKind == HaskeLUIMacCatalogBadge) {
        title.frame = NSInsetRect(box.contentView.bounds, 8, 5);
        title.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        title.alignment = NSTextAlignmentCenter;
        detail.hidden = YES;
      } else {
        CGFloat height = NSHeight(box.contentView.bounds);
        CGFloat width = MAX(0, NSWidth(box.contentView.bounds) - 24);
        title.frame = NSMakeRect(12, MAX(6, height - 26), width, 18);
        title.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        detail.frame = NSMakeRect(12, 6, width, MAX(0, height - 34));
        detail.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      }
      [box.contentView addSubview:title];
      [box.contentView addSubview:detail];
      view = box;
      focusView = box;
      break;
    }
    case HaskeLUIMacCatalogDialog:
    case HaskeLUIMacCatalogAlert:
    case HaskeLUIMacCatalogPopover: {
      NSView *placeholder = [[NSView alloc] initWithFrame:HaskeLUIRect(frame)];
      placeholder.hidden = YES;
      view = placeholder;
      focusView = placeholder;
      break;
    }
    case HaskeLUIMacCatalogContainer:
    default: {
      target = HaskeLUINewTarget(identity, HaskeLUIMacEventDisclosureChanged);
      NSBox *box = [[NSBox alloc] initWithFrame:HaskeLUIRect(frame)];
      box.boxType = NSBoxCustom;
      box.transparent = YES;
      NSButton *disclosure = [[NSButton alloc] initWithFrame:NSZeroRect];
      disclosure.buttonType = NSButtonTypePushOnPushOff;
      disclosure.bezelStyle = NSBezelStyleDisclosure;
      disclosure.target = target;
      disclosure.action = @selector(performAction:);
      disclosure.identifier = @"disclosure";
      disclosure.hidden = YES;
      NSTextField *disclosureLabel = [NSTextField labelWithString:@""];
      disclosureLabel.identifier = @"disclosureLabel";
      disclosureLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
      disclosureLabel.hidden = YES;
      HaskeLUIContainerHostView *content = [[HaskeLUIContainerHostView alloc] initWithFrame:box.contentView.bounds];
      content.identifier = @"content";
      content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      [box.contentView addSubview:content];
      [box.contentView addSubview:disclosure];
      [box.contentView addSubview:disclosureLabel];
      view = box;
      focusView = box;
      break;
    }
  }

  HaskeLUIMacControlRef reference = HaskeLUIRetainControl(
      view, focusView, target, HaskeLUIMacControlKindCatalog, identity, window);
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  handle.catalogKind = catalogKind;
  handle.collectionAdapter = collectionAdapter;
  handle.gridAdapter = gridAdapter;
  handle.outlineAdapter = outlineAdapter;
  if (collectionAdapter != nil) {
    handle.contentView = collectionAdapter.table;
  } else if (gridAdapter != nil) {
    handle.contentView = gridAdapter.collection;
  } else if (outlineAdapter != nil) {
    handle.contentView = outlineAdapter.outline;
  } else if (catalogKind == HaskeLUIMacCatalogContainer) {
    NSBox *box = (NSBox *)view;
    for (NSView *subview in box.contentView.subviews) {
      if ([subview.identifier isEqualToString:@"content"]) {
        handle.normalContentView = subview;
      } else if ([subview.identifier isEqualToString:@"disclosure"]) {
        handle.disclosureButton = (NSButton *)subview;
      } else if ([subview.identifier isEqualToString:@"disclosureLabel"]) {
        handle.disclosureLabel = (NSTextField *)subview;
      }
    }
    handle.contentView = handle.normalContentView;
  } else if ([view isKindOfClass:NSBox.class]) {
    handle.contentView = ((NSBox *)view).contentView;
  } else if (catalogKind == HaskeLUIMacCatalogTabView) {
    for (NSView *subview in view.subviews) {
      if ([subview.identifier isEqualToString:@"content"]) {
        handle.contentView = subview;
      }
    }
  }
  switch (catalogKind) {
    case HaskeLUIMacCatalogRichText:
      focusView.accessibilityRole = NSAccessibilityStaticTextRole;
      break;
    case HaskeLUIMacCatalogImage:
    case HaskeLUIMacCatalogIcon:
      focusView.accessibilityRole = NSAccessibilityImageRole;
      break;
    case HaskeLUIMacCatalogRepeatButton:
    case HaskeLUIMacCatalogToggleButton:
    case HaskeLUIMacCatalogLink:
    case HaskeLUIMacCatalogSplitButton:
    case HaskeLUIMacCatalogToggleSplitButton:
      focusView.accessibilityRole = catalogKind == HaskeLUIMacCatalogLink
          ? NSAccessibilityLinkRole
          : NSAccessibilityButtonRole;
      break;
    case HaskeLUIMacCatalogCheckBox:
    case HaskeLUIMacCatalogSwitch:
      focusView.accessibilityRole = NSAccessibilityCheckBoxRole;
      break;
    case HaskeLUIMacCatalogRadioGroup:
      focusView.accessibilityRole = NSAccessibilityRadioGroupRole;
      break;
    case HaskeLUIMacCatalogSegmentedChoice:
    case HaskeLUIMacCatalogTabView:
      focusView.accessibilityRole = NSAccessibilityTabGroupRole;
      break;
    case HaskeLUIMacCatalogMenuButton:
    case HaskeLUIMacCatalogChoicePicker:
    case HaskeLUIMacCatalogContextMenu:
      focusView.accessibilityRole = NSAccessibilityPopUpButtonRole;
      break;
    case HaskeLUIMacCatalogTextArea:
    case HaskeLUIMacCatalogRichTextEditor:
      focusView.accessibilityRole = NSAccessibilityTextAreaRole;
      break;
    case HaskeLUIMacCatalogSecureField:
    case HaskeLUIMacCatalogSearchField:
      focusView.accessibilityRole = NSAccessibilityTextFieldRole;
      break;
    case HaskeLUIMacCatalogSuggestField:
    case HaskeLUIMacCatalogEditableComboBox:
      focusView.accessibilityRole = NSAccessibilityComboBoxRole;
      break;
    case HaskeLUIMacCatalogNumberField:
    case HaskeLUIMacCatalogStepper:
      focusView.accessibilityRole = NSAccessibilityIncrementorRole;
      break;
    case HaskeLUIMacCatalogSlider:
    case HaskeLUIMacCatalogRating:
      focusView.accessibilityRole = NSAccessibilitySliderRole;
      break;
    case HaskeLUIMacCatalogDatePicker:
    case HaskeLUIMacCatalogTimePicker:
    case HaskeLUIMacCatalogCalendarView:
      focusView.accessibilityRole = NSAccessibilityDateTimeAreaRole;
      break;
    case HaskeLUIMacCatalogColorPicker:
      focusView.accessibilityRole = NSAccessibilityColorWellRole;
      break;
    case HaskeLUIMacCatalogTreeView:
    case HaskeLUIMacCatalogNavigationSidebar:
      focusView.accessibilityRole = NSAccessibilityOutlineRole;
      break;
    case HaskeLUIMacCatalogTableView:
      focusView.accessibilityRole = NSAccessibilityTableRole;
      break;
    case HaskeLUIMacCatalogListView:
    case HaskeLUIMacCatalogCollectionView:
    case HaskeLUIMacCatalogItemRepeater:
      focusView.accessibilityRole = NSAccessibilityListRole;
      break;
    case HaskeLUIMacCatalogMenuBar:
      focusView.accessibilityRole = NSAccessibilityMenuBarRole;
      break;
    case HaskeLUIMacCatalogToolbar:
      focusView.accessibilityRole = NSAccessibilityToolbarRole;
      break;
    case HaskeLUIMacCatalogProgressBar:
    case HaskeLUIMacCatalogMeter:
      focusView.accessibilityRole = NSAccessibilityProgressIndicatorRole;
      break;
    case HaskeLUIMacCatalogActivityIndicator:
      focusView.accessibilityRole = NSAccessibilityBusyIndicatorRole;
      break;
    default:
      focusView.accessibilityRole = NSAccessibilityGroupRole;
      break;
  }
  return reference;
}

static NSView *HaskeLUIDescendant(NSView *root, NSString *identifier) {
  for (NSView *subview in root.subviews) {
    if ([subview.identifier isEqualToString:identifier]) {
      return subview;
    }
    NSView *nested = HaskeLUIDescendant(subview, identifier);
    if (nested != nil) {
      return nested;
    }
  }
  return nil;
}

static NSView *HaskeLUISubview(HaskeLUIMacControlHandle *handle, NSString *identifier) {
  return HaskeLUIDescendant(handle.view, identifier);
}

static void HaskeLUILayoutMessage(HaskeLUIMacControlHandle *handle) {
  if (handle.kind != HaskeLUIMacControlKindCatalog ||
      (handle.catalogKind != HaskeLUIMacCatalogTooltip &&
       handle.catalogKind != HaskeLUIMacCatalogBadge &&
       handle.catalogKind != HaskeLUIMacCatalogInlineNotice) ||
      ![handle.view isKindOfClass:NSBox.class]) {
    return;
  }
  NSBox *box = (NSBox *)handle.view;
  [box layoutSubtreeIfNeeded];
  NSRect bounds = box.contentView.bounds;
  NSTextField *title = (NSTextField *)HaskeLUISubview(handle, @"messageTitle");
  NSTextField *detail = (NSTextField *)HaskeLUISubview(handle, @"messageDetail");
  if (handle.catalogKind == HaskeLUIMacCatalogBadge) {
    title.frame = NSInsetRect(bounds, 8, 5);
  } else {
    CGFloat height = NSHeight(bounds);
    CGFloat width = MAX(0, NSWidth(bounds) - 24);
    title.frame = NSMakeRect(12, MAX(6, height - 26), width, 18);
    detail.frame = NSMakeRect(12, 6, width, MAX(0, height - 34));
  }
}

static void HaskeLUIMoveSubviews(NSView *source, NSView *destination) {
  for (NSView *child in source.subviews.copy) {
    [child removeFromSuperview];
    [destination addSubview:child];
  }
}

static NSSize HaskeLUIDesiredSizeForSubview(NSView *view) {
  __block NSSize result = view.frame.size;
  [HaskeLUIState.controls enumerateKeysAndObjectsUsingBlock:
      ^(NSNumber *key, HaskeLUIMacControlHandle *candidate, BOOL *stop) {
        (void)key;
        if (candidate.view == view) {
          result = candidate.desiredFrame.size;
          *stop = YES;
        }
      }];
  return result;
}

static void HaskeLUILayoutContainer(HaskeLUIMacControlHandle *handle) {
  if (handle.catalogKind != HaskeLUIMacCatalogContainer || handle.contentView == nil) {
    return;
  }
  NSView *host = handle.contentView;
  NSArray<NSView *> *children = host.subviews;
  NSInteger count = children.count;
  NSInteger state = handle.containerState;
  NSRect bounds = ((NSBox *)handle.view).contentView.bounds;

  if (state == 3000 || state == 6300) {
    CGFloat headerY = MAX(0, NSHeight(bounds) - 28);
    handle.disclosureLabel.frame = NSMakeRect(12, headerY + 2,
        MAX(0, NSWidth(bounds) - 24), 22);
    bounds.size.height = MAX(0, NSHeight(bounds) - 30);
    host.hidden = NO;
  } else if ((state >= 5000 && state < 5100) ||
             (state >= 6500 && state < 6600)) {
    CGFloat headerY = MAX(0, NSHeight(bounds) - 28);
    handle.disclosureButton.frame = NSMakeRect(0, headerY, 22, 24);
    handle.disclosureLabel.frame = NSMakeRect(26, headerY + 2,
        MAX(0, NSWidth(bounds) - 26), 22);
    bounds.size.height = MAX(0, NSHeight(bounds) - 30);
    host.hidden = state == 5000 || state == 6500;
  } else {
    host.hidden = NO;
  }

  if (state == 4000 || state == 6100) {
    CGFloat maximumY = NSHeight(bounds);
    CGFloat maximumX = NSWidth(bounds);
    for (NSView *child in children) {
      maximumY = MAX(maximumY, NSMaxY(child.frame));
      maximumX = MAX(maximumX, NSMaxX(child.frame));
    }
    host.frame = NSMakeRect(0, 0, maximumX, maximumY);
    if (state == 4000 && !handle.containerScrollInitialized && handle.containerScrollView != nil &&
        maximumY > NSHeight(handle.containerScrollView.contentView.bounds) + 0.5) {
      NSClipView *clip = handle.containerScrollView.contentView;
      [clip scrollToPoint:NSMakePoint(0, MAX(0, maximumY - NSHeight(clip.bounds)))];
      [handle.containerScrollView reflectScrolledClipView:clip];
      handle.containerScrollInitialized = YES;
    }
    return;
  }
  host.frame = bounds;
  if (count == 0) {
    return;
  }

  if (state >= 1000 && state < 2000) {
    NSInteger encoded = state - 1000;
    NSInteger columns = MAX(1, encoded / 100);
    CGFloat spacing = (CGFloat)(encoded % 100);
    NSInteger rows = (count + columns - 1) / columns;
    CGFloat width = MAX(0, (NSWidth(bounds) - spacing * (columns - 1)) / columns);
    CGFloat height = MAX(0, (NSHeight(bounds) - spacing * (rows - 1)) / rows);
    [children enumerateObjectsUsingBlock:^(NSView *child, NSUInteger index, BOOL *stop) {
      (void)stop;
      NSInteger column = (NSInteger)index % columns;
      NSInteger row = (NSInteger)index / columns;
      NSSize desired = HaskeLUIDesiredSizeForSubview(child);
      CGFloat childWidth = desired.width > 0 ? MIN(width, desired.width) : width;
      CGFloat childHeight = desired.height > 0 ? MIN(height, desired.height) : height;
      CGFloat cellX = column * (width + spacing);
      CGFloat cellY = NSHeight(bounds) - (row + 1) * height - row * spacing;
      child.frame = NSMakeRect(cellX + (width - childWidth) / 2,
                               cellY + (height - childHeight) / 2,
                               childWidth, childHeight);
    }];
  } else if (state >= 0 && state < 200) {
    BOOL vertical = state >= 100;
    CGFloat spacing = (CGFloat)(state % 100);
    if (vertical) {
      CGFloat y = NSHeight(bounds);
      for (NSView *child in children) {
        NSSize desired = HaskeLUIDesiredSizeForSubview(child);
        CGFloat height = desired.height > 0 ? MIN(y, desired.height) : 0;
        CGFloat width = desired.width > 0 ? MIN(NSWidth(bounds), desired.width) : NSWidth(bounds);
        y -= height;
        child.frame = NSMakeRect(0, MAX(0, y), width, height);
        y -= spacing;
      }
    } else {
      CGFloat x = 0;
      for (NSView *child in children) {
        NSSize desired = HaskeLUIDesiredSizeForSubview(child);
        CGFloat width = desired.width > 0 ? MIN(MAX(0, NSWidth(bounds) - x), desired.width) : 0;
        CGFloat height = desired.height > 0 ? MIN(NSHeight(bounds), desired.height) : NSHeight(bounds);
        child.frame = NSMakeRect(x, (NSHeight(bounds) - height) / 2, width, height);
        x += width + spacing;
      }
    }
  }
}

static void HaskeLUIConfigureContainer(HaskeLUIMacControlHandle *handle, int32_t state) {
  NSBox *box = (NSBox *)handle.view;
  BOOL portable = state >= 6000;
  BOOL wantsScroll = state == 4000 || state == 6100;
  if (wantsScroll && handle.containerScrollView == nil) {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:handle.normalContentView.frame];
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    HaskeLUIContainerHostView *document =
        [[HaskeLUIContainerHostView alloc] initWithFrame:handle.normalContentView.bounds];
    document.usesTopLeftCoordinates = portable;
    scroll.documentView = document;
    [box.contentView addSubview:scroll positioned:NSWindowBelow relativeTo:handle.disclosureButton];
    HaskeLUIMoveSubviews(handle.normalContentView, document);
    handle.normalContentView.hidden = YES;
    handle.containerScrollView = scroll;
    handle.containerScrollDocument = document;
    handle.containerScrollInitialized = NO;
    handle.contentView = document;
  } else if (!wantsScroll && handle.containerScrollView != nil) {
    HaskeLUIMoveSubviews(handle.containerScrollDocument, handle.normalContentView);
    [handle.containerScrollView removeFromSuperview];
    handle.containerScrollView = nil;
    handle.containerScrollDocument = nil;
    handle.containerScrollInitialized = NO;
    handle.normalContentView.hidden = NO;
    handle.contentView = handle.normalContentView;
  }

  handle.containerState = state;
  if ([handle.normalContentView isKindOfClass:HaskeLUIContainerHostView.class]) {
    ((HaskeLUIContainerHostView *)handle.normalContentView).usesTopLeftCoordinates = portable;
  }
  if ([handle.contentView isKindOfClass:HaskeLUIContainerHostView.class]) {
    ((HaskeLUIContainerHostView *)handle.contentView).usesTopLeftCoordinates = portable;
  }
  BOOL disclosure = (state >= 5000 && state < 5100) ||
      (state >= 6500 && state < 6600);
  BOOL group = state == 3000 || state == 6300;
  handle.disclosureButton.hidden = !disclosure;
  handle.disclosureLabel.hidden = !(disclosure || group);
  handle.disclosureButton.state =
      (state == 5001 || state == 6501) ? NSControlStateValueOn : NSControlStateValueOff;
  box.transparent = !group;
  if (disclosure) {
    box.title = @"";
    handle.disclosureButton.title = @"";
    handle.disclosureLabel.stringValue = handle.primaryText ?: @"";
  } else if (group) {
    box.title = @"";
    handle.disclosureLabel.stringValue = handle.primaryText ?: @"";
  } else {
    box.title = @"";
  }
  HaskeLUILayoutContainer(handle);
}

static NSImage *HaskeLUIImageSource(NSString *source) {
  NSImage *image = nil;
  if ([source hasPrefix:@"system:"]) {
    NSString *name = [source substringFromIndex:7];
    if (@available(macOS 11.0, *)) {
      image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    }
  } else if ([source hasPrefix:@"file:"]) {
    image = [[NSImage alloc] initWithContentsOfFile:[source substringFromIndex:5]];
  } else if ([source hasPrefix:@"named:"]) {
    image = [NSImage imageNamed:[source substringFromIndex:6]];
  }
  return image;
}

static void HaskeLUISetImageSource(NSImageView *imageView, NSString *source) {
  imageView.image = HaskeLUIImageSource(source);
}

void haskelui_macos_catalog_control_set_primary_text(
    HaskeLUIMacControlRef reference,
    const char *utf8Text) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  NSString *text = HaskeLUIString(utf8Text);
  handle.primaryText = text;
  if (text.length > 0) {
    handle.focusView.accessibilityLabel = text;
  }
  switch (handle.catalogKind) {
    case HaskeLUIMacCatalogRichText:
      if (![((NSTextView *)handle.focusView).string isEqualToString:text]) {
        ((NSTextView *)handle.focusView).string = text;
      }
      break;
    case HaskeLUIMacCatalogImage:
    case HaskeLUIMacCatalogIcon:
      HaskeLUISetImageSource((NSImageView *)handle.view, text);
      break;
    case HaskeLUIMacCatalogRepeatButton:
    case HaskeLUIMacCatalogToggleButton:
    case HaskeLUIMacCatalogCheckBox:
    case HaskeLUIMacCatalogLink:
      ((NSButton *)handle.view).title = text;
      break;
    case HaskeLUIMacCatalogSwitch:
      ((NSTextField *)HaskeLUISubview(handle, @"switchLabel")).stringValue = text;
      break;
    case HaskeLUIMacCatalogSplitButton:
    case HaskeLUIMacCatalogToggleSplitButton:
      ((NSButton *)HaskeLUISubview(handle, @"primary")).title = text;
      break;
    case HaskeLUIMacCatalogTextArea:
    case HaskeLUIMacCatalogRichTextEditor:
      if (![((NSTextView *)handle.focusView).string isEqualToString:text]) {
        ((NSTextView *)handle.focusView).string = text;
      }
      break;
    case HaskeLUIMacCatalogSecureField:
    case HaskeLUIMacCatalogSearchField:
    case HaskeLUIMacCatalogSuggestField:
    case HaskeLUIMacCatalogEditableComboBox:
      if (![((NSTextField *)handle.focusView).stringValue isEqualToString:text]) {
        ((NSTextField *)handle.focusView).stringValue = text;
      }
      break;
    case HaskeLUIMacCatalogContextMenu:
      ((NSPopUpButton *)handle.view).title = text;
      break;
    case HaskeLUIMacCatalogTooltip:
    case HaskeLUIMacCatalogBadge:
    case HaskeLUIMacCatalogInlineNotice: {
      NSTextField *label = (NSTextField *)HaskeLUISubview(handle, @"messageTitle");
      label.stringValue = text;
      HaskeLUILayoutMessage(handle);
      break;
    }
    case HaskeLUIMacCatalogDialog:
    case HaskeLUIMacCatalogAlert:
    case HaskeLUIMacCatalogPopover:
    case HaskeLUIMacCatalogContainer:
      if ([handle.view isKindOfClass:NSBox.class]) {
        if (handle.containerState == 3000 ||
            (handle.containerState >= 5000 && handle.containerState < 5100)) {
          handle.disclosureLabel.stringValue = text;
        } else {
          ((NSBox *)handle.view).title = text;
        }
      }
      break;
    default:
      break;
  }
}

void haskelui_macos_catalog_control_set_secondary_text(
    HaskeLUIMacControlRef reference,
    const char *utf8Text) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  NSString *text = HaskeLUIString(utf8Text);
  handle.secondaryText = text;
  if ([handle.focusView isKindOfClass:NSTextField.class] &&
      (handle.catalogKind == HaskeLUIMacCatalogSecureField ||
       handle.catalogKind == HaskeLUIMacCatalogSearchField ||
       handle.catalogKind == HaskeLUIMacCatalogSuggestField ||
       handle.catalogKind == HaskeLUIMacCatalogEditableComboBox)) {
    ((NSTextField *)handle.focusView).placeholderString = text;
  } else if (handle.catalogKind == HaskeLUIMacCatalogRepeatButton ||
             handle.catalogKind == HaskeLUIMacCatalogToggleButton ||
             handle.catalogKind == HaskeLUIMacCatalogLink) {
    ((NSButton *)handle.view).image = HaskeLUIImageSource(text);
    ((NSButton *)handle.view).imagePosition = text.length == 0
        ? NSNoImage
        : NSImageLeading;
  } else if (handle.catalogKind == HaskeLUIMacCatalogSplitButton ||
             handle.catalogKind == HaskeLUIMacCatalogToggleSplitButton) {
    NSButton *button = (NSButton *)HaskeLUISubview(handle, @"primary");
    button.image = HaskeLUIImageSource(text);
    button.imagePosition = text.length == 0 ? NSNoImage : NSImageLeading;
  } else if (handle.catalogKind == HaskeLUIMacCatalogTooltip ||
             handle.catalogKind == HaskeLUIMacCatalogBadge ||
             handle.catalogKind == HaskeLUIMacCatalogInlineNotice) {
    handle.view.toolTip = text;
    ((NSTextField *)HaskeLUISubview(handle, @"messageDetail")).stringValue = text;
    HaskeLUILayoutMessage(handle);
  } else if (handle.catalogKind == HaskeLUIMacCatalogImage ||
             handle.catalogKind == HaskeLUIMacCatalogIcon) {
    handle.focusView.accessibilityLabel = text;
  }
}

void haskelui_macos_catalog_control_set_state(
    HaskeLUIMacControlRef reference,
    int32_t state) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  NSControlStateValue nativeState = state < 0
      ? NSControlStateValueMixed
      : (state == 0 ? NSControlStateValueOff : NSControlStateValueOn);
  if ([handle.view isKindOfClass:NSButton.class]) {
    ((NSButton *)handle.view).state = nativeState;
  } else if ([handle.view isKindOfClass:NSSwitch.class]) {
    ((NSSwitch *)handle.view).state = nativeState;
  } else if (handle.catalogKind == HaskeLUIMacCatalogSwitch) {
    ((NSSwitch *)handle.focusView).state = nativeState;
  } else if (handle.catalogKind == HaskeLUIMacCatalogToggleSplitButton) {
    ((NSButton *)HaskeLUISubview(handle, @"primary")).state = nativeState;
  } else if (handle.catalogKind == HaskeLUIMacCatalogActivityIndicator) {
    NSProgressIndicator *indicator = (NSProgressIndicator *)handle.view;
    if (state != 0) {
      [indicator startAnimation:nil];
    } else {
      [indicator stopAnimation:nil];
    }
  } else if (handle.collectionAdapter != nil ||
             handle.gridAdapter != nil ||
             handle.outlineAdapter != nil) {
    handle.collectionSelectionMode = MAX(0, MIN(2, state));
  } else if (handle.catalogKind == HaskeLUIMacCatalogContainer) {
    HaskeLUIConfigureContainer(handle, state);
  }
}

void haskelui_macos_catalog_control_set_row_sizing(
    HaskeLUIMacControlRef reference,
    int32_t sizing,
    double fixedHeight) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  NSTableView *table = handle.collectionAdapter != nil
      ? handle.collectionAdapter.table
      : handle.outlineAdapter.outline;
  if (table == nil) {
    return;
  }

  table.usesAutomaticRowHeights = NO;
  if (handle.collectionAdapter != nil) {
    handle.collectionAdapter.contentSizedRows = NO;
  }
  if (handle.outlineAdapter != nil) {
    handle.outlineAdapter.contentSizedRows = NO;
  }

  switch (sizing) {
    case 1:
      table.rowSizeStyle = NSTableViewRowSizeStyleSmall;
      break;
    case 2:
      table.rowSizeStyle = NSTableViewRowSizeStyleMedium;
      break;
    case 3:
      table.rowSizeStyle = NSTableViewRowSizeStyleLarge;
      break;
    case 4:
      if (isfinite(fixedHeight) && fixedHeight > 0) {
        table.rowSizeStyle = NSTableViewRowSizeStyleCustom;
        table.rowHeight = fixedHeight;
      } else {
        table.rowSizeStyle = NSTableViewRowSizeStyleDefault;
      }
      break;
    case 5:
      table.rowSizeStyle = NSTableViewRowSizeStyleCustom;
      table.usesAutomaticRowHeights = YES;
      if (handle.collectionAdapter != nil) {
        handle.collectionAdapter.contentSizedRows = YES;
      }
      if (handle.outlineAdapter != nil) {
        handle.outlineAdapter.contentSizedRows = YES;
      }
      break;
    default:
      table.rowSizeStyle = NSTableViewRowSizeStyleDefault;
      break;
  }
}

static void HaskeLUIConfigureNumericControl(
    NSControl *control,
    double value,
    double minimum,
    double maximum,
    double step) {
  control.doubleValue = value;
  if ([control isKindOfClass:NSSlider.class]) {
    NSSlider *slider = (NSSlider *)control;
    slider.minValue = minimum;
    slider.maxValue = maximum;
    slider.numberOfTickMarks = step > 0 && maximum > minimum
        ? MIN(20, MAX(0, (NSInteger)llround((maximum - minimum) / step) + 1))
        : 0;
    slider.allowsTickMarkValuesOnly = NO;
  } else if ([control isKindOfClass:NSStepper.class]) {
    NSStepper *stepper = (NSStepper *)control;
    stepper.minValue = minimum;
    stepper.maxValue = maximum;
    stepper.increment = step;
  } else if ([control isKindOfClass:NSLevelIndicator.class]) {
    NSLevelIndicator *level = (NSLevelIndicator *)control;
    level.minValue = minimum;
    level.maxValue = maximum;
  }
}

void haskelui_macos_catalog_control_set_numeric(
    HaskeLUIMacControlRef reference,
    double value,
    double minimum,
    double maximum,
    double step) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  if (handle.catalogKind == HaskeLUIMacCatalogNumberField) {
    NSTextField *field = (NSTextField *)HaskeLUISubview(handle, @"numberField");
    NSStepper *stepper = (NSStepper *)HaskeLUISubview(handle, @"numberStepper");
    field.doubleValue = value;
    HaskeLUIConfigureNumericControl(stepper, value, minimum, maximum, step);
  } else if ([handle.view isKindOfClass:NSControl.class]) {
    HaskeLUIConfigureNumericControl((NSControl *)handle.view, value, minimum, maximum, step);
  } else if ([handle.view isKindOfClass:NSProgressIndicator.class]) {
    NSProgressIndicator *progress = (NSProgressIndicator *)handle.view;
    progress.minValue = minimum;
    progress.maxValue = maximum;
    progress.doubleValue = value;
  }
}

void haskelui_macos_catalog_control_set_color(
    HaskeLUIMacControlRef reference,
    double red,
    double green,
    double blue,
    double alpha) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  if ([handle.view isKindOfClass:NSColorWell.class]) {
    ((NSColorWell *)handle.view).color = HaskeLUIColor(red, green, blue, alpha);
  }
}

void haskelui_macos_catalog_control_set_date_time(
    HaskeLUIMacControlRef reference,
    int32_t year,
    int32_t month,
    int32_t day,
    int32_t hour,
    int32_t minute,
    int32_t second) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  if (![handle.view isKindOfClass:NSDatePicker.class]) {
    return;
  }
  NSDateComponents *parts = [[NSDateComponents alloc] init];
  parts.year = year;
  parts.month = month;
  parts.day = day;
  parts.hour = hour;
  parts.minute = minute;
  parts.second = second;
  NSDate *date = [[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian] dateFromComponents:parts];
  if (date != nil) {
    ((NSDatePicker *)handle.view).dateValue = date;
  }
}

void haskelui_macos_catalog_control_set_command(
    HaskeLUIMacControlRef reference,
    uint64_t commandIdentity) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  handle.commandIdentity = commandIdentity;
  if (handle.target != nil) {
    if (handle.catalogKind == HaskeLUIMacCatalogToggleSplitButton) {
      handle.target.secondaryIdentity = commandIdentity;
      handle.target.secondaryEventKind = HaskeLUIMacEventCommand;
    } else {
      handle.target.identity = commandIdentity;
      handle.target.eventKind = HaskeLUIMacEventCommand;
    }
  }
}

static void HaskeLUIReleaseItemTargets(HaskeLUIMacControlHandle *handle) {
  for (HaskeLUIMacActionTarget *target in handle.itemTargets) {
    (void)target;
    HaskeLUILiveActionTargets -= 1;
  }
  [handle.itemTargets removeAllObjects];
}

void haskelui_macos_catalog_control_begin_items(HaskeLUIMacControlRef reference) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  HaskeLUIReleaseItemTargets(handle);
  [handle.items removeAllObjects];
  [handle.slots removeAllObjects];
  if (handle.catalogKind == HaskeLUIMacCatalogSplitButton ||
      handle.catalogKind == HaskeLUIMacCatalogToggleSplitButton) {
    [(NSPopUpButton *)HaskeLUISubview(handle, @"menu") removeAllItems];
  } else if ([handle.view isKindOfClass:NSPopUpButton.class]) {
    [(NSPopUpButton *)handle.view removeAllItems];
  } else if ([handle.view isKindOfClass:NSSegmentedControl.class]) {
    ((NSSegmentedControl *)handle.view).segmentCount = 0;
  } else if ([handle.view isKindOfClass:NSStackView.class]) {
    NSStackView *stack = (NSStackView *)handle.view;
    for (NSView *child in stack.arrangedSubviews.copy) {
      [stack removeArrangedSubview:child];
      [child removeFromSuperview];
    }
  } else if (handle.catalogKind == HaskeLUIMacCatalogTabView) {
    NSSegmentedControl *segments = (NSSegmentedControl *)HaskeLUISubview(handle, @"tabs");
    segments.segmentCount = 0;
    for (NSView *child in handle.contentView.subviews.copy) {
      [child removeFromSuperview];
    }
  } else if ([handle.focusView isKindOfClass:NSComboBox.class]) {
    [(NSComboBox *)handle.focusView removeAllItems];
  }
  if (handle.collectionAdapter != nil) {
    [handle.collectionAdapter.items removeAllObjects];
  }
  if (handle.gridAdapter != nil) {
    [handle.gridAdapter.items removeAllObjects];
  }
  if (handle.outlineAdapter != nil) {
    [handle.outlineAdapter.items removeAllObjects];
  }
}

void haskelui_macos_catalog_control_add_item(
    HaskeLUIMacControlRef reference,
    uint64_t itemIdentity,
    const char *utf8Label,
    const char *utf8Detail,
    const char *utf8Icon,
    int32_t depth,
    int32_t flags,
    uint64_t commandIdentity) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  NSString *label = HaskeLUIString(utf8Label);
  NSString *detail = HaskeLUIString(utf8Detail);
  NSString *icon = HaskeLUIString(utf8Icon);
  BOOL enabled = (flags & 1) != 0;
  BOOL selected = (flags & 2) != 0;
  BOOL expanded = (flags & 4) != 0;
  BOOL separator = (flags & 8) != 0;
  BOOL expandable = (flags & 16) != 0;
  NSDictionary *item = @{
    @"identity": @(itemIdentity),
    @"label": label,
    @"detail": detail,
    @"icon": icon,
    @"depth": @(MAX(0, depth)),
    @"enabled": @(enabled),
    @"selected": @(selected),
    @"expanded": @(expanded),
    @"expandable": @(expandable),
    @"command": @(commandIdentity)
  };
  [handle.items addObject:item];

  if (handle.catalogKind == HaskeLUIMacCatalogRadioGroup) {
    HaskeLUIMacActionTarget *target = HaskeLUINewTarget(handle.identity, HaskeLUIMacEventChoiceChanged);
    target.fixedPayload = [@(itemIdentity) stringValue];
    [handle.itemTargets addObject:target];
    NSButton *button = [NSButton radioButtonWithTitle:label target:target action:@selector(performAction:)];
    button.tag = (NSInteger)itemIdentity;
    button.enabled = enabled;
    button.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
    [(NSStackView *)handle.view addArrangedSubview:button];
  } else if (handle.catalogKind == HaskeLUIMacCatalogMenuBar ||
             handle.catalogKind == HaskeLUIMacCatalogToolbar) {
    if (separator) {
      NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 1, 20)];
      line.boxType = NSBoxSeparator;
      [(NSStackView *)handle.view addArrangedSubview:line];
    } else {
      if (label.length == 0 && commandIdentity != 0) {
        NSMenuItem *commandItem = HaskeLUIState.commandItems[@(commandIdentity)];
        label = commandItem.title ?: @"";
      }
      HaskeLUIMacActionTarget *target = HaskeLUINewTarget(commandIdentity, HaskeLUIMacEventCommand);
      [handle.itemTargets addObject:target];
      NSButton *button = [NSButton buttonWithTitle:label target:target action:@selector(performAction:)];
      button.enabled = enabled;
      button.bezelStyle = handle.catalogKind == HaskeLUIMacCatalogToolbar
          ? NSBezelStyleTexturedRounded
          : NSBezelStyleInline;
      [(NSStackView *)handle.view addArrangedSubview:button];
    }
  } else if ([handle.view isKindOfClass:NSSegmentedControl.class]) {
    NSSegmentedControl *segments = (NSSegmentedControl *)handle.view;
    NSInteger index = segments.segmentCount;
    segments.segmentCount = index + 1;
    [segments setLabel:label forSegment:index];
    [segments setTag:(NSInteger)itemIdentity forSegment:index];
    [segments setEnabled:enabled forSegment:index];
    [segments setSelected:selected forSegment:index];
    NSImage *image = HaskeLUIImageSource(icon);
    if (image != nil) {
      [segments setImage:image forSegment:index];
    }
  } else if ([handle.view isKindOfClass:NSPopUpButton.class]) {
    NSPopUpButton *popup = (NSPopUpButton *)handle.view;
    if (separator) {
      [popup.menu addItem:NSMenuItem.separatorItem];
    } else {
      [popup addItemWithTitle:label];
      popup.lastItem.representedObject = @(itemIdentity);
      popup.lastItem.enabled = enabled;
      popup.lastItem.image = HaskeLUIImageSource(icon);
      if (commandIdentity != 0) {
        HaskeLUIMacActionTarget *target = HaskeLUINewTarget(commandIdentity, HaskeLUIMacEventCommand);
        [handle.itemTargets addObject:target];
        popup.lastItem.target = target;
        popup.lastItem.action = @selector(performAction:);
      }
      if (selected) {
        [popup selectItem:popup.lastItem];
      }
    }
  } else if (handle.catalogKind == HaskeLUIMacCatalogSplitButton ||
             handle.catalogKind == HaskeLUIMacCatalogToggleSplitButton) {
    NSPopUpButton *popup = (NSPopUpButton *)HaskeLUISubview(handle, @"menu");
    if (separator) {
      [popup.menu addItem:NSMenuItem.separatorItem];
    } else {
      HaskeLUIMacActionTarget *target = HaskeLUINewTarget(commandIdentity, HaskeLUIMacEventCommand);
      [handle.itemTargets addObject:target];
      NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:label
                                                      action:@selector(performAction:)
                                               keyEquivalent:@""];
      menuItem.target = target;
      menuItem.enabled = enabled;
      [popup.menu addItem:menuItem];
    }
  } else if (handle.catalogKind == HaskeLUIMacCatalogTabView) {
    NSSegmentedControl *segments = (NSSegmentedControl *)HaskeLUISubview(handle, @"tabs");
    NSInteger index = segments.segmentCount;
    segments.segmentCount = index + 1;
    [segments setLabel:label forSegment:index];
    [segments setTag:(NSInteger)itemIdentity forSegment:index];
    [segments setSelected:selected forSegment:index];
    NSView *slot = [[NSView alloc] initWithFrame:handle.contentView.bounds];
    slot.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    slot.hidden = !selected;
    [handle.contentView addSubview:slot];
    handle.slots[@(itemIdentity)] = slot;
  } else if ([handle.focusView isKindOfClass:NSComboBox.class]) {
    [(NSComboBox *)handle.focusView addItemWithObjectValue:label];
  }
  if (handle.collectionAdapter != nil) {
    [handle.collectionAdapter.items addObject:item];
  }
  if (handle.gridAdapter != nil) {
    [handle.gridAdapter.items addObject:item];
  }
  if (handle.outlineAdapter != nil) {
    [handle.outlineAdapter.items addObject:item];
  }
}

void haskelui_macos_catalog_control_end_items(HaskeLUIMacControlRef reference) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  if (handle.collectionAdapter != nil) {
    NSTableView *table = handle.collectionAdapter.table;
    handle.collectionAdapter.suppressSelectionEvent = YES;
    table.allowsEmptySelection = YES;
    table.allowsMultipleSelection = handle.collectionSelectionMode == 2;
    table.allowsColumnSelection = NO;
    table.allowsTypeSelect = YES;
    table.enabled = handle.collectionSelectionMode != 0;
    [table reloadData];
    NSMutableIndexSet *selected = [[NSMutableIndexSet alloc] init];
    [handle.collectionAdapter.items enumerateObjectsUsingBlock:
        ^(NSDictionary *item, NSUInteger index, BOOL *stop) {
          (void)stop;
          if ([item[@"selected"] boolValue]) {
            [selected addIndex:index];
          }
        }];
    [table selectRowIndexes:selected byExtendingSelection:NO];
    handle.collectionAdapter.suppressSelectionEvent = NO;
  }
  if (handle.gridAdapter != nil) {
    NSCollectionView *collection = handle.gridAdapter.collection;
    handle.gridAdapter.suppressSelectionEvent = YES;
    collection.selectable = handle.collectionSelectionMode != 0;
    collection.allowsMultipleSelection = handle.collectionSelectionMode == 2;
    [collection reloadData];
    NSMutableSet<NSIndexPath *> *selected = [[NSMutableSet alloc] init];
    [handle.gridAdapter.items enumerateObjectsUsingBlock:
        ^(NSDictionary *item, NSUInteger index, BOOL *stop) {
          (void)stop;
          if ([item[@"selected"] boolValue]) {
            [selected addObject:[NSIndexPath indexPathForItem:(NSInteger)index inSection:0]];
          }
        }];
    collection.selectionIndexPaths = selected;
    handle.gridAdapter.suppressSelectionEvent = NO;
  }
  if (handle.outlineAdapter != nil) {
    handle.outlineAdapter.outline.allowsMultipleSelection = handle.collectionSelectionMode == 2;
    handle.outlineAdapter.outline.enabled = handle.collectionSelectionMode != 0;
    [handle.outlineAdapter reload];
  }
  if (handle.catalogKind == HaskeLUIMacCatalogTabView) {
    NSSegmentedControl *segments = (NSSegmentedControl *)HaskeLUISubview(handle, @"tabs");
    if (segments.selectedSegment < 0 && segments.segmentCount > 0) {
      segments.selectedSegment = 0;
      NSNumber *key = @([segments tagForSegment:0]);
      handle.slots[key].hidden = NO;
    }
  }
}

void haskelui_macos_catalog_control_set_tooltip(
    HaskeLUIMacControlRef reference,
    const char *utf8Tooltip) {
  HaskeLUIAssertMainThread();
  HaskeLUIControl(reference).view.toolTip = HaskeLUIString(utf8Tooltip);
}

void haskelui_macos_catalog_control_set_presentation(
    HaskeLUIMacControlRef reference,
    int32_t visible,
    uint64_t anchorIdentity) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  BOOL wantsVisible = visible != 0;
  if (wantsVisible == handle.presentationVisible) {
    return;
  }
  handle.presentationVisible = wantsVisible;
  if (!wantsVisible) {
    if (handle.popover != nil) {
      [handle.popover close];
      handle.popover = nil;
    }
    if (handle.presentationWindow != nil) {
      [handle.presentationWindow.sheetParent endSheet:handle.presentationWindow];
      handle.presentationWindow = nil;
    }
    return;
  }

  HaskeLUIMacWindowHandle *owner = nil;
  for (HaskeLUIMacWindowHandle *candidate in HaskeLUIState.windows.allValues) {
    if (handle.view.window == candidate.window) {
      owner = candidate;
      break;
    }
  }
  if (handle.catalogKind == HaskeLUIMacCatalogPopover) {
    HaskeLUIMacControlHandle *anchor = HaskeLUIState.controls[@(anchorIdentity)];
    if (anchor == nil) {
      handle.presentationVisible = NO;
      return;
    }
    NSViewController *controller = [[NSViewController alloc] init];
    NSTextField *title = [NSTextField labelWithString:handle.primaryText ?: @""];
    title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    title.frame = NSMakeRect(16, 86, 260, 20);
    NSTextField *message = [NSTextField wrappingLabelWithString:handle.secondaryText ?: @""];
    message.frame = NSMakeRect(16, 16, 260, 62);
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 292, 120)];
    [content addSubview:title];
    [content addSubview:message];
    controller.view = content;
    NSPopover *popover = [[NSPopover alloc] init];
    popover.contentViewController = controller;
    popover.behavior = HaskeLUIControlGalleryTestActive
        ? NSPopoverBehaviorApplicationDefined
        : NSPopoverBehaviorTransient;
    popover.delegate = handle;
    [popover showRelativeToRect:anchor.view.bounds ofView:anchor.view preferredEdge:NSRectEdgeMaxY];
    handle.popover = popover;
  } else if (owner != nil) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = handle.primaryText ?: @"";
    alert.informativeText = handle.secondaryText ?: @"";
    [alert addButtonWithTitle:@"OK"];
    if (handle.catalogKind == HaskeLUIMacCatalogDialog) {
      [alert addButtonWithTitle:@"Cancel"];
    }
    [alert beginSheetModalForWindow:owner.window completionHandler:^(NSModalResponse response) {
      BOOL wasPresented = handle.presentationVisible;
      handle.presentationVisible = NO;
      handle.presentationWindow = nil;
      NSString *result = response == NSAlertFirstButtonReturn ? @"accepted" : @"cancelled";
      if (wasPresented) {
        HaskeLUIEmit(HaskeLUIMacEventPresentationClosed, handle.identity, result);
      }
    }];
    handle.presentationWindow = alert.window;
  }
}

void haskelui_macos_control_set_text(HaskeLUIMacControlRef reference, const char *utf8_text) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  NSString *value = HaskeLUIString(utf8_text);
  switch (handle.kind) {
    case HaskeLUIMacControlKindButton:
      ((NSButton *)handle.view).title = value;
      break;
    case HaskeLUIMacControlKindLabel:
    case HaskeLUIMacControlKindTextField: {
      NSTextField *field = (NSTextField *)handle.view;
      if (![field.stringValue isEqualToString:value]) {
        field.stringValue = value;
      }
      break;
    }
    case HaskeLUIMacControlKindTextEditor: {
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
    case HaskeLUIMacControlKindDrawing:
      break;
    case HaskeLUIMacControlKindCatalog:
      haskelui_macos_catalog_control_set_primary_text(reference, utf8_text);
      break;
  }
}

static CGFloat HaskeLUIClampUnit(double value) {
  return (CGFloat)MIN(1.0, MAX(0.0, value));
}

static NSColor *HaskeLUIColor(double red, double green, double blue, double alpha) {
  return [NSColor colorWithSRGBRed:HaskeLUIClampUnit(red)
                             green:HaskeLUIClampUnit(green)
                              blue:HaskeLUIClampUnit(blue)
                             alpha:HaskeLUIClampUnit(alpha)];
}

static NSFontWeight HaskeLUIFontWeight(int32_t weight) {
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

static NSFont *HaskeLUIFontForStyle(NSFont *existingFont, const HaskeLUIMacTextStyle *style) {
  uint32_t fontFields =
      HaskeLUIMacTextStyleFontFamily |
      HaskeLUIMacTextStyleFontSize |
      HaskeLUIMacTextStyleFontWeight |
      HaskeLUIMacTextStyleFontSlant;
  if ((style->fields & fontFields) == 0) {
    return nil;
  }

  NSFont *existing = existingFont ?: [NSFont systemFontOfSize:13.0];
  CGFloat size =
      (style->fields & HaskeLUIMacTextStyleFontSize) != 0
          ? (CGFloat)MAX(1.0, style->font_size)
          : existing.pointSize;
  NSFontWeight weight =
      (style->fields & HaskeLUIMacTextStyleFontWeight) != 0
          ? HaskeLUIFontWeight(style->font_weight)
          : NSFontWeightRegular;
  NSFont *font = existing;

  if ((style->fields & HaskeLUIMacTextStyleFontFamily) != 0) {
    switch (style->font_family_kind) {
      case 1:
        font = [NSFont systemFontOfSize:size weight:weight];
        break;
      case 2:
        font = [NSFont monospacedSystemFontOfSize:size weight:weight];
        break;
      case 3: {
        NSString *name = HaskeLUIString(style->utf8_font_family);
        font = [NSFont fontWithName:name size:size] ?: existing;
        break;
      }
      default:
        break;
    }
  } else if ((style->fields & HaskeLUIMacTextStyleFontSize) != 0) {
    font = [NSFont fontWithDescriptor:existing.fontDescriptor size:size] ?: existing;
  }

  if ((style->fields & HaskeLUIMacTextStyleFontWeight) != 0 &&
      (style->fields & HaskeLUIMacTextStyleFontFamily) == 0) {
    NSFontDescriptor *weightedDescriptor =
        [font.fontDescriptor fontDescriptorByAddingAttributes:@{
          NSFontTraitsAttribute: @{NSFontWeightTrait: @(weight)}
        }];
    font = [NSFont fontWithDescriptor:weightedDescriptor size:size] ?: font;
  }

  if ((style->fields & HaskeLUIMacTextStyleFontSlant) != 0) {
    NSFontTraitMask trait = style->font_slant == 1 ? 0 : NSItalicFontMask;
    font = trait == 0
        ? [NSFontManager.sharedFontManager convertFont:font toNotHaveTrait:NSItalicFontMask]
        : [NSFontManager.sharedFontManager convertFont:font toHaveTrait:trait];
  }
  return font;
}

static NSUnderlineStyle HaskeLUIUnderlineStyle(int32_t style) {
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

static BOOL HaskeLUIIsTextEditorHandle(HaskeLUIMacControlHandle *handle) {
  return handle.kind == HaskeLUIMacControlKindTextEditor ||
      (handle.kind == HaskeLUIMacControlKindCatalog &&
       (handle.catalogKind == HaskeLUIMacCatalogRichTextEditor ||
        handle.catalogKind == HaskeLUIMacCatalogRichText));
}

void haskelui_macos_text_editor_begin_presentation(HaskeLUIMacControlRef reference) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  if (!HaskeLUIIsTextEditorHandle(handle)) {
    return;
  }
  NSTextView *editor = (NSTextView *)handle.focusView;
  BOOL staticRichText = handle.kind == HaskeLUIMacControlKindCatalog &&
      handle.catalogKind == HaskeLUIMacCatalogRichText;
  if (staticRichText && editor.string.length > 0) {
    [editor.textStorage setAttributes:@{}
                                range:NSMakeRange(0, editor.string.length)];
  }
  if (editor.string.length > 0) {
    [editor.layoutManager
        setTemporaryAttributes:@{}
              forCharacterRange:NSMakeRange(0, editor.string.length)];
  }
}

void haskelui_macos_text_editor_set_base_style(
    HaskeLUIMacControlRef reference,
    const HaskeLUIMacTextStyle *style) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  if (!HaskeLUIIsTextEditorHandle(handle) || style == NULL) {
    return;
  }
  NSTextView *editor = (NSTextView *)handle.focusView;
  BOOL staticRichText = handle.kind == HaskeLUIMacControlKindCatalog &&
      handle.catalogKind == HaskeLUIMacCatalogRichText;
  editor.font = staticRichText
      ? [NSFont systemFontOfSize:13 weight:NSFontWeightRegular]
      : [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
  editor.textColor = NSColor.textColor;
  editor.drawsBackground = !staticRichText;
  editor.backgroundColor = staticRichText ? NSColor.clearColor : NSColor.textBackgroundColor;
  if ((style->fields & HaskeLUIMacTextStyleForeground) != 0) {
    editor.textColor =
        HaskeLUIColor(
            style->foreground_red,
            style->foreground_green,
            style->foreground_blue,
            style->foreground_alpha);
  }
  if ((style->fields & HaskeLUIMacTextStyleBackground) != 0) {
    editor.backgroundColor =
        HaskeLUIColor(
            style->background_red,
            style->background_green,
            style->background_blue,
            style->background_alpha);
  }
  NSFont *font = HaskeLUIFontForStyle(editor.font, style);
  if (font != nil) {
    editor.font = font;
  }
  if (staticRichText && editor.string.length > 0) {
    [editor.textStorage addAttributes:@{
        NSFontAttributeName: editor.font,
        NSForegroundColorAttributeName: editor.textColor
      }
                               range:NSMakeRange(0, editor.string.length)];
  }
}

int32_t haskelui_macos_text_editor_apply_style(
    HaskeLUIMacControlRef reference,
    uint64_t utf16Location,
    uint64_t utf16Length,
    const HaskeLUIMacTextStyle *style) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  if (!HaskeLUIIsTextEditorHandle(handle) || style == NULL ||
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
  if ((style->fields & HaskeLUIMacTextStyleForeground) != 0) {
    attributes[NSForegroundColorAttributeName] =
        HaskeLUIColor(
            style->foreground_red,
            style->foreground_green,
            style->foreground_blue,
            style->foreground_alpha);
  }
  if ((style->fields & HaskeLUIMacTextStyleBackground) != 0) {
    attributes[NSBackgroundColorAttributeName] =
        HaskeLUIColor(
            style->background_red,
            style->background_green,
            style->background_blue,
            style->background_alpha);
  }
  NSFont *font = HaskeLUIFontForStyle(editor.font, style);
  if (font != nil) {
    attributes[NSFontAttributeName] = font;
  }
  if ((style->fields & HaskeLUIMacTextStyleUnderline) != 0) {
    attributes[NSUnderlineStyleAttributeName] = @(HaskeLUIUnderlineStyle(style->underline_style));
  }
  if ((style->fields & HaskeLUIMacTextStyleUnderlineColor) != 0) {
    attributes[NSUnderlineColorAttributeName] =
        HaskeLUIColor(
            style->underline_red,
            style->underline_green,
            style->underline_blue,
            style->underline_alpha);
  }
  if ((style->fields & HaskeLUIMacTextStyleStrikethrough) != 0) {
    attributes[NSStrikethroughStyleAttributeName] =
        style->strikethrough != 0 ? @(NSUnderlineStyleSingle) : @0;
  }
  if ((style->fields & HaskeLUIMacTextStyleLetterSpacing) != 0) {
    attributes[NSKernAttributeName] = @(style->letter_spacing);
  }
  if ((style->fields & HaskeLUIMacTextStyleBaselineOffset) != 0) {
    attributes[NSBaselineOffsetAttributeName] = @(style->baseline_offset);
  }

  if (length > 0 && attributes.count > 0) {
    BOOL staticRichText = handle.kind == HaskeLUIMacControlKindCatalog &&
        handle.catalogKind == HaskeLUIMacCatalogRichText;
    if (staticRichText) {
      [editor.textStorage addAttributes:attributes range:NSMakeRange(location, length)];
    } else {
      [editor.layoutManager
          addTemporaryAttributes:attributes
                forCharacterRange:NSMakeRange(location, length)];
    }
  }
  return 1;
}

int32_t haskelui_macos_text_editor_navigate(
    HaskeLUIMacControlRef reference,
    uint64_t utf16Location,
    uint64_t utf16Length,
    int32_t selectRange,
    int32_t focusEditor) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  if (!HaskeLUIIsTextEditorHandle(handle) ||
      utf16Location > NSUIntegerMax || utf16Length > NSUIntegerMax) {
    return 0;
  }
  NSTextView *editor = (NSTextView *)handle.focusView;
  NSUInteger location = (NSUInteger)utf16Location;
  NSUInteger length = (NSUInteger)utf16Length;
  if (location > editor.string.length || length > editor.string.length - location) {
    return 0;
  }
  NSRange range = NSMakeRange(location, length);
  if (selectRange != 0) {
    editor.selectedRange = range;
  }
  [editor scrollRangeToVisible:range];
  if (focusEditor != 0 && editor.window != nil) {
    [editor.window makeFirstResponder:editor];
  }
  return 1;
}

void haskelui_macos_text_editor_end_presentation(HaskeLUIMacControlRef reference) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  if (!HaskeLUIIsTextEditorHandle(handle)) {
    return;
  }
  NSTextView *editor = (NSTextView *)handle.focusView;
  if (editor.string.length > 0) {
    [editor.layoutManager invalidateDisplayForCharacterRange:NSMakeRange(0, editor.string.length)];
  }
}

void haskelui_macos_control_measure(
    HaskeLUIMacControlRef reference,
    double maximumWidth,
    double maximumHeight,
    HaskeLUIMacRect *result) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  NSView *view = handle.view;
  NSSize measured = view.fittingSize;

  if (handle.kind == HaskeLUIMacControlKindCatalog &&
      (handle.catalogKind == HaskeLUIMacCatalogTooltip ||
       handle.catalogKind == HaskeLUIMacCatalogBadge ||
       handle.catalogKind == HaskeLUIMacCatalogInlineNotice)) {
    NSTextField *title = (NSTextField *)HaskeLUISubview(handle, @"messageTitle");
    NSTextField *detail = (NSTextField *)HaskeLUISubview(handle, @"messageDetail");
    NSSize titleSize = [title.stringValue sizeWithAttributes:@{
      NSFontAttributeName: title.font
    }];
    NSSize detailSize = [detail.stringValue sizeWithAttributes:@{
      NSFontAttributeName: detail.font
    }];
    CGFloat titleWidth =
        ceil(MAX(titleSize.width, title.cell.cellSize.width)) + 2;
    CGFloat detailWidth =
        ceil(MAX(detailSize.width, detail.cell.cellSize.width)) + 2;
    NSBox *box = (NSBox *)handle.view;
    CGFloat horizontalChrome =
        MAX(0, NSWidth(box.bounds) - NSWidth(box.contentView.bounds));
    CGFloat verticalChrome =
        MAX(0, NSHeight(box.bounds) - NSHeight(box.contentView.bounds));
    if (handle.catalogKind == HaskeLUIMacCatalogBadge) {
      measured.width = MAX(measured.width,
          titleWidth + 16 + horizontalChrome);
      measured.height = MAX(measured.height,
          ceil(titleSize.height) + 10 + verticalChrome);
    } else {
      measured.width = MAX(measured.width,
          MAX(titleWidth, detailWidth) + 24 + horizontalChrome);
      measured.height = MAX(measured.height,
          ceil(titleSize.height + detailSize.height) + 18 + verticalChrome);
    }
  }

  if (HaskeLUIIsTextEditorHandle(handle) && maximumWidth > 0 && isfinite(maximumWidth)) {
    NSTextView *editor = (NSTextView *)handle.focusView;
    editor.textContainer.containerSize = NSMakeSize(maximumWidth, CGFLOAT_MAX);
    [editor.layoutManager ensureLayoutForTextContainer:editor.textContainer];
    NSRect used = [editor.layoutManager usedRectForTextContainer:editor.textContainer];
    measured.width = maximumWidth;
    measured.height = MAX(editor.font.pointSize + 8, NSHeight(used) + 8);
  }

  if (!(measured.width > 0) || !isfinite(measured.width)) {
    measured.width = MAX(0, handle.desiredFrame.size.width);
  }
  if (!(measured.height > 0) || !isfinite(measured.height)) {
    measured.height = MAX(0, handle.desiredFrame.size.height);
  }
  if (maximumWidth > 0 && isfinite(maximumWidth)) {
    measured.width = MIN(measured.width, maximumWidth);
  }
  if (maximumHeight > 0 && isfinite(maximumHeight)) {
    measured.height = MIN(measured.height, maximumHeight);
  }
  result->x = 0;
  result->y = 0;
  result->width = measured.width;
  result->height = measured.height;
}

void haskelui_macos_control_set_frame(HaskeLUIMacControlRef reference, const HaskeLUIMacRect *frame) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  handle.desiredFrame = HaskeLUIRect(frame);
  handle.view.frame = handle.desiredFrame;
  HaskeLUILayoutMessage(handle);
  HaskeLUILayoutContainer(handle);
}

void haskelui_macos_control_set_enabled(HaskeLUIMacControlRef reference, int32_t enabled) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *handle = HaskeLUIControl(reference);
  NSView *view = handle.view;
  if ([view isKindOfClass:NSControl.class]) {
    ((NSControl *)view).enabled = enabled != 0;
  }
  if (handle.focusView != view && [handle.focusView isKindOfClass:NSControl.class]) {
    ((NSControl *)handle.focusView).enabled = enabled != 0;
  }
  for (NSView *child in view.subviews) {
    if ([child isKindOfClass:NSControl.class]) {
      ((NSControl *)child).enabled = enabled != 0;
    }
  }
}

void haskelui_macos_control_focus(HaskeLUIMacWindowRef window, HaskeLUIMacControlRef control) {
  HaskeLUIAssertMainThread();
  [HaskeLUIWindow(window).window makeFirstResponder:HaskeLUIControl(control).focusView];
}

void haskelui_macos_control_set_next_key(
    HaskeLUIMacControlRef reference,
    HaskeLUIMacControlRef nextReference) {
  HaskeLUIAssertMainThread();
  HaskeLUIControl(reference).focusView.nextKeyView = HaskeLUIControl(nextReference).focusView;
}

static void HaskeLUIAttachControl(
    HaskeLUIMacControlHandle *control,
    NSView *parent,
    int32_t fillParent) {
  if (control == nil || parent == nil) {
    return;
  }
  if (control.view.superview != parent) {
    [control.view removeFromSuperview];
    [parent addSubview:control.view];
  }
  if (fillParent != 0) {
    control.view.frame = parent.bounds;
    control.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  }
}

void haskelui_macos_control_set_parent_item(
    HaskeLUIMacWindowRef windowReference,
    HaskeLUIMacControlRef controlReference,
    uint64_t itemIdentity,
    int32_t fillParent) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacWindowHandle *window = HaskeLUIWindow(windowReference);
  HaskeLUIAttachControl(
      HaskeLUIControl(controlReference),
      window.workspaceItems[@(itemIdentity)],
      fillParent);
}

void haskelui_macos_control_set_parent_tab(
    HaskeLUIMacWindowRef windowReference,
    HaskeLUIMacControlRef controlReference,
    uint64_t groupIdentity,
    uint64_t tabIdentity,
    int32_t fillParent) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacWindowHandle *window = HaskeLUIWindow(windowReference);
  HaskeLUIMacTabGroupHandle *group = window.tabGroups[@(groupIdentity)];
  HaskeLUIMacTabHandle *tab = group.tabs[@(tabIdentity)];
  HaskeLUIAttachControl(HaskeLUIControl(controlReference), tab.contentView, fillParent);
}

void haskelui_macos_control_set_parent_status(
    HaskeLUIMacWindowRef windowReference,
    HaskeLUIMacControlRef controlReference,
    int32_t fillParent) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacWindowHandle *window = HaskeLUIWindow(windowReference);
  HaskeLUIAttachControl(HaskeLUIControl(controlReference), window.workspaceStatus, fillParent);
}

void haskelui_macos_control_set_parent_control(
    HaskeLUIMacControlRef parentReference,
    HaskeLUIMacControlRef childReference,
    uint64_t slotIdentity,
    int32_t fillParent) {
  HaskeLUIAssertMainThread();
  HaskeLUIMacControlHandle *parent = HaskeLUIControl(parentReference);
  NSView *host = slotIdentity == 0
      ? parent.contentView
      : parent.slots[@(slotIdentity)];
  HaskeLUIAttachControl(HaskeLUIControl(childReference), host, fillParent);
  HaskeLUILayoutContainer(parent);
}

static void HaskeLUIDetachCallbacks(NSView *view) {
  if ([view isKindOfClass:NSTextField.class]) {
    ((NSTextField *)view).delegate = nil;
  }
  if ([view isKindOfClass:NSTextView.class]) {
    ((NSTextView *)view).delegate = nil;
  }
  if ([view isKindOfClass:NSControl.class]) {
    ((NSControl *)view).target = nil;
    ((NSControl *)view).action = nil;
  }
  for (NSView *child in view.subviews) {
    HaskeLUIDetachCallbacks(child);
  }
}

void haskelui_macos_control_destroy(HaskeLUIMacControlRef reference) {
  HaskeLUIAssertMainThread();
  if (reference == NULL) {
    return;
  }
  HaskeLUIMacControlHandle *handle = (__bridge_transfer HaskeLUIMacControlHandle *)reference;
  [HaskeLUIState.controls removeObjectForKey:@(handle.identity)];
  HaskeLUIDetachCallbacks(handle.view);
  if (handle.collectionAdapter != nil) {
    handle.collectionAdapter.table.delegate = nil;
    handle.collectionAdapter.table.dataSource = nil;
    handle.collectionAdapter = nil;
  }
  if (handle.gridAdapter != nil) {
    handle.gridAdapter.collection.delegate = nil;
    handle.gridAdapter.collection.dataSource = nil;
    handle.gridAdapter = nil;
  }
  if (handle.outlineAdapter != nil) {
    handle.outlineAdapter.outline.delegate = nil;
    handle.outlineAdapter.outline.dataSource = nil;
    handle.outlineAdapter = nil;
  }
  if (handle.popover != nil) {
    [handle.popover close];
    handle.popover = nil;
  }
  if (handle.presentationWindow != nil && handle.presentationWindow.sheetParent != nil) {
    [handle.presentationWindow.sheetParent endSheet:handle.presentationWindow];
    handle.presentationWindow = nil;
  }
  HaskeLUIReleaseItemTargets(handle);
  [handle.view removeFromSuperview];
  if (handle.target != nil) {
    handle.target = nil;
    HaskeLUILiveActionTargets -= 1;
  }
  handle.focusView = nil;
  handle.view = nil;
}

void haskelui_macos_command_set(
    uint64_t identity,
    const char *utf8_title,
    const char *utf8_key_equivalent,
    int32_t enabled) {
  HaskeLUIAssertMainThread();
  NSNumber *key = @(identity);
  NSMenuItem *item = HaskeLUIState.commandItems[key];
  if (item == nil) {
    HaskeLUIMacActionTarget *target = [[HaskeLUIMacActionTarget alloc] init];
    HaskeLUILiveActionTargets += 1;
    target.identity = identity;
    target.eventKind = HaskeLUIMacEventCommand;
    item = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(performAction:) keyEquivalent:@""];
    item.target = target;
    HaskeLUIState.commandItems[key] = item;
    HaskeLUIState.commandTargets[key] = target;
    [HaskeLUIState.fileMenu addItem:item];
  }
  item.title = HaskeLUIString(utf8_title);
  item.keyEquivalent = [HaskeLUIString(utf8_key_equivalent) lowercaseString];
  item.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  item.enabled = enabled != 0;
}

void haskelui_macos_command_remove(uint64_t identity) {
  HaskeLUIAssertMainThread();
  NSNumber *key = @(identity);
  NSMenuItem *item = HaskeLUIState.commandItems[key];
  if (item == nil) {
    return;
  }
  item.target = nil;
  [HaskeLUIState.fileMenu removeItem:item];
  [HaskeLUIState.commandItems removeObjectForKey:key];
  if (HaskeLUIState.commandTargets[key] != nil) {
    HaskeLUILiveActionTargets -= 1;
  }
  [HaskeLUIState.commandTargets removeObjectForKey:key];
}

void haskelui_macos_open_text_files(void) {
  HaskeLUIAssertMainThread();
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseFiles = YES;
  panel.canChooseDirectories = NO;
  panel.allowsMultipleSelection = YES;
  panel.resolvesAliases = YES;
  panel.title = @"Open Text Files";
  panel.prompt = @"Open";
  HaskeLUIState.openPanel = panel;
  [panel beginWithCompletionHandler:^(NSModalResponse response) {
    HaskeLUIState.openPanel = nil;
    if (response != NSModalResponseOK) {
      return;
    }
    for (NSURL *url in panel.URLs) {
      HaskeLUIEmit(HaskeLUIMacEventTextFileChosen, 0, url.path);
    }
  }];
}

void haskelui_macos_open_project_folder(void) {
  HaskeLUIAssertMainThread();
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseFiles = NO;
  panel.canChooseDirectories = YES;
  panel.allowsMultipleSelection = NO;
  panel.resolvesAliases = YES;
  panel.title = @"Open Project Folder";
  panel.prompt = @"Open";
  HaskeLUIState.openPanel = panel;
  [panel beginWithCompletionHandler:^(NSModalResponse response) {
    HaskeLUIState.openPanel = nil;
    if (response != NSModalResponseOK || panel.URL == nil) {
      return;
    }
    HaskeLUIEmit(HaskeLUIMacEventProjectFolderChosen, 0, panel.URL.path);
  }];
}

static void HaskeLUITestFail(NSString *message) {
  HaskeLUITestFailures += 1;
  if (HaskeLUILastTestFailure == nil) {
    HaskeLUILastTestFailure = [message copy];
  }
  NSLog(@"HaskeLUI native validation failure: %@", message);
}

static BOOL HaskeLUIResponderBelongsToView(NSResponder *responder, NSView *view) {
  if (responder == view) {
    return YES;
  }
  if ([responder isKindOfClass:NSText.class]) {
    return (id)((NSText *)responder).delegate == (id)view;
  }
  return NO;
}

void haskelui_macos_debug_counters(HaskeLUIMacDebugCounters *counters) {
  if (counters == NULL) {
    return;
  }
  counters->windows = HaskeLUILiveWindows;
  counters->controls = HaskeLUILiveControls;
  counters->action_targets = HaskeLUILiveActionTargets;
  counters->window_delegates = HaskeLUILiveWindowDelegates;
  counters->queued_callbacks = HaskeLUIQueuedCallbacks;
  counters->test_failures = HaskeLUITestFailures;
}

const char *haskelui_macos_test_last_failure(void) {
  return HaskeLUILastTestFailure == nil ? NULL : HaskeLUILastTestFailure.UTF8String;
}

int32_t haskelui_macos_test_acquire_process_lock(void) {
  if (HaskeLUITestProcessLockDescriptor >= 0) {
    return 1;
  }
  NSString *path = [NSTemporaryDirectory()
      stringByAppendingPathComponent:@"haskelui-appkit-native-tests.lock"];
  int descriptor = open(path.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
  if (descriptor < 0) {
    return 0;
  }
  int result;
  do {
    result = flock(descriptor, LOCK_EX);
  } while (result < 0 && errno == EINTR);
  if (result < 0) {
    close(descriptor);
    return 0;
  }
  HaskeLUITestProcessLockDescriptor = descriptor;
  return 1;
}

void haskelui_macos_test_release_process_lock(void) {
  int descriptor = HaskeLUITestProcessLockDescriptor;
  if (descriptor < 0) {
    return;
  }
  HaskeLUITestProcessLockDescriptor = -1;
  flock(descriptor, LOCK_UN);
  close(descriptor);
}

static void HaskeLUITestAfter(double seconds, dispatch_block_t block) {
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
      dispatch_get_main_queue(),
      block);
}

static void HaskeLUITestEventuallyAt(
    CFAbsoluteTime deadline,
    BOOL (^condition)(void),
    dispatch_block_t block) {
  if (condition() || CFAbsoluteTimeGetCurrent() >= deadline) {
    block();
    return;
  }
  HaskeLUITestAfter(0.05, ^{
    HaskeLUITestEventuallyAt(deadline, condition, block);
  });
}

static void HaskeLUITestEventually(
    double timeout,
    BOOL (^condition)(void),
    dispatch_block_t block) {
  HaskeLUITestEventuallyAt(CFAbsoluteTimeGetCurrent() + timeout, condition, block);
}

void haskelui_macos_test_schedule_vertical_script(
    uint64_t mainWindowIdentity,
    uint64_t nameFieldIdentity,
    uint64_t greetingLabelIdentity,
    uint64_t saveCommandIdentity) {
  HaskeLUIAssertMainThread();

  HaskeLUITestAfter(0.10, ^{
        HaskeLUIMacWindowHandle *mainWindow = HaskeLUIState.windows[@(mainWindowIdentity)];
        HaskeLUIMacControlHandle *nameField = HaskeLUIState.controls[@(nameFieldIdentity)];
        HaskeLUIMacControlHandle *greetingLabel = HaskeLUIState.controls[@(greetingLabelIdentity)];
        NSMenuItem *saveItem = HaskeLUIState.commandItems[@(saveCommandIdentity)];
        if (mainWindow == nil || nameField == nil || greetingLabel == nil || saveItem == nil) {
          HaskeLUITestFail(@"initial native window, controls, or Save command were not registered");
          [NSApplication.sharedApplication stop:nil];
          return;
        }

        NSTextField *field = (NSTextField *)nameField.view;
        NSString *expectedIdentifier =
            [NSString stringWithFormat:@"haskelui-control-%llu", nameFieldIdentity];
        if (![field.accessibilityIdentifier isEqualToString:expectedIdentifier]) {
          HaskeLUITestFail(@"text field does not expose its stable HaskeLUI accessibility identifier");
        }
        NSString *role = field.accessibilityRole;
        if (![role isEqualToString:NSAccessibilityTextFieldRole]) {
          HaskeLUITestFail([NSString stringWithFormat:
              @"text field exposes accessibility role %@ instead of %@",
              role,
              NSAccessibilityTextFieldRole]);
        }

        [mainWindow.window makeKeyAndOrderFront:nil];
        if (![mainWindow.window makeFirstResponder:field] ||
            !HaskeLUIResponderBelongsToView(mainWindow.window.firstResponder, field)) {
          HaskeLUITestFail(@"text field could not become the native first responder");
        }
        NSView *nextKeyView = field.nextKeyView;
        if (nextKeyView == nil || nextKeyView == field) {
          HaskeLUITestFail(@"explicit key-view traversal was not installed");
        } else {
          if (![mainWindow.window makeFirstResponder:nextKeyView] ||
              !HaskeLUIResponderBelongsToView(mainWindow.window.firstResponder, nextKeyView)) {
            HaskeLUITestFail(@"next key-view control could not become the native first responder");
          }
          [mainWindow.window makeFirstResponder:field];
        }

        [mainWindow.window performClose:nil];

        HaskeLUITestAfter(0.12, ^{
          HaskeLUIMacWindowHandle *retainedMainWindow = HaskeLUIState.windows[@(mainWindowIdentity)];
          HaskeLUIMacControlHandle *retainedNameField = HaskeLUIState.controls[@(nameFieldIdentity)];
          if (retainedMainWindow == nil) {
            HaskeLUITestFail(@"dirty main window was not retained after its close veto");
            [NSApplication.sharedApplication stop:nil];
            return;
          }
          if (retainedNameField == nil || retainedNameField.kind != HaskeLUIMacControlKindTextField) {
            HaskeLUITestFail(@"name text field disappeared after close veto");
            [NSApplication.sharedApplication stop:nil];
            return;
          }
          NSTextField *retainedField = (NSTextField *)retainedNameField.view;
          retainedField.stringValue = @"Ada";
          [retainedField.delegate controlTextDidChange:
              [NSNotification
                  notificationWithName:NSControlTextDidChangeNotification
                                object:retainedField]];

          HaskeLUITestAfter(0.12, ^{
            HaskeLUIMacWindowHandle *editedMainWindow = HaskeLUIState.windows[@(mainWindowIdentity)];
            HaskeLUIMacControlHandle *editedGreeting = HaskeLUIState.controls[@(greetingLabelIdentity)];
            NSMenuItem *enabledSaveItem = HaskeLUIState.commandItems[@(saveCommandIdentity)];
            if (editedMainWindow == nil || editedGreeting == nil || enabledSaveItem == nil) {
              HaskeLUITestFail(@"native scene disappeared before keyboard-equivalent validation");
              [NSApplication.sharedApplication stop:nil];
              return;
            }
            NSString *greeting = ((NSTextField *)editedGreeting.view).stringValue;
            if (![greeting isEqualToString:@"Hello, Ada!"]) {
              HaskeLUITestFail(@"text delegate callback did not reconcile the greeting label");
            }
            if (!enabledSaveItem.enabled) {
              HaskeLUITestFail(@"Save command unexpectedly disabled before keyboard dispatch");
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
              HaskeLUITestFail(@"AppKit main menu did not handle the Command-S key equivalent");
            }

            HaskeLUITestAfter(0.12, ^{
              HaskeLUIMacWindowHandle *savedMainWindow = HaskeLUIState.windows[@(mainWindowIdentity)];
              NSMenuItem *disabledSaveItem = HaskeLUIState.commandItems[@(saveCommandIdentity)];
              if (savedMainWindow == nil || disabledSaveItem == nil) {
                HaskeLUITestFail(@"main window or Save command disappeared after keyboard dispatch");
                [NSApplication.sharedApplication stop:nil];
                return;
              }
              if ([savedMainWindow.window.title containsString:@"Edited"] ||
                  disabledSaveItem.enabled) {
                HaskeLUITestFail(@"Command-S did not reconcile saved state into window and menu");
              }
              [savedMainWindow.window performClose:nil];

              HaskeLUITestAfter(0.50, ^{
                if (HaskeLUIState != nil) {
                  HaskeLUITestFail(@"vertical validation timed out before the application stopped");
                  [NSApplication.sharedApplication stop:nil];
                }
              });
            });
          });
        });
      });
}

static BOOL HaskeLUISelectCatalogSegment(HaskeLUIMacControlHandle *handle, uint64_t identity) {
  NSSegmentedControl *segments = nil;
  if ([handle.view isKindOfClass:NSSegmentedControl.class]) {
    segments = (NSSegmentedControl *)handle.view;
  } else if (handle.catalogKind == HaskeLUIMacCatalogTabView) {
    segments = (NSSegmentedControl *)HaskeLUISubview(handle, @"tabs");
  }
  if (segments == nil) {
    return NO;
  }
  for (NSInteger index = 0; index < segments.segmentCount; index += 1) {
    if ((uint64_t)[segments tagForSegment:index] == identity) {
      segments.selectedSegment = index;
      [segments sendAction:segments.action to:segments.target];
      return YES;
    }
  }
  return NO;
}

void haskelui_macos_test_schedule_control_gallery_script(
    uint64_t windowIdentity,
    uint64_t rootTabIdentity,
    uint64_t textInputIdentity,
    uint64_t textMirrorIdentity,
    uint64_t toggleIdentity,
    uint64_t choiceIdentity,
    uint64_t numericIdentity,
    uint64_t collectionIdentity,
    uint64_t dialogButtonIdentity,
    uint64_t dialogIdentity,
    uint64_t popoverButtonIdentity,
    uint64_t popoverIdentity,
    uint64_t containerIdentity,
    uint64_t nestedChildIdentity) {
  HaskeLUIAssertMainThread();
  HaskeLUIControlGalleryTestActive = YES;

  HaskeLUITestAfter(0.12, ^{
    HaskeLUIMacWindowHandle *window = HaskeLUIState.windows[@(windowIdentity)];
    HaskeLUIMacControlHandle *rootTabs = HaskeLUIState.controls[@(rootTabIdentity)];
    HaskeLUIMacControlHandle *container = HaskeLUIState.controls[@(containerIdentity)];
    HaskeLUIMacControlHandle *nestedChild = HaskeLUIState.controls[@(nestedChildIdentity)];
    if (window == nil || rootTabs == nil || container == nil || nestedChild == nil) {
      HaskeLUITestFail(@"control gallery window or structural controls were not registered");
      [NSApplication.sharedApplication stop:nil];
      return;
    }
    if (HaskeLUIState.controls.count < 174) {
      HaskeLUITestFail([NSString stringWithFormat:
          @"control gallery registered only %lu of 174 controls",
          (unsigned long)HaskeLUIState.controls.count]);
    }

    BOOL seenCatalog[HaskeLUIMacCatalogContainer + 1] = {NO};
    BOOL seenLegacy[4] = {NO};
    HaskeLUIMacControlHandle *richText = HaskeLUIState.controls[@102];
    for (HaskeLUIMacControlHandle *control in HaskeLUIState.controls.allValues) {
      NSString *expectedIdentifier =
          [NSString stringWithFormat:@"haskelui-control-%llu", control.identity];
      if (![control.focusView.accessibilityIdentifier isEqualToString:expectedIdentifier]) {
        HaskeLUITestFail([NSString stringWithFormat:
            @"control %llu lost its stable accessibility identity", control.identity]);
      }
      if (control.kind == HaskeLUIMacControlKindCatalog &&
          control.catalogKind >= HaskeLUIMacCatalogRichText &&
          control.catalogKind <= HaskeLUIMacCatalogContainer) {
        seenCatalog[control.catalogKind] = YES;
      } else if (control.kind >= HaskeLUIMacControlKindLabel &&
                 control.kind <= HaskeLUIMacControlKindTextEditor) {
        seenLegacy[control.kind] = YES;
      }
    }
    for (NSInteger kind = HaskeLUIMacCatalogRichText; kind <= HaskeLUIMacCatalogContainer; kind += 1) {
      if (!seenCatalog[kind]) {
        HaskeLUITestFail([NSString stringWithFormat:@"catalog kind %ld has no native peer", (long)kind]);
      }
    }
    for (NSInteger kind = 0; kind < 4; kind += 1) {
      if (!seenLegacy[kind]) {
        HaskeLUITestFail([NSString stringWithFormat:@"legacy control kind %ld is missing", (long)kind]);
      }
    }
    if (rootTabs.catalogKind != HaskeLUIMacCatalogTabView || rootTabs.slots.count != 6) {
      HaskeLUITestFail(@"ordinary tab view did not retain all six gallery pages");
    }
    if (nestedChild.view.superview != container.contentView) {
      HaskeLUITestFail(@"arbitrary child was not parented inside its semantic container");
    }

    HaskeLUIMacControlHandle *layoutRoot = HaskeLUIState.controls[@6000];
    HaskeLUIMacControlHandle *flowGroup = HaskeLUIState.controls[@6010];
    HaskeLUIMacControlHandle *fixedFlow = HaskeLUIState.controls[@6011];
    HaskeLUIMacControlHandle *growOne = HaskeLUIState.controls[@6012];
    HaskeLUIMacControlHandle *growTwo = HaskeLUIState.controls[@6013];
    HaskeLUIMacControlHandle *evenBadge = HaskeLUIState.controls[@6024];
    HaskeLUIMacControlHandle *gridFixed = HaskeLUIState.controls[@6031];
    HaskeLUIMacControlHandle *wrapFirst = HaskeLUIState.controls[@6051];
    HaskeLUIMacControlHandle *wrapLast = HaskeLUIState.controls[@6058];
    HaskeLUIMacControlHandle *compactAdaptive = HaskeLUIState.controls[@6071];
    HaskeLUIMacControlHandle *wideAdaptive = HaskeLUIState.controls[@6072];
    HaskeLUIMacControlHandle *compactFirst = HaskeLUIState.controls[@6080];
    HaskeLUIMacControlHandle *compactSecond = HaskeLUIState.controls[@6081];
    HaskeLUIMacControlHandle *wideFirst = HaskeLUIState.controls[@6090];
    HaskeLUIMacControlHandle *wideSecond = HaskeLUIState.controls[@6091];
    HaskeLUIMacControlHandle *tableGroup = HaskeLUIState.controls[@6100];
    HaskeLUIMacControlHandle *tableHeaderFirst = HaskeLUIState.controls[@6110];
    HaskeLUIMacControlHandle *tableHeaderLast = HaskeLUIState.controls[@6113];
    HaskeLUIMacControlHandle *tableFinalCell = HaskeLUIState.controls[@6129];
    HaskeLUIMacControlHandle *tableVerticalLine = HaskeLUIState.controls[@6140];
    HaskeLUIMacControlHandle *tableHorizontalLine = HaskeLUIState.controls[@6150];
    if (layoutRoot == nil || flowGroup == nil || fixedFlow == nil ||
        growOne == nil || growTwo == nil || evenBadge == nil || gridFixed == nil ||
        wrapFirst == nil || wrapLast == nil || compactAdaptive == nil ||
        wideAdaptive == nil || compactFirst == nil || compactSecond == nil ||
        wideFirst == nil || wideSecond == nil || tableGroup == nil ||
        tableHeaderFirst == nil || tableHeaderLast == nil ||
        tableFinalCell == nil || tableVerticalLine == nil ||
        tableHorizontalLine == nil) {
      HaskeLUITestFail(@"portable layout lab did not realize all native peers");
    } else {
      if (layoutRoot.containerState != 6100 ||
          layoutRoot.containerScrollView == nil ||
          !layoutRoot.contentView.isFlipped ||
          flowGroup.view.superview != layoutRoot.contentView ||
          fixedFlow.view.superview != flowGroup.contentView) {
        HaskeLUITestFail(@"portable scroll/group hosts lost their top-left hierarchy");
      }
      NSClipView *layoutClip = layoutRoot.containerScrollView.contentView;
      CGFloat layoutScrollRange =
          NSHeight(layoutRoot.contentView.frame) - NSHeight(layoutClip.bounds);
      if (layoutScrollRange <= 0.5) {
        HaskeLUITestFail(@"portable scroll host did not preserve its larger layout document");
      } else {
        [layoutClip scrollToPoint:NSMakePoint(0, layoutScrollRange)];
        [layoutRoot.containerScrollView reflectScrolledClipView:layoutClip];
        if (NSMinY(layoutClip.bounds) <= 0.5) {
          HaskeLUITestFail(@"portable scroll host did not scroll through its layout document");
        }
        [layoutClip scrollToPoint:NSMakePoint(0, 0)];
        [layoutRoot.containerScrollView reflectScrolledClipView:layoutClip];
      }
      if (fabs(NSWidth(fixedFlow.view.frame) - 130) > 0.5 ||
          NSWidth(growTwo.view.frame) <= NSWidth(growOne.view.frame) ||
          NSMinX(growOne.view.frame) <= NSMaxX(fixedFlow.view.frame)) {
        HaskeLUITestFail(@"portable flex basis, gap, or weighted growth is incorrect");
      }
      NSTextField *evenBadgeTitle =
          (NSTextField *)HaskeLUISubview(evenBadge, @"messageTitle");
      NSSize evenBadgeTextSize =
          [evenBadgeTitle.stringValue sizeWithAttributes:@{
            NSFontAttributeName: evenBadgeTitle.font
          }];
      CGFloat evenBadgeTextWidth =
          ceil(MAX(evenBadgeTextSize.width,
                   evenBadgeTitle.cell.cellSize.width)) + 2;
      CGFloat evenBadgeChrome =
          NSWidth(evenBadge.view.bounds) -
          NSWidth(((NSBox *)evenBadge.view).contentView.bounds);
      if (![evenBadgeTitle.stringValue isEqualToString:@"Even 1"] ||
          NSWidth(evenBadge.view.frame) + 0.5 <
              evenBadgeTextWidth + 16 + evenBadgeChrome ||
          NSWidth(evenBadgeTitle.frame) + 0.5 < evenBadgeTextWidth) {
        HaskeLUITestFail([NSString stringWithFormat:
            @"portable intrinsic measurement clipped badge text "
             "(value=%@, control=%.1f, title=%.1f, text=%.1f, content=%.1f)",
            evenBadgeTitle.stringValue,
            NSWidth(evenBadge.view.frame),
            NSWidth(evenBadgeTitle.frame),
            evenBadgeTextSize.width,
            NSWidth(((NSBox *)evenBadge.view).contentView.bounds)]);
      }
      if (fabs(NSWidth(gridFixed.view.frame) - 170) > 0.5) {
        HaskeLUITestFail(@"portable fixed grid track was not committed natively");
      }
      if (tableGroup.view.superview != layoutRoot.contentView ||
          tableHeaderFirst.view.superview != tableGroup.contentView) {
        HaskeLUITestFail(@"portable table grid lost its retained native hierarchy");
      }
      if (NSMinX(tableHeaderLast.view.frame) <= NSMaxX(tableHeaderFirst.view.frame) ||
          NSMinY(tableFinalCell.view.frame) <= NSMaxY(tableHeaderFirst.view.frame)) {
        HaskeLUITestFail(@"portable table grid did not form distinct rows and columns");
      }
      if (fabs(NSWidth(tableVerticalLine.view.frame) - 1) > 0.5 ||
          NSHeight(tableVerticalLine.view.frame) <= NSHeight(tableHeaderFirst.view.frame) ||
          fabs(NSHeight(tableHorizontalLine.view.frame) - 1) > 0.5 ||
          NSWidth(tableHorizontalLine.view.frame) <= NSWidth(tableHeaderFirst.view.frame)) {
        HaskeLUITestFail(@"portable table grid separator tracks do not outline its cells");
      }
      if (NSMinY(wrapLast.view.frame) <= NSMinY(wrapFirst.view.frame)) {
        HaskeLUITestFail(@"portable wrap layout did not form multiple visual lines");
      }
      if (compactAdaptive.view.frame.size.width < 400 &&
          NSMinY(compactSecond.view.frame) <= NSMinY(compactFirst.view.frame)) {
        HaskeLUITestFail(@"compact adaptive layout did not use its column strategy");
      }
      if (wideAdaptive.view.frame.size.width >= 400 &&
          NSMinX(wideSecond.view.frame) <= NSMinX(wideFirst.view.frame)) {
        HaskeLUITestFail(@"wide adaptive layout did not use its row strategy");
      }
    }
    if (richText == nil || ![richText.focusView isKindOfClass:NSTextView.class]) {
      HaskeLUITestFail(@"rich text did not map to an attributed native text peer");
    } else {
      NSTextView *text = (NSTextView *)richText.focusView;
      NSDictionary<NSAttributedStringKey, id> *boldAttributes =
          [text.textStorage attributesAtIndex:1 effectiveRange:NULL];
      NSDictionary<NSAttributedStringKey, id> *colorAttributes =
          [text.textStorage attributesAtIndex:12 effectiveRange:NULL];
      NSDictionary<NSAttributedStringKey, id> *sizeAttributes =
          [text.textStorage attributesAtIndex:18 effectiveRange:NULL];
      NSDictionary<NSAttributedStringKey, id> *italicAttributes =
          [text.textStorage attributesAtIndex:24 effectiveRange:NULL];
      NSFont *boldFont = boldAttributes[NSFontAttributeName];
      NSFont *sizeFont = sizeAttributes[NSFontAttributeName];
      NSFont *italicFont = italicAttributes[NSFontAttributeName];
      NSNumber *weight = boldFont.fontDescriptor.fontAttributes[NSFontTraitsAttribute]
          [NSFontWeightTrait];
      BOOL hasBold = weight.doubleValue >= NSFontWeightSemibold ||
          (boldFont.fontDescriptor.symbolicTraits & NSFontDescriptorTraitBold) != 0;
      BOOL hasColor = colorAttributes[NSForegroundColorAttributeName] != nil;
      BOOL hasSize = fabs(sizeFont.pointSize - 20.0) < 0.1;
      BOOL hasItalic = (italicFont.fontDescriptor.symbolicTraits &
                        NSFontDescriptorTraitItalic) != 0;
      if (!hasBold || !hasColor || !hasSize || !hasItalic) {
        HaskeLUITestFail([NSString stringWithFormat:
            @"rich text realization failed (bold=%d color=%d size=%d italic=%d, pointSize=%.2f)",
            hasBold, hasColor, hasSize, hasItalic, sizeFont.pointSize]);
      }
    }

    HaskeLUIMacControlHandle *checkBox = HaskeLUIState.controls[@108];
    HaskeLUIMacControlHandle *nativeSwitch = HaskeLUIState.controls[@109];
    HaskeLUIMacControlHandle *radioGroup = HaskeLUIState.controls[@111];
    NSButton *firstRadio = (NSButton *)((NSStackView *)radioGroup.view).arrangedSubviews.firstObject;
    if (![checkBox.view isKindOfClass:NSButton.class] ||
        ((NSButton *)checkBox.view).title.length == 0 ||
        ![((NSButton *)checkBox.view).accessibilityRole isEqualToString:NSAccessibilityCheckBoxRole]) {
      HaskeLUITestFail(@"checkbox did not retain its native indicator and visible label");
    }
    if (![nativeSwitch.focusView isKindOfClass:NSSwitch.class] ||
        ((NSTextField *)HaskeLUISubview(nativeSwitch, @"switchLabel")).stringValue.length == 0) {
      HaskeLUITestFail(@"switch did not retain its native peer and visible label");
    }
    if (![firstRadio isKindOfClass:NSButton.class] || firstRadio.title.length == 0 ||
        ((NSStackView *)radioGroup.view).arrangedSubviews.count != 3) {
      HaskeLUITestFail(@"radio group did not retain native radio indicators and labels");
    }

    HaskeLUIMacControlHandle *listPeer = HaskeLUIState.controls[@301];
    HaskeLUIMacControlHandle *gridPeer = HaskeLUIState.controls[@302];
    HaskeLUIMacControlHandle *treePeer = HaskeLUIState.controls[@303];
    HaskeLUIMacControlHandle *tablePeer = HaskeLUIState.controls[@304];
    HaskeLUIMacControlHandle *repeaterPeer = HaskeLUIState.controls[@305];
    HaskeLUIMacControlHandle *sidebarPeer = HaskeLUIState.controls[@306];
    if (listPeer.collectionAdapter == nil || gridPeer.gridAdapter == nil ||
        treePeer.outlineAdapter == nil || tablePeer.collectionAdapter == nil ||
        repeaterPeer.gridAdapter == nil || !repeaterPeer.gridAdapter.repeater ||
        sidebarPeer.collectionAdapter.table.style != NSTableViewStyleSourceList) {
      HaskeLUITestFail(@"collection families collapsed to indistinguishable native peers");
    }
    HaskeLUIMacOutlineNode *lazyFolderNode = nil;
    for (HaskeLUIMacOutlineNode *node in treePeer.outlineAdapter.roots) {
      if ([node.value[@"identity"] unsignedLongLongValue] == 5) {
        lazyFolderNode = node;
        break;
      }
    }
    if (lazyFolderNode == nil ||
        ![treePeer.outlineAdapter.outline isExpandable:lazyFolderNode]) {
      HaskeLUITestFail(@"an explicitly expandable unloaded tree item has no native disclosure affordance");
    }
    NSTableView *nativeTable = tablePeer.collectionAdapter.table;
    if (listPeer.collectionAdapter.table.rowSizeStyle != NSTableViewRowSizeStyleDefault ||
        treePeer.outlineAdapter.outline.rowSizeStyle != NSTableViewRowSizeStyleDefault ||
        nativeTable.rowSizeStyle != NSTableViewRowSizeStyleDefault ||
        sidebarPeer.collectionAdapter.table.rowSizeStyle != NSTableViewRowSizeStyleDefault) {
      HaskeLUITestFail(@"row-based controls did not preserve AppKit's system-default row size policy");
    }
    haskelui_macos_catalog_control_set_row_sizing((__bridge HaskeLUIMacControlRef)tablePeer, 4, 31);
    if (nativeTable.rowSizeStyle != NSTableViewRowSizeStyleCustom ||
        fabs(nativeTable.rowHeight - 31) > 0.001) {
      HaskeLUITestFail(@"explicit fixed row sizing did not reach NSTableView");
    }
    haskelui_macos_catalog_control_set_row_sizing((__bridge HaskeLUIMacControlRef)tablePeer, 5, 0);
    if (!nativeTable.usesAutomaticRowHeights ||
        !tablePeer.collectionAdapter.contentSizedRows) {
      HaskeLUITestFail(@"content-sized rows did not enable AppKit automatic row heights");
    }
    haskelui_macos_catalog_control_set_row_sizing((__bridge HaskeLUIMacControlRef)tablePeer, 0, 0);
    if (nativeTable.rowSizeStyle != NSTableViewRowSizeStyleDefault ||
        nativeTable.usesAutomaticRowHeights) {
      HaskeLUITestFail(@"system-default row sizing was not restored");
    }
    if (nativeTable == nil || nativeTable.headerView == nil ||
        NSHeight(nativeTable.headerView.frame) < 20 ||
        nativeTable.tableColumns.count != 2 ||
        !nativeTable.usesAlternatingRowBackgroundColors ||
        ![nativeTable.tableColumns[0].title isEqualToString:@"Item"] ||
        ![nativeTable.tableColumns[1].title isEqualToString:@"Value"]) {
      HaskeLUITestFail(@"TableView is not an identifiable native two-column table with header and alternating rows");
    }
    HaskeLUICenteredTableCellView *selectedTableCell = (HaskeLUICenteredTableCellView *)
        [nativeTable viewAtColumn:0 row:1 makeIfNecessary:YES];
    HaskeLUICenteredTableCellView *selectedTreeCell = (HaskeLUICenteredTableCellView *)
        [treePeer.outlineAdapter.outline viewAtColumn:0 row:1 makeIfNecessary:YES];
    [selectedTableCell layoutSubtreeIfNeeded];
    [selectedTreeCell layoutSubtreeIfNeeded];
    BOOL (^isVerticallyCentered)(HaskeLUICenteredTableCellView *) =
        ^BOOL(HaskeLUICenteredTableCellView *cell) {
          if (![cell isKindOfClass:HaskeLUICenteredTableCellView.class]) {
            return NO;
          }
          CGFloat lower = NSMinY(cell.centeredLabel.frame) - NSMinY(cell.bounds);
          CGFloat upper = NSMaxY(cell.bounds) - NSMaxY(cell.centeredLabel.frame);
          return lower >= -0.5 && upper >= -0.5 && fabs(lower - upper) <= 0.5;
        };
    if (!isVerticallyCentered(selectedTableCell) ||
        !isVerticallyCentered(selectedTreeCell)) {
      HaskeLUITestFail(@"selected table or tree text is not vertically centered in its row");
    }
    HaskeLUIMacGridItem *firstGridItem = (HaskeLUIMacGridItem *)
        [gridPeer.gridAdapter.collection itemAtIndexPath:
            [NSIndexPath indexPathForItem:0 inSection:0]];
    if (firstGridItem == nil ||
        !NSContainsRect(firstGridItem.card.contentView.bounds, firstGridItem.titleLabel.frame) ||
        !NSContainsRect(firstGridItem.card.contentView.bounds, firstGridItem.detailLabel.frame) ||
        NSIntersectsRect(firstGridItem.titleLabel.frame, firstGridItem.detailLabel.frame)) {
      HaskeLUITestFail(@"CollectionView card text escapes its content bounds or overlaps");
    }

    rootTabs.slots[@9201].hidden = YES;
    rootTabs.slots[@9202].hidden = NO;
    HaskeLUIMacControlHandle *textInput = HaskeLUIState.controls[@(textInputIdentity)];
    if (textInput == nil || ![textInput.focusView isKindOfClass:NSTextView.class]) {
      HaskeLUITestFail(@"gallery text area has no native text view");
      [NSApplication.sharedApplication stop:nil];
      return;
    }
    NSTextView *editor = (NSTextView *)textInput.focusView;
    [window.window makeFirstResponder:editor];
    editor.string = @"native gallery edit";
    [editor.delegate textDidChange:
        [NSNotification notificationWithName:NSTextDidChangeNotification object:editor]];

    HaskeLUITestAfter(0.14, ^{
      HaskeLUIMacControlHandle *textMirror = HaskeLUIState.controls[@(textMirrorIdentity)];
      if (textMirror == nil ||
          ![((NSTextField *)textMirror.view).stringValue isEqualToString:@"native gallery edit"]) {
        HaskeLUITestFail(@"typed text callback did not reconcile the shared gallery model");
      }
      HaskeLUIMacControlHandle *updatedTextInput = HaskeLUIState.controls[@(textInputIdentity)];
      if (window.window.firstResponder != updatedTextInput.focusView) {
        HaskeLUITestFail(@"text-area reconciliation discarded the native first responder");
      }

      HaskeLUIMacControlHandle *toggle = HaskeLUIState.controls[@(toggleIdentity)];
      if (toggle == nil || ![toggle.view isKindOfClass:NSButton.class]) {
        HaskeLUITestFail(@"gallery toggle has no native button peer");
      } else {
        [(NSButton *)toggle.view performClick:nil];
      }

      HaskeLUITestAfter(0.14, ^{
        HaskeLUIMacControlHandle *updatedToggle = HaskeLUIState.controls[@(toggleIdentity)];
        if (((NSButton *)updatedToggle.view).state != NSControlStateValueOff) {
          HaskeLUITestFail(@"typed toggle callback did not reconcile Boolean state");
        }
        HaskeLUIMacControlHandle *choice = HaskeLUIState.controls[@(choiceIdentity)];
        if (!HaskeLUISelectCatalogSegment(choice, 2)) {
          HaskeLUITestFail(@"segmented choice could not select its keyed second item");
        }

        HaskeLUITestAfter(0.14, ^{
          HaskeLUIMacControlHandle *updatedChoice = HaskeLUIState.controls[@(choiceIdentity)];
          NSSegmentedControl *choiceSegments = (NSSegmentedControl *)updatedChoice.view;
          if (choiceSegments.selectedSegment < 0 ||
              [choiceSegments tagForSegment:choiceSegments.selectedSegment] != 2) {
            HaskeLUITestFail(@"typed choice callback did not preserve keyed selection");
          }

          HaskeLUIMacControlHandle *numeric = HaskeLUIState.controls[@(numericIdentity)];
          NSSlider *slider = (NSSlider *)numeric.view;
          slider.doubleValue = 7;
          [slider sendAction:slider.action to:slider.target];

          HaskeLUIMacControlHandle *collection = HaskeLUIState.controls[@(collectionIdentity)];
          rootTabs.slots[@9202].hidden = YES;
          rootTabs.slots[@9203].hidden = NO;
          [window.window makeFirstResponder:collection.collectionAdapter.table];
          [collection.collectionAdapter.table
              selectRowIndexes:[NSIndexSet indexSetWithIndex:2]
             byExtendingSelection:NO];

          HaskeLUITestAfter(0.16, ^{
            HaskeLUIMacControlHandle *updatedNumeric = HaskeLUIState.controls[@(numericIdentity)];
            if (fabs(((NSSlider *)updatedNumeric.view).doubleValue - 7) > 0.001) {
              HaskeLUITestFail(@"typed numeric callback did not reconcile the slider value");
            }
            HaskeLUIMacControlHandle *updatedCollection = HaskeLUIState.controls[@(collectionIdentity)];
            if (![updatedCollection.collectionAdapter.table.selectedRowIndexes containsIndex:2]) {
              HaskeLUITestFail(@"typed collection callback did not reconcile keyed selection");
            }
            if (window.window.firstResponder != updatedCollection.collectionAdapter.table) {
              HaskeLUITestFail(@"collection reconciliation discarded the native first responder");
            }

            HaskeLUIMacControlHandle *updatedTabs = HaskeLUIState.controls[@(rootTabIdentity)];
            if (!HaskeLUISelectCatalogSegment(updatedTabs, 9204)) {
              HaskeLUITestFail(@"gallery shell tab could not be selected");
            }

            HaskeLUITestAfter(0.14, ^{
              HaskeLUIMacControlHandle *dialogButton = HaskeLUIState.controls[@(dialogButtonIdentity)];
              if (dialogButton == nil || ![dialogButton.view isKindOfClass:NSButton.class]) {
                HaskeLUITestFail(@"dialog command button has no native peer");
              } else {
                [(NSButton *)dialogButton.view performClick:nil];
              }

              HaskeLUITestAfter(0.18, ^{
                HaskeLUIMacControlHandle *dialog = HaskeLUIState.controls[@(dialogIdentity)];
                if (dialog == nil || dialog.presentationWindow == nil ||
                    dialog.presentationWindow.sheetParent == nil) {
                  HaskeLUITestFail(@"desired dialog state did not produce a native sheet");
                } else {
                  [dialog.presentationWindow.sheetParent
                      endSheet:dialog.presentationWindow
                     returnCode:NSAlertFirstButtonReturn];
                }

                HaskeLUITestAfter(0.16, ^{
                  HaskeLUIMacControlHandle *popoverButton = HaskeLUIState.controls[@(popoverButtonIdentity)];
                  if (popoverButton == nil || ![popoverButton.view isKindOfClass:NSButton.class]) {
                    HaskeLUITestFail(@"popover command button has no native peer");
                  } else {
                    [(NSButton *)popoverButton.view performClick:nil];
                  }

                  HaskeLUITestAfter(0.18, ^{
                    HaskeLUIMacControlHandle *popover = HaskeLUIState.controls[@(popoverIdentity)];
                    if (popover == nil || popover.popover == nil || !popover.popover.shown ||
                        !popover.presentationVisible) {
                      HaskeLUITestFail([NSString stringWithFormat:
                          @"desired popover state did not remain anchored and visible "
                           "(handle=%d, peer=%d, shown=%d, desired=%d, appActive=%d, anchorWindow=%d)",
                          popover != nil,
                          popover.popover != nil,
                          popover.popover.shown,
                          popover.presentationVisible,
                          NSApplication.sharedApplication.active,
                          popoverButton.view.window != nil]);
                    } else {
                      [popover.popover performClose:nil];
                    }

                    HaskeLUITestAfter(0.35, ^{
                      HaskeLUIMacControlHandle *dismissedPopover = HaskeLUIState.controls[@(popoverIdentity)];
                      if (dismissedPopover != nil &&
                          (dismissedPopover.popover != nil || dismissedPopover.presentationVisible)) {
                        HaskeLUITestFail(@"native popover dismissal did not reconcile desired state");
                      }
                      HaskeLUIMacWindowHandle *openWindow = HaskeLUIState.windows[@(windowIdentity)];
                      if (openWindow != nil) {
                        [openWindow.window performClose:nil];
                      }

                      HaskeLUITestAfter(0.70, ^{
                        if (HaskeLUIState != nil) {
                          HaskeLUITestFail(@"control gallery validation timed out before application stop");
                          [NSApplication.sharedApplication stop:nil];
                        }
                      });
                    });
                  });
                });
              });
            });
          });
        });
      });
    });
  });
}

void haskelui_macos_test_schedule_text_editor_script(
    uint64_t documentWindowIdentity,
    uint64_t editorIdentity,
    uint64_t tabIdentity,
    uint64_t saveCommandIdentity,
    uint64_t openFolderCommandIdentity) {
  HaskeLUIAssertMainThread();

  HaskeLUITestAfter(0.10, ^{
    HaskeLUIMacWindowHandle *documentWindow = HaskeLUIState.windows[@(documentWindowIdentity)];
    HaskeLUIMacControlHandle *editorHandle = HaskeLUIState.controls[@(editorIdentity)];
    HaskeLUIMacTabHandle *tabHandle = nil;
    HaskeLUIMacTabGroupHandle *documentTabGroup = nil;
    for (HaskeLUIMacTabGroupHandle *group in documentWindow.tabGroups.allValues) {
      tabHandle = group.tabs[@(tabIdentity)];
      if (tabHandle != nil) {
        documentTabGroup = group;
        break;
      }
    }
    NSMenuItem *saveItem = HaskeLUIState.commandItems[@(saveCommandIdentity)];
    NSMenuItem *openFolderItem = HaskeLUIState.commandItems[@(openFolderCommandIdentity)];
    if (documentWindow == nil || editorHandle == nil || tabHandle == nil ||
        documentTabGroup == nil || saveItem == nil ||
        openFolderItem == nil ||
        editorHandle.kind != HaskeLUIMacControlKindTextEditor) {
      HaskeLUITestFail(@"native workspace, document tab, or text editor was not registered");
      [NSApplication.sharedApplication stop:nil];
      return;
    }
    if (documentWindow.workspaceSplit == nil ||
        documentWindow.workspaceSplit.subviews.count != 3 ||
        documentWindow.workspaceStatus == nil || tabHandle.contentView.hidden) {
      HaskeLUITestFail(@"native workspace split, status area, or selected tab is incorrect");
    }
    NSArray<NSView *> *tabHeaders = documentTabGroup.tabBar.arrangedSubviews;
    if (tabHeaders.count != 3) {
      HaskeLUITestFail(@"native multi-document fixture did not render all three tabs");
    } else {
      CGFloat expectedLeadingEdge = documentTabGroup.tabBar.edgeInsets.left;
      CGFloat previousMaxX = expectedLeadingEdge - documentTabGroup.tabBar.spacing;
      for (NSView *tabHeader in tabHeaders) {
        CGFloat actualMinX = NSMinX(tabHeader.frame);
        if (actualMinX > previousMaxX + documentTabGroup.tabBar.spacing + 1) {
          HaskeLUITestFail(@"native document tabs were split across the tab bar instead of leading-packed");
          break;
        }
        previousMaxX = NSMaxX(tabHeader.frame);
      }
    }
    NSTextView *editor = (NSTextView *)editorHandle.focusView;
    NSString *expectedIdentifier =
        [NSString stringWithFormat:@"haskelui-control-%llu", editorIdentity];
    if (![editor.accessibilityIdentifier isEqualToString:expectedIdentifier] ||
        ![editor.accessibilityRole isEqualToString:NSAccessibilityTextAreaRole]) {
      HaskeLUITestFail(@"native text editor accessibility identity or role is incorrect");
    }
    if (![editor.string isEqualToString:@"😀 module Initial where\n"]) {
      HaskeLUITestFail([NSString stringWithFormat:
          @"native text editor did not retain the Unicode fixture (actual=%@)",
          editor.string]);
    } else {
      NSColor *editorBackground =
          [editor.backgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
      BOOL systemIsDark = [HaskeLUISystemColorScheme() isEqualToString:@"dark"];
      CGFloat backgroundLuminance = editorBackground == nil
          ? (systemIsDark ? 1.0 : 0.0)
          : 0.2126 * editorBackground.redComponent +
                0.7152 * editorBackground.greenComponent +
                0.0722 * editorBackground.blueComponent;
      if ((systemIsDark && backgroundLuminance >= 0.5) ||
          (!systemIsDark && backgroundLuminance < 0.5)) {
        HaskeLUITestFail([NSString stringWithFormat:
            @"native text editor palette did not follow the system appearance "
             "(system=%@ background=%@ luminance=%.3f)",
            HaskeLUISystemColorScheme(),
            editor.backgroundColor,
            backgroundLuminance]);
      }
      NSDictionary<NSAttributedStringKey, id> *baseAttributes =
          [editor.layoutManager temporaryAttributesAtCharacterIndex:2 effectiveRange:NULL];
      NSDictionary<NSAttributedStringKey, id> *keywordAttributes =
          [editor.layoutManager temporaryAttributesAtCharacterIndex:3 effectiveRange:NULL];
      NSColor *baseColor = baseAttributes[NSForegroundColorAttributeName];
      if (baseColor == nil) {
        baseColor = editor.textColor;
      }
      NSColor *keywordColor = keywordAttributes[NSForegroundColorAttributeName];
      if (baseColor == nil || keywordColor == nil || [baseColor isEqual:keywordColor]) {
        HaskeLUITestFail(@"Unicode scalar ranges were not translated to the highlighted AppKit range");
      }
    }
    NSRange requestedNavigation = NSMakeRange(3, 6);
    if (!haskelui_macos_text_editor_navigate(
            (__bridge HaskeLUIMacControlRef)editorHandle,
            requestedNavigation.location,
            requestedNavigation.length,
            1,
            1) ||
        !NSEqualRanges(editor.selectedRange, requestedNavigation) ||
        !HaskeLUIResponderBelongsToView(documentWindow.window.firstResponder, editor)) {
      HaskeLUITestFail(@"native text navigation did not select, reveal, and focus the requested UTF-16 range");
    }

    dispatch_block_t continueTextEditorValidation = ^{
    [tabHandle.selectButton performClick:nil];
    HaskeLUIEmit(HaskeLUIMacEventCommand, openFolderCommandIdentity, @"");
    HaskeLUITestEventually(2.0, ^BOOL{
      return HaskeLUIState.openPanel != nil && HaskeLUIState.openPanel.visible;
    }, ^{
    if (HaskeLUIState.openPanel == nil || !HaskeLUIState.openPanel.visible ||
        !HaskeLUIState.openPanel.canChooseDirectories || HaskeLUIState.openPanel.canChooseFiles ||
        HaskeLUIState.openPanel.allowsMultipleSelection) {
      HaskeLUITestFail([NSString stringWithFormat:
          @"Open Folder command did not produce a single-directory native panel "
           "(panel=%d visible=%d directories=%d files=%d multiple=%d)",
          HaskeLUIState.openPanel != nil,
          HaskeLUIState.openPanel.visible,
          HaskeLUIState.openPanel.canChooseDirectories,
          HaskeLUIState.openPanel.canChooseFiles,
          HaskeLUIState.openPanel.allowsMultipleSelection]);
    }
    [HaskeLUIState.openPanel cancel:nil];
    haskelui_macos_open_text_files();
    if (HaskeLUIState.openPanel == nil || !HaskeLUIState.openPanel.visible) {
      HaskeLUITestFail(@"native multi-file Open panel did not become visible");
    }
    [HaskeLUIState.openPanel cancel:nil];
    [documentWindow.window makeKeyAndOrderFront:nil];
    if (![documentWindow.window makeFirstResponder:editor] ||
        !HaskeLUIResponderBelongsToView(documentWindow.window.firstResponder, editor)) {
      HaskeLUITestFail(@"native text editor could not become first responder");
    }

    editor.string = @"module Saved where\nanswer = 42\n";
    NSRange expectedSelection = NSMakeRange(7, 5);
    editor.selectedRange = expectedSelection;
    [editor.undoManager removeAllActions];
    [editor.delegate textDidChange:
        [NSNotification notificationWithName:NSTextDidChangeNotification object:editor]];

    HaskeLUITestEventually(2.0, ^BOOL{
      HaskeLUIMacWindowHandle *candidateWindow =
          HaskeLUIState.windows[@(documentWindowIdentity)];
      NSMenuItem *candidateSaveItem =
          HaskeLUIState.commandItems[@(saveCommandIdentity)];
      HaskeLUIMacControlHandle *candidateEditorHandle =
          HaskeLUIState.controls[@(editorIdentity)];
      if (candidateWindow == nil || candidateSaveItem == nil ||
          candidateEditorHandle == nil ||
          ![candidateWindow.window.title containsString:@"Edited"] ||
          !candidateSaveItem.enabled) {
        return NO;
      }
      NSTextView *candidateEditor = (NSTextView *)candidateEditorHandle.focusView;
      NSDictionary<NSAttributedStringKey, id> *candidateKeywordAttributes =
          [candidateEditor.layoutManager
              temporaryAttributesAtCharacterIndex:0
                                     effectiveRange:NULL];
      return candidateKeywordAttributes[NSForegroundColorAttributeName] != nil;
    }, ^{
      HaskeLUIMacWindowHandle *editedWindow = HaskeLUIState.windows[@(documentWindowIdentity)];
      NSMenuItem *enabledSaveItem = HaskeLUIState.commandItems[@(saveCommandIdentity)];
      if (editedWindow == nil || enabledSaveItem == nil) {
        HaskeLUITestFail(@"text editor scene disappeared after native edit callback");
        [NSApplication.sharedApplication stop:nil];
        return;
      }
      if (![editedWindow.window.title containsString:@"Edited"] || !enabledSaveItem.enabled) {
        HaskeLUITestFail(@"native text edit did not reconcile dirty document state");
      }
      HaskeLUIMacControlHandle *editedEditorHandle = HaskeLUIState.controls[@(editorIdentity)];
      NSTextView *editedEditor = (NSTextView *)editedEditorHandle.focusView;
      NSDictionary<NSAttributedStringKey, id> *baseAttributes =
          [editedEditor.layoutManager temporaryAttributesAtCharacterIndex:6 effectiveRange:NULL];
      NSDictionary<NSAttributedStringKey, id> *keywordAttributes =
          [editedEditor.layoutManager temporaryAttributesAtCharacterIndex:0 effectiveRange:NULL];
      NSColor *baseColor = baseAttributes[NSForegroundColorAttributeName];
      if (baseColor == nil) {
        baseColor = editedEditor.textColor;
      }
      NSColor *keywordColor = keywordAttributes[NSForegroundColorAttributeName];
      if (baseColor == nil || keywordColor == nil || [baseColor isEqual:keywordColor]) {
        HaskeLUITestFail(@"syntax presentation was not refreshed after a native edit");
      }
      if (!NSEqualRanges(editedEditor.selectedRange, expectedSelection)) {
        HaskeLUITestFail([NSString stringWithFormat:
            @"syntax presentation changed the native selection (expected=%@ actual=%@)",
            NSStringFromRange(expectedSelection),
            NSStringFromRange(editedEditor.selectedRange)]);
      }
      if (editedEditor.undoManager.canUndo) {
        HaskeLUITestFail(@"syntax presentation created a native undo action");
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
        HaskeLUITestFail(@"text editor Save command did not handle Command-S");
      }

      HaskeLUITestEventually(2.0, ^BOOL{
        HaskeLUIMacWindowHandle *candidateWindow =
            HaskeLUIState.windows[@(documentWindowIdentity)];
        NSMenuItem *candidateSaveItem =
            HaskeLUIState.commandItems[@(saveCommandIdentity)];
        return candidateWindow != nil && candidateSaveItem != nil &&
            ![candidateWindow.window.title containsString:@"Edited"] &&
            !candidateSaveItem.enabled;
      }, ^{
        HaskeLUIMacWindowHandle *savedWindow = HaskeLUIState.windows[@(documentWindowIdentity)];
        NSMenuItem *disabledSaveItem = HaskeLUIState.commandItems[@(saveCommandIdentity)];
        if (savedWindow == nil || disabledSaveItem == nil) {
          HaskeLUITestFail(@"text editor scene disappeared after Save");
          [NSApplication.sharedApplication stop:nil];
          return;
        }
        if ([savedWindow.window.title containsString:@"Edited"] || disabledSaveItem.enabled) {
          HaskeLUITestFail(@"successful file write did not reconcile saved document state");
        }
        HaskeLUIMacTabHandle *savedTab = nil;
        for (HaskeLUIMacTabGroupHandle *group in savedWindow.tabGroups.allValues) {
          savedTab = group.tabs[@(tabIdentity)];
          if (savedTab != nil) {
            break;
          }
        }
        if (savedTab == nil) {
          HaskeLUITestFail(@"saved document tab disappeared before close-button validation");
          [NSApplication.sharedApplication stop:nil];
          return;
        }
        [savedTab.closeButton performClick:nil];

        HaskeLUITestEventually(2.0, ^BOOL{
          HaskeLUIMacWindowHandle *candidateWindow =
              HaskeLUIState.windows[@(documentWindowIdentity)];
          if (candidateWindow == nil) {
            return NO;
          }
          for (HaskeLUIMacTabGroupHandle *group in candidateWindow.tabGroups.allValues) {
            if (group.tabs[@(tabIdentity)] != nil) {
              return NO;
            }
          }
          return YES;
        }, ^{
          HaskeLUIMacWindowHandle *emptyWorkspace = HaskeLUIState.windows[@(documentWindowIdentity)];
          BOOL tabStillPresent = NO;
          for (HaskeLUIMacTabGroupHandle *group in emptyWorkspace.tabGroups.allValues) {
            if (group.tabs[@(tabIdentity)] != nil) {
              tabStillPresent = YES;
            }
          }
          if (emptyWorkspace == nil || tabStillPresent) {
            HaskeLUITestFail(@"clean tab close did not retain the workspace and remove only the tab");
            [NSApplication.sharedApplication stop:nil];
            return;
          }
          [emptyWorkspace.window performClose:nil];

          HaskeLUITestEventually(2.0, ^BOOL{
            return HaskeLUIState == nil ||
                HaskeLUIState.windows[@(documentWindowIdentity)] == nil;
          }, ^{
            if (HaskeLUIState != nil && HaskeLUIState.windows[@(documentWindowIdentity)] != nil) {
              HaskeLUITestFail(@"empty workspace close request did not remove its native window");
              [NSApplication.sharedApplication stop:nil];
            } else if (HaskeLUIState != nil) {
              [NSApplication.sharedApplication stop:nil];
            }
          });
        });
      });
    });
    });
    };

    HaskeLUIMacTabHandle *otherTab = nil;
    for (NSNumber *candidateKey in documentTabGroup.tabs) {
      if (candidateKey.unsignedLongLongValue != tabIdentity) {
        otherTab = documentTabGroup.tabs[candidateKey];
        break;
      }
    }
    NSSplitView *workspaceSplit = documentWindow.workspaceSplit;
    NSView *navigatorPane = workspaceSplit.subviews.firstObject;
    NSView *inspectorPane = workspaceSplit.subviews.lastObject;
    if (otherTab == nil || navigatorPane == nil || inspectorPane == nil) {
      HaskeLUITestFail(@"native pane resize test could not locate another tab or sidebar");
      [NSApplication.sharedApplication stop:nil];
      return;
    }
    documentWindow.workspaceTestingPaneResize = YES;
    [workspaceSplit setPosition:40 ofDividerAtIndex:0];
    [workspaceSplit
        setPosition:NSWidth(workspaceSplit.bounds) - 40
        ofDividerAtIndex:workspaceSplit.subviews.count - 2];
    if (NSWidth(navigatorPane.frame) < 159 || NSWidth(inspectorPane.frame) < 179) {
      HaskeLUITestFail([NSString stringWithFormat:
          @"native pane minimum extents were not enforced "
           "(navigator=%.1f inspector=%.1f)",
          NSWidth(navigatorPane.frame),
          NSWidth(inspectorPane.frame)]);
    }
    [workspaceSplit setPosition:300 ofDividerAtIndex:0];
    [workspaceSplit
        setPosition:NSWidth(workspaceSplit.bounds) - 340
        ofDividerAtIndex:workspaceSplit.subviews.count - 2];
    documentWindow.workspaceTestingPaneResize = NO;
    CGFloat expectedNavigatorExtent = NSWidth(navigatorPane.frame);
    CGFloat expectedInspectorExtent = NSWidth(inspectorPane.frame);

    HaskeLUITestAfter(0.15, ^{
      [otherTab.selectButton performClick:nil];
      HaskeLUITestEventually(2.0, ^BOOL{
        return !otherTab.contentView.hidden &&
            fabs(NSWidth(navigatorPane.frame) - expectedNavigatorExtent) <= 1 &&
            fabs(NSWidth(inspectorPane.frame) - expectedInspectorExtent) <= 1;
      }, ^{
        if (fabs(NSWidth(navigatorPane.frame) - expectedNavigatorExtent) > 1 ||
            fabs(NSWidth(inspectorPane.frame) - expectedInspectorExtent) > 1) {
          HaskeLUITestFail([NSString stringWithFormat:
              @"native pane resize did not survive a document-tab switch "
               "(navigator expected=%.1f actual=%.1f, inspector expected=%.1f actual=%.1f)",
              expectedNavigatorExtent,
              NSWidth(navigatorPane.frame),
              expectedInspectorExtent,
              NSWidth(inspectorPane.frame)]);
        }
        [tabHandle.selectButton performClick:nil];
        HaskeLUITestEventually(2.0, ^BOOL{
          return !tabHandle.contentView.hidden &&
              fabs(NSWidth(navigatorPane.frame) - expectedNavigatorExtent) <= 1 &&
              fabs(NSWidth(inspectorPane.frame) - expectedInspectorExtent) <= 1;
        }, ^{
          if (fabs(NSWidth(navigatorPane.frame) - expectedNavigatorExtent) > 1 ||
              fabs(NSWidth(inspectorPane.frame) - expectedInspectorExtent) > 1) {
            HaskeLUITestFail(@"native pane resize was lost when returning to the original tab");
          }
          continueTextEditorValidation();
        });
      });
    });
  });
}

void haskelui_macos_test_schedule_explorer_script(
    uint64_t workspaceWindowIdentity,
    uint64_t projectTreeIdentity,
    uint64_t fileItemIdentity,
    uint64_t expectedTabIdentity) {
  HaskeLUIAssertMainThread();

  HaskeLUITestAfter(0.35, ^{
    HaskeLUIMacWindowHandle *window = HaskeLUIState.windows[@(workspaceWindowIdentity)];
    HaskeLUIMacControlHandle *tree = HaskeLUIState.controls[@(projectTreeIdentity)];
    if (window == nil || tree == nil || tree.outlineAdapter == nil) {
      HaskeLUITestFail(@"Visual Haskell project outline was not registered");
      [NSApplication.sharedApplication stop:nil];
      return;
    }

    NSOutlineView *outline = tree.outlineAdapter.outline;
    NSInteger fileRow = -1;
    for (NSInteger row = 0; row < outline.numberOfRows; row += 1) {
      HaskeLUIMacOutlineNode *node = [outline itemAtRow:row];
      if ([node.value[@"identity"] unsignedLongLongValue] == fileItemIdentity) {
        fileRow = row;
        break;
      }
    }
    if (fileRow < 0) {
      HaskeLUITestFail(@"Visual Haskell project file row was not visible");
      [NSApplication.sharedApplication stop:nil];
      return;
    }

    [window.window makeKeyAndOrderFront:nil];
    [window.window makeFirstResponder:outline];
    [outline selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)fileRow]
         byExtendingSelection:NO];
    [outline sendAction:outline.action to:outline.target];

    HaskeLUITestAfter(0.40, ^{
      HaskeLUIMacWindowHandle *updatedWindow = HaskeLUIState.windows[@(workspaceWindowIdentity)];
      HaskeLUIMacTabHandle *openedTab = nil;
      for (HaskeLUIMacTabGroupHandle *group in updatedWindow.tabGroups.allValues) {
        openedTab = group.tabs[@(expectedTabIdentity)];
        if (openedTab != nil) {
          break;
        }
      }
      if (updatedWindow == nil || openedTab == nil || openedTab.contentView.hidden) {
        HaskeLUITestFail(@"selecting a native project file did not open and activate its tab");
        [NSApplication.sharedApplication stop:nil];
        return;
      }

      [updatedWindow.window performClose:nil];
      HaskeLUITestAfter(0.20, ^{
        if (HaskeLUIState != nil && HaskeLUIState.windows[@(workspaceWindowIdentity)] != nil) {
          HaskeLUITestFail(@"clean explorer fixture did not close its workspace");
        }
        if (HaskeLUIState != nil) {
          [NSApplication.sharedApplication stop:nil];
        }
      });
    });
  });
}

void haskelui_macos_test_schedule_drawing_script(
    uint64_t windowIdentity,
    uint64_t drawingSurfaceIdentity) {
  HaskeLUIAssertMainThread();
  HaskeLUITestAfter(0.15, ^{
    HaskeLUIMacWindowHandle *window = HaskeLUIState.windows[@(windowIdentity)];
    HaskeLUIMacControlHandle *control = HaskeLUIState.controls[@(drawingSurfaceIdentity)];
    if (window == nil || control == nil ||
        control.kind != HaskeLUIMacControlKindDrawing ||
        ![control.view isKindOfClass:HaskeLUIDrawingView.class]) {
      HaskeLUITestFail(@"drawing gallery did not create its native drawing surface");
      [NSApplication.sharedApplication stop:nil];
      return;
    }
    HaskeLUIDrawingView *view = (HaskeLUIDrawingView *)control.view;
    if (!view.isFlipped) {
      HaskeLUITestFail(@"drawing surface does not use portable top-left coordinates");
    }
    if (view.drawingCommands.count < 60) {
      HaskeLUITestFail(@"drawing surface did not retain the complete primitive display list");
    }
    if (![view.accessibilityRole isEqualToString:NSAccessibilityImageRole] ||
        view.accessibilityLabel.length == 0) {
      HaskeLUITestFail(@"drawing surface accessibility metadata is incomplete");
    }
    if (!view.drawingInputEnabled || view.drawingTrackingArea == nil) {
      HaskeLUITestFail(@"drawing surface did not install native pointer tracking");
    }
    [window.window makeKeyAndOrderFront:nil];
    [window.window displayIfNeeded];
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    if (bitmap == nil) {
      HaskeLUITestFail(@"AppKit could not allocate an offscreen drawing-surface snapshot");
    } else {
      [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
      NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
      if (png.length == 0) {
        HaskeLUITestFail(@"drawing surface paint pass produced no bitmap data");
      }
    }
    uint64_t initialGeneration = view.drawingPresentationGeneration;
    NSPoint downLocation = [view convertPoint:NSMakePoint(150, 466) toView:nil];
    NSPoint dragLocation = [view convertPoint:NSMakePoint(190, 490) toView:nil];
    NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                      location:downLocation
                                 modifierFlags:0
                                     timestamp:NSProcessInfo.processInfo.systemUptime
                                  windowNumber:window.window.windowNumber
                                       context:nil
                                   eventNumber:1
                                    clickCount:1
                                      pressure:1.0];
    NSEvent *drag = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged
                                      location:dragLocation
                                 modifierFlags:0
                                     timestamp:NSProcessInfo.processInfo.systemUptime
                                  windowNumber:window.window.windowNumber
                                       context:nil
                                   eventNumber:2
                                    clickCount:1
                                      pressure:1.0];
    NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                    location:dragLocation
                               modifierFlags:0
                                   timestamp:NSProcessInfo.processInfo.systemUptime
                                windowNumber:window.window.windowNumber
                                     context:nil
                                 eventNumber:3
                                  clickCount:1
                                    pressure:0.0];
    [view mouseDown:down];
    [view mouseDragged:drag];
    [view mouseUp:up];
    /* Let typed callbacks drain, reconcile the advanced drawing revision, and
       then leave through the normal backend shutdown path. */
    HaskeLUITestAfter(0.15, ^{
      if (view.drawingPresentationGeneration <= initialGeneration) {
        HaskeLUITestFail(@"native drawing pointer input did not update the Haskell model and display list");
      }
      [NSApplication.sharedApplication stop:nil];
    });
  });
}
