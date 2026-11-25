// XScreens.m - every screen. Each screen has an Easy view (plain language) and a Pro view (raw data).
#import "XCore.h"
#import <QuartzCore/QuartzCore.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void (^XGoBlock)(UINavigationController *nav);
typedef NSArray *(^XProvider)(void);

#pragma mark - row helpers

static NSDictionary *XRow(NSString *k, NSString *v) {
    return [NSDictionary dictionaryWithObjectsAndKeys:k ? k : @"", @"k", v ? v : @"", @"v", nil];
}
static NSDictionary *XGo(NSString *k, NSString *v, XGoBlock go) {
    return [NSDictionary dictionaryWithObjectsAndKeys:k ? k : @"", @"k", v ? v : @"", @"v",
            [[go copy] autorelease], @"go", nil];
}
static NSDictionary *XSec(NSString *t, NSString *f, NSArray *rows) {
    return [NSDictionary dictionaryWithObjectsAndKeys:t ? t : @"", @"t", f ? f : @"", @"f",
            rows ? rows : [NSArray array], @"r", nil];
}
static NSString *XPct(double v) { return [NSString stringWithFormat:@"%.0f%%", v]; }
static NSString *XBase(NSString *p) { return p ? [p lastPathComponent] : @"?"; }

static NSString *XBattery(void) {
    UIDevice *d = [UIDevice currentDevice];
    float l = d.batteryLevel;
    if (l < 0) return @"Unknown";
    NSString *st = d.batteryState == UIDeviceBatteryStateCharging ? @"charging"
                 : d.batteryState == UIDeviceBatteryStateFull ? @"full" : @"on battery";
    return [NSString stringWithFormat:@"%.0f%% (%@)", l * 100, st];
}

#pragma mark - text prompt helper (alert with a text field)

@interface XPrompt : NSObject <UIAlertViewDelegate> {
    void (^cb)(NSString *);
}
+ (void)ask:(NSString *)title text:(NSString *)t done:(void (^)(NSString *))done;
@end

@implementation XPrompt
+ (void)ask:(NSString *)title text:(NSString *)t done:(void (^)(NSString *))done {
    XPrompt *p = [[XPrompt alloc] init];   // released when the alert is dismissed
    p->cb = [done copy];
    UIAlertView *a = [[[UIAlertView alloc] initWithTitle:title message:nil delegate:p
                                       cancelButtonTitle:@"Cancel" otherButtonTitles:@"OK", nil] autorelease];
    a.alertViewStyle = UIAlertViewStylePlainTextInput;
    UITextField *f = [a textFieldAtIndex:0];
    f.text = t;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    [a show];
}
- (void)alertView:(UIAlertView *)a clickedButtonAtIndex:(NSInteger)i {
    if (i == 1 && cb) cb([a textFieldAtIndex:0].text);
}
- (void)alertView:(UIAlertView *)a didDismissWithButtonIndex:(NSInteger)i { [self release]; }
- (void)dealloc { [cb release]; [super dealloc]; }
@end

#pragma mark - forward declarations

@interface XThreadsVC : UITableViewController
- (id)initWithPid:(pid_t)pid name:(NSString *)name;
@end
@interface XSamplerVC : UITableViewController
- (id)initWithPid:(pid_t)pid name:(NSString *)name;
@end
@interface XMapVC : UITableViewController
- (id)initWithPid:(pid_t)pid name:(NSString *)name;
@end
@interface XFilesVC : UITableViewController
- (id)initWithPid:(pid_t)pid name:(NSString *)name;
@end
@interface XHexVC : UITableViewController
- (id)initWithPid:(pid_t)pid addr:(uint32_t)addr;
@end
@interface XTraceVC : UITableViewController
- (id)initWithPid:(pid_t)pid;
@end
@interface XSysctlVC : UITableViewController
@end

#pragma mark - base table: linen background, Easy/Pro button, auto refresh

@interface XBaseTable : UITableViewController {
    NSTimer *xtimer;
    NSTimeInterval xinterval;
}
- (void)tick;
- (void)setRefreshInterval:(NSTimeInterval)iv;
- (void)updateModeButton;
@end

@implementation XBaseTable

- (id)initWithStyle:(UITableViewStyle)s {
    self = [super initWithStyle:s];
    if (self) [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(modeChanged) name:XModeChanged object:nil];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [xtimer invalidate];
    [super dealloc];
}

- (void)setRefreshInterval:(NSTimeInterval)iv { xinterval = iv; }

- (void)viewDidLoad {
    [super viewDidLoad];
    if (self.tableView.style == UITableViewStyleGrouped) {
        UIView *bg = [[[UIView alloc] init] autorelease];
        bg.backgroundColor = XLinen();
        self.tableView.backgroundView = bg;
    }
    [self updateModeButton];
}

- (void)updateModeButton {
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:XIsPro() ? @"Pro" : @"Easy"
        style:UIBarButtonItemStyleBordered target:self action:@selector(toggleMode)] autorelease];
}

- (void)toggleMode { XSetPro(!XIsPro()); }

- (void)modeChanged {
    [self updateModeButton];
    if ([self isViewLoaded] && self.view.window) [self tick];
}

- (void)tick {}

- (void)viewWillAppear:(BOOL)a {
    [super viewWillAppear:a];
    [self updateModeButton];
    [self tick];
    [xtimer invalidate];
    xtimer = nil;
    if (xinterval > 0)
        xtimer = [NSTimer scheduledTimerWithTimeInterval:xinterval target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)a {
    [super viewWillDisappear:a];
    [xtimer invalidate];
    xtimer = nil;
}

@end

#pragma mark - generic sectioned info table

@interface XInfoVC : XBaseTable {
    NSArray *sections;
    XProvider provider;
}
- (id)initWithTitle:(NSString *)t interval:(NSTimeInterval)iv provider:(XProvider)p;
- (NSArray *)build;
- (void)rebuild;
@end

@implementation XInfoVC

- (id)initWithTitle:(NSString *)t interval:(NSTimeInterval)iv provider:(XProvider)p {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (self) {
        self.title = t;
        provider = [p copy];
        [self setRefreshInterval:iv];
    }
    return self;
}

- (void)dealloc { [sections release]; [provider release]; [super dealloc]; }

- (NSArray *)build { return provider ? provider() : nil; }

- (void)rebuild {
    [sections release];
    sections = [[self build] retain];
    [self.tableView reloadData];
}

- (void)tick { [self rebuild]; }

- (NSDictionary *)rowAt:(NSIndexPath *)ip {
    return [[[sections objectAtIndex:ip.section] objectForKey:@"r"] objectAtIndex:ip.row];
}

- (BOOL)isLong:(NSDictionary *)r {
    NSString *v = [r objectForKey:@"v"], *k = [r objectForKey:@"k"];
    return [v length] > 24 || ([k length] + [v length]) > 38;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return [sections count]; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return [[[sections objectAtIndex:s] objectForKey:@"r"] count];
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *r = [self rowAt:ip];
    if (![self isLong:r]) return 44;
    CGSize s = [[r objectForKey:@"v"] sizeWithFont:[UIFont fontWithName:@"Courier" size:12]
                                 constrainedToSize:CGSizeMake(250, 4000) lineBreakMode:UILineBreakModeCharacterWrap];
    return MAX(44, 26 + s.height + 8);
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *r = [self rowAt:ip];
    BOOL lng = [self isLong:r];
    NSString *rid = lng ? @"L" : @"S";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:rid];
    if (!c) {
        c = [[[UITableViewCell alloc] initWithStyle:lng ? UITableViewCellStyleSubtitle : UITableViewCellStyleValue1
                                    reuseIdentifier:rid] autorelease];
        c.textLabel.font = [UIFont boldSystemFontOfSize:14];
        c.textLabel.shadowColor = [UIColor whiteColor];
        c.textLabel.shadowOffset = CGSizeMake(0, 1);
        if (lng) {
            c.detailTextLabel.font = [UIFont fontWithName:@"Courier" size:12];
            c.detailTextLabel.numberOfLines = 0;
            c.detailTextLabel.lineBreakMode = UILineBreakModeCharacterWrap;
            c.detailTextLabel.textColor = [UIColor colorWithWhite:0.25 alpha:1];
        } else {
            c.detailTextLabel.font = [UIFont systemFontOfSize:14];
        }
    }
    c.textLabel.text = [r objectForKey:@"k"];
    c.detailTextLabel.text = [r objectForKey:@"v"];
    BOOL go = [r objectForKey:@"go"] != nil;
    c.accessoryType = go ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    c.selectionStyle = go ? UITableViewCellSelectionStyleBlue : UITableViewCellSelectionStyleNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    XGoBlock go = [[self rowAt:ip] objectForKey:@"go"];
    if (go) go(self.navigationController);
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return [[[sections objectAtIndex:s] objectForKey:@"t"] length] ? 34 : 10;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    NSString *t = [[sections objectAtIndex:s] objectForKey:@"t"];
    if (![t length]) return nil;
    UIView *v = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 34)] autorelease];
    UILabel *l = [[[UILabel alloc] initWithFrame:CGRectMake(20, 8, 280, 22)] autorelease];
    l.backgroundColor = [UIColor clearColor];
    l.text = t;
    l.font = [UIFont boldSystemFontOfSize:15];
    l.textColor = [UIColor colorWithRed:0.18 green:0.20 blue:0.24 alpha:1];
    l.shadowColor = [UIColor colorWithWhite:1 alpha:0.7];
    l.shadowOffset = CGSizeMake(0, 1);
    [v addSubview:l];
    return v;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    NSString *f = [[sections objectAtIndex:s] objectForKey:@"f"];
    return [f length] ? f : nil;
}

@end

#pragma mark - Overview (gauges + summary)

@interface XOverviewVC : XInfoVC {
    XGauge *cpuG, *memG;
    UILabel *stat;
    NSArray *tops;
    BOOL busy;
}
@end

@implementation XOverviewVC

- (id)init { return [super initWithTitle:@"Overview" interval:2.0 provider:nil]; }

- (void)dealloc { [tops release]; [super dealloc]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    XLeather *hdr = [[[XLeather alloc] initWithFrame:CGRectMake(0, 0, 320, 200)] autorelease];
    cpuG = [[[XGauge alloc] initWithFrame:CGRectMake(14, 12, 136, 152)] autorelease];
    [cpuG setCaption:@"CPU"];
    memG = [[[XGauge alloc] initWithFrame:CGRectMake(170, 12, 136, 152)] autorelease];
    [memG setCaption:@"MEMORY"];
    stat = [[[UILabel alloc] initWithFrame:CGRectMake(12, 168, 296, 22)] autorelease];
    stat.backgroundColor = [UIColor clearColor];
    stat.textColor = [UIColor colorWithRed:0.96 green:0.90 blue:0.78 alpha:1];
    stat.shadowColor = [UIColor blackColor];
    stat.shadowOffset = CGSizeMake(0, -1);
    stat.font = [UIFont boldSystemFontOfSize:13];
    stat.textAlignment = UITextAlignmentCenter;
    stat.adjustsFontSizeToFitWidth = YES;
    [hdr addSubview:cpuG];
    [hdr addSubview:memG];
    [hdr addSubview:stat];
    self.tableView.tableHeaderView = hdr;
}

- (void)tick {
    [self rebuild];
    if (busy) return;
    busy = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSArray *ps = [XCore processList];
        NSMutableArray *live = [NSMutableArray array];
        for (XProc *p in ps) if (p->haveTask && p->pid > 0) [live addObject:p];
        NSArray *byCpu = [live sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            double x = ((XProc *)a)->cpu, y = ((XProc *)b)->cpu;
            return x > y ? NSOrderedAscending : (x < y ? NSOrderedDescending : NSOrderedSame);
        }];
        NSArray *byMem = [live sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            uint64_t x = ((XProc *)a)->resident, y = ((XProc *)b)->resident;
            return x > y ? NSOrderedAscending : (x < y ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray *c = [NSMutableArray array], *m = [NSMutableArray array];
        for (int i = 0; i < 4 && i < (int)[byCpu count]; i++) {
            XProc *p = [byCpu objectAtIndex:i];
            if (p->cpu >= 1) [c addObject:[NSArray arrayWithObjects:p->name, XPct(p->cpu), nil]];
        }
        for (int i = 0; i < 4 && i < (int)[byMem count]; i++) {
            XProc *p = [byMem objectAtIndex:i];
            [m addObject:[NSArray arrayWithObjects:p->name, XBytes(p->resident), nil]];
        }
        NSArray *res = [[NSArray alloc] initWithObjects:c, m, nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [tops release];
            tops = [res retain];
            busy = NO;
            [self rebuild];
        });
        [res release];
        [pool drain];
    });
}

- (NSArray *)build {
    NSDictionary *vm = [XKern vm];
    NSArray *cores = [XKern perCPULoads];
    double cpu = 0;
    for (NSNumber *n in cores) cpu += [n doubleValue];
    if ([cores count]) cpu /= [cores count];
    double total = [[vm objectForKey:@"total"] doubleValue];
    double fr = [[vm objectForKey:@"free"] doubleValue];
    double inact = [[vm objectForKey:@"inactive"] doubleValue];
    double usedPct = total > 0 ? (total - fr - inact) / total * 100.0 : 0;
    [cpuG setValue:cpu];
    [memG setValue:usedPct];
    double availMB = (fr + inact) / 1048576.0;
    NSString *mem = availMB > 120 ? @"Memory comfortable" : (availMB > 50 ? @"Memory getting tight" : @"Memory very low");
    NSString *cp = cpu < 10 ? @"phone idle" : (cpu < 60 ? @"working" : @"heavily loaded");
    stat.text = [NSString stringWithFormat:@"%@  \u2022  %@", mem, cp];

    NSMutableArray *S = [NSMutableArray array];
    NSMutableArray *r = [NSMutableArray array];
    [r addObject:XRow(@"CPU", [NSString stringWithFormat:@"%.0f%% busy", cpu])];
    [r addObject:XRow(@"Memory", [NSString stringWithFormat:@"%@ free of %@", XBytes((uint64_t)(fr + inact)), XBytes((uint64_t)total)])];
    [r addObject:XRow(@"Battery", XBattery())];
    [r addObject:XRow(@"Phone on for", XDur([XKern uptime]))];
    [S addObject:XSec(@"Right now", nil, r)];

    NSArray *tc = tops ? [tops objectAtIndex:0] : nil;
    NSArray *tm = tops ? [tops objectAtIndex:1] : nil;
    NSMutableArray *r2 = [NSMutableArray array];
    for (NSArray *x in tc) [r2 addObject:XRow([x objectAtIndex:0], [x objectAtIndex:1])];
    if (![r2 count]) [r2 addObject:XRow(tops ? @"Nothing busy right now" : @"Scanning\u2026", @"")];
    [S addObject:XSec(@"Busiest", nil, r2)];
    NSMutableArray *r3 = [NSMutableArray array];
    for (NSArray *x in tm) [r3 addObject:XRow([x objectAtIndex:0], [x objectAtIndex:1])];
    if ([r3 count]) [S addObject:XSec(@"Biggest memory users", nil, r3)];

    if (XIsPro()) {
        NSMutableArray *rc = [NSMutableArray array];
        for (NSUInteger i = 0; i < [cores count]; i++)
            [rc addObject:XRow([NSString stringWithFormat:@"Core %lu", (unsigned long)i], XPct([[cores objectAtIndex:i] doubleValue]))];
        double la[3] = { 0, 0, 0 };
        getloadavg(la, 3);
        [rc addObject:XRow(@"Load average", [NSString stringWithFormat:@"%.2f  %.2f  %.2f", la[0], la[1], la[2]])];
        [S addObject:XSec(@"Processor", @"Load average = runnable threads over 1, 5, 15 minutes.", rc)];

        NSMutableArray *rv = [NSMutableArray array];
#define MB(key) XBytes([[vm objectForKey:key] unsignedLongLongValue])
#define NUM(key) [NSString stringWithFormat:@"%llu", [[vm objectForKey:key] unsignedLongLongValue]]
        [rv addObject:XRow(@"Free", MB(@"free"))];
        [rv addObject:XRow(@"Active", MB(@"active"))];
        [rv addObject:XRow(@"Inactive (reclaimable)", MB(@"inactive"))];
        [rv addObject:XRow(@"Wired (kernel)", MB(@"wired"))];
        [rv addObject:XRow(@"Page faults", NUM(@"faults"))];
        [rv addObject:XRow(@"Page-ins", NUM(@"pageins"))];
        [rv addObject:XRow(@"Page-outs", NUM(@"pageouts"))];
        [rv addObject:XRow(@"Copy-on-write faults", NUM(@"cow"))];
        [rv addObject:XRow(@"Zero-fill pages", NUM(@"zerofill"))];
        [rv addObject:XRow(@"Reactivations", NUM(@"reactivations"))];
        double lk = [[vm objectForKey:@"lookups"] doubleValue], ht = [[vm objectForKey:@"hits"] doubleValue];
        [rv addObject:XRow(@"VM cache hit rate", lk > 0 ? [NSString stringWithFormat:@"%.1f%%", ht / lk * 100] : @"-")];
        [rv addObject:XRow(@"Page size", NUM(@"pagesize"))];
#undef MB
#undef NUM
        [S addObject:XSec(@"Virtual memory", nil, rv)];

        NSMutableArray *rh = [NSMutableArray array];
        NSString *mach = [XKern sysctlString:"hw.machine"];
        [rh addObject:XRow(@"Model", mach ? mach : @"?")];
        [rh addObject:XRow(@"Cores", [NSString stringWithFormat:@"%llu", [XKern sysctlNumber:"hw.ncpu"]])];
        [rh addObject:XRow(@"Running as", getuid() == 0 ? @"root" : [NSString stringWithFormat:@"uid %d", getuid()])];
        [S addObject:XSec(@"Device", nil, rh)];
    }
    BOOL ok = [XCore hasKernelAccess];
    NSString *hi = [XCore accessInfo];
    [S addObject:XSec(@"Access", ok ? nil : @"Limited: /usr/libexec/xrayd must exist and be setuid root (chmod 4755).",
                      [NSArray arrayWithObjects:XRow(@"Kernel access", ok ? @"Full (task_for_pid works)" : @"Limited"),
                       XRow(@"Helper", hi ? hi : @"not found at /usr/libexec/xrayd"), nil])];
    return S;
}

@end

#pragma mark - Process list

@interface XProcDetailVC : XInfoVC {
    pid_t pid;
    NSString *pname;
}
- (id)initWithPid:(pid_t)p name:(NSString *)n;
@end

@interface XProcListVC : XBaseTable {
    NSArray *procs;
    UISegmentedControl *seg;
    BOOL busy;
}
@end

@implementation XProcListVC

- (id)init {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        self.title = @"Processes";
        [self setRefreshInterval:2.5];
    }
    return self;
}

- (void)dealloc { [procs release]; [super dealloc]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    seg = [[[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:@"CPU", @"Memory", @"PID", @"Name", nil]] autorelease];
    seg.segmentedControlStyle = UISegmentedControlStyleBar;
    seg.tintColor = [UIColor colorWithRed:0.30 green:0.19 blue:0.12 alpha:1];
    seg.selectedSegmentIndex = 0;
    seg.frame = CGRectMake(8, 6, 304, 30);
    [seg addTarget:self action:@selector(tick) forControlEvents:UIControlEventValueChanged];
    UIView *h = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 42)] autorelease];
    h.backgroundColor = XLinen();
    [h addSubview:seg];
    self.tableView.tableHeaderView = h;
    self.tableView.rowHeight = 58;
}

- (void)tick {
    if (busy) return;
    busy = YES;
    [self retain];
    int key = (int)seg.selectedSegmentIndex;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSArray *ps = [XCore processList];
        NSArray *sorted = [ps sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            XProc *x = a, *y = b;
            switch (key) {
                case 0: return x->cpu > y->cpu ? NSOrderedAscending : (x->cpu < y->cpu ? NSOrderedDescending : NSOrderedSame);
                case 1: return x->resident > y->resident ? NSOrderedAscending : (x->resident < y->resident ? NSOrderedDescending : NSOrderedSame);
                case 2: return x->pid < y->pid ? NSOrderedAscending : (x->pid > y->pid ? NSOrderedDescending : NSOrderedSame);
            }
            return [x->name caseInsensitiveCompare:y->name];
        }];
        NSArray *res = [[NSArray alloc] initWithArray:sorted];
        dispatch_async(dispatch_get_main_queue(), ^{
            [procs release];
            procs = [res retain];
            busy = NO;
            [self.tableView reloadData];
            [self release];
        });
        [res release];
        [pool drain];
    });
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return [procs count]; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"P"];
    XLed *led;
    if (!c) {
        c = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"P"] autorelease];
        c.textLabel.font = [UIFont boldSystemFontOfSize:15];
        c.detailTextLabel.font = [UIFont systemFontOfSize:11];
        c.detailTextLabel.numberOfLines = 2;
        c.detailTextLabel.textColor = [UIColor colorWithWhite:0.35 alpha:1];
        led = [[[XLed alloc] initWithFrame:CGRectMake(0, 0, 62, 14)] autorelease];
        led.tag = 77;
        c.accessoryView = led;
        c.accessoryView.tag = 77;
    }
    led = (XLed *)c.accessoryView;
    XProc *p = [procs objectAtIndex:ip.row];
    c.textLabel.text = p->name;
    if (XIsPro()) {
        c.detailTextLabel.text = [NSString stringWithFormat:@"pid %d  ppid %d  uid %d  threads %d\nrss %@  vsz %@  cpu %.1f%%",
            p->pid, p->ppid, p->uid, p->threads, XBytes(p->resident), XBytes(p->virt), p->cpu];
    } else if (!p->haveTask) {
        c.detailTextLabel.text = @"No access to this process";
    } else {
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@  \u2022  %@ memory",
            p->cpu < 3 ? @"Idle" : [NSString stringWithFormat:@"Busy %.0f%%", p->cpu], XBytes(p->resident)];
    }
    [led setLevel:p->haveTask ? p->cpu : 0];
    c.accessoryType = UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    XProc *p = [procs objectAtIndex:ip.row];
    [self.navigationController pushViewController:[[[XProcDetailVC alloc] initWithPid:p->pid name:p->name] autorelease] animated:YES];
}

@end

#pragma mark - Process detail

@implementation XProcDetailVC

- (id)initWithPid:(pid_t)p name:(NSString *)n {
    self = [super initWithTitle:n interval:2.0 provider:nil];
    if (self) {
        pid = p;
        pname = [n copy];
    }
    return self;
}

- (void)dealloc { [pname release]; [super dealloc]; }

- (NSArray *)build {
    XProc *p = [XCore procForPid:pid];
    if (!p) return [NSArray arrayWithObject:XSec(@"This process has ended", nil, [NSArray array])];
    pid_t xpid = pid;
    NSString *xname = [[pname copy] autorelease];
    UIViewController *me = self;
    NSMutableArray *S = [NSMutableArray array];
    NSMutableArray *r = [NSMutableArray array];

    if (!XIsPro()) {
        NSString *what = !p->haveTask ? @"Can't look inside (no access)"
                       : (p->cpu < 3 ? @"Idle, waiting for work" : [NSString stringWithFormat:@"Busy, using %.0f%% of the CPU", p->cpu]);
        [r addObject:XRow(@"Status", what)];
        if (p->haveTask) {
            [r addObject:XRow(@"Memory", XBytes(p->resident))];
            [r addObject:XRow(@"Threads", [NSString stringWithFormat:@"%d", p->threads])];
        }
        if (p->path) [r addObject:XRow(@"Program", p->path)];
        [S addObject:XSec(@"Summary", nil, r)];
    } else {
        [r addObject:XRow(@"PID / parent", [NSString stringWithFormat:@"%d / %d", p->pid, p->ppid])];
        [r addObject:XRow(@"User ID", [NSString stringWithFormat:@"%d", p->uid])];
        static const char *sn[] = { "?", "idle", "running", "sleeping", "stopped", "zombie" };
        [r addObject:XRow(@"State", [NSString stringWithUTF8String:sn[p->stat >= 0 && p->stat < 6 ? p->stat : 0]])];
        if (p->path) [r addObject:XRow(@"Path", p->path)];
        [S addObject:XSec(@"Identity", nil, r)];
        NSMutableArray *r2 = [NSMutableArray array];
        [r2 addObject:XRow(@"CPU now", [NSString stringWithFormat:@"%.1f%%", p->cpu])];
        [r2 addObject:XRow(@"CPU time user / system", [NSString stringWithFormat:@"%.2f s / %.2f s", p->userTime, p->sysTime])];
        [r2 addObject:XRow(@"Resident memory", XBytes(p->resident))];
        [r2 addObject:XRow(@"Virtual size", XBytes(p->virt))];
        [r2 addObject:XRow(@"Threads", [NSString stringWithFormat:@"%d", p->threads])];
        [r2 addObject:XRow(@"Suspend count", [NSString stringWithFormat:@"%d", p->suspend])];
        [S addObject:XSec(@"Resources", nil, r2)];
        NSArray *ev = [XCore taskEventsForPid:pid];
        if (ev) {
            NSMutableArray *r3 = [NSMutableArray array];
            for (NSArray *e in ev)
                [r3 addObject:XRow([e objectAtIndex:0], [NSString stringWithFormat:@"%lld", [[e objectAtIndex:1] longLongValue]])];
            [S addObject:XSec(@"Counters since launch", nil, r3)];
        }
    }

    NSMutableArray *t = [NSMutableArray array];
    [t addObject:XGo(XIsPro() ? @"Threads and stacks" : @"What is it doing right now?", @"", ^(UINavigationController *nav) {
        [nav pushViewController:[[[XThreadsVC alloc] initWithPid:xpid name:xname] autorelease] animated:YES]; })];
    [t addObject:XGo(XIsPro() ? @"Sampler (hot spots)" : @"Where does the time go? (5 s)", @"", ^(UINavigationController *nav) {
        [nav pushViewController:[[[XSamplerVC alloc] initWithPid:xpid name:xname] autorelease] animated:YES]; })];
    [t addObject:XGo(XIsPro() ? @"Memory map" : @"Memory by library", @"", ^(UINavigationController *nav) {
        [nav pushViewController:[[[XMapVC alloc] initWithPid:xpid name:xname] autorelease] animated:YES]; })];
    [t addObject:XGo(@"Open files", @"", ^(UINavigationController *nav) {
        [nav pushViewController:[[[XFilesVC alloc] initWithPid:xpid name:xname] autorelease] animated:YES]; })];
    [t addObject:XGo(@"Live activity (kernel trace)", @"", ^(UINavigationController *nav) {
        [nav pushViewController:[[[XTraceVC alloc] initWithPid:xpid] autorelease] animated:YES]; })];
    if (XIsPro()) {
        [t addObject:XGo(@"Hex memory viewer (read-only)", @"", ^(UINavigationController *nav) {
            uint32_t def = 0x1000;
            for (XRegion *rg in [XCore regionsForPid:xpid]) if (rg->prot & VM_PROT_EXECUTE) { def = rg->addr; break; }
            [XPrompt ask:@"Start address (hex)" text:[NSString stringWithFormat:@"%08x", def] done:^(NSString *s) {
                uint32_t a = (uint32_t)strtoul([s UTF8String], NULL, 16);
                [nav pushViewController:[[[XHexVC alloc] initWithPid:xpid addr:a] autorelease] animated:YES];
            }];
        })];
        if (pid > 0) [t addObject:XGo(@"Send signal\u2026", @"", ^(UINavigationController *nav) {
            UIActionSheet *sh = [[[UIActionSheet alloc] initWithTitle:[NSString stringWithFormat:@"%@ (pid %d)", xname, xpid]
                delegate:(id)me cancelButtonTitle:@"Cancel" destructiveButtonTitle:@"Kill (SIGKILL)"
                otherButtonTitles:@"Pause (SIGSTOP)", @"Resume (SIGCONT)", @"Quit (SIGTERM)", nil] autorelease];
            [sh showInView:((UIViewController *)me).tabBarController.view];
        })];
    }
    [S addObject:XSec(@"Look inside", nil, t)];
    return S;
}

- (void)actionSheet:(UIActionSheet *)sh clickedButtonAtIndex:(NSInteger)i {
    int sig = 0;
    if (i == 0) sig = SIGKILL;
    else if (i == 1) sig = SIGSTOP;
    else if (i == 2) sig = SIGCONT;
    else if (i == 3) sig = SIGTERM;
    if (sig && pid > 0) [XCore signalPid:pid sig:sig];
}

@end

#pragma mark - Threads and stacks

@interface XThreadsVC ()
@end

@interface XThreadsInfo : XInfoVC {
    pid_t pid;
}
- (id)initWithPid:(pid_t)p name:(NSString *)n;
@end

@implementation XThreadsInfo

- (id)initWithPid:(pid_t)p name:(NSString *)n {
    self = [super initWithTitle:[NSString stringWithFormat:@"%@ threads", n] interval:2.5 provider:nil];
    if (self) pid = p;
    return self;
}

- (NSArray *)build {
    NSArray *th = [XCore threadsForPid:pid];
    if (!th) return [NSArray arrayWithObject:XSec(@"No access to this process", @"Needs root (setuid) and a kernel with task_for_pid enabled.", [NSArray array])];
    NSMutableArray *S = [NSMutableArray array];
    if (!XIsPro()) {
        NSMutableArray *r = [NSMutableArray array];
        for (XThread *t in th)
            [r addObject:XRow([NSString stringWithFormat:@"Thread %d", t->index + 1], [XCore describeTop:t])];
        [S addObject:XSec(@"What each thread is doing", @"Sleeping threads are just waiting for work, which is normal.", r)];
    } else {
        for (XThread *t in th) {
            NSString *title = [NSString stringWithFormat:@"Thread %d  tid %llx  %.0f%%  %@", t->index + 1, t->tid, t->cpu, [XCore stateName:t->runState]];
            NSMutableArray *r = [NSMutableArray array];
            if (t->haveRegs)
                [r addObject:XRow(@"regs", [NSString stringWithFormat:@"pc %08x lr %08x sp %08x r7 %08x cpsr %08x",
                                            t->regs[15], t->regs[14], t->regs[13], t->regs[7], t->regs[16]])];
            for (NSUInteger i = 0; i < [t->symbols count]; i++)
                [r addObject:XRow([NSString stringWithFormat:@"#%lu", (unsigned long)i], [t->symbols objectAtIndex:i])];
            if (![r count]) [r addObject:XRow(@"stack", @"unavailable")];
            [S addObject:XSec(title, nil, r)];
        }
    }
    return S;
}

@end

@implementation XThreadsVC
- (id)initWithPid:(pid_t)pid name:(NSString *)name {
    [self release];
    return (XThreadsVC *)[[XThreadsInfo alloc] initWithPid:pid name:name];
}
@end

#pragma mark - Sampler

@interface XSamplerInfo : XInfoVC {
    pid_t pid;
    XSampler *smp;
    BOOL running;
    double progress;
}
- (id)initWithPid:(pid_t)p name:(NSString *)n;
@end

@implementation XSamplerInfo

- (id)initWithPid:(pid_t)p name:(NSString *)n {
    self = [super initWithTitle:[NSString stringWithFormat:@"%@ sampler", n] interval:0.5 provider:nil];
    if (self) pid = p;
    return self;
}

- (void)dealloc { [smp release]; [super dealloc]; }

- (void)start {
    if (running) return;
    running = YES;
    progress = 0;
    [smp release];
    smp = [[XSampler alloc] initWithPid:pid includeWaiting:XIsPro()];
    XSampler *s = smp;
    [self retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSDate *t0 = [NSDate date];
        while (1) {
            double el = -[t0 timeIntervalSinceNow];
            if (el >= 5.0) break;
            if (![s step]) break;
            progress = el / 5.0;
            usleep(8000);
        }
        [s finish];
        dispatch_async(dispatch_get_main_queue(), ^{
            running = NO;
            progress = 1;
            [self rebuild];
            [self release];
        });
        [pool drain];
    });
}

- (NSArray *)build {
    NSMutableArray *S = [NSMutableArray array];
    XSamplerInfo *me = self;
    id first = running ? XRow(@"Sampling\u2026", XPct(progress * 100))
                       : XGo(smp ? @"Run again (5 s)" : @"Start 5-second sample", @"", ^(UINavigationController *nav) { [me start]; });
    [S addObject:XSec(nil, XIsPro() ? @"Suspends each thread for microseconds, 100 times a second, and records the stack. 'self' = time at the top of the stack, 'total' = time anywhere in the stack." : @"Take a 5-second look at what this program is busy with.", [NSArray arrayWithObject:first])];
    if (smp) {
        NSArray *rep = [smp report];
        int total = [smp threadSampleCount];
        NSMutableArray *r = [NSMutableArray array];
        int lim = XIsPro() ? 50 : 8;
        for (NSDictionary *d in rep) {
            if ((int)[r count] >= lim) break;
            double sf = total ? [[d objectForKey:@"self"] intValue] * 100.0 / total : 0;
            double tt = total ? [[d objectForKey:@"total"] intValue] * 100.0 / total : 0;
            if (!XIsPro() && sf < 1) continue;
            NSString *v = XIsPro() ? [NSString stringWithFormat:@"self %.1f%%  total %.1f%%", sf, MIN(tt, 100.0)]
                                   : [NSString stringWithFormat:@"%.0f%% of its working time", sf];
            [r addObject:XRow([d objectForKey:@"sym"], v)];
        }
        if (![r count]) [r addObject:XRow(running ? @"Collecting\u2026" : @"Nothing was running (idle)", @"")];
        [S addObject:XSec(@"Hot spots", nil, r)];
    }
    return S;
}

@end

@implementation XSamplerVC
- (id)initWithPid:(pid_t)pid name:(NSString *)name {
    [self release];
    return (XSamplerVC *)[[XSamplerInfo alloc] initWithPid:pid name:name];
}
@end

#pragma mark - Memory map

@interface XMapInfo : XInfoVC {
    pid_t pid;
}
- (id)initWithPid:(pid_t)p name:(NSString *)n;
@end

@implementation XMapInfo

- (id)initWithPid:(pid_t)p name:(NSString *)n {
    self = [super initWithTitle:[NSString stringWithFormat:@"%@ memory", n] interval:0 provider:nil];
    if (self) pid = p;
    return self;
}

static NSString *XProt(int p) {
    return [NSString stringWithFormat:@"%c%c%c", (p & VM_PROT_READ) ? 'r' : '-', (p & VM_PROT_WRITE) ? 'w' : '-', (p & VM_PROT_EXECUTE) ? 'x' : '-'];
}

- (NSArray *)build {
    NSArray *regs = [XCore regionsForPid:pid];
    if (!regs) return [NSArray arrayWithObject:XSec(@"No access to this process", nil, [NSArray array])];
    uint64_t tv = 0, tr = 0;
    for (XRegion *g in regs) { tv += g->size; tr += g->resident; }
    NSMutableArray *S = [NSMutableArray array];
    [S addObject:XSec(nil, nil, [NSArray arrayWithObject:XRow(@"Total", [NSString stringWithFormat:@"%@ in use of %@ reserved", XBytes(tr), XBytes(tv)])])];
    if (!XIsPro()) {
        NSMutableDictionary *agg = [NSMutableDictionary dictionary];
        for (XRegion *g in regs) {
            NSString *k = g->file ? XBase(g->file) : @"Heap, stacks and other";
            NSMutableArray *a = [agg objectForKey:k];
            if (!a) { a = [NSMutableArray arrayWithObjects:[NSNumber numberWithUnsignedLongLong:0], [NSNumber numberWithUnsignedLongLong:0], nil]; [agg setObject:a forKey:k]; }
            [a replaceObjectAtIndex:0 withObject:[NSNumber numberWithUnsignedLongLong:[[a objectAtIndex:0] unsignedLongLongValue] + g->resident]];
            [a replaceObjectAtIndex:1 withObject:[NSNumber numberWithUnsignedLongLong:[[a objectAtIndex:1] unsignedLongLongValue] + g->size]];
        }
        NSArray *keys = [[agg allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            unsigned long long x = [[[agg objectForKey:a] objectAtIndex:0] unsignedLongLongValue];
            unsigned long long y = [[[agg objectForKey:b] objectAtIndex:0] unsignedLongLongValue];
            return x > y ? NSOrderedAscending : (x < y ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray *r = [NSMutableArray array];
        for (NSString *k in keys) {
            if ([r count] >= 25) break;
            NSArray *a = [agg objectForKey:k];
            [r addObject:XRow(k, XBytes([[a objectAtIndex:0] unsignedLongLongValue]))];
        }
        [S addObject:XSec(@"Biggest memory users (resident)", nil, r)];
    } else {
        pid_t xpid = pid;
        NSMutableArray *r = [NSMutableArray array];
        for (XRegion *g in regs) {
            NSString *k = [NSString stringWithFormat:@"%08x-%08x %@", g->addr, g->addr + g->size, XProt(g->prot)];
            NSString *v = [NSString stringWithFormat:@"%@ / %@%@%@", XBytes(g->resident), XBytes(g->size),
                           g->share == 1 ? @"  shared" : @"", g->file ? [@"  " stringByAppendingString:XBase(g->file)] : @""];
            uint32_t a = g->addr;
            [r addObject:XGo(k, v, ^(UINavigationController *nav) {
                [nav pushViewController:[[[XHexVC alloc] initWithPid:xpid addr:a] autorelease] animated:YES]; })];
        }
        [S addObject:XSec(@"Regions (resident / size). Tap to view bytes.", nil, r)];
    }
    return S;
}

@end

@implementation XMapVC
- (id)initWithPid:(pid_t)pid name:(NSString *)name {
    [self release];
    return (XMapVC *)[[XMapInfo alloc] initWithPid:pid name:name];
}
@end

#pragma mark - Open files

@interface XFilesInfo : XInfoVC {
    pid_t pid;
}
- (id)initWithPid:(pid_t)p name:(NSString *)n;
@end

@implementation XFilesInfo

- (id)initWithPid:(pid_t)p name:(NSString *)n {
    self = [super initWithTitle:[NSString stringWithFormat:@"%@ files", n] interval:3.0 provider:nil];
    if (self) pid = p;
    return self;
}

- (NSArray *)build {
    NSArray *fs = [XCore openFilesForPid:pid];
    if (!fs) return [NSArray arrayWithObject:XSec(@"No access to this process", nil, [NSArray array])];
    NSMutableDictionary *cnt = [NSMutableDictionary dictionary];
    NSMutableArray *paths = [NSMutableArray array];
    for (NSDictionary *f in fs) {
        NSString *t = [f objectForKey:@"type"];
        [cnt setObject:[NSNumber numberWithInt:[[cnt objectForKey:t] intValue] + 1] forKey:t];
        NSString *p = [f objectForKey:@"path"];
        if ([p length]) {
            if (XIsPro()) [paths addObject:XRow([NSString stringWithFormat:@"fd %@", [f objectForKey:@"fd"]], p)];
            else [paths addObject:XRow(XBase(p), p)];
        } else if (XIsPro()) {
            [paths addObject:XRow([NSString stringWithFormat:@"fd %@", [f objectForKey:@"fd"]], [f objectForKey:@"type"])];
        }
    }
    NSMutableArray *sm = [NSMutableArray array];
    for (NSString *k in [[cnt allKeys] sortedArrayUsingSelector:@selector(compare:)])
        [sm addObject:XRow(k, [NSString stringWithFormat:@"%d", [[cnt objectForKey:k] intValue]])];
    NSMutableArray *S = [NSMutableArray array];
    [S addObject:XSec(@"Open right now", nil, sm)];
    if ([paths count]) [S addObject:XSec(@"Files", nil, paths)];
    return S;
}

@end

@implementation XFilesVC
- (id)initWithPid:(pid_t)pid name:(NSString *)name {
    [self release];
    return (XFilesVC *)[[XFilesInfo alloc] initWithPid:pid name:name];
}
@end

#pragma mark - Hex viewer (read-only)

@interface XHexView : XBaseTable {
    pid_t pid;
    uint32_t base;
    NSData *data;
}
- (id)initWithPid:(pid_t)p addr:(uint32_t)a;
@end

@implementation XHexView

- (id)initWithPid:(pid_t)p addr:(uint32_t)a {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        pid = p;
        base = a & ~7u;
    }
    return self;
}

- (void)dealloc { [data release]; [super dealloc]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    UISegmentedControl *s = [[[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:@"\u25C0 Prev", @"Go to\u2026", @"Next \u25B6", nil]] autorelease];
    s.segmentedControlStyle = UISegmentedControlStyleBar;
    s.tintColor = [UIColor colorWithRed:0.30 green:0.19 blue:0.12 alpha:1];
    s.momentary = YES;
    s.frame = CGRectMake(8, 6, 304, 30);
    [s addTarget:self action:@selector(nav:) forControlEvents:UIControlEventValueChanged];
    UIView *h = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 42)] autorelease];
    h.backgroundColor = XLinen();
    [h addSubview:s];
    self.tableView.tableHeaderView = h;
    self.tableView.rowHeight = 18;
}

- (void)nav:(UISegmentedControl *)s {
    if (s.selectedSegmentIndex == 0) { base -= 4096; [self tick]; }
    else if (s.selectedSegmentIndex == 2) { base += 4096; [self tick]; }
    else {
        [XPrompt ask:@"Go to address (hex)" text:[NSString stringWithFormat:@"%08x", base] done:^(NSString *t) {
            base = (uint32_t)strtoul([t UTF8String], NULL, 16) & ~7u;
            [self tick];
        }];
    }
}

- (void)tick {
    [data release];
    data = nil;
    for (uint32_t len = 4096; len >= 8 && !data; len /= 2) data = [[XCore readPid:pid addr:base len:len] retain];
    self.title = [NSString stringWithFormat:@"%08x", base];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return data ? (NSInteger)(([data length] + 7) / 8) : 1; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"H"];
    if (!c) {
        c = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"H"] autorelease];
        c.textLabel.font = [UIFont fontWithName:@"Courier" size:11];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    if (!data) { c.textLabel.text = @"Unreadable (unmapped or protected)"; return c; }
    const unsigned char *b = (const unsigned char *)[data bytes];
    NSUInteger off = ip.row * 8, len = [data length];
    NSMutableString *hx = [NSMutableString string], *as = [NSMutableString string];
    for (int j = 0; j < 8; j++) {
        if (off + j < len) {
            unsigned char ch = b[off + j];
            [hx appendFormat:@"%02x ", ch];
            [as appendFormat:@"%c", (ch >= 32 && ch < 127) ? ch : '.'];
        } else {
            [hx appendString:@"   "];
        }
    }
    c.textLabel.text = [NSString stringWithFormat:@"%08x  %@|%@|", (unsigned)(base + off), hx, as];
    return c;
}

@end

@implementation XHexVC
- (id)initWithPid:(pid_t)pid addr:(uint32_t)addr {
    [self release];
    return (XHexVC *)[[XHexView alloc] initWithPid:pid addr:addr];
}
@end

#pragma mark - Live kernel trace

@interface XTraceView : XBaseTable {
    pid_t pid;
    int filter;
    NSArray *shown;
    UISegmentedControl *seg;
}
- (id)initWithPid:(pid_t)p;
@end

@implementation XTraceView

- (id)initWithPid:(pid_t)p {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        pid = p;
        filter = 1;
        self.title = p > 0 ? @"Live activity" : @"Trace";
        [self setRefreshInterval:0.4];
    }
    return self;
}

- (void)dealloc {
    if (pid > 0) [[XTrace shared] stop];
    [shown release];
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    seg = [[[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:@"All", @"Files/Sys", @"Mach", @"FS", @"Net", @"IOKit", nil]] autorelease];
    seg.segmentedControlStyle = UISegmentedControlStyleBar;
    seg.tintColor = [UIColor colorWithRed:0.30 green:0.19 blue:0.12 alpha:1];
    seg.selectedSegmentIndex = 1;
    seg.frame = CGRectMake(8, 6, 304, 30);
    [seg addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];
    UIView *h = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 42)] autorelease];
    h.backgroundColor = XLinen();
    [h addSubview:seg];
    self.tableView.tableHeaderView = h;
    self.tableView.rowHeight = 24;
    [self updateButtons];
}

- (void)updateButtons {
    self.navigationItem.leftBarButtonItems = [NSArray arrayWithObjects:
        [[[UIBarButtonItem alloc] initWithTitle:[[XTrace shared] running] ? @"Stop" : @"Start" style:UIBarButtonItemStyleBordered target:self action:@selector(startStop)] autorelease],
        [[[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStyleBordered target:self action:@selector(clearLog)] autorelease], nil];
}

- (void)updateModeButton {
    [super updateModeButton];
    [self updateButtons];
}

- (void)startStop {
    XTrace *t = [XTrace shared];
    if ([t running]) { [t stop]; }
    else if (![t startFilter:filter pid:pid]) {
        [[[[UIAlertView alloc] initWithTitle:@"Trace failed" message:[t lastError] delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] autorelease] show];
    }
    [self updateButtons];
}

- (void)clearLog { [[XTrace shared] clear]; [self tick]; }

- (void)filterChanged {
    filter = (int)seg.selectedSegmentIndex;
    XTrace *t = [XTrace shared];
    if ([t running]) { [t stop]; [t startFilter:filter pid:pid]; }
    [self updateButtons];
}

- (void)tick {
    NSArray *all = [[XTrace shared] snapshot];
    NSMutableArray *out = [NSMutableArray array];
    BOOL pro = XIsPro();
    for (NSInteger i = (NSInteger)[all count] - 1; i >= 0 && [out count] < 400; i--) {
        XEvent *e = [all objectAtIndex:i];
        NSString *s = pro ? e->raw : e->simple;
        if (s) [out addObject:s];
    }
    [shown release];
    shown = [out retain];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return [shown count] ? [shown count] : 1; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"T"];
    if (!c) {
        c = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"T"] autorelease];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        c.textLabel.lineBreakMode = UILineBreakModeMiddleTruncation;
    }
    c.textLabel.font = XIsPro() ? [UIFont fontWithName:@"Courier" size:9] : [UIFont systemFontOfSize:12];
    if (![shown count]) c.textLabel.text = [[XTrace shared] running] ? @"Waiting for events\u2026" : @"Tap Start to watch what the system is doing";
    else c.textLabel.text = [shown objectAtIndex:ip.row];
    return c;
}

@end

@implementation XTraceVC
- (id)initWithPid:(pid_t)pid {
    [self release];
    return (XTraceVC *)[[XTraceView alloc] initWithPid:pid];
}
@end

#pragma mark - Kernel tab

@interface XKernelVC : XInfoVC
@end

@implementation XKernelVC

- (id)init { return [super initWithTitle:@"Kernel" interval:2.0 provider:nil]; }

- (NSArray *)build {
    NSMutableArray *S = [NSMutableArray array];
    NSMutableArray *r = [NSMutableArray array];
    NSString *ver = [XKern sysctlString:"kern.version"];
    NSString *osv = [XKern sysctlString:"kern.osversion"];
    NSString *rel = [XKern sysctlString:"kern.osrelease"];
    [r addObject:XRow(@"Darwin", rel ? rel : @"?")];
    [r addObject:XRow(@"iOS build", osv ? osv : @"?")];
    if (XIsPro() && ver) [r addObject:XRow(@"Kernel version", ver)];
    [r addObject:XRow(@"Up for", XDur([XKern uptime]))];
    [S addObject:XSec(@"Kernel", nil, r)];

    NSMutableArray *l = [NSMutableArray array];
    [l addObject:XRow(@"Max processes", [NSString stringWithFormat:@"%llu", [XKern sysctlNumber:"kern.maxproc"]])];
    [l addObject:XRow(@"Max open files (system)", [NSString stringWithFormat:@"%llu", [XKern sysctlNumber:"kern.maxfiles"]])];
    [l addObject:XRow(@"Max open files (per process)", [NSString stringWithFormat:@"%llu", [XKern sysctlNumber:"kern.maxfilesperproc"]])];
    [S addObject:XSec(@"Limits", nil, l)];

    if (XIsPro()) {
        NSArray *cores = [XKern perCPULoads];
        NSMutableArray *c = [NSMutableArray array];
        for (NSUInteger i = 0; i < [cores count]; i++)
            [c addObject:XRow([NSString stringWithFormat:@"Core %lu", (unsigned long)i], XPct([[cores objectAtIndex:i] doubleValue]))];
        [S addObject:XSec(@"Scheduler", nil, c)];
        NSMutableArray *t = [NSMutableArray array];
        [t addObject:XGo(@"All kernel parameters (sysctl)", @"", ^(UINavigationController *nav) {
            [nav pushViewController:[[[XSysctlVC alloc] initWithStyle:UITableViewStylePlain] autorelease] animated:YES]; })];
        [t addObject:XGo(@"Kernel threads", @"", ^(UINavigationController *nav) {
            [nav pushViewController:[[[XThreadsVC alloc] initWithPid:0 name:@"kernel_task"] autorelease] animated:YES]; })];
        [t addObject:XGo(@"Kernel memory (hex, read-only)", @"", ^(UINavigationController *nav) {
            [XPrompt ask:@"Kernel address (hex)" text:@"80001000" done:^(NSString *s) {
                uint32_t a = (uint32_t)strtoul([s UTF8String], NULL, 16);
                [nav pushViewController:[[[XHexVC alloc] initWithPid:0 addr:a] autorelease] animated:YES];
            }];
        })];
        [S addObject:XSec(@"Tools", @"Kernel threads and memory need a patched task_for_pid(0).", t)];
    } else {
        [S addObject:XSec(nil, @"Switch to Pro (top right) for the raw kernel view.", [NSArray array])];
    }
    return S;
}

@end

#pragma mark - sysctl browser

@interface XSysctlView : XBaseTable <UISearchBarDelegate> {
    NSArray *all, *shown;
    UISearchBar *sb;
    BOOL loading;
}
@end

@implementation XSysctlView

- (id)initWithStyle:(UITableViewStyle)s {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) self.title = @"sysctl";
    return self;
}

- (void)dealloc { [all release]; [shown release]; [super dealloc]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    sb = [[[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)] autorelease];
    sb.delegate = self;
    sb.autocapitalizationType = UITextAutocapitalizationTypeNone;
    sb.autocorrectionType = UITextAutocorrectionTypeNo;
    sb.placeholder = @"Filter name or value";
    self.tableView.tableHeaderView = sb;
    self.tableView.rowHeight = 46;
}

- (void)tick {
    if (all || loading) return;
    loading = YES;
    [self retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSArray *d = [XKern sysctlDump];
        NSArray *res = [[NSArray alloc] initWithArray:d];
        dispatch_async(dispatch_get_main_queue(), ^{
            all = [res retain];
            loading = NO;
            [self applyFilter];
            [self release];
        });
        [res release];
        [pool drain];
    });
}

- (void)applyFilter {
    NSString *q = [[sb.text lowercaseString] copy];
    NSMutableArray *o = [NSMutableArray array];
    for (NSDictionary *d in all) {
        if (![q length] || [[[d objectForKey:@"name"] lowercaseString] rangeOfString:q].location != NSNotFound ||
            [[[d objectForKey:@"value"] lowercaseString] rangeOfString:q].location != NSNotFound)
            [o addObject:d];
    }
    [q release];
    [shown release];
    shown = [o retain];
    [self.tableView reloadData];
}

- (void)searchBar:(UISearchBar *)b textDidChange:(NSString *)t { [self applyFilter]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)b { [b resignFirstResponder]; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return all ? (NSInteger)[shown count] : 1; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"Y"];
    if (!c) {
        c = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Y"] autorelease];
        c.textLabel.font = [UIFont fontWithName:@"Courier" size:12];
        c.detailTextLabel.font = [UIFont fontWithName:@"Courier" size:11];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    if (!all) { c.textLabel.text = @"Reading the kernel parameter tree\u2026"; c.detailTextLabel.text = @""; return c; }
    NSDictionary *d = [shown objectAtIndex:ip.row];
    c.textLabel.text = [d objectForKey:@"name"];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@  (%@)", [d objectForKey:@"value"], [d objectForKey:@"type"]];
    return c;
}

@end

@implementation XSysctlVC
- (id)initWithStyle:(UITableViewStyle)s {
    [self release];
    return (XSysctlVC *)[[XSysctlView alloc] initWithStyle:s];
}
@end

#pragma mark - root

static UINavigationController *XNav(UIViewController *vc, NSString *title, int icon, int tag) {
    UINavigationController *n = [[[UINavigationController alloc] initWithRootViewController:vc] autorelease];
    n.tabBarItem = [[[UITabBarItem alloc] initWithTitle:title image:XIcon(icon) tag:tag] autorelease];
    return n;
}

UIViewController *XMakeRoot(void) {
    XApplySkin();
    UITabBarController *tb = [[[UITabBarController alloc] init] autorelease];
    tb.viewControllers = [NSArray arrayWithObjects:
        XNav([[[XOverviewVC alloc] init] autorelease], @"Overview", 0, 0),
        XNav([[[XProcListVC alloc] init] autorelease], @"Processes", 1, 1),
        XNav([[[XTraceView alloc] initWithPid:0] autorelease], @"Trace", 2, 2),
        XNav([[[XKernelVC alloc] init] autorelease], @"Kernel", 3, 3), nil];
    return tb;
}
