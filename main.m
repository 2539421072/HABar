#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import "HAClient.h"

static NSString *const kURLKey = @"ha_url";
static NSString *const kTokenKey = @"ha_token";
static NSString *const kDefaultURL = @"http://192.168.31.200:8123";
static NSString *const kDefaultToken = @"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiI4YWFhYzRkYTA5ZjA0YTY4OGFmZmQyYzM3ZGVkNmE4NCIsImlhdCI6MTc5MzYxOTcyMCwiZXhwIjoyMTA4OTc5NzIwfQ.9vaazzOqmYfijwONjY6tW_8x_26fZWgr1HtzCXA_SVk";

static NSString *gSnapshotPath = nil;
static NSString *gHTMLPath = nil;
static double gSnapshotDelay = 3.0;
static BOOL gSelfTest = NO;
static NSString *gEvalJS = nil;
static BOOL gShowPopover = NO;
static BOOL gStats = NO;
static CGFloat gShotW = 1020;
static CGFloat gShotH = 760;

static const CGFloat kPanelW = 1020;
static const CGFloat kPanelH = 760;

static NSString *JSStringLiteral(NSString *s) {
    if (!s) return @"\"\"";
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[s] options:0 error:nil];
    NSString *arr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (arr.length < 2) return @"\"\"";
    return [arr substringWithRange:NSMakeRange(1, arr.length - 2)];
}

@interface AppDelegate : NSObject <NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler, HAClientDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSPopover *popover;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) HAClient *client;
@property (nonatomic, strong) NSArray *cachedStates;
@property (nonatomic, strong) NSMutableDictionary *pendingStates;
@property (nonatomic, assign) BOOL flushScheduled;
@property (nonatomic, assign) BOOL webReady;
@property (nonatomic, assign) NSInteger unreadErrors;
@property (nonatomic, assign) BOOL filterNoise;
@property (nonatomic, strong) NSMutableSet<NSString *> *panelIDs;
@property (nonatomic, assign) NSUInteger noiseSkipped;
@property (nonatomic, assign) NSUInteger statIn;
@property (nonatomic, assign) NSUInteger statOut;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    // 单实例保护：无头调试模式（截图/自检）不受限制
    if (!gSelfTest && !gSnapshotPath && !gShowPopover) {
        NSArray<NSRunningApplication *> *same = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"cn.local.habar"];
        for (NSRunningApplication *app in same) {
            if (app.processIdentifier != [NSProcessInfo processInfo].processIdentifier) {
                NSLog(@"[HABar] 已有实例在运行（pid=%d），本实例退出", app.processIdentifier);
                [NSApp terminate:nil];
                return;
            }
        }
    }

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (![ud stringForKey:kURLKey]) [ud setObject:kDefaultURL forKey:kURLKey];
    if (![ud stringForKey:kTokenKey]) [ud setObject:kDefaultToken forKey:kTokenKey];

    self.client = [[HAClient alloc] init];
    self.client.delegate = self;
    self.client.baseURL = [ud stringForKey:kURLKey];
    self.client.token = [ud stringForKey:kTokenKey];
    self.pendingStates = [NSMutableDictionary dictionary];
    [self loadNoiseSettings];

    [self buildWebView];

    if (gSelfTest) {
        [self runSelfTest];
        return;
    }
    if (gSnapshotPath) {
        [self runSnapshot];
        return;
    }

    [self buildStatusItem];
    [self.client start];
    [self registerGlobalHotkeyFallback];

    if (gStats) {
        [NSTimer scheduledTimerWithTimeInterval:10 repeats:YES block:^(NSTimer *t) {
            NSLog(@"[HABar] STAT in=%lu filtered=%lu out=%lu filterOn=%d",
                  (unsigned long)self.statIn, (unsigned long)self.noiseSkipped,
                  (unsigned long)self.statOut, (int)self.filterNoise);
        }];
    }

    if (gShowPopover) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showPopover];
        });
        if (gEvalJS.length) {
            double d = gSnapshotDelay > 2.4 ? gSnapshotDelay - 1.2 : 2.0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self.webView evaluateJavaScript:gEvalJS completionHandler:nil];
            });
        }
    }
}

- (void)registerGlobalHotkeyFallback {
    // 保留占位：后续可扩展全局快捷键
}

#pragma mark - webview

- (void)buildWebView {
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *uc = [[WKUserContentController alloc] init];
    [uc addScriptMessageHandler:self name:@"ha"];
    cfg.userContentController = uc;
    cfg.preferences.javaScriptCanOpenWindowsAutomatically = NO;
    [cfg.preferences setValue:@YES forKey:@"developerExtrasEnabled"];

    self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, kPanelW, kPanelH) configuration:cfg];
    self.webView.navigationDelegate = self;
    self.webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.webView setValue:@NO forKey:@"drawsBackground"];

    NSURL *url = nil;
    NSURL *readAccess = nil;
    if (gHTMLPath.length) {
        url = [NSURL fileURLWithPath:gHTMLPath];
        readAccess = [url URLByDeletingLastPathComponent];
    } else {
        url = [[NSBundle mainBundle] URLForResource:@"index" withExtension:@"html"];
        readAccess = [[NSBundle mainBundle] resourceURL];
    }
    if (url) [self.webView loadFileURL:url allowingReadAccessToURL:readAccess];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.webReady = YES;
    // 页面会主动发 ready，届时再推送配置/偏好/状态，避免竞态
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *body = message.body;
    NSString *action = body[@"t"];

    if ([action isEqualToString:@"ready"]) {
        [self pushConfig];
        [self pushPrefs];
        [self pushStatus];
        if (self.cachedStates.count) [self sendEvent:@{@"t": @"states", @"data": self.cachedStates}];
        [self pushMeta];
        return;
    }
    if ([action isEqualToString:@"autostart"]) {
        [self setAutostart:[body[@"on"] boolValue]];
        return;
    }
    if ([action isEqualToString:@"noise"]) {
        self.filterNoise = [body[@"on"] boolValue];
        [[NSUserDefaults standardUserDefaults] setBool:self.filterNoise forKey:@"filterNoise"];
        [self pushConfig];
        return;
    }
    if ([action isEqualToString:@"prefs"]) {
        NSDictionary *data = body[@"data"];
        if ([data isKindOfClass:[NSDictionary class]]) {
            [[NSUserDefaults standardUserDefaults] setObject:data forKey:@"ui_prefs"];
            [self syncPanelIDsFromPrefs:data];
        }
        return;
    }
    if ([action isEqualToString:@"saveConfig"]) {
        NSString *url = body[@"url"] ?: @"";
        NSString *token = body[@"token"] ?: @"";
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setObject:url forKey:kURLKey];
        [ud setObject:token forKey:kTokenKey];
        [ud synchronize];
        self.client.baseURL = url;
        self.client.token = token;
        self.cachedStates = nil;
        [self.client restart];
        [self toast:@"已保存设置，正在重新连接"];
        return;
    }
    if ([action isEqualToString:@"refresh"]) {
        [self.client fetchStatesWithCompletion:nil];
        [self toast:@"正在刷新"];
        return;
    }
    if ([action isEqualToString:@"reconnect"]) {
        [self.client restart];
        return;
    }
    if ([action isEqualToString:@"test"]) {
        NSString *url = body[@"url"] ?: self.client.baseURL;
        NSString *token = body[@"token"] ?: self.client.token;
        HAClient *probe = [[HAClient alloc] init];
        probe.baseURL = url;
        probe.token = token;
        [probe checkReachableWithCompletion:^(BOOL ok, NSString *msg) {
            [self sendEvent:@{@"t": @"testResult", @"ok": @(ok), @"msg": msg ?: @""}];
        }];
        return;
    }
    if ([action isEqualToString:@"call"]) {
        NSString *domain = body[@"domain"];
        NSString *service = body[@"service"];
        NSDictionary *data = body[@"data"];
        if (domain.length && service.length) {
            [self.client callService:domain service:service data:data ?: @{}];
        }
        return;
    }
    if ([action isEqualToString:@"openURL"]) {
        NSString *path = body[@"path"] ?: @"";
        NSString *base = self.client.baseURL ?: @"";
        while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
        NSURL *u = [NSURL URLWithString:[base stringByAppendingString:path]];
        if (u) [[NSWorkspace sharedWorkspace] openURL:u];
        return;
    }
    if ([action isEqualToString:@"copy"]) {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:body[@"text"] ?: @"" forType:NSPasteboardTypeString];
        [self toast:@"已复制"];
        return;
    }
    if ([action isEqualToString:@"quit"]) {
        [NSApp terminate:nil];
        return;
    }
    if ([action isEqualToString:@"hide"]) {
        [self.popover performClose:nil];
        return;
    }
    if ([action isEqualToString:@"log"]) {
        NSLog(@"[HABar] %@", body[@"msg"]);
        return;
    }
}

- (void)sendEvent:(NSDictionary *)payload {
    if (!payload) return;
    NSData *d = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!d) return;
    NSString *json = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    NSString *js = [NSString stringWithFormat:@"window.hb && window.hb.receive(%@)", JSStringLiteral(json)];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.webView) [self.webView evaluateJavaScript:js completionHandler:nil];
    });
}

- (void)toast:(NSString *)text {
    [self sendEvent:@{@"t": @"toast", @"msg": text ?: @""}];
}

#pragma mark - 开机自启

- (NSString *)launchAgentPath {
    return [@"~/Library/LaunchAgents/cn.local.habar.plist" stringByExpandingTildeInPath];
}

- (BOOL)autostartEnabled {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self launchAgentPath]];
}

- (void)runLaunchctl:(NSArray<NSString *> *)args {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/bin/launchctl";
    t.arguments = args;
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) { NSLog(@"[HABar] launchctl 失败: %@", e); }
}

- (void)setAutostart:(BOOL)on {
    NSString *path = [self launchAgentPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (on) {
        NSString *exe = [[NSBundle mainBundle] executablePath];
        if (!exe) exe = [NSProcessInfo processInfo].arguments.firstObject;
        if (!exe) return;
        [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *xml = [NSString stringWithFormat:
            @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
             "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
             "<plist version=\"1.0\"><dict>"
             "<key>Label</key><string>cn.local.habar</string>"
             "<key>ProgramArguments</key><array><string>%@</string></array>"
             "<key>RunAtLoad</key><true/>"
             "<key>LimitLoadToSessionType</key><string>Aqua</string>"
             "</dict></plist>", exe];
        [xml writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [self runLaunchctl:@[@"unload", @"-w", path]];
        [self runLaunchctl:@[@"load", @"-w", path]];
    } else {
        [self runLaunchctl:@[@"unload", @"-w", path]];
        [fm removeItemAtPath:path error:nil];
    }
    [self pushConfig];
}

- (void)pushConfig {
    [self sendEvent:@{@"t": @"config",
                      @"url": self.client.baseURL ?: @"",
                      @"token": self.client.token ?: @"",
                      @"autostart": @([self autostartEnabled]),
                      @"noise": @(self.filterNoise)}];
}

- (void)pushStatus {
    [self sendEvent:@{@"t": @"status", @"state": self.client.status ?: @"idle", @"msg": self.client.statusMessage ?: @""}];
}

- (void)pushMeta {
    [self sendEvent:@{@"t": @"meta",
                      @"areas": self.client.entityAreas ?: @{},
                      @"areaNames": self.client.areaNames ?: @{}}];
}

- (void)pushPrefs {
    // 即使没有存过也要发（空字典），前端据此判断「确实没存过」才做首次播种
    NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"ui_prefs"] ?: @{};
    [self sendEvent:@{@"t": @"prefs", @"data": prefs}];
}

#pragma mark - HAClientDelegate

- (void)haClientStatusChanged:(HAClient *)client {
    [self pushStatus];
    if ([client.status isEqualToString:@"connected"]) {
        [self pushMeta];
    }
}

- (void)haClient:(HAClient *)client didReceiveStates:(NSArray *)states {
    self.cachedStates = states;
    [self sendEvent:@{@"t": @"states", @"data": states}];
}

#pragma mark - 诊断类实体的推送过滤

- (void)loadNoiseSettings {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    // 未设置过时默认开启
    self.filterNoise = [ud objectForKey:@"filterNoise"] == nil ? YES : [ud boolForKey:@"filterNoise"];
    self.panelIDs = [NSMutableSet set];
    [self syncPanelIDsFromPrefs:[ud dictionaryForKey:@"ui_prefs"]];
}

- (void)syncPanelIDsFromPrefs:(NSDictionary *)prefs {
    if (![prefs isKindOfClass:[NSDictionary class]]) return;
    NSArray *order = prefs[@"order"];
    if (![order isKindOfClass:[NSArray class]]) return;
    NSMutableSet *set = [NSMutableSet setWithCapacity:order.count];
    for (id x in order) {
        if ([x isKindOfClass:[NSString class]]) [set addObject:x];
    }
    self.panelIDs = set;
}

/**
 判断一条 state_changed 是否属于「纯诊断」噪声。
 口径：HA 注册表里 entity_category = diagnostic 的实体（不面向看板，多为诊断/资源类），
 外加两类没有注册表信息也能认出来的：小米 MIoT 的「信息」按钮、update.* 更新实体。
 面板里用户手动添加过的实体永远不过滤。
 */
- (BOOL)isNoiseState:(NSDictionary *)state {
    if (!self.filterNoise) return NO;
    NSString *eid = state[@"entity_id"];
    if (![eid isKindOfClass:[NSString class]] || !eid.length) return NO;
    if ([self.panelIDs containsObject:eid]) return NO;

    // HA 自己就把这类实体标成了 diagnostic（不面向看板），直接采信
    if ([self.client.diagnosticEntities containsObject:eid]) return YES;

    NSRange dot = [eid rangeOfString:@"."];
    if (dot.location == NSNotFound) return NO;
    NSString *dom = [eid substringToIndex:dot.location];
    NSString *obj = [eid substringFromIndex:dot.location + 1];

    if ([dom isEqualToString:@"button"]) {
        // 只认 MIoT 那种带 prop 属性的信息按钮，普通场景按钮照常推送
        NSDictionary *attrs = state[@"attributes"];
        if (![attrs isKindOfClass:[NSDictionary class]]) return NO;
        for (NSString *k in attrs) {
            if ([k isKindOfClass:[NSString class]] && [k hasPrefix:@"button."]) return YES;
        }
        return NO;
    }
    if ([dom isEqualToString:@"update"]) return YES;
    if ([dom isEqualToString:@"sensor"]) {
        for (NSString *suf in @[@"_processor_usage", @"_memory_usage", @"_uptime", @"_storage", @"_swap_usage"]) {
            if ([obj hasSuffix:suf]) return YES;
        }
    }
    return NO;
}

- (void)haClient:(HAClient *)client didUpdateEntity:(NSDictionary *)state {
    NSString *eid = state[@"entity_id"];
    if (!eid) return;
    self.statIn++;
    if ([self isNoiseState:state]) { self.noiseSkipped++; return; }
    if (gStats) NSLog(@"[HABar] PASS %@", eid);
    self.pendingStates[eid] = state;
    // 同步维护本地缓存，重开面板时数据是最新的
    if (self.cachedStates.count) {
        NSMutableArray *arr = [self.cachedStates mutableCopy];
        NSUInteger idx = [arr indexOfObjectPassingTest:^BOOL(id obj, NSUInteger i, BOOL *stop) {
            return [obj[@"entity_id"] isEqualToString:eid];
        }];
        if (idx != NSNotFound) arr[idx] = state; else [arr addObject:state];
        self.cachedStates = arr;
    }
    if (self.flushScheduled) return;
    self.flushScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.flushScheduled = NO;
        NSArray *values = self.pendingStates.allValues;
        self.statOut += values.count;
        [self.pendingStates removeAllObjects];
        if (values.count == 1) {
            [self sendEvent:@{@"t": @"entity", @"data": values.firstObject}];
        } else if (values.count > 1) {
            [self sendEvent:@{@"t": @"entities", @"data": values}];
        }
    });
}

- (void)haClient:(HAClient *)client didLoadMeta:(NSDictionary *)entityAreas areaNames:(NSDictionary *)areaNames {
    [self sendEvent:@{@"t": @"meta", @"areas": entityAreas ?: @{}, @"areaNames": areaNames ?: @{}}];
}

- (void)haClient:(HAClient *)client didLog:(NSString *)line {
    NSLog(@"[HABar] %@", line);
    [self toast:line ?: @"操作失败"];
}

#pragma mark - status item

/** 面板尺寸：默认 1020x760（两列布局），屏幕放不下时自动收敛 */
- (NSSize)desiredContentSize {
    NSScreen *screen = [NSScreen mainScreen];
    if (!screen) screen = [NSScreen screens].firstObject;
    CGFloat w = kPanelW, h = kPanelH;
    if (screen) {
        NSRect vis = screen.visibleFrame;
        w = MIN(w, MAX(560, vis.size.width - 24));
        h = MIN(h, MAX(420, vis.size.height - 12));
    }
    return NSMakeSize(w, h);
}

- (void)buildStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *button = self.statusItem.button;
    NSImage *img = [NSImage imageWithSystemSymbolName:@"house.fill" accessibilityDescription:@"HA"];
    img.template = YES;
    button.image = img;
    button.imagePosition = NSImageOnly;
    button.toolTip = @"HA 面板";
    button.target = self;
    button.action = @selector(statusItemClicked:);
    [button sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];

    NSSize sz = [self desiredContentSize];
    NSViewController *vc = [[NSViewController alloc] init];
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, sz.width, sz.height)];
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.webView.frame = container.bounds;
    [container addSubview:self.webView];
    vc.view = container;

    self.popover = [[NSPopover alloc] init];
    self.popover.contentViewController = vc;
    self.popover.contentSize = sz;
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.animates = YES;
}

- (void)statusItemClicked:(id)sender {
    NSEvent *event = [NSApp currentEvent];
    if (event.type == NSEventTypeRightMouseUp || (event.modifierFlags & NSEventModifierFlagControl)) {
        [self showContextMenu];
        return;
    }
    if (self.popover.isShown) {
        [self.popover performClose:nil];
    } else {
        [self showPopover];
    }
}

- (void)showPopover {
    NSStatusBarButton *button = self.statusItem.button;
    if (!button) return;
    NSSize size = [self desiredContentSize];
    self.popover.contentSize = size;
    self.webView.frame = NSMakeRect(0, 0, size.width, size.height);
    [NSApp activateIgnoringOtherApps:YES];
    [self.popover showRelativeToRect:button.bounds ofView:button preferredEdge:NSRectEdgeMinY];
    if (gShowPopover) {
        NSString *dbg = [NSString stringWithFormat:@"shown=%d winNum=%ld buttonWindow=%@ screen=%@ popoverWindow=%@\n",
                         self.popover.isShown,
                         (long)self.popover.contentViewController.view.window.windowNumber,
                         NSStringFromRect(button.window.frame),
                         NSStringFromRect([NSScreen mainScreen].frame),
                         self.popover.isShown ? NSStringFromRect(self.popover.contentViewController.view.window.frame) : @"nil"];
        [dbg writeToFile:@"/tmp/habar-debug.log" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    [self.webView.window makeFirstResponder:self.webView];
    [self sendEvent:@{@"t": @"shown"}];
}

- (void)showContextMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:@"刷新设备状态" action:@selector(menuRefresh) keyEquivalent:@"r"].target = self;
    [menu addItemWithTitle:@"重新连接" action:@selector(menuReconnect) keyEquivalent:@""].target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"退出" action:@selector(terminate) keyEquivalent:@"q"].target = self;
    NSStatusBarButton *button = self.statusItem.button;
    if (button) {
        [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, button.bounds.size.height + 4) inView:button];
    }
}

- (void)menuRefresh {
    [self.client fetchStatesWithCompletion:nil];
}

- (void)menuReconnect {
    [self.client restart];
}

- (void)terminate {
    [NSApp terminate:nil];
}

#pragma mark - snapshot / selftest

- (void)runSelfTest {
    self.client.baseURL = gHTMLPath ?: self.client.baseURL;
    __weak typeof(self) weakSelf = self;
    [self.client start];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AppDelegate *s = weakSelf;
        printf("status=%s msg=%s\n", s.client.status.UTF8String, s.client.statusMessage.UTF8String);
        printf("areas=%lu\n", (unsigned long)s.client.areaNames.count);
        printf("entityAreas=%lu\n", (unsigned long)s.client.entityAreas.count);
        NSArray *sample = s.client.areaNames.allValues;
        for (NSUInteger i = 0; i < MIN(sample.count, 12); i++) printf("  area: %s\n", [sample[i] description].UTF8String);
        [s.client callService:@"light" service:@"toggle" data:@{@"entity_id": @"light.lemesh_wy02_cc83_light"}];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSDictionary *e = nil;
            for (NSDictionary *s2 in s.cachedStates) if ([s2[@"entity_id"] isEqualToString:@"light.lemesh_wy02_cc83_light"]) e = s2;
            printf("toggle -> %s\n", [e[@"state"] description].UTF8String);
            [s.client callService:@"light" service:@"toggle" data:@{@"entity_id": @"light.lemesh_wy02_cc83_light"}];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                printf("restored\n");
                exit(0);
            });
        });
    });
}

- (void)runSnapshot {
    NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 200, gShotW, gShotH)
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    win.backgroundColor = [NSColor clearColor];
    win.opaque = NO;
    self.webView.frame = NSMakeRect(0, 0, gShotW, gShotH);
    win.contentView = self.webView;
    [win setLevel:NSFloatingWindowLevel];
    [win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.client start];

    if (gEvalJS.length) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((gSnapshotDelay - 1.2) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.webView evaluateJavaScript:gEvalJS completionHandler:nil];
        });
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gSnapshotDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WKSnapshotConfiguration *cfg = [[WKSnapshotConfiguration alloc] init];
        cfg.rect = NSMakeRect(0, 0, gShotW, gShotH);
        [self.webView takeSnapshotWithConfiguration:cfg completionHandler:^(NSImage *image, NSError *error) {
            if (!image) {
                printf("snapshot failed: %s\n", error.localizedDescription.UTF8String);
                exit(1);
            }
            NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
            NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            [png writeToFile:gSnapshotPath atomically:YES];
            printf("snapshot saved: %s (%lu bytes)\n", gSnapshotPath.UTF8String, (unsigned long)png.length);
            exit(0);
        }];
    });
}

@end

int main(int argc, const char *argv[]) {
    for (int i = 1; i < argc; i++) {
        NSString *arg = [NSString stringWithUTF8String:argv[i]];
        if ([arg isEqualToString:@"--snapshot"] && i + 1 < argc) {
            gSnapshotPath = [NSString stringWithUTF8String:argv[++i]];
        } else if ([arg isEqualToString:@"--html"] && i + 1 < argc) {
            gHTMLPath = [NSString stringWithUTF8String:argv[++i]];
        } else if ([arg isEqualToString:@"--delay"] && i + 1 < argc) {
            gSnapshotDelay = atof(argv[++i]);
        } else if ([arg isEqualToString:@"--js"] && i + 1 < argc) {
            gEvalJS = [NSString stringWithUTF8String:argv[++i]];
        } else if ([arg isEqualToString:@"--stats"]) {
            gStats = YES;
        } else if ([arg isEqualToString:@"--show"]) {
            gShowPopover = YES;
        } else if ([arg isEqualToString:@"--size"] && i + 1 < argc) {
            NSString *sz = [NSString stringWithUTF8String:argv[++i]];
            NSArray *parts = [sz componentsSeparatedByString:@"x"];
            if (parts.count == 2) { gShotW = [(NSString *)parts[0] doubleValue]; gShotH = [(NSString *)parts[1] doubleValue]; }
        } else if ([arg isEqualToString:@"--selftest"]) {
            gSelfTest = YES;
        }
    }

    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
