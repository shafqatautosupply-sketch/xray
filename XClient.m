// XClient.m - app side. Every privileged call runs /usr/libexec/xrayd (setuid root) and reads back a plist.
#import "XCore.h"
#include <spawn.h>
#include <crt_externs.h>
#include <sys/wait.h>
#include <sys/select.h>
#include <unistd.h>
#include <signal.h>
#include <string.h>
#include <stdlib.h>

#define XHELPER_PATH "/usr/libexec/xrayd"

// Starts the helper with its stdout connected to a pipe. Returns the child pid, or -1.
static pid_t XSpawn(NSArray *args, int *rfd) {
    int fds[2];
    if (pipe(fds) != 0) return -1;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
    posix_spawn_file_actions_addclose(&fa, fds[0]);
    posix_spawn_file_actions_addclose(&fa, fds[1]);
    int n = (int)[args count];
    char **argv = (char **)calloc(n + 2, sizeof(char *));
    argv[0] = (char *)"xrayd";
    for (int i = 0; i < n; i++) argv[i + 1] = (char *)[[args objectAtIndex:i] UTF8String];
    pid_t child = 0;
    int rc = posix_spawn(&child, XHELPER_PATH, &fa, NULL, argv, *_NSGetEnviron());
    posix_spawn_file_actions_destroy(&fa);
    free(argv);
    close(fds[1]);
    if (rc != 0) { close(fds[0]); return -1; }
    *rfd = fds[0];
    return child;
}

static id XParse(NSData *buf) {
    if (![buf length]) return nil;
    NSDictionary *d = [NSPropertyListSerialization propertyListWithData:buf options:NSPropertyListImmutable format:NULL error:NULL];
    if (![d isKindOfClass:[NSDictionary class]] || ![[d objectForKey:@"ok"] boolValue]) return nil;
    return [d objectForKey:@"v"];
}

static NSData *XReadAll(int fd) {
    NSMutableData *buf = [NSMutableData data];
    char tmp[16384];
    ssize_t r;
    while ((r = read(fd, tmp, sizeof(tmp))) > 0) [buf appendBytes:tmp length:r];
    return buf;
}

// One-shot call: run the helper, read its plist reply, return the "v" value (nil on any failure).
static id XCall(NSArray *args) {
    int rfd = -1;
    pid_t child = XSpawn(args, &rfd);
    if (child < 0) return nil;
    NSData *buf = XReadAll(rfd);
    close(rfd);
    int st;
    waitpid(child, &st, 0);
    return XParse(buf);
}

static NSString *XS(int v) { return [NSString stringWithFormat:@"%d", v]; }

@implementation XCore

+ (NSDictionary *)accessDict {
    static NSDictionary *cached = nil;
    static NSTimeInterval at = 0;
    @synchronized (self) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (!cached || now - at > 4) {
            [cached release];
            id v = XCall([NSArray arrayWithObjects:@"access", nil]);
            cached = [([v isKindOfClass:[NSDictionary class]] ? v : [NSDictionary dictionary]) retain];
            at = now;
        }
        return cached;
    }
}

+ (BOOL)hasKernelAccess { return [[[self accessDict] objectForKey:@"tfp"] boolValue]; }

+ (NSString *)accessInfo {
    NSDictionary *d = [self accessDict];
    if (![d objectForKey:@"uid"]) return nil;
    return [NSString stringWithFormat:@"running as uid %d / euid %d", [[d objectForKey:@"uid"] intValue], [[d objectForKey:@"euid"] intValue]];
}

+ (NSArray *)processList {
    NSArray *a = XCall([NSArray arrayWithObjects:@"procs", nil]);
    NSMutableArray *o = [NSMutableArray array];
    if ([a isKindOfClass:[NSArray class]]) for (NSDictionary *d in a) [o addObject:[XProc fromDict:d]];
    return o;
}

+ (XProc *)procForPid:(pid_t)pid {
    id v = XCall([NSArray arrayWithObjects:@"proc", XS(pid), nil]);
    if (![v isKindOfClass:[NSDictionary class]] || ![v count]) return nil;
    return [XProc fromDict:v];
}

+ (void)fillTaskInfo:(XProc *)p {}

+ (NSArray *)taskEventsForPid:(pid_t)pid {
    id v = XCall([NSArray arrayWithObjects:@"events", XS(pid), nil]);
    return [v isKindOfClass:[NSArray class]] ? v : nil;
}

+ (NSArray *)threadsForPid:(pid_t)pid {
    id v = XCall([NSArray arrayWithObjects:@"threads", XS(pid), nil]);
    if (![v isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *o = [NSMutableArray array];
    for (NSDictionary *d in v) [o addObject:[XThread fromDict:d]];
    return o;
}

+ (NSArray *)regionsForPid:(pid_t)pid {
    id v = XCall([NSArray arrayWithObjects:@"regions", XS(pid), nil]);
    if (![v isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *o = [NSMutableArray array];
    for (NSDictionary *d in v) [o addObject:[XRegion fromDict:d]];
    return o;
}

+ (NSArray *)openFilesForPid:(pid_t)pid {
    id v = XCall([NSArray arrayWithObjects:@"files", XS(pid), nil]);
    return [v isKindOfClass:[NSArray class]] ? v : nil;
}

+ (NSData *)readPid:(pid_t)pid addr:(uint32_t)a len:(uint32_t)len {
    id v = XCall([NSArray arrayWithObjects:@"read", XS(pid), [NSString stringWithFormat:@"%x", a], [NSString stringWithFormat:@"%u", len], nil]);
    return [v isKindOfClass:[NSData class]] ? v : nil;
}

+ (NSString *)symbolizeAddr:(uint32_t)a pid:(pid_t)pid { return [NSString stringWithFormat:@"0x%08x", a]; }
+ (NSString *)pathForPid:(pid_t)pid { return nil; }

+ (BOOL)signalPid:(pid_t)pid sig:(int)sig {
    id v = XCall([NSArray arrayWithObjects:@"signal", XS(pid), XS(sig), nil]);
    return [v boolValue];
}

@end

#pragma mark - Sampler: the helper does the whole 5 s run and returns the finished report

@implementation XSampler

- (id)initWithPid:(pid_t)p includeWaiting:(BOOL)w {
    self = [super init];
    if (self) { pid = p; waiting = w; child = -1; rfd = -1; }
    return self;
}

- (void)dealloc { [self finish]; [rows release]; [super dealloc]; }

- (BOOL)step {
    if (!started) {
        started = YES;
        child = XSpawn([NSArray arrayWithObjects:@"sample", XS(pid), waiting ? @"1" : @"0", @"5.0", nil], &rfd);
        if (child < 0) { done = YES; return NO; }
    }
    return !done;
}

- (void)finish {
    if (!started || done) return;
    done = YES;
    NSData *buf = XReadAll(rfd);       // blocks until the helper has finished sampling
    close(rfd);
    int st;
    waitpid(child, &st, 0);
    id v = XParse(buf);
    if ([v isKindOfClass:[NSDictionary class]]) {
        threadSamples = [[v objectForKey:@"n"] intValue];
        rows = [[v objectForKey:@"rows"] retain];
    }
}

- (int)threadSampleCount { return threadSamples; }
- (NSArray *)report { return rows ? rows : [NSArray array]; }

@end

#pragma mark - Trace: the helper streams decoded events, one per line (raw 0x1F simple)

@implementation XTrace

+ (XTrace *)shared {
    static XTrace *s = nil;
    if (!s) s = [[XTrace alloc] init];
    return s;
}

- (id)init {
    self = [super init];
    if (self) {
        events = [[NSMutableArray alloc] init];
        lock = [[NSLock alloc] init];
        child = -1;
        rfd = -1;
    }
    return self;
}

- (BOOL)running { return running; }
- (NSString *)lastError { return err; }
- (NSArray *)takeAll { return [self snapshot]; }

- (void)clear {
    [lock lock];
    [events removeAllObjects];
    [lock unlock];
}

- (NSArray *)snapshot {
    [lock lock];
    NSArray *a = [NSArray arrayWithArray:events];
    [lock unlock];
    return a;
}

// Reads one line (without the newline) with a timeout; returns nil on timeout or EOF.
static NSString *XReadLine(int fd, double secs) {
    NSMutableData *d = [NSMutableData data];
    NSTimeInterval end = [NSDate timeIntervalSinceReferenceDate] + secs;
    while (1) {
        double left = end - [NSDate timeIntervalSinceReferenceDate];
        if (left <= 0) return nil;
        fd_set fs;
        FD_ZERO(&fs);
        FD_SET(fd, &fs);
        struct timeval tv = { (int)left, (int)((left - (int)left) * 1e6) };
        if (select(fd + 1, &fs, NULL, NULL, &tv) <= 0) return nil;
        char c;
        if (read(fd, &c, 1) != 1) return nil;
        if (c == '\n') {
            if (![d length]) continue;   // skip heartbeat lines
            break;
        }
        [d appendBytes:&c length:1];
    }
    return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] autorelease];
}

- (BOOL)startFilter:(int)filter pid:(pid_t)p {
    if (running) [self stop];
    [err release]; err = nil;
    int fd = -1;
    pid_t c = XSpawn([NSArray arrayWithObjects:@"trace", XS(filter), XS(p), nil], &fd);
    if (c < 0) { err = [@"Could not start /usr/libexec/xrayd (is it installed and setuid root?)" retain]; return NO; }
    NSString *first = XReadLine(fd, 4.0);
    if (![first hasPrefix:@"OK"]) {
        err = [(first && [first length] > 4 ? [first substringFromIndex:4] : @"kdebug could not be started by the helper") retain];
        close(fd);
        int st;
        waitpid(c, &st, 0);
        return NO;
    }
    child = c;
    rfd = fd;
    stopFlag = NO;
    running = YES;
    readerBusy = YES;
    [NSThread detachNewThreadSelector:@selector(readLoop) toTarget:self withObject:nil];
    return YES;
}

// Closing our end makes the helper's next write fail; it then switches kdebug off and exits.
- (void)stop {
    if (!running) return;
    stopFlag = YES;
    running = NO;
    for (int i = 0; i < 75 && readerBusy; i++) usleep(20000);
}

- (void)readLoop {
    NSAutoreleasePool *outer = [[NSAutoreleasePool alloc] init];
    NSMutableData *acc = [NSMutableData data];
    char buf[8192];
    while (!stopFlag) {
        fd_set fs;
        FD_ZERO(&fs);
        FD_SET(rfd, &fs);
        struct timeval tv = { 0, 200000 };
        int s = select(rfd + 1, &fs, NULL, NULL, &tv);
        if (s < 0) break;
        if (s == 0) continue;
        ssize_t r = read(rfd, buf, sizeof(buf));
        if (r <= 0) break;
        [acc appendBytes:buf length:r];
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        const char *b = (const char *)[acc bytes];
        NSUInteger len = [acc length], start = 0;
        [lock lock];
        for (NSUInteger i = 0; i < len; i++) {
            if (b[i] != '\n') continue;
            if (i > start) {
                NSString *line = [[[NSString alloc] initWithBytes:b + start length:i - start encoding:NSUTF8StringEncoding] autorelease];
                NSRange sep = [line rangeOfString:@"\x1f"];
                if (line && sep.location != NSNotFound) {
                    XEvent *e = [[[XEvent alloc] init] autorelease];
                    e->raw = [[line substringToIndex:sep.location] retain];
                    NSString *sm = [line substringFromIndex:sep.location + 1];
                    e->simple = [sm length] ? [sm retain] : nil;
                    [events addObject:e];
                }
            }
            start = i + 1;
        }
        while ([events count] > 5000) [events removeObjectAtIndex:0];
        [lock unlock];
        if (start > 0) [acc replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
        [pool drain];
    }
    close(rfd);
    rfd = -1;
    int st;
    waitpid(child, &st, 0);
    child = -1;
    readerBusy = NO;
    [outer drain];
}

@end
