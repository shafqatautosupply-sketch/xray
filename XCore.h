// XCore.h - shared declarations for Xray (app) and xrayd (root helper). Manual retain/release, armv7.
#import <Foundation/Foundation.h>
#ifndef XHELPER
#import <UIKit/UIKit.h>
#endif
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/types.h>

extern NSString *const XModeChanged;
BOOL XIsPro(void);
void XSetPro(BOOL pro);
NSString *XBytes(uint64_t b);
NSString *XDur(double secs);

#pragma mark - Data model (shared; converted to/from property lists to cross the helper pipe)

@interface XProc : NSObject {
@public
    pid_t pid, ppid;
    uid_t uid;
    int stat;
    NSString *name;
    NSString *path;
    BOOL haveTask;
    double cpu;
    uint64_t resident, virt;
    int threads, suspend;
    double userTime, sysTime;
}
@end
@interface XProc (Plist)
- (NSDictionary *)toDict;
+ (XProc *)fromDict:(NSDictionary *)d;
@end

@interface XThread : NSObject {
@public
    int index;
    double cpu;
    int runState, flags, suspend, sleepTime, policy;
    uint64_t tid;
    BOOL haveRegs;
    uint32_t regs[17];          // r0-r12, sp, lr, pc, cpsr
    NSArray *frames;            // NSNumber addresses, [0] = pc
    NSArray *symbols;           // NSString, parallel to frames
}
@end
@interface XThread (Plist)
- (NSDictionary *)toDict;
+ (XThread *)fromDict:(NSDictionary *)d;
@end

@interface XRegion : NSObject {
@public
    uint32_t addr, size, resident;
    int prot, maxprot, share;
    NSString *file;
}
@end
@interface XRegion (Plist)
- (NSDictionary *)toDict;
+ (XRegion *)fromDict:(NSDictionary *)d;
@end

#pragma mark - Privileged access. In xrayd this is the real implementation (XProc.m);
#pragma mark   in the app it is a thin client that runs /usr/libexec/xrayd (XClient.m).

@interface XCore : NSObject
+ (NSArray *)processList;
+ (XProc *)procForPid:(pid_t)pid;
+ (void)fillTaskInfo:(XProc *)p;
+ (NSArray *)taskEventsForPid:(pid_t)pid;       // NSArray of @[label, NSNumber]
+ (NSArray *)threadsForPid:(pid_t)pid;
+ (NSArray *)regionsForPid:(pid_t)pid;
+ (NSArray *)openFilesForPid:(pid_t)pid;        // NSDictionary: fd, type, path
+ (NSData *)readPid:(pid_t)pid addr:(uint32_t)a len:(uint32_t)len;   // read-only
+ (NSString *)symbolizeAddr:(uint32_t)a pid:(pid_t)pid;
+ (NSString *)pathForPid:(pid_t)pid;
+ (BOOL)hasKernelAccess;
+ (BOOL)signalPid:(pid_t)pid sig:(int)sig;      // STOP / CONT / TERM / KILL only
+ (NSString *)accessInfo;                       // helper uid/euid text, nil if helper is missing
@end

@interface XCore (Pure)                          // shared, no privileges needed
+ (NSString *)describeTop:(XThread *)t;
+ (NSString *)stateName:(int)runState;
@end

@interface XSampler : NSObject {
    pid_t pid;
    mach_port_t task;
    BOOL waiting;
    int steps, threadSamples;
    NSMutableDictionary *selfCount, *inclCount, *cache;
    // client side
    int child, rfd;
    BOOL started, done;
    NSArray *rows;
}
- (id)initWithPid:(pid_t)p includeWaiting:(BOOL)w;
- (BOOL)step;
- (void)finish;
- (int)threadSampleCount;
- (NSArray *)report;                            // NSDictionary: sym, self, total (sorted)
@end

#pragma mark - Kernel / host (no privileges needed; runs inside the app)

@interface XKern : NSObject
+ (NSDictionary *)vm;
+ (NSArray *)perCPULoads;
+ (NSString *)sysctlString:(const char *)name;
+ (uint64_t)sysctlNumber:(const char *)name;
+ (double)uptime;
+ (NSArray *)sysctlDump;
@end

#pragma mark - kdebug tracer

@interface XEvent : NSObject {
@public
    NSString *simple;                           // nil = hidden in Easy mode
    NSString *raw;
}
@end

@interface XTrace : NSObject {
    BOOL running, stopFlag, readerBusy;
    NSMutableArray *events;
    NSMutableDictionary *thrNames, *paths, *pathFirst;
    NSString *err;
    uint64_t t0;
    mach_timebase_info_data_t tb;
    NSLock *lock;
    int child, rfd;
}
+ (XTrace *)shared;
- (BOOL)startFilter:(int)filter pid:(pid_t)pid;  // 0 all, 1 BSD/files, 2 Mach, 3 FS, 4 Net, 5 IOKit
- (void)stop;
- (BOOL)running;
- (NSArray *)snapshot;                          // newest last
- (NSArray *)takeAll;                           // helper only: returns and removes everything
- (void)clear;
- (NSString *)lastError;
@end

#ifndef XHELPER
#pragma mark - Skin (skeuomorphic drawing)

UIColor *XLinen(void);
UIImage *XIcon(int kind);
void XApplySkin(void);

@interface XLeather : UIView
@end

@interface XGauge : UIView {
    double target, shown;
    NSTimer *timer;
    NSString *caption;
}
- (void)setValue:(double)v;
- (void)setCaption:(NSString *)c;
@end

@interface XLed : UIView {
    double level;
}
- (void)setLevel:(double)l;
@end

UIViewController *XMakeRoot(void);
#endif
