// XKern.m - host/kernel statistics and a full sysctl tree walker
#import "XCore.h"
#include <sys/sysctl.h>
#include <sys/time.h>
#include <string.h>
#include <stdlib.h>

@implementation XKern

+ (NSString *)sysctlString:(const char *)name {
    size_t len = 0;
    if (sysctlbyname(name, NULL, &len, NULL, 0) != 0 || len == 0) return nil;
    char *b = (char *)malloc(len + 1);
    if (!b) return nil;
    if (sysctlbyname(name, b, &len, NULL, 0) != 0) { free(b); return nil; }
    b[len] = 0;
    NSString *s = [NSString stringWithUTF8String:b];
    free(b);
    return s;
}

+ (uint64_t)sysctlNumber:(const char *)name {
    uint64_t v = 0;
    size_t len = sizeof(v);
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return 0;
    if (len == 4) return (uint32_t)v;
    return v;
}

+ (double)uptime {
    int mib[2] = { CTL_KERN, KERN_BOOTTIME };
    struct timeval bt;
    size_t sz = sizeof(bt);
    if (sysctl(mib, 2, &bt, &sz, NULL, 0) != 0) return 0;
    struct timeval now;
    gettimeofday(&now, NULL);
    return (double)(now.tv_sec - bt.tv_sec);
}

+ (NSDictionary *)vm {
    mach_port_t host = mach_host_self();
    vm_size_t ps = 4096;
    host_page_size(host, &ps);
    vm_statistics_data_t v;
    mach_msg_type_number_t c = HOST_VM_INFO_COUNT;
    memset(&v, 0, sizeof(v));
    host_statistics(host, HOST_VM_INFO, (host_info_t)&v, &c);
    mach_port_deallocate(mach_task_self(), host);
    uint64_t total = [self sysctlNumber:"hw.memsize"];
    if (!total) total = [self sysctlNumber:"hw.physmem"];
#define N(x) [NSNumber numberWithUnsignedLongLong:(unsigned long long)(x)]
    return [NSDictionary dictionaryWithObjectsAndKeys:
        N(total), @"total",
        N((uint64_t)v.free_count * ps), @"free",
        N((uint64_t)v.active_count * ps), @"active",
        N((uint64_t)v.inactive_count * ps), @"inactive",
        N((uint64_t)v.wire_count * ps), @"wired",
        N(v.faults), @"faults",
        N(v.pageins), @"pageins",
        N(v.pageouts), @"pageouts",
        N(v.cow_faults), @"cow",
        N(v.zero_fill_count), @"zerofill",
        N(v.reactivations), @"reactivations",
        N(v.hits), @"hits",
        N(v.lookups), @"lookups",
        N(ps), @"pagesize", nil];
#undef N
}

+ (NSArray *)perCPULoads {
    static natural_t prev[8][CPU_STATE_MAX];
    static BOOL have = NO;
    static natural_t pn = 0;
    natural_t n = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t cnt = 0;
    mach_port_t host = mach_host_self();
    kern_return_t kr = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt);
    mach_port_deallocate(mach_task_self(), host);
    if (kr != KERN_SUCCESS) return [NSArray array];
    processor_cpu_load_info_t li = (processor_cpu_load_info_t)info;
    NSMutableArray *out = [NSMutableArray array];
    for (natural_t i = 0; i < n && i < 8; i++) {
        double pct = 0;
        if (have && pn == n) {
            double du = li[i].cpu_ticks[CPU_STATE_USER] - prev[i][CPU_STATE_USER];
            double ds = li[i].cpu_ticks[CPU_STATE_SYSTEM] - prev[i][CPU_STATE_SYSTEM];
            double dn = li[i].cpu_ticks[CPU_STATE_NICE] - prev[i][CPU_STATE_NICE];
            double di = li[i].cpu_ticks[CPU_STATE_IDLE] - prev[i][CPU_STATE_IDLE];
            double busy = du + ds + dn, tot = busy + di;
            pct = tot > 0 ? 100.0 * busy / tot : 0;
        }
        for (int s = 0; s < CPU_STATE_MAX; s++) prev[i][s] = li[i].cpu_ticks[s];
        [out addObject:[NSNumber numberWithDouble:pct]];
    }
    have = YES;
    pn = n;
    vm_deallocate(mach_task_self(), (vm_address_t)info, cnt * sizeof(integer_t));
    return out;
}

// Walks the whole sysctl MIB tree using the kernel's own "next OID" interface (the way sysctl -a does).
// Only small INT / QUAD / STRING leaves are read; opaque structs are listed without being read.
+ (NSArray *)sysctlDump {
    NSMutableArray *out = [NSMutableArray array];
    int oid[CTL_MAXNAME];
    size_t len = 1;
    oid[0] = 1;   // CTL_KERN
    for (int guard = 0; guard < 6000; guard++) {
        int q[CTL_MAXNAME + 2];
        q[0] = 0;
        memcpy(q + 2, oid, len * sizeof(int));

        char nm[256];
        size_t nl = sizeof(nm);
        q[1] = 1;   // name
        if (sysctl(q, (u_int)len + 2, nm, &nl, NULL, 0) == 0 && nl > 0) {
            char fmt[256];
            size_t fl = sizeof(fmt);
            q[1] = 4;   // oidfmt: uint32 kind, then format string
            uint32_t kind = 0;
            if (sysctl(q, (u_int)len + 2, fmt, &fl, NULL, 0) == 0 && fl >= 4) memcpy(&kind, fmt, 4);
            int type = kind & 0xf;   // 1 node, 2 int, 3 string, 4 quad, 5 opaque
            if (type != 1) {
                NSString *val = @"";
                NSString *tn = @"struct";
                if (type == 2) {
                    tn = @"int";
                    int v = 0; size_t sz = sizeof(v);
                    if (sysctl(oid, (u_int)len, &v, &sz, NULL, 0) == 0) val = [NSString stringWithFormat:@"%d", v];
                } else if (type == 4) {
                    tn = @"quad";
                    long long v = 0; size_t sz = sizeof(v);
                    if (sysctl(oid, (u_int)len, &v, &sz, NULL, 0) == 0) val = [NSString stringWithFormat:@"%lld", v];
                } else if (type == 3) {
                    tn = @"string";
                    char sb[512]; size_t sz = sizeof(sb) - 1;
                    if (sysctl(oid, (u_int)len, sb, &sz, NULL, 0) == 0) {
                        sb[sz] = 0;
                        NSString *s = [NSString stringWithUTF8String:sb];
                        val = s ? s : @"";
                    }
                }
                [out addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    [NSString stringWithUTF8String:nm], @"name", val, @"value", tn, @"type", nil]];
            }
        }
        // next OID
        int nxt[CTL_MAXNAME];
        size_t nsz = sizeof(nxt);
        q[1] = 2;
        if (sysctl(q, (u_int)len + 2, nxt, &nsz, NULL, 0) != 0) break;
        len = nsz / sizeof(int);
        if (len == 0) break;
        memcpy(oid, nxt, nsz);
    }
    return out;
}

@end
