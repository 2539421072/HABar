#import "MQTTPublisher.h"

#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

static const NSTimeInterval kRetryMin = 2.0;
static const NSTimeInterval kRetryMax = 20.0;
static const NSTimeInterval kPingInterval = 25.0;

@implementation MQTTPublisher {
    int _sock;
    BOOL _connected;
    BOOL _running;
    dispatch_queue_t _q;
    dispatch_source_t _timer;
    NSMutableArray<NSDictionary *> *_outbox;
    NSTimeInterval _nextRetry;
    NSTimeInterval _lastPing;
    NSTimeInterval _backoff;
}

- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port {
    if ((self = [super init])) {
        _host = [host copy];
        _port = port ?: 1883;
        _keepAlive = 60;
        NSString *uuid = [NSUUID UUID].UUIDString;
        NSString *shortId = [[uuid substringToIndex:8] lowercaseString];
        _clientId = [NSString stringWithFormat:@"habar-%@", shortId];
        _sock = -1;
        _outbox = [NSMutableArray array];
        _q = dispatch_queue_create("cn.local.habar.mqtt", DISPATCH_QUEUE_SERIAL);
        _backoff = kRetryMin;
    }
    return self;
}

- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
    if (_sock >= 0) close(_sock);
}

#pragma mark - 对外

- (void)start {
    dispatch_async(_q, ^{
        if (self->_running) return;
        self->_running = YES;
        self->_nextRetry = 0;
        [self startTimerLocked];
    });
}

- (void)stop {
    dispatch_sync(_q, ^{
        self->_running = NO;
        if (self->_timer) { dispatch_source_cancel(self->_timer); self->_timer = nil; }
        [self sendBytes:[self disconnectPacket] thenClose:YES];
        [self setStatus:MQTTLinkStatusIdle detail:@"已断开"];
    });
}

- (void)forceReconnect {
    dispatch_async(_q, ^{
        [self closeSocketLocked];
        self->_nextRetry = 0;
        self->_backoff = kRetryMin;
        [self connectLocked];
    });
}

- (BOOL)isConnected {
    __block BOOL c = NO;
    dispatch_sync(_q, ^{ c = self->_connected; });
    return c;
}

- (void)publish:(NSString *)topic payload:(NSString *)payload retain:(BOOL)retain {
    if (!topic.length) return;
    NSDictionary *item = @{@"t": topic, @"p": payload ?: @"", @"r": @(retain)};
    dispatch_async(_q, ^{
        if (self->_connected && [self flushItemLocked:item]) return;
        if (self->_outbox.count < 64) [self->_outbox addObject:item];
    });
}

- (void)publishNow:(NSString *)topic payload:(NSString *)payload retain:(BOOL)retain {
    if (!topic.length) return;
    NSDictionary *item = @{@"t": topic, @"p": payload ?: @"", @"r": @(retain)};
    dispatch_sync(_q, ^{
        if (self->_connected && [self flushItemLocked:item]) return;
        if (self->_outbox.count < 64) [self->_outbox addObject:item];
    });
}

#pragma mark - 连接

- (void)startTimerLocked {
    if (_timer) return;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), 1 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tickLocked]; });
    dispatch_resume(_timer);
}

- (void)tickLocked {
    if (!_running) return;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;

    if (!_connected) {
        if (now >= _nextRetry) [self connectLocked];
        return;
    }

    [self pumpLocked];
    if (!_connected) return;

    if (now - _lastPing >= kPingInterval) {
        _lastPing = now;
        uint8_t ping[2] = {0xC0, 0x00};
        if (![self sendRaw:ping len:2]) [self dropLocked:@"链路已断"];
    }
}

- (void)connectLocked {
    if (!_running) return;
    [self closeSocketLocked];

    if (!self.host.length) {
        [self setStatus:MQTTLinkStatusFailed detail:@"未填写 MQTT 服务器"];
        [self scheduleRetryLocked];
        return;
    }

    [self setStatus:MQTTLinkStatusConnecting detail:self.host];

    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char portstr[8];
    snprintf(portstr, sizeof portstr, "%u", (unsigned)self.port);

    if (getaddrinfo(self.host.UTF8String, portstr, &hints, &res) != 0 || !res) {
        [self setStatus:MQTTLinkStatusFailed detail:@"域名解析失败"];
        [self scheduleRetryLocked];
        return;
    }

    int fd = -1;
    int lasterr = 0;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) { lasterr = errno; continue; }

        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);

        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);

        int rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (rc == 0) break;

        if (errno == EINPROGRESS) {
            fd_set wfds;
            FD_ZERO(&wfds);
            FD_SET(fd, &wfds);
            struct timeval tv = {4, 0};
            if (select(fd + 1, NULL, &wfds, NULL, &tv) > 0) {
                int soerr = 0;
                socklen_t slen = sizeof soerr;
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &slen);
                if (soerr == 0) break;
                lasterr = soerr;
            } else {
                lasterr = ETIMEDOUT;
            }
        } else {
            lasterr = errno;
        }
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);

    if (fd < 0) {
        [self setStatus:MQTTLinkStatusFailed detail:[NSString stringWithFormat:@"连接失败 (%d)", lasterr]];
        [self scheduleRetryLocked];
        return;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
    struct timeval snd = {2, 0};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &snd, sizeof snd);

    _sock = fd;

    NSMutableData *pkt = [self connectPacket];
    if (![self sendBytes:pkt thenClose:NO]) {
        [self setStatus:MQTTLinkStatusFailed detail:@"发送 CONNECT 失败"];
        [self closeSocketLocked];
        [self scheduleRetryLocked];
        return;
    }

    // 等 CONNACK：0x20 0x02 <session> <rc>
    uint8_t buf[8];
    struct timeval rcv = {4, 0};
    setsockopt(_sock, SOL_SOCKET, SO_RCVTIMEO, &rcv, sizeof rcv);
    ssize_t n = recv(_sock, buf, sizeof buf, 0);
    struct timeval norcv = {0, 0};
    setsockopt(_sock, SOL_SOCKET, SO_RCVTIMEO, &norcv, sizeof norcv);

    if (n < 4 || buf[0] != 0x20) {
        [self setStatus:MQTTLinkStatusFailed detail:@"MQTT 握手无响应"];
        [self closeSocketLocked];
        [self scheduleRetryLocked];
        return;
    }
    if (buf[3] != 0x00) {
        NSString *why = buf[3] == 4 ? @"用户名或密码错误" : (buf[3] == 5 ? @"未被授权" : [NSString stringWithFormat:@"拒绝连接 (%d)", buf[3]]);
        [self setStatus:MQTTLinkStatusFailed detail:why];
        [self closeSocketLocked];
        [self scheduleRetryLocked];
        return;
    }

    _connected = YES;
    _backoff = kRetryMin;
    _lastPing = [NSDate date].timeIntervalSince1970;
    [self setStatus:MQTTLinkStatusConnected detail:@""];

    NSArray *pending = [_outbox copy];
    [_outbox removeAllObjects];
    for (NSDictionary *item in pending) {
        if (!_connected) break;
        [self flushItemLocked:item];
    }
}

- (void)scheduleRetryLocked {
    _nextRetry = [NSDate date].timeIntervalSince1970 + _backoff;
    _backoff = MIN(_backoff * 2, kRetryMax);
}

- (void)closeSocketLocked {
    _connected = NO;
    if (_sock >= 0) { close(_sock); _sock = -1; }
}

- (void)dropLocked:(NSString *)reason {
    [self closeSocketLocked];
    [self setStatus:MQTTLinkStatusFailed detail:reason ?: @"断开"];
    [self scheduleRetryLocked];
}

- (void)pumpLocked {
    if (_sock < 0) return;
    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(_sock, &rfds);
    struct timeval tv = {0, 0};
    if (select(_sock + 1, &rfds, NULL, NULL, &tv) <= 0) return;

    uint8_t buf[512];
    ssize_t n = recv(_sock, buf, sizeof buf, 0);
    if (n <= 0) { [self dropLocked:@"MQTT 连接已断开"]; return; }
    // 只有 PINGRESP 之类的下行，无需处理
}

#pragma mark - 报文

- (BOOL)flushItemLocked:(NSDictionary *)item {
    NSMutableData *body = [NSMutableData data];
    [self appendString:item[@"t"] to:body];
    NSData *payload = [item[@"p"] dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    [body appendData:payload];

    NSMutableData *pkt = [NSMutableData data];
    uint8_t h = 0x30 | ([item[@"r"] boolValue] ? 0x01 : 0x00);
    [pkt appendBytes:&h length:1];
    [self appendRemainingLength:body.length to:pkt];
    [pkt appendData:body];

    if (![self sendBytes:pkt thenClose:NO]) {
        [self dropLocked:@"发送失败"];
        return NO;
    }
    return YES;
}

- (NSMutableData *)connectPacket {
    NSMutableData *body = [NSMutableData data];
    [self appendString:@"MQTT" to:body];

    uint8_t level = 4;
    [body appendBytes:&level length:1];

    uint8_t flags = 0x02; // clean session
    BOOL hasUser = self.username.length > 0;
    BOOL hasPass = self.password.length > 0;
    if (hasUser) flags |= 0x80;
    if (hasPass) flags |= 0x40;
    [body appendBytes:&flags length:1];

    uint8_t ka[2] = {(uint8_t)(self.keepAlive >> 8), (uint8_t)(self.keepAlive & 0xFF)};
    [body appendBytes:ka length:2];

    [self appendString:self.clientId to:body];
    if (hasUser) [self appendString:self.username to:body];
    if (hasPass) [self appendString:self.password to:body];

    NSMutableData *pkt = [NSMutableData data];
    uint8_t h = 0x10;
    [pkt appendBytes:&h length:1];
    [self appendRemainingLength:body.length to:pkt];
    [pkt appendData:body];
    return pkt;
}

- (NSMutableData *)disconnectPacket {
    NSMutableData *pkt = [NSMutableData data];
    uint8_t b[2] = {0xE0, 0x00};
    [pkt appendBytes:b length:2];
    return pkt;
}

- (void)appendString:(NSString *)s to:(NSMutableData *)d {
    NSData *u = [s dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    uint8_t len[2] = {(uint8_t)(u.length >> 8), (uint8_t)(u.length & 0xFF)};
    [d appendBytes:len length:2];
    [d appendData:u];
}

- (void)appendRemainingLength:(NSUInteger)len to:(NSMutableData *)d {
    do {
        uint8_t b = len % 128;
        len /= 128;
        if (len > 0) b |= 0x80;
        [d appendBytes:&b length:1];
    } while (len > 0);
}

- (BOOL)sendBytes:(NSData *)data thenClose:(BOOL)closeAfter {
    if (_sock < 0) return NO;
    const uint8_t *p = data.bytes;
    NSUInteger left = data.length;
    while (left > 0) {
        ssize_t n = send(_sock, p, left, 0);
        if (n <= 0) return NO;
        p += n;
        left -= (NSUInteger)n;
    }
    if (closeAfter) [self closeSocketLocked];
    return YES;
}

- (BOOL)sendRaw:(const uint8_t *)bytes len:(NSUInteger)len {
    if (_sock < 0) return NO;
    NSUInteger left = len;
    while (left > 0) {
        ssize_t n = send(_sock, bytes, left, 0);
        if (n <= 0) return NO;
        bytes += n;
        left -= (NSUInteger)n;
    }
    return YES;
}

#pragma mark - 状态回调

- (void)setStatus:(MQTTLinkStatus)status detail:(NSString *)detail {
    void (^cb)(MQTTLinkStatus, NSString *) = self.onStatus;
    if (!cb) return;
    dispatch_async(dispatch_get_main_queue(), ^{ cb(status, detail ?: @""); });
}

@end
