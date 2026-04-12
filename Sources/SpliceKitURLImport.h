//
//  SpliceKitURLImport.h
//  Remote URL -> local media -> Final Cut import workflow.
//

#ifndef SpliceKitURLImport_h
#define SpliceKitURLImport_h

#import <Foundation/Foundation.h>

NSDictionary *SpliceKitURLImport_start(NSDictionary *params);
NSDictionary *SpliceKitURLImport_importSync(NSDictionary *params);
NSDictionary *SpliceKitURLImport_status(NSDictionary *params);
NSDictionary *SpliceKitURLImport_cancel(NSDictionary *params);

#endif /* SpliceKitURLImport_h */
