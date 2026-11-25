// XSkin.m - skeuomorphic drawing code (no image assets: everything is drawn with CoreGraphics)
#import "XCore.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <stdlib.h>

static CGGradientRef XGrad(CGFloat *c, CGFloat *loc, int n) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, c, loc, n);
    CGColorSpaceRelease(cs);
    return g;
}

UIColor *XLinen(void) {
    static UIColor *c = nil;
    if (!c) {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(64, 64), YES, 0);
        CGContextRef g = UIGraphicsGetCurrentContext();
        CGContextSetRGBFillColor(g, 0.60, 0.63, 0.67, 1);
        CGContextFillRect(g, CGRectMake(0, 0, 64, 64));
        srand(7);
        for (int i = 0; i < 64; i += 2) {
            CGFloat a = (rand() % 100) / 100.0 * 0.10;
            CGContextSetRGBFillColor(g, 1, 1, 1, a);
            CGContextFillRect(g, CGRectMake(0, i, 64, 1));
            a = (rand() % 100) / 100.0 * 0.10;
            CGContextSetRGBFillColor(g, 0, 0, 0, a);
            CGContextFillRect(g, CGRectMake(i, 0, 1, 64));
        }
        UIImage *im = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        c = [[UIColor colorWithPatternImage:im] retain];
    }
    return c;
}

#pragma mark - Leather panel with stitching

@implementation XLeather

- (id)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)drawRect:(CGRect)r {
    CGContextRef g = UIGraphicsGetCurrentContext();
    CGRect b = self.bounds;
    CGFloat c[] = { 0.34, 0.21, 0.13, 1, 0.17, 0.09, 0.05, 1 };
    CGFloat l[] = { 0, 1 };
    CGGradientRef gr = XGrad(c, l, 2);
    CGContextDrawLinearGradient(g, gr, CGPointMake(0, 0), CGPointMake(0, b.size.height), 0);
    CGGradientRelease(gr);
    srand(11);
    int w = (int)b.size.width, h = (int)b.size.height;
    for (int i = 0; i < 1400 && w > 0 && h > 0; i++) {
        CGFloat x = rand() % w, y = rand() % h;
        CGFloat a = (rand() % 100) / 100.0 * 0.18;
        if (i & 1) CGContextSetRGBFillColor(g, 1, 0.9, 0.8, a * 0.6);
        else CGContextSetRGBFillColor(g, 0, 0, 0, a);
        CGContextFillRect(g, CGRectMake(x, y, 1.5, 1.5));
    }
    CGContextSetRGBFillColor(g, 0, 0, 0, 0.35);
    CGContextFillRect(g, CGRectMake(0, 0, b.size.width, 2));
    CGContextSetRGBFillColor(g, 1, 1, 1, 0.12);
    CGContextFillRect(g, CGRectMake(0, b.size.height - 1, b.size.width, 1));
    UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, 6, 6) cornerRadius:8];
    CGFloat dash[] = { 5, 3 };
    [p setLineDash:dash count:2 phase:0];
    p.lineWidth = 1.2;
    CGContextSaveGState(g);
    CGContextTranslateCTM(g, 0, 1);
    [[UIColor colorWithWhite:0 alpha:0.6] setStroke];
    [p stroke];
    CGContextRestoreGState(g);
    [[UIColor colorWithRed:0.88 green:0.75 blue:0.52 alpha:1] setStroke];
    [p stroke];
}

@end

#pragma mark - Chrome gauge with animated needle

@implementation XGauge

- (id)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
    }
    return self;
}

- (void)dealloc {
    [timer invalidate];
    [caption release];
    [super dealloc];
}

- (void)setCaption:(NSString *)c {
    [caption release];
    caption = [c copy];
    [self setNeedsDisplay];
}

- (void)setValue:(double)v {
    target = v < 0 ? 0 : (v > 100 ? 100 : v);
    if (!timer) timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)tick {
    double d = target - shown;
    if (fabs(d) < 0.2) {
        shown = target;
        [timer invalidate];
        timer = nil;
    } else {
        shown += d * 0.25;
    }
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef g = UIGraphicsGetCurrentContext();
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat S = MIN(W, H - 22);
    CGFloat cx = W / 2, cy = S / 2 + 2, R = S / 2 - 3;

    // drop shadow under the bezel
    CGContextSaveGState(g);
    CGContextSetShadowWithColor(g, CGSizeMake(0, 2), 5, [UIColor colorWithWhite:0 alpha:0.7].CGColor);
    CGContextSetRGBFillColor(g, 0.1, 0.1, 0.1, 1);
    CGContextFillEllipseInRect(g, CGRectMake(cx - R, cy - R, 2 * R, 2 * R));
    CGContextRestoreGState(g);

    // chrome ring
    CGContextSaveGState(g);
    CGContextAddEllipseInRect(g, CGRectMake(cx - R, cy - R, 2 * R, 2 * R));
    CGContextAddEllipseInRect(g, CGRectMake(cx - R + 7, cy - R + 7, 2 * R - 14, 2 * R - 14));
    CGContextEOClip(g);
    CGFloat ch[] = { 0.98, 0.98, 0.98, 1, 0.55, 0.56, 0.58, 1, 0.85, 0.86, 0.88, 1, 0.30, 0.31, 0.33, 1 };
    CGFloat cl[] = { 0, 0.45, 0.6, 1 };
    CGGradientRef cg = XGrad(ch, cl, 4);
    CGContextDrawLinearGradient(g, cg, CGPointMake(cx, cy - R), CGPointMake(cx, cy + R), 0);
    CGGradientRelease(cg);
    CGContextRestoreGState(g);

    // dark face
    CGFloat fr = R - 7;
    CGContextSaveGState(g);
    CGContextAddEllipseInRect(g, CGRectMake(cx - fr, cy - fr, 2 * fr, 2 * fr));
    CGContextClip(g);
    CGFloat fc[] = { 0.20, 0.23, 0.26, 1, 0.02, 0.03, 0.04, 1 };
    CGFloat fl[] = { 0, 1 };
    CGGradientRef fg = XGrad(fc, fl, 2);
    CGContextDrawRadialGradient(g, fg, CGPointMake(cx, cy - fr * 0.25), 0, CGPointMake(cx, cy), fr,
                                kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(fg);

    // red zone and tick marks (270 degree sweep, starting lower-left)
    double a0 = 135 * M_PI / 180, sweep = 270 * M_PI / 180;
    CGContextSetRGBStrokeColor(g, 0.85, 0.12, 0.10, 0.9);
    CGContextSetLineWidth(g, 4);
    CGContextAddArc(g, cx, cy, fr - 9, a0 + sweep * 0.8, a0 + sweep, 0);
    CGContextStrokePath(g);
    for (int i = 0; i <= 20; i++) {
        double a = a0 + sweep * (i / 20.0);
        BOOL major = (i % 4 == 0);
        double r1 = fr - 4, r2 = fr - (major ? 15 : 10);
        CGContextSetRGBStrokeColor(g, 0.92, 0.92, 0.85, major ? 0.95 : 0.55);
        CGContextSetLineWidth(g, major ? 2 : 1);
        CGContextMoveToPoint(g, cx + cos(a) * r1, cy + sin(a) * r1);
        CGContextAddLineToPoint(g, cx + cos(a) * r2, cy + sin(a) * r2);
        CGContextStrokePath(g);
    }

    // digital readout
    NSString *num = [NSString stringWithFormat:@"%.0f%%", shown];
    [[UIColor colorWithRed:0.55 green:1 blue:0.65 alpha:0.9] set];
    [num drawInRect:CGRectMake(cx - 30, cy + fr * 0.30, 60, 18) withFont:[UIFont boldSystemFontOfSize:14]
      lineBreakMode:UILineBreakModeClip alignment:UITextAlignmentCenter];

    // needle
    double na = a0 + sweep * (shown / 100.0);
    CGContextSaveGState(g);
    CGContextTranslateCTM(g, cx, cy);
    CGContextRotateCTM(g, na);
    CGContextSetShadowWithColor(g, CGSizeMake(2, 2), 3, [UIColor colorWithWhite:0 alpha:0.8].CGColor);
    CGContextSetRGBFillColor(g, 0.95, 0.18, 0.12, 1);
    CGContextMoveToPoint(g, fr - 12, 0);
    CGContextAddLineToPoint(g, -8, 3);
    CGContextAddLineToPoint(g, -8, -3);
    CGContextClosePath(g);
    CGContextFillPath(g);
    CGContextRestoreGState(g);
    CGContextSetRGBFillColor(g, 0.75, 0.75, 0.78, 1);
    CGContextFillEllipseInRect(g, CGRectMake(cx - 6, cy - 6, 12, 12));
    CGContextSetRGBStrokeColor(g, 0, 0, 0, 0.6);
    CGContextSetLineWidth(g, 1);
    CGContextStrokeEllipseInRect(g, CGRectMake(cx - 6, cy - 6, 12, 12));

    // glass gloss
    CGContextAddEllipseInRect(g, CGRectMake(cx - fr * 0.9, cy - fr * 0.98, fr * 1.8, fr * 1.05));
    CGContextClip(g);
    CGFloat gc[] = { 1, 1, 1, 0.38, 1, 1, 1, 0.02 };
    CGFloat gl[] = { 0, 1 };
    CGGradientRef gg = XGrad(gc, gl, 2);
    CGContextDrawLinearGradient(g, gg, CGPointMake(cx, cy - fr), CGPointMake(cx, cy), 0);
    CGGradientRelease(gg);
    CGContextRestoreGState(g);

    // embossed caption
    if (caption) {
        UIFont *f = [UIFont boldSystemFontOfSize:13];
        CGRect cr = CGRectMake(0, S + 4, W, 16);
        [[UIColor blackColor] set];
        [caption drawInRect:CGRectOffset(cr, 0, -1) withFont:f lineBreakMode:UILineBreakModeClip alignment:UITextAlignmentCenter];
        [[UIColor colorWithRed:0.96 green:0.90 blue:0.78 alpha:1] set];
        [caption drawInRect:cr withFont:f lineBreakMode:UILineBreakModeClip alignment:UITextAlignmentCenter];
    }
}

@end

#pragma mark - 5-segment LED level bar

@implementation XLed

- (id)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
    }
    return self;
}

- (void)setLevel:(double)l {
    level = l;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)r {
    int n = 5;
    CGFloat w = (self.bounds.size.width - (n - 1) * 2) / n;
    int lit = level < 1.5 ? 0 : (int)ceil(level / 20.0);
    if (lit > n) lit = n;
    for (int i = 0; i < n; i++) {
        CGRect rr = CGRectMake(i * (w + 2), 1, w, self.bounds.size.height - 2);
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:rr cornerRadius:2];
        if (i < lit) {
            if (i < 3) [[UIColor colorWithRed:0.25 green:0.85 blue:0.30 alpha:1] setFill];
            else if (i == 3) [[UIColor colorWithRed:0.95 green:0.82 blue:0.20 alpha:1] setFill];
            else [[UIColor colorWithRed:0.92 green:0.20 blue:0.15 alpha:1] setFill];
        } else {
            [[UIColor colorWithWhite:0.20 alpha:1] setFill];
        }
        [p fill];
        if (i < lit) {
            [[UIColor colorWithWhite:1 alpha:0.30] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(rr.origin.x, rr.origin.y, rr.size.width, rr.size.height / 2) cornerRadius:2] fill];
        }
        [[UIColor colorWithWhite:0 alpha:0.5] setStroke];
        [p stroke];
    }
}

@end

#pragma mark - Tab icons (alpha masks, tinted by the tab bar)

UIImage *XIcon(int kind) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(30, 30), NO, 0);
    CGContextRef g = UIGraphicsGetCurrentContext();
    CGContextSetRGBStrokeColor(g, 0, 0, 0, 1);
    CGContextSetRGBFillColor(g, 0, 0, 0, 1);
    CGContextSetLineWidth(g, 2.5);
    CGContextSetLineCap(g, kCGLineCapRound);
    switch (kind) {
        case 0:   // gauge
            CGContextAddArc(g, 15, 17, 11, M_PI * 0.75, M_PI * 2.25, 0);
            CGContextStrokePath(g);
            CGContextMoveToPoint(g, 15, 17);
            CGContextAddLineToPoint(g, 21, 9);
            CGContextStrokePath(g);
            CGContextFillEllipseInRect(g, CGRectMake(12, 14, 6, 6));
            break;
        case 1:   // list
            for (int i = 0; i < 3; i++) {
                [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(6, 6 + i * 8, 18, 4) cornerRadius:2] fill];
            }
            break;
        case 2:   // pulse
            CGContextMoveToPoint(g, 3, 16);
            CGContextAddLineToPoint(g, 9, 16);
            CGContextAddLineToPoint(g, 12, 6);
            CGContextAddLineToPoint(g, 16, 25);
            CGContextAddLineToPoint(g, 20, 12);
            CGContextAddLineToPoint(g, 23, 16);
            CGContextAddLineToPoint(g, 27, 16);
            CGContextStrokePath(g);
            break;
        default:  // chip
            CGContextFillRect(g, CGRectMake(8, 8, 14, 14));
            CGContextSetLineWidth(g, 2);
            for (int i = 0; i < 3; i++) {
                CGFloat p = 10 + i * 5;
                CGContextMoveToPoint(g, p, 3); CGContextAddLineToPoint(g, p, 8);
                CGContextMoveToPoint(g, p, 22); CGContextAddLineToPoint(g, p, 27);
                CGContextMoveToPoint(g, 3, p); CGContextAddLineToPoint(g, 8, p);
                CGContextMoveToPoint(g, 22, p); CGContextAddLineToPoint(g, 27, p);
            }
            CGContextStrokePath(g);
            break;
    }
    UIImage *im = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return im;
}

void XApplySkin(void) {
    UIColor *leather = [UIColor colorWithRed:0.30 green:0.19 blue:0.12 alpha:1];
    [[UINavigationBar appearance] setTintColor:leather];
    [[UITabBar appearance] setTintColor:[UIColor colorWithWhite:0.20 alpha:1]];
    [[UISearchBar appearance] setTintColor:leather];
    NSDictionary *t = [NSDictionary dictionaryWithObjectsAndKeys:
        [UIColor colorWithRed:0.96 green:0.90 blue:0.78 alpha:1], UITextAttributeTextColor,
        [UIColor blackColor], UITextAttributeTextShadowColor,
        [NSValue valueWithUIOffset:UIOffsetMake(0, -1)], UITextAttributeTextShadowOffset, nil];
    [[UINavigationBar appearance] setTitleTextAttributes:t];
}
