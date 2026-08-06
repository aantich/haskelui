#ifndef HaskeLUI_APPKIT_COMPATIBILITY_H
#define HaskeLUI_APPKIT_COMPATIBILITY_H

#import <AppKit/AppKit.h>

NS_INLINE BOOL HaskeLUIAppKitIsMainThread(void) {
  return [NSThread isMainThread];
}

#endif
