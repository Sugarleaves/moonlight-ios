//
//  DesktopTouchHandler.h
//  Moonlight
//

#import <UIKit/UIKit.h>

@class StreamView;

NS_ASSUME_NONNULL_BEGIN

@interface DesktopTouchHandler : UIResponder <UIGestureRecognizerDelegate>

- (instancetype)initWithView:(StreamView *)view nativeTouchRequested:(BOOL)nativeTouchRequested;
- (void)cancelAllInput;

@end

NS_ASSUME_NONNULL_END
