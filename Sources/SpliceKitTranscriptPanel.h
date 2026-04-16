//
//  SpliceKitTranscriptPanel.h
//  SpliceKit - Text-based editing via speech transcription
//

#ifndef SpliceKitTranscriptPanel_h
#define SpliceKitTranscriptPanel_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#pragma mark - Data Model

@interface SpliceKitTranscriptWord : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) double startTime;       // seconds on timeline
@property (nonatomic) double duration;         // seconds
@property (nonatomic) double endTime;          // startTime + duration
@property (nonatomic) double confidence;       // 0.0 - 1.0
@property (nonatomic) NSUInteger wordIndex;    // index in words array
@property (nonatomic) NSRange textRange;       // range in text view string
@property (nonatomic, copy) NSString *clipHandle; // handle to the FCP clip this word belongs to
@property (nonatomic) double clipTimelineStart;   // where the clip starts on timeline
@property (nonatomic) double sourceMediaOffset;   // offset in source media (trim start)
@property (nonatomic) double sourceMediaTime;     // absolute time in source media file (immutable after creation)
@property (nonatomic, copy) NSString *sourceMediaPath; // path to source media file (immutable)
@property (nonatomic, copy) NSString *speaker;    // detected or assigned speaker name
@end

@interface SpliceKitTranscriptSilence : NSObject
@property (nonatomic) double startTime;        // silence start (end of previous word)
@property (nonatomic) double endTime;          // silence end (start of next word)
@property (nonatomic) double duration;         // endTime - startTime
@property (nonatomic) NSUInteger afterWordIndex;  // index of word before this silence (-1 if before first word)
@property (nonatomic) NSRange textRange;       // range in text view string
@end

#pragma mark - Transcript Panel

typedef NS_ENUM(NSInteger, SpliceKitTranscriptStatus) {
    SpliceKitTranscriptStatusIdle = 0,
    SpliceKitTranscriptStatusTranscribing,
    SpliceKitTranscriptStatusReady,
    SpliceKitTranscriptStatusError
};

typedef NS_ENUM(NSInteger, SpliceKitTranscriptEngine) {
    SpliceKitTranscriptEngineFCPNative = 0,   // FCP's built-in AASpeechAnalyzer (fast, on-device)
    SpliceKitTranscriptEngineAppleSpeech,     // SFSpeechRecognizer (slower, network-capable)
    SpliceKitTranscriptEngineParakeet,        // NVIDIA Parakeet TDT 0.6B via FluidAudio (on-device, auto-downloads)
};

@interface SpliceKitTranscriptPanel : NSObject

+ (instancetype)sharedPanel;

// Panel visibility
- (void)showPanel;
- (void)hidePanel;
- (BOOL)isVisible;

// Transcription
- (void)transcribeTimeline;                    // auto-detect clips from current timeline
- (void)transcribeFromURL:(NSURL *)audioURL;   // transcribe a specific audio/video file
- (void)transcribeFromURL:(NSURL *)audioURL
       timelineStart:(double)timelineStart
       trimStart:(double)trimStart
       trimDuration:(double)trimDuration;

// State
- (NSDictionary *)getState;
- (void)restorePersistedStateForCurrentSequenceIfNeeded;
- (void)ensurePersistedStateLoaded;  // restore if needed, handles project switches
- (void)clearTranscript;  // clear all words/silences from memory and disk cache
@property (nonatomic, readonly) SpliceKitTranscriptStatus status;
@property (nonatomic, readonly) NSArray<SpliceKitTranscriptWord *> *words;
@property (nonatomic, readonly) NSArray<SpliceKitTranscriptSilence *> *silences;
@property (nonatomic, readonly, copy) NSString *fullText;
@property (nonatomic, readonly, copy) NSString *errorMessage;

// Editing operations - return result dictionaries
- (NSDictionary *)deleteWordsFromIndex:(NSUInteger)startIndex count:(NSUInteger)count;
- (NSDictionary *)moveWordsFromIndex:(NSUInteger)startIndex count:(NSUInteger)count toIndex:(NSUInteger)destIndex;

// Engine selection
@property (nonatomic) SpliceKitTranscriptEngine engine; // default: SpliceKitTranscriptEngineFCPNative

// Silence operations
@property (nonatomic) double silenceThreshold;  // seconds, default 0.3
- (void)detectSilences;                          // recompute silences from word timings
- (void)redetectSilencesAndRefreshUI;            // detectSilences + rebuild text view
- (NSDictionary *)deleteAllSilences;
- (NSDictionary *)deleteSilencesLongerThan:(double)minDuration;

// Speaker assignment
- (void)setSpeaker:(NSString *)speaker forWordsFrom:(NSUInteger)startIndex count:(NSUInteger)count;

// Search
- (NSDictionary *)searchTranscript:(NSString *)query;

// Playhead sync
- (void)updatePlayheadHighlight:(double)timeInSeconds;

@end

#endif /* SpliceKitTranscriptPanel_h */
