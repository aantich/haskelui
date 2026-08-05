#ifndef UIH_APPKIT_COMPATIBILITY_H
#define UIH_APPKIT_COMPATIBILITY_H

#import <AppKit/AppKit.h>

NS_INLINE BOOL UIHAppKitIsMainThread(void) {
  return [NSThread isMainThread];
}

#endif
