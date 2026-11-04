#import <Foundation/Foundation.h>

/**
 * 把本机的电源状态（开机 / 睡眠 / 关机）通过 MQTT 上报给 Home Assistant。
 *
 * 设计取舍：
 * - 状态是「值」而不是「事件」，所以睡眠期间实体显示 sleep，而不是被 LWT 打成 unavailable；
 * - 关机前抢发一条 off 并保留（retain），下次开机再发 on，历史里就是完整的关-开往返；
 * - 不用 LWT：Mac 一睡就没心跳，用 LWT 只会让实体在每次睡眠时变不可用；
 * - 每 5 分钟重发一次状态，防 broker 重启丢 retained。
 */
@interface PowerReporter : NSObject

/// cfg 键：enabled / host / port / user / pass / device
- (instancetype)initWithConfig:(NSDictionary *)cfg;

- (void)start;
/// 用户主动退出 App：把可用性置 offline 后断开（机器还在运行，但上报停了）
- (void)stopForQuit;
/// 改配置时静默停机，不碰可用性
- (void)stopSilently;

/// 连接状态文案变化（主线程回调）
@property (nonatomic, copy) void (^onStatus)(NSString *text, BOOL connected);
/// 当前状态变化：on / sleep / off
@property (nonatomic, copy) void (^onStateChange)(NSString *state);

+ (NSString *)slugify:(NSString *)name;

@end
