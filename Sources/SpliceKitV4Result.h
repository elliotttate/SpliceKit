// Shared v4 result contract (Foundation only; also see mcp/splicekit_v4/envelope.py).
// All keys below are always present. nil becomes JSON null. The optional `status`
// extension is reserved for the operation core (pending/completed/unknown/etc.).
// Handlers may return this envelope or a plain readback dictionary. Never report
// applied=NO after a potentially partial mutation unless independently established.
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
NSDictionary *SpliceKitV4Result(NSString *operationID, BOOL ok, NSNumber *applied,
    NSDictionary *readback, NSString *revisionBefore, NSString *revisionAfter,
    NSString *undoKind, NSString *undoLabel, NSArray *warnings, NSDictionary *error);
NSDictionary *SpliceKitV4Error(NSString *operationID, NSString *code, NSString *message,
    NSNumber *applied, NSDictionary *readback);
BOOL SpliceKitV4IsEnvelope(NSDictionary *value);
#ifdef __cplusplus
}
#endif
