#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, MQTTLinkStatus) {
    MQTTLinkStatusIdle = 0,
    MQTTLinkStatusConnecting,
    MQTTLinkStatusConnected,
    MQTTLinkStatusFailed
};

/**
 * 极简 MQTT 3.1.1 发布端（只发不收，QoS0 + retain）。
 * 不引第三方库，够用就行：CONNECT / PUBLISH / PINGREQ / DISCONNECT。
 * 故意不设置遗嘱（LWT）——Mac 睡眠时进程还在但发不出心跳，
 * LWT 会把实体打成 unavailable，而睡眠本身应该是一个状态值。
 */
@interface MQTTPublisher : NSObject

@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, copy) NSString *clientId;
@property (nonatomic, assign) uint16_t keepAlive;   // 默认 60
@property (nonatomic, copy) void (^onStatus)(MQTTLinkStatus status, NSString *detail);

- (instancetype)initWithHost:(NSString *)host port:(uint16_t)port;

- (void)start;
- (void)stop;                  // 发 DISCONNECT 正常断开
- (void)forceReconnect;        // 唤醒后用：扔掉旧连接立刻重连

- (BOOL)isConnected;

// 异步排队发布（自动在重连后补发不保证，失败即丢）
- (void)publish:(NSString *)topic payload:(NSString *)payload retain:(BOOL)retain;
// 同步发布：关机/睡眠前用，尽量把字节送出去
- (void)publishNow:(NSString *)topic payload:(NSString *)payload retain:(BOOL)retain;

@end
