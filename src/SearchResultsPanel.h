// Search results window: one group per search, files below it, matching lines below each file.
// Double-click a line to jump to the match.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <Cocoa/Cocoa.h>

#include <vector>

#include "SearchEngine.h"

@class Document;

@interface SearchResultsPanel : NSWindowController

+ (instancetype) shared;

// Starts a group of results, shown on top. The returned token identifies it in the calls below.
- (id) beginSearchFor: (NSString *) pattern scope: (NSString *) scope;

// Adds the hits of one file. `document` is set for hits found in an open document
// (which may have no file yet); `url` for hits found on disk.
- (void) addHits: (const std::vector<SearchHit> &) hits
          forURL: (NSURL *) url
        document: (Document *) document
        toSearch: (id) search;

// Marks the search as complete and updates its summary line. `note` adds a remark such as "stopped".
- (void) finishSearch: (id) search note: (NSString *) note;

- (NSInteger) hitCountOfSearch: (id) search;
- (NSInteger) fileCountOfSearch: (id) search;

- (IBAction) clearResults: (id) sender;

// Jumps to the selected result (double click or Return in the list).
- (IBAction) openSelectedResult: (id) sender;

@end
