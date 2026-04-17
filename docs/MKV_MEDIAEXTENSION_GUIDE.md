# Writing an MKV MediaExtension for Final Cut Pro

This guide explains how to build a modern Apple MediaExtension format reader that adds
Matroska (`.mkv`) and WebM (`.webm`) container support to Final Cut Pro and other
professional-video hosts.

The focus here is the container side:

- parsing the file through `MEFormatReader`
- exposing tracks through `METrackReader`
- vendoring seekable sample access through `MESampleCursor`
- creating `CMFormatDescription`s that AVFoundation / CoreMedia / Final Cut Pro can consume

Just as important: container support is not the same thing as codec support.

If your MKV file contains codecs that the system can already decode, a format reader may be
enough. If it contains codecs that VideoToolbox / CoreMedia cannot decode, you will usually
need a companion `MEVideoDecoder` extension as well.

This document is based on four local sources:

1. Apple SDK headers for `MediaExtension`, `MediaToolbox`, and `VideoToolbox`
2. The ObjC prototype in `FFMPEGMediaExtension`
3. The more complete Swift implementation in `QuickLookVideo`
4. Reverse-engineered bundle layout and symbols from the shipped `VidCore` MKV reader

---

## Table of Contents

1. [What You Are Building](#what-you-are-building)
2. [Observed Architecture in VidCore](#observed-architecture-in-vidcore)
3. [Host Registration and Why FCP Matters](#host-registration-and-why-fcp-matters)
4. [Project Layout](#project-layout)
5. [Info.plist and Entitlements](#infoplist-and-entitlements)
6. [Apple Protocol Surface](#apple-protocol-surface)
7. [MKV Domain Model You Need](#mkv-domain-model-you-need)
8. [Reader Architecture Choices](#reader-architecture-choices)
9. [Factory Implementation](#factory-implementation)
10. [Bridging `MEByteSource` Into a Parser](#bridging-mebytesource-into-a-parser)
11. [Implementing `MEFormatReader`](#implementing-meformatreader)
12. [Implementing `METrackReader`](#implementing-metrackreader)
13. [Building Track Format Descriptions](#building-track-format-descriptions)
14. [Implementing `MESampleCursor`](#implementing-mesamplecursor)
15. [Sample Delivery Strategies](#sample-delivery-strategies)
16. [MKV-Specific Parsing and Indexing](#mkv-specific-parsing-and-indexing)
17. [Metadata, Attachments, Chapters, and Sidecars](#metadata-attachments-chapters-and-sidecars)
18. [FCP-Specific Behavior and Gotchas](#fcp-specific-behavior-and-gotchas)
19. [Testing Strategy](#testing-strategy)
20. [Troubleshooting](#troubleshooting)
21. [Implementation Checklist](#implementation-checklist)
22. [Reference Files](#reference-files)

---

## What You Are Building

At a high level, the data flow looks like this:

```text
Final Cut Pro / AVFoundation host
    -> MediaToolbox registers professional workflow format readers
    -> your Reader.appex is discovered
    -> MediaToolbox creates MEByteSource for file
    -> your factory creates MEFormatReader
    -> format reader parses file, tracks, metadata
    -> track readers vend sample cursors
    -> sample cursors seek and return sample buffers or byte ranges
    -> system decodes using built-in decoders or your companion MEVideoDecoder
```

An MKV format reader does three big jobs:

1. Parse Matroska / EBML structure and discover tracks, duration, metadata, cues, and samples.
2. Translate Matroska semantics into CoreMedia semantics.
3. Answer random-access sample queries efficiently enough for scrubbing, thumbnails, stepping,
   and timeline import.

What it does not automatically do:

- decode VP9, AV1, ProRes RAW, or other codecs by itself
- invent a `CMFormatDescription` for codecs whose initialization records you did not parse
- make Final Cut Pro "just work" with every MKV if the codec path is still unsupported

That split is visible in the two local reference projects:

- `FFMPEGMediaExtension` mostly proves the `MEFormatReader` container side.
- `QuickLookVideo` goes further and pairs a format reader with a video decoder strategy.

---

## Observed Architecture in VidCore

The shipped `VidCore.app` bundle is useful because it shows a realistic production split.

Its extension bundle declares:

- extension point: `com.apple.mediaextension.formatreader`
- principal class: `MKVFormatReaderFactory`
- supported extensions: `mkv`, `webm`
- exported UTTypes for custom Matroska and WebM identifiers

Relevant bundle files:

- `Reader.appex`
- embedded `MKV.framework`

Observed symbol families in the reader binary:

- `MKVFormatReaderFactory`
- `MKVFormatReader`
- `MKVTrackReader`
- `MKVSampleCursor`
- `IndexingCoordinator`
- `CoordinatorProbeScheduler`

Observed symbol families in the embedded framework:

- `EBMLReader`
- `EBMLStreamingRangeReader`
- `MKVUnifiedIndexer`
- `MKVIndexingOperation`
- `MKVTrackModel`
- `MKVSampleModel`
- `MKVFileByteSource`

That suggests a clean production architecture:

```text
Reader.appex
    factory and MediaExtension protocol objects
    light orchestration
    host-facing translation layer

MKV.framework
    pure parser / indexing engine
    EBML reader
    track + sample models
    random-access index builder
    byte-source abstraction
```

That split is a good one to copy.

---

## Host Registration and Why FCP Matters

MediaExtensions are not used by every app automatically. The host has to opt into the
professional-video workflow path.

Apple exposes this through:

```c
MTRegisterProfessionalVideoWorkflowFormatReaders();
VTRegisterProfessionalVideoWorkflowVideoDecoders();
```

The SDK headers describe the intent clearly:

- `MTRegisterProfessionalVideoWorkflowFormatReaders()` tells MediaToolbox that the client wants
  MediaExtension format readers.
- `VTRegisterProfessionalVideoWorkflowVideoDecoders()` does the same for video decoders.

For your own standalone test app, call these during startup:

```swift
import MediaToolbox
import VideoToolbox

@main
struct TestHost: App {
    init() {
        MTRegisterProfessionalVideoWorkflowFormatReaders()
        VTRegisterProfessionalVideoWorkflowVideoDecoders()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

That is exactly how `QuickLookVideo`'s local `simpleplayer` test app is set up.

For Final Cut Pro specifically, the point is not to modify FCP. The point is to ship an
extension in a form that FCP's professional-video path can discover and use when it registers
workflow readers.

Important implication:

- If you only want to validate parsing, a small AVFoundation host app is easier to debug.
- If you want to validate import, scrubbing, thumbnails, and timeline behavior in FCP,
  you eventually need to test inside FCP.

---

## Project Layout

The cleanest structure is:

```text
MyMKVHost/
    MyMKVHost.app
    Reader.appex
    MKVCore.framework
```

Recommended responsibility split:

```text
MyMKVHost.app
    signing container
    preferences / diagnostics
    standalone test harness

Reader.appex
    MEFormatReaderExtension factory
    MEFormatReader implementation
    METrackReader implementation
    MESampleCursor implementation
    bridge layer between CoreMedia and parser/index

MKVCore.framework
    EBML parser
    Matroska element decoding
    cue/index generation
    sample model
    track model
    codec-private parsing helpers
    byte-range reader
```

If you expect to support many container formats later, generalize `MKVCore.framework` into
something like:

```text
MediaContainerCore.framework
    EBML/
    Matroska/
    MP4/
    Utilities/
```

But for a single-format extension, a dedicated `MKV` or `MKVCore` framework is simpler.

---

## Info.plist and Entitlements

### Extension Info.plist

At minimum, the extension must declare the format reader extension point and supported types.

Example:

```xml
<key>EXAppExtensionAttributes</key>
<dict>
    <key>EXExtensionPointIdentifier</key>
    <string>com.apple.mediaextension.formatreader</string>

    <key>ClassImplementationID</key>
    <string>com.example.mkv.reader</string>

    <key>EXPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).MKVFormatReaderFactory</string>

    <key>ObjectName</key>
    <string>MKV / WebM Format Reader</string>

    <key>MTFileNameExtensionArray</key>
    <array>
        <string>mkv</string>
        <string>webm</string>
    </array>

    <key>MTUTTypeArray</key>
    <array>
        <string>org.matroska.mkv</string>
        <string>org.webmproject.webm</string>
        <string>com.example.mkv</string>
    </array>
</dict>

<key>UTExportedTypeDeclarations</key>
<array>
    <dict>
        <key>UTTypeIdentifier</key>
        <string>com.example.mkv</string>
        <key>UTTypeDescription</key>
        <string>Matroska Video File</string>
        <key>UTTypeConformsTo</key>
        <array>
            <string>com.apple.mediaextension-content</string>
            <string>public.movie</string>
        </array>
        <key>UTTypeTagSpecification</key>
        <dict>
            <key>public.filename-extension</key>
            <array>
                <string>mkv</string>
            </array>
            <key>public.mime-type</key>
            <string>video/x-matroska</string>
        </dict>
    </dict>
</array>
```

Notes:

- `com.apple.mediaextension-content` matters. Apple explicitly calls this out as the
  professional-video content umbrella type for format readers.
- If you want related files or sidecars, their file extensions must also appear in the plist.
- `VidCore` exports custom UTTypes in addition to standard Matroska identifiers.

### Extension entitlements

The important entitlement is:

```xml
<key>com.apple.developer.mediaextension.formatreader</key>
<true/>
```

Typical sandbox bundle:

```xml
<dict>
    <key>com.apple.developer.mediaextension.formatreader</key>
    <true/>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.example.mkv</string>
    </array>
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>
</dict>
```

Use an app group if:

- you want preferences shared between host app and extension
- you want diagnostics or caching shared between them
- you want a decoder extension and reader extension to share settings

---

## Apple Protocol Surface

These are the main protocols and objects you must understand.

### `MEFormatReaderExtension`

Purpose: factory for a new reader instance.

Required methods:

| Method | Meaning |
|---|---|
| `-init` | extension object creation |
| `formatReaderWithByteSource:options:error:` | create reader for one asset |

### `MEFormatReader`

Purpose: asset-level object.

Required methods:

| Method | Meaning |
|---|---|
| `loadFileInfoWithCompletionHandler:` | duration, fragments, sidecar file |
| `loadMetadataWithCompletionHandler:` | file-level metadata |
| `loadTrackReadersWithCompletionHandler:` | one `METrackReader` per usable track |

Optional methods:

| Method | Meaning |
|---|---|
| `parseAdditionalFragmentsWithCompletionHandler:` | incremental fragment parsing |

### `METrackReader`

Purpose: one logical track.

Required methods:

| Method | Meaning |
|---|---|
| `loadTrackInfoWithCompletionHandler:` | build `METrackInfo` |
| `generateSampleCursorAtPresentationTimeStamp:completionHandler:` | random seek |
| `generateSampleCursorAtFirstSampleInDecodeOrderWithCompletionHandler:` | first sample |
| `generateSampleCursorAtLastSampleInDecodeOrderWithCompletionHandler:` | last sample |

Optional methods:

| Method | Meaning |
|---|---|
| `loadUneditedDurationWithCompletionHandler:` | raw track duration |
| `loadTotalSampleDataLengthWithCompletionHandler:` | total sample bytes |
| `loadEstimatedDataRateWithCompletionHandler:` | bytes/sec |
| `loadMetadataWithCompletionHandler:` | track-level metadata |

### `METrackInfo`

Mandatory constructor:

```objc
- (instancetype)initWithMediaType:(CMMediaType)mediaType
                          trackID:(CMPersistentTrackID)trackID
               formatDescriptions:(NSArray *)formatDescriptions;
```

Important properties:

| Property | Meaning |
|---|---|
| `mediaType` | video, audio, subtitle, metadata |
| `trackID` | must be non-zero and unique within asset |
| `enabled` | default enabled state |
| `formatDescriptions` | one or more `CMFormatDescription`s |
| `naturalTimescale` | track timebase |
| `trackEdits` | optional edit list |
| `extendedLanguageTag` | RFC 4646 / BCP 47 language |
| `naturalSize` | video dimensions |
| `preferredTransform` | display transform |
| `nominalFrameRate` | fps |
| `requiresFrameReordering` | B-frame / reordered decode |

### `MESampleCursor`

Required state:

| Property | Meaning |
|---|---|
| `presentationTimeStamp` | current PTS |
| `decodeTimeStamp` | current DTS |
| `currentSampleDuration` | current sample duration |
| `currentSampleFormatDescription` | format description at current sample |

Required navigation:

| Method | Meaning |
|---|---|
| `stepInDecodeOrderByCount:completionHandler:` | sample count stepping |
| `stepInPresentationOrderByCount:completionHandler:` | PTS-order stepping |
| `stepByDecodeTime:completionHandler:` | seek by decode time delta |
| `stepByPresentationTime:completionHandler:` | seek by presentation time delta |

Important optional capabilities:

| Method / property | Why it matters |
|---|---|
| `syncInfo` | keyframe and droppable flags |
| `dependencyInfo` | reference-frame dependencies |
| `sampleLocationReturningError:` | direct byte-range sample access |
| `chunkDetailsReturningError:` | direct chunk access |
| `estimatedSampleLocationReturningError:` | two-step range refinement |
| `refineSampleLocation:...` | exact range after estimate |
| `loadSampleBufferContainingSamplesToEndCursor:completionHandler:` | direct sample buffer delivery |
| `loadPostDecodeProcessingMetadataWithCompletionHandler:` | frame-level post-decode metadata |

### `MEByteSource`

This is the host-owned file access object you get from MediaToolbox.

Useful properties:

| Property | Meaning |
|---|---|
| `fileName` | file name |
| `contentType` | `UTType` |
| `fileLength` | file size if known |
| `relatedFileNamesInSameDirectory` | visible sibling files |

Useful methods:

| Method | Meaning |
|---|---|
| `readDataOfLength:fromOffset:toDestination:bytesRead:error:` | sync read into buffer |
| `readDataOfLength:fromOffset:completionHandler:` | async read into `NSData` |
| `availableLengthAtOffset:` | how much data is currently available |
| `byteSourceForRelatedFileName:error:` | open sidecar or sibling file |

### Errors

The core `MEError` values you will actually use are:

| Error | Use it when |
|---|---|
| `MEErrorUnsupportedFeature` | codec / track / feature not supported |
| `MEErrorParsingFailure` | malformed MKV / EBML |
| `MEErrorNoSamples` | empty track or impossible sample request |
| `MEErrorLocationNotAvailable` | sample is not directly readable as one contiguous range |
| `MEErrorEndOfStream` | EOF |
| `MEErrorPermissionDenied` | related file access denied |

---

## MKV Domain Model You Need

Do not make CoreMedia objects your primary storage model. Build a Matroska-native model first.

Minimum model types:

```swift
struct MKVFileModel {
    var duration: CMTime
    var title: String?
    var muxingApp: String?
    var writingApp: String?
    var tags: [String: String]
    var tracks: [MKVTrackModel]
    var cues: [MKVCuePoint]
}

struct MKVTrackModel {
    var trackNumber: UInt64
    var trackID: CMPersistentTrackID
    var mediaType: CMMediaType
    var codecID: String
    var codecPrivate: Data?
    var language: String?
    var enabled: Bool
    var timeScale: Int32
    var displayWidth: Int32?
    var displayHeight: Int32?
    var sampleRate: Double?
    var channels: Int32?
    var samples: [MKVSampleModel]
}

struct MKVSampleModel {
    var ordinal: Int
    var byteOffset: Int64
    var byteLength: Int
    var clusterOffset: Int64
    var clusterTimecode: Int64
    var blockRelativeTimecode: Int16
    var pts: CMTime
    var dts: CMTime
    var duration: CMTime
    var isKeyframe: Bool
    var dependsOnOthers: Bool
    var laceCount: Int
}
```

For MKV, the index is not optional if you want good UX.

You need to answer:

- seek to nearest sample by PTS
- seek to first / last decode sample
- move by sample count
- identify keyframes for scrubbing
- map sample -> byte offset for direct read or fallback to decoded delivery

Matroska-specific structures worth parsing:

- `EBML`
- `Segment`
- `SeekHead`
- `Info`
- `Tracks`
- `Cluster`
- `SimpleBlock`
- `BlockGroup`
- `BlockDuration`
- `Cues`
- `Tags`
- `Attachments`
- `Chapters`

If you skip cues and skip prebuilt indexing, seeking will be bad.

---

## Reader Architecture Choices

There are two practical implementation styles.

### Option 1: Use FFmpeg / libavformat as your parser

Pros:

- fastest path to "works on a lot of files"
- `avformat_find_stream_info` gives you tracks, metadata, and codec parameters
- easier prototype

Cons:

- sample location and chunk semantics do not map cleanly to CoreMedia
- Matroska-specific fidelity is hidden behind FFmpeg abstractions
- random-access sample cursor behavior needs extra buffering and bookkeeping
- you still need to build proper CoreMedia objects

This is the direction taken by `FFMPEGMediaExtension` and `QuickLookVideo`.

### Option 2: Write a native EBML / Matroska parser and indexer

Pros:

- full control over cues, lacing, attachments, chapter markers, and cue strategy
- easier to reason about direct sample byte offsets
- easier to build a sidecar index
- closer to what the shipped VidCore reader appears to do

Cons:

- much more code
- you need to translate codec-private data yourself
- you need to solve container edge cases yourself

For production MKV support in FCP, this second architecture is the better long-term design.

### Hybrid design

A good compromise:

- native EBML parser for structure and sample indexing
- use FFmpeg only for codec-private normalization or fallback decode paths

That gives you precise sample addressing without reinventing every codec helper.

---

## Factory Implementation

A minimal Swift factory:

```swift
import Foundation
import MediaExtension
import OSLog

final class MKVFormatReaderFactory: NSObject, MEFormatReaderExtension {
    private let log = Logger(subsystem: "com.example.mkv", category: "reader")

    override init() {
        super.init()
        log.debug("MKVFormatReaderFactory init")
    }

    func formatReader(
        with primaryByteSource: MEByteSource,
        options: MEFormatReaderInstantiationOptions?
    ) throws -> any MEFormatReader {
        let typeID = primaryByteSource.contentType?.identifier ?? "unknown"
        log.debug("creating reader for \(primaryByteSource.fileName, privacy: .public) type=\(typeID, privacy: .public)")
        return try MKVFormatReader(primaryByteSource: primaryByteSource, options: options)
    }
}
```

ObjC factory equivalent:

```objc
@implementation MKVFormatReaderFactory

- (id<MEFormatReader>)formatReaderWithByteSource:(MEByteSource *)primaryByteSource
                                         options:(MEFormatReaderInstantiationOptions *)options
                                           error:(NSError * _Nullable __autoreleasing *)error
{
    return [[MKVFormatReader alloc] initWithByteSource:primaryByteSource options:options error:error];
}

@end
```

The factory should be boring. All real logic belongs in the reader and parser layers.

---

## Bridging `MEByteSource` Into a Parser

If you are using FFmpeg, you need to bridge `MEByteSource` into `AVIOContext`.

### ObjC bridge callback example

This is the cleanest way to use the synchronous `MEByteSource` buffer-read API:

```objc
int MEByteSource_read_packet(void *opaque, uint8_t *buf, int buf_size) {
    MKVFormatReader *reader = (__bridge MKVFormatReader *)opaque;
    size_t bytesRead = 0;
    NSError *error = nil;

    if ([reader.byteSource readDataOfLength:buf_size
                                 fromOffset:reader.filePosition
                              toDestination:buf
                                  bytesRead:&bytesRead
                                      error:&error]) {
        reader.filePosition += bytesRead;
        return (int)bytesRead;
    }

    if (error.code == MEErrorEndOfStream) {
        return AVERROR_EOF;
    }

    return AVERROR_UNKNOWN;
}

int64_t MEByteSource_seek(void *opaque, int64_t offset, int whence) {
    MKVFormatReader *reader = (__bridge MKVFormatReader *)opaque;

    switch (whence) {
        case AVSEEK_SIZE:
            return reader.byteSource.fileLength;
        case SEEK_SET:
            reader.filePosition = offset;
            return reader.filePosition;
        case SEEK_CUR:
            reader.filePosition += offset;
            return reader.filePosition;
        case SEEK_END:
            reader.filePosition = reader.byteSource.fileLength + offset;
            return reader.filePosition;
        default:
            return AVERROR_BUG;
    }
}
```

### Direct parser wrapper example

If you are writing your own EBML parser, make the byte source look like a regular range reader:

```swift
protocol RangeReadable {
    var length: Int64 { get }
    func read(offset: Int64, length: Int) throws -> Data
}

final class MKVFileByteSource: RangeReadable {
    let byteSource: MEByteSource

    init(byteSource: MEByteSource) {
        self.byteSource = byteSource
    }

    var length: Int64 { byteSource.fileLength }

    func read(offset: Int64, length: Int) throws -> Data {
        var output = Data(count: length)
        let bytesRead = try output.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return 0 }
            var actual = 0
            var error: NSError?
            let ok = byteSource.readDataOfLength(
                length,
                fromOffset: offset,
                toDestination: base,
                bytesRead: &actual,
                error: &error
            )
            if !ok {
                throw error ?? NSError(domain: "MKVFileByteSource", code: -1)
            }
            return actual
        }
        output.removeSubrange(bytesRead..<output.count)
        return output
    }
}
```

This is the better abstraction if you plan to build your own `EBMLReader`.

---

## Implementing `MEFormatReader`

Your format reader owns asset-wide state:

- the primary `MEByteSource`
- the parser / demuxer
- the parsed file model
- the array of track readers
- optionally a sidecar index path or incremental indexing state

Example skeleton:

```swift
import AVFoundation
import MediaExtension

final class MKVFormatReader: NSObject, MEFormatReader {
    let primaryByteSource: MEByteSource
    let options: MEFormatReaderInstantiationOptions?
    let byteReader: MKVFileByteSource

    private var fileModel: MKVFileModel?
    private var trackReaders: [MKVTrackReader] = []

    init(primaryByteSource: MEByteSource, options: MEFormatReaderInstantiationOptions?) throws {
        self.primaryByteSource = primaryByteSource
        self.options = options
        self.byteReader = MKVFileByteSource(byteSource: primaryByteSource)
        super.init()
    }

    func loadFileInfo(completionHandler: @escaping @Sendable (MEFileInfo?, (any Error)?) -> Void) {
        do {
            let parsed = try parseFileIfNeeded()
            let info = MEFileInfo()
            info.duration = parsed.duration
            info.fragmentsStatus = .couldNotContainFragments
            completionHandler(info, nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    func loadMetadata(completionHandler: @escaping @Sendable ([AVMetadataItem]?, (any Error)?) -> Void) {
        do {
            let parsed = try parseFileIfNeeded()
            completionHandler(makeFileMetadata(parsed), nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    func loadTrackReaders(completionHandler: @escaping @Sendable ([any METrackReader]?, (any Error)?) -> Void) {
        do {
            let parsed = try parseFileIfNeeded()
            if trackReaders.isEmpty {
                trackReaders = try parsed.tracks.enumerated().map { index, track in
                    try MKVTrackReader(parent: self, track: track, ordinal: index)
                }
            }
            completionHandler(trackReaders, nil)
        } catch {
            completionHandler(nil, error)
        }
    }
}
```

### When to parse

You have two basic choices:

1. Parse eagerly in `init`.
2. Parse lazily in the first load method.

Lazy parsing is usually better because:

- factory construction stays cheap
- error reporting lands in the async load call the host already expects
- you can short-circuit on obviously unsupported content types before touching the file

### What `loadFileInfo` should really do

It should at least establish:

- total duration
- whether the file can contain incremental fragments
- optional sidecar index filename

For plain MKV/WebM:

- `fragmentsStatus` is usually `.couldNotContainFragments`
- `sidecarFileName` can be useful if you want to persist a generated index

Example:

```swift
func loadFileInfo(completionHandler: @escaping @Sendable (MEFileInfo?, (any Error)?) -> Void) {
    do {
        let parsed = try parseFileIfNeeded()
        let info = MEFileInfo()
        info.duration = parsed.duration
        info.fragmentsStatus = .couldNotContainFragments
        info.sidecarFileName = "\(primaryByteSource.fileName).mkvindex"
        completionHandler(info, nil)
    } catch {
        completionHandler(nil, error)
    }
}
```

### File-level metadata mapping

Matroska tags do not match AVFoundation identifiers one-for-one. Build a mapping layer.

Example:

```swift
func makeFileMetadata(_ model: MKVFileModel) -> [AVMetadataItem] {
    var items: [AVMetadataItem] = []

    func append(_ identifier: AVMetadataIdentifier, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.dataType = String(kCMMetadataBaseDataType_UTF8)
        item.value = value as NSString
        items.append(item)
    }

    append(.commonIdentifierTitle, model.title)
    append(.quickTimeMetadataSoftware, model.writingApp)
    append(.quickTimeMetadataEncodedBy, model.muxingApp)

    for (key, value) in model.tags {
        switch key.lowercased() {
            case "artist": append(.commonIdentifierArtist, value)
            case "album": append(.commonIdentifierAlbumName, value)
            case "comment": append(.quickTimeMetadataComment, value)
            default: break
        }
    }

    return items
}
```

---

## Implementing `METrackReader`

Each `METrackReader` should wrap one logical MKV track.

Typical responsibilities:

- build `METrackInfo`
- translate track language / edit state / timescale
- vend sample cursors for first, last, or arbitrary PTS

Example skeleton:

```swift
final class MKVTrackReader: NSObject, METrackReader {
    unowned let parent: MKVFormatReader
    let track: MKVTrackModel
    let ordinal: Int
    let formatDescription: CMFormatDescription

    init(parent: MKVFormatReader, track: MKVTrackModel, ordinal: Int) throws {
        self.parent = parent
        self.track = track
        self.ordinal = ordinal
        self.formatDescription = try MKVTrackReader.makeFormatDescription(for: track)
        super.init()
    }

    func loadTrackInfo(completionHandler: @escaping @Sendable (METrackInfo?, (any Error)?) -> Void) {
        do {
            let info = METrackInfo(
                __mediaType: track.mediaType,
                trackID: track.trackID,
                formatDescriptions: [formatDescription]
            )
            info.isEnabled = track.enabled
            info.naturalTimescale = track.timeScale
            info.extendedLanguageTag = track.language

            if track.mediaType == kCMMediaType_Video {
                info.naturalSize = CGSize(width: Int(track.displayWidth ?? 0), height: Int(track.displayHeight ?? 0))
                info.requiresFrameReordering = track.samples.contains { $0.dts != $0.pts }
            }

            completionHandler(info, nil)
        } catch {
            completionHandler(nil, error)
        }
    }
}
```

### Track IDs

Do not use zero.

Apple explicitly reserves `0` as invalid. If the container's native track numbering is not
usable as `CMPersistentTrackID`, map them yourself:

```swift
let persistentTrackID = CMPersistentTrackID(ordinal + 1)
```

### Which tracks should you expose

For FCP, you usually want:

- primary video tracks
- primary audio tracks
- subtitle tracks only if you can provide sensible CoreMedia metadata

You usually do not want:

- cover-art attachment streams as playback tracks
- fonts and binary attachments as tracks
- junk metadata streams

Attachment streams should normally become metadata, not `METrackReader`s.

---

## Building Track Format Descriptions

This is where many implementations fail.

The parser knows container + codec.
CoreMedia needs a valid `CMFormatDescription`.

### Video

For video, use `CMVideoFormatDescriptionCreate`.

Example:

```swift
static func makeVideoDescription(for track: MKVTrackModel) throws -> CMFormatDescription {
    let codecType = try codecTypeForTrack(track)
    var desc: CMVideoFormatDescription?

    let extensions = makeVideoExtensions(for: track)
    let status = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: codecType,
        width: Int32(track.displayWidth ?? 0),
        height: Int32(track.displayHeight ?? 0),
        extensions: extensions.isEmpty ? nil : extensions as CFDictionary,
        formatDescriptionOut: &desc
    )

    guard status == noErr, let desc else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return desc
}
```

For H.264 / HEVC / AV1 / VP9, you may need codec-specific atoms in
`kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms`.

Examples:

- H.264 -> `avcC`
- HEVC -> `hvcC`
- AV1 -> `av1C`
- VP8 / VP9 -> `vpcC`
- MPEG-4 Part 2 -> `esds`

This is one of the most useful ideas in `QuickLookVideo`: synthesize the atom if the
container does not hand it to you in the form CoreMedia expects.

### Audio

For audio, use `CMAudioFormatDescriptionCreate`.

Example:

```swift
static func makeAudioDescription(
    sampleRate: Double,
    channels: UInt32,
    formatID: AudioFormatID,
    bitsPerChannel: UInt32
) throws -> CMFormatDescription {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: formatID,
        mFormatFlags: kAudioFormatFlagIsSignedInteger,
        mBytesPerPacket: (bitsPerChannel / 8) * channels,
        mFramesPerPacket: 1,
        mBytesPerFrame: (bitsPerChannel / 8) * channels,
        mChannelsPerFrame: channels,
        mBitsPerChannel: bitsPerChannel,
        mReserved: 0
    )

    var desc: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &desc
    )

    guard status == noErr, let desc else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return desc
}
```

Compressed audio is trickier:

- if the system can decode it, you may be able to pass compressed packets through
- if not, decode in your extension and vend PCM sample buffers

### Subtitle tracks

Subtitle support is possible, but it is not the first thing to ship.

Unless you already know how you want CoreMedia and FCP to consume the subtitle payload,
leave subtitle `METrackReader`s out of the first version and treat them as metadata.

---

## Implementing `MESampleCursor`

This is the hard part.

The host will create sample cursors and then ask them to:

- report current PTS / DTS / duration
- step forward and backward
- seek to arbitrary times
- return sync and dependency info
- deliver bytes or sample buffers

The cursor should not be your parser.
It should be a cheap view over a prebuilt sample index.

Example index-backed cursor:

```swift
final class MKVSampleCursor: NSObject, MESampleCursor, NSCopying {
    let track: MKVTrackModel
    let byteReader: MKVFileByteSource
    var sampleIndex: Int

    init(track: MKVTrackModel, byteReader: MKVFileByteSource, sampleIndex: Int) {
        self.track = track
        self.byteReader = byteReader
        self.sampleIndex = sampleIndex
        super.init()
    }

    func copy(with zone: NSZone? = nil) -> Any {
        MKVSampleCursor(track: track, byteReader: byteReader, sampleIndex: sampleIndex)
    }

    private var current: MKVSampleModel {
        track.samples[sampleIndex]
    }

    var presentationTimeStamp: CMTime { current.pts }
    var decodeTimeStamp: CMTime { current.dts }
    var currentSampleDuration: CMTime { current.duration }
    var currentSampleFormatDescription: CMFormatDescription? { nil }
}
```

### Required stepping methods

Count-based stepping:

```swift
func stepInDecodeOrder(
    by stepCount: Int64,
    completionHandler: @escaping @Sendable (Int64, (any Error)?) -> Void
) {
    let original = sampleIndex
    let requested = sampleIndex + Int(stepCount)
    sampleIndex = min(max(0, requested), track.samples.count - 1)
    completionHandler(Int64(sampleIndex - original), nil)
}
```

PTS seek:

```swift
func stepByPresentationTime(
    _ deltaPresentationTime: CMTime,
    completionHandler: @escaping @Sendable (CMTime, Bool, (any Error)?) -> Void
) {
    let target = current.pts + deltaPresentationTime
    let newIndex = nearestSampleIndex(atOrBeforePTS: target)
    let pinned = (newIndex == 0 || newIndex == track.samples.count - 1) && track.samples[newIndex].pts != target
    sampleIndex = newIndex
    completionHandler(track.samples[newIndex].pts, pinned, nil)
}
```

Cursor generation by PTS:

```swift
func generateSampleCursor(
    atPresentationTimeStamp presentationTimeStamp: CMTime,
    completionHandler: @escaping @Sendable ((any MESampleCursor)?, (any Error)?) -> Void
) {
    let index = nearestSampleIndex(atOrBeforePTS: presentationTimeStamp)
    completionHandler(MKVSampleCursor(track: track, byteReader: parent.byteReader, sampleIndex: index), nil)
}
```

### Sync and dependency info

Do not skip this. Scrubbing quality depends on it.

Example:

```swift
var syncInfo: AVSampleCursorSyncInfo {
    AVSampleCursorSyncInfo(
        sampleIsFullSync: ObjCBool(current.isKeyframe),
        sampleIsPartialSync: false,
        sampleIsDroppable: false
    )
}

var dependencyInfo: AVSampleCursorDependencyInfo {
    AVSampleCursorDependencyInfo(
        sampleIndicatesWhetherItHasDependentSamples: true,
        sampleHasDependentSamples: ObjCBool(current.isKeyframe),
        sampleIndicatesWhetherItDependsOnOthers: true,
        sampleDependsOnOthers: ObjCBool(current.dependsOnOthers),
        sampleIndicatesWhetherItHasRedundantCoding: false,
        sampleHasRedundantCoding: false
    )
}
```

---

## Sample Delivery Strategies

Apple's own `MEFormatReader.h` effectively gives you three models.

### Strategy 1: direct sample location

Use when each sample is available as a single contiguous byte range.

Implement:

- `sampleLocationReturningError:`
- optionally `chunkDetailsReturningError:`

Best for:

- simple containers
- un-laced data
- files where your index records exact byte offsets

### Strategy 2: estimated + refined location

Use when you can cheaply find an approximate region, then refine it.

Implement:

- `estimatedSampleLocationReturningError:`
- `refineSampleLocation:...`

Best for:

- formats where exact location requires a secondary parse
- large interleaved chunks with local indexing

### Strategy 3: direct sample-buffer delivery

Use when CoreMedia cannot read the sample directly from one contiguous file range.

Implement:

- `loadSampleBufferContainingSamplesToEndCursor:completionHandler:`

Best for:

- laced MKV blocks
- decompressed audio output
- synthesized samples
- cases where you need to unpack or reorder before delivery

### What usually works best for MKV

For MKV, a hybrid is the pragmatic answer:

- use `sampleLocation` for simple contiguous samples
- return `MEErrorLocationNotAvailable` for laced / non-contiguous / synthesized cases
- fall back to `loadSampleBufferContainingSamplesToEndCursor`

That is also exactly how Apple describes the intended contract in the header comments.

### Example: location path

```swift
func sampleLocation() throws -> MESampleLocation {
    guard current.laceCount <= 1 else {
        throw MEError(.locationNotAvailable)
    }

    let range = AVSampleCursorStorageRange(offset: current.byteOffset, length: current.byteLength)
    return MESampleLocation(byteSource: byteReader.byteSource, sampleLocation: range)
}
```

### Example: chunk path

```swift
func chunkDetails() throws -> MESampleCursorChunk {
    guard current.laceCount <= 1 else {
        throw MEError(.locationNotAvailable)
    }

    var info = AVSampleCursorChunkInfo()
    info.chunkSampleCount = 1
    info.chunkHasUniformSampleSizes = false
    info.chunkHasUniformSampleDurations = false
    info.chunkHasUniformFormatDescriptions = true

    let range = AVSampleCursorStorageRange(offset: current.clusterOffset, length: current.byteLength)
    return MESampleCursorChunk(
        byteSource: byteReader.byteSource,
        chunkStorageRange: range,
        chunkInfo: info,
        sampleIndexWithinChunk: 0
    )
}
```

### Example: direct sample-buffer path

```swift
func loadSampleBufferContainingSamples(
    to endSampleCursor: (any MESampleCursor)?,
    completionHandler: @escaping (CMSampleBuffer?, (any Error)?) -> Void
) {
    do {
        let payload = try readCurrentSamplePayload()
        var blockBuffer: CMBlockBuffer?
        let status1 = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status1 == noErr, let blockBuffer else {
            return completionHandler(nil, NSError(domain: NSOSStatusErrorDomain, code: Int(status1)))
        }

        let status2 = CMBlockBufferReplaceDataBytes(
            with: (payload as NSData).bytes,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: payload.count
        )
        guard status2 == noErr else {
            return completionHandler(nil, NSError(domain: NSOSStatusErrorDomain, code: Int(status2)))
        }

        var timing = CMSampleTimingInfo(
            duration: current.duration,
            presentationTimeStamp: current.pts,
            decodeTimeStamp: current.dts
        )

        var sampleBuffer: CMSampleBuffer?
        let status3 = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: currentSampleFormatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status3 == noErr else {
            return completionHandler(nil, NSError(domain: NSOSStatusErrorDomain, code: Int(status3)))
        }

        completionHandler(sampleBuffer, nil)
    } catch {
        completionHandler(nil, error)
    }
}
```

For audio, you may return one buffer containing multiple samples or frames.

---

## MKV-Specific Parsing and Indexing

This is where a real MKV implementation differs from a generic "FFmpeg wrapped in MediaExtension".

### 1. EBML reader

You need an EBML reader that can:

- read variable-length IDs and sizes
- skip unknown elements safely
- preserve absolute file offsets
- support incremental or range-based reading

Suggested interface:

```swift
protocol EBMLReader {
    func readElementHeader(at offset: Int64) throws -> EBMLElementHeader
    func readData(at offset: Int64, length: Int) throws -> Data
    func scanChildren(of parent: EBMLRegion) throws -> [EBMLElement]
}
```

### 2. Track table

For each `TrackEntry`, parse at least:

- `TrackNumber`
- `TrackUID`
- `TrackType`
- `CodecID`
- `CodecPrivate`
- `Language`
- `FlagDefault`
- video dimensions
- audio sample rate and channels

Map Matroska track types roughly as:

| Matroska | CoreMedia |
|---|---|
| video | `kCMMediaType_Video` |
| audio | `kCMMediaType_Audio` |
| subtitles | `kCMMediaType_Subtitle` |
| attachments | not a playback track |

### 3. Timebase

Matroska uses a segment timecode scale, commonly `1000000` ns.

Your sample times should be normalized into `CMTime` once, not recomputed ad hoc in every cursor:

```swift
func makeCMTime(clusterTimecode: Int64, relativeBlockTimecode: Int16, timecodeScale: Int64) -> CMTime {
    let ns = (clusterTimecode + Int64(relativeBlockTimecode)) * timecodeScale
    return CMTime(value: ns, timescale: 1_000_000_000)
}
```

### 4. Cues

Parse `Cues` if present.

Use them to:

- jump to the nearest cluster before a target time
- avoid linear scans on random seek
- identify efficient pre-roll points for keyframe-based video seeking

If `Cues` are missing:

- build your own index once
- optionally persist it as a sidecar

### 5. Lacing

You cannot ignore lacing.

Matroska blocks may contain multiple frames:

- Xiph lacing
- EBML lacing
- fixed-size lacing

For laced blocks:

- one block may represent multiple logical samples
- direct `sampleLocation` often stops being a good fit
- direct `loadSampleBufferContainingSamplesToEndCursor` is usually easier

### 6. Block vs BlockGroup

Handle both:

- `SimpleBlock`
- `BlockGroup`

`BlockGroup` can carry:

- explicit `BlockDuration`
- references
- discard padding

You need that information for:

- accurate duration
- keyframe / dependency flags
- gapless audio correctness

---

## Metadata, Attachments, Chapters, and Sidecars

### File tags

Map `Tags` to `AVMetadataItem`s where possible.

Not every Matroska tag belongs in the file-level metadata array. Prefer:

- title
- artist
- album
- comment
- creation / writing app

### Attachments

Matroska attachments may include:

- cover art
- fonts for subtitles
- arbitrary blobs

Recommended behavior:

- expose cover art as common artwork metadata
- do not turn attachments into playback tracks
- only advertise related attachment sidecars if your reader can actually access them

### Chapters

Chapters are useful for media players and possibly import metadata, but not required for
first-pass playback support.

Treat them as optional metadata in v1.

### Sidecar index files

Apple added `MEFileInfo.sidecarFileName` and `MEByteSource.byteSourceForRelatedFileName:error:`
for a reason.

For MKV, a sidecar index can be extremely useful:

- store cue-like seek tables when original file has poor indexing
- cache expensive cluster scans
- persist derived codec-private or sample maps

Example strategy:

```text
movie.mkv
movie.mkv.mkvindex
```

The sidecar must:

- live in the same directory
- use an extension declared in your extension bundle
- be treated as advisory, never authoritative if stale

---

## FCP-Specific Behavior and Gotchas

This section is the difference between "opens in a toy player" and "survives Final Cut Pro".

### 1. Container support is not codec support

If FCP can parse the container but cannot decode the codec, import still fails or behaves badly.

Practical cases:

- MKV + H.264 + AAC: format reader may be enough
- MKV + HEVC: usually okay if you can build `hvcC`
- MKV + VP9 / AV1 / older MPEG-4 variants: often need companion decoder support
- MKV + Vorbis / Opus: audio may need decode-in-extension path or a decoder strategy

### 2. FCP will seek aggressively

Expect:

- first sample
- last sample
- near arbitrary PTS
- repeated cursor creation
- audio stepping in large bursts

Your cursor path cannot assume linear playback.

### 3. `trackID` cannot be zero

This sounds trivial but breaks reader implementations surprisingly often.

### 4. PTS matters more than you think

If your format does not naturally expose stable PTS values, synthesize them before CoreMedia sees
the track. `QuickLookVideo` explicitly turns on `AVFMT_FLAG_GENPTS` for this reason.

### 5. `sampleLocation` is optional for a reason

Do not force direct byte-range delivery if the sample model does not fit it.

For MKV, use `MEErrorLocationNotAvailable` when:

- the block is laced
- the payload spans multiple discontiguous reads
- you need decode / unpack / metadata synthesis first

### 6. Audio and video need different cursor strategies

Video is usually easy to represent as one compressed sample per packet.

Audio is not:

- variable packet durations
- planar vs interleaved decoded PCM
- large multi-packet delivery
- gapless / discard padding details

It is common to have:

- passthrough cursor for system-decodable audio
- decoded cursor for unsupported or awkward audio formats

### 7. Last-sample semantics matter

The more complete `QuickLookVideo` implementation explicitly precomputes last packets because the
host asks for them and because that request can otherwise disturb demux state.

For an index-backed native parser, make `last sample` trivial:

- store `track.samples.last`
- build a cursor with `sampleIndex = samples.count - 1`

### 8. Keep the parser and cursor separate

If your cursor has to re-parse the file on every step or seek, FCP scrubbing will suffer badly.

---

## Testing Strategy

Do not start in FCP.

Use a staged test plan.

### Stage 1: standalone AVFoundation host

Build a tiny app that:

- calls `MTRegisterProfessionalVideoWorkflowFormatReaders()`
- optionally calls `VTRegisterProfessionalVideoWorkflowVideoDecoders()`
- opens an `AVPlayerItem` from an MKV
- logs track info and playback status

This is the fastest loop for:

- bundle discovery
- parser correctness
- metadata shape
- format-description issues

### Stage 2: asset inspection

Write a test harness that exercises:

- `loadFileInfo`
- `loadMetadata`
- `loadTrackReaders`
- cursor creation at first / last / arbitrary PTS
- stepping
- sample delivery

### Stage 3: FCP import and playback

Test in FCP with:

- H.264/AAC MKV
- HEVC MKV
- VP9 WebM
- AV1 WebM
- Opus audio
- laced audio blocks
- files with no cues
- files with attachments and cover art

Validate:

- import works
- skimming works
- timeline thumbnails work
- audio/video stay in sync
- seeking does not explode

### Stage 4: negative tests

Deliberately test:

- malformed EBML sizes
- broken cues
- unsupported codec IDs
- missing codec private data
- huge files
- sparse seek patterns

---

## Troubleshooting

### The extension is not discovered

Check:

- correct extension point: `com.apple.mediaextension.formatreader`
- correct principal class
- format-reader entitlement present
- host called `MTRegisterProfessionalVideoWorkflowFormatReaders()`
- UTTypes conform to `com.apple.mediaextension-content` / `public.movie`

### The file is recognized but playback fails

Usually one of:

- wrong `CMFormatDescription`
- missing codec-private atom (`avcC`, `hvcC`, `av1C`, `vpcC`, `esds`)
- unsupported codec without decoder fallback
- wrong sample timing

### Seeking is broken

Usually one of:

- no cue/index table
- PTS vs DTS mixup
- sample ordinals built from decode order but queried by presentation order
- cursor stepping reparses and loses state

### Audio imports but does not play

Usually one of:

- bad `AudioStreamBasicDescription`
- incorrect channel layout
- planar PCM delivered where CoreMedia expects packed data
- compressed audio delivered through the wrong sample-buffer path

### Video frame order is wrong

Check:

- `requiresFrameReordering`
- PTS / DTS mapping
- keyframe / dependency flags

### `sampleLocation` crashes or is ignored

Remember:

- return `MEErrorLocationNotAvailable` for non-contiguous cases
- if you expose `sampleLocation`, the byte range must really correspond to the sample
- for laced blocks, use sample-buffer delivery instead

---

## Implementation Checklist

### Bundle and signing

- [ ] container app builds and signs
- [ ] `Reader.appex` builds and signs
- [ ] format-reader entitlement present
- [ ] plist declares `com.apple.mediaextension.formatreader`
- [ ] supported extensions and UTTypes declared

### Reader

- [ ] factory creates reader from `MEByteSource`
- [ ] `loadFileInfo` returns correct duration
- [ ] `loadMetadata` returns file metadata
- [ ] `loadTrackReaders` returns only usable tracks

### Track readers

- [ ] non-zero unique `trackID`
- [ ] correct `mediaType`
- [ ] correct `CMFormatDescription`
- [ ] `naturalTimescale` set
- [ ] language tag set when available
- [ ] frame rate and reordering set for video

### Sample cursor

- [ ] first / last / arbitrary PTS cursor generation works
- [ ] decode-order stepping works
- [ ] presentation-order stepping works
- [ ] sync info populated
- [ ] dependency info populated
- [ ] direct location path works for simple samples
- [ ] sample-buffer path works for complex samples

### MKV specifics

- [ ] EBML parser handles unknown elements
- [ ] tracks parsed correctly
- [ ] clusters parsed correctly
- [ ] cues parsed or generated
- [ ] lacing handled
- [ ] codec private data parsed
- [ ] attachments mapped appropriately

### Host validation

- [ ] standalone AVFoundation host works
- [ ] FCP import works
- [ ] scrubbing works
- [ ] thumbnails work
- [ ] unsupported codecs fail cleanly

---

## Reference Files

Apple SDK surface:

- `MediaExtension.framework/Headers/MEFormatReader.h`
- `MediaExtension.framework/Headers/MEError.h`
- `MediaToolbox.framework/Headers/MTProfessionalVideoWorkflow.h`
- `VideoToolbox.framework/Headers/VTProfessionalVideoWorkflow.h`

Local reference implementations:

- `FFMPEGMediaExtension/README.md`
- `FFMPEGMediaExtension/LibAVExtension/Info.plist`
- `FFMPEGMediaExtension/LibAVExtension/LibAVFormatReaderFactory.m`
- `FFMPEGMediaExtension/LibAVExtension/LibAVFormatReader.m`
- `FFMPEGMediaExtension/LibAVExtension/LibAVTrackReader.m`
- `FFMPEGMediaExtension/LibAVExtension/LibAVSampleCursor.m`
- `QuickLookVideo/formatreader/Info.plist`
- `QuickLookVideo/formatreader/formatreaderfactory.swift`
- `QuickLookVideo/formatreader/formatreader.swift`
- `QuickLookVideo/formatreader/trackreader.swift`
- `QuickLookVideo/formatreader/videotrackreader.swift`
- `QuickLookVideo/formatreader/audiotrackreader.swift`
- `QuickLookVideo/formatreader/samplecursor.swift`
- `QuickLookVideo/formatreader/packetdemuxer.swift`
- `QuickLookVideo/formatreader/callbacks.m`
- `QuickLookVideo/simpleplayer/simpleplayer.swift`

Observed production structure:

- `VidCore.app/Contents/Extensions/Reader.appex/Contents/Info.plist`
- `VidCore.app/Contents/Extensions/Reader.appex/Contents/Frameworks/MKV.framework/Versions/A/Resources/Info.plist`
- shipped symbols:
  - `MKVFormatReaderFactory`
  - `MKVFormatReader`
  - `MKVTrackReader`
  - `MKVSampleCursor`
  - `IndexingCoordinator`
  - `CoordinatorProbeScheduler`
  - `EBMLReader`
  - `EBMLStreamingRangeReader`
  - `MKVUnifiedIndexer`
  - `MKVIndexingOperation`
  - `MKVTrackModel`
  - `MKVSampleModel`
  - `MKVFileByteSource`

---

## Final Advice

If the goal is "MKV support in FCP", do not start by writing an `MESampleCursor`.

Build in this order:

1. parser and index model
2. `loadFileInfo`
3. `loadTrackReaders`
4. `CMFormatDescription` creation
5. index-backed cursor navigation
6. sample delivery
7. only then codec fallback / decoder extension work

The reader succeeds or fails on the quality of its index and format descriptions.
Everything else is downstream of that.
