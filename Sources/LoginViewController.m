//
//  LoginViewController.m
//  热水器蓝牙 —— 登录页
//
//  两种登录方式：
//    · 密码登录    —— 手机号 + 密码
//    · 验证码登录  —— 手机号 + 短信验证码（未注册的手机号会自动注册）
//

#import "LoginViewController.h"
#import "KRWMClient.h"
#import "ProbeViewController.h"

@interface LoginViewController () <UITextFieldDelegate>

@property (nonatomic, strong) UISegmentedControl *modeControl;
@property (nonatomic, strong) UITextField *phoneField;
@property (nonatomic, strong) UITextField *passwordField;
@property (nonatomic, strong) UITextField *codeField;
@property (nonatomic, strong) UIButton *sendCodeButton;
@property (nonatomic, strong) UIButton *loginButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIStackView *codeRow;

@property (nonatomic, strong) NSTimer *countdownTimer;
@property (nonatomic, assign) NSInteger countdown;

@end

@implementation LoginViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"登录";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // 保留只读探针作为调试入口：万一客户端行为异常，可以用它把原始报文捞出来
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"探针" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(onProbe)];

    [self setupUI];
    [self onModeChanged];
}

- (void)onProbe {
    [self.navigationController pushViewController:[[ProbeViewController alloc] init] animated:YES];
}

- (void)dealloc {
    [self.countdownTimer invalidate];
}

#pragma mark - UI

- (void)setupUI {
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"趣智校园 · 热水";
    titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    titleLabel.textAlignment = NSTextAlignmentCenter;

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = @"使用你的校园账号登录";
    subtitleLabel.font = [UIFont systemFontOfSize:14];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.textAlignment = NSTextAlignmentCenter;

    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"密码登录", @"验证码登录"]];
    self.modeControl.selectedSegmentIndex = 0;
    [self.modeControl addTarget:self action:@selector(onModeChanged)
               forControlEvents:UIControlEventValueChanged];

    self.phoneField = [self makeField:@"手机号" secure:NO];
    self.phoneField.keyboardType = UIKeyboardTypeNumberPad;
    self.phoneField.textContentType = UITextContentTypeTelephoneNumber;

    self.passwordField = [self makeField:@"密码" secure:YES];

    self.codeField = [self makeField:@"短信验证码" secure:NO];
    self.codeField.keyboardType = UIKeyboardTypeNumberPad;
    self.codeField.textContentType = UITextContentTypeOneTimeCode;

    self.sendCodeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sendCodeButton setTitle:@"获取验证码" forState:UIControlStateNormal];
    self.sendCodeButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.sendCodeButton.backgroundColor = [UIColor tertiarySystemFillColor];
    self.sendCodeButton.layer.cornerRadius = 8;
    [self.sendCodeButton addTarget:self action:@selector(onSendCode)
                  forControlEvents:UIControlEventTouchUpInside];

    self.codeRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.codeField, self.sendCodeButton]];
    self.codeRow.axis = UILayoutConstraintAxisHorizontal;
    self.codeRow.spacing = 10;
    self.codeRow.alignment = UIStackViewAlignmentFill;
    [self.sendCodeButton.widthAnchor constraintEqualToConstant:110].active = YES;

    self.loginButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.loginButton setTitle:@"登 录" forState:UIControlStateNormal];
    [self.loginButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.loginButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.loginButton.backgroundColor = [UIColor systemBlueColor];
    self.loginButton.layer.cornerRadius = 10;
    [self.loginButton addTarget:self action:@selector(onLogin) forControlEvents:UIControlEventTouchUpInside];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        titleLabel, subtitleLabel,
        self.modeControl,
        self.phoneField, self.passwordField, self.codeRow,
        self.loginButton, self.spinner, self.statusLabel
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.alignment = UIStackViewAlignmentFill;
    [stack setCustomSpacing:24 afterView:subtitleLabel];
    [stack setCustomSpacing:10 afterView:self.modeControl];
    [stack setCustomSpacing:8 afterView:self.loginButton];
    [self.view addSubview:stack];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:48],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:28],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-28],
        [self.phoneField.heightAnchor constraintEqualToConstant:46],
        [self.passwordField.heightAnchor constraintEqualToConstant:46],
        [self.codeRow.heightAnchor constraintEqualToConstant:46],
        [self.loginButton.heightAnchor constraintEqualToConstant:48],
    ]];
}

- (UITextField *)makeField:(NSString *)placeholder secure:(BOOL)secure {
    UITextField *f = [[UITextField alloc] init];
    f.placeholder = placeholder;
    f.secureTextEntry = secure;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.font = [UIFont systemFontOfSize:16];
    f.delegate = self;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    return f;
}

#pragma mark - 模式切换

- (void)onModeChanged {
    BOOL smsMode = (self.modeControl.selectedSegmentIndex == 1);

    self.passwordField.hidden = smsMode;
    self.codeRow.hidden = !smsMode;
    [self.loginButton setTitle:(smsMode ? @"登录 / 注册" : @"登 录") forState:UIControlStateNormal];

    if (smsMode) {
        [self setStatus:@"没注册过的手机号会自动注册" color:[UIColor secondaryLabelColor]];
    } else {
        [self setStatus:@"密码不会明文上传，本地按官方算法加密后再发送"
                 color:[UIColor secondaryLabelColor]];
    }
}

#pragma mark - 获取验证码

- (void)onSendCode {
    NSString *phone = [self trimmedPhone];
    if (phone.length != 11) {
        [self setStatus:@"请输入 11 位手机号" color:[UIColor systemRedColor]];
        return;
    }

    self.sendCodeButton.enabled = NO;
    [self.sendCodeButton setTitle:@"发送中…" forState:UIControlStateNormal];
    [self setStatus:@"正在发送验证码…" color:[UIColor secondaryLabelColor]];

    __weak typeof(self) ws = self;
    [[KRWMClient shared] sendSmsCodeToPhone:phone completion:^(BOOL ok, NSDictionary *data, NSString *message) {
        if (!ok) {
            [ws setStatus:(message.length ? message : @"验证码发送失败")
                    color:[UIColor systemRedColor]];
            [ws updateSendCodeButton];
            return;
        }
        [ws setStatus:@"验证码已发送，请查看短信" color:[UIColor systemGreenColor]];
        [ws startCountdown];
    }];
}

- (void)startCountdown {
    [self.countdownTimer invalidate];
    self.countdown = 60;
    [self updateSendCodeButton];

    __weak typeof(self) ws = self;
    self.countdownTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        ws.countdown -= 1;
        [ws updateSendCodeButton];
        if (ws.countdown <= 0) {
            [t invalidate];
            ws.countdownTimer = nil;
        }
    }];
}

- (void)updateSendCodeButton {
    if (self.countdown > 0) {
        self.sendCodeButton.enabled = NO;
        [self.sendCodeButton setTitle:[NSString stringWithFormat:@"%ld 秒", (long)self.countdown]
                             forState:UIControlStateNormal];
    } else {
        self.sendCodeButton.enabled = YES;
        [self.sendCodeButton setTitle:@"获取验证码" forState:UIControlStateNormal];
    }
}

#pragma mark - 登录

- (void)onLogin {
    NSString *phone = [self trimmedPhone];
    if (phone.length != 11) {
        [self setStatus:@"请输入 11 位手机号" color:[UIColor systemRedColor]];
        return;
    }

    BOOL smsMode = (self.modeControl.selectedSegmentIndex == 1);
    NSString *code = [self.codeField.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    NSString *password = self.passwordField.text ?: @"";

    if (smsMode && code.length == 0) {
        [self setStatus:@"请输入短信验证码" color:[UIColor systemRedColor]];
        return;
    }
    if (!smsMode && password.length == 0) {
        [self setStatus:@"请输入密码" color:[UIColor systemRedColor]];
        return;
    }

    [self setLoading:YES];
    [self setStatus:@"正在登录…" color:[UIColor secondaryLabelColor]];

    __weak typeof(self) ws = self;
    KRWMResponseHandler handler = ^(BOOL ok, NSDictionary *data, NSString *message) {
        [ws setLoading:NO];
        if (!ok) {
            [ws setStatus:(message.length ? message : @"登录失败") color:[UIColor systemRedColor]];
            return;
        }
        [ws setStatus:@"登录成功" color:[UIColor systemGreenColor]];
        if (ws.onLoginSuccess) ws.onLoginSuccess();
    };

    if (smsMode) {
        [[KRWMClient shared] loginWithPhone:phone smsCode:code completion:handler];
    } else {
        [[KRWMClient shared] loginWithPhone:phone password:password completion:handler];
    }
}

- (NSString *)trimmedPhone {
    NSString *text = self.phoneField.text ?: @"";
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)setLoading:(BOOL)loading {
    self.loginButton.enabled = !loading;
    self.loginButton.alpha = loading ? 0.5 : 1.0;
    if (loading) {
        [self.spinner startAnimating];
    } else {
        [self.spinner stopAnimating];
    }
}

- (void)setStatus:(NSString *)text color:(UIColor *)color {
    self.statusLabel.text = text;
    self.statusLabel.textColor = color;
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    if (textField == self.phoneField) {
        if (self.modeControl.selectedSegmentIndex == 1) {
            [self.codeField becomeFirstResponder];
        } else {
            [self.passwordField becomeFirstResponder];
        }
    } else {
        [self onLogin];
    }
    return YES;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.view endEditing:YES];
}

@end
