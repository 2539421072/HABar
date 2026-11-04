#import "PowerReporter.h"
#import "MQTTPublisher.h"
#import <AppKit/AppKit.h>

#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>

static NSString *const kPrefix = @"homeassistant";

@implementation PowerReporter {
    MQTTPublisher *_mqtt;
    NSString *_slug;
    NSString *_deviceName;
    NSString *_state;              // on / sleep / off
    NSDate *_bootTime;
    NSDate *_lastChange;
    NSDate *_lastOff;
    NSString *_lastEvent;          // booted / slept / woke / shutdown / started
    BOOL _enabled;
    BOOL _poweringOff;
    BOOL _started;
    NSTimer *_heartbeat;
}

+ (NSString *)slugify:(NSString *)name {
    if (!name.length) return @"mac";
    NSMutableString *out = [NSMutableString string];
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if ([ok characterIsMember:c]) [out appendFormat:@"%C", c];
        else if (out.length && ![out hasSuffix:@"_"]) [out appendString:@"_"];
    }
    NSString *s = [out stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"_"]];
    s = [s lowercaseString];
    if (!s.length) s = @"mac";
    if (s.length > 40) s = [s substringToIndex:40];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"_"]];
    return s.length ? s : @"mac";
}

- (instancetype)initWithConfig:(NSDictionary *)cfg {
    if ((self = [super init])) {
        _state = @"on";
        _lastEvent = @"started";
        _lastChange = [NSDate date];
        _bootTime = [self systemBootTime];
        [self applyConfig:cfg];
    }
    return self;
}

- (void)applyConfig:(NSDictionary *)cfg {
    if (![cfg isKindOfClass:[NSDictionary class]]) cfg = @{};

    _enabled = [cfg[@"enabled"] boolValue];

    NSString *host = cfg[@"host"];
    NSNumber *port = cfg[@"port"];
    _deviceName = [cfg[@"device"] length] ? cfg[@"device"] : [[NSProcessInfo processInfo] hostName];
    if ([_deviceName hasSuffix:@".local"]) _deviceName = [_deviceName stringByDeletingPathExtension];
    _slug = [PowerReporter slugify:_deviceName];

    [_mqtt stop];
    _mqtt = nil;
    if (!_enabled || !host.length) return;

    _mqtt = [[MQTTPublisher alloc] initWithHost:host port:(uint16_t)(port ? port.unsignedShortValue : 1883)];
    _mqtt.username = cfg[@"user"];
    _mqtt.password = cfg[@"pass"];
    __weak typeof(self) weakSelf = self;
    _mqtt.onStatus = ^(MQTTLinkStatus status, NSString *detail) {
        [weakSelf handleMQTTStatus:status detail:detail];
    };
}

- (void)start {
    if (_started) return;
    _started = YES;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(willSleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [nc addObserver:self selector:@selector(didWake:) name:NSWorkspaceDidWakeNotification object:nil];
    [nc addObserver:self selector:@selector(willPowerOff:) name:NSWorkspaceWillPowerOffNotification object:nil];
    [nc addObserver:self selector:@selector(screensDidSleep:) name:NSWorkspaceScreensDidSleepNotification object:nil];

    if (!_enabled || !_mqtt) {
        [self reportStatus:@"未启用" connected:NO];
        return;
    }

    _lastEvent = @"booted";
    _lastChange = [NSDate date];
    [_mqtt start];

    _heartbeat = [NSTimer scheduledTimerWithTimeInterval:300 repeats:YES block:^(NSTimer *t) {
        [self publishState];
    }];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_heartbeat invalidate];
}

#pragma mark - 系统事件

- (void)willSleep:(NSNotification *)n {
    [self setState:@"sleep" event:@"slept" sync:YES];
}

- (void)didWake:(NSNotification *)n {
    // 睡眠后 socket 基本是死的，先重连；连上会自动重发一次状态
    [_mqtt forceReconnect];
    [self setState:@"on" event:@"woke" sync:YES];
}

- (void)willPowerOff:(NSNotification *)n {
    _poweringOff = YES;
    [self setState:@"off" event:@"shutdown" sync:YES];
    _lastOff = [NSDate date];
}

// 显示器睡眠不等于整机睡眠，单独记录，状态仍然是 on
- (void)screensDidSleep:(NSNotification *)n {
    if (![_state isEqualToString:@"on"]) return;
    [self publishState];
}

#pragma mark - 状态

- (void)setState:(NSString *)state event:(NSString *)event sync:(BOOL)sync {
    BOOL changed = ![_state isEqualToString:state];
    _state = state;
    _lastEvent = event;
    _lastChange = [NSDate date];
    if (changed) {
        void (^cb)(NSString *) = self.onStateChange;
        if (cb) cb(state);
    }
    if (sync) {
        [self publishNow];
        // 给 broker 一点时间收包：睡眠/关机之后就没机会了
        usleep(200 * 1000);
    } else {
        [self publishState];
    }
}

- (void)publishState {
    if (!_enabled || !_mqtt) return;
    [_mqtt publish:[self stateTopic] payload:_state retain:YES];
    [_mqtt publish:[self attrTopic] payload:[self attributesJSON] retain:YES];
}

- (void)publishNow {
    if (!_enabled || !_mqtt) return;
    [_mqtt publishNow:[self stateTopic] payload:_state retain:YES];
    [_mqtt publishNow:[self attrTopic] payload:[self attributesJSON] retain:YES];
}

- (NSString *)stateTopic { return [NSString stringWithFormat:@"%@/sensor/%@/power_state/state", kPrefix, _slug]; }
- (NSString *)attrTopic  { return [NSString stringWithFormat:@"%@/sensor/%@/power_state/attr", kPrefix, _slug]; }
- (NSString *)bootTopic  { return [NSString stringWithFormat:@"%@/sensor/%@/last_boot/state", kPrefix, _slug]; }
- (NSString *)availTopic { return [NSString stringWithFormat:@"%@/sensor/%@/availability", kPrefix, _slug]; }

- (NSString *)isoString:(NSDate *)date {
    if (!date) return @"";
    NSISO8601DateFormatter *f = [[NSISO8601DateFormatter alloc] init];
    f.timeZone = [NSTimeZone localTimeZone];
    return [f stringFromDate:date];
}

- (NSString *)attributesJSON {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"last_event"] = _lastEvent ?: @"";
    d[@"last_state_change"] = [self isoString:_lastChange];
    d[@"boot_time"] = [self isoString:_bootTime];
    long up = (long)[[NSDate date] timeIntervalSinceDate:_bootTime];
    if (up < 0) up = 0;
    d[@"uptime_seconds"] = @(up);
    d[@"device_name"] = _deviceName ?: @"";
    if (_lastOff) d[@"last_shutdown"] = [self isoString:_lastOff];
    NSData *data = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

- (NSDate *)systemBootTime {
    struct timeval tv;
    size_t len = sizeof tv;
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &tv, &len, NULL, 0) == 0 && tv.tv_sec > 0) {
        return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)tv.tv_sec];
    }
    return [NSDate dateWithTimeIntervalSinceNow:-[NSProcessInfo processInfo].systemUptime];
}

#pragma mark - MQTT

- (void)handleMQTTStatus:(MQTTLinkStatus)status detail:(NSString *)detail {
    switch (status) {
        case MQTTLinkStatusConnected:
            [self reportStatus:@"已连接" connected:YES];
            [self publishDiscovery];
            [_mqtt publish:[self availTopic] payload:@"online" retain:YES];
            [self publishState];
            break;
        case MQTTLinkStatusConnecting:
            [self reportStatus:@"连接中…" connected:NO];
            break;
        case MQTTLinkStatusFailed:
            [self reportStatus:detail.length ? detail : @"连接失败" connected:NO];
            break;
        default:
            [self reportStatus:@"未连接" connected:NO];
            break;
    }
}

- (void)reportStatus:(NSString *)text connected:(BOOL)connected {
    void (^cb)(NSString *, BOOL) = self.onStatus;
    if (!cb) return;
    dispatch_async(dispatch_get_main_queue(), ^{ cb(text, connected); });
}

- (void)publishDiscovery {
    NSDictionary *device = @{
        @"identifiers": @[[NSString stringWithFormat:@"habar_%@", _slug]],
        @"name": _deviceName ?: @"Mac",
        @"manufacturer": @"HABar",
        @"model": @"macOS Menu Bar Panel"
    };

    NSDictionary *power = @{
        @"name": @"开关机 / 睡眠状态",
        @"unique_id": [NSString stringWithFormat:@"%@_power_state", _slug],
        @"object_id": [NSString stringWithFormat:@"%@_power_state", _slug],
        @"default_entity_id": [NSString stringWithFormat:@"sensor.%@_power_state", _slug],
        @"state_topic": [self stateTopic],
        @"availability_topic": [self availTopic],
        @"payload_available": @"online",
        @"payload_not_available": @"offline",
        @"json_attributes_topic": [self attrTopic],
        @"device_class": @"enum",
        @"options": @[@"on", @"sleep", @"off"],
        @"icon": @"mdi:power",
        @"device": device
    };

    NSDictionary *boot = @{
        @"name": @"上次开机时间",
        @"unique_id": [NSString stringWithFormat:@"%@_last_boot", _slug],
        @"object_id": [NSString stringWithFormat:@"%@_last_boot", _slug],
        @"default_entity_id": [NSString stringWithFormat:@"sensor.%@_last_boot", _slug],
        @"state_topic": [self bootTopic],
        @"availability_topic": [self availTopic],
        @"payload_available": @"online",
        @"payload_not_available": @"offline",
        @"device_class": @"timestamp",
        @"icon": @"mdi:clock-start",
        @"device": device
    };

    NSString *pTopic = [NSString stringWithFormat:@"%@/sensor/%@/power_state/config", kPrefix, _slug];
    NSString *bTopic = [NSString stringWithFormat:@"%@/sensor/%@/last_boot/config", kPrefix, _slug];
    [_mqtt publish:pTopic payload:[self json:power] retain:YES];
    [_mqtt publish:bTopic payload:[self json:boot] retain:YES];
    [_mqtt publish:[self bootTopic] payload:[self isoString:_bootTime] retain:YES];
}

- (NSString *)json:(NSDictionary *)d {
    NSData *data = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}

- (void)stopSilently {
    [_heartbeat invalidate];
    _heartbeat = nil;
    [_mqtt stop];
    _started = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)stopForQuit {
    [_heartbeat invalidate];
    _heartbeat = nil;
    if (_poweringOff) {
        // 关机流程：状态已经发了 off，直接断开，别把可用性打成 offline
        [_mqtt stop];
        return;
    }
    if (_mqtt && _enabled) {
        [_mqtt publishNow:[self availTopic] payload:@"offline" retain:YES];
        usleep(120 * 1000);
    }
    [_mqtt stop];
}

@end
