#import "MainViewController.h"
#import "RawMicEngine.h"
#import <AVFoundation/AVFoundation.h>

#pragma mark - 波形视图

@interface WaveView : UIView
@property (nonatomic, copy) NSArray<NSNumber *> *samples;
@end

@implementation WaveView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
        self.layer.cornerRadius = 12;
        self.layer.masksToBounds = YES;
        _samples = @[];
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGFloat w = CGRectGetWidth(rect);
    CGFloat h = CGRectGetHeight(rect);
    CGFloat mid = h / 2.0;

    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.22 alpha:1].CGColor);
    CGContextSetLineWidth(ctx, 0.5);
    CGContextMoveToPoint(ctx, 0, mid);
    CGContextAddLineToPoint(ctx, w, mid);
    CGContextStrokePath(ctx);

    NSUInteger n = self.samples.count;
    if (n < 2) return;

    CGFloat step = w / (CGFloat)(n - 1);
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.2 green:0.85 blue:0.6 alpha:1].CGColor);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextSetLineCap(ctx, kCGLineCapRound);

    for (NSUInteger i = 0; i < n; i++) {
        CGFloat v = self.samples[i].floatValue;
        // sqrt 压缩动态范围，微弱信号也看得见
        CGFloat amp = sqrtf(fminf(fmaxf(v, 0.0f), 1.0f)) * (mid - 3);
        CGFloat x = i * step;
        CGContextMoveToPoint(ctx, x, mid - amp);
        CGContextAddLineToPoint(ctx, x, mid + amp);
    }
    CGContextStrokePath(ctx);
}

@end

#pragma mark - 主界面

@interface MainViewController () <RawMicEngineDelegate> {
    float _waveBuf[256];
    CADisplayLink *_link;
}

@property (nonatomic, strong) WaveView *waveView;
@property (nonatomic, strong) UILabel *gainLabel;
@property (nonatomic, strong) UISlider *gainSlider;
@property (nonatomic, strong) UILabel *volLabel;
@property (nonatomic, strong) UISlider *volSlider;
@property (nonatomic, strong) UIButton *startButton;
@property (nonatomic, strong) UIButton *recButton;
@property (nonatomic, strong) UISwitch *clipSwitch;
@property (nonatomic, strong) UISwitch *hpSwitch;
@property (nonatomic, strong) UILabel *levelLabel;
@property (nonatomic, strong) UILabel *diagLabel;
@property (nonatomic, strong) UIButton *inputButton;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIVisualEffectView *levelBarBg;
@property (nonatomic, strong) UIView *levelBarFill;

@end

@implementation MainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"胎心监听";
    self.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];
    self.navigationController.navigationBar.barStyle = UIBarStyleBlack;
    self.navigationController.navigationBar.tintColor =
        [UIColor colorWithRed:0.2 green:0.85 blue:0.6 alpha:1];

    [self setupUI];
    [self requestMicPermission];
}

- (void)setupUI {
    CGFloat W = self.view.bounds.size.width;
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];

    CGFloat pad = 20;
    CGFloat w = W - pad * 2;
    CGFloat y = 14;

    // ---- 波形
    self.waveView = [[WaveView alloc] initWithFrame:CGRectMake(pad, y, w, 132)];
    [self.scrollView addSubview:self.waveView];
    y += 132 + 10;

    // ---- 电平条（图形化，比数字直观）
    self.levelBarBg = [[UIVisualEffectView alloc] initWithEffect:
                       [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    self.levelBarBg.frame = CGRectMake(pad, y, w, 8);
    self.levelBarBg.layer.cornerRadius = 4;
    self.levelBarBg.clipsToBounds = YES;
    [self.scrollView addSubview:self.levelBarBg];

    self.levelBarFill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 8)];
    self.levelBarFill.backgroundColor = [UIColor colorWithRed:0.2 green:0.85 blue:0.6 alpha:1];
    [self.levelBarBg.contentView addSubview:self.levelBarFill];
    y += 8 + 8;

    self.levelLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w, 20)];
    self.levelLabel.text = @"输入 —  输出 —";
    self.levelLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.levelLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    [self.scrollView addSubview:self.levelLabel];
    y += 20 + 18;

    // ---- 增益
    self.gainLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w, 34)];
    self.gainLabel.text = @"放大倍数  1.0×";
    self.gainLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
    self.gainLabel.textColor = [UIColor whiteColor];
    [self.scrollView addSubview:self.gainLabel];
    y += 34;

    self.gainSlider = [[UISlider alloc] initWithFrame:CGRectMake(pad, y, w, 44)];
    self.gainSlider.minimumValue = 0.0f;      // 0..1 映射到 1x..20x（对数）
    self.gainSlider.maximumValue = 1.0f;
    self.gainSlider.value = 0.0f;
    self.gainSlider.minimumTrackTintColor = [UIColor colorWithRed:0.2 green:0.85 blue:0.6 alpha:1];
    [self.gainSlider addTarget:self action:@selector(gainChanged:)
             forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.gainSlider];
    y += 44 + 4;

    // 刻度提示
    UILabel *scale = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w, 16)];
    scale.text = @"1×          3×        5×         10×              20×";
    scale.font = [UIFont systemFontOfSize:10 weight:UIFontWeightRegular];
    scale.textColor = [UIColor colorWithWhite:0.38 alpha:1];
    scale.textAlignment = NSTextAlignmentCenter;
    [self.scrollView addSubview:scale];
    y += 16 + 10;

    // 快捷倍数
    NSArray *presets = @[@"1×", @"3×", @"5×", @"10×", @"20×"];
    CGFloat pw = (w - 8 * 4) / 5.0;
    for (NSUInteger i = 0; i < presets.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(pad + i * (pw + 8), y, pw, 36);
        [b setTitle:presets[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        b.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1];
        b.layer.cornerRadius = 8;
        [b setTitleColor:[UIColor colorWithWhite:0.9 alpha:1] forState:UIControlStateNormal];
        b.tag = (NSInteger)i;
        [b addTarget:self action:@selector(presetTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [self.scrollView addSubview:b];
    }
    y += 36 + 24;

    // ---- 监听音量
    self.volLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w, 26)];
    self.volLabel.text = @"耳机音量  70%";
    self.volLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    self.volLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    [self.scrollView addSubview:self.volLabel];
    y += 26;

    self.volSlider = [[UISlider alloc] initWithFrame:CGRectMake(pad, y, w, 44)];
    self.volSlider.minimumValue = 0;
    self.volSlider.maximumValue = 1;
    self.volSlider.value = 0.7;
    self.volSlider.minimumTrackTintColor = [UIColor colorWithWhite:0.5 alpha:1];
    [self.volSlider addTarget:self action:@selector(volChanged:)
             forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.volSlider];
    y += 44 + 14;

    // ---- 开关
    self.clipSwitch = [self addSwitchRow:@"软限幅（防爆音）" on:YES y:&y pad:pad w:w];
    [self.clipSwitch addTarget:self action:@selector(clipToggled:)
              forControlEvents:UIControlEventValueChanged];
    self.clipSwitch.on = YES;

    self.hpSwitch = [self addSwitchRow:@"高通滤波（压低频轰鸣）" on:NO y:&y pad:pad w:w];
    [self.hpSwitch addTarget:self action:@selector(hpToggled:)
            forControlEvents:UIControlEventValueChanged];
    self.hpSwitch.on = NO;

    y += 6;

    // ---- 主按钮
    self.startButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.startButton.frame = CGRectMake(pad, y, w, 62);
    [self.startButton setTitle:@"开始监听" forState:UIControlStateNormal];
    self.startButton.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    self.startButton.backgroundColor = [UIColor colorWithRed:0.16 green:0.68 blue:0.44 alpha:1];
    [self.startButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.startButton.layer.cornerRadius = 14;
    [self.startButton addTarget:self action:@selector(startTapped)
               forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.startButton];
    y += 62 + 10;

    self.recButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.recButton.frame = CGRectMake(pad, y, w, 48);
    [self.recButton setTitle:@"录制原始音频" forState:UIControlStateNormal];
    self.recButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.recButton.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1];
    [self.recButton setTitleColor:[UIColor colorWithWhite:0.9 alpha:1] forState:UIControlStateNormal];
    self.recButton.layer.cornerRadius = 12;
    [self.recButton addTarget:self action:@selector(recTapped)
             forControlEvents:UIControlEventTouchUpInside];
    self.recButton.alpha = 0.4;
    [self.scrollView addSubview:self.recButton];
    y += 48 + 10;

    self.inputButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.inputButton.frame = CGRectMake(pad, y, w, 44);
    [self.inputButton setTitle:@"麦克风：默认" forState:UIControlStateNormal];
    self.inputButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    [self.inputButton setTitleColor:[UIColor colorWithWhite:0.7 alpha:1] forState:UIControlStateNormal];
    self.inputButton.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1];
    self.inputButton.layer.cornerRadius = 10;
    [self.inputButton addTarget:self action:@selector(inputTapped)
               forControlEvents:UIControlEventTouchUpInside];
    [self.scrollView addSubview:self.inputButton];
    y += 44 + 22;

    // ---- 诊断
    self.diagLabel = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w, 60)];
    self.diagLabel.numberOfLines = 0;
    self.diagLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.diagLabel.textColor = [UIColor colorWithWhite:0.42 alpha:1];
    self.diagLabel.text = @"尚未启动";
    [self.scrollView addSubview:self.diagLabel];
    y += 80;

    self.scrollView.contentSize = CGSizeMake(W, y);
}

- (UISwitch *)addSwitchRow:(NSString *)title on:(BOOL)on y:(CGFloat *)y pad:(CGFloat)pad w:(CGFloat)w {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(pad, *y, w - 64, 31)];
    l.text = title;
    l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    l.textColor = [UIColor colorWithWhite:0.7 alpha:1];
    [self.scrollView addSubview:l];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(pad + w - 51, *y, 51, 31)];
    sw.onTintColor = [UIColor colorWithRed:0.2 green:0.85 blue:0.6 alpha:1];
    sw.on = on;
    [self.scrollView addSubview:sw];

    *y += 40;
    return sw;
}

#pragma mark - 权限

- (void)requestMicPermission {
    void (^handler)(BOOL) = ^(BOOL granted) {
        if (!granted) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showPermissionAlert]; });
        }
    };
    if (@available(iOS 17.0, *)) {
        // iOS 17+ 的新 API：注意 selector 带 WithCompletionHandler 后缀
        [AVAudioApplication requestRecordPermissionWithCompletionHandler:handler];
    } else {
        [AVAudioSession.sharedInstance requestRecordPermission:handler];
    }
}

- (void)showPermissionAlert {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"没有麦克风权限"
                         message:@"请到「设置 → 胎心监听 → 麦克风」打开权限后再回来。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)showAlert:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 交互

// 滑块 0..1 → 增益 1..20（对数）。听感上每格幅度更均匀，也更容易停在 3x/5x 这种常用档
- (void)gainChanged:(UISlider *)s {
    float gain = powf(20.0f, s.value);
    RawMicEngine.shared.inputGain = gain;
    self.gainLabel.text = [NSString stringWithFormat:@"放大倍数  %.1f×", gain];
}

- (void)presetTapped:(UIButton *)b {
    float presets[] = {1.0f, 3.0f, 5.0f, 10.0f, 20.0f};
    float g = presets[b.tag];
    self.gainSlider.value = logf(g) / logf(20.0f);
    [self gainChanged:self.gainSlider];
}

- (void)volChanged:(UISlider *)s {
    RawMicEngine.shared.outputVolume = s.value;
    self.volLabel.text = [NSString stringWithFormat:@"耳机音量  %.0f%%", s.value * 100];
}

- (void)clipToggled:(UISwitch *)sw { RawMicEngine.shared.softClip = sw.isOn; }
- (void)hpToggled:(UISwitch *)sw   { RawMicEngine.shared.highPass = sw.isOn; }

- (void)startTapped {
    RawMicEngine *e = RawMicEngine.shared;
    if (e.isRunning) {
        [e stop];
        [self applyRunning:NO];
        return;
    }

    NSError *err = nil;
    if (![e startWithError:&err]) {
        [self showAlert:@"启动失败" message:err.localizedDescription ?: @"未知错误"];
        return;
    }
    e.delegate = self;
    [self applyRunning:YES];
    [self refreshDiag];

    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tickWave)];
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)applyRunning:(BOOL)running {
    if (running) {
        [self.startButton setTitle:@"停止监听" forState:UIControlStateNormal];
        self.startButton.backgroundColor = [UIColor colorWithRed:0.7 green:0.22 blue:0.22 alpha:1];
        self.recButton.enabled = YES;
        self.recButton.alpha = 1.0;
        self.inputButton.enabled = NO;
    } else {
        [self.startButton setTitle:@"开始监听" forState:UIControlStateNormal];
        self.startButton.backgroundColor = [UIColor colorWithRed:0.16 green:0.68 blue:0.44 alpha:1];
        self.recButton.enabled = NO;
        self.recButton.alpha = 0.4;
        self.inputButton.enabled = YES;
        [self.recButton setTitle:@"录制原始音频" forState:UIControlStateNormal];
        self.recButton.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1];
        [_link invalidate];
        _link = nil;
        [self clearWave];
        self.diagLabel.text = @"已停止";
    }
}

- (void)recTapped {
    RawMicEngine *e = RawMicEngine.shared;
    if (e.isRecording) {
        [e stopRecording];
        [self.recButton setTitle:@"录制原始音频" forState:UIControlStateNormal];
        self.recButton.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1];
        [self showAlert:@"录音已保存"
                message:[NSString stringWithFormat:
                    @"%@\n\n这是增益之前的原始音频。\n用「文件」App 进 App 目录可以导出。",
                    e.recordingURL.lastPathComponent ?: @""]];
        return;
    }

    NSError *err = nil;
    if (![e startRecordingWithError:&err]) {
        [self showAlert:@"录制失败" message:err.localizedDescription ?: @"未知错误"];
        return;
    }
    [self.recButton setTitle:@"停止录制" forState:UIControlStateNormal];
    self.recButton.backgroundColor = [UIColor colorWithRed:0.58 green:0.18 blue:0.18 alpha:1];
}

- (void)inputTapped {
    NSArray<AVAudioSessionPortDescription *> *inputs = [RawMicEngine.shared availableInputs];
    if (inputs.count == 0) {
        [self showAlert:@"没有可用麦克风" message:@"当前会话没有报告任何输入设备。"];
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择麦克风"
                                                                  message:@"外接麦克风需先插好"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (AVAudioSessionPortDescription *p in inputs) {
        NSString *t = [NSString stringWithFormat:@"%@（%@）", p.portName, p.portType];
        [sheet addAction:[UIAlertAction actionWithTitle:t
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            NSError *err = nil;
            if ([RawMicEngine.shared selectInput:p error:&err]) {
                [self.inputButton setTitle:[NSString stringWithFormat:@"麦克风：%@", p.portName]
                                  forState:UIControlStateNormal];
            } else {
                [self showAlert:@"切换失败" message:err.localizedDescription ?: @"未知错误"];
            }
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    sheet.popoverPresentationController.sourceView = self.inputButton;
    sheet.popoverPresentationController.sourceRect = self.inputButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 刷新

- (void)tickWave {
    RawMicEngine *e = RawMicEngine.shared;
    if (!e.isRunning) return;

    [e copyWaveform:_waveBuf count:256];
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:256];
    for (int i = 0; i < 256; i++) [arr addObject:@(_waveBuf[i])];
    self.waveView.samples = arr;
    [self.waveView setNeedsDisplay];
}

- (void)rawMicDidUpdateInputPeak:(float)inPeak outputPeak:(float)outPeak rms:(float)rms {
    float inDb = 20.0f * log10f(fmaxf(inPeak, 1e-6f));
    float outDb = 20.0f * log10f(fmaxf(outPeak, 1e-6f));

    self.levelLabel.text = [NSString stringWithFormat:@"输入 %.0f dB    输出 %.0f dB",
                            inDb, outDb];
    if (outDb > -1.0f) {
        self.levelLabel.textColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.3 alpha:1];
    } else {
        self.levelLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    }

    // 电平条：用输出 dB 映射，-60dB→0，0dB→满
    CGFloat frac = (outDb + 60.0f) / 60.0f;
    frac = fmaxf(0.0f, fminf(1.0f, frac));
    CGRect f = self.levelBarFill.frame;
    CGFloat full = self.levelBarBg.bounds.size.width;
    f.size.width = full * frac;
    self.levelBarFill.frame = f;
    self.levelBarFill.backgroundColor = (outDb > -1.0f)
        ? [UIColor colorWithRed:1.0 green:0.45 blue:0.3 alpha:1]
        : [UIColor colorWithRed:0.2 green:0.85 blue:0.6 alpha:1];

    [self refreshDiag];
}

- (void)refreshDiag {
    RawMicEngine *e = RawMicEngine.shared;
    if (!e.isRunning) return;

    NSString *vp = e.voiceProcessingEnabled ? @"⚠️ 系统语音处理未关掉" : @"系统处理已关闭";

    // 只换文字，不 sizeToFit —— 每 200ms 重排会导致界面抖动
    self.diagLabel.text = [NSString stringWithFormat:
        @"采样 %.0f Hz · %lu 通道 · 缓冲 %.1f ms\n"
        @"输入 %@\n输出 %@\n%@ · 回调 %lu · 丢帧 %lu",
        e.actualSampleRate,
        (unsigned long)e.actualInputChannels,
        e.ioBufferDuration * 1000.0,
        e.currentInputName,
        e.currentOutputName,
        vp,
        (unsigned long)e.callbackCount,
        (unsigned long)e.droppedBuffers];
}

- (void)clearWave {
    self.waveView.samples = @[];
    [self.waveView setNeedsDisplay];
    self.levelLabel.text = @"输入 —  输出 —";
    self.levelLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    CGRect f = self.levelBarFill.frame;
    f.size.width = 0;
    self.levelBarFill.frame = f;
}

@end
