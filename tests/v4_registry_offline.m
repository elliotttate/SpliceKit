#import <Foundation/Foundation.h>
#import "SpliceKitV4Core.h"
extern void SpliceKitV4SetTestHost(NSString *, NSDictionary *(^)(void), NSUndoManager *(^)(void), NSTimeInterval);
static NSMutableDictionary *records;
void SpliceKit_registerPluginMethod(NSString *name, SpliceKitMethodHandler handler, NSDictionary *metadata) {
    if (!records) records = [NSMutableDictionary dictionary];
    if (records[name]) abort();
    records[name] = metadata;
}
id SpliceKit_getActiveTimelineModule(void) { abort(); }
void SpliceKit_executeOnMainThread(dispatch_block_t block) { block(); }
NSString *SpliceKit_storeHandle(id object) { abort(); }
NSDictionary *SpliceKit_handleRequest(NSDictionary *request) { abort(); }
NSDictionary *SpliceKit_handleFCPXMLExport(NSDictionary *params) { abort(); }
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 1;
        SpliceKitV4SetTestHost(@(argv[1]), ^{ return @{}; }, ^{ return (NSUndoManager *)nil; }, 0.1);
        SpliceKitV4RegisterMethods();
        // Run all production constructors; no domain handler or FCP selector runs.
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        NSData *data = [NSJSONSerialization dataWithJSONObject:records options:NSJSONWritingSortedKeys error:nil];
        fwrite(data.bytes, 1, data.length, stdout);
    }
}
