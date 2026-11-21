#import "RawMicEngine.h"
#import <AudioToolbox/AudioToolbox.h>
#import <math.h>
#import <string.h>

// ============================================================
// 原始麦克风监听引擎
// ------------------------------------------------------------
// 需求定义（用户原话）：
//   「不做降噪处理的，直接听苹果手机 mic 的原始声音，最大放大到 20 倍」
//
// 对应的三个技术决定：
//   1. AVAudioSessionModeMeasurement —— iOS 关闭降噪/AGC/回声消除的官方开关。
//      用 Default / VoiceChat 模式，系统会偷偷做 AGC 和降噪，20 倍放大后声音完全变味。
//   2. 显式 setVoiceProcessingEnabled:NO —— iOS 13+ 的输入节点可能自带语音处理，
//      测量模式下也关掉它，确保拿到裸 PCM。
//   3. 增益放在【播放侧】而不是采集侧 —— 录音文件永远存增益前的原始样本，
//      这样「原始声音」可回溯、可验证。
//
// 线程模型（最重要）：
//   采集回调（实时线程）只做：混单声道 → 复制到环形缓冲 → 算峰值。
//   增益 / 限幅 / 写盘 / 送播放全在消费者队列。
//   绝不在采集回调里分配内存、加锁、做磁盘 IO。
// ============================================================

static const double kPreferredSampleRate = 48000.0;
static const double kPreferredIOBuffer   = 0.005;   // 5ms 低延迟
static const NSUInteger kRingSeconds     = 4;
static const NSUInteger kWaveformPoints  = 256;
static const NSUInteger kMonoScratch     = 8192;    // tap 单次最多处理的帧数

static void elog(NSString *fmt, ...);   // 前向声明

#pragma mark - 环形缓冲（单生产者单消费者，无锁）

typedef struct {
    float   *data;
    NSUInteger capacity;
    volatile NSUInteger writeIdx;
    volatile NSUInteger readIdx;
    volatile NSUInteger dropped;
} RingBuffer;

static void RingInit(RingBuffer *r, NSUInteger capacity) {
    r->data = (float *)calloc(capacity, sizeof(float));
    r->capacity = capacity;
    r->writeIdx = 0;
    r->readIdx = 0;
    r->dropped = 0;
}

static void RingFree(RingBuffer *r) {
    if (r->data) { free(r->data); r->data = NULL; }
    r->capacity = 0;
}

static void RingWrite(RingBuffer *r, const float *src, NSUInteger n) {
    if (!r->data || r->capacity == 0 || n == 0) return;
    NSUInteger w = r->writeIdx;
    NSUInteger rd = r->readIdx;
    NSUInteger used = (w + r->capacity - rd) % r->capacity;
    NSUInteger freeSlots = r->capacity - 1 - used;
    if (n > freeSlots) {
        r->dropped += (n - freeSlots);
        n = freeSlots;
    }
    if (n == 0) return;
    NSUInteger first = r->capacity - w;
    if (first > n) first = n;
    memcpy(r->data + w, src, first * sizeof(float));
    if (n > first) memcpy(r->data, src + first, (n - first) * sizeof(float));
    r->writeIdx = (w + n) % r->capacity;
}

static NSUInteger RingRead(RingBuffer *r, float *dst, NSUInteger maxN) {
    if (!r->data || r->capacity == 0) return 0;
    NSUInteger w = r->writeIdx;
    NSUInteger rd = r->readIdx;
    NSUInteger avail = (w + r->capacity - rd) % r->capacity;
    NSUInteger n = (avail < maxN) ? avail : maxN;
    if (n == 0) return 0;
    NSUInteger first = r->capacity - rd;
    if (first > n) first = n;
    memcpy(dst, r->data + rd, first * sizeof(float));
    if (n > first) memcpy(dst + first, r->data, (n - first) * sizeof(float));
    r->readIdx = (rd + n) % r->capacity;
    return n;
}

#pragma mark - 引擎

@interface RawMicEngine () {
    AVAudioEngine       *_engine;
    AVAudioInputNode    *_input;
    AVAudioPlayerNode   *_player;
    RingBuffer          _ring;

    dispatch_queue_t    _consumerQueue;
    dispatch_source_t   _consumerTimer;

    float              *_consumeBuf;      // 消费者临时缓冲
    float              *_monoScratch;     // 采集回调里混音用（预分配，回调里不 malloc）
    int16_t            *_s16Scratch;      // 写盘用
    AVAudioFormat      *_playFormat;

    // ★ 播放缓冲池：AVAudioPlayerNode 会持有 buffer 直到播完，
    //   所以绝不能复用同一个 buffer（会爆音/崩溃）。
    //   用一池子轮转，播完由 completionHandler 归还。
    NSMutableArray<AVAudioPCMBuffer *> *_playFree;   // 仅在 _consumerQueue 上访问
    NSUInteger          _playPoolSize;

    FILE               *_fp;
    UInt64              _rawFrames;
    UInt16              _rawChannels;
    NSString           *_recordPath;

    float               _waveform[kWaveformPoints];
    volatile NSUInteger _wavePos;
    volatile NSUInteger _cbCount;
    volatile NSUInteger _dropCount;
    volatile float      _inPeak;
    volatile float      _outPeak;
    volatile float      _rms;
    float               _lastReportedOutPeak;
    NSUInteger          _tick;
}

@property (nonatomic, readwrite) BOOL isRunning;
@property (nonatomic, readwrite) BOOL isRecording;
@property (nonatomic, readwrite, nullable) NSURL *recordingURL;
@property (nonatomic, readwrite) double actualSampleRate;
@property (nonatomic, readwrite) NSUInteger actualInputChannels;
@property (nonatomic, readwrite) double ioBufferDuration;
@property (nonatomic, readwrite) BOOL voiceProcessingEnabled;
@property (nonatomic, readwrite, copy) NSString *currentInputName;
@property (nonatomic, readwrite, copy) NSString *currentOutputName;
@property (nonatomic, readwrite, copy) NSString *categoryModeDescription;
@property (nonatomic, readwrite) NSUInteger callbackCount;
@property (nonatomic, readwrite) NSUInteger droppedBuffers;

@end

@implementation RawMicEngine

+ (instancetype)shared {
    static RawMicEngine *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [RawMicEngine new]; });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _inputGain = 1.0f;
        _outputVolume = 0.7f;
        _softClip = YES;
        _consumerQueue = dispatch_queue_create("com.wb.fetalscope.consumer", DISPATCH_QUEUE_SERIAL);
        memset(_waveform, 0, sizeof(_waveform));
        _monoScratch = (float *)calloc(kMonoScratch, sizeof(float));
        _s16Scratch = (int16_t *)calloc(kMonoScratch, sizeof(int16_t));
        _consumeBuf = (float *)calloc(kMonoScratch, sizeof(float));
    }
    return self;
}

+ (NSString *)documentsPath {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

#pragma mark - 输入设备

- (NSArray<AVAudioSessionPortDescription *> *)availableInputs {
    return AVAudioSession.sharedInstance.availableInputs ?: @[];
}

- (BOOL)selectInput:(AVAudioSessionPortDescription *)port error:(NSError **)error {
    AVAudioSession *s = AVAudioSession.sharedInstance;
    BOOL ok = [s setPreferredInput:port error:error];
    if (ok) self.currentInputName = port.portName;
    return ok;
}

#pragma mark - 会话配置（带降级链）

// 顺序尝试，第一个成功即用。Measurement 是我们的目标，但它在个别机型/蓝牙组合上会失败，
// 所以要有一级一级的退路，而不是直接启动不了。
- (BOOL)configureSession:(NSError **)error {
    AVAudioSession *s = AVAudioSession.sharedInstance;

    // AllowBluetooth 在 iOS 8 起就有了，新 SDK 会提示用 AllowBluetoothHFP 替代，
    // 但后者需要 iOS 13+，而我们的最低目标是 iOS 15，所以直接用新名字更干净。
    AVAudioSessionCategoryOptions baseOpts = AVAudioSessionCategoryOptionAllowBluetoothA2DP
                                           | AVAudioSessionCategoryOptionAllowBluetoothHFP;

    struct { AVAudioSessionCategory cat; AVAudioSessionMode mode;
             AVAudioSessionCategoryOptions opts; NSString *desc; } tries[] = {
        { AVAudioSessionCategoryPlayAndRecord, AVAudioSessionModeMeasurement, baseOpts,
          @"PlayAndRecord + Measurement（降噪已关）" },
        { AVAudioSessionCategoryPlayAndRecord, AVAudioSessionModeMeasurement,
          AVAudioSessionCategoryOptionAllowBluetoothA2DP,
          @"PlayAndRecord + Measurement（仅 A2DP）" },
        { AVAudioSessionCategoryPlayAndRecord, AVAudioSessionModeMeasurement,
          0,
          @"PlayAndRecord + Measurement（无蓝牙）" },
        { AVAudioSessionCategoryPlayAndRecord, AVAudioSessionModeDefault, baseOpts,
          @"⚠️ PlayAndRecord + Default（降噪未完全关闭）" },
    };

    NSError *lastErr = nil;
    for (size_t i = 0; i < sizeof(tries)/sizeof(tries[0]); i++) {
        NSError *e = nil;
        if ([s setCategory:tries[i].cat mode:tries[i].mode options:tries[i].opts error:&e]) {
            [s setPreferredSampleRate:kPreferredSampleRate error:nil];
            [s setPreferredIOBufferDuration:kPreferredIOBuffer error:nil];
            if ([s setActive:YES error:&e]) {
                self.categoryModeDescription = tries[i].desc;
                elog(@"会话: %@", tries[i].desc);
                return YES;
            }
        }
        lastErr = e ?: lastErr;
        elog(@"会话尝试失败[%zu]: %@", i, e.localizedDescription ?: @"?");
    }
    if (error) *error = lastErr ?: [NSError errorWithDomain:@"FetalScope" code:-10
                          userInfo:@{NSLocalizedDescriptionKey: @"音频会话激活失败"}];
    return NO;
}

#pragma mark - 启动

- (BOOL)startWithError:(NSError **)error {
    if (self.isRunning) return YES;

    if (![self configureSession:error]) return NO;

    AVAudioSession *session = AVAudioSession.sharedInstance;

    _engine = [[AVAudioEngine alloc] init];
    _input = _engine.inputNode;

    // ★ 关掉输入节点的语音处理（iOS 13+ 有可能默认开着）
    BOOL vpOn = NO;
    if ([_input respondsToSelector:@selector(isVoiceProcessingEnabled)] &&
        _input.isVoiceProcessingEnabled) {
        NSError *vpErr = nil;
        if ([_input setVoiceProcessingEnabled:NO error:&vpErr]) vpOn = NO;
        else { vpOn = YES; elog(@"⚠️ 关不掉语音处理: %@", vpErr.localizedDescription); }
    }
    self.voiceProcessingEnabled = vpOn;

    AVAudioFormat *inFormat = [_input outputFormatForBus:0];
    if (!inFormat || inFormat.sampleRate <= 0 || inFormat.channelCount == 0) {
        if (error) *error = [NSError errorWithDomain:@"FetalScope" code:-11
                          userInfo:@{NSLocalizedDescriptionKey: @"麦克风格式取不到（会话未激活？）"}];
        return NO;
    }

    elog(@"输入 %.0f Hz / %u ch", inFormat.sampleRate, (unsigned)inFormat.channelCount);

    self.actualSampleRate = inFormat.sampleRate;
    self.actualInputChannels = inFormat.channelCount;
    self.ioBufferDuration = session.IOBufferDuration;
    self.currentInputName = session.currentRoute.inputs.firstObject.portName ?: @"未知";
    self.currentOutputName = session.currentRoute.outputs.firstObject.portName ?: @"无";

    RingInit(&_ring, (NSUInteger)(inFormat.sampleRate * kRingSeconds) + 1024);

    // 播放节点
    _player = [[AVAudioPlayerNode alloc] init];
    [_engine attachNode:_player];
    _playFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                   sampleRate:inFormat.sampleRate
                                                     channels:1
                                                  interleaved:NO];
    [_engine connect:_player to:_engine.mainMixerNode format:_playFormat];
    _engine.mainMixerNode.outputVolume = self.outputVolume;

    // 播放缓冲池：8 个，每个 8192 帧（约 170ms @48k），足够覆盖任何抖动
    _playPoolSize = 8;
    _playFree = [NSMutableArray arrayWithCapacity:_playPoolSize];
    for (NSUInteger i = 0; i < _playPoolSize; i++) {
        AVAudioPCMBuffer *b = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_playFormat
                                                            frameCapacity:kMonoScratch];
        if (b) [_playFree addObject:b];
    }
    elog(@"播放缓冲池: %lu 个", (unsigned long)_playFree.count);

    __weak typeof(self) weakSelf = self;
    NSUInteger chCount = inFormat.channelCount;

    [_input installTapOnBus:0 bufferSize:1024 format:inFormat
                      block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        RawMicEngine *s = weakSelf;
        if (!s) return;

        float *const *ch = buf.floatChannelData;
        AVAudioFrameCount n = buf.frameLength;
        if (!ch || n == 0) return;

        float *mono = s->_monoScratch;
        AVAudioFrameCount m = (n > kMonoScratch) ? (AVAudioFrameCount)kMonoScratch : n;

        if (chCount == 1) {
            memcpy(mono, ch[0], m * sizeof(float));
        } else {
            float inv = 1.0f / (float)chCount;
            for (AVAudioFrameCount i = 0; i < m; i++) {
                float acc = 0;
                for (NSUInteger c = 0; c < chCount; c++) acc += ch[c][i];
                mono[i] = acc * inv;
            }
        }

        float peak = 0;
        double sq = 0;
        for (AVAudioFrameCount i = 0; i < m; i++) {
            float a = fabsf(mono[i]);
            if (a > peak) peak = a;
            sq += (double)mono[i] * (double)mono[i];
        }
        s->_inPeak = peak;
        s->_rms = (float)sqrt(sq / (double)m);
        s->_cbCount = s->_cbCount + 1;

        NSUInteger wp = s->_wavePos;
        s->_waveform[wp % kWaveformPoints] = peak;
        s->_wavePos = wp + 1;

        RingWrite(&s->_ring, mono, m);
    }];

    NSError *startErr = nil;
    if (![_engine startAndReturnError:&startErr]) {
        [_input removeTapOnBus:0];
        [session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        if (error) *error = startErr;
        return NO;
    }
    [_player play];

    self.isRunning = YES;
    self.callbackCount = 0;
    self.droppedBuffers = 0;
    [self startConsumer];

    elog(@"已启动 gain=%.1fx vol=%.2f clip=%d（无任何滤波）",
         self.inputGain, self.outputVolume, self.softClip);
    return YES;
}

#pragma mark - 消费者

- (void)startConsumer {
    if (_consumerTimer) return;
    _consumerTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _consumerQueue);
    uint64_t interval = (uint64_t)(5 * NSEC_PER_MSEC);
    dispatch_source_set_timer(_consumerTimer,
                              dispatch_time(DISPATCH_TIME_NOW, interval),
                              interval, NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_consumerTimer, ^{ [weakSelf consumeOnce]; });
    dispatch_resume(_consumerTimer);
}

- (void)consumeOnce {
    if (!_ring.data) return;

    NSUInteger got = RingRead(&_ring, _consumeBuf, kMonoScratch);
    if (got == 0) return;

    float gain = self.inputGain;
    if (gain < 1.0f) gain = 1.0f;
    if (gain > 20.0f) gain = 20.0f;

    // 录音：写增益之前的原始样本
    if (_fp) {
        NSUInteger m = (got > kMonoScratch) ? kMonoScratch : got;
        for (NSUInteger i = 0; i < m; i++) {
            float s = _consumeBuf[i];
            if (s > 1.0f) s = 1.0f;
            else if (s < -1.0f) s = -1.0f;
            _s16Scratch[i] = (int16_t)lrintf(s * 32767.0f);
        }
        fwrite(_s16Scratch, sizeof(int16_t), m, _fp);
        _rawFrames += m;
    }

    // 播放：增益 → 限幅。没有滤波器，这是用户明确要求的信号链
    float peakOut = 0;
    BOOL clipped = NO;
    for (NSUInteger i = 0; i < got; i++) {
        float s = _consumeBuf[i];
        s *= gain;
        if (self.softClip) {
            // x/sqrt(1+x²) 是 tanh 的快速近似：小信号近似线性，大信号平滑压缩
            s = s / sqrtf(1.0f + s * s);
        } else {
            if (s > 1.0f) { s = 1.0f; clipped = YES; }
            else if (s < -1.0f) { s = -1.0f; clipped = YES; }
        }
        _consumeBuf[i] = s;
        float a = fabsf(s);
        if (a > peakOut) peakOut = a;
    }
    _outPeak = peakOut;

    // 播放：从池里取一个空闲 buffer，填完送出，播完归还
    if (_player.isPlaying && _playFree.count > 0 && _playFormat) {
        AVAudioPCMBuffer *pcm = _playFree.firstObject;
        [_playFree removeObjectAtIndex:0];

        if ((NSUInteger)pcm.frameCapacity >= got) {
            pcm.frameLength = (AVAudioFrameCount)got;
            memcpy(pcm.floatChannelData[0], _consumeBuf, got * sizeof(float));
            __weak typeof(self) weakSelf = self;
            [_player scheduleBuffer:pcm completionHandler:^{
                // completionHandler 在播放线程，不能直接改 _playFree（那是消费者队列独占的）
                RawMicEngine *s = weakSelf;
                if (!s) return;
                dispatch_async(s->_consumerQueue, ^{
                    if (s->_playFree && s->_playFree.count < s->_playPoolSize) {
                        [s->_playFree addObject:pcm];
                    }
                });
            }];
        } else {
            [_playFree addObject:pcm];   // 尺寸不对，还回去
        }
    }

    // 每 200ms 汇报一次（5ms × 40）
    _tick++;
    if (_tick % 40 == 0) {
        _lastReportedOutPeak = peakOut;
        self.callbackCount = _cbCount;
        self.droppedBuffers = _ring.dropped;
        float ip = _inPeak, op = peakOut, rm = _rms;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            RawMicEngine *s = weakSelf;
            [s.delegate rawMicDidUpdateInputPeak:ip outputPeak:op rms:rm];
        });
    }
    (void)clipped;
}

#pragma mark - 停止

- (void)stop {
    if (!self.isRunning) return;

    if (_fp) [self stopRecording];

    if (_consumerTimer) {
        dispatch_source_cancel(_consumerTimer);
        _consumerTimer = nil;
    }
    dispatch_sync(_consumerQueue, ^{});   // 等当前一轮消费者跑完

    if (_input) [_input removeTapOnBus:0];
    if (_player) {
        [_player stop];
        [_engine detachNode:_player];
    }
    if (_engine) [_engine stop];

    _engine = nil;
    _input = nil;
    _player = nil;
    _playFormat = nil;
    _playFree = nil;

    RingFree(&_ring);

    [AVAudioSession.sharedInstance setActive:NO
                                 withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                       error:nil];
    self.isRunning = NO;
    elog(@"已停止");
}

#pragma mark - 录音

- (BOOL)startRecordingWithError:(NSError **)error {
    if (_fp) return YES;

    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *stamp = [f stringFromDate:[NSDate date]];
    NSString *dir = [RawMicEngine documentsPath];

    NSString *path = nil;
    FILE *fp = NULL;

    for (int n = 1; n <= 20 && !fp; n++) {
        NSString *name = (n == 1)
            ? [NSString stringWithFormat:@"raw_%@.wav", stamp]
            : [NSString stringWithFormat:@"raw_%@_%d.wav", stamp, n];
        NSString *cand = [dir stringByAppendingPathComponent:name];
        fp = fopen(cand.fileSystemRepresentation, "wbx");   // 独占创建，不覆盖
        if (fp) path = cand;
    }

    if (!fp) {
        if (error) *error = [NSError errorWithDomain:@"FetalScope" code:-20
                          userInfo:@{NSLocalizedDescriptionKey: @"录音文件创建失败"}];
        return NO;
    }

    _rawChannels = 1;
    _rawFrames = 0;
    [self writeWavHeaderTo:fp frames:0];

    _fp = fp;
    _recordPath = path;
    self.recordingURL = [NSURL fileURLWithPath:path];
    self.isRecording = YES;
    elog(@"开始录音(原始): %@", path.lastPathComponent);
    return YES;
}

// 只在停止时调用（消费者队列），绝不在音频回调里
- (void)writeWavHeaderTo:(FILE *)fp frames:(UInt64)frames {
    if (!fp) return;
    UInt32 rate = (UInt32)(_actualSampleRate > 0 ? _actualSampleRate : 48000);
    UInt16 ch = _rawChannels ? _rawChannels : 1;
    UInt32 dataBytes = (UInt32)(frames * ch * 2);
    UInt32 riffBytes = 36 + dataBytes;
    UInt32 byteRate = rate * ch * 2;
    UInt16 blockAlign = ch * 2;

    UInt8 h[44];
    memset(h, 0, sizeof(h));
    memcpy(h + 0, "RIFF", 4);
    h[4] = riffBytes & 0xff; h[5] = (riffBytes >> 8) & 0xff;
    h[6] = (riffBytes >> 16) & 0xff; h[7] = (riffBytes >> 24) & 0xff;
    memcpy(h + 8, "WAVEfmt ", 8);
    h[16] = 16;
    h[20] = 1;
    h[22] = ch & 0xff; h[23] = (ch >> 8) & 0xff;
    h[24] = rate & 0xff; h[25] = (rate >> 8) & 0xff;
    h[26] = (rate >> 16) & 0xff; h[27] = (rate >> 24) & 0xff;
    h[28] = byteRate & 0xff; h[29] = (byteRate >> 8) & 0xff;
    h[30] = (byteRate >> 16) & 0xff; h[31] = (byteRate >> 24) & 0xff;
    h[32] = blockAlign & 0xff; h[33] = (blockAlign >> 8) & 0xff;
    h[34] = 16;
    memcpy(h + 36, "data", 4);
    h[40] = dataBytes & 0xff; h[41] = (dataBytes >> 8) & 0xff;
    h[42] = (dataBytes >> 16) & 0xff; h[43] = (dataBytes >> 24) & 0xff;

    fseek(fp, 0, SEEK_SET);
    fwrite(h, 1, 44, fp);
}

- (void)stopRecording {
    if (!_fp) return;
    FILE *fp = _fp;
    _fp = NULL;

    [self writeWavHeaderTo:fp frames:_rawFrames];
    fflush(fp);
    fclose(fp);

    double secs = (double)_rawFrames / (_actualSampleRate > 0 ? _actualSampleRate : 48000.0);
    elog(@"录音结束: %.1f 秒, %llu 帧", secs, (unsigned long long)_rawFrames);
    self.isRecording = NO;
}

#pragma mark - 波形

- (void)copyWaveform:(float *)dst count:(NSUInteger)count {
    if (!dst || count == 0) return;
    NSUInteger pos = _wavePos;
    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger idx = (pos + kWaveformPoints - count + i) % kWaveformPoints;
        dst[i] = _waveform[idx];
    }
}

#pragma mark - setters

- (void)setOutputVolume:(float)v {
    if (v < 0) v = 0;
    if (v > 1) v = 1;
    _outputVolume = v;
    if (_engine) _engine.mainMixerNode.outputVolume = v;
}


#pragma mark - 日志

static void elog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], body];

    NSString *path = [[RawMicEngine documentsPath] stringByAppendingPathComponent:@"fetalscope.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) { }
    } else {
        [[line dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
    }
    NSLog(@"[FetalScope] %@", body);
}

@end
