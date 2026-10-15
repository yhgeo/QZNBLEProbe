//
//  AppDelegate.m
//  热水器蓝牙
//

#import "AppDelegate.h"
#import "LoginViewController.h"
#import "MainViewController.h"
#import "KRWMClient.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showLogin)
                                                 name:@"KRWMLogoutNotification"
                                               object:nil];

    // 本地有登录态就直接进主流程，否则先登录
    if ([[KRWMClient shared] restoreSession]) {
        [self showMain];
    } else {
        [self showLogin];
    }

    [self.window makeKeyAndVisible];
    return YES;
}

#pragma mark - 根控制器切换

- (void)showLogin {
    LoginViewController *vc = [[LoginViewController alloc] init];
    __weak typeof(self) ws = self;
    vc.onLoginSuccess = ^{ [ws showMain]; };
    [self swapRootViewController:[[UINavigationController alloc] initWithRootViewController:vc]];
}

- (void)showMain {
    MainViewController *vc = [[MainViewController alloc] init];
    [self swapRootViewController:[[UINavigationController alloc] initWithRootViewController:vc]];
}

- (void)swapRootViewController:(UIViewController *)root {
    if (self.window.rootViewController == nil) {
        self.window.rootViewController = root;
        return;
    }
    [UIView transitionWithView:self.window
                      duration:0.28
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ self.window.rootViewController = root; }
                    completion:nil];
}

@end
