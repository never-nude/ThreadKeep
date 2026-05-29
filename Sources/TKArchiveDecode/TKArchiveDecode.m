#import "TKArchiveDecode.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

id _Nullable TKTryUnarchive(NSData *data) {
    if (data.length == 0) {
        return nil;
    }
    @try {
        return [NSUnarchiver unarchiveObjectWithData:data];
    }
    @catch (NSException *exception) {
        // Malformed/legacy archive: NSUnarchiver raised. Swallow so the caller skips the row.
        return nil;
    }
}

#pragma clang diagnostic pop
