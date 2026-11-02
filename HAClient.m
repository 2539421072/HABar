#import "HAClient.h"

@interface HAClient () <NSURLSessionWebSocketDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionWebSocketTask *ws;
@property (nonatomic, strong) NSTimer *pingTimer;
@property (nonatomic, strong) NSTimer *reconnectTimer;
@property (nonatomic, assign) BOOL stopping;
@property (nonatomic, assign) BOOL authed;
@property (nonatomic, assign) NSInteger seq;
@property (nonatomic, readwrite) NSString *status;
@property (nonatomic, readwrite) NSString *statusMessage;
@property (nonatomic, readwrite) NSDictionary *areaNames;
@property (nonatomic, readwrite) NSDictionary *entityAreas;
@property (nonatomic, strong) NSMutableDictionary *areaById;      // id -> name
@property (nonatomic, strong) NSMutableDictionary *entityAreaId;  // entity_id -> area_id
@property (nonatomic, strong) NSMutableDictionary *deviceAreaId;  // device_id -> area_id
@property (nonatomic, strong) NSMutableDictionary *entityDevice;  // entity_id -> device_id
@property (nonatomic, strong) NSMutableArray *rawEntities;        // registry entries
@property (nonatomic, strong) NSMutableSet *diagSet;                // entity_category = diagnostic
@end

@implementation HAClient

- (instancetype)init {
    if ((self = [super init])) {
        _status = @"idle";
        _statusMessage = @"未连接";
        _areaById = [NSMutableDictionary dictionary];
        _entityAreaId = [NSMutableDictionary dictionary];
        _deviceAreaId = [NSMutableDictionary dictionary];
        _entityDevice = [NSMutableDictionary dictionary];
        _diagSet = [NSMutableSet set];
        _areaNames = @{};
        _entityAreas = @{};
        _seq = 10;
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 12;
        cfg.waitsForConnectivity = NO;
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:nil delegateQueue:nil];
    }
    return self;
}

#pragma mark - helpers

- (NSString *)trimmedBase {
    NSString *b = [self.baseURL stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([b hasSuffix:@"/"]) b = [b substringToIndex:b.length - 1];
    if (b.length && ![b hasPrefix:@"http://"] && ![b hasPrefix:@"https://"]) b = [@"http://" stringByAppendingString:b];
    return b;
}

- (NSURL *)wsURL {
    NSString *b = [self trimmedBase];
    if ([b hasPrefix:@"https://"]) b = [@"wss://" stringByAppendingString:[b substringFromIndex:8]];
    else if ([b hasPrefix:@"http://"]) b = [@"ws://" stringByAppendingString:[b substringFromIndex:7]];
    return [NSURL URLWithString:[b stringByAppendingString:@"/api/websocket"]];
}

- (void)setStatus:(NSString *)status message:(NSString *)message {
    self.status = status;
    self.statusMessage = message ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate haClientStatusChanged:self];
    });
}

#pragma mark - lifecycle

- (void)start {
    self.stopping = NO;
    [self.reconnectTimer invalidate];
    self.reconnectTimer = nil;
    [self.ws cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    self.ws = nil;
    self.authed = NO;

    if ([self trimmedBase].length == 0 || self.token.length == 0) {
        [self setStatus:@"idle" message:@"请填写地址与令牌"];
        return;
    }
    [self setStatus:@"connecting" message:@"正在连接…"];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *s = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    self.session = s;
    self.ws = [s webSocketTaskWithURL:[self wsURL]];
    self.ws.maximumMessageSize = 32 * 1024 * 1024;
    [self.ws resume];
    [self receiveNext];

    self.pingTimer = [NSTimer scheduledTimerWithTimeInterval:25 target:self selector:@selector(sendPing) userInfo:nil repeats:YES];
}

- (void)stop {
    self.stopping = YES;
    [self.pingTimer invalidate];
    self.pingTimer = nil;
    [self.reconnectTimer invalidate];
    self.reconnectTimer = nil;
    [self.ws cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    self.ws = nil;
    self.authed = NO;
    [self setStatus:@"idle" message:@"已断开"];
}

- (void)restart {
    [self stop];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self start];
    });
}

- (void)sendPing {
    [self.ws sendPingWithPongReceiveHandler:^(NSError *error) {
        if (error) [self handleDisconnect:error];
    }];
}

- (void)handleDisconnect:(NSError *)error {
    if (self.stopping) return;
    self.authed = NO;
    [self.pingTimer invalidate];
    self.pingTimer = nil;
    NSString *msg = error.localizedDescription ?: @"连接中断";
    [self setStatus:@"error" message:msg];
    [self.reconnectTimer invalidate];
    self.reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(reconnectTick) userInfo:nil repeats:NO];
}

- (void)reconnectTick {
    if (self.stopping) return;
    [self start];
}

#pragma mark - websocket

- (void)receiveNext {
    __weak typeof(self) weakSelf = self;
    NSURLSessionWebSocketTask *task = self.ws;
    if (!task) return;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error) {
            [self handleDisconnect:error];
            return;
        }
        if (message.type == NSURLSessionWebSocketMessageTypeString && message.string) {
            [self handleRawMessage:message.string];
        } else if (message.type == NSURLSessionWebSocketMessageTypeData && message.data) {
            NSString *str = [[NSString alloc] initWithData:message.data encoding:NSUTF8StringEncoding];
            if (str) [self handleRawMessage:str];
        }
        [self receiveNext];
    }];
}

- (void)handleRawMessage:(NSString *)text {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *msg = obj;
    NSString *type = msg[@"type"];

    if ([type isEqualToString:@"auth_required"]) {
        [self sendJSON:@{@"type": @"auth", @"access_token": self.token ?: @""}];
        return;
    }
    if ([type isEqualToString:@"auth_ok"]) {
        self.authed = YES;
        [self setStatus:@"connected" message:@"已连接"];
        [self subscribeAll];
        return;
    }
    if ([type isEqualToString:@"auth_invalid"]) {
        self.stopping = YES;
        [self setStatus:@"error" message:msg[@"message"] ?: @"令牌无效"];
        return;
    }
    if ([type isEqualToString:@"event"]) {
        NSDictionary *event = msg[@"event"];
        if ([event[@"event_type"] isEqualToString:@"state_changed"]) {
            NSDictionary *newState = event[@"data"][@"new_state"];
            if ([newState isKindOfClass:[NSDictionary class]] && newState[@"entity_id"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate haClient:self didUpdateEntity:newState];
                });
            }
        }
        return;
    }
    if ([type isEqualToString:@"result"]) {
        NSNumber *ident = msg[@"id"];
        id result = msg[@"result"];
        if ([msg[@"success"] boolValue] == NO) return;
        if (![result isKindOfClass:[NSArray class]]) return;
        if ([ident integerValue] == 21) [self ingestAreas:result];
        else if ([ident integerValue] == 22) [self ingestDevices:result];
        else if ([ident integerValue] == 23) [self ingestEntities:result];
        return;
    }
}

- (void)sendJSON:(NSDictionary *)dict {
    NSData *d = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (!d) return;
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    [self.ws sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:s] completionHandler:^(NSError *error) {
        if (error) [self handleDisconnect:error];
    }];
}

- (void)subscribeAll {
    self.seq = 10;
    [self sendJSON:@{@"id": @(1), @"type": @"subscribe_events", @"event_type": @"state_changed"}];
    [self sendJSON:@{@"id": @(21), @"type": @"config/area_registry/list"}];
    [self sendJSON:@{@"id": @(22), @"type": @"config/device_registry/list"}];
    [self sendJSON:@{@"id": @(23), @"type": @"config/entity_registry/list"}];
    [self fetchStatesWithCompletion:nil];
}

#pragma mark - registry ingest

- (void)ingestAreas:(NSArray *)list {
    [self.areaById removeAllObjects];
    for (NSDictionary *a in list) {
        if (![a isKindOfClass:[NSDictionary class]]) continue;
        NSString *aid = a[@"area_id"];
        NSString *name = a[@"name"];
        if (aid && name) self.areaById[aid] = name;
    }
    [self rebuildMeta];
}

- (void)ingestDevices:(NSArray *)list {
    [self.deviceAreaId removeAllObjects];
    for (NSDictionary *d in list) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSString *did = d[@"id"];
        NSString *aid = d[@"area_id"];
        if (did && [aid isKindOfClass:[NSString class]] && aid.length) self.deviceAreaId[did] = aid;
    }
    [self rebuildMeta];
}

- (void)ingestEntities:(NSArray *)list {
    [self.entityAreaId removeAllObjects];
    [self.entityDevice removeAllObjects];
    [self.diagSet removeAllObjects];
    for (NSDictionary *e in list) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSString *eid = e[@"entity_id"];
        if (!eid) continue;
        NSString *aid = e[@"area_id"];
        NSString *did = e[@"device_id"];
        if ([aid isKindOfClass:[NSString class]] && aid.length) self.entityAreaId[eid] = aid;
        if ([did isKindOfClass:[NSString class]] && did.length) self.entityDevice[eid] = did;
        NSString *cat = e[@"entity_category"];
        if ([cat isKindOfClass:[NSString class]] && [cat isEqualToString:@"diagnostic"]) {
            [self.diagSet addObject:eid];
        }
    }
    [self rebuildMeta];
}

- (NSSet<NSString *> *)diagnosticEntities {
    return self.diagSet ? [self.diagSet copy] : [NSSet set];
}

- (void)rebuildMeta {
    NSMutableDictionary *areas = [NSMutableDictionary dictionary];
    NSMutableSet *allEntities = [NSMutableSet setWithArray:self.entityAreaId.allKeys];
    [allEntities addObjectsFromArray:self.entityDevice.allKeys];
    for (NSString *eid in allEntities) {
        NSString *aid = self.entityAreaId[eid];
        if (!aid.length) {
            NSString *did = self.entityDevice[eid];
            if (did) aid = self.deviceAreaId[did];
        }
        if (aid.length) {
            NSString *name = self.areaById[aid] ?: aid;
            areas[eid] = name;
        }
    }
    self.entityAreas = areas;
    self.areaNames = [self.areaById copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate haClient:self didLoadMeta:areas areaNames:[self.areaById copy]];
    });
}

#pragma mark - rest

- (void)fetchStatesWithCompletion:(void (^)(NSArray *, NSError *))completion {
    NSString *b = [self trimmedBase];
    if (b.length == 0 || self.token.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"HA" code:1 userInfo:@{NSLocalizedDescriptionKey: @"缺少地址或令牌"}]);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[b stringByAppendingString:@"/api/states"]]];
    [req setValue:[@"Bearer " stringByAppendingString:self.token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger code = [(NSHTTPURLResponse *)response statusCode];
            if (code == 401) {
                [self setStatus:@"error" message:@"令牌无效（401）"];
                if (completion) completion(nil, [NSError errorWithDomain:@"HA" code:401 userInfo:@{NSLocalizedDescriptionKey: @"令牌无效"}]);
                return;
            }
        }
        id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![obj isKindOfClass:[NSArray class]]) {
            if (completion) completion(nil, [NSError errorWithDomain:@"HA" code:2 userInfo:@{NSLocalizedDescriptionKey: @"返回数据无法解析"}]);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate haClient:self didReceiveStates:obj];
        });
        if (completion) completion(obj, nil);
    }];
    [task resume];
}

- (void)callService:(NSString *)domain service:(NSString *)service data:(NSDictionary *)data {
    NSString *b = [self trimmedBase];
    if (b.length == 0) return;
    NSString *url = [NSString stringWithFormat:@"%@/api/services/%@/%@", b, domain, service];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    [req setValue:[@"Bearer " stringByAppendingString:self.token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:data ?: @{} options:0 error:nil];
    req.timeoutInterval = 12;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.delegate respondsToSelector:@selector(haClient:didLog:)]) [self.delegate haClient:self didLog:error.localizedDescription];
            });
            return;
        }
        id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([obj isKindOfClass:[NSArray class]]) {
            NSArray *changed = obj;
            dispatch_async(dispatch_get_main_queue(), ^{
                for (NSDictionary *st in changed) {
                    if ([st isKindOfClass:[NSDictionary class]] && st[@"entity_id"]) {
                        [self.delegate haClient:self didUpdateEntity:st];
                    }
                }
            });
        }
    }];
    [task resume];
}

- (BOOL)checkReachableWithCompletion:(void (^)(BOOL, NSString *))completion {
    NSString *b = [self trimmedBase];
    if (b.length == 0 || self.token.length == 0) {
        completion(NO, @"请先填写地址与令牌");
        return NO;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[b stringByAppendingString:@"/api/"]]];
    [req setValue:[@"Bearer " stringByAppendingString:self.token] forHTTPHeaderField:@"Authorization"];
    req.timeoutInterval = 8;
    [[self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) completion(NO, error.localizedDescription);
            else if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                NSInteger code = [(NSHTTPURLResponse *)response statusCode];
                if (code == 200) completion(YES, @"连接正常");
                else if (code == 401) completion(NO, @"令牌无效（401）");
                else completion(NO, [NSString stringWithFormat:@"HTTP %ld", (long)code]);
            } else completion(NO, @"未知响应");
        });
    }] resume];
    return YES;
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    if (self.stopping) return;
    NSString *r = reason ? [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] : @"";
    [self handleDisconnect:[NSError errorWithDomain:@"HA" code:closeCode userInfo:@{NSLocalizedDescriptionKey: r.length ? r : @"连接已关闭"}]];
}

@end
