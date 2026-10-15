//
//  WalletViewController.m
//  涌泉 —— 钱包：余额 / 水费记录
//
//  数据来自官方两个只读接口：
//    GET /account/wallet                    → 余额
//    GET /order/query/account/bill/list     → 账单（按月）
//
//  ⚠️ 充值不在这里做：官方充值走的是微信 / 支付宝支付，
//     第三方客户端拿不到支付能力，所以只做「余额 + 消费记录」的展示。
//

#import "WalletViewController.h"
#import "KRWMClient.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - 账单条目

@interface KRWMBillItem : NSObject
@property (nonatomic, copy) NSString *orderId;
/// 原始时间串。实测两种格式都出现过：`20261015204116` 与 `2026-10-15 20:41:16`
@property (nonatomic, copy) NSString *consumeDate;
@property (nonatomic, copy) NSString *consumeMoney;  // 元，字符串
@property (nonatomic, copy) NSString *desc;          // 如 "热水表-工程学院北区-C6-5层-506"
@end

@implementation KRWMBillItem
@end

#pragma mark - 账单行（两行：日期+金额 / 完整描述）

@interface KRWMBillCell : UITableViewCell
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UILabel *moneyLabel;
@property (nonatomic, strong) UILabel *descLabel;
@end

@implementation KRWMBillCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        _dateLabel = [[UILabel alloc] init];
        _dateLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
        _dateLabel.textColor = [UIColor secondaryLabelColor];

        _moneyLabel = [[UILabel alloc] init];
        _moneyLabel.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightSemibold];
        _moneyLabel.textColor = [UIColor labelColor];
        _moneyLabel.textAlignment = NSTextAlignmentRight;
        [_moneyLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_moneyLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                     forAxis:UILayoutConstraintAxisHorizontal];

        _descLabel = [[UILabel alloc] init];
        _descLabel.font = [UIFont systemFontOfSize:13];
        _descLabel.textColor = [UIColor labelColor];
        _descLabel.numberOfLines = 1;
        // 描述可能很长（如「热水表-工程学院北区-C6-5层-506」），缩字号而不是截断
        _descLabel.adjustsFontSizeToFitWidth = YES;
        _descLabel.minimumScaleFactor = 0.75;

        for (UILabel *l in @[_dateLabel, _moneyLabel, _descLabel]) {
            l.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:l];
        }

        UILayoutGuide *g = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_dateLabel.topAnchor constraintEqualToAnchor:g.topAnchor constant:10],
            [_dateLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],

            [_moneyLabel.centerYAnchor constraintEqualToAnchor:_dateLabel.centerYAnchor],
            [_moneyLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
            [_moneyLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_dateLabel.trailingAnchor
                                                                   constant:8],

            [_descLabel.topAnchor constraintEqualToAnchor:_dateLabel.bottomAnchor constant:4],
            [_descLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
            [_descLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
            [_descLabel.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-10],
        ]];
    }
    return self;
}

@end

#pragma mark - 小工具

static NSString *KRWMStr(id obj) {
    if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
    if ([obj isKindOfClass:[NSNumber class]]) return [(NSNumber *)obj stringValue];
    return @"";
}

/// 时间串 → "10-15 20:41"
///
/// 实测 `consumeDate` 两种写法都出现过：`20261015204116` 和 `2026-10-15 20:41:16`。
/// 所以先把数字全部提出来再切，两种都能吃。
static NSString *KRWMFormatBillDate(NSString *raw) {
    if (raw.length == 0) return @"—";

    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
    }
    if (digits.length < 12) return raw;

    return [NSString stringWithFormat:@"%@-%@ %@:%@",
            [digits substringWithRange:NSMakeRange(4, 2)],
            [digits substringWithRange:NSMakeRange(6, 2)],
            [digits substringWithRange:NSMakeRange(8, 2)],
            [digits substringWithRange:NSMakeRange(10, 2)]];
}

static NSArray<KRWMBillItem *> *KRWMParseBills(NSArray *raw) {
    NSMutableArray<KRWMBillItem *> *out = [NSMutableArray array];
    for (id obj in raw) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *dict = (NSDictionary *)obj;
        NSDictionary *dto = [dict[@"consumeBillDTO"] isKindOfClass:[NSDictionary class]]
                          ? dict[@"consumeBillDTO"] : dict;

        KRWMBillItem *item = [[KRWMBillItem alloc] init];
        item.orderId      = KRWMStr(dto[@"orderId"]);
        item.consumeDate  = KRWMStr(dto[@"consumeDate"]);
        item.consumeMoney = KRWMStr(dto[@"consumeMoney"]);
        item.desc         = KRWMStr(dto[@"description"]);
        [out addObject:item];
    }
    return out;
}

static NSString *KRWMMonthString(NSDate *date) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM";
    return [f stringFromDate:date];
}

#pragma mark -

@interface WalletViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *balanceLabel;
@property (nonatomic, strong) UILabel *givenLabel;
@property (nonatomic, strong) UILabel *monthLabel;
@property (nonatomic, strong) UILabel *monthStatLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

@property (nonatomic, strong) NSArray<KRWMBillItem *> *bills;
@property (nonatomic, copy)   NSString *currentMonth;

@end

@implementation WalletViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"钱包";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.currentMonth = KRWMMonthString([NSDate date]);

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"充值" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(onRecharge)];

    [self setupUI];
    [self rebuildHeader];

    [self loadWallet];
    [self loadBills];
}

#pragma mark - UI

- (void)setupUI {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = [UIColor systemBackgroundColor];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68;
    [self.tableView registerClass:[KRWMBillCell class] forCellReuseIdentifier:@"bill"];
    [self.view addSubview:self.tableView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],

        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

/// 统一的卡片外观：圆角、内边距一致，保证视觉对齐
- (UIView *)makeCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 14;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    return card;
}

- (UILabel *)makeLabel:(NSString *)text font:(UIFont *)font color:(UIColor *)color {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = font;
    l.textColor = color;
    return l;
}

- (void)rebuildHeader {
    CGFloat width = self.view.bounds.size.width;
    if (width <= 0) width = [UIScreen mainScreen].bounds.size.width;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 10)];

    // ── 余额卡片 ──
    UIView *balanceCard = [self makeCard];

    UILabel *balanceTitle = [self makeLabel:@"账户余额" font:[UIFont systemFontOfSize:13 weight:UIFontWeightMedium]
                                      color:[UIColor secondaryLabelColor]];
    self.balanceLabel = [self makeLabel:@"¥ --" font:[UIFont monospacedDigitSystemFontOfSize:34 weight:UIFontWeightBold]
                                  color:[UIColor labelColor]];
    self.givenLabel = [self makeLabel:@"赠送 ¥--" font:[UIFont systemFontOfSize:12]
                                color:[UIColor secondaryLabelColor]];

    for (UIView *v in @[balanceTitle, self.balanceLabel, self.givenLabel]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [balanceCard addSubview:v];
    }
    [NSLayoutConstraint activateConstraints:@[
        [balanceTitle.topAnchor constraintEqualToAnchor:balanceCard.topAnchor constant:16],
        [balanceTitle.leadingAnchor constraintEqualToAnchor:balanceCard.leadingAnchor constant:16],

        [self.balanceLabel.topAnchor constraintEqualToAnchor:balanceTitle.bottomAnchor constant:6],
        [self.balanceLabel.leadingAnchor constraintEqualToAnchor:balanceCard.leadingAnchor constant:16],
        [self.balanceLabel.trailingAnchor constraintEqualToAnchor:balanceCard.trailingAnchor constant:-16],

        [self.givenLabel.topAnchor constraintEqualToAnchor:self.balanceLabel.bottomAnchor constant:6],
        [self.givenLabel.leadingAnchor constraintEqualToAnchor:balanceCard.leadingAnchor constant:16],
        [self.givenLabel.bottomAnchor constraintEqualToAnchor:balanceCard.bottomAnchor constant:-16],
    ]];

    // ── 本月统计卡片 ──
    UIView *statCard = [self makeCard];

    UILabel *statTitle = [self makeLabel:@"本月消费" font:[UIFont systemFontOfSize:13 weight:UIFontWeightMedium]
                                   color:[UIColor secondaryLabelColor]];
    self.monthStatLabel = [self makeLabel:@"¥ --" font:[UIFont monospacedDigitSystemFontOfSize:22 weight:UIFontWeightSemibold]
                                    color:[UIColor labelColor]];

    UIButton *prev = [UIButton buttonWithType:UIButtonTypeSystem];
    [prev setTitle:@"◀" forState:UIControlStateNormal];
    prev.titleLabel.font = [UIFont systemFontOfSize:13];
    [prev addTarget:self action:@selector(onPrevMonth) forControlEvents:UIControlEventTouchUpInside];

    UIButton *next = [UIButton buttonWithType:UIButtonTypeSystem];
    [next setTitle:@"▶" forState:UIControlStateNormal];
    next.titleLabel.font = [UIFont systemFontOfSize:13];
    [next addTarget:self action:@selector(onNextMonth) forControlEvents:UIControlEventTouchUpInside];

    self.monthLabel = [self makeLabel:self.currentMonth
                                 font:[UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium]
                                color:[UIColor secondaryLabelColor]];
    self.monthLabel.textAlignment = NSTextAlignmentCenter;

    UIStackView *monthRow = [[UIStackView alloc] initWithArrangedSubviews:@[prev, self.monthLabel, next]];
    monthRow.axis = UILayoutConstraintAxisHorizontal;
    monthRow.alignment = UIStackViewAlignmentCenter;
    monthRow.spacing = 6;
    [self.monthLabel.widthAnchor constraintEqualToConstant:74].active = YES;

    for (UIView *v in @[statTitle, self.monthStatLabel, monthRow]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [statCard addSubview:v];
    }
    [NSLayoutConstraint activateConstraints:@[
        [statTitle.topAnchor constraintEqualToAnchor:statCard.topAnchor constant:16],
        [statTitle.leadingAnchor constraintEqualToAnchor:statCard.leadingAnchor constant:16],

        [self.monthStatLabel.topAnchor constraintEqualToAnchor:statTitle.bottomAnchor constant:6],
        [self.monthStatLabel.leadingAnchor constraintEqualToAnchor:statCard.leadingAnchor constant:16],

        [monthRow.centerYAnchor constraintEqualToAnchor:self.monthStatLabel.centerYAnchor],
        [monthRow.trailingAnchor constraintEqualToAnchor:statCard.trailingAnchor constant:-16],

        [self.monthStatLabel.bottomAnchor constraintEqualToAnchor:statCard.bottomAnchor constant:-16],
    ]];

    // ── 标题「水费记录」 ──
    UILabel *sectionTitle = [self makeLabel:@"水费记录" font:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]
                                      color:[UIColor labelColor]];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[balanceCard, statCard, sectionTitle]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.alignment = UIStackViewAlignmentFill;
    [stack setCustomSpacing:20 afterView:statCard];
    [header addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:header.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-8],
    ]];

    // tableHeaderView 必须给定明确高度
    CGSize size = [header systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                       withHorizontalFittingPriority:UILayoutPriorityRequired
                             verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    header.frame = CGRectMake(0, 0, width, size.height);
    self.tableView.tableHeaderView = header;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 宽度变化（旋转等）时重建 header，避免卡片宽度不同步
    UIView *header = self.tableView.tableHeaderView;
    if (header && fabs(header.frame.size.width - self.tableView.bounds.size.width) > 0.5) {
        [self rebuildHeader];
    }
}

#pragma mark - 数据

- (void)loadWallet {
    [self.spinner startAnimating];
    __weak typeof(self) ws = self;
    [[KRWMClient shared] loadWalletWithCompletion:^(BOOL ok, NSDictionary *data, NSString *message) {
        [ws.spinner stopAnimating];
        if (!ok || data == nil) {
            ws.balanceLabel.text = @"¥ --";
            ws.givenLabel.text = @"赠送 ¥--";
            return;
        }

        // ⚠️ `accountRealMoney` / `accountGivenMoney` 的单位是**厘**
        //    （55460 表示 55.46 元），必须优先用 `money` 字符串字段——它已经是元。
        NSString *moneyStr = KRWMStr(data[@"money"]);
        double yuan = moneyStr.length
            ? moneyStr.doubleValue
            : [KRWMStr(data[@"accountRealMoney"]) doubleValue] / 1000.0;
        double given = [KRWMStr(data[@"accountGivenMoney"]) doubleValue] / 1000.0;

        ws.balanceLabel.text = [NSString stringWithFormat:@"¥ %.2f", yuan];
        ws.givenLabel.text = [NSString stringWithFormat:@"赠送 ¥%.2f", given];
    }];
}

- (void)loadBills {
    [self.spinner startAnimating];
    __weak typeof(self) ws = self;
    [[KRWMClient shared] loadBillsForMonth:self.currentMonth
                                completion:^(BOOL ok, NSArray *list, NSString *message) {
        [ws.spinner stopAnimating];
        if (!ok) {
            ws.bills = @[];
            [ws setMonthStat:@"加载失败"];
            [ws.tableView reloadData];
            return;
        }
        ws.bills = KRWMParseBills(list);
        [ws updateMonthStat];
        [ws.tableView reloadData];
    }];
}

- (void)updateMonthStat {
    double total = 0;
    for (KRWMBillItem *item in self.bills) {
        total += item.consumeMoney.doubleValue;
    }
    self.monthStatLabel.text = [NSString stringWithFormat:@"¥ %.2f", total];
    self.monthLabel.text = self.currentMonth;
}

- (void)setMonthStat:(NSString *)text {
    self.monthStatLabel.text = text;
    self.monthLabel.text = self.currentMonth;
}

- (void)onPrevMonth {
    self.currentMonth = KRWMMonthString([self monthDateOffset:-1]);
    [self loadBills];
}

- (void)onNextMonth {
    self.currentMonth = KRWMMonthString([self monthDateOffset:1]);
    [self loadBills];
}

- (NSDate *)monthDateOffset:(NSInteger)months {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM";
    NSDate *base = [f dateFromString:self.currentMonth] ?: [NSDate date];
    NSDateComponents *comp = [[NSDateComponents alloc] init];
    comp.month = months;
    return [[NSCalendar currentCalendar] dateByAddingComponents:comp toDate:base options:0] ?: base;
}

#pragma mark - 充值

- (void)onRecharge {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"充值请走官方渠道"
        message:@"本客户端只读取余额与消费记录，不涉及支付。\n\n"
                 "充值请在「趣智校园」官方 App 或微信公众号里完成，"
                 "充完后回到本页即可看到新余额。"
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.bills.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.bills.count == 0) return @"本月没有消费记录";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    KRWMBillCell *cell = [tableView dequeueReusableCellWithIdentifier:@"bill" forIndexPath:indexPath];
    KRWMBillItem *item = self.bills[indexPath.row];

    cell.dateLabel.text = KRWMFormatBillDate(item.consumeDate);
    cell.moneyLabel.text = [NSString stringWithFormat:@"¥%@",
                            item.consumeMoney.length ? item.consumeMoney : @"0"];
    // 完整显示，不再截断——名字长时缩字号
    cell.descLabel.text = item.desc.length ? item.desc : @"—";
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

@end
