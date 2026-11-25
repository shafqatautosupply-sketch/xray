// helper.m - xrayd, the setuid-root helper. Read-only queries plus kdebug streaming. No UIKit.
//   xrayd access | procs | proc PID | events PID | threads PID | regions PID | files PID
//   xrayd read PID HEXADDR LEN | sample PID WAITING SECS | signal PID SIG | trace FILTER PID
#define XHELPER 1
#import "XCore.h"
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static volatile sig_atomic_t gStop = 0;
static void onSig(int s) { gStop = 1; }

static void XEmit(id v) {
    NSDictionary *d = v ? [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:YES], @"ok", v, @"v", nil]
                        : [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:NO], @"ok", nil];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:d format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    const unsigned char *p = (const unsigned char *)[data bytes];
    size_t n = [data length];
    while (n > 0) {
        ssize_t w = write(1, p, n);
        if (w <= 0) break;
        p += w;
        n -= (size_t)w;
    }
}

static NSArray *XDicts(NSArray *objs) {
    NSMutableArray *o = [NSMutableArray array];
    for (id x in objs) [o addObject:[x toDict]];
    return o;
}

static void XCleanLine(NSMutableString *s) {
    [s replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:NSMakeRange(0, [s length])];
    [s replaceOccurrencesOfString:@"\x1f" withString:@" " options:0 range:NSMakeRange(0, [s length])];
}

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (argc < 2) return 2;
    if (geteuid() == 0) { setgid(0); setuid(0); }   // real uid root too: kdebug and task_for_pid may check it
    NSString *cmd = [NSString stringWithUTF8String:argv[1]];
    pid_t pid = argc > 2 ? (pid_t)atoi(argv[2]) : 0;

    if ([cmd isEqualToString:@"access"]) {
        XEmit([NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithBool:[XCore hasKernelAccess]], @"tfp",
            [NSNumber numberWithInt:(int)getuid()], @"uid",
            [NSNumber numberWithInt:(int)geteuid()], @"euid", nil]);
    } else if ([cmd isEqualToString:@"procs"]) {
        XEmit(XDicts([XCore processList]));
    } else if ([cmd isEqualToString:@"proc"]) {
        XProc *p = [XCore procForPid:pid];
        XEmit(p ? [p toDict] : [NSDictionary dictionary]);
    } else if ([cmd isEqualToString:@"events"]) {
        XEmit([XCore taskEventsForPid:pid]);
    } else if ([cmd isEqualToString:@"threads"]) {
        NSArray *t = [XCore threadsForPid:pid];
        XEmit(t ? XDicts(t) : nil);
    } else if ([cmd isEqualToString:@"regions"]) {
        NSArray *r = [XCore regionsForPid:pid];
        XEmit(r ? XDicts(r) : nil);
    } else if ([cmd isEqualToString:@"files"]) {
        XEmit([XCore openFilesForPid:pid]);
    } else if ([cmd isEqualToString:@"read"] && argc > 4) {
        uint32_t addr = (uint32_t)strtoul(argv[3], NULL, 16);
        uint32_t len = (uint32_t)strtoul(argv[4], NULL, 10);
        if (len > 65536) len = 65536;
        XEmit([XCore readPid:pid addr:addr len:len]);
    } else if ([cmd isEqualToString:@"signal"] && argc > 3) {
        int sig = atoi(argv[3]);
        BOOL allowed = (sig == SIGSTOP || sig == SIGCONT || sig == SIGTERM || sig == SIGKILL);
        XEmit([NSNumber numberWithBool:(allowed && [XCore signalPid:pid sig:sig])]);
    } else if ([cmd isEqualToString:@"sample"] && argc > 4) {
        BOOL waiting = atoi(argv[3]) != 0;
        double secs = atof(argv[4]);
        if (secs < 0.5) secs = 0.5;
        if (secs > 30) secs = 30;
        signal(SIGTERM, onSig);
        XSampler *s = [[XSampler alloc] initWithPid:pid includeWaiting:waiting];
        NSDate *t0 = [NSDate date];
        while (-[t0 timeIntervalSinceNow] < secs && !gStop) {
            if (![s step]) break;
            usleep(8000);
        }
        [s finish];
        NSArray *rep = [s report];
        if ([rep count] > 80) rep = [rep subarrayWithRange:NSMakeRange(0, 80)];
        XEmit([NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithInt:[s threadSampleCount]], @"n", rep, @"rows", nil]);
        [s release];
    } else if ([cmd isEqualToString:@"trace"] && argc > 3) {
        int filter = atoi(argv[2]);
        pid_t tp = (pid_t)atoi(argv[3]);
        signal(SIGTERM, onSig);
        signal(SIGINT, onSig);
        signal(SIGPIPE, onSig);   // the app closing its end ends the trace
        XTrace *t = [XTrace shared];
        if (![t startFilter:filter pid:tp]) {
            printf("ERR\t%s\n", [[t lastError] UTF8String] ? [[t lastError] UTF8String] : "kdebug failed");
            fflush(stdout);
            [pool drain];
            return 1;
        }
        printf("OK\n");
        fflush(stdout);
        while (!gStop) {
            NSAutoreleasePool *p2 = [[NSAutoreleasePool alloc] init];
            NSArray *evs = [t takeAll];
            for (XEvent *e in evs) {
                NSMutableString *raw = [NSMutableString stringWithString:e->raw ? e->raw : @""];
                NSMutableString *sm = [NSMutableString stringWithString:e->simple ? e->simple : @""];
                XCleanLine(raw);
                XCleanLine(sm);
                if (printf("%s\x1f%s\n", [raw UTF8String], [sm UTF8String]) < 0) gStop = 1;
            }
            if (printf("\n") < 0) gStop = 1;   // heartbeat: lets us notice a closed pipe even when idle
            if (fflush(stdout) != 0) gStop = 1;
            [p2 drain];
            if (!gStop) usleep(120000);
        }
        [t stop];   // always switch kdebug off
    } else {
        [pool drain];
        return 2;
    }
    [pool drain];
    return 0;
}
