//
//  SpliceKitTranscriptDiagnostics.h
//  SpliceKit - Detailed transcription diagnostics for remote troubleshooting.
//
//  All functions log to [TranscriptDiag] via SpliceKit_log so they appear
//  in ~/Library/Logs/SpliceKit/splicekit.log alongside normal output.
//

#ifndef SpliceKitTranscriptDiagnostics_h
#define SpliceKitTranscriptDiagnostics_h

#import <Foundation/Foundation.h>

#pragma mark - System & Environment

/// Log macOS version, chip, RAM, disk space, and FluidAudio model cache state.
void SpliceKitTranscriptDiag_logSystemInfo(void);

#pragma mark - Binary Validation

/// Validate the parakeet-transcriber binary: exists, executable, arch, codesign, size.
void SpliceKitTranscriptDiag_logBinaryInfo(NSString *binaryPath);

#pragma mark - Timeline & Clip Collection

/// Dump all collected clip infos with full coordinate details.
/// Call after collectClipInfosForSequence returns.
void SpliceKitTranscriptDiag_logClipInfos(NSArray *clipInfos, NSString *engineName);

#pragma mark - Parakeet Process

/// Log the batch manifest contents being sent to parakeet-transcriber.
void SpliceKitTranscriptDiag_logBatchManifest(NSArray *manifestEntries);

/// Log process launch details: binary, args, environment.
void SpliceKitTranscriptDiag_logProcessLaunch(NSString *binaryPath, NSArray *args);

/// Log process exit: code, timing, stdout/stderr sizes, output previews.
void SpliceKitTranscriptDiag_logProcessExit(int exitCode, NSData *stdoutData,
                                             NSData *stderrData, NSTimeInterval elapsed);

#pragma mark - JSON Parsing

/// Inspect raw stdout for known issues (E5RT prefix, truncation, encoding)
/// and log a detailed report. Returns YES if issues were detected.
BOOL SpliceKitTranscriptDiag_inspectRawOutput(NSData *stdoutData);

/// Log parsed batch results: file count, per-file word counts, time ranges.
void SpliceKitTranscriptDiag_logParsedResults(NSArray *batchResults);

#pragma mark - Word Filtering

/// Log the coordinate mapping for a single clip: trimStart, mediaOrigin,
/// fileRelativeTrimStart, filter window, and how many words passed vs failed.
void SpliceKitTranscriptDiag_logWordFiltering(NSString *fileName,
                                               NSArray *rawWords,
                                               double trimStart,
                                               double mediaOrigin,
                                               double clipDuration,
                                               NSUInteger wordsAccepted);

#pragma mark - Apple Speech

/// Log Apple Speech authorization state and recognizer availability details.
void SpliceKitTranscriptDiag_logAppleSpeechState(void);

#pragma mark - FCP Native

/// Log FCP native transcription coordinator availability and asset details.
void SpliceKitTranscriptDiag_logFCPNativeState(NSArray *clipInfos);

#pragma mark - Summary

/// Log a final transcription summary: engine, timing, word/silence counts,
/// any anomalies detected.
void SpliceKitTranscriptDiag_logSummary(NSString *engineName,
                                         NSTimeInterval totalElapsed,
                                         NSUInteger wordCount,
                                         NSUInteger silenceCount,
                                         NSUInteger clipCount,
                                         NSString *errorMessage);

#endif /* SpliceKitTranscriptDiagnostics_h */
