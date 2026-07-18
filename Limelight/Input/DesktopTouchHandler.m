//
//  DesktopTouchHandler.m
//  Moonlight
//

#import "DesktopTouchHandler.h"
#import "StreamView.h"

#include <Limelight.h>
#include <limits.h>

static const CGFloat DESKTOP_DRAG_THRESHOLD = 5.0;
static const CGFloat DESKTOP_SCROLL_THRESHOLD = 3.0;
static const CGFloat DESKTOP_SCROLL_SCALE = 10.0;
static const CGFloat DESKTOP_MOMENTUM_STOP_VELOCITY = 8.0;

@implementation DesktopTouchHandler {
    __weak StreamView *_view;
    BOOL _nativeTouchRequested;
    BOOL _nativeTouchActive;
    BOOL _nativeTouchFallbackLogged;
    NSMapTable<UITouch *, NSNumber *> *_pointerIds;
    uint32_t _nextPointerId;

    __weak UITouch *_primaryTouch;
    CGPoint _initialLocation;
    CGPoint _lastLocation;
    NSUInteger _peakTouchCount;
    BOOL _dragging;
    BOOL _scrollMoved;

    UIPanGestureRecognizer *_scrollRecognizer;
    CGPoint _lastScrollTranslation;
    CADisplayLink *_momentumDisplayLink;
    CGPoint _momentumVelocity;
    CFTimeInterval _lastMomentumTimestamp;
}

- (instancetype)initWithView:(StreamView *)view nativeTouchRequested:(BOOL)nativeTouchRequested {
    self = [super init];
    if (self) {
        _view = view;
        _nextPointerId = 1;
        _pointerIds = [NSMapTable strongToStrongObjectsMapTable];
        // Host capabilities are populated during connection setup, after StreamView is
        // constructed. Resolve native touch lazily on the first interaction.
        _nativeTouchRequested = nativeTouchRequested;
        _scrollRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleScroll:)];
        _scrollRecognizer.minimumNumberOfTouches = 2;
        _scrollRecognizer.maximumNumberOfTouches = 2;
        _scrollRecognizer.cancelsTouchesInView = NO;
        _scrollRecognizer.delegate = self;
        [view addGestureRecognizer:_scrollRecognizer];
    }
    return self;
}

- (void)resolveNativeTouchMode {
    if (!_nativeTouchRequested || _nativeTouchActive) {
        return;
    }

    if ((LiGetHostFeatureFlags() & LI_FF_PEN_TOUCH_EVENTS) != 0) {
        _nativeTouchActive = YES;
        _scrollRecognizer.enabled = NO;
        Log(LOG_I, @"Using native host touch injection for Desktop Touch Mode");
    } else if (!_nativeTouchFallbackLogged) {
        _nativeTouchFallbackLogged = YES;
        Log(LOG_W, @"Native desktop touch unsupported by host; using mouse emulation");
    }
}

- (void)dealloc {
    [_momentumDisplayLink invalidate];
    if (_scrollRecognizer != nil) {
        [_view removeGestureRecognizer:_scrollRecognizer];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (CGPoint)locationForTouches:(NSSet<UITouch *> *)touches {
    CGFloat x = 0;
    CGFloat y = 0;
    for (UITouch *touch in touches) {
        CGPoint location = [touch locationInView:_view];
        x += location.x;
        y += location.y;
    }
    return CGPointMake(x / touches.count, y / touches.count);
}

- (void)sendClickForButton:(int)button atLocation:(CGPoint)location {
    [_view updateCursorLocation:location isMouse:NO];
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, button);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, button);
    });
}

- (void)sendNativeTouches:(NSSet<UITouch *> *)touches type:(uint8_t)type removeAfter:(BOOL)removeAfter {
    for (UITouch *touch in touches) {
        NSNumber *pointerId = [_pointerIds objectForKey:touch];
        if (pointerId == nil && type == LI_TOUCH_EVENT_DOWN) {
            pointerId = @(_nextPointerId++);
            [_pointerIds setObject:pointerId forKey:touch];
        }
        if (pointerId == nil) {
            continue;
        }

        CGPoint normalized = [_view normalizedVideoCoordinatesForPoint:[touch locationInView:_view]];
        CGFloat radius = touch.majorRadius;
        CGSize videoSize = [_view getVideoAreaSize];
        float contactMajor = videoSize.width > 0 ? (radius * 2.0) / videoSize.width : 0;
        float contactMinor = videoSize.height > 0 ? (radius * 2.0) / videoSize.height : 0;
        float pressure = touch.maximumPossibleForce > 0 ? touch.force / touch.maximumPossibleForce : 0;

        LiSendTouchEvent(type, pointerId.unsignedIntValue,
                         normalized.x, normalized.y, pressure,
                         contactMajor, contactMinor, LI_ROT_UNKNOWN);

        if (removeAfter) {
            [_pointerIds removeObjectForKey:touch];
        }
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self stopMomentum];
    [self resolveNativeTouchMode];
    if (_nativeTouchActive) {
        [self sendNativeTouches:touches type:LI_TOUCH_EVENT_DOWN removeAfter:NO];
        return;
    }

    NSUInteger count = event.allTouches.count;
    _peakTouchCount = MAX(_peakTouchCount, count);
    if (count == 1) {
        _primaryTouch = event.allTouches.anyObject;
        _initialLocation = _lastLocation = [_primaryTouch locationInView:_view];
        _scrollMoved = NO;
    } else {
        if (_dragging) {
            LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
            _dragging = NO;
        }
        _lastLocation = [self locationForTouches:event.allTouches];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_nativeTouchActive) {
        [self sendNativeTouches:touches type:LI_TOUCH_EVENT_MOVE removeAfter:NO];
        return;
    }

    if (event.allTouches.count != 1 || _primaryTouch == nil || _peakTouchCount > 1) {
        return;
    }

    CGPoint location = [_primaryTouch locationInView:_view];
    if (!_dragging && hypot(location.x - _initialLocation.x, location.y - _initialLocation.y) >= DESKTOP_DRAG_THRESHOLD) {
        [_view updateCursorLocation:_initialLocation isMouse:NO];
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
        _dragging = YES;
    }
    if (_dragging) {
        [_view updateCursorLocation:location isMouse:NO];
    }
    _lastLocation = location;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_nativeTouchActive) {
        [self sendNativeTouches:touches type:LI_TOUCH_EVENT_UP removeAfter:YES];
        return;
    }

    if (event.allTouches.count != touches.count) {
        return;
    }

    if (_dragging) {
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    } else if (!_scrollMoved) {
        if (_peakTouchCount == 1) {
            [self sendClickForButton:BUTTON_LEFT atLocation:_lastLocation];
        } else if (_peakTouchCount == 2) {
            [self sendClickForButton:BUTTON_RIGHT atLocation:_lastLocation];
        }
    }

    _primaryTouch = nil;
    _peakTouchCount = 0;
    _dragging = NO;
    _scrollMoved = NO;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_nativeTouchActive) {
        [self sendNativeTouches:touches type:LI_TOUCH_EVENT_CANCEL removeAfter:YES];
    } else {
        [self cancelAllInput];
    }
}

- (void)sendScrollDelta:(CGPoint)delta {
    short vertical = (short)MAX(SHRT_MIN, MIN(SHRT_MAX, delta.y * DESKTOP_SCROLL_SCALE));
    short horizontal = (short)MAX(SHRT_MIN, MIN(SHRT_MAX, -delta.x * DESKTOP_SCROLL_SCALE));
    if (vertical != 0) {
        LiSendHighResScrollEvent(vertical);
    }
    if (horizontal != 0) {
        LiSendHighResHScrollEvent(horizontal);
    }
}

- (void)handleScroll:(UIPanGestureRecognizer *)recognizer {
    CGPoint translation = [recognizer translationInView:_view];
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            [self stopMomentum];
            _lastScrollTranslation = translation;
            break;
        case UIGestureRecognizerStateChanged: {
            CGPoint delta = CGPointMake(translation.x - _lastScrollTranslation.x,
                                        translation.y - _lastScrollTranslation.y);
            if (hypot(translation.x, translation.y) >= DESKTOP_SCROLL_THRESHOLD) {
                _scrollMoved = YES;
            }
            [self sendScrollDelta:delta];
            _lastScrollTranslation = translation;
            break;
        }
        case UIGestureRecognizerStateEnded:
            if (_scrollMoved) {
                [self startMomentumWithVelocity:[recognizer velocityInView:_view]];
            }
            _lastScrollTranslation = CGPointZero;
            break;
        default:
            _lastScrollTranslation = CGPointZero;
            break;
    }
}

- (void)startMomentumWithVelocity:(CGPoint)velocity {
    _momentumVelocity = velocity;
    _lastMomentumTimestamp = 0;
    _momentumDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(momentumTick:)];
    [_momentumDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)momentumTick:(CADisplayLink *)displayLink {
    if (_lastMomentumTimestamp == 0) {
        _lastMomentumTimestamp = displayLink.timestamp;
        return;
    }
    CFTimeInterval elapsed = displayLink.timestamp - _lastMomentumTimestamp;
    _lastMomentumTimestamp = displayLink.timestamp;
    [self sendScrollDelta:CGPointMake(_momentumVelocity.x * elapsed, _momentumVelocity.y * elapsed)];

    // UIScrollViewDecelerationRateNormal is a per-millisecond decay factor.
    CGFloat decay = pow(UIScrollViewDecelerationRateNormal, elapsed * 1000.0);
    _momentumVelocity = CGPointMake(_momentumVelocity.x * decay, _momentumVelocity.y * decay);
    if (hypot(_momentumVelocity.x, _momentumVelocity.y) < DESKTOP_MOMENTUM_STOP_VELOCITY) {
        [self stopMomentum];
    }
}

- (void)stopMomentum {
    [_momentumDisplayLink invalidate];
    _momentumDisplayLink = nil;
    _lastMomentumTimestamp = 0;
}

- (void)cancelAllInput {
    [self stopMomentum];
    if (_nativeTouchActive) {
        LiSendTouchEvent(LI_TOUCH_EVENT_CANCEL_ALL, 0, 0, 0, 0, 0, 0, LI_ROT_UNKNOWN);
        [_pointerIds removeAllObjects];
    }
    if (_dragging) {
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    }
    _primaryTouch = nil;
    _peakTouchCount = 0;
    _dragging = NO;
    _scrollMoved = NO;
}

@end
