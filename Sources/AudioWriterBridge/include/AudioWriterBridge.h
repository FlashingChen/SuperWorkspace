#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Converts AVFoundation configuration exceptions into recoverable errors.
FOUNDATION_EXPORT AVAssetWriterInput * _Nullable SWMakeAudioWriterInput(
    NSDictionary<NSString *, id> *settings,
    CMFormatDescriptionRef formatHint,
    NSError * _Nullable * _Nullable error
) NS_SWIFT_NAME(makeAudioWriterInput(settings:formatHint:error:));
NS_ASSUME_NONNULL_END
