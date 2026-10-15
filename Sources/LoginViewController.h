//
//  LoginViewController.h
//  热水器蓝牙 —— 登录页
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface LoginViewController : UIViewController

/// 登录成功回调（由外部切换根控制器）
@property (nonatomic, copy, nullable) void (^onLoginSuccess)(void);

@end

NS_ASSUME_NONNULL_END
