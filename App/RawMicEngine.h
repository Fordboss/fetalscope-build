#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol RawMicEngineDelegate <NSObject>
@optional
- (void)rawMicDidUpdateInputPeak:(float)inPeak
                      outputPeak:(float)outPeak
                            rms:(float)rms;
- (void)rawMicDidFailWithMessage:(NSString *)msg;
@end

/// 原始麦克风监听引擎
///
/// 设计约束（不要随便改，每一条都是需求）：
///   1. 不做任何降噪 / AGC / 语音处理 → AVAudioSessionModeMeasurement
///   2. 输入增益最高 20 倍，分两段：输入增益(1~20×) + 输出音量(0~100%)
///   3. 实时监听（耳机），带软限幅防削顶爆音
///   4. 录音写的是【增益之前】的原始样本，保证「原始声音」可回溯
///   5. 音频回调里只做浮点运算 + fwrite，绝不 seek / flush / 建对象以外的重活
///   6. 【没有任何滤波器】—— 高通/低通/陷波一律不提供，信号链只有增益和限幅
@interface RawMicEngine : NSObject

+ (instancetype)shared;

@property (nonatomic, weak, nullable) id<RawMicEngineDelegate> delegate;

/// 输入增益，1.0 ~ 20.0
@property (nonatomic, assign) float inputGain;
/// 输出音量，0.0 ~ 1.0（耳机里听多大）
@property (nonatomic, assign) float outputVolume;
/// 软限幅：开=好听不爆音，关=绝对原始但会削顶
@property (nonatomic, assign) BOOL softClip;

// ★ 不再提供任何滤波器。
//   曾经的「高通滤波」已彻底移除 —— 用户要的是不滤波的原始声音，
//   留一个可开的滤波开关本身就是隐患（手滑开了就以为听到的是原始信号）。
//   信号链现在是：麦克风 → ×增益 → 软限幅 → 耳机。仅此而已。

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) BOOL isRecording;
@property (nonatomic, readonly, nullable) NSURL *recordingURL;

/// 诊断信息（界面上显示，出问题时一眼看出跑在什么状态）
@property (nonatomic, readonly) double actualSampleRate;
@property (nonatomic, readonly) NSUInteger actualInputChannels;
@property (nonatomic, readonly) double ioBufferDuration;
@property (nonatomic, readonly) BOOL voiceProcessingEnabled;
@property (nonatomic, readonly, copy) NSString *currentInputName;
@property (nonatomic, readonly, copy) NSString *currentOutputName;
@property (nonatomic, readonly, copy) NSString *categoryModeDescription;
@property (nonatomic, readonly) NSUInteger callbackCount;
@property (nonatomic, readonly) NSUInteger droppedBuffers;

- (BOOL)startWithError:(NSError **)error;
- (void)stop;

/// 列出所有可用输入（比如内置麦克风 / 外接转接头麦克风），用于让用户选
- (NSArray<AVAudioSessionPortDescription *> *)availableInputs;
- (BOOL)selectInput:(AVAudioSessionPortDescription *)port error:(NSError **)error;

/// 录音：写原始（增益前）16-bit PCM WAV
- (BOOL)startRecordingWithError:(NSError **)error;
- (void)stopRecording;

/// 最近一段波形（0..1 的峰值包络），给波形视图画
- (void)copyWaveform:(float *)dst count:(NSUInteger)count;

+ (NSString *)documentsPath;

@end

NS_ASSUME_NONNULL_END
