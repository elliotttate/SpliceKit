#import "SpliceKitV4Media.h"

// Admission records deliberately do not claim to be native analysis tasks. The
// selectors in media-selectors.tsv establish ABI, not the request/result format.
// A blocked admission can be queried/cancelled but can never become ready.
static NSMutableDictionary<NSString *, NSMutableDictionary *> *sMediaAnalysisAdmissions;

static NSDictionary *SKMAnalysisRequirements(void) {
    return @{
        @"object_tracker": @[@"tracker instance and parent effect binding", @"trackShape options format and direction", @"range completion and result geometry", @"task-scoped cancellation"],
        @"shape_mask": @[@"mask instance and parent effect binding", @"geometry coordinate space and control-point format", @"native frame readback; no temporal analysis is implied"],
        @"magnetic_mask": @[@"foreground/background control-point format", @"segmentation range and task identity", @"propagation result coverage", @"task-scoped cancellation"],
        @"auto_mask": @[@"semantic type enum labels", @"mask instance and effect binding", @"analysis availability and range coverage"],
        @"smart_conform": @[@"target container and aspect ratio", @"analysis result representation and ROI", @"apply-result and cancellation contract"],
        @"stabilizer": @[@"algorithm enum labels", @"analysis result availability; waitingForAnalysis=false alone is insufficient", @"range coverage and task-scoped cancellation"]
    };
}

static NSMutableDictionary *SKMAnalysisAdmission(NSDictionary *params) {
    SKMRequire(SKMString(params[@"job_id"]), @"INVALID_PARAMS", @"job_id is required.");
    NSMutableDictionary *job = sMediaAnalysisAdmissions[params[@"job_id"]];
    SKMRequire(job != nil, @"UNKNOWN_JOB", @"The admission is unknown or belongs to another FCP process.");
    return job;
}

void SpliceKitV4RegisterAnalysis(void) {
    sMediaAnalysisAdmissions = [NSMutableDictionary dictionary];
    SKMRegister(@"v4.analysis.start", NO, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        SKMRequire(SKMString(p[@"kind"]) && SKMAnalysisRequirements()[p[@"kind"]], @"INVALID_PARAMS", @"Unknown analysis kind.");
        CMTime start, duration;
        NSDictionary *range = p[@"component_range"];
        SKMRequire([range isKindOfClass:[NSDictionary class]] && SKMTime(range[@"start"], &start) &&
            SKMTime(range[@"duration"], &duration) && CMTimeCompare(duration, kCMTimeZero) > 0,
            @"INVALID_PARAMS", @"A positive rational component_range is required.");
        (void)SKMClip(p);
        SKMRequire(sMediaAnalysisAdmissions.count < 256, @"JOB_LIMIT", @"This process has reached its 256 admission record limit.");
        NSString *jobID = [@"media-analysis-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSMutableDictionary *job = [@{@"job_id": jobID, @"kind": p[@"kind"],
            @"target": p[@"target"], @"component_range": range,
            @"state": @"blocked", @"native_started": @NO, @"ready": @NO,
            @"required_evidence": SKMAnalysisRequirements()[p[@"kind"]],
            @"readiness_rule": @"An identified native task completed successfully, its result belongs to the same clip/effect/mask, and it covers the requested range. Idle or a written slider is insufficient.",
            @"result": NSNull.null} mutableCopy];
        sMediaAnalysisAdmissions[jobID] = job;
        return SKMResult(p, NO, @NO, [job copy], @"UNSUPPORTED_ANALYSIS_ADAPTER",
            @"Admission is blocked. No native analysis was started; the request/result and cancellation formats need calibration.");
    });
    SKMRegister(@"v4.analysis.status", YES, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        return SKMResult(p, YES, @NO, [SKMAnalysisAdmission(p) copy], nil, nil);
    });
    SKMRegister(@"v4.analysis.cancel", NO, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        NSMutableDictionary *job = SKMAnalysisAdmission(p);
        // This cancels only a blocked local admission, never a global FCP task.
        job[@"state"] = @"cancelled";
        return SKMResult(p, YES, @NO, [job copy], nil, nil);
    });
    SKMRegister(@"v4.analysis.result", YES, ^NSDictionary *(NSDictionary *p, BOOL *attempted) {
        return SKMResult(p, NO, @NO, [SKMAnalysisAdmission(p) copy], @"ANALYSIS_NOT_READY",
            @"The admission has no native result. No completion or mask geometry is fabricated.");
    });
}
