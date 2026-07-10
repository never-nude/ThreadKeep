#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Decodes a legacy `streamtyped` archive (Messages `attributedBody`) using `NSUnarchiver`.
///
/// `NSUnarchiver.decodeObject` throws an Objective-C `NSException` on malformed input, which
/// Swift's `do/try/catch` cannot catch — an uncaught throw aborts the process. This shim wraps
/// the decode in `@try/@catch` so the caller can simply treat a `nil` result as "undecodable"
/// and skip the row instead of crashing.
///
/// - Returns: the decoded object, or `nil` if `NSUnarchiver` throws on malformed data.
id _Nullable TKTryUnarchive(NSData *data);

NS_ASSUME_NONNULL_END
