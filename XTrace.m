// XTrace.m - live kernel event trace through the kdebug sysctl interface (same one fs_usage uses)
#import "XCore.h"
#include <sys/sysctl.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

#ifndef KERN_KDEBUG
#define KERN_KDEBUG 24
#endif
#define KD_ENABLE 3
#define KD_SETBUF 4
#define KD_GETBUF 5
#define KD_SETUP 6
#define KD_REMOVE 7
#define KD_SETREG 8
#define KD_READTR 10
#define KD_PIDTR 11
#define KD_THRMAP 12

#define KDBG_CLASSTYPE 0x10000
#define KDBG_TYPENONE 0x80000

typedef struct { unsigned int type, value1, value2, value3, value4; } XKdReg;
typedef struct { uint64_t ts; uint32_t a1, a2, a3, a4, a5, dbg; } XKd;          // 32 bytes on armv7
typedef struct { uint32_t thread; int valid; char command[20]; } XKdThr;      // 28 bytes on armv7

static int KD(int op, int val, BOOL hasVal, void *buf, size_t *sz) {
    int mib[4] = { CTL_KERN, KERN_KDEBUG, op, val };
    return sysctl(mib, hasVal ? 4 : 3, buf, sz, NULL, 0);
}


#pragma mark - BSD syscall names (best effort; unknown numbers print as sysN)

static NSDictionary *XSysNames(void) {
    static NSDictionary *d = nil;
    if (d) return d;
    static const struct { int n; const char *s; } t[] = {
        {1,"exit"},{2,"fork"},{3,"read"},{4,"write"},{5,"open"},{6,"close"},{7,"wait4"},{9,"link"},
        {10,"unlink"},{12,"chdir"},{15,"chmod"},{20,"getpid"},{23,"setuid"},{24,"getuid"},{33,"access"},
        {36,"sync"},{37,"kill"},{39,"getppid"},{42,"pipe"},{54,"ioctl"},{58,"readlink"},{59,"execve"},
        {73,"munmap"},{74,"mprotect"},{75,"madvise"},{92,"fcntl"},{93,"select"},{97,"socket"},{98,"connect"},
        {104,"bind"},{106,"listen"},{116,"gettimeofday"},{117,"getrusage"},{118,"getsockopt"},{120,"readv"},
        {121,"writev"},{128,"rename"},{133,"sendto"},{134,"shutdown"},{136,"mkdir"},{137,"rmdir"},
        {138,"utimes"},{153,"pread"},{154,"pwrite"},{188,"stat"},{189,"fstat"},{190,"lstat"},{194,"getrlimit"},
        {195,"setrlimit"},{196,"getdirentries"},{197,"mmap"},{199,"lseek"},{200,"truncate"},{201,"ftruncate"},
        {202,"__sysctl"},{203,"mlock"},{204,"munlock"},{220,"getattrlist"},{221,"setattrlist"},
        {336,"proc_info"},{338,"stat64"},{339,"fstat64"},{340,"lstat64"},{344,"getdirentries64"},
        {360,"bsdthread_create"},{361,"bsdthread_terminate"},{362,"kqueue"},{363,"kevent"},
        {366,"bsdthread_register"},{367,"workq_open"},{368,"workq_kernreturn"},{372,"thread_selfid"},
        {396,"read_nocancel"},{397,"write_nocancel"},{398,"open_nocancel"},{399,"close_nocancel"},{0,NULL}
    };
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (int i = 0; t[i].s; i++)
        [m setObject:[NSString stringWithUTF8String:t[i].s] forKey:[NSNumber numberWithInt:t[i].n]];
    d = [m retain];
    return d;
}

static NSString *XSysName(int n) {
    NSString *s = [XSysNames() objectForKey:[NSNumber numberWithInt:n]];
    return s ? s : [NSString stringWithFormat:@"sys%d", n];
}

// Syscalls shown in Easy mode, with a plain-language verb.
static NSString *XVerb(NSString *n) {
    static NSDictionary *v = nil;
    if (!v) v = [[NSDictionary dictionaryWithObjectsAndKeys:
        @"opened", @"open", @"opened", @"open_nocancel", @"closed", @"close", @"closed", @"close_nocancel",
        @"read", @"read", @"read", @"read_nocancel", @"read", @"pread", @"wrote", @"write", @"wrote", @"write_nocancel",
        @"wrote", @"pwrite", @"looked up", @"stat", @"looked up", @"stat64", @"looked up", @"lstat",
        @"looked up", @"lstat64", @"checked access to", @"access", @"deleted", @"unlink", @"renamed", @"rename",
        @"created folder", @"mkdir", @"removed folder", @"rmdir", @"launched", @"execve", @"forked", @"fork",
        @"opened a socket", @"socket", @"connected", @"connect", @"sent data", @"sendto", @"mapped memory", @"mmap",
        @"sent a signal to", @"kill", @"changed permissions of", @"chmod", @"listed folder", @"getdirentries",
        @"listed folder", @"getdirentries64", nil] retain];
    return [v objectForKey:n];
}

static NSString *XClassName(int c) {
    switch (c) {
        case 1: return @"MACH"; case 2: return @"NET"; case 3: return @"FS"; case 4: return @"BSD";
        case 5: return @"IOKIT"; case 6: return @"DRV"; case 7: return @"TRACE"; case 8: return @"DLIL";
        case 9: return @"SEC"; case 20: return @"MISC"; case 31: return @"DYLD"; case 32: return @"QT";
        case 33: return @"APPS"; case 34: return @"LAUNCHD"; case 37: return @"PERF";
    }
    return [NSString stringWithFormat:@"C%d", c];
}

static NSString *XMachName(int n) {
    switch (n) {
        case 26: return @"mach_reply_port"; case 27: return @"thread_self_trap"; case 28: return @"task_self_trap";
        case 29: return @"host_self_trap"; case 31: return @"mach_msg_trap"; case 32: return @"mach_msg_overwrite";
    }
    return [NSString stringWithFormat:@"mach_trap%d", n];
}

#pragma mark - trace.codes (debugid -> name). Put the file in Resources/trace.codes before building.

static uint32_t gLookupId = 0x03010090u;   // VFS_LOOKUP; replaced by the value found in trace.codes

static NSDictionary *XCodes(void) {
    static NSDictionary *d = nil;
    static BOOL tried = NO;
    if (tried) return d;
    tried = YES;
    NSMutableArray *cands = [NSMutableArray array];
    NSString *bp = [[NSBundle mainBundle] pathForResource:@"trace" ofType:@"codes"];
    if (bp) [cands addObject:bp];
    [cands addObject:@"/usr/share/misc/trace.codes"];
    [cands addObject:@"/usr/libexec/trace.codes"];
    [cands addObject:@"/Applications/Xray.app/trace.codes"];
    [cands addObject:@"/var/mobile/trace.codes"];
    for (NSString *p in cands) {
        NSString *txt = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
        if (!txt) txt = [NSString stringWithContentsOfFile:p encoding:NSISOLatin1StringEncoding error:NULL];
        if (!txt) continue;
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
        for (NSString *line in [txt componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *t = [line stringByTrimmingCharactersInSet:ws];
            if (![t length] || [t hasPrefix:@"#"]) continue;
            NSMutableArray *f = [NSMutableArray array];
            for (NSString *x in [t componentsSeparatedByCharactersInSet:ws]) if ([x length]) [f addObject:x];
            if ([f count] < 2) continue;
            NSString *ids = [f objectAtIndex:0];
            if (![ids hasPrefix:@"0x"] && ![ids hasPrefix:@"0X"]) continue;
            uint32_t code = (uint32_t)strtoul([ids UTF8String], NULL, 16) & ~3u;
            NSString *nm = [f objectAtIndex:1];
            [m setObject:nm forKey:[NSNumber numberWithUnsignedInt:code]];
            if ([nm isEqualToString:@"VFS_LOOKUP"]) gLookupId = code;
        }
        if ([m count]) { d = [m retain]; break; }
    }
    return d;
}

#pragma mark - tracer

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
        thrNames = [[NSMutableDictionary alloc] init];
        paths = [[NSMutableDictionary alloc] init];
        pathFirst = [[NSMutableDictionary alloc] init];
        lock = [[NSLock alloc] init];
        mach_timebase_info(&tb);
    }
    return self;
}

- (BOOL)running { return running; }
- (NSString *)lastError { return err; }

- (NSArray *)takeAll {
    [lock lock];
    NSArray *a = [NSArray arrayWithArray:events];
    [events removeAllObjects];
    [lock unlock];
    return a;
}

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

- (BOOL)startFilter:(int)filter pid:(pid_t)pid {
    if (running) [self stop];
    [err release]; err = nil;
    (void)XCodes();   // load trace.codes now so the VFS_LOOKUP id is known before the first event
    size_t sz = 0;
    KD(KD_REMOVE, 0, NO, NULL, &sz);
    int nbufs = 32768;
    sz = 0;
    if (KD(KD_SETBUF, nbufs, YES, NULL, &sz) != 0) { err = [@"kdebug refused buffer setup (needs root: is the app setuid root?)" retain]; return NO; }
    sz = 0;
    if (KD(KD_SETUP, 0, NO, NULL, &sz) != 0) { err = [@"kdebug setup failed (another tracer running?)" retain]; return NO; }
    if (filter > 0) {
        static const int classes[] = { 0, 4, 1, 3, 2, 5 };
        XKdReg r;
        memset(&r, 0, sizeof(r));
        r.type = KDBG_CLASSTYPE;
        r.value1 = classes[filter];
        r.value2 = classes[filter];
        sz = sizeof(r);
        KD(KD_SETREG, 0, NO, &r, &sz);
    }
    if (pid > 0) {
        XKdReg p;
        memset(&p, 0, sizeof(p));
        p.type = KDBG_TYPENONE;
        p.value1 = pid;
        p.value2 = 1;
        sz = sizeof(p);
        KD(KD_PIDTR, 0, NO, &p, &sz);
    }
    sz = 0;
    if (KD(KD_ENABLE, 1, YES, NULL, &sz) != 0) { err = [@"kdebug could not be enabled" retain]; return NO; }

    // Thread -> process name map (snapshot taken when tracing was enabled).
    [thrNames removeAllObjects];
    unsigned char info[64];
    memset(info, 0, sizeof(info));
    sz = sizeof(info);
    if (KD(KD_GETBUF, 0, NO, info, &sz) == 0) {
        int nthr;
        memcpy(&nthr, info + 12, 4);   // kbufinfo_t.nkdthreads
        if (nthr > 0 && nthr < 50000) {
            size_t bytes = (size_t)nthr * sizeof(XKdThr);
            XKdThr *tm = (XKdThr *)calloc(nthr, sizeof(XKdThr));
            if (tm) {
                if (KD(KD_THRMAP, 0, NO, tm, &bytes) == 0) {
                    int cnt = (int)(bytes / sizeof(XKdThr));
                    if (cnt > nthr) cnt = nthr;
                    for (int i = 0; i < cnt; i++) {
                        tm[i].command[19] = 0;
                        NSString *s = [NSString stringWithUTF8String:tm[i].command];
                        if (s && [s length])
                            [thrNames setObject:s forKey:[NSNumber numberWithUnsignedInt:tm[i].thread]];
                    }
                }
                free(tm);
            }
        }
    }
    [paths removeAllObjects];
    [pathFirst removeAllObjects];
    t0 = 0;
    stopFlag = NO;
    running = YES;
    [NSThread detachNewThreadSelector:@selector(loop) toTarget:self withObject:nil];
    return YES;
}

- (void)stop {
    if (!running) return;
    stopFlag = YES;
    running = NO;
    usleep(150000);   // let the reader thread finish its current read
    size_t sz = 0;
    KD(KD_ENABLE, 0, YES, NULL, &sz);
    sz = 0;
    KD(KD_REMOVE, 0, NO, NULL, &sz);
}

- (void)loop {
    NSAutoreleasePool *outer = [[NSAutoreleasePool alloc] init];
    const int N = 4096;
    XKd *buf = (XKd *)malloc(sizeof(XKd) * N);
    while (!stopFlag && buf) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        size_t need = sizeof(XKd) * N;
        int count = 0;
        if (KD(KD_READTR, 0, NO, buf, &need) == 0) {
            count = (int)need;               // kdebug returns the number of records here
            if (count > N) count = (int)(need / sizeof(XKd));
        }
        if (count > 0) {
            [lock lock];
            for (int i = 0; i < count; i++) [self ingest:&buf[i]];
            while ([events count] > 5000) [events removeObjectAtIndex:0];
            [lock unlock];
        }
        [pool drain];
        if (count < N / 2) usleep(100000);
    }
    free(buf);
    [outer drain];
}

// Called with the lock held.
- (void)ingest:(XKd *)b {
    uint64_t ts = b->ts & 0x00ffffffffffffffULL;
    int cpu = (int)(b->ts >> 56);
    uint32_t did = b->dbg;
    int cls = (int)(did >> 24), sub = (int)((did >> 16) & 0xff), code = (int)((did >> 2) & 0x3fff), fn = (int)(did & 3);
    NSNumber *tk = [NSNumber numberWithUnsignedInt:b->a5];
    if (!t0) t0 = ts;
    double secs = (double)(ts - t0) * tb.numer / tb.denom / 1e9;
    NSString *proc = [thrNames objectForKey:tk];
    if (!proc) proc = [NSString stringWithFormat:@"t%x", b->a5 & 0xffff];

    // VFS lookup events carry the path text 4 bytes per argument.
    if ((did & ~3u) == gLookupId) {
        NSMutableData *d = [paths objectForKey:tk];
        if (!d) { d = [NSMutableData data]; [paths setObject:d forKey:tk]; }
        if (![pathFirst objectForKey:tk]) {
            [pathFirst setObject:[NSNumber numberWithBool:YES] forKey:tk];
            [d appendBytes:&b->a2 length:12];
        } else {
            [d appendBytes:&b->a1 length:16];
        }
    }

    NSString *cn = [XCodes() objectForKey:[NSNumber numberWithUnsignedInt:did & ~3u]];
    NSString *desc;
    NSString *simple = nil;
    NSString *fname = (fn == 1) ? @"start" : (fn == 2) ? @"end" : @"";
    if (cls == 4 && sub == 0x0c) {
        NSString *nm = cn ? cn : XSysName(code);
        if ([nm hasPrefix:@"BSC_"]) nm = [nm substringFromIndex:4];
        desc = [NSString stringWithFormat:@"%@ %@", nm, fname];
        if (fn & 1) {
            [paths removeObjectForKey:tk];
            [pathFirst removeObjectForKey:tk];
        } else if (fn & 2) {
            NSString *verb = XVerb(nm);
            if (verb) {
                NSString *path = nil;
                NSData *d = [paths objectForKey:tk];
                if (d && [d length]) {
                    const char *p = (const char *)[d bytes];
                    size_t l = strnlen(p, [d length]);
                    if (l) path = [[[NSString alloc] initWithBytes:p length:l encoding:NSUTF8StringEncoding] autorelease];
                }
                NSString *detail = path ? path : @"";
                if (!path && ([nm hasPrefix:@"read"] || [nm hasPrefix:@"write"] || [nm hasPrefix:@"pread"] || [nm hasPrefix:@"pwrite"]))
                    detail = [NSString stringWithFormat:@"%u bytes", b->a2];
                simple = [NSString stringWithFormat:@"%@  %@ %@%@", proc, verb, detail, b->a1 ? @"  (failed)" : @""];
            }
        }
    } else if (cls == 1 && sub == 0x0a) {
        desc = [NSString stringWithFormat:@"%@ %@", cn ? cn : XMachName(code), fname];
    } else {
        if (cn) desc = [NSString stringWithFormat:@"%@ %@", cn, fname];
        else desc = [NSString stringWithFormat:@"%@ %02x:%03x %@", XClassName(cls), sub, code, fname];
    }
    XEvent *e = [[[XEvent alloc] init] autorelease];
    e->simple = [simple retain];
    e->raw = [[NSString stringWithFormat:@"%8.3f c%d %@ %@  %08x %08x %08x %08x", secs, cpu, proc, desc,
               b->a1, b->a2, b->a3, b->a4] retain];
    [events addObject:e];
}

@end
