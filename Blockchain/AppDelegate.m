//
//  AppDelegate.m
//  Blockchain
//
//  Created by Ben Reeves on 05/01/2012.
//  Copyright (c) 2012 Qkos Services Ltd. All rights reserved.
//
#import <QuartzCore/QuartzCore.h>

#import "AppDelegate.h"
#import "MultiAddressResponse.h"
#import "Wallet.h"
#import "BCFadeView.h"
#import "TabViewController.h"
#import "ReceiveCoinsViewController.h"
#import "SendViewController.h"
#import "TransactionsViewController.h"
#import "BCCreateWalletView.h"
#import "BCManualPairView.h"
#import "NSString+SHA256.h"
#import "Transaction.h"
#import "Input.h"
#import "Output.h"
#import "UIDevice+Hardware.h"
#import "UncaughtExceptionHandler.h"
#import "UITextField+Blocks.h"
#import "UIAlertView+Blocks.h"
#import "PairingCodeParser.h"
#import "PrivateKeyReader.h"
#import "MerchantViewController.h"
#import "NSData+Hex.h"
#import <AVFoundation/AVFoundation.h>
#import "Reachability.h"
#import "SideMenuViewController.h"
#import "BCWelcomeView.h"
#import "BCWebViewController.h"

#define CURTAIN_IMAGE_TAG 123

AppDelegate * app;

@implementation AppDelegate

@synthesize window = _window;
@synthesize wallet;
@synthesize modalView;
@synthesize latestResponse;

BOOL showSendCoins = NO;

#pragma mark - Lifecycle

- (id)init
{
    if (self = [super init]) {
        self.btcFormatter = [[NSNumberFormatter alloc] init];
        [_btcFormatter setMaximumFractionDigits:8];
        [_btcFormatter setNumberStyle:NSNumberFormatterDecimalStyle];
        
        self.localCurrencyFormatter = [[NSNumberFormatter alloc] init];
        [_localCurrencyFormatter setMinimumFractionDigits:2];
        [_localCurrencyFormatter setMaximumFractionDigits:2];
        [_localCurrencyFormatter setNumberStyle:NSNumberFormatterDecimalStyle];
        
        self.modalChain = [[NSMutableArray alloc] init];
        
        app = self;
    }
    
    return self;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // Make sure the server session id SID is persisted for new UIWebViews
    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    [cookieStorage setCookieAcceptPolicy:NSHTTPCookieAcceptPolicyAlways];
    
    // Allocate the global wallet
    self.wallet = [[Wallet alloc] init];
    self.wallet.delegate = self;
    
    // Send email when exceptions are caught
#ifndef DEBUG
    NSSetUncaughtExceptionHandler(&HandleException);
#endif
    
    [[NSNotificationCenter defaultCenter] addObserverForName:LOADING_TEXT_NOTIFICAITON_KEY object:nil queue:nil usingBlock:^(NSNotification * notification) {
        self.loadingText = [notification object];
    }];
    
    _window.backgroundColor = [UIColor whiteColor];
    
    // Side menu
    _slidingViewController = [[ECSlidingViewController alloc] init];
    _slidingViewController.topViewController = _tabViewController;
    _slidingViewController.underLeftViewController = [[SideMenuViewController alloc] init];
    _window.rootViewController = _slidingViewController;
    
    [_window makeKeyAndVisible];
    
    // Default view in TabViewController: transactionsViewController
    [_tabViewController setActiveViewController:_transactionsViewController];
    [_window.rootViewController.view addSubview:busyView];
    
    busyView.frame = _window.frame;
    busyView.alpha = 0.0f;
    
    // Load settings    
    symbolLocal = [[NSUserDefaults standardUserDefaults] boolForKey:@"symbolLocal"];
    
    // If either of these is nil we are not properly paired
    if (![self guid] || ![self sharedKey]) {
        [self showWelcome];
        return TRUE;
    }
    
    // We are properly paired here
    
    // If the PIN is set show the entry modal
    if ([self isPINSet]) {
        [self showPinModalAsView:YES];
    } else {
        // No PIN set we need to ask for the main password
        [self showPasswordModal];
    }
    
    /* Migrate Password and PIN from NSUserDefaults (for users updating from old version) */
    NSString * password = [[NSUserDefaults standardUserDefaults] objectForKey:@"password"];
    NSString * pin = [[NSUserDefaults standardUserDefaults] objectForKey:@"pin"];
    
    if (password && pin) {
        self.wallet.password = password;
        
        [self savePIN:pin];
        
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"password"];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"pin"];
    }
    
    return TRUE;
}

- (void)transitionToIndex:(NSInteger)newIndex
{
    if (newIndex == 0)
        [self sendCoinsClicked:nil];
    else if (newIndex == 1)
        [self transactionsClicked:nil];
    else if (newIndex == 2)
        [self receiveCoinClicked:nil];
    else
        DLog(@"Unknown tab index: %d", newIndex);
}

- (void)swipeLeft
{
    if (_tabViewController.selectedIndex < 2)
    {
        NSInteger newIndex = _tabViewController.selectedIndex + 1;
        [self transitionToIndex:newIndex];
    }
}

- (void)swipeRight
{
    if (_tabViewController.selectedIndex)
    {
        NSInteger newIndex = _tabViewController.selectedIndex - 1;
        [self transitionToIndex:newIndex];
    }
}

- (IBAction)balanceTextClicked:(id)sender {
    [self toggleSymbol];
}

#pragma mark - UI State
- (void)toggleSymbol {
    symbolLocal = !symbolLocal;
    
    // Save this setting here and load it on start
    [[NSUserDefaults standardUserDefaults] setBool:symbolLocal forKey:@"symbolLocal"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    [_transactionsViewController reload];
    [_sendViewController reloadWithCurrencyChange:YES];
    [_receiveViewController reload];
}


- (void)setDisableBusyView:(BOOL)__disableBusyView {
    _disableBusyView = __disableBusyView;
    
    if (_disableBusyView) {
        [busyView removeFromSuperview];
    }
    else {
        [_window.rootViewController.view addSubview:busyView];
    }
}

- (void)didWalletDecryptStart {
    [self networkActivityStart];
}

- (void)didWalletDecryptFinish {
    [self networkActivityStop];
}


- (void)networkActivityStart {
    [busyView fadeIn];
    
    [powerButton setEnabled:FALSE];
    
    if (self.loadingText) {
        [busyLabel setText:self.loadingText];
    }
    
    [self setStatus];
}

- (void)networkActivityStop {
    [powerButton setEnabled:TRUE];
    
    [busyView fadeOut];
    
    [activity stopAnimating];
    
    [self setStatus];
}

- (void)setStatus {
    if ([app.wallet getWebsocketReadyState] != 1) {
        [powerButton setHighlighted:TRUE];
    } else {
        [powerButton setHighlighted:FALSE];
    }
}

#pragma mark - AlertView Helpers

- (void)standardNotify:(NSString*)message
{
    [self standardNotify:message title:BC_STRING_ERROR delegate:nil];
}

- (void)standardNotify:(NSString*)message delegate:(id)fdelegate
{
    [self standardNotify:message title:BC_STRING_ERROR delegate:fdelegate];
}

- (void)standardNotify:(NSString*)message title:(NSString*)title delegate:(id)fdelegate
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([[UIApplication sharedApplication] applicationState] == UIApplicationStateActive) {
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title message:message  delegate:fdelegate cancelButtonTitle:BC_STRING_OK otherButtonTitles: nil];
            [alert show];
        }
    });
}

# pragma mark - Wallet.js callbacks

- (void)walletDidLoad
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0f * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self endBackgroundUpdateTask];
    });
}

- (void)walletFailedToLoad
{
    // When doing a manual pair the wallet fails to load the first time because the server needs to verify via email that the user grants access to this device. In that case we don't want to display any additional errors besides the server error telling the user to check his email.
    if ([manualPairView isDescendantOfView:_window.rootViewController.view]) {
        return;
    }
    
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:BC_STRING_FAILED_TO_LOAD_WALLET_TITLE
                                                    message:[NSString stringWithFormat:BC_STRING_FAILED_TO_LOAD_WALLET_DETAIL]
                                                   delegate:nil
                                          cancelButtonTitle:BC_STRING_FORGET_WALLET
                                          otherButtonTitles:BC_STRING_CLOSE_APP, nil];
    
    alert.tapBlock = ^(UIAlertView *alertView, NSInteger buttonIndex) {
        // Close App
        if (buttonIndex == 1) {
            UIApplication *app = [UIApplication sharedApplication];
            
            [app performSelector:@selector(suspend)];
        }
        // Forget Wallet
        else {
            [self confirmForgetWalletWithBlock:^(UIAlertView *alertView, NSInteger buttonIndex) {
                // Forget Wallet Cancelled
                if (buttonIndex == 0) {
                    // Open the Failed to load alert again
                    [self walletFailedToLoad];
                }
                // Forget Wallet Confirmed
                else if (buttonIndex == 1) {
                    [self forgetWallet];
                    [app showWelcome];
                }
            }];
        }
    };
    
    [alert show];
}

- (void)walletDidDecrypt
{
    DLog(@"walletDidDecrypt");
    
    if (showSendCoins) {
        [self showSendCoins];
        showSendCoins = NO;
    }
    
    [self setAccountData:wallet.guid sharedKey:wallet.sharedKey];
    
    [_transactionsViewController reload];
    [_receiveViewController reload];
    [_sendViewController reloadWithCurrencyChange:NO];
    
    [app closeAllModals];
    
    //Becuase we are not storing the password on the device. We record the first few letters of the hashed password.
    //With the hash prefix we can then figure out if the password changed
    NSString * passwordPartHash = [[NSUserDefaults standardUserDefaults] objectForKey:@"passwordPartHash"];
    if (![[[app.wallet.password SHA256] substringToIndex:MIN([app.wallet.password length], 5)] isEqualToString:passwordPartHash]) {
        [self clearPin];
    }
    
    if (![app isPINSet]) {
        [app showPinModalAsView:NO];
    }
}

- (void)didGetMultiAddressResponse:(MulitAddressResponse*)response
{
    self.latestResponse = response;
    
    _transactionsViewController.data = response;
    
    [_transactionsViewController reload];
    [_receiveViewController reload];
    [_sendViewController reloadWithCurrencyChange:NO];
}

- (void)didSetLatestBlock:(LatestBlock*)block
{
    _transactionsViewController.latestBlock = block;
    [_transactionsViewController reload];
}

- (void)walletFailedToDecrypt
{
    // In case we were on the manual pair screen, we want to go back there. The way to check for that is that the wallet has a guid, but it's not saved yet
    if (wallet.guid && ![[NSUserDefaults standardUserDefaults] objectForKey:@"guid"]) {
        [self showModalWithContent:manualPairView closeType:ModalCloseTypeBack];
        
        return;
    }
    
    [self showPasswordModal];
}

- (void)showPasswordModal
{
    [self showModalWithContent:mainPasswordView closeType:ModalCloseTypeNone];
}

- (void) beginBackgroundUpdateTask
{
    // We're using a background task to insure we get enough time to sync. The bg task has to be ended before or when the timer expires, otherwise the app gets killed by the system.
    // Always kill the old handler before starting a new one. In case the system starts a bg task when the app goes into background, comes to foreground and goes to background before the first background task was ended. In that case the first background task is never killed and the system kills the app when the maximum time is up.
    [self endBackgroundUpdateTask];
    
    self.backgroundUpdateTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [self endBackgroundUpdateTask];
    }];
}

- (void) endBackgroundUpdateTask
{
    if (self.backgroundUpdateTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.backgroundUpdateTask];
        self.backgroundUpdateTask = UIBackgroundTaskInvalid;
    }
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // Fade out the LaunchImage
    UIView *curtainView = [self.window viewWithTag:CURTAIN_IMAGE_TAG];
    [UIView animateWithDuration:0.25 animations:^{
        curtainView.alpha = 0;
    } completion:^(BOOL finished) {
        [curtainView removeFromSuperview];
    }];
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    // Dismiss sendviewController keyboard
    if (_sendViewController) {
        [_sendViewController dismissKeyboard];
        
        // Make sure the the send payment button on send screen is enabled (bug when second password requested and app is backgrounded)
        [_sendViewController reset];
    }
    
    // Cancel Notification for new address on receive coins view controller (bug when second password requested and app is backgrounded)
    [[NSNotificationCenter defaultCenter] removeObserver:_receiveViewController name:EVENT_NEW_ADDRESS object:nil];
    
    // Show the LaunchImage so the list of running apps does not show the user's information
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Small delay so we don't change the view while it's zooming out
        UIImageView *curtainImageView = [[UIImageView alloc] initWithFrame:self.window.bounds];
        
        // Select the correct image depending on the screen size. The names used are the default names that LaunchImage assets get after processing. See @http://stackoverflow.com/questions/19107543/xcode-5-asset-catalog-how-to-reference-the-launchimage
        // This works for iPhone 4/4S, 5/5S, 6 and 6Plus in Portrait
        // TODO need to add new screen sizes with new iPhones ... ugly
        // TODO we're currently using the scaled version of the app on iPhone 6 and 6 Plus
//        NSDictionary *dict = @{@"320x480" : @"LaunchImage-700", @"320x568" : @"LaunchImage-700-568h", @"375x667" : @"LaunchImage-800-667h", @"414x736" : @"LaunchImage-800-Portrait-736h"};
        NSDictionary *dict = @{@"320x480" : @"LaunchImage-700", @"320x568" : @"LaunchImage-700-568h", @"375x667" : @"LaunchImage-700-568h", @"414x736" : @"LaunchImage-700-568h"};
        NSString *key = [NSString stringWithFormat:@"%dx%d", (int)[UIScreen mainScreen].bounds.size.width, (int)[UIScreen mainScreen].bounds.size.height];
        UIImage *launchImage = [UIImage imageNamed:dict[key]];
        
        curtainImageView.image = launchImage;
        
        curtainImageView.alpha = 0;
        [curtainImageView setTag:CURTAIN_IMAGE_TAG];
        [self.window addSubview:curtainImageView];
        [self.window bringSubviewToFront:curtainImageView];
        
        [UIView animateWithDuration:ANIMATION_DURATION animations:^{
            curtainImageView.alpha = 1;
        } completion:^(BOOL finished) {
            // Dismiss any ViewControllers that are used modally, except for the MerchantViewController
            if (_tabViewController.presentedViewController == _bcWebViewController) {
                [_bcWebViewController dismissViewControllerAnimated:NO completion:nil];
            }
        }];
    });
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // Close all modals
    [app closeAllModals];
    
    // Close PIN Modal in case we are setting it (after login or when changing the PIN)
    if (self.pinEntryViewController.verifyOnly == NO) {
        [self closePINModal:NO];
    }
    
    // Show pin modal before we close the app so the PIN verify modal gets shown in the list of running apps and immediately after we restart
    if ([self isPINSet]) {
        [self showPinModalAsView:YES];
        [self.pinEntryViewController reset];
    }
    
    if ([wallet isInitialized]) {
        [self beginBackgroundUpdateTask];
        
        [self logout];
    }
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    // The PIN modal is shown on ResignActive, but we don't want to override the modal with the welcome screen
    if ([self isPINSet]) {
        return;
    }
    
    if (![wallet isInitialized]) {
        [app showWelcome];
        
        if ([self guid] && [self sharedKey]) {
            [self showModalWithContent:mainPasswordView closeType:ModalCloseTypeNone];
        }
    }
}

- (void)playBeepSound
{
    if (beepSoundID == 0) {
        AudioServicesCreateSystemSoundID((__bridge CFURLRef)[NSURL fileURLWithPath: [[NSBundle mainBundle] pathForResource:@"beep" ofType:@"wav"]], &beepSoundID);
    }
    
    AudioServicesPlaySystemSound(beepSoundID);
}

- (void)playAlertSound
{
    if (alertSoundID == 0) {
        //Find the Alert Sound
        NSString * alert_sound = [[NSBundle mainBundle] pathForResource:@"alert-received" ofType:@"wav"];
        
        //Create the system sound
        AudioServicesCreateSystemSoundID((__bridge CFURLRef)[NSURL fileURLWithPath: alert_sound], &alertSoundID);
    }
    
    AudioServicesPlaySystemSound(alertSoundID);
}

- (void)pushWebViewController:(NSString*)url
{
    _bcWebViewController = [[BCWebViewController alloc] init];
    [_bcWebViewController loadURL:url];
    [_tabViewController presentViewController:_bcWebViewController animated:YES completion:nil];
}

- (NSMutableDictionary *)parseQueryString:(NSString *)query
{
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] initWithCapacity:6];
    NSArray *pairs = [query componentsSeparatedByString:@"&"];
    
    for (NSString *pair in pairs) {
        NSArray *elements = [pair componentsSeparatedByString:@"="];
        if ([elements count] >= 2) {
            NSString *key = [[elements objectAtIndex:0] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
            NSString *val = [[elements objectAtIndex:1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
            
            [dict setObject:val forKey:key];
        }
    }
    return dict;
}

- (NSDictionary*)parseURI:(NSString*)urlString
{
    if (![urlString hasPrefix:@"bitcoin:"]) {
        return [NSDictionary dictionaryWithObject:urlString forKey:@"address"];
    }
    
    NSString * replaced = [[urlString stringByReplacingOccurrencesOfString:@"bitcoin:" withString:@"bitcoin://"] stringByReplacingOccurrencesOfString:@"////" withString:@"//"];
    
    NSURL * url = [NSURL URLWithString:replaced];
    
    NSMutableDictionary *dict = [self parseQueryString:[url query]];
    
    if ([url host] != NULL)
        [dict setObject:[url host] forKey:@"address"];
    
    return dict;
}

- (BOOL)application:(UIApplication *)application handleOpenURL:(NSURL *)url
{
    [app closeModalWithTransition:kCATransitionFade];
    
    showSendCoins = YES;
    
    if (!_sendViewController) {
        // really no reason to lazyload anymore...
        _sendViewController = [[SendViewController alloc] initWithNibName:@"SendCoins" bundle:[NSBundle mainBundle]];
    }
    
    NSDictionary *dict = [self parseURI:[url absoluteString]];
    NSString * addr = [dict objectForKey:@"address"];
    NSString * amount = [dict objectForKey:@"amount"];
    
    [_sendViewController setAmountFromUrlHandler:amount withToAddress:addr];
    [_sendViewController reloadWithCurrencyChange:NO];
    
    return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField*)textField
{
    if (textField == secondPasswordTextField) {
        [self secondPasswordClicked:textField];
    }
    else if (textField == mainPasswordTextField) {
        [self mainPasswordClicked:textField];
    }
    
    return YES;
}

- (void)getPrivateKeyPassword:(void (^)(NSString *))success error:(void (^)(NSString *))error
{
    validateSecondPassword = FALSE;
    
    secondPasswordDescriptionLabel.text = BC_STRING_PRIVATE_KEY_ENCRYPTED_DESCRIPTION;
    
    [app showModalWithContent:secondPasswordView closeType:ModalCloseTypeNone onDismiss:^() {
        NSString * password = secondPasswordTextField.text;
        
        if ([password length] == 0) {
            if (error) error(BC_STRING_NO_PASSWORD_ENTERED);
        } else {
            if (success) success(password);
        }
        
        secondPasswordTextField.text = nil;
    } onResume:nil];
    
    [secondPasswordTextField becomeFirstResponder];
}

- (IBAction)secondPasswordClicked:(id)sender
{
    NSString * password = secondPasswordTextField.text;
    
    if (!validateSecondPassword || [wallet validateSecondPassword:password]) {
        [app closeModalWithTransition:kCATransitionFade];
    } else {
        [app standardNotify:BC_STRING_SECOND_PASSWORD_INCORRECT];
        secondPasswordTextField.text = nil;
    }
}

- (void)getSecondPassword:(void (^)(NSString *))success error:(void (^)(NSString *))error
{
    secondPasswordDescriptionLabel.text = BC_STRING_ACTION_REQUIRES_SECOND_PASSWORD;
    
    validateSecondPassword = TRUE;
    
    [app showModalWithContent:secondPasswordView closeType:ModalCloseTypeClose onDismiss:^() {
        NSString * password = secondPasswordTextField.text;
        
        if ([password length] == 0) {
            if (error) error(BC_STRING_NO_PASSWORD_ENTERED);
        } else if(![wallet validateSecondPassword:password]) {
            if (error) error(BC_STRING_SECOND_PASSWORD_INCORRECT);
        } else {
            if (success) success(password);
        }
        
        secondPasswordTextField.text = nil;
    } onResume:nil];
    
    [secondPasswordTextField becomeFirstResponder];
}

- (void)closeAllModals
{
    [modalView removeFromSuperview];
    
    CATransition *animation = [CATransition animation];
    [animation setDuration:ANIMATION_DURATION];
    [animation setType:kCATransitionFade];
    
    [animation setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear]];
    [[_window layer] addAnimation:animation forKey:@"HideModal"];
    
    if (self.modalView.onDismiss) {
        self.modalView.onDismiss();
        self.modalView.onDismiss = nil;
    }
    
    self.modalView = nil;
    
    for (BCModalView *modalChainView in self.modalChain) {
        
        for (UIView *subView in [modalChainView.myHolderView subviews]) {
            [subView removeFromSuperview];
        }
        
        [modalChainView.myHolderView removeFromSuperview];
        
        if (modalChainView.onDismiss) {
            modalChainView.onDismiss();
        }
    }
    
    [self.modalChain removeAllObjects];
}

- (void)closeModalWithTransition:(NSString *)transition
{
    [modalView removeFromSuperview];
    
    CATransition *animation = [CATransition animation];
    // There are two types of transitions: movement based and fade in/out. The movement based ones can have a subType to set which direction the movement is in. In case the transition parameter is a direction, we use the MoveIn transition and the transition parameter as the direction, otherwise we use the transition parameter as the transition type.
    [animation setDuration:ANIMATION_DURATION];
    if (transition != kCATransitionFade) {
        [animation setType:kCATransitionMoveIn];
        [animation setSubtype:transition];
    }
    else {
        [animation setType:transition];
    }
    
    [animation setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear]];
    [[_window layer] addAnimation:animation forKey:@"HideModal"];
    
    if (self.modalView.onDismiss) {
        self.modalView.onDismiss();
        self.modalView.onDismiss = nil;
    }
    
    if ([self.modalChain count] > 0) {
        BCModalView * previousModalView = [self.modalChain objectAtIndex:[self.modalChain count]-1];
        
        [_window.rootViewController.view addSubview:previousModalView];
        
        [_window.rootViewController.view bringSubviewToFront:busyView];
        
        [_window.rootViewController.view endEditing:TRUE];
        
        if (self.modalView.onResume) {
            self.modalView.onResume();
        }
        
        self.modalView = previousModalView;
        
        [self.modalChain removeObjectAtIndex:[self.modalChain count]-1];
    }
    else {
        self.modalView = nil;
    }
}

- (void)showModalWithContent:(UIView *)contentView closeType:(ModalCloseType)closeType
{
    [self showModalWithContent:(BCModalContentView *)contentView closeType:closeType showHeader:YES onDismiss:nil onResume:nil];
}

- (void)showModalWithContent:(UIView *)contentView closeType:(ModalCloseType)closeType onDismiss:(void (^)())onDismiss onResume:(void (^)())onResume
{
    [self showModalWithContent:(BCModalContentView *)contentView closeType:closeType showHeader:YES onDismiss:onDismiss onResume:onResume];
}

- (void)showModalWithContent:(UIView *)contentView closeType:(ModalCloseType)closeType showHeader:(BOOL)showHeader onDismiss:(void (^)())onDismiss onResume:(void (^)())onResume
{
    // Remove the modal if we have one
    if (modalView) {
        [modalView removeFromSuperview];
        
        if (modalView.closeType != ModalCloseTypeNone) {
            if (modalView.onDismiss) {
                modalView.onDismiss();
                modalView.onDismiss = nil;
            }
        } else {
            [self.modalChain addObject:modalView];
        }
        
        self.modalView = nil;
    }
    
    // Show modal
    modalView = [[BCModalView alloc] initWithCloseType:closeType showHeader:showHeader];
    self.modalView.onDismiss = onDismiss;
    self.modalView.onResume = onResume;
    if (onResume) {
        onResume();
    }
    
    if ([contentView respondsToSelector:@selector(prepareForModalPresentation)]) {
        [(BCModalContentView *)contentView prepareForModalPresentation];
    }
    
    [modalView.myHolderView addSubview:contentView];
    
    contentView.frame = CGRectMake(0, 0, modalView.myHolderView.frame.size.width, modalView.myHolderView.frame.size.height);
    
    [_window.rootViewController.view addSubview:modalView];
    [_window.rootViewController.view bringSubviewToFront:busyView];
    [_window.rootViewController.view endEditing:TRUE];
    
    @try {
        CATransition *animation = [CATransition animation];
        [animation setDuration:ANIMATION_DURATION];
        
        if (closeType == ModalCloseTypeBack) {
            [animation setType:kCATransitionMoveIn];
            [animation setSubtype:kCATransitionFromRight];
        }
        else {
            [animation setType:kCATransitionFade];
        }
        
        [animation setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear]];
        [[_window.rootViewController.view layer] addAnimation:animation forKey:@"ShowModal"];
    } @catch (NSException * e) {
        DLog(@"Animation Exception %@", e);
    }
}

- (void)didFailBackupWallet
{
    [self networkActivityStop];
    
    // Cancel any tx signing just in case
    [self.wallet cancelTxSigning];
    
    // Refresh the wallet and history
    [self.wallet getWalletAndHistory];
}

- (void)didBackupWallet
{
    [_transactionsViewController reload];
    [_receiveViewController reload];
    [_sendViewController reloadWithCurrencyChange:NO];
}

- (void)setAccountData:(NSString*)guid sharedKey:(NSString*)sharedKey
{
    if ([guid length] != 36) {
        [app standardNotify:BC_STRING_INVALID_GUID];
        return;
    }
    
    if ([sharedKey length] != 36) {
        [app standardNotify:BC_STRING_INVALID_SHARED_KEY];
        return;
    }
    
    [[NSUserDefaults standardUserDefaults] setObject:guid forKey:@"guid"];
    [[NSUserDefaults standardUserDefaults] setObject:sharedKey forKey:@"sharedKey"];
    
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    [app closeModalWithTransition:kCATransitionFade];
}

- (BOOL)isQRCodeScanningSupported
{
    NSUInteger platformType = [[UIDevice currentDevice] platformType];
    
    if (platformType ==  UIDeviceiPhoneSimulator || platformType ==  UIDeviceiPhoneSimulatoriPhone  || platformType ==  UIDeviceiPhoneSimulatoriPhone || platformType ==  UIDevice1GiPhone || platformType ==  UIDevice3GiPhone || platformType ==  UIDevice1GiPod || platformType ==  UIDevice2GiPod || ![UIImagePickerController isSourceTypeAvailable: UIImagePickerControllerSourceTypeCamera]) {
        return FALSE;
    }
    
    return TRUE;
}

- (IBAction)scanAccountQRCodeclicked:(id)sender
{
    if ([self isQRCodeScanningSupported]) {
        PairingCodeParser * pairingCodeParser = [[PairingCodeParser alloc] initWithSuccess:^(NSDictionary*code) {
            DLog(@"scanAndParse success");
            
            [app forgetWallet];
            
            [app clearPin];
            
            [app standardNotify:[NSString stringWithFormat:BC_STRING_WALLET_PAIRED_SUCCESSFULLY_DETAIL] title:BC_STRING_WALLET_PAIRED_SUCCESSFULLY_TITLE delegate:nil];
            
            [self.wallet loadGuid:[code objectForKey:@"guid"] sharedKey:[code objectForKey:@"sharedKey"]];
            
            self.wallet.password = [code objectForKey:@"password"];
            
            self.wallet.delegate = self;
            
        } error:^(NSString*error) {
            [app standardNotify:error];
        }];
        
        [self.slidingViewController presentViewController:pairingCodeParser animated:YES completion:nil];
    } else {
        [self showModalWithContent:manualPairView closeType:ModalCloseTypeBack];
    }
}

- (void)askForPrivateKey:(NSString*)address success:(void(^)(id))_success error:(void(^)(id))_error
{
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:BC_STRING_ASK_FOR_PRIVATE_KEY_TITLE
                                                    message:[NSString stringWithFormat:BC_STRING_ASK_FOR_PRIVATE_KEY_DETAIL, address]
                                                   delegate:nil
                                          cancelButtonTitle:BC_STRING_NO
                                          otherButtonTitles:BC_STRING_YES, nil];
    
    alert.tapBlock = ^(UIAlertView *alertView, NSInteger buttonIndex) {
        if (buttonIndex == 0) {
            _error(BC_STRING_USER_DECLINED);
        } else {
            PrivateKeyReader *reader = [[PrivateKeyReader alloc] initWithSuccess:_success error:_error];
            [app.slidingViewController presentViewController:reader animated:YES completion:nil];
        }
    };
    
    [alert show];
}

- (void)logout
{
    [self.wallet cancelTxSigning];
    
    [self.wallet loadBlankWallet];
    
    self.latestResponse = nil;
    
    _transactionsViewController.data = nil;
    
    [_transactionsViewController reload];
    [_receiveViewController reload];
    [_sendViewController reloadWithCurrencyChange:NO];
}

- (void)forgetWallet
{
    [self clearPin];
    
    // Clear all cookies (important one is the server session id SID)
    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *each in cookieStorage.cookies) {
        [cookieStorage deleteCookie:each];
    }
    
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"guid"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"sharedKey"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    [self.wallet cancelTxSigning];
    
    [self.wallet clearLocalStorage];
    
    [self.wallet loadBlankWallet];
    
    self.latestResponse = nil;
    
    [_transactionsViewController setData:nil];
    
    [_transactionsViewController reload];
    [_receiveViewController reload];
    [_sendViewController reloadWithCurrencyChange:NO];
    
    [self transitionToIndex:1];
}

#pragma mark - Show Screens

- (void)showAccountSettings
{
    _bcWebViewController = [[BCWebViewController alloc] init];
    [_bcWebViewController loadSettings];
    
    [_tabViewController presentViewController:_bcWebViewController animated:YES completion:nil];
}

- (void)showSendCoins
{
    if (!_sendViewController) {
        _sendViewController = [[SendViewController alloc] initWithNibName:@"SendCoins" bundle:[NSBundle mainBundle]];
    }
    
    [_tabViewController setActiveViewController:_sendViewController animated:TRUE index:0];
}

- (void)clearPin
{
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"encryptedPINPassword"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"passwordPartHash"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"pinKey"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (BOOL)isPINSet
{
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"pinKey"] != nil && [[NSUserDefaults standardUserDefaults] objectForKey:@"encryptedPINPassword"] != nil;
}

- (void)closePINModal:(BOOL)animated
{
    // There are two different ways the pinModal is displayed: as a subview of tabViewController (on start) and as a viewController. This checks which one it is and dismisses accordingly
    if ([self.pinEntryViewController.view isDescendantOfView:_window.rootViewController.view]) {
        if (animated) {
            [UIView animateWithDuration:ANIMATION_DURATION animations:^{
                self.pinEntryViewController.view.alpha = 0;
            } completion:^(BOOL finished) {
                [self.pinEntryViewController.view removeFromSuperview];
            }];
        }
        else {
            [self.pinEntryViewController.view removeFromSuperview];
        }
    }
    else {
        [_tabViewController dismissViewControllerAnimated:animated completion:^{ }];
    }
}

- (void)showPinModalAsView:(BOOL)asView
{
    // Don't show a new one if we already show it
    if ([self.pinEntryViewController.view isDescendantOfView:_window.rootViewController.view] ||
        ( _tabViewController.presentedViewController != nil &&_tabViewController.presentedViewController == self.pinEntryViewController && !_pinEntryViewController.isBeingDismissed)) {
        return;
    }
    
    // if pin exists - verify
    if ([self isPINSet]) {
        self.pinEntryViewController = [PEPinEntryController pinVerifyController];
    }
    // no pin - create
    else {
        self.pinEntryViewController = [PEPinEntryController pinCreateController];
    }
    
    self.pinEntryViewController.navigationBarHidden = YES;
    self.pinEntryViewController.pinDelegate = self;
    
    // asView inserts the modal's view into the rootViewController as a view - this is only used in didFinishLaunching so there is no delay when showing the PIN on start
    if (asView) {
        [_window.rootViewController.view addSubview:self.pinEntryViewController.view];
    }
    else {
        [self.tabViewController presentViewController:self.pinEntryViewController animated:YES completion:nil];
    }
    
    [self.pinEntryViewController setActivityIndicatorAnimated:FALSE];
}

- (void)toggleSideMenu
{
    // If the sideMenu is not shown, show it
    if (_slidingViewController.currentTopViewPosition == ECSlidingViewControllerTopViewPositionCentered) {        
        [_slidingViewController anchorTopViewToRightAnimated:YES];
    }
    // If the sideMenu is shown, dismiss it
    else {
        [_slidingViewController resetTopViewAnimated:YES];
    }
}

- (void)showWelcome
{
    BCWelcomeView *welcomeView = [[BCWelcomeView alloc] init];
    [welcomeView.createWalletButton addTarget:self action:@selector(showCreateWallet:) forControlEvents:UIControlEventTouchUpInside];
    [welcomeView.existingWalletButton addTarget:self action:@selector(showPairWallet:) forControlEvents:UIControlEventTouchUpInside];
    [app showModalWithContent:welcomeView closeType:ModalCloseTypeNone showHeader:NO onDismiss:^{
        [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleLightContent];
        modalView.backgroundColor = COLOR_BLOCKCHAIN_BLUE;
    } onResume:nil];
}

- (void)showCreateWallet:(id)sender
{
    [app showModalWithContent:newAccountView closeType:ModalCloseTypeBack];
}

- (void)showPairWallet:(id)sender
{
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:BC_STRING_HOW_WOULD_YOU_LIKE_TO_PAIR
                                                    message:nil
                                                   delegate:self
                                          cancelButtonTitle:BC_STRING_MANUALLY
                                          otherButtonTitles:BC_STRING_AUTOMATICALLY, nil];
    
    alert.tapBlock = ^(UIAlertView *alertView, NSInteger buttonIndex) {
        // Manually
        if (buttonIndex == 0) {
            [app showModalWithContent:manualPairView closeType:ModalCloseTypeBack];
        }
        // QR
        else if (buttonIndex == 1) {
            [app showModalWithContent:pairingInstructionsView closeType:ModalCloseTypeBack];
        }
    };
    
    [alert show];
}


#pragma mark - Actions

- (IBAction)powerClicked:(id)sender
{
    if (_sendViewController) {
        [_sendViewController dismissKeyboard];
    }
    [self toggleSideMenu];
}

// Open ZeroBlock if it's installed, otherwise go to the ZeroBlock mobile homepage in the web modal
- (IBAction)newsClicked:(id)sender
{
    // TODO ZeroBlock does not have the URL scheme in it's .plist yet
    NSURL *zeroBlockAppURL = [NSURL URLWithString:@"zeroblock://"];
    
    if ([[UIApplication sharedApplication] canOpenURL:zeroBlockAppURL]) {
        [[UIApplication sharedApplication] openURL:zeroBlockAppURL];
    }
    else {
        [self pushWebViewController:@"https://zeroblock.com/"];
    }
}

- (IBAction)accountSettingsClicked:(id)sender
{
    [app showAccountSettings];
}

- (IBAction)changePINClicked:(id)sender
{
    [self changePIN];
}

- (void)changePIN
{
    PEPinEntryController *c = [PEPinEntryController pinChangeController];
    c.pinDelegate = self;
    c.navigationBarHidden = YES;
    
    PEViewController *peViewController = (PEViewController *)[[c viewControllers] objectAtIndex:0];
    peViewController.cancelButton.hidden = NO;
    
    self.pinEntryViewController = c;
    
    peViewController.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self.tabViewController presentViewController:c animated:YES completion:nil];
}

- (IBAction)logoutClicked:(id)sender
{
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:BC_STRING_LOGOUT
                                                    message:BC_STRING_REALLY_LOGOUT
                                                   delegate:self
                                          cancelButtonTitle:BC_STRING_CANCEL
                                          otherButtonTitles:BC_STRING_OK, nil];
    
    alert.tapBlock = ^(UIAlertView *alertView, NSInteger buttonIndex) {
        // Actually log out
        if (buttonIndex == 1) {
            [self clearPin];
            [self logout];
            
            [self showPasswordModal];
        }
    };
    
    [alert show];
}

- (void)confirmForgetWalletWithBlock:(void (^)(UIAlertView *alertView, NSInteger buttonIndex))tapBlock
{
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:BC_STRING_WARNING
                                                    message:BC_STRING_FORGET_WALLET_DETAILS
                                                   delegate:self
                                          cancelButtonTitle:BC_STRING_CANCEL
                                          otherButtonTitles:BC_STRING_FORGET_WALLET, nil];
    alert.tapBlock = tapBlock;
    
    [alert show];
    
}

- (IBAction)forgetWalletClicked:(id)sender
{
    // confirm forget wallet
    [self confirmForgetWalletWithBlock:^(UIAlertView *alertView, NSInteger buttonIndex) {
        // Forget Wallet Cancelled
        if (buttonIndex == 0) {
        }
        // Forget Wallet Confirmed
        else if (buttonIndex == 1) {
            DLog(@"forgetting wallet");
            [app closeModalWithTransition:kCATransitionFade];
            [self forgetWallet];
            [app showWelcome];
        }
    }];
    
}

- (IBAction)receiveCoinClicked:(UIButton *)sender
{
    if (!_receiveViewController) {
        _receiveViewController = [[ReceiveCoinsViewController alloc] initWithNibName:@"ReceiveCoins" bundle:[NSBundle mainBundle]];
    }
    
    [_tabViewController setActiveViewController:_receiveViewController animated:TRUE index:2];
}

- (IBAction)transactionsClicked:(UIButton *)sender
{
    [_tabViewController setActiveViewController:_transactionsViewController animated:TRUE index:1];
}

- (IBAction)sendCoinsClicked:(UIButton *)sender
{
    [self showSendCoins];
}

- (IBAction)merchantClicked:(UIButton *)sender
{
    if (!_merchantViewController) {
        _merchantViewController = [[MerchantViewController alloc] initWithNibName:@"MerchantMap" bundle:[NSBundle mainBundle]];
    }
    
    _merchantViewController.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [_tabViewController presentViewController:_merchantViewController animated:YES completion:nil];
}

-(IBAction)QRCodebuttonClicked:(id)sender
{
    if (!_sendViewController) {
        _sendViewController = [[SendViewController alloc] initWithNibName:@"SendCoins" bundle:[NSBundle mainBundle]];
    }
    [_sendViewController QRCodebuttonClicked:sender];
}

- (IBAction)mainPasswordClicked:(id)sender
{
    [mainPasswordTextField performSelectorOnMainThread:@selector(resignFirstResponder) withObject:nil waitUntilDone:NO];
    
    NSString * password = [mainPasswordTextField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString * guid = [[NSUserDefaults standardUserDefaults] objectForKey:@"guid"];
    NSString * sharedKey = [[NSUserDefaults standardUserDefaults] objectForKey:@"sharedKey"];
    
    if (guid && sharedKey && password) {
        
        [self.wallet loadGuid:guid sharedKey:sharedKey];
        
        self.wallet.password = password;
        
        self.wallet.delegate = self;
    }
    
    mainPasswordTextField.text = nil;
}

- (IBAction)refreshClicked:(id)sender
{
    if (![self guid] || ![self sharedKey]) {
        [app showWelcome];
        return;
    }
    
    // If displaying the merchant view controller refresh the map instead
    if (_tabViewController.activeViewController == _merchantViewController) {
        [_merchantViewController refresh];
    }
    // Otherwise just fetch the transaction history again
    else {
        [self.wallet getWalletAndHistory];
    }
}

#pragma mark - Accessors

- (NSString*)guid
{
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"guid"];
}

- (NSString*)sharedKey
{
    return [[NSUserDefaults standardUserDefaults] objectForKey:@"sharedKey"];
}

#pragma mark - Pin Entry Delegates

- (void)pinEntryController:(PEPinEntryController *)c shouldAcceptPin:(NSUInteger)_pin callback:(void(^)(BOOL))callback
{
    self.lastEnteredPIN = _pin;
    
    // TODO does this ever happen?
    if (!app.wallet) {
        assert(1 == 2);
        [self askIfUserWantsToResetPIN];
        return;
    }
    
    NSString * pinKey = [[NSUserDefaults standardUserDefaults] objectForKey:@"pinKey"];
    NSString * pin = [NSString stringWithFormat:@"%d", _pin];
    
    [self.pinEntryViewController setActivityIndicatorAnimated:TRUE];
    
    // Check if we have an internet connection
    // This only checks if a network interface is up. All other errors (including timeouts) are handled by JavaScript callbacks in Wallet.m
    Reachability *reachability = [Reachability reachabilityForInternetConnection];
    if ([reachability currentReachabilityStatus] == NotReachable) {
        DLog(@"No Internet connection");
        
        [self showPinErrorWithMessage:BC_STRING_NO_INTERNET_CONNECTION];
        
        return;
    }
    
    [app.wallet apiGetPINValue:pinKey pin:pin withWalletDownload:!c.verifyOnly];
    
    self.pinViewControllerCallback = callback;
}

- (void)showPinErrorWithMessage:(NSString *)message
{
    DLog(@"Pin error: %@", message);
    
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:BC_STRING_ERROR
                                                    message:message
                                                   delegate:nil
                                          cancelButtonTitle:BC_STRING_OK
                                          otherButtonTitles:nil];
    
    alert.tapBlock = ^(UIAlertView *alertView, NSInteger buttonIndex) {
        // Reset the pin entry field
        [self.pinEntryViewController setActivityIndicatorAnimated:FALSE];
        [self.pinEntryViewController reset];
    };
    
    [alert show];
}

- (void)askIfUserWantsToResetPIN {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:BC_STRING_PIN_VALIDATION_ERROR
                                                    message:BC_STRING_PIN_VALIDATION_ERROR_DETAIL
                                                   delegate:self
                                          cancelButtonTitle:BC_STRING_ENTER_PASSWORD
                                          otherButtonTitles:RETRY_VALIDATION, nil];
    
    alert.tapBlock = ^(UIAlertView *alertView, NSInteger buttonIndex) {
        if (buttonIndex == 0) {
            [self closePINModal:YES];
            
            [self showPasswordModal];
        } else if (buttonIndex == 1) {
            [self pinEntryController:self.pinEntryViewController shouldAcceptPin:self.lastEnteredPIN callback:self.pinViewControllerCallback];
        }
    };
    
    [alert show];
    
}

- (void)didFailGetPin:(NSString*)value {
    [self.pinEntryViewController setActivityIndicatorAnimated:FALSE];
    
    [self askIfUserWantsToResetPIN];
}

-(void)didFailGetPinTimeout
{
    [self showPinErrorWithMessage:BC_STRING_TIMED_OUT];
}

-(void)didFailGetPinNoResponse
{
    [self showPinErrorWithMessage:BC_STRING_EMPTY_RESPONSE];
}

-(void)didFailGetPinInvalidResponse
{
    [self showPinErrorWithMessage:BC_STRING_INVALID_RESPONSE];
}

- (void)didGetPinSuccess:(NSDictionary*)dictionary {
    [self.pinEntryViewController setActivityIndicatorAnimated:FALSE];
    
    NSNumber * code = [dictionary objectForKey:@"code"]; //This is a status code from the server
    NSString * error = [dictionary objectForKey:@"error"]; //This is an error string from the server or nil
    NSString * success = [dictionary objectForKey:@"success"]; //The PIN decryption value from the server
    NSString * encryptedPINPassword = [[NSUserDefaults standardUserDefaults] objectForKey:@"encryptedPINPassword"];
    
    BOOL pinSuccess = FALSE;
    if (code == nil) {
        [app standardNotify:[NSString stringWithFormat:BC_STRING_SERVER_RETURNED_NULL_STATUS_CODE]];
    } else if ([code intValue] == PIN_API_STATUS_CODE_DELETED) {
        [app standardNotify:BC_STRING_PIN_VALIDATION_CANNOT_BE_COMPLETED];
        
        [self clearPin];
        
        [self showPasswordModal];
        
        [self closePINModal:YES];
    } else if ([code integerValue] == PIN_API_STATUS_PIN_INCORRECT) {
        
        if (error == nil) {
            error = @"PIN Code Incorrect. Unknown Error Message.";
        }
        
        [app standardNotify:error];
    } else if ([code intValue] == PIN_API_STATUS_OK) {
        // This is for change PIN - verify the password first, then show the enter screens
        if (self.pinEntryViewController.verifyOnly == NO) {
            if (self.pinViewControllerCallback) {
                self.pinViewControllerCallback(YES);
                self.pinViewControllerCallback = nil;
            }
            
            return;
        }
        
        if ([success length] == 0) {
            [app standardNotify:BC_STRING_PIN_RESPONSE_OBJECT_SUCCESS_LENGTH_0];
            [self askIfUserWantsToResetPIN];
            return;
        }
        
        NSString * decrypted = [app.wallet decrypt:encryptedPINPassword password:success pbkdf2_iterations:PIN_PBKDF2_ITERATIONS];
        
        if ([decrypted length] == 0) {
            [app standardNotify:BC_STRING_DECRYPTED_PIN_PASSWORD_LENGTH_0];
            [self askIfUserWantsToResetPIN];
            return;
        }
        
        NSString * guid = [self guid];
        NSString * sharedKey = [self sharedKey];
        
        if (guid && sharedKey) {
            [self.wallet loadGuid:guid sharedKey:sharedKey];
        }
        
        app.wallet.password = decrypted;
        
        [self closePINModal:YES];
        
        pinSuccess = TRUE;
    } else {
        //Unknown error
        [self askIfUserWantsToResetPIN];
    }
    
    if (self.pinViewControllerCallback) {
        self.pinViewControllerCallback(pinSuccess);
        self.pinViewControllerCallback = nil;
    }
}

- (void)didFailPutPin:(NSString*)value {
    [self.pinEntryViewController setActivityIndicatorAnimated:FALSE];
    
    // If the server returns an "Invalid Numerical Value" response it means the user entered "0000" and we show a slightly different error message
    if ([@"Invalid Numerical Value" isEqual:value]) {
        value = BC_STRING_PLEASE_CHOOSE_ANOTHER_PIN;
    }
    [app standardNotify:value];
    
    [self closePINModal:NO];
    
    // Show the pin modal to enter a pin again
    self.pinEntryViewController = [PEPinEntryController pinCreateController];
    self.pinEntryViewController.navigationBarHidden = YES;
    self.pinEntryViewController.pinDelegate = self;
    
    [_window.rootViewController.view addSubview:self.pinEntryViewController.view];
}

- (void)didPutPinSuccess:(NSDictionary*)dictionary {
    [self.pinEntryViewController setActivityIndicatorAnimated:FALSE];
    
    if (!app.wallet.password) {
        [self didFailPutPin:BC_STRING_CANNOT_SAVE_PIN_CODE_WHILE];
        return;
    }
    
    NSNumber * code = [dictionary objectForKey:@"code"]; //This is a status code from the server
    NSString * error = [dictionary objectForKey:@"error"]; //This is an error string from the server or nil
    NSString * key = [dictionary objectForKey:@"key"]; //This is our pin code lookup key
    NSString * value = [dictionary objectForKey:@"value"]; //This is our encryption string
    
    if (error != nil) {
        [self didFailPutPin:error];
    } else if (code == nil || [code intValue] != PIN_API_STATUS_OK) {
        [self didFailPutPin:[NSString stringWithFormat:BC_STRING_INVALID_STATUS_CODE_RETURNED, code]];
    } else if ([key length] == 0 || [value length] == 0) {
        [self didFailPutPin:BC_STRING_PIN_RESPONSE_OBJECT_KEY_OR_VALUE_LENGTH_0];
    } else {
        //Encrypt the wallet password with the random value
        NSString * encrypted = [app.wallet encrypt:app.wallet.password password:value pbkdf2_iterations:PIN_PBKDF2_ITERATIONS];
        
        //Store the encrypted result and discard the value
        value = nil;
        
        if (!encrypted) {
            [self didFailPutPin:BC_STRING_PIN_ENCRYPTED_STRING_IS_NIL];
            return;
        }
        
        [[NSUserDefaults standardUserDefaults] setValue:encrypted forKey:@"encryptedPINPassword"];
        [[NSUserDefaults standardUserDefaults] setValue:[[app.wallet.password SHA256] substringToIndex:MIN([app.wallet.password length], 5)] forKey:@"passwordPartHash"];
        [[NSUserDefaults standardUserDefaults] setValue:key forKey:@"pinKey"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        // Update your info to new pin code
        [self closePINModal:YES];
        
        [app standardNotify:BC_STRING_PIN_SAVED_SUCCESSFULLY title:BC_STRING_SUCCESS delegate:nil];
    }
}

- (void)pinEntryController:(PEPinEntryController *)c changedPin:(NSUInteger)_pin
{
    if (![app.wallet isInitialized] || !app.wallet.password) {
        [self didFailPutPin:BC_STRING_CANNOT_SAVE_PIN_CODE_WHILE];
        return;
    }
    
    NSString * pin = [NSString stringWithFormat:@"%d", _pin];
    
    [self.pinEntryViewController setActivityIndicatorAnimated:TRUE];
    
    [self savePIN:pin];
}

- (void)savePIN:(NSString*)pin {
    uint8_t data[32];
    int err = 0;
    
    //32 Random bytes for key
    err = SecRandomCopyBytes(kSecRandomDefault, 32, data);
    if(err != noErr)
        @throw [NSException exceptionWithName:@"..." reason:@"..." userInfo:nil];
    
    NSString * key = [[[NSData alloc] initWithBytes:data length:32] hexadecimalString];
    
    //32 random bytes for value
    err = SecRandomCopyBytes(kSecRandomDefault, 32, data);
    if(err != noErr)
        @throw [NSException exceptionWithName:@"..." reason:@"..." userInfo:nil];
    
    NSString * value = [[[NSData alloc] initWithBytes:data length:32] hexadecimalString];
    
    [app.wallet pinServerPutKeyOnPinServerServer:key value:value pin:pin];
}

- (void)pinEntryControllerDidCancel:(PEPinEntryController *)c
{
    DLog(@"Pin change cancelled!");
    [self closePINModal:YES];
}

#pragma mark - Format helpers

- (NSString*)formatMoney:(uint64_t)value localCurrency:(BOOL)fsymbolLocal {
    if (fsymbolLocal && latestResponse.symbol_local.conversion) {
        @try {
            BOOL negative = false;
            
            NSDecimalNumber * number = [(NSDecimalNumber*)[NSDecimalNumber numberWithLongLong:value] decimalNumberByDividingBy:(NSDecimalNumber*)[NSDecimalNumber numberWithDouble:(double)latestResponse.symbol_local.conversion]];
            
            if ([number compare:[NSNumber numberWithInt:0]] < 0) {
                number = [number decimalNumberByMultiplyingBy:[NSDecimalNumber decimalNumberWithString:@"-1"]];
                negative = TRUE;
            }
            
            if (negative)
                return [@"-" stringByAppendingString:[latestResponse.symbol_local.symbol stringByAppendingString:[self.localCurrencyFormatter stringFromNumber:number]]];
            else
                return [latestResponse.symbol_local.symbol stringByAppendingString:[self.localCurrencyFormatter stringFromNumber:number]];
            
        } @catch (NSException * e) {
            DLog(@"Exception: %@", e);
        }
    } else if (latestResponse.symbol_btc) {
        NSDecimalNumber * number = [(NSDecimalNumber*)[NSDecimalNumber numberWithLongLong:value] decimalNumberByDividingBy:(NSDecimalNumber*)[NSDecimalNumber numberWithLongLong:latestResponse.symbol_btc.conversion]];
        
        NSString * string = [self.btcFormatter stringFromNumber:number];
        
        return [string stringByAppendingFormat:@" %@", latestResponse.symbol_btc.symbol];
    }
    
    NSDecimalNumber * number = [(NSDecimalNumber*)[NSDecimalNumber numberWithLongLong:value] decimalNumberByDividingBy:(NSDecimalNumber*)[NSDecimalNumber numberWithDouble:SATOSHI]];
    
    NSString * string = [self.btcFormatter stringFromNumber:number];
    
    return [string stringByAppendingString:@" BTC"];
}

- (NSString*)formatMoney:(uint64_t)value {
    return [self formatMoney:value localCurrency:symbolLocal];
}

@end
