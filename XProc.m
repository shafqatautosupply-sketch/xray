// XProc.m - process list, task/thread info, stacks, memory map, open files, sampler
#import "XCore.h"
#include <sys/sysctl.h>
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>

extern kern_return_t task_for_pid(mach_port_t target, int pid, mach_port_t *t);

#pragma mark - libproc, resolved at runtime so a missing symbol can't break the link

static int (*f_pidpath)(int, void *, uint32_t);
static int (*f_regionfile)(int, uint64_t, void *, uint32_t);
static int (*f_pidinfo)(int, int, uint64_t, void *, int);
static int (*f_pidfdinfo)(int, int, int, void *, int);

static void XInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f_pidpath = (int (*)(int, void *, uint32_t))dlsym(RTLD_DEFAULT, "proc_pidpath");
        f_regionfile = (int (*)(int, uint64_t, void *, uint32_t))dlsym(RTLD_DEFAULT, "proc_regionfilename");
        f_pidinfo = (int (*)(int, int, uint64_t, void *, int))dlsym(RTLD_DEFAULT, "proc_pidinfo");
        f_pidfdinfo = (int (*)(int, int, int, void *, int))dlsym(RTLD_DEFAULT, "proc_pidfdinfo");
    });
}

typedef struct { int32_t proc_fd; uint32_t proc_fdtype; } XFdInfo;

#pragma mark - task port helpers

static mach_port_t XTask(pid_t pid) {
    if (pid == getpid()) return mach_task_self();
    mach_port_t t = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &t) != KERN_SUCCESS) return MACH_PORT_NULL;
    return t;
}

static void XTaskDone(mach_port_t t, pid_t pid) {
    if (t != MACH_PORT_NULL && pid != getpid()) mach_port_deallocate(mach_task_self(), t);
}

static uint32_t XReadWord(mach_port_t task, uint32_t addr, BOOL *ok) {
    uint32_t v = 0;
    vm_size_t out = 0;
    kern_return_t kr = vm_read_overwrite(task, addr, 4, (vm_address_t)&v, &out);
    *ok = (kr == KERN_SUCCESS && out == 4);
    return v;
}

#pragma mark - symbols

// Resolves an address in another process. Shared-cache libraries sit at the same address in every
// process, so dladdr() in our own process can name them. We only trust dladdr when the target's
// region file matches (or is the dyld shared cache), so our own binary's symbols never leak in.
static NSString *XSym(uint32_t a, pid_t pid, BOOL withOffset) {
    XInit();
    uint32_t pc = a & ~1u;
    char file[1024];
    file[0] = 0;
    if (f_regionfile && pid > 0) f_regionfile(pid, pc, file, sizeof(file));
    if (pid > 0 && file[0]) {
        Dl_info di;
        memset(&di, 0, sizeof(di));
        if (dladdr((void *)(uintptr_t)pc, &di) && di.dli_sname && di.dli_fname) {
            BOOL ok = (strcmp(di.dli_fname, file) == 0) || (strstr(file, "dyld_shared_cache") != NULL);
            if (ok) {
                const char *img = strrchr(di.dli_fname, '/');
                img = img ? img + 1 : di.dli_fname;
                if (withOffset)
                    return [NSString stringWithFormat:@"%s+%u (%s)", di.dli_sname,
                            (unsigned)(pc - (uint32_t)(uintptr_t)di.dli_saddr), img];
                return [NSString stringWithFormat:@"%s (%s)", di.dli_sname, img];
            }
        }
        const char *b = strrchr(file, '/');
        b = b ? b + 1 : file;
        return [NSString stringWithFormat:@"0x%08x (%s)", pc, b];
    }
    return [NSString stringWithFormat:@"0x%08x", pc];
}

// ARM Darwin frame chain: r7 is the frame pointer, [fp] = caller fp, [fp+4] = return address.
static NSArray *XWalk(mach_port_t task, const uint32_t *regs) {
    NSMutableArray *f = [NSMutableArray array];
    [f addObject:[NSNumber numberWithUnsignedInt:regs[15]]];
    uint32_t lr = regs[14], fp = regs[7];
    NSMutableArray *chain = [NSMutableArray array];
    for (int k = 0; k < 30; k++) {
        if ((fp & 3) || fp < 0x1000) break;
        BOOL ok1, ok2;
        uint32_t next = XReadWord(task, fp, &ok1);
        uint32_t ret = XReadWord(task, fp + 4, &ok2);
        if (!ok1 || !ok2 || ret == 0) break;
        [chain addObject:[NSNumber numberWithUnsignedInt:ret]];
        if (next <= fp) break;
        fp = next;
    }
    if (lr && (![chain count] || [[chain objectAtIndex:0] unsignedIntValue] != lr))
        [f addObject:[NSNumber numberWithUnsignedInt:lr]];
    [f addObjectsFromArray:chain];
    return f;
}

static XProc *XMakeProc(struct kinfo_proc *k);

@implementation XCore

+ (BOOL)signalPid:(pid_t)pid sig:(int)sig {
    if (pid <= 1) return NO;
    return kill(pid, sig) == 0;
}

+ (NSString *)accessInfo { return nil; }

+ (BOOL)hasKernelAccess {
    mach_port_t t = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), 1, &t) != KERN_SUCCESS) return NO;
    mach_port_deallocate(mach_task_self(), t);
    return YES;
}

+ (NSString *)pathForPid:(pid_t)pid {
    XInit();
    if (!f_pidpath || pid <= 0) return nil;
    char buf[1024];
    int r = f_pidpath(pid, buf, sizeof(buf));
    if (r <= 0) return nil;
    return [NSString stringWithUTF8String:buf];
}

+ (NSArray *)processList {
    XInit();
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    size_t sz = 0;
    if (sysctl(mib, 3, NULL, &sz, NULL, 0) != 0) return [NSArray array];
    sz += sz / 8 + sizeof(struct kinfo_proc) * 8;
    struct kinfo_proc *kp = (struct kinfo_proc *)malloc(sz);
    if (!kp) return [NSArray array];
    if (sysctl(mib, 3, kp, &sz, NULL, 0) != 0) { free(kp); return [NSArray array]; }
    int n = (int)(sz / sizeof(struct kinfo_proc));
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
    for (int i = 0; i < n; i++) [out addObject:XMakeProc(&kp[i])];
    free(kp);
    return out;
}

+ (XProc *)procForPid:(pid_t)pid {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc k;
    size_t sz = sizeof(k);
    memset(&k, 0, sz);
    if (sysctl(mib, 4, &k, &sz, NULL, 0) != 0 || sz == 0) return nil;
    return XMakeProc(&k);
}

+ (void)fillTaskInfo:(XProc *)p {
    if (p->pid == 0) return;   // never poke kernel_task from the list view; Kernel tab opens it on request
    mach_port_t t = XTask(p->pid);
    if (t == MACH_PORT_NULL) return;
    p->haveTask = YES;
    task_basic_info_data_t bi;
    mach_msg_type_number_t c = TASK_BASIC_INFO_COUNT;
    if (task_info(t, TASK_BASIC_INFO, (task_info_t)&bi, &c) == KERN_SUCCESS) {
        p->resident = bi.resident_size;
        p->virt = bi.virtual_size;
        p->suspend = bi.suspend_count;
        p->userTime = bi.user_time.seconds + bi.user_time.microseconds / 1e6;
        p->sysTime = bi.system_time.seconds + bi.system_time.microseconds / 1e6;
    }
    thread_act_array_t th = NULL;
    mach_msg_type_number_t n = 0;
    if (task_threads(t, &th, &n) == KERN_SUCCESS) {
        p->threads = (int)n;
        double cpu = 0;
        for (mach_msg_type_number_t i = 0; i < n; i++) {
            thread_basic_info_data_t ti;
            c = THREAD_BASIC_INFO_COUNT;
            if (thread_info(th[i], THREAD_BASIC_INFO, (thread_info_t)&ti, &c) == KERN_SUCCESS &&
                !(ti.flags & TH_FLAGS_IDLE))
                cpu += ti.cpu_usage;
            mach_port_deallocate(mach_task_self(), th[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof(thread_t));
        p->cpu = cpu / (double)TH_USAGE_SCALE * 100.0;
    }
    XTaskDone(t, p->pid);
}

+ (NSArray *)taskEventsForPid:(pid_t)pid {
    mach_port_t t = XTask(pid);
    if (t == MACH_PORT_NULL) return nil;
    task_events_info_data_t ev;
    mach_msg_type_number_t c = TASK_EVENTS_INFO_COUNT;
    kern_return_t kr = task_info(t, TASK_EVENTS_INFO, (task_info_t)&ev, &c);
    XTaskDone(t, pid);
    if (kr != KERN_SUCCESS) return nil;
    NSMutableArray *o = [NSMutableArray array];
#define EV(l, v) [o addObject:[NSArray arrayWithObjects:l, [NSNumber numberWithLongLong:(long long)(v)], nil]]
    EV(@"Page faults", ev.faults);
    EV(@"Page-ins", ev.pageins);
    EV(@"Copy-on-write faults", ev.cow_faults);
    EV(@"Mach messages sent", ev.messages_sent);
    EV(@"Mach messages received", ev.messages_received);
    EV(@"Mach syscalls", ev.syscalls_mach);
    EV(@"Unix syscalls", ev.syscalls_unix);
    EV(@"Context switches", ev.csw);
#undef EV
    return o;
}

+ (NSArray *)threadsForPid:(pid_t)pid {
    mach_port_t task = XTask(pid);
    if (task == MACH_PORT_NULL) return nil;
    thread_act_array_t th = NULL;
    mach_msg_type_number_t n = 0;
    if (task_threads(task, &th, &n) != KERN_SUCCESS) { XTaskDone(task, pid); return nil; }
    NSMutableArray *out = [NSMutableArray array];
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        XThread *x = [[[XThread alloc] init] autorelease];
        x->index = (int)i;
        thread_basic_info_data_t bi;
        mach_msg_type_number_t c = THREAD_BASIC_INFO_COUNT;
        if (thread_info(th[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &c) == KERN_SUCCESS) {
            x->cpu = bi.cpu_usage / (double)TH_USAGE_SCALE * 100.0;
            x->runState = bi.run_state;
            x->flags = bi.flags;
            x->suspend = bi.suspend_count;
            x->sleepTime = bi.sleep_time;
            x->policy = bi.policy;
        }
#ifdef THREAD_IDENTIFIER_INFO
        thread_identifier_info_data_t ii;
        c = THREAD_IDENTIFIER_INFO_COUNT;
        if (thread_info(th[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &c) == KERN_SUCCESS)
            x->tid = ii.thread_id;
#endif
        NSArray *addrs = nil;
        // Never suspend our own threads (deadlock) or kernel threads. The suspend lasts only for
        // the register read plus a few memory reads, and the thread is always resumed right after.
        if (pid != getpid() && !(x->flags & TH_FLAGS_IDLE)) {
            BOOL susp = NO;
            if (pid != 0) susp = (thread_suspend(th[i]) == KERN_SUCCESS);
            natural_t st[ARM_THREAD_STATE_COUNT];
            mach_msg_type_number_t sc = ARM_THREAD_STATE_COUNT;
            if (thread_get_state(th[i], ARM_THREAD_STATE, (thread_state_t)st, &sc) == KERN_SUCCESS && sc >= 17) {
                x->haveRegs = YES;
                for (int k = 0; k < 17; k++) x->regs[k] = st[k];
                addrs = XWalk(task, x->regs);
            }
            if (susp) thread_resume(th[i]);
        }
        if (addrs) {
            NSMutableArray *syms = [NSMutableArray array];
            int lim = 0;
            for (NSNumber *a in addrs) {
                if (lim++ >= 24) break;
                [syms addObject:XSym([a unsignedIntValue], pid, YES)];
            }
            x->frames = [addrs retain];
            x->symbols = [syms retain];
        }
        [out addObject:x];
        mach_port_deallocate(mach_task_self(), th[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof(thread_t));
    XTaskDone(task, pid);
    return out;
}

+ (NSString *)symbolizeAddr:(uint32_t)a pid:(pid_t)pid { return XSym(a, pid, YES); }

+ (NSArray *)regionsForPid:(pid_t)pid {
    XInit();
    mach_port_t task = XTask(pid);
    if (task == MACH_PORT_NULL) return nil;
    NSMutableArray *out = [NSMutableArray array];
    vm_address_t addr = 0;
    for (int guard = 0; guard < 4000; guard++) {
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t c = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        kern_return_t kr = vm_region_64(task, &addr, &size, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&info, &c, &obj);
        if (kr != KERN_SUCCESS) break;
        XRegion *r = [[[XRegion alloc] init] autorelease];
        r->addr = (uint32_t)addr;
        r->size = (uint32_t)size;
        r->prot = info.protection;
        r->maxprot = info.max_protection;
        r->share = info.shared;
#ifdef VM_REGION_EXTENDED_INFO
        vm_region_extended_info_data_t ex;
        c = VM_REGION_EXTENDED_INFO_COUNT;
        vm_address_t a2 = addr;
        vm_size_t s2 = 0;
        mach_port_t o2 = MACH_PORT_NULL;
        if (vm_region_64(task, &a2, &s2, VM_REGION_EXTENDED_INFO, (vm_region_info_t)&ex, &c, &o2) == KERN_SUCCESS &&
            a2 == addr)
            r->resident = (uint32_t)(ex.pages_resident * 4096ULL);
#endif
        if (f_regionfile && pid > 0) {
            char buf[1024];
            buf[0] = 0;
            f_regionfile(pid, (uint64_t)addr, buf, sizeof(buf));
            if (buf[0]) r->file = [[NSString stringWithUTF8String:buf] retain];
        }
        [out addObject:r];
        vm_address_t next = addr + size;
        if (next <= addr) break;
        addr = next;
    }
    XTaskDone(task, pid);
    return out;
}

+ (NSArray *)openFilesForPid:(pid_t)pid {
    XInit();
    if (!f_pidinfo) return nil;
    int need = f_pidinfo(pid, 1 /* PROC_PIDLISTFDS */, 0, NULL, 0);
    if (need <= 0) return nil;
    int cap = need + 16 * (int)sizeof(XFdInfo);
    XFdInfo *fds = (XFdInfo *)malloc(cap);
    if (!fds) return nil;
    int got = f_pidinfo(pid, 1, 0, fds, cap);
    if (got <= 0) { free(fds); return nil; }
    int n = got / (int)sizeof(XFdInfo);
    static const char *tn[] = { "?", "file", "socket", "shared mem", "semaphore", "kqueue", "pipe", "fsevents" };
    NSMutableArray *out = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
        NSString *path = nil;
        uint32_t ty = fds[i].proc_fdtype;
        if (ty == 1 && f_pidfdinfo) {
            char buf[2048];
            memset(buf, 0, sizeof(buf));
            int r = f_pidfdinfo(pid, fds[i].proc_fd, 2 /* PROC_PIDFDVNODEPATHINFO */, buf, sizeof(buf));
            if (r > 1024) {   // the path is the last 1024 bytes of vnode_fdinfowithpath
                const char *p = buf + r - 1024;
                size_t l = strnlen(p, 1024);
                if (l) path = [[[NSString alloc] initWithBytes:p length:l encoding:NSUTF8StringEncoding] autorelease];
            }
        }
        [out addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithInt:fds[i].proc_fd], @"fd",
            [NSString stringWithUTF8String:tn[ty < 8 ? ty : 0]], @"type",
            path ? path : @"", @"path", nil]];
    }
    free(fds);
    return out;
}

+ (NSData *)readPid:(pid_t)pid addr:(uint32_t)a len:(uint32_t)len {
    mach_port_t task = XTask(pid);
    if (task == MACH_PORT_NULL || len == 0) return nil;
    void *buf = malloc(len);
    if (!buf) { XTaskDone(task, pid); return nil; }
    vm_size_t out = 0;
    kern_return_t kr = vm_read_overwrite(task, a, len, (vm_address_t)buf, &out);
    XTaskDone(task, pid);
    if (kr != KERN_SUCCESS || out == 0) { free(buf); return nil; }
    return [NSData dataWithBytesNoCopy:buf length:out freeWhenDone:YES];
}

@end

static XProc *XMakeProc(struct kinfo_proc *k) {
    XProc *p = [[[XProc alloc] init] autorelease];
    p->pid = k->kp_proc.p_pid;
    p->ppid = k->kp_eproc.e_ppid;
    p->uid = k->kp_eproc.e_ucred.cr_uid;
    p->stat = k->kp_proc.p_stat;
    char comm[20];
    strlcpy(comm, k->kp_proc.p_comm, sizeof(comm));
    p->path = [[XCore pathForPid:p->pid] retain];
    NSString *n = p->path ? [p->path lastPathComponent] : [NSString stringWithUTF8String:comm];
    if (p->pid == 0) n = @"kernel_task";
    p->name = [(n ? n : @"?") copy];
    [XCore fillTaskInfo:p];
    return p;
}

#pragma mark - Sampler (poor man's profiler: where is this process spending its time)

@implementation XSampler

- (id)initWithPid:(pid_t)p includeWaiting:(BOOL)w {
    self = [super init];
    if (self) {
        pid = p;
        waiting = w;
        task = XTask(p);
        selfCount = [[NSMutableDictionary alloc] init];
        inclCount = [[NSMutableDictionary alloc] init];
        cache = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc {
    [self finish];
    [selfCount release]; [inclCount release]; [cache release];
    [super dealloc];
}

- (BOOL)step {
    if (task == MACH_PORT_NULL) return NO;
    thread_act_array_t th = NULL;
    mach_msg_type_number_t n = 0;
    if (task_threads(task, &th, &n) != KERN_SUCCESS) return NO;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    @synchronized (self) { steps++; }
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        thread_basic_info_data_t bi;
        mach_msg_type_number_t c = THREAD_BASIC_INFO_COUNT;
        BOOL take = NO;
        if (thread_info(th[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &c) == KERN_SUCCESS &&
            !(bi.flags & TH_FLAGS_IDLE))
            take = waiting || bi.run_state == TH_STATE_RUNNING;
        if (take && pid != getpid()) {
            BOOL susp = NO;
            if (pid != 0) susp = (thread_suspend(th[i]) == KERN_SUCCESS);
            natural_t st[ARM_THREAD_STATE_COUNT];
            mach_msg_type_number_t sc = ARM_THREAD_STATE_COUNT;
            NSArray *fr = nil;
            if (thread_get_state(th[i], ARM_THREAD_STATE, (thread_state_t)st, &sc) == KERN_SUCCESS && sc >= 17) {
                uint32_t r[17];
                for (int k = 0; k < 17; k++) r[k] = st[k];
                fr = XWalk(task, r);
            }
            if (susp) thread_resume(th[i]);
            if (fr) {
                NSMutableSet *seen = [NSMutableSet set];
                BOOL first = YES;
                int lim = 0;
                for (NSNumber *a in fr) {
                    if (lim++ >= 24) break;
                    NSString *sym = [cache objectForKey:a];
                    if (!sym) { sym = XSym([a unsignedIntValue], pid, NO); [cache setObject:sym forKey:a]; }
                    @synchronized (self) {
                        if (first) {
                            [selfCount setObject:[NSNumber numberWithInt:[[selfCount objectForKey:sym] intValue] + 1] forKey:sym];
                            threadSamples++;
                        }
                        if (![seen containsObject:sym])
                            [inclCount setObject:[NSNumber numberWithInt:[[inclCount objectForKey:sym] intValue] + 1] forKey:sym];
                    }
                    [seen addObject:sym];
                    first = NO;
                }
            }
        }
        mach_port_deallocate(mach_task_self(), th[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof(thread_t));
    [pool drain];
    return YES;
}

- (void)finish {
    if (task != MACH_PORT_NULL) { XTaskDone(task, pid); task = MACH_PORT_NULL; }
}

- (int)threadSampleCount { @synchronized (self) { return threadSamples; } }

- (NSArray *)report {
    NSMutableArray *rows = [NSMutableArray array];
    int total;
    @synchronized (self) {
        total = threadSamples;
        for (NSString *k in inclCount) {
            [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                k, @"sym",
                [NSNumber numberWithInt:[[selfCount objectForKey:k] intValue]], @"self",
                [inclCount objectForKey:k], @"total",
                [NSNumber numberWithInt:total], @"n", nil]];
        }
    }
    [rows sortUsingComparator:^NSComparisonResult(id a, id b) {
        int sa = [[a objectForKey:@"self"] intValue], sb = [[b objectForKey:@"self"] intValue];
        if (sa != sb) return sa > sb ? NSOrderedAscending : NSOrderedDescending;
        int ta = [[a objectForKey:@"total"] intValue], tb2 = [[b objectForKey:@"total"] intValue];
        if (ta != tb2) return ta > tb2 ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    return rows;
}

@end
