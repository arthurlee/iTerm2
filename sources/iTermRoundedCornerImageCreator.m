//
//  iTermRoundedCornerImageCreator.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 2/9/20.
//

#import "iTermRoundedCornerImageCreator.h"

#import "NSImage+iTerm.h"

@implementation iTermRoundedCornerImageCreator {
    CGFloat _inset;
}

- (instancetype)initWithColor:(id)color
                         size:(NSSize)size
                       radius:(CGFloat)radius
              strokeThickness:(CGFloat)strokeThickness {
    self = [super init];
    if (self) {
        _color = color;
        _size = size;
        _radius = radius;
        _strokeThickness = strokeThickness;
        _inset = strokeThickness / 2.0;
    }
    return self;
}

// (0,radius) (radius,radius)
//  +--------+
//  |        |
//  |        |
//  |        |
//  +--------+
// (0,0)  (radius,0)

- (NSImage *)bottomLeft {
    return [self imageStartingAt:NSMakePoint(_inset, _radius)
                        endingAt:NSMakePoint(_radius, _inset)
                      controlsAt:NSMakePoint(_inset, _inset)];
}

- (NSImage *)bottomRight {
    return [self imageStartingAt:NSMakePoint(0, _inset)
                        endingAt:NSMakePoint(_radius - _inset, _radius)
                      controlsAt:NSMakePoint(_radius - _inset, _inset)];
}

- (NSImage *)topLeft {
    return [self imageStartingAt:NSMakePoint(_radius, _radius - _inset)
                        endingAt:NSMakePoint(_inset, 0)
                      controlsAt:NSMakePoint(_inset, _radius - _inset)];
}

- (NSImage *)topRight {
    return [self imageStartingAt:NSMakePoint(0, _radius - _inset)
                        endingAt:NSMakePoint(_radius - _inset, 0)
                      controlsAt:NSMakePoint(_radius - _inset, _radius - _inset)];
}

- (NSImage *)imageStartingAt:(NSPoint)start
                    endingAt:(NSPoint)end
                  controlsAt:(NSPoint)controls {
    return [NSImage imageOfSize:NSMakeSize(_radius, _radius) drawBlock:^{
        [[NSColor clearColor] set];
        NSRectFill(NSMakeRect(0, 0, _radius, _radius));
        NSBezierPath *path = [[NSBezierPath alloc] init];
        [path moveToPoint:start];
        if (_radius == 0) {
            [path lineToPoint:controls];
            [path lineToPoint:end];
        } else {
            [path curveToPoint:end controlPoint1:controls controlPoint2:controls];
        }
        [_color set];
        [path stroke];
    }];
}

@end
