//
//  FCPCommandPalette.h
//  Command palette for quick access to FCP actions + Apple LLM natural language
//

#ifndef FCPCommandPalette_h
#define FCPCommandPalette_h

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

// Command categories
typedef NS_ENUM(NSInteger, FCPCommandCategory) {
    FCPCommandCategoryEditing,
    FCPCommandCategoryPlayback,
    FCPCommandCategoryColor,
    FCPCommandCategorySpeed,
    FCPCommandCategoryMarkers,
    FCPCommandCategoryTitles,
    FCPCommandCategoryKeyframes,
    FCPCommandCategoryEffects,
    FCPCommandCategoryTranscript,
    FCPCommandCategoryExport,
    FCPCommandCategoryAI,
    FCPCommandCategoryOptions,
};

@interface FCPCommand : NSObject
@property (nonatomic, strong) NSString *name;           // Display name
@property (nonatomic, strong) NSString *action;         // Action ID (e.g. "blade")
@property (nonatomic, strong) NSString *type;           // "timeline", "playback", "transcript"
@property (nonatomic, assign) FCPCommandCategory category;
@property (nonatomic, strong) NSString *categoryName;   // Display category name
@property (nonatomic, strong) NSString *shortcut;       // Keyboard shortcut hint (display only)
@property (nonatomic, strong) NSString *detail;         // Short description
@property (nonatomic, strong) NSArray<NSString *> *keywords; // Extra search terms
@property (nonatomic, assign) CGFloat score;            // Fuzzy match score (transient)
@property (nonatomic, assign) BOOL isFavoritedItem;     // transient: star indicator
@property (nonatomic, assign) BOOL isSeparatorRow;       // transient: section divider
@end

@interface FCPCommandPalette : NSObject

+ (instancetype)sharedPalette;

// Show/hide
- (void)showPalette;
- (void)hidePalette;
- (void)togglePalette;
- (BOOL)isVisible;

// Execute a command by action name
- (NSDictionary *)executeCommand:(NSString *)action type:(NSString *)type;

// Search commands
- (NSArray<FCPCommand *> *)searchCommands:(NSString *)query;

// Get command at display row (accounting for AI row offset)
- (FCPCommand *)commandForDisplayRow:(NSInteger)row;

// Context menu for right-click in browse mode
- (NSMenu *)contextMenuForRow:(NSInteger)row;

// AI natural language (async, calls completion on main thread)
- (void)executeNaturalLanguage:(NSString *)query completion:(void(^)(NSArray<NSDictionary *> *actions, NSString *error))completion;

@end

#endif /* FCPCommandPalette_h */
