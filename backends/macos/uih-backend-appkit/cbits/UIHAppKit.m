#import "UIHAppKit.h"
#import "compat/UIHAppKitCompatibility.h"

#import <dispatch/dispatch.h>

_Static_assert(sizeof(UIHMacTextStyle) == 120, "UIHMacTextStyle ABI must match its Haskell Storable instance");

typedef NS_ENUM(NSInteger, UIHMacControlKind) {
  UIHMacControlKindLabel,
  UIHMacControlKindButton,
  UIHMacControlKindTextField,
  UIHMacControlKindTextEditor,
  UIHMacControlKindCatalog
};

@class UIHMacWindowHandle;
@class UIHMacControlHandle;
@class UIHMacTabGroupHandle;
@class UIHMacTabHandle;

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

static NSColor *UIHColor(double red, double green, double blue, double alpha);

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
@property(nonatomic, copy) NSString *fixedPayload;
@property(nonatomic, assign) uint64_t secondaryIdentity;
@property(nonatomic, assign) int32_t secondaryEventKind;
- (void)performAction:(id)sender;
@end

@implementation UIHMacActionTarget
- (void)performAction:(id)sender {
  NSString *payload = self.fixedPayload ?: @"";
  if (self.fixedPayload == nil) {
    if (self.eventKind == UIHMacEventToggleChanged ||
        self.eventKind == UIHMacEventDisclosureChanged) {
      payload = [NSString stringWithFormat:@"%ld", (long)((NSControl *)sender).integerValue];
    } else if (self.eventKind == UIHMacEventNumberChanged) {
      payload = [NSString stringWithFormat:@"%.17g", ((NSControl *)sender).doubleValue];
    } else if (self.eventKind == UIHMacEventChoiceChanged) {
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
    } else if (self.eventKind == UIHMacEventDateChanged ||
               self.eventKind == UIHMacEventTimeChanged) {
      NSDatePicker *picker = sender;
      NSDateComponents *parts = [[NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian]
          components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                      NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond)
          fromDate:picker.dateValue];
      payload = [NSString stringWithFormat:@"%04ld-%02ld-%02ldT%02ld:%02ld:%02ld",
          (long)parts.year, (long)parts.month, (long)parts.day,
          (long)parts.hour, (long)parts.minute, (long)parts.second];
    } else if (self.eventKind == UIHMacEventColorChanged) {
      NSColor *color = [((NSColorWell *)sender).color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
      payload = [NSString stringWithFormat:@"%.17g,%.17g,%.17g,%.17g",
          color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent];
    }
  }
  UIHEmit(self.eventKind, self.identity, payload);
  if (self.secondaryEventKind != 0) {
    UIHEmit(self.secondaryEventKind, self.secondaryIdentity, @"");
  }
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

@interface UIHMacCollectionAdapter : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *items;
@property(nonatomic, weak) NSTableView *table;
@property(nonatomic, assign) BOOL suppressSelectionEvent;
@property(nonatomic, assign) BOOL showsDepth;
@property(nonatomic, assign) BOOL navigationStyle;
@end

@implementation UIHMacCollectionAdapter
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
  NSTextField *field = [NSTextField labelWithString:value ?: @""];
  field.lineBreakMode = NSLineBreakByTruncatingTail;
  field.textColor = [item[@"enabled"] boolValue]
      ? NSColor.labelColor
      : NSColor.disabledControlTextColor;
  return field;
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
  UIHEmit(UIHMacEventCollectionSelectionChanged, self.identity,
          [keys componentsJoinedByString:@","]);
}
@end

@interface UIHMacGridItem : NSCollectionViewItem
@property(nonatomic, strong) NSBox *card;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *detailLabel;
@end

@implementation UIHMacGridItem
- (void)loadView {
  NSBox *card = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 150, 66)];
  card.boxType = NSBoxCustom;
  card.borderWidth = 1;
  card.cornerRadius = 7;
  card.fillColor = NSColor.controlBackgroundColor;
  NSTextField *title = [NSTextField labelWithString:@""];
  title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
  title.frame = NSMakeRect(10, 34, 130, 20);
  title.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  NSTextField *detail = [NSTextField labelWithString:@""];
  detail.textColor = NSColor.secondaryLabelColor;
  detail.font = [NSFont systemFontOfSize:11];
  detail.frame = NSMakeRect(10, 10, 130, 18);
  detail.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  [card.contentView addSubview:title];
  [card.contentView addSubview:detail];
  self.card = card;
  self.titleLabel = title;
  self.detailLabel = detail;
  self.view = card;
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

@interface UIHMacGridAdapter : NSObject <NSCollectionViewDataSource, NSCollectionViewDelegate>
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *items;
@property(nonatomic, weak) NSCollectionView *collection;
@property(nonatomic, assign) BOOL suppressSelectionEvent;
@property(nonatomic, assign) BOOL repeater;
@end

@implementation UIHMacGridAdapter
- (NSInteger)collectionView:(NSCollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section {
  (void)collectionView;
  (void)section;
  return self.items.count;
}

- (NSCollectionViewItem *)collectionView:(NSCollectionView *)collectionView
    itemForRepresentedObjectAtIndexPath:(NSIndexPath *)indexPath {
  UIHMacGridItem *item = (UIHMacGridItem *)[collectionView
      makeItemWithIdentifier:@"UIHGridItem"
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
  UIHEmit(UIHMacEventCollectionSelectionChanged, self.identity,
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

@interface UIHMacOutlineNode : NSObject
@property(nonatomic, strong) NSDictionary *value;
@property(nonatomic, strong) NSMutableArray<UIHMacOutlineNode *> *children;
@end

@implementation UIHMacOutlineNode
@end

@interface UIHMacOutlineAdapter : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *items;
@property(nonatomic, strong) NSMutableArray<UIHMacOutlineNode *> *roots;
@property(nonatomic, weak) NSOutlineView *outline;
@property(nonatomic, assign) BOOL suppressEvents;
- (void)reload;
@end

@implementation UIHMacOutlineAdapter
- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
  (void)outlineView;
  return item == nil ? self.roots.count : ((UIHMacOutlineNode *)item).children.count;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
  (void)outlineView;
  return item == nil ? self.roots[(NSUInteger)index]
                     : ((UIHMacOutlineNode *)item).children[(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
  (void)outlineView;
  return ((UIHMacOutlineNode *)item).children.count > 0;
}

- (NSView *)outlineView:(NSOutlineView *)outlineView
    viewForTableColumn:(NSTableColumn *)tableColumn
                  item:(id)item {
  (void)outlineView;
  (void)tableColumn;
  UIHMacOutlineNode *node = item;
  NSTextField *field = [NSTextField labelWithString:node.value[@"label"] ?: @""];
  field.lineBreakMode = NSLineBreakByTruncatingTail;
  return field;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldSelectItem:(id)item {
  (void)outlineView;
  return [((UIHMacOutlineNode *)item).value[@"enabled"] boolValue];
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
  if (self.suppressEvents) {
    return;
  }
  NSOutlineView *outline = notification.object;
  NSMutableArray<NSString *> *keys = [[NSMutableArray alloc] init];
  [outline.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
    (void)stop;
    UIHMacOutlineNode *node = [outline itemAtRow:(NSInteger)row];
    if (node != nil) {
      [keys addObject:[node.value[@"identity"] stringValue]];
    }
  }];
  UIHEmit(UIHMacEventCollectionSelectionChanged, self.identity,
          [keys componentsJoinedByString:@","]);
}

- (void)emitExpansion:(NSNotification *)notification expanded:(BOOL)expanded {
  if (self.suppressEvents) {
    return;
  }
  UIHMacOutlineNode *node = notification.userInfo[@"NSObject"] ?: notification.object;
  if (![node isKindOfClass:UIHMacOutlineNode.class]) {
    return;
  }
  NSString *payload = [NSString stringWithFormat:@"%@,%d",
      [node.value[@"identity"] stringValue], expanded ? 1 : 0];
  UIHEmit(UIHMacEventCollectionExpansionChanged, self.identity, payload);
}

- (void)outlineViewItemDidExpand:(NSNotification *)notification {
  [self emitExpansion:notification expanded:YES];
}

- (void)outlineViewItemDidCollapse:(NSNotification *)notification {
  [self emitExpansion:notification expanded:NO];
}

- (void)expandNodes:(NSArray<UIHMacOutlineNode *> *)nodes {
  for (UIHMacOutlineNode *node in nodes) {
    if ([node.value[@"expanded"] boolValue]) {
      [self.outline expandItem:node];
    }
    [self expandNodes:node.children];
  }
}

- (void)reload {
  [self.roots removeAllObjects];
  NSMutableArray<UIHMacOutlineNode *> *stack = [[NSMutableArray alloc] init];
  for (NSDictionary *value in self.items) {
    UIHMacOutlineNode *node = [[UIHMacOutlineNode alloc] init];
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
    UIHMacOutlineNode *node = [self.outline itemAtRow:row];
    if ([node.value[@"selected"] boolValue]) {
      [selected addIndex:(NSUInteger)row];
    }
  }
  [self.outline selectRowIndexes:selected byExtendingSelection:NO];
  self.suppressEvents = NO;
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
@property(nonatomic, strong) NSView *workspaceRoot;
@property(nonatomic, strong) NSSplitView *workspaceSplit;
@property(nonatomic, strong) NSView *workspaceStatus;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSView *> *workspacePanes;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *workspacePaneRoles;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *workspacePaneExtents;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSView *> *workspaceItems;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, UIHMacTabGroupHandle *> *tabGroups;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *seenPanes;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *seenItems;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *seenTabGroups;
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

@interface UIHMacTabHandle : NSObject
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, strong) NSStackView *tabHeader;
@property(nonatomic, strong) NSButton *selectButton;
@property(nonatomic, strong) NSButton *closeButton;
@property(nonatomic, strong) NSView *contentView;
@property(nonatomic, strong) UIHMacActionTarget *selectTarget;
@property(nonatomic, strong) UIHMacActionTarget *closeTarget;
@end

@implementation UIHMacTabHandle
@end

@interface UIHMacTabGroupHandle : NSObject
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, strong) NSView *rootView;
@property(nonatomic, strong) NSScrollView *tabScrollView;
@property(nonatomic, strong) NSStackView *tabBar;
@property(nonatomic, strong) NSView *contentHost;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, UIHMacTabHandle *> *tabs;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *seenTabs;
@property(nonatomic, strong) NSNumber *selectedTab;
@end

@implementation UIHMacTabGroupHandle
@end

@interface UIHMacControlHandle : NSObject <NSPopoverDelegate>
@property(nonatomic, assign) uint64_t identity;
@property(nonatomic, strong) NSView *view;
@property(nonatomic, strong) NSView *focusView;
@property(nonatomic, assign) NSRect desiredFrame;
@property(nonatomic, strong) UIHMacActionTarget *target;
@property(nonatomic, assign) UIHMacControlKind kind;
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
@property(nonatomic, strong) NSMutableArray<UIHMacActionTarget *> *itemTargets;
@property(nonatomic, strong) UIHMacCollectionAdapter *collectionAdapter;
@property(nonatomic, strong) UIHMacGridAdapter *gridAdapter;
@property(nonatomic, strong) UIHMacOutlineAdapter *outlineAdapter;
@property(nonatomic, strong) NSWindow *presentationWindow;
@property(nonatomic, strong) NSPopover *popover;
@property(nonatomic, assign) BOOL presentationVisible;
@property(nonatomic, assign) uint64_t commandIdentity;
@property(nonatomic, assign) int32_t collectionSelectionMode;
@property(nonatomic, assign) int32_t containerState;
@property(nonatomic, copy) NSString *primaryText;
@property(nonatomic, copy) NSString *secondaryText;
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

- (void)finishPopoverDismissal {
  BOOL wasPresented = self.presentationVisible;
  self.presentationVisible = NO;
  self.popover = nil;
  if (wasPresented) {
    UIHEmit(UIHMacEventPresentationClosed, self.identity, @"dismissed");
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
  handle.workspacePanes = [[NSMutableDictionary alloc] init];
  handle.workspacePaneRoles = [[NSMutableDictionary alloc] init];
  handle.workspacePaneExtents = [[NSMutableDictionary alloc] init];
  handle.workspaceItems = [[NSMutableDictionary alloc] init];
  handle.tabGroups = [[NSMutableDictionary alloc] init];
  handle.seenPanes = [[NSMutableSet alloc] init];
  handle.seenItems = [[NSMutableSet alloc] init];
  handle.seenTabGroups = [[NSMutableSet alloc] init];
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

static void UIHReleaseTab(UIHMacTabHandle *tab) {
  [tab.tabHeader removeFromSuperview];
  [tab.contentView removeFromSuperview];
  if (tab.selectTarget != nil) {
    tab.selectButton.target = nil;
    tab.selectTarget = nil;
    UIHLiveActionTargets -= 1;
  }
  if (tab.closeTarget != nil) {
    tab.closeButton.target = nil;
    tab.closeTarget = nil;
    UIHLiveActionTargets -= 1;
  }
}

static void UIHReleaseTabGroup(UIHMacTabGroupHandle *group) {
  for (UIHMacTabHandle *tab in group.tabs.allValues) {
    UIHReleaseTab(tab);
  }
  [group.tabs removeAllObjects];
  [group.rootView removeFromSuperview];
}

void uih_macos_window_destroy(UIHMacWindowRef reference) {
  UIHAssertMainThread();
  if (reference == NULL) {
    return;
  }
  UIHMacWindowHandle *handle = (__bridge_transfer UIHMacWindowHandle *)reference;
  [UIHState.windows removeObjectForKey:@(handle.identity)];
  for (UIHMacTabGroupHandle *group in handle.tabGroups.allValues) {
    UIHReleaseTabGroup(group);
  }
  [handle.tabGroups removeAllObjects];
  [handle.workspaceRoot removeFromSuperview];
  handle.window.delegate = nil;
  [handle.window orderOut:nil];
  [handle.window close];
  if (handle.delegate != nil) {
    handle.delegate = nil;
    UIHLiveWindowDelegates -= 1;
  }
  handle.window = nil;
}

static NSView *UIHWorkspacePaneView(int32_t role) {
  if (role == 0 || role == 2) {
    NSVisualEffectView *view = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    view.material = role == 0 ? NSVisualEffectMaterialSidebar : NSVisualEffectMaterialContentBackground;
    view.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    view.state = NSVisualEffectStateFollowsWindowActiveState;
    return view;
  }
  return [[NSView alloc] initWithFrame:NSZeroRect];
}

static void UIHFillView(NSView *view, NSView *parent) {
  if (view.superview != parent) {
    [view removeFromSuperview];
    [parent addSubview:view];
  }
  view.frame = parent.bounds;
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}

void uih_macos_workspace_begin(
    UIHMacWindowRef reference,
    int32_t sideBySide,
    double statusHeight) {
  UIHAssertMainThread();
  UIHMacWindowHandle *handle = UIHWindow(reference);
  NSView *content = handle.window.contentView;
  CGFloat safeStatusHeight = (CGFloat)MAX(0.0, statusHeight);
  if (handle.workspaceRoot == nil) {
    NSView *root = [[NSView alloc] initWithFrame:content.bounds];
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    root.accessibilityElement = YES;
    root.accessibilityRole = NSAccessibilityGroupRole;
    root.accessibilityIdentifier =
        [NSString stringWithFormat:@"uih-workspace-%llu", handle.identity];

    NSSplitView *split = [[NSSplitView alloc] initWithFrame:NSZeroRect];
    split.dividerStyle = NSSplitViewDividerStyleThin;
    split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSVisualEffectView *status = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    status.material = NSVisualEffectMaterialHeaderView;
    status.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    status.state = NSVisualEffectStateFollowsWindowActiveState;
    status.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    status.accessibilityElement = YES;
    status.accessibilityRole = NSAccessibilityGroupRole;
    status.accessibilityIdentifier =
        [NSString stringWithFormat:@"uih-workspace-status-%llu", handle.identity];

    NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, content.bounds.size.width, 1)];
    separator.boxType = NSBoxSeparator;
    separator.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [status addSubview:separator];

    [root addSubview:split];
    [root addSubview:status];
    [content addSubview:root];
    handle.workspaceRoot = root;
    handle.workspaceSplit = split;
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
  for (UIHMacTabGroupHandle *group in handle.tabGroups.allValues) {
    [group.seenTabs removeAllObjects];
    group.selectedTab = nil;
  }
}

void uih_macos_workspace_pane_set(
    UIHMacWindowRef reference,
    uint64_t paneIdentity,
    int32_t paneRole,
    double preferredExtent,
    int32_t collapsed) {
  UIHAssertMainThread();
  UIHMacWindowHandle *handle = UIHWindow(reference);
  NSNumber *key = @(paneIdentity);
  NSView *pane = handle.workspacePanes[key];
  NSNumber *oldRole = handle.workspacePaneRoles[key];
  if (pane == nil || oldRole.intValue != paneRole) {
    NSView *oldPane = pane;
    pane = UIHWorkspacePaneView(paneRole);
    pane.accessibilityElement = YES;
    pane.accessibilityRole = NSAccessibilityGroupRole;
    pane.accessibilityIdentifier =
        [NSString stringWithFormat:@"uih-workspace-pane-%llu", paneIdentity];
    for (NSView *child in oldPane.subviews.copy) {
      UIHFillView(child, pane);
    }
    [oldPane removeFromSuperview];
    handle.workspacePanes[key] = pane;
  }
  handle.workspacePaneRoles[key] = @(paneRole);
  handle.workspacePaneExtents[key] = @(MAX(0.0, preferredExtent));
  pane.hidden = collapsed != 0;
  if (pane.superview != handle.workspaceSplit) {
    [handle.workspaceSplit addSubview:pane];
  }
  [handle.seenPanes addObject:key];
}

void uih_macos_workspace_item_set(
    UIHMacWindowRef reference,
    uint64_t paneIdentity,
    uint64_t itemIdentity) {
  UIHAssertMainThread();
  UIHMacWindowHandle *handle = UIHWindow(reference);
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
        [NSString stringWithFormat:@"uih-workspace-item-%llu", itemIdentity];
    handle.workspaceItems[itemKey] = item;
  }
  UIHFillView(item, pane);
  [handle.seenItems addObject:itemKey];
}

static UIHMacTabGroupHandle *UIHEnsureTabGroup(
    UIHMacWindowHandle *window,
    uint64_t identity) {
  NSNumber *key = @(identity);
  UIHMacTabGroupHandle *group = window.tabGroups[key];
  if (group != nil) {
    return group;
  }
  group = [[UIHMacTabGroupHandle alloc] init];
  group.identity = identity;
  group.tabs = [[NSMutableDictionary alloc] init];
  group.seenTabs = [[NSMutableSet alloc] init];

  NSView *root = [[NSView alloc] initWithFrame:NSZeroRect];
  root.accessibilityElement = YES;
  root.accessibilityRole = NSAccessibilityGroupRole;
  root.accessibilityIdentifier = [NSString stringWithFormat:@"uih-tab-group-%llu", identity];
  NSStackView *bar = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 100, 32)];
  bar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  bar.alignment = NSLayoutAttributeCenterY;
  bar.spacing = 2;
  bar.edgeInsets = NSEdgeInsetsMake(3, 6, 3, 6);
  bar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
  content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [root addSubview:bar];
  [root addSubview:content];
  group.rootView = root;
  group.tabBar = bar;
  group.contentHost = content;
  window.tabGroups[key] = group;
  return group;
}

static void UIHLayoutTabGroup(UIHMacTabGroupHandle *group) {
  CGFloat barHeight = 34;
  NSRect bounds = group.rootView.bounds;
  group.tabBar.frame = NSMakeRect(0, MAX(0, bounds.size.height - barHeight), bounds.size.width, barHeight);
  group.contentHost.frame = NSMakeRect(0, 0, bounds.size.width, MAX(0, bounds.size.height - barHeight));
  for (UIHMacTabHandle *tab in group.tabs.allValues) {
    tab.contentView.frame = group.contentHost.bounds;
  }
}

void uih_macos_workspace_tab_group_set(
    UIHMacWindowRef reference,
    uint64_t itemIdentity,
    uint64_t groupIdentity) {
  UIHAssertMainThread();
  UIHMacWindowHandle *handle = UIHWindow(reference);
  NSView *item = handle.workspaceItems[@(itemIdentity)];
  if (item == nil) {
    return;
  }
  UIHMacTabGroupHandle *group = UIHEnsureTabGroup(handle, groupIdentity);
  UIHFillView(group.rootView, item);
  UIHLayoutTabGroup(group);
  for (UIHMacTabHandle *tab in group.tabs.allValues) {
    [group.tabBar removeArrangedSubview:tab.tabHeader];
    [tab.tabHeader removeFromSuperview];
  }
  [handle.seenTabGroups addObject:@(groupIdentity)];
}

static UIHMacTabHandle *UIHEnsureTab(
    UIHMacTabGroupHandle *group,
    uint64_t identity) {
  NSNumber *key = @(identity);
  UIHMacTabHandle *tab = group.tabs[key];
  if (tab != nil) {
    return tab;
  }
  tab = [[UIHMacTabHandle alloc] init];
  tab.identity = identity;

  UIHMacActionTarget *selectTarget = [[UIHMacActionTarget alloc] init];
  UIHLiveActionTargets += 1;
  selectTarget.identity = identity;
  selectTarget.eventKind = UIHMacEventTabSelected;
  NSButton *selectButton = [NSButton buttonWithTitle:@"" target:selectTarget action:@selector(performAction:)];
  selectButton.bezelStyle = NSBezelStyleTexturedRounded;

  UIHMacActionTarget *closeTarget = [[UIHMacActionTarget alloc] init];
  UIHLiveActionTargets += 1;
  closeTarget.identity = identity;
  closeTarget.eventKind = UIHMacEventTabCloseRequested;
  NSButton *closeButton = [NSButton buttonWithTitle:@"×" target:closeTarget action:@selector(performAction:)];
  closeButton.bezelStyle = NSBezelStyleInline;
  closeButton.toolTip = @"Close";

  NSStackView *header = [NSStackView stackViewWithViews:@[selectButton, closeButton]];
  header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  header.alignment = NSLayoutAttributeCenterY;
  header.spacing = 1;
  NSView *content = [[NSView alloc] initWithFrame:group.contentHost.bounds];
  content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  content.accessibilityElement = YES;
  content.accessibilityRole = NSAccessibilityGroupRole;
  content.accessibilityIdentifier = [NSString stringWithFormat:@"uih-tab-content-%llu", identity];
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

void uih_macos_workspace_tab_set(
    UIHMacWindowRef reference,
    uint64_t groupIdentity,
    uint64_t tabIdentity,
    const char *utf8Title,
    int32_t modified,
    int32_t closeable,
    int32_t selected) {
  UIHAssertMainThread();
  UIHMacWindowHandle *handle = UIHWindow(reference);
  UIHMacTabGroupHandle *group = handle.tabGroups[@(groupIdentity)];
  if (group == nil) {
    return;
  }
  UIHMacTabHandle *tab = UIHEnsureTab(group, tabIdentity);
  if (tab.tabHeader.superview != group.tabBar) {
    [group.tabBar addArrangedSubview:tab.tabHeader];
  }
  NSString *title = UIHString(utf8Title);
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

void uih_macos_workspace_end(UIHMacWindowRef reference) {
  UIHAssertMainThread();
  UIHMacWindowHandle *handle = UIHWindow(reference);

  for (NSNumber *groupKey in handle.tabGroups.allKeys.copy) {
    UIHMacTabGroupHandle *group = handle.tabGroups[groupKey];
    if (![handle.seenTabGroups containsObject:groupKey]) {
      UIHReleaseTabGroup(group);
      [handle.tabGroups removeObjectForKey:groupKey];
      continue;
    }
    for (NSNumber *tabKey in group.tabs.allKeys.copy) {
      if (![group.seenTabs containsObject:tabKey]) {
        UIHReleaseTab(group.tabs[tabKey]);
        [group.tabs removeObjectForKey:tabKey];
      }
    }
    UIHLayoutTabGroup(group);
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
  handle.desiredFrame = view.frame;
  handle.target = target;
  handle.kind = kind;
  handle.contentView = view;
  handle.slots = [[NSMutableDictionary alloc] init];
  handle.items = [[NSMutableArray alloc] init];
  handle.itemTargets = [[NSMutableArray alloc] init];
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
    case UIHMacControlKindCatalog:
      focusView.accessibilityRole = NSAccessibilityGroupRole;
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

static UIHMacActionTarget *UIHNewTarget(uint64_t identity, int32_t eventKind) {
  UIHMacActionTarget *target = [[UIHMacActionTarget alloc] init];
  UIHLiveActionTargets += 1;
  target.identity = identity;
  target.eventKind = eventKind;
  return target;
}

static NSScrollView *UIHTextArea(
    const UIHMacRect *frame,
    UIHMacActionTarget *target,
    BOOL rich,
    NSTextView **editorResult) {
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:UIHRect(frame)];
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

static NSScrollView *UIHCollectionView(
    const UIHMacRect *frame,
    uint64_t identity,
    BOOL tableColumns,
    UIHMacCollectionAdapter **adapterResult,
    NSTableView **tableResult) {
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:UIHRect(frame)];
  scroll.borderType = NSBezelBorder;
  scroll.hasVerticalScroller = YES;
  NSTableView *table = [[NSTableView alloc] initWithFrame:scroll.bounds];
  table.usesAlternatingRowBackgroundColors = YES;
  table.allowsEmptySelection = YES;
  table.headerView = tableColumns ? [[NSTableHeaderView alloc] initWithFrame:NSZeroRect] : nil;
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
  UIHMacCollectionAdapter *adapter = [[UIHMacCollectionAdapter alloc] init];
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

static NSScrollView *UIHGridCollectionView(
    const UIHMacRect *frame,
    uint64_t identity,
    BOOL repeater,
    UIHMacGridAdapter **adapterResult,
    NSCollectionView **collectionResult) {
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:UIHRect(frame)];
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
  [collection registerClass:UIHMacGridItem.class forItemWithIdentifier:@"UIHGridItem"];
  UIHMacGridAdapter *adapter = [[UIHMacGridAdapter alloc] init];
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

static NSScrollView *UIHOutlineCollectionView(
    const UIHMacRect *frame,
    uint64_t identity,
    UIHMacOutlineAdapter **adapterResult,
    NSOutlineView **outlineResult) {
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:UIHRect(frame)];
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
  UIHMacOutlineAdapter *adapter = [[UIHMacOutlineAdapter alloc] init];
  adapter.identity = identity;
  adapter.items = [[NSMutableArray alloc] init];
  adapter.roots = [[NSMutableArray alloc] init];
  adapter.outline = outline;
  outline.dataSource = adapter;
  outline.delegate = adapter;
  scroll.documentView = outline;
  *adapterResult = adapter;
  *outlineResult = outline;
  return scroll;
}

UIHMacControlRef uih_macos_catalog_control_create(
    UIHMacWindowRef window,
    uint64_t identity,
    int32_t catalogKind,
    const UIHMacRect *frame) {
  UIHAssertMainThread();
  NSView *view = nil;
  NSView *focusView = nil;
  UIHMacActionTarget *target = nil;
  UIHMacCollectionAdapter *collectionAdapter = nil;
  UIHMacGridAdapter *gridAdapter = nil;
  UIHMacOutlineAdapter *outlineAdapter = nil;

  switch (catalogKind) {
    case UIHMacCatalogRichText: {
      NSTextView *text = nil;
      NSScrollView *scroll = UIHTextArea(frame, nil, YES, &text);
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
    case UIHMacCatalogImage:
    case UIHMacCatalogIcon: {
      NSImageView *image = [[NSImageView alloc] initWithFrame:UIHRect(frame)];
      image.imageScaling = NSImageScaleProportionallyUpOrDown;
      view = image;
      focusView = image;
      break;
    }
    case UIHMacCatalogSeparator: {
      NSBox *separator = [[NSBox alloc] initWithFrame:UIHRect(frame)];
      separator.boxType = NSBoxSeparator;
      view = separator;
      focusView = separator;
      break;
    }
    case UIHMacCatalogRepeatButton:
    case UIHMacCatalogToggleButton:
    case UIHMacCatalogCheckBox:
    case UIHMacCatalogLink: {
      int32_t eventKind = catalogKind == UIHMacCatalogRepeatButton || catalogKind == UIHMacCatalogLink
          ? UIHMacEventControlInvoked
          : UIHMacEventToggleChanged;
      target = UIHNewTarget(identity, eventKind);
      NSButton *button = catalogKind == UIHMacCatalogCheckBox
          ? [NSButton checkboxWithTitle:@"" target:target action:@selector(performAction:)]
          : [NSButton buttonWithTitle:@"" target:target action:@selector(performAction:)];
      button.frame = UIHRect(frame);
      if (catalogKind == UIHMacCatalogToggleButton) {
        button.buttonType = NSButtonTypePushOnPushOff;
      } else if (catalogKind == UIHMacCatalogCheckBox) {
        button.allowsMixedState = YES;
      } else if (catalogKind == UIHMacCatalogLink) {
        button.bordered = NO;
        button.bezelStyle = NSBezelStyleInline;
        button.contentTintColor = NSColor.linkColor;
        button.alignment = NSTextAlignmentLeft;
      }
      if (catalogKind == UIHMacCatalogRepeatButton) {
        button.continuous = YES;
        [button setPeriodicDelay:0.35 interval:0.08];
      }
      view = button;
      focusView = button;
      break;
    }
    case UIHMacCatalogSwitch: {
      target = UIHNewTarget(identity, UIHMacEventToggleChanged);
      NSSwitch *toggle = [[NSSwitch alloc] initWithFrame:NSZeroRect];
      toggle.target = target;
      toggle.action = @selector(performAction:);
      toggle.identifier = @"switch";
      NSTextField *label = [NSTextField labelWithString:@""];
      label.identifier = @"switchLabel";
      NSStackView *stack = [NSStackView stackViewWithViews:@[toggle, label]];
      stack.frame = UIHRect(frame);
      stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
      stack.alignment = NSLayoutAttributeCenterY;
      stack.spacing = 8;
      view = stack;
      focusView = toggle;
      break;
    }
    case UIHMacCatalogRadioGroup:
    case UIHMacCatalogMenuBar:
    case UIHMacCatalogToolbar: {
      NSStackView *stack = [[NSStackView alloc] initWithFrame:UIHRect(frame)];
      stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
      stack.alignment = NSLayoutAttributeCenterY;
      stack.spacing = 6;
      view = stack;
      focusView = stack;
      break;
    }
    case UIHMacCatalogSegmentedChoice:
    case UIHMacCatalogBreadcrumb: {
      target = UIHNewTarget(identity, UIHMacEventChoiceChanged);
      NSSegmentedControl *segments = [[NSSegmentedControl alloc] initWithFrame:UIHRect(frame)];
      segments.target = target;
      segments.action = @selector(performAction:);
      segments.segmentStyle = catalogKind == UIHMacCatalogBreadcrumb
          ? NSSegmentStyleTexturedRounded
          : NSSegmentStyleRounded;
      view = segments;
      focusView = segments;
      break;
    }
    case UIHMacCatalogMenuButton:
    case UIHMacCatalogChoicePicker:
    case UIHMacCatalogContextMenu: {
      target = UIHNewTarget(identity, UIHMacEventChoiceChanged);
      NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:UIHRect(frame) pullsDown:NO];
      popup.target = target;
      popup.action = @selector(performAction:);
      view = popup;
      focusView = popup;
      break;
    }
    case UIHMacCatalogSplitButton:
    case UIHMacCatalogToggleSplitButton: {
      target = UIHNewTarget(identity,
          catalogKind == UIHMacCatalogToggleSplitButton
              ? UIHMacEventToggleChanged
              : UIHMacEventControlInvoked);
      NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
      button.target = target;
      button.action = @selector(performAction:);
      button.bezelStyle = NSBezelStyleRounded;
      if (catalogKind == UIHMacCatalogToggleSplitButton) {
        button.buttonType = NSButtonTypePushOnPushOff;
      }
      NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
      NSStackView *stack = [NSStackView stackViewWithViews:@[button, popup]];
      stack.frame = UIHRect(frame);
      stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
      stack.spacing = 1;
      button.identifier = @"primary";
      popup.identifier = @"menu";
      view = stack;
      focusView = button;
      break;
    }
    case UIHMacCatalogTextArea:
    case UIHMacCatalogRichTextEditor: {
      target = UIHNewTarget(identity, UIHMacEventTextChanged);
      NSTextView *editor = nil;
      view = UIHTextArea(frame, target, catalogKind == UIHMacCatalogRichTextEditor, &editor);
      focusView = editor;
      break;
    }
    case UIHMacCatalogSecureField:
    case UIHMacCatalogSearchField:
    case UIHMacCatalogSuggestField:
    case UIHMacCatalogEditableComboBox: {
      target = UIHNewTarget(identity, UIHMacEventTextChanged);
      NSTextField *field = nil;
      if (catalogKind == UIHMacCatalogSecureField) {
        field = [[NSSecureTextField alloc] initWithFrame:UIHRect(frame)];
      } else if (catalogKind == UIHMacCatalogSearchField) {
        field = [[NSSearchField alloc] initWithFrame:UIHRect(frame)];
      } else {
        field = [[NSComboBox alloc] initWithFrame:UIHRect(frame)];
      }
      field.delegate = target;
      view = field;
      focusView = field;
      break;
    }
    case UIHMacCatalogNumberField: {
      target = UIHNewTarget(identity, UIHMacEventNumberChanged);
      NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];
      field.target = target;
      field.action = @selector(performAction:);
      NSStepper *stepper = [[NSStepper alloc] initWithFrame:NSZeroRect];
      stepper.target = target;
      stepper.action = @selector(performAction:);
      NSStackView *stack = [NSStackView stackViewWithViews:@[field, stepper]];
      stack.frame = UIHRect(frame);
      stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
      stack.spacing = 4;
      [field.widthAnchor constraintGreaterThanOrEqualToConstant:MAX(60, frame->width - 34)].active = YES;
      field.identifier = @"numberField";
      stepper.identifier = @"numberStepper";
      view = stack;
      focusView = field;
      break;
    }
    case UIHMacCatalogStepper:
    case UIHMacCatalogSlider:
    case UIHMacCatalogRating: {
      target = UIHNewTarget(identity, UIHMacEventNumberChanged);
      NSControl *control = nil;
      if (catalogKind == UIHMacCatalogStepper) {
        control = [[NSStepper alloc] initWithFrame:UIHRect(frame)];
      } else if (catalogKind == UIHMacCatalogSlider) {
        control = [[NSSlider alloc] initWithFrame:UIHRect(frame)];
      } else {
        NSLevelIndicator *rating = [[NSLevelIndicator alloc] initWithFrame:UIHRect(frame)];
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
    case UIHMacCatalogDatePicker:
    case UIHMacCatalogTimePicker:
    case UIHMacCatalogCalendarView: {
      int32_t eventKind = catalogKind == UIHMacCatalogTimePicker
          ? UIHMacEventTimeChanged
          : UIHMacEventDateChanged;
      target = UIHNewTarget(identity, eventKind);
      NSDatePicker *picker = [[NSDatePicker alloc] initWithFrame:UIHRect(frame)];
      picker.target = target;
      picker.action = @selector(performAction:);
      picker.datePickerElements = catalogKind == UIHMacCatalogTimePicker
          ? (NSDatePickerElementFlagHourMinuteSecond)
          : (NSDatePickerElementFlagYearMonthDay);
      picker.datePickerStyle = catalogKind == UIHMacCatalogCalendarView
          ? NSDatePickerStyleClockAndCalendar
          : NSDatePickerStyleTextFieldAndStepper;
      view = picker;
      focusView = picker;
      break;
    }
    case UIHMacCatalogColorPicker: {
      target = UIHNewTarget(identity, UIHMacEventColorChanged);
      NSColorWell *well = [[NSColorWell alloc] initWithFrame:UIHRect(frame)];
      well.target = target;
      well.action = @selector(performAction:);
      view = well;
      focusView = well;
      break;
    }
    case UIHMacCatalogListView:
    case UIHMacCatalogTableView:
    case UIHMacCatalogNavigationSidebar: {
      NSTableView *table = nil;
      view = UIHCollectionView(frame, identity, catalogKind == UIHMacCatalogTableView,
                               &collectionAdapter, &table);
      if (catalogKind == UIHMacCatalogNavigationSidebar) {
        table.style = NSTableViewStyleSourceList;
        table.usesAlternatingRowBackgroundColors = NO;
        table.rowHeight = 26;
        collectionAdapter.showsDepth = YES;
        collectionAdapter.navigationStyle = YES;
      } else if (catalogKind == UIHMacCatalogListView) {
        table.usesAlternatingRowBackgroundColors = NO;
        table.rowHeight = 24;
      }
      focusView = table;
      break;
    }
    case UIHMacCatalogCollectionView:
    case UIHMacCatalogItemRepeater: {
      NSCollectionView *collection = nil;
      view = UIHGridCollectionView(
          frame, identity, catalogKind == UIHMacCatalogItemRepeater,
          &gridAdapter, &collection);
      focusView = collection;
      break;
    }
    case UIHMacCatalogTreeView: {
      NSOutlineView *outline = nil;
      view = UIHOutlineCollectionView(frame, identity, &outlineAdapter, &outline);
      focusView = outline;
      break;
    }
    case UIHMacCatalogTabView: {
      target = UIHNewTarget(identity, UIHMacEventChoiceChanged);
      NSSegmentedControl *segments = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
      segments.target = target;
      segments.action = @selector(performAction:);
      segments.identifier = @"tabs";
      NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
      content.identifier = @"content";
      NSView *root = [[NSView alloc] initWithFrame:UIHRect(frame)];
      [root addSubview:segments];
      [root addSubview:content];
      segments.frame = NSMakeRect(0, MAX(0, frame->height - 30), frame->width, 28);
      content.frame = NSMakeRect(0, 0, frame->width, MAX(0, frame->height - 32));
      view = root;
      focusView = segments;
      break;
    }
    case UIHMacCatalogProgressBar:
    case UIHMacCatalogActivityIndicator:
    case UIHMacCatalogMeter: {
      NSProgressIndicator *progress = [[NSProgressIndicator alloc] initWithFrame:UIHRect(frame)];
      progress.style = catalogKind == UIHMacCatalogActivityIndicator
          ? NSProgressIndicatorStyleSpinning
          : NSProgressIndicatorStyleBar;
      progress.indeterminate = catalogKind == UIHMacCatalogActivityIndicator;
      if (catalogKind == UIHMacCatalogActivityIndicator) {
        [progress startAnimation:nil];
      }
      view = progress;
      focusView = progress;
      break;
    }
    case UIHMacCatalogTooltip:
    case UIHMacCatalogBadge:
    case UIHMacCatalogInlineNotice: {
      NSBox *box = [[NSBox alloc] initWithFrame:UIHRect(frame)];
      box.boxType = NSBoxCustom;
      box.titlePosition = NSNoTitle;
      box.borderWidth = catalogKind == UIHMacCatalogBadge ? 1.0 : 0.75;
      box.cornerRadius = catalogKind == UIHMacCatalogBadge ? 10.0 : 7.0;
      box.fillColor = catalogKind == UIHMacCatalogBadge
          ? NSColor.controlBackgroundColor
          : NSColor.windowBackgroundColor;
      NSTextField *title = [NSTextField wrappingLabelWithString:@""];
      title.identifier = @"messageTitle";
      title.font = catalogKind == UIHMacCatalogBadge
          ? [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]
          : [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
      NSTextField *detail = [NSTextField wrappingLabelWithString:@""];
      detail.identifier = @"messageDetail";
      detail.font = [NSFont systemFontOfSize:11];
      detail.textColor = NSColor.secondaryLabelColor;
      if (catalogKind == UIHMacCatalogBadge) {
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
    case UIHMacCatalogDialog:
    case UIHMacCatalogAlert:
    case UIHMacCatalogPopover: {
      NSView *placeholder = [[NSView alloc] initWithFrame:UIHRect(frame)];
      placeholder.hidden = YES;
      view = placeholder;
      focusView = placeholder;
      break;
    }
    case UIHMacCatalogContainer:
    default: {
      target = UIHNewTarget(identity, UIHMacEventDisclosureChanged);
      NSBox *box = [[NSBox alloc] initWithFrame:UIHRect(frame)];
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
      NSView *content = [[NSView alloc] initWithFrame:box.contentView.bounds];
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

  UIHMacControlRef reference = UIHRetainControl(
      view, focusView, target, UIHMacControlKindCatalog, identity, window);
  UIHMacControlHandle *handle = UIHControl(reference);
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
  } else if (catalogKind == UIHMacCatalogContainer) {
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
  } else if (catalogKind == UIHMacCatalogTabView) {
    for (NSView *subview in view.subviews) {
      if ([subview.identifier isEqualToString:@"content"]) {
        handle.contentView = subview;
      }
    }
  }
  switch (catalogKind) {
    case UIHMacCatalogRichText:
      focusView.accessibilityRole = NSAccessibilityStaticTextRole;
      break;
    case UIHMacCatalogImage:
    case UIHMacCatalogIcon:
      focusView.accessibilityRole = NSAccessibilityImageRole;
      break;
    case UIHMacCatalogRepeatButton:
    case UIHMacCatalogToggleButton:
    case UIHMacCatalogLink:
    case UIHMacCatalogSplitButton:
    case UIHMacCatalogToggleSplitButton:
      focusView.accessibilityRole = catalogKind == UIHMacCatalogLink
          ? NSAccessibilityLinkRole
          : NSAccessibilityButtonRole;
      break;
    case UIHMacCatalogCheckBox:
    case UIHMacCatalogSwitch:
      focusView.accessibilityRole = NSAccessibilityCheckBoxRole;
      break;
    case UIHMacCatalogRadioGroup:
      focusView.accessibilityRole = NSAccessibilityRadioGroupRole;
      break;
    case UIHMacCatalogSegmentedChoice:
    case UIHMacCatalogTabView:
      focusView.accessibilityRole = NSAccessibilityTabGroupRole;
      break;
    case UIHMacCatalogMenuButton:
    case UIHMacCatalogChoicePicker:
    case UIHMacCatalogContextMenu:
      focusView.accessibilityRole = NSAccessibilityPopUpButtonRole;
      break;
    case UIHMacCatalogTextArea:
    case UIHMacCatalogRichTextEditor:
      focusView.accessibilityRole = NSAccessibilityTextAreaRole;
      break;
    case UIHMacCatalogSecureField:
    case UIHMacCatalogSearchField:
      focusView.accessibilityRole = NSAccessibilityTextFieldRole;
      break;
    case UIHMacCatalogSuggestField:
    case UIHMacCatalogEditableComboBox:
      focusView.accessibilityRole = NSAccessibilityComboBoxRole;
      break;
    case UIHMacCatalogNumberField:
    case UIHMacCatalogStepper:
      focusView.accessibilityRole = NSAccessibilityIncrementorRole;
      break;
    case UIHMacCatalogSlider:
    case UIHMacCatalogRating:
      focusView.accessibilityRole = NSAccessibilitySliderRole;
      break;
    case UIHMacCatalogDatePicker:
    case UIHMacCatalogTimePicker:
    case UIHMacCatalogCalendarView:
      focusView.accessibilityRole = NSAccessibilityDateTimeAreaRole;
      break;
    case UIHMacCatalogColorPicker:
      focusView.accessibilityRole = NSAccessibilityColorWellRole;
      break;
    case UIHMacCatalogTreeView:
    case UIHMacCatalogNavigationSidebar:
      focusView.accessibilityRole = NSAccessibilityOutlineRole;
      break;
    case UIHMacCatalogTableView:
      focusView.accessibilityRole = NSAccessibilityTableRole;
      break;
    case UIHMacCatalogListView:
    case UIHMacCatalogCollectionView:
    case UIHMacCatalogItemRepeater:
      focusView.accessibilityRole = NSAccessibilityListRole;
      break;
    case UIHMacCatalogMenuBar:
      focusView.accessibilityRole = NSAccessibilityMenuBarRole;
      break;
    case UIHMacCatalogToolbar:
      focusView.accessibilityRole = NSAccessibilityToolbarRole;
      break;
    case UIHMacCatalogProgressBar:
    case UIHMacCatalogMeter:
      focusView.accessibilityRole = NSAccessibilityProgressIndicatorRole;
      break;
    case UIHMacCatalogActivityIndicator:
      focusView.accessibilityRole = NSAccessibilityBusyIndicatorRole;
      break;
    default:
      focusView.accessibilityRole = NSAccessibilityGroupRole;
      break;
  }
  return reference;
}

static NSView *UIHSubview(UIHMacControlHandle *handle, NSString *identifier) {
  for (NSView *subview in handle.view.subviews) {
    if ([subview.identifier isEqualToString:identifier]) {
      return subview;
    }
  }
  return nil;
}

static void UIHMoveSubviews(NSView *source, NSView *destination) {
  for (NSView *child in source.subviews.copy) {
    [child removeFromSuperview];
    [destination addSubview:child];
  }
}

static NSSize UIHDesiredSizeForSubview(NSView *view) {
  __block NSSize result = view.frame.size;
  [UIHState.controls enumerateKeysAndObjectsUsingBlock:
      ^(NSNumber *key, UIHMacControlHandle *candidate, BOOL *stop) {
        (void)key;
        if (candidate.view == view) {
          result = candidate.desiredFrame.size;
          *stop = YES;
        }
      }];
  return result;
}

static void UIHLayoutContainer(UIHMacControlHandle *handle) {
  if (handle.catalogKind != UIHMacCatalogContainer || handle.contentView == nil) {
    return;
  }
  NSView *host = handle.contentView;
  NSArray<NSView *> *children = host.subviews;
  NSInteger count = children.count;
  NSInteger state = handle.containerState;
  NSRect bounds = ((NSBox *)handle.view).contentView.bounds;

  if (state == 3000) {
    CGFloat headerY = MAX(0, NSHeight(bounds) - 28);
    handle.disclosureLabel.frame = NSMakeRect(12, headerY + 2,
        MAX(0, NSWidth(bounds) - 24), 22);
    bounds.size.height = MAX(0, NSHeight(bounds) - 30);
    host.hidden = NO;
  } else if (state >= 5000 && state < 5100) {
    CGFloat headerY = MAX(0, NSHeight(bounds) - 28);
    handle.disclosureButton.frame = NSMakeRect(0, headerY, 22, 24);
    handle.disclosureLabel.frame = NSMakeRect(26, headerY + 2,
        MAX(0, NSWidth(bounds) - 26), 22);
    bounds.size.height = MAX(0, NSHeight(bounds) - 30);
    host.hidden = state == 5000;
  } else {
    host.hidden = NO;
  }

  if (state == 4000) {
    CGFloat maximumY = NSHeight(bounds);
    CGFloat maximumX = NSWidth(bounds);
    for (NSView *child in children) {
      maximumY = MAX(maximumY, NSMaxY(child.frame));
      maximumX = MAX(maximumX, NSMaxX(child.frame));
    }
    host.frame = NSMakeRect(0, 0, maximumX, maximumY);
    if (!handle.containerScrollInitialized && handle.containerScrollView != nil &&
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
      NSSize desired = UIHDesiredSizeForSubview(child);
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
        NSSize desired = UIHDesiredSizeForSubview(child);
        CGFloat height = desired.height > 0 ? MIN(y, desired.height) : 0;
        CGFloat width = desired.width > 0 ? MIN(NSWidth(bounds), desired.width) : NSWidth(bounds);
        y -= height;
        child.frame = NSMakeRect(0, MAX(0, y), width, height);
        y -= spacing;
      }
    } else {
      CGFloat x = 0;
      for (NSView *child in children) {
        NSSize desired = UIHDesiredSizeForSubview(child);
        CGFloat width = desired.width > 0 ? MIN(MAX(0, NSWidth(bounds) - x), desired.width) : 0;
        CGFloat height = desired.height > 0 ? MIN(NSHeight(bounds), desired.height) : NSHeight(bounds);
        child.frame = NSMakeRect(x, (NSHeight(bounds) - height) / 2, width, height);
        x += width + spacing;
      }
    }
  }
}

static void UIHConfigureContainer(UIHMacControlHandle *handle, int32_t state) {
  NSBox *box = (NSBox *)handle.view;
  BOOL wantsScroll = state == 4000;
  if (wantsScroll && handle.containerScrollView == nil) {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:handle.normalContentView.frame];
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSView *document = [[NSView alloc] initWithFrame:handle.normalContentView.bounds];
    scroll.documentView = document;
    [box.contentView addSubview:scroll positioned:NSWindowBelow relativeTo:handle.disclosureButton];
    UIHMoveSubviews(handle.normalContentView, document);
    handle.normalContentView.hidden = YES;
    handle.containerScrollView = scroll;
    handle.containerScrollDocument = document;
    handle.containerScrollInitialized = NO;
    handle.contentView = document;
  } else if (!wantsScroll && handle.containerScrollView != nil) {
    UIHMoveSubviews(handle.containerScrollDocument, handle.normalContentView);
    [handle.containerScrollView removeFromSuperview];
    handle.containerScrollView = nil;
    handle.containerScrollDocument = nil;
    handle.containerScrollInitialized = NO;
    handle.normalContentView.hidden = NO;
    handle.contentView = handle.normalContentView;
  }

  handle.containerState = state;
  BOOL disclosure = state >= 5000 && state < 5100;
  BOOL group = state == 3000;
  handle.disclosureButton.hidden = !disclosure;
  handle.disclosureLabel.hidden = !(disclosure || group);
  handle.disclosureButton.state = state == 5001 ? NSControlStateValueOn : NSControlStateValueOff;
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
  UIHLayoutContainer(handle);
}

static NSImage *UIHImageSource(NSString *source) {
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

static void UIHSetImageSource(NSImageView *imageView, NSString *source) {
  imageView.image = UIHImageSource(source);
}

void uih_macos_catalog_control_set_primary_text(
    UIHMacControlRef reference,
    const char *utf8Text) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  NSString *text = UIHString(utf8Text);
  handle.primaryText = text;
  if (text.length > 0) {
    handle.focusView.accessibilityLabel = text;
  }
  switch (handle.catalogKind) {
    case UIHMacCatalogRichText:
      if (![((NSTextView *)handle.focusView).string isEqualToString:text]) {
        ((NSTextView *)handle.focusView).string = text;
      }
      break;
    case UIHMacCatalogImage:
    case UIHMacCatalogIcon:
      UIHSetImageSource((NSImageView *)handle.view, text);
      break;
    case UIHMacCatalogRepeatButton:
    case UIHMacCatalogToggleButton:
    case UIHMacCatalogCheckBox:
    case UIHMacCatalogLink:
      ((NSButton *)handle.view).title = text;
      break;
    case UIHMacCatalogSwitch:
      ((NSTextField *)UIHSubview(handle, @"switchLabel")).stringValue = text;
      break;
    case UIHMacCatalogSplitButton:
    case UIHMacCatalogToggleSplitButton:
      ((NSButton *)UIHSubview(handle, @"primary")).title = text;
      break;
    case UIHMacCatalogTextArea:
    case UIHMacCatalogRichTextEditor:
      if (![((NSTextView *)handle.focusView).string isEqualToString:text]) {
        ((NSTextView *)handle.focusView).string = text;
      }
      break;
    case UIHMacCatalogSecureField:
    case UIHMacCatalogSearchField:
    case UIHMacCatalogSuggestField:
    case UIHMacCatalogEditableComboBox:
      if (![((NSTextField *)handle.focusView).stringValue isEqualToString:text]) {
        ((NSTextField *)handle.focusView).stringValue = text;
      }
      break;
    case UIHMacCatalogContextMenu:
      ((NSPopUpButton *)handle.view).title = text;
      break;
    case UIHMacCatalogTooltip:
    case UIHMacCatalogBadge:
    case UIHMacCatalogInlineNotice: {
      NSTextField *label = nil;
      for (NSView *candidate in handle.contentView.subviews) {
        if ([candidate.identifier isEqualToString:@"messageTitle"]) {
          label = (NSTextField *)candidate;
        }
      }
      label.stringValue = text;
      break;
    }
    case UIHMacCatalogDialog:
    case UIHMacCatalogAlert:
    case UIHMacCatalogPopover:
    case UIHMacCatalogContainer:
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

void uih_macos_catalog_control_set_secondary_text(
    UIHMacControlRef reference,
    const char *utf8Text) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  NSString *text = UIHString(utf8Text);
  handle.secondaryText = text;
  if ([handle.focusView isKindOfClass:NSTextField.class] &&
      (handle.catalogKind == UIHMacCatalogSecureField ||
       handle.catalogKind == UIHMacCatalogSearchField ||
       handle.catalogKind == UIHMacCatalogSuggestField ||
       handle.catalogKind == UIHMacCatalogEditableComboBox)) {
    ((NSTextField *)handle.focusView).placeholderString = text;
  } else if (handle.catalogKind == UIHMacCatalogRepeatButton ||
             handle.catalogKind == UIHMacCatalogToggleButton ||
             handle.catalogKind == UIHMacCatalogLink) {
    ((NSButton *)handle.view).image = UIHImageSource(text);
    ((NSButton *)handle.view).imagePosition = text.length == 0
        ? NSNoImage
        : NSImageLeading;
  } else if (handle.catalogKind == UIHMacCatalogSplitButton ||
             handle.catalogKind == UIHMacCatalogToggleSplitButton) {
    NSButton *button = (NSButton *)UIHSubview(handle, @"primary");
    button.image = UIHImageSource(text);
    button.imagePosition = text.length == 0 ? NSNoImage : NSImageLeading;
  } else if (handle.catalogKind == UIHMacCatalogTooltip ||
             handle.catalogKind == UIHMacCatalogBadge ||
             handle.catalogKind == UIHMacCatalogInlineNotice) {
    handle.view.toolTip = text;
    for (NSView *candidate in handle.contentView.subviews) {
      if ([candidate.identifier isEqualToString:@"messageDetail"]) {
        ((NSTextField *)candidate).stringValue = text;
      }
    }
  } else if (handle.catalogKind == UIHMacCatalogImage ||
             handle.catalogKind == UIHMacCatalogIcon) {
    handle.focusView.accessibilityLabel = text;
  }
}

void uih_macos_catalog_control_set_state(
    UIHMacControlRef reference,
    int32_t state) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  NSControlStateValue nativeState = state < 0
      ? NSControlStateValueMixed
      : (state == 0 ? NSControlStateValueOff : NSControlStateValueOn);
  if ([handle.view isKindOfClass:NSButton.class]) {
    ((NSButton *)handle.view).state = nativeState;
  } else if ([handle.view isKindOfClass:NSSwitch.class]) {
    ((NSSwitch *)handle.view).state = nativeState;
  } else if (handle.catalogKind == UIHMacCatalogSwitch) {
    ((NSSwitch *)handle.focusView).state = nativeState;
  } else if (handle.catalogKind == UIHMacCatalogToggleSplitButton) {
    ((NSButton *)UIHSubview(handle, @"primary")).state = nativeState;
  } else if (handle.catalogKind == UIHMacCatalogActivityIndicator) {
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
  } else if (handle.catalogKind == UIHMacCatalogContainer) {
    UIHConfigureContainer(handle, state);
  }
}

static void UIHConfigureNumericControl(
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

void uih_macos_catalog_control_set_numeric(
    UIHMacControlRef reference,
    double value,
    double minimum,
    double maximum,
    double step) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  if (handle.catalogKind == UIHMacCatalogNumberField) {
    NSTextField *field = (NSTextField *)UIHSubview(handle, @"numberField");
    NSStepper *stepper = (NSStepper *)UIHSubview(handle, @"numberStepper");
    field.doubleValue = value;
    UIHConfigureNumericControl(stepper, value, minimum, maximum, step);
  } else if ([handle.view isKindOfClass:NSControl.class]) {
    UIHConfigureNumericControl((NSControl *)handle.view, value, minimum, maximum, step);
  } else if ([handle.view isKindOfClass:NSProgressIndicator.class]) {
    NSProgressIndicator *progress = (NSProgressIndicator *)handle.view;
    progress.minValue = minimum;
    progress.maxValue = maximum;
    progress.doubleValue = value;
  }
}

void uih_macos_catalog_control_set_color(
    UIHMacControlRef reference,
    double red,
    double green,
    double blue,
    double alpha) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  if ([handle.view isKindOfClass:NSColorWell.class]) {
    ((NSColorWell *)handle.view).color = UIHColor(red, green, blue, alpha);
  }
}

void uih_macos_catalog_control_set_date_time(
    UIHMacControlRef reference,
    int32_t year,
    int32_t month,
    int32_t day,
    int32_t hour,
    int32_t minute,
    int32_t second) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
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

void uih_macos_catalog_control_set_command(
    UIHMacControlRef reference,
    uint64_t commandIdentity) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  handle.commandIdentity = commandIdentity;
  if (handle.target != nil) {
    if (handle.catalogKind == UIHMacCatalogToggleSplitButton) {
      handle.target.secondaryIdentity = commandIdentity;
      handle.target.secondaryEventKind = UIHMacEventCommand;
    } else {
      handle.target.identity = commandIdentity;
      handle.target.eventKind = UIHMacEventCommand;
    }
  }
}

static void UIHReleaseItemTargets(UIHMacControlHandle *handle) {
  for (UIHMacActionTarget *target in handle.itemTargets) {
    (void)target;
    UIHLiveActionTargets -= 1;
  }
  [handle.itemTargets removeAllObjects];
}

void uih_macos_catalog_control_begin_items(UIHMacControlRef reference) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  UIHReleaseItemTargets(handle);
  [handle.items removeAllObjects];
  [handle.slots removeAllObjects];
  if (handle.catalogKind == UIHMacCatalogSplitButton ||
      handle.catalogKind == UIHMacCatalogToggleSplitButton) {
    [(NSPopUpButton *)UIHSubview(handle, @"menu") removeAllItems];
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
  } else if (handle.catalogKind == UIHMacCatalogTabView) {
    NSSegmentedControl *segments = (NSSegmentedControl *)UIHSubview(handle, @"tabs");
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

void uih_macos_catalog_control_add_item(
    UIHMacControlRef reference,
    uint64_t itemIdentity,
    const char *utf8Label,
    const char *utf8Detail,
    int32_t depth,
    int32_t flags,
    uint64_t commandIdentity) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  NSString *label = UIHString(utf8Label);
  NSString *detail = UIHString(utf8Detail);
  BOOL enabled = (flags & 1) != 0;
  BOOL selected = (flags & 2) != 0;
  BOOL expanded = (flags & 4) != 0;
  BOOL separator = (flags & 8) != 0;
  NSDictionary *item = @{
    @"identity": @(itemIdentity),
    @"label": label,
    @"detail": detail,
    @"depth": @(MAX(0, depth)),
    @"enabled": @(enabled),
    @"selected": @(selected),
    @"expanded": @(expanded),
    @"command": @(commandIdentity)
  };
  [handle.items addObject:item];

  if (handle.catalogKind == UIHMacCatalogRadioGroup) {
    UIHMacActionTarget *target = UIHNewTarget(handle.identity, UIHMacEventChoiceChanged);
    target.fixedPayload = [@(itemIdentity) stringValue];
    [handle.itemTargets addObject:target];
    NSButton *button = [NSButton radioButtonWithTitle:label target:target action:@selector(performAction:)];
    button.tag = (NSInteger)itemIdentity;
    button.enabled = enabled;
    button.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
    [(NSStackView *)handle.view addArrangedSubview:button];
  } else if (handle.catalogKind == UIHMacCatalogMenuBar ||
             handle.catalogKind == UIHMacCatalogToolbar) {
    if (separator) {
      NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 1, 20)];
      line.boxType = NSBoxSeparator;
      [(NSStackView *)handle.view addArrangedSubview:line];
    } else {
      if (label.length == 0 && commandIdentity != 0) {
        NSMenuItem *commandItem = UIHState.commandItems[@(commandIdentity)];
        label = commandItem.title ?: @"";
      }
      UIHMacActionTarget *target = UIHNewTarget(commandIdentity, UIHMacEventCommand);
      [handle.itemTargets addObject:target];
      NSButton *button = [NSButton buttonWithTitle:label target:target action:@selector(performAction:)];
      button.enabled = enabled;
      button.bezelStyle = handle.catalogKind == UIHMacCatalogToolbar
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
    NSImage *image = UIHImageSource(detail);
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
      popup.lastItem.image = UIHImageSource(detail);
      if (commandIdentity != 0) {
        UIHMacActionTarget *target = UIHNewTarget(commandIdentity, UIHMacEventCommand);
        [handle.itemTargets addObject:target];
        popup.lastItem.target = target;
        popup.lastItem.action = @selector(performAction:);
      }
      if (selected) {
        [popup selectItem:popup.lastItem];
      }
    }
  } else if (handle.catalogKind == UIHMacCatalogSplitButton ||
             handle.catalogKind == UIHMacCatalogToggleSplitButton) {
    NSPopUpButton *popup = (NSPopUpButton *)UIHSubview(handle, @"menu");
    if (separator) {
      [popup.menu addItem:NSMenuItem.separatorItem];
    } else {
      UIHMacActionTarget *target = UIHNewTarget(commandIdentity, UIHMacEventCommand);
      [handle.itemTargets addObject:target];
      NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:label
                                                      action:@selector(performAction:)
                                               keyEquivalent:@""];
      menuItem.target = target;
      menuItem.enabled = enabled;
      [popup.menu addItem:menuItem];
    }
  } else if (handle.catalogKind == UIHMacCatalogTabView) {
    NSSegmentedControl *segments = (NSSegmentedControl *)UIHSubview(handle, @"tabs");
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

void uih_macos_catalog_control_end_items(UIHMacControlRef reference) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
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
  if (handle.catalogKind == UIHMacCatalogTabView) {
    NSSegmentedControl *segments = (NSSegmentedControl *)UIHSubview(handle, @"tabs");
    if (segments.selectedSegment < 0 && segments.segmentCount > 0) {
      segments.selectedSegment = 0;
      NSNumber *key = @([segments tagForSegment:0]);
      handle.slots[key].hidden = NO;
    }
  }
}

void uih_macos_catalog_control_set_tooltip(
    UIHMacControlRef reference,
    const char *utf8Tooltip) {
  UIHAssertMainThread();
  UIHControl(reference).view.toolTip = UIHString(utf8Tooltip);
}

void uih_macos_catalog_control_set_presentation(
    UIHMacControlRef reference,
    int32_t visible,
    uint64_t anchorIdentity) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
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

  UIHMacWindowHandle *owner = nil;
  for (UIHMacWindowHandle *candidate in UIHState.windows.allValues) {
    if (handle.view.window == candidate.window) {
      owner = candidate;
      break;
    }
  }
  if (handle.catalogKind == UIHMacCatalogPopover) {
    UIHMacControlHandle *anchor = UIHState.controls[@(anchorIdentity)];
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
    popover.behavior = NSPopoverBehaviorTransient;
    popover.delegate = handle;
    [popover showRelativeToRect:anchor.view.bounds ofView:anchor.view preferredEdge:NSRectEdgeMaxY];
    handle.popover = popover;
  } else if (owner != nil) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = handle.primaryText ?: @"";
    alert.informativeText = handle.secondaryText ?: @"";
    [alert addButtonWithTitle:@"OK"];
    if (handle.catalogKind == UIHMacCatalogDialog) {
      [alert addButtonWithTitle:@"Cancel"];
    }
    [alert beginSheetModalForWindow:owner.window completionHandler:^(NSModalResponse response) {
      BOOL wasPresented = handle.presentationVisible;
      handle.presentationVisible = NO;
      handle.presentationWindow = nil;
      NSString *result = response == NSAlertFirstButtonReturn ? @"accepted" : @"cancelled";
      if (wasPresented) {
        UIHEmit(UIHMacEventPresentationClosed, handle.identity, result);
      }
    }];
    handle.presentationWindow = alert.window;
  }
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
    case UIHMacControlKindCatalog:
      uih_macos_catalog_control_set_primary_text(reference, utf8_text);
      break;
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

static BOOL UIHIsTextEditorHandle(UIHMacControlHandle *handle) {
  return handle.kind == UIHMacControlKindTextEditor ||
      (handle.kind == UIHMacControlKindCatalog &&
       (handle.catalogKind == UIHMacCatalogRichTextEditor ||
        handle.catalogKind == UIHMacCatalogRichText));
}

void uih_macos_text_editor_begin_presentation(UIHMacControlRef reference) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  if (!UIHIsTextEditorHandle(handle)) {
    return;
  }
  NSTextView *editor = (NSTextView *)handle.focusView;
  BOOL staticRichText = handle.kind == UIHMacControlKindCatalog &&
      handle.catalogKind == UIHMacCatalogRichText;
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

void uih_macos_text_editor_set_base_style(
    UIHMacControlRef reference,
    const UIHMacTextStyle *style) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  if (!UIHIsTextEditorHandle(handle) || style == NULL) {
    return;
  }
  NSTextView *editor = (NSTextView *)handle.focusView;
  BOOL staticRichText = handle.kind == UIHMacControlKindCatalog &&
      handle.catalogKind == UIHMacCatalogRichText;
  editor.font = staticRichText
      ? [NSFont systemFontOfSize:13 weight:NSFontWeightRegular]
      : [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
  editor.textColor = NSColor.textColor;
  editor.drawsBackground = !staticRichText;
  editor.backgroundColor = staticRichText ? NSColor.clearColor : NSColor.textBackgroundColor;
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
  if (staticRichText && editor.string.length > 0) {
    [editor.textStorage addAttributes:@{
        NSFontAttributeName: editor.font,
        NSForegroundColorAttributeName: editor.textColor
      }
                               range:NSMakeRange(0, editor.string.length)];
  }
}

int32_t uih_macos_text_editor_apply_style(
    UIHMacControlRef reference,
    uint64_t utf16Location,
    uint64_t utf16Length,
    const UIHMacTextStyle *style) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  if (!UIHIsTextEditorHandle(handle) || style == NULL ||
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
    BOOL staticRichText = handle.kind == UIHMacControlKindCatalog &&
        handle.catalogKind == UIHMacCatalogRichText;
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

void uih_macos_text_editor_end_presentation(UIHMacControlRef reference) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  if (!UIHIsTextEditorHandle(handle)) {
    return;
  }
  NSTextView *editor = (NSTextView *)handle.focusView;
  if (editor.string.length > 0) {
    [editor.layoutManager invalidateDisplayForCharacterRange:NSMakeRange(0, editor.string.length)];
  }
}

void uih_macos_control_set_frame(UIHMacControlRef reference, const UIHMacRect *frame) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
  handle.desiredFrame = UIHRect(frame);
  handle.view.frame = handle.desiredFrame;
  UIHLayoutContainer(handle);
}

void uih_macos_control_set_enabled(UIHMacControlRef reference, int32_t enabled) {
  UIHAssertMainThread();
  UIHMacControlHandle *handle = UIHControl(reference);
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

static void UIHAttachControl(
    UIHMacControlHandle *control,
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

void uih_macos_control_set_parent_item(
    UIHMacWindowRef windowReference,
    UIHMacControlRef controlReference,
    uint64_t itemIdentity,
    int32_t fillParent) {
  UIHAssertMainThread();
  UIHMacWindowHandle *window = UIHWindow(windowReference);
  UIHAttachControl(
      UIHControl(controlReference),
      window.workspaceItems[@(itemIdentity)],
      fillParent);
}

void uih_macos_control_set_parent_tab(
    UIHMacWindowRef windowReference,
    UIHMacControlRef controlReference,
    uint64_t groupIdentity,
    uint64_t tabIdentity,
    int32_t fillParent) {
  UIHAssertMainThread();
  UIHMacWindowHandle *window = UIHWindow(windowReference);
  UIHMacTabGroupHandle *group = window.tabGroups[@(groupIdentity)];
  UIHMacTabHandle *tab = group.tabs[@(tabIdentity)];
  UIHAttachControl(UIHControl(controlReference), tab.contentView, fillParent);
}

void uih_macos_control_set_parent_status(
    UIHMacWindowRef windowReference,
    UIHMacControlRef controlReference,
    int32_t fillParent) {
  UIHAssertMainThread();
  UIHMacWindowHandle *window = UIHWindow(windowReference);
  UIHAttachControl(UIHControl(controlReference), window.workspaceStatus, fillParent);
}

void uih_macos_control_set_parent_control(
    UIHMacControlRef parentReference,
    UIHMacControlRef childReference,
    uint64_t slotIdentity,
    int32_t fillParent) {
  UIHAssertMainThread();
  UIHMacControlHandle *parent = UIHControl(parentReference);
  NSView *host = slotIdentity == 0
      ? parent.contentView
      : parent.slots[@(slotIdentity)];
  UIHAttachControl(UIHControl(childReference), host, fillParent);
  UIHLayoutContainer(parent);
}

static void UIHDetachCallbacks(NSView *view) {
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
    UIHDetachCallbacks(child);
  }
}

void uih_macos_control_destroy(UIHMacControlRef reference) {
  UIHAssertMainThread();
  if (reference == NULL) {
    return;
  }
  UIHMacControlHandle *handle = (__bridge_transfer UIHMacControlHandle *)reference;
  [UIHState.controls removeObjectForKey:@(handle.identity)];
  UIHDetachCallbacks(handle.view);
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
  UIHReleaseItemTargets(handle);
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

static BOOL UIHSelectCatalogSegment(UIHMacControlHandle *handle, uint64_t identity) {
  NSSegmentedControl *segments = nil;
  if ([handle.view isKindOfClass:NSSegmentedControl.class]) {
    segments = (NSSegmentedControl *)handle.view;
  } else if (handle.catalogKind == UIHMacCatalogTabView) {
    segments = (NSSegmentedControl *)UIHSubview(handle, @"tabs");
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

void uih_macos_test_schedule_control_gallery_script(
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
  UIHAssertMainThread();

  UIHTestAfter(0.12, ^{
    UIHMacWindowHandle *window = UIHState.windows[@(windowIdentity)];
    UIHMacControlHandle *rootTabs = UIHState.controls[@(rootTabIdentity)];
    UIHMacControlHandle *container = UIHState.controls[@(containerIdentity)];
    UIHMacControlHandle *nestedChild = UIHState.controls[@(nestedChildIdentity)];
    if (window == nil || rootTabs == nil || container == nil || nestedChild == nil) {
      UIHTestFail(@"control gallery window or structural controls were not registered");
      [NSApplication.sharedApplication stop:nil];
      return;
    }
    if (UIHState.controls.count < 89) {
      UIHTestFail([NSString stringWithFormat:
          @"control gallery registered only %lu of 89 controls",
          (unsigned long)UIHState.controls.count]);
    }

    BOOL seenCatalog[UIHMacCatalogContainer + 1] = {NO};
    BOOL seenLegacy[4] = {NO};
    UIHMacControlHandle *richText = nil;
    for (UIHMacControlHandle *control in UIHState.controls.allValues) {
      NSString *expectedIdentifier =
          [NSString stringWithFormat:@"uih-control-%llu", control.identity];
      if (![control.focusView.accessibilityIdentifier isEqualToString:expectedIdentifier]) {
        UIHTestFail([NSString stringWithFormat:
            @"control %llu lost its stable accessibility identity", control.identity]);
      }
      if (control.kind == UIHMacControlKindCatalog &&
          control.catalogKind >= UIHMacCatalogRichText &&
          control.catalogKind <= UIHMacCatalogContainer) {
        seenCatalog[control.catalogKind] = YES;
        if (control.catalogKind == UIHMacCatalogRichText) {
          richText = control;
        }
      } else if (control.kind >= UIHMacControlKindLabel &&
                 control.kind <= UIHMacControlKindTextEditor) {
        seenLegacy[control.kind] = YES;
      }
    }
    for (NSInteger kind = UIHMacCatalogRichText; kind <= UIHMacCatalogContainer; kind += 1) {
      if (!seenCatalog[kind]) {
        UIHTestFail([NSString stringWithFormat:@"catalog kind %ld has no native peer", (long)kind]);
      }
    }
    for (NSInteger kind = 0; kind < 4; kind += 1) {
      if (!seenLegacy[kind]) {
        UIHTestFail([NSString stringWithFormat:@"legacy control kind %ld is missing", (long)kind]);
      }
    }
    if (rootTabs.catalogKind != UIHMacCatalogTabView || rootTabs.slots.count != 5) {
      UIHTestFail(@"ordinary tab view did not retain all five gallery pages");
    }
    if (nestedChild.view.superview != container.contentView) {
      UIHTestFail(@"arbitrary child was not parented inside its semantic container");
    }
    if (richText == nil || ![richText.focusView isKindOfClass:NSTextView.class]) {
      UIHTestFail(@"rich text did not map to an attributed native text peer");
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
        UIHTestFail(@"rich text color, size, bold, or italic runs were not realized natively");
      }
    }

    UIHMacControlHandle *checkBox = UIHState.controls[@108];
    UIHMacControlHandle *nativeSwitch = UIHState.controls[@109];
    UIHMacControlHandle *radioGroup = UIHState.controls[@111];
    NSButton *firstRadio = (NSButton *)((NSStackView *)radioGroup.view).arrangedSubviews.firstObject;
    if (![checkBox.view isKindOfClass:NSButton.class] ||
        ((NSButton *)checkBox.view).title.length == 0 ||
        ![((NSButton *)checkBox.view).accessibilityRole isEqualToString:NSAccessibilityCheckBoxRole]) {
      UIHTestFail(@"checkbox did not retain its native indicator and visible label");
    }
    if (![nativeSwitch.focusView isKindOfClass:NSSwitch.class] ||
        ((NSTextField *)UIHSubview(nativeSwitch, @"switchLabel")).stringValue.length == 0) {
      UIHTestFail(@"switch did not retain its native peer and visible label");
    }
    if (![firstRadio isKindOfClass:NSButton.class] || firstRadio.title.length == 0 ||
        ((NSStackView *)radioGroup.view).arrangedSubviews.count != 3) {
      UIHTestFail(@"radio group did not retain native radio indicators and labels");
    }

    UIHMacControlHandle *listPeer = UIHState.controls[@301];
    UIHMacControlHandle *gridPeer = UIHState.controls[@302];
    UIHMacControlHandle *treePeer = UIHState.controls[@303];
    UIHMacControlHandle *tablePeer = UIHState.controls[@304];
    UIHMacControlHandle *repeaterPeer = UIHState.controls[@305];
    UIHMacControlHandle *sidebarPeer = UIHState.controls[@306];
    if (listPeer.collectionAdapter == nil || gridPeer.gridAdapter == nil ||
        treePeer.outlineAdapter == nil || tablePeer.collectionAdapter.table.tableColumns.count != 2 ||
        repeaterPeer.gridAdapter == nil || !repeaterPeer.gridAdapter.repeater ||
        sidebarPeer.collectionAdapter.table.style != NSTableViewStyleSourceList) {
      UIHTestFail(@"collection families collapsed to indistinguishable native peers");
    }

    rootTabs.slots[@9201].hidden = YES;
    rootTabs.slots[@9202].hidden = NO;
    UIHMacControlHandle *textInput = UIHState.controls[@(textInputIdentity)];
    if (textInput == nil || ![textInput.focusView isKindOfClass:NSTextView.class]) {
      UIHTestFail(@"gallery text area has no native text view");
      [NSApplication.sharedApplication stop:nil];
      return;
    }
    NSTextView *editor = (NSTextView *)textInput.focusView;
    [window.window makeFirstResponder:editor];
    editor.string = @"native gallery edit";
    [editor.delegate textDidChange:
        [NSNotification notificationWithName:NSTextDidChangeNotification object:editor]];

    UIHTestAfter(0.14, ^{
      UIHMacControlHandle *textMirror = UIHState.controls[@(textMirrorIdentity)];
      if (textMirror == nil ||
          ![((NSTextField *)textMirror.view).stringValue isEqualToString:@"native gallery edit"]) {
        UIHTestFail(@"typed text callback did not reconcile the shared gallery model");
      }
      UIHMacControlHandle *updatedTextInput = UIHState.controls[@(textInputIdentity)];
      if (window.window.firstResponder != updatedTextInput.focusView) {
        UIHTestFail(@"text-area reconciliation discarded the native first responder");
      }

      UIHMacControlHandle *toggle = UIHState.controls[@(toggleIdentity)];
      if (toggle == nil || ![toggle.view isKindOfClass:NSButton.class]) {
        UIHTestFail(@"gallery toggle has no native button peer");
      } else {
        [(NSButton *)toggle.view performClick:nil];
      }

      UIHTestAfter(0.14, ^{
        UIHMacControlHandle *updatedToggle = UIHState.controls[@(toggleIdentity)];
        if (((NSButton *)updatedToggle.view).state != NSControlStateValueOff) {
          UIHTestFail(@"typed toggle callback did not reconcile Boolean state");
        }
        UIHMacControlHandle *choice = UIHState.controls[@(choiceIdentity)];
        if (!UIHSelectCatalogSegment(choice, 2)) {
          UIHTestFail(@"segmented choice could not select its keyed second item");
        }

        UIHTestAfter(0.14, ^{
          UIHMacControlHandle *updatedChoice = UIHState.controls[@(choiceIdentity)];
          NSSegmentedControl *choiceSegments = (NSSegmentedControl *)updatedChoice.view;
          if (choiceSegments.selectedSegment < 0 ||
              [choiceSegments tagForSegment:choiceSegments.selectedSegment] != 2) {
            UIHTestFail(@"typed choice callback did not preserve keyed selection");
          }

          UIHMacControlHandle *numeric = UIHState.controls[@(numericIdentity)];
          NSSlider *slider = (NSSlider *)numeric.view;
          slider.doubleValue = 7;
          [slider sendAction:slider.action to:slider.target];

          UIHMacControlHandle *collection = UIHState.controls[@(collectionIdentity)];
          rootTabs.slots[@9202].hidden = YES;
          rootTabs.slots[@9203].hidden = NO;
          [window.window makeFirstResponder:collection.collectionAdapter.table];
          [collection.collectionAdapter.table
              selectRowIndexes:[NSIndexSet indexSetWithIndex:2]
             byExtendingSelection:NO];

          UIHTestAfter(0.16, ^{
            UIHMacControlHandle *updatedNumeric = UIHState.controls[@(numericIdentity)];
            if (fabs(((NSSlider *)updatedNumeric.view).doubleValue - 7) > 0.001) {
              UIHTestFail(@"typed numeric callback did not reconcile the slider value");
            }
            UIHMacControlHandle *updatedCollection = UIHState.controls[@(collectionIdentity)];
            if (![updatedCollection.collectionAdapter.table.selectedRowIndexes containsIndex:2]) {
              UIHTestFail(@"typed collection callback did not reconcile keyed selection");
            }
            if (window.window.firstResponder != updatedCollection.collectionAdapter.table) {
              UIHTestFail(@"collection reconciliation discarded the native first responder");
            }

            UIHMacControlHandle *updatedTabs = UIHState.controls[@(rootTabIdentity)];
            if (!UIHSelectCatalogSegment(updatedTabs, 9204)) {
              UIHTestFail(@"gallery shell tab could not be selected");
            }

            UIHTestAfter(0.14, ^{
              UIHMacControlHandle *dialogButton = UIHState.controls[@(dialogButtonIdentity)];
              if (dialogButton == nil || ![dialogButton.view isKindOfClass:NSButton.class]) {
                UIHTestFail(@"dialog command button has no native peer");
              } else {
                [(NSButton *)dialogButton.view performClick:nil];
              }

              UIHTestAfter(0.18, ^{
                UIHMacControlHandle *dialog = UIHState.controls[@(dialogIdentity)];
                if (dialog == nil || dialog.presentationWindow == nil ||
                    dialog.presentationWindow.sheetParent == nil) {
                  UIHTestFail(@"desired dialog state did not produce a native sheet");
                } else {
                  [dialog.presentationWindow.sheetParent
                      endSheet:dialog.presentationWindow
                     returnCode:NSAlertFirstButtonReturn];
                }

                UIHTestAfter(0.16, ^{
                  UIHMacControlHandle *popoverButton = UIHState.controls[@(popoverButtonIdentity)];
                  if (popoverButton == nil || ![popoverButton.view isKindOfClass:NSButton.class]) {
                    UIHTestFail(@"popover command button has no native peer");
                  } else {
                    [(NSButton *)popoverButton.view performClick:nil];
                  }

                  UIHTestAfter(0.18, ^{
                    UIHMacControlHandle *popover = UIHState.controls[@(popoverIdentity)];
                    if (popover == nil || popover.popover == nil || !popover.popover.shown ||
                        !popover.presentationVisible) {
                      UIHTestFail(@"desired popover state did not remain anchored and visible");
                    } else {
                      [popover.popover performClose:nil];
                    }

                    UIHTestAfter(0.35, ^{
                      UIHMacControlHandle *dismissedPopover = UIHState.controls[@(popoverIdentity)];
                      if (dismissedPopover != nil &&
                          (dismissedPopover.popover != nil || dismissedPopover.presentationVisible)) {
                        UIHTestFail(@"native popover dismissal did not reconcile desired state");
                      }
                      UIHMacWindowHandle *openWindow = UIHState.windows[@(windowIdentity)];
                      if (openWindow != nil) {
                        [openWindow.window performClose:nil];
                      }

                      UIHTestAfter(0.70, ^{
                        if (UIHState != nil) {
                          UIHTestFail(@"control gallery validation timed out before application stop");
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

void uih_macos_test_schedule_text_editor_script(
    uint64_t documentWindowIdentity,
    uint64_t editorIdentity,
    uint64_t tabIdentity,
    uint64_t saveCommandIdentity) {
  UIHAssertMainThread();

  UIHTestAfter(0.10, ^{
    UIHMacWindowHandle *documentWindow = UIHState.windows[@(documentWindowIdentity)];
    UIHMacControlHandle *editorHandle = UIHState.controls[@(editorIdentity)];
    UIHMacTabHandle *tabHandle = nil;
    for (UIHMacTabGroupHandle *group in documentWindow.tabGroups.allValues) {
      tabHandle = group.tabs[@(tabIdentity)];
      if (tabHandle != nil) {
        break;
      }
    }
    NSMenuItem *saveItem = UIHState.commandItems[@(saveCommandIdentity)];
    if (documentWindow == nil || editorHandle == nil || tabHandle == nil || saveItem == nil ||
        editorHandle.kind != UIHMacControlKindTextEditor) {
      UIHTestFail(@"native workspace, document tab, or text editor was not registered");
      [NSApplication.sharedApplication stop:nil];
      return;
    }
    if (documentWindow.workspaceSplit == nil ||
        documentWindow.workspaceSplit.subviews.count != 3 ||
        documentWindow.workspaceStatus == nil || tabHandle.contentView.hidden) {
      UIHTestFail(@"native workspace split, status area, or selected tab is incorrect");
    }
    [tabHandle.selectButton performClick:nil];

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
        UIHMacTabHandle *savedTab = nil;
        for (UIHMacTabGroupHandle *group in savedWindow.tabGroups.allValues) {
          savedTab = group.tabs[@(tabIdentity)];
          if (savedTab != nil) {
            break;
          }
        }
        if (savedTab == nil) {
          UIHTestFail(@"saved document tab disappeared before close-button validation");
          [NSApplication.sharedApplication stop:nil];
          return;
        }
        [savedTab.closeButton performClick:nil];

        UIHTestAfter(0.12, ^{
          UIHMacWindowHandle *emptyWorkspace = UIHState.windows[@(documentWindowIdentity)];
          BOOL tabStillPresent = NO;
          for (UIHMacTabGroupHandle *group in emptyWorkspace.tabGroups.allValues) {
            if (group.tabs[@(tabIdentity)] != nil) {
              tabStillPresent = YES;
            }
          }
          if (emptyWorkspace == nil || tabStillPresent) {
            UIHTestFail(@"clean tab close did not retain the workspace and remove only the tab");
            [NSApplication.sharedApplication stop:nil];
            return;
          }
          [emptyWorkspace.window performClose:nil];

          UIHTestAfter(0.30, ^{
            if (UIHState != nil && UIHState.windows[@(documentWindowIdentity)] != nil) {
              UIHTestFail(@"empty workspace close request did not remove its native window");
              [NSApplication.sharedApplication stop:nil];
            } else if (UIHState != nil) {
              [NSApplication.sharedApplication stop:nil];
            }
          });
        });
      });
    });
  });
}
