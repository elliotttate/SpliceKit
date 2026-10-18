// Durable, session-aware idempotency ledger. Foundation only; no FCP dependency.
// reserve writes+fsyncs before admitting work. IDs are never evicted: compaction
// keeps the last full record per ID. Capacity/corruption/I/O failures close writes.
// A recovered queued/running operation becomes UNKNOWN and is never re-executed.
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
NSString *SpliceKitV4Fingerprint(NSDictionary *value);
BOOL SpliceKitV4OperationIsSettled(NSString *state);
#ifdef __cplusplus
}
#endif

@interface SpliceKitV4OperationLedger : NSObject
@property(nonatomic, readonly) NSString *sessionID;
@property(nonatomic, readonly) NSString *path;
- (instancetype)initWithPath:(NSString *)path sessionID:(NSString *)sessionID;
- (NSDictionary *)reserve:(NSString *)operationID method:(NSString *)method
    fingerprint:(NSString *)fingerprint created:(BOOL *)created error:(NSString **)error;
- (BOOL)update:(NSString *)operationID state:(NSString *)state result:(NSDictionary *)result
    details:(NSDictionary *)details;
- (NSDictionary *)operation:(NSString *)operationID;
- (NSDictionary *)waitFor:(NSString *)operationID timeout:(NSTimeInterval)timeout;
- (NSDictionary *)summary;
@end
