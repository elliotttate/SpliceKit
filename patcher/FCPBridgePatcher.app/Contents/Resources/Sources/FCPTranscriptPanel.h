//
//  FCPTranscriptPanel.h
//  FCPBridge - Text-based editing via speech transcription
//

#ifndef FCPTranscriptPanel_h
#define FCPTranscriptPanel_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#pragma mark - Data Model

@interface FCPTranscriptWord : NSObject
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
@end

#pragma mark - Transcript Panel

typedef NS_ENUM(NSInteger, FCPTranscriptStatus) {
    FCPTranscriptStatusIdle = 0,
    FCPTranscriptStatusTranscribing,
    FCPTranscriptStatusReady,
    FCPTranscriptStatusError
};

@interface FCPTranscriptPanel : NSObject

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
@property (nonatomic, readonly) FCPTranscriptStatus status;
@property (nonatomic, readonly) NSArray<FCPTranscriptWord *> *words;
@property (nonatomic, readonly, copy) NSString *fullText;
@property (nonatomic, readonly, copy) NSString *errorMessage;

// Editing operations - return result dictionaries
- (NSDictionary *)deleteWordsFromIndex:(NSUInteger)startIndex count:(NSUInteger)count;
- (NSDictionary *)moveWordsFromIndex:(NSUInteger)startIndex count:(NSUInteger)count toIndex:(NSUInteger)destIndex;

// Playhead sync
- (void)updatePlayheadHighlight:(double)timeInSeconds;

@end

#endif /* FCPTranscriptPanel_h */
