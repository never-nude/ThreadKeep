#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Attempts to decode a legacy `streamtyped` (NSUnarchiver) archive.
///
/// `NSUnarchiver` raises an Objective-C `NSException` on malformed input, which Swift's
/// `do/try/catch` cannot intercept — an uncaught throw terminates the process. This shim wraps the
/// decode in `@try/@catch` so a single corrupt `attributedBody` row can be skipped instead of
/// crashing the whole import.
///
/// - Returns: the decoded object, or `nil` if the data is `nil`/empty or `NSUnarchiver` throws.
id _Nullable TKTryUnarchive(NSData *_Nullable data);

NS_ASSUME_NONNULL_END
