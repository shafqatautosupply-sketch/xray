// XModel.m - code shared by the app and the helper: model classes, plist conversion, pure helpers
#import "XCore.h"
#include <string.h>

NSString *const XModeChanged = @"XModeChanged";

BOOL XIsPro(void) { return [[NSUserDefaults standardUserDefaults] boolForKey:@"xray.pro"]; }

void XSetPro(BOOL pro) {
    [[NSUserDefaults standardUserDefaults] setBool:pro forKey:@"xray.pro"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:XModeChanged object:nil];
}

NSString *XBytes(uint64_t b) {
    if (b < 1024) return [NSString stringWithFormat:@"%llu B", b];
    if (b < 1048576ULL) return [NSString stringWithFormat:@"%.1f KB", b / 1024.0];
    if (b < 1073741824ULL) return [NSString stringWithFormat:@"%.1f MB", b / 1048576.0];
    return [NSString stringWithFormat:@"%.2f GB", b / 1073741824.0];
}

NSString *XDur(double s) {
    if (s < 60) return [NSString stringWithFormat:@"%.0f s", s];
    if (s < 3600) return [NSString stringWithFormat:@"%.0f min", s / 60];
    if (s < 86400) return [NSString stringWithFormat:@"%.1f hours", s / 3600];
    return [NSString stringWithFormat:@"%.1f days", s / 86400];
}

#define NI(x) [NSNumber numberWithInt:(int)(x)]
#define NU(x) [NSNumber numberWithUnsignedLongLong:(unsigned long long)(x)]
#define ND(x) [NSNumber numberWithDouble:(x)]
#define GI(d, k) [[d objectForKey:k] intValue]
#define GU(d, k) [[d objectForKey:k] unsignedLongLongValue]
#define GD(d, k) [[d objectForKey:k] doubleValue]

#pragma mark - XProc

@implementation XProc
- (void)dealloc { [name release]; [path release]; [super dealloc]; }
@end

@implementation XProc (Plist)
- (NSDictionary *)toDict {
    return [NSDictionary dictionaryWithObjectsAndKeys:
        NI(pid), @"pid", NI(ppid), @"ppid", NU(uid), @"uid", NI(stat), @"stat",
        name ? name : @"", @"name", path ? path : @"", @"path",
        NI(haveTask), @"have", ND(cpu), @"cpu", NU(resident), @"res", NU(virt), @"virt",
        NI(threads), @"thr", NI(suspend), @"susp", ND(userTime), @"ut", ND(sysTime), @"st", nil];
}
+ (XProc *)fromDict:(NSDictionary *)d {
    XProc *p = [[[XProc alloc] init] autorelease];
    p->pid = GI(d, @"pid"); p->ppid = GI(d, @"ppid"); p->uid = (uid_t)GU(d, @"uid"); p->stat = GI(d, @"stat");
    p->name = [[d objectForKey:@"name"] copy];
    NSString *pa = [d objectForKey:@"path"];
    p->path = [pa length] ? [pa copy] : nil;
    p->haveTask = GI(d, @"have") != 0; p->cpu = GD(d, @"cpu");
    p->resident = GU(d, @"res"); p->virt = GU(d, @"virt");
    p->threads = GI(d, @"thr"); p->suspend = GI(d, @"susp");
    p->userTime = GD(d, @"ut"); p->sysTime = GD(d, @"st");
    return p;
}
@end

#pragma mark - XThread

@implementation XThread
- (void)dealloc { [frames release]; [symbols release]; [super dealloc]; }
@end

@implementation XThread (Plist)
- (NSDictionary *)toDict {
    NSMutableDictionary *m = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        NI(index), @"i", ND(cpu), @"cpu", NI(runState), @"rs", NI(flags), @"fl", NI(suspend), @"su",
        NI(sleepTime), @"sl", NI(policy), @"po", NU(tid), @"tid", NI(haveRegs), @"hr", nil];
    NSMutableArray *r = [NSMutableArray array];
    for (int i = 0; i < 17; i++) [r addObject:NU(regs[i])];
    [m setObject:r forKey:@"regs"];
    if (frames) [m setObject:frames forKey:@"fr"];
    if (symbols) [m setObject:symbols forKey:@"sy"];
    return m;
}
+ (XThread *)fromDict:(NSDictionary *)d {
    XThread *t = [[[XThread alloc] init] autorelease];
    t->index = GI(d, @"i"); t->cpu = GD(d, @"cpu"); t->runState = GI(d, @"rs"); t->flags = GI(d, @"fl");
    t->suspend = GI(d, @"su"); t->sleepTime = GI(d, @"sl"); t->policy = GI(d, @"po");
    t->tid = GU(d, @"tid"); t->haveRegs = GI(d, @"hr") != 0;
    NSArray *r = [d objectForKey:@"regs"];
    for (int i = 0; i < 17 && i < (int)[r count]; i++) t->regs[i] = (uint32_t)[[r objectAtIndex:i] unsignedLongLongValue];
    t->frames = [[d objectForKey:@"fr"] retain];
    t->symbols = [[d objectForKey:@"sy"] retain];
    return t;
}
@end

#pragma mark - XRegion

@implementation XRegion
- (void)dealloc { [file release]; [super dealloc]; }
@end

@implementation XRegion (Plist)
- (NSDictionary *)toDict {
    return [NSDictionary dictionaryWithObjectsAndKeys:
        NU(addr), @"a", NU(size), @"s", NU(resident), @"r", NI(prot), @"p", NI(maxprot), @"mp", NI(share), @"sh",
        file ? file : @"", @"f", nil];
}
+ (XRegion *)fromDict:(NSDictionary *)d {
    XRegion *r = [[[XRegion alloc] init] autorelease];
    r->addr = (uint32_t)GU(d, @"a"); r->size = (uint32_t)GU(d, @"s"); r->resident = (uint32_t)GU(d, @"r");
    r->prot = GI(d, @"p"); r->maxprot = GI(d, @"mp"); r->share = GI(d, @"sh");
    NSString *f = [d objectForKey:@"f"];
    r->file = [f length] ? [f copy] : nil;
    return r;
}
@end

#pragma mark - XEvent

@implementation XEvent
- (void)dealloc { [simple release]; [raw release]; [super dealloc]; }
@end

#pragma mark - pure helpers

@implementation XCore (Pure)

+ (NSString *)stateName:(int)s {
    switch (s) {
        case TH_STATE_RUNNING: return @"RUNNING";
        case TH_STATE_STOPPED: return @"STOPPED";
        case TH_STATE_WAITING: return @"WAITING";
        case TH_STATE_UNINTERRUPTIBLE: return @"UNINTERRUPTIBLE";
        case TH_STATE_HALTED: return @"HALTED";
    }
    return @"?";
}

+ (NSString *)describeTop:(XThread *)t {
    if (t->flags & TH_FLAGS_IDLE) return @"Kernel idle thread";
    NSString *s0 = [t->symbols count] > 0 ? [t->symbols objectAtIndex:0] : nil;
    NSString *s1 = [t->symbols count] > 1 ? [t->symbols objectAtIndex:1] : @"";
    if (!s0) return @"Couldn't read this thread (no access)";
    static const char *idleNames[] = { "mach_msg", "semaphore_wait", "semwait_signal", "psynch_cvwait",
        "kevent", "__select", "workq_kernreturn", "nanosleep", "usleep", "__sigwait", "__wait4", NULL };
    for (int i = 0; idleNames[i]; i++) {
        NSString *k = [NSString stringWithUTF8String:idleNames[i]];
        if ([s0 rangeOfString:k].location != NSNotFound || [s1 rangeOfString:k].location != NSNotFound)
            return @"Sleeping, waiting for something to do (normal)";
    }
    NSRange r = [s0 rangeOfString:@"+"];
    NSString *nm = r.location != NSNotFound ? [s0 substringToIndex:r.location] : s0;
    if (t->runState == TH_STATE_RUNNING) return [NSString stringWithFormat:@"Working in %@", nm];
    return [NSString stringWithFormat:@"Blocked in %@", nm];
}

@end
