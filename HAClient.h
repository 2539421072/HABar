#import <Foundation/Foundation.h>

@class HAClient;

@protocol HAClientDelegate <NSObject>
- (void)haClientStatusChanged:(HAClient *)client;
- (void)haClient:(HAClient *)client didReceiveStates:(NSArray *)states;
- (void)haClient:(HAClient *)client didUpdateEntity:(NSDictionary *)state;
- (void)haClient:(HAClient *)client didLoadMeta:(NSDictionary *)entityAreas areaNames:(NSDictionary *)areaNames;
@optional
- (void)haClient:(HAClient *)client didLog:(NSString *)line;
@end

@interface HAClient : NSObject

@property (nonatomic, weak) id<HAClientDelegate> delegate;
@property (nonatomic, copy) NSString *baseURL;
@property (nonatomic, copy) NSString *token;

@property (nonatomic, readonly) NSString *status;         // idle | connecting | connected | error
@property (nonatomic, readonly) NSString *statusMessage;
@property (nonatomic, readonly) NSDictionary *entityAreas; // entity_id -> area name
@property (nonatomic, readonly) NSDictionary *areaNames;   // area_id -> name
@property (nonatomic, readonly) NSSet<NSString *> *diagnosticEntities; // entity_category 为 diagnostic 的实体

- (void)start;
- (void)stop;
- (void)restart;
- (void)fetchStatesWithCompletion:(void (^)(NSArray *states, NSError *error))completion;
- (void)callService:(NSString *)domain service:(NSString *)service data:(NSDictionary *)data;
- (BOOL)checkReachableWithCompletion:(void (^)(BOOL ok, NSString *message))completion;

@end
