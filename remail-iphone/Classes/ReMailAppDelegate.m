//
//  NextMailAppDelegate.m
//  NextMail iPhone Application
//
//  Created by Gabor Cselle on 1/16/09.
//  Copyright 2010 Google Inc.
//  
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//  
//   http://www.apache.org/licenses/LICENSE-2.0
//  
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "ReMailAppDelegate.h"
#import "Reachability.h"
#import "AppSettings.h"
#import "HomeViewController.h"
#import "HomeViewController.h"
#import "SyncManager.h"
#import "StringUtil.h"
#import "SearchRunner.h"
#import "AccountTypeSelectViewController.h"
#import "GlobalDBFunctions.h"
#import "ActivityIndicator.h"
#import "EmailProcessor.h"
#import "AddEmailDBAccessor.h"
#import	"SearchEmailDBAccessor.h"
#import "ContactDBAccessor.h"
#import "UidDBAccessor.h"
#import "StoreObserver.h"
#import <StoreKit/StoreKit.h>

#import "APViewController.h"
#import "SViewController.h"
#import <SecurityCheck/SecurityCheck.h>


@interface ReMailAppDelegate()

    //-----------------------------------
    // Callback block from SecurityCheck
    //-----------------------------------
    typedef void (^cbBlock) (void);

    - (void) weHaveAProblem;

@end


@implementation ReMailAppDelegate

@synthesize window = _window;
@synthesize pushSetupScreen;

-(void)dealloc {
    [window release];
    [super dealloc];
}

-(void)deactivateAllPurchases {
	// This is debug code, it should never be called in production
	[AppSettings setFeatureUnpurchased:@"RM_NOADS"];
	[AppSettings setFeatureUnpurchased:@"RM_IMAP"];
	[AppSettings setFeatureUnpurchased:@"RM_RACKSPACE"];
}

-(void)activateAllPurchasedFeatures {
	[AppSettings setFeaturePurchased:@"RM_NOADS"];
	[AppSettings setFeaturePurchased:@"RM_IMAP"];
	[AppSettings setFeaturePurchased:@"RM_RACKSPACE"];
}

-(void)pingHomeThread {
	// ping home to www.remail.com - this is for user # tracking only and does not send any
	// personally identifiable or usage information
	NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
	
	NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];      
	
	NSString* model = [[AppSettings model] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
	model = [model stringByReplacingOccurrencesOfString:@"?" withString:@"%3F"];
	model = [model stringByReplacingOccurrencesOfString:@"&" withString:@"%26"];
	
	int edition = (int)[AppSettings reMailEdition];
		
	NSString *encodedPostString = [NSString stringWithFormat:@"umd=%@&m=%@&v=%@&sv=%@&e=%i", md5([AppSettings udid]), model, [AppSettings version], [AppSettings systemVersion], edition];
	
	NSLog(@"pingRemail: %@", encodedPostString);
	
	NSData *postData = [encodedPostString dataUsingEncoding:NSUTF8StringEncoding];
	
	[request setURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://www.remail.com/ping"]]];
	[request setHTTPMethod:@"POST"];
	
	[request setValue:@"application/x-www-form-urlencoded;charset=UTF-8" forHTTPHeaderField:@"content-type"];
	[request setHTTPBody:postData];	
	
	// Execute HTTP call
	NSHTTPURLResponse *response;
	NSError *error;
	NSData *responseData = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
	
	if((!error) && ([(NSHTTPURLResponse *)response statusCode] == 200) && ([responseData length] > 0)) {
		[AppSettings setPinged];
	} else {
		NSLog(@"Invalid ping response %i", [(NSHTTPURLResponse *)response statusCode]);
	}
	
	[request release];
	
	[pool release];	
}

-(void)pingHome {
	NSThread *driverThread = [[NSThread alloc] initWithTarget:self selector:@selector(pingHomeThread) object:nil];
	[driverThread start];
	[driverThread release];
}

-(void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
	NSLog(@"Failed push registration with error: %@", error);

	// I feel like this is kind of a hack
	if(self.pushSetupScreen != nil && [self.pushSetupScreen respondsToSelector:@selector(didFailToRegisterForRemoteNotificationsWithError:)]) {
		[self.pushSetupScreen performSelectorOnMainThread:@selector(didFailToRegisterForRemoteNotificationsWithError:) withObject:error waitUntilDone:NO];
	}
}

-(void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)_deviceToken {
	// Get a hex string from the device token with no spaces or < >
	NSString* deviceToken = [[[[_deviceToken description] stringByReplacingOccurrencesOfString:@"<"withString:@""] 
						 stringByReplacingOccurrencesOfString:@">" withString:@""] 
						stringByReplacingOccurrencesOfString: @" " withString: @""];
	
	NSLog(@"Device Token: %@", deviceToken);
	if(self.pushSetupScreen != nil && [self.pushSetupScreen respondsToSelector:@selector(didRegisterForRemoteNotificationsWithDeviceToken:)]) {
		[self.pushSetupScreen performSelectorOnMainThread:@selector(didRegisterForRemoteNotificationsWithDeviceToken:) withObject:deviceToken waitUntilDone:NO];
	}									   
}

-(void)resetApp {
	// reset - delete all data and settings
	[AppSettings setReset:NO];
	for(int i = 0; i < [AppSettings numAccounts]; i++) {
		[AppSettings setUsername:@"" accountNum:i];
		[AppSettings setPassword:@"" accountNum:i];
		[AppSettings setServer:@"" accountNum:i];
		
		[AppSettings setAccountDeleted:YES accountNum:0];	
	}
		
	[AppSettings setLastpos:@"home"];
	[AppSettings setDataInitVersion];
	[AppSettings setFirstSync:YES];
	[AppSettings setGlobalDBVersion:0];
	
	[AppSettings setNumAccounts:0];
	
	[GlobalDBFunctions deleteAll];
}

-(void)setImapErrorLogPath {
	NSString* mailimapErrorLogPath = [StringUtil filePathInDocumentsDirectoryForFileName:@"mailimap_error.log"];
	const char* a = [mailimapErrorLogPath cStringUsingEncoding:NSASCIIStringEncoding];
	setenv("REMAIL_MAILIMAP_ERROR_LOG_PATH", a, 1);
	
	// delete file that might have been left around
	if ([[NSFileManager defaultManager] fileExistsAtPath:mailimapErrorLogPath]) {
		[[NSFileManager defaultManager] removeItemAtPath:mailimapErrorLogPath error:NULL];
	}
}


//*************************************
//*************************************
//**
//** iMAS security init code
//**

- (void)performLaunchSteps {
    
#if TARGET_OS_IPHONE && !TARGET_IPHONE_SIMULATOR
    
    
#if 1
    //--------------------------------
    // do not allow debuggers
    //--------------------------------
    dbgStop;
    
    //--------------------------------------------------------------------------
    // check for the presence of a debugger, call weHaveAProblem if there is one
    //--------------------------------------------------------------------------
    cbBlock dbChkCallback = ^{
        
        __weak id weakSelf = self;
        
        if (weakSelf) [weakSelf weHaveAProblem];
    };
    
    dbgCheck(dbChkCallback);
#endif


    //-----------------------------------
    // call back to weHaveAProblem
    //-----------------------------------
    cbBlock chkCallback  = ^{
        

        __weak id weakSelf = self;
        
        if (weakSelf) [weakSelf weHaveAProblem];
    };

    //-----------------------------------
    // jailbreak detection
    //-----------------------------------
    checkFork(chkCallback);
    checkFiles(chkCallback);
    checkLinks(chkCallback);
    
    
#endif

    
    //** Launch passcode
    APViewController *apc = [[APViewController alloc] init];
    apc.delegate = (id)self;
    
    _window.rootViewController = apc;
    [_window makeKeyAndVisible];

}


//--------------------------------------------------------------------
// if a debugger is attached to the app or jailbreak detection then this method will be called
//--------------------------------------------------------------------
- (void) weHaveAProblem {
    NSLog(@"weHaveAProblem in AppDelegate");
    
    //** cause segfault
    //int *foo = (int*)-1; // make a bad pointer
    //printf("%d\n", *foo);       // causes segfault
    
    //** OR launch blank, black colored window that hangs the user
    SViewController *sc = [[SViewController alloc] init];
    _window.rootViewController = sc;
    [_window makeKeyAndVisible];

#if 1
    //** OR re-launch the splash screen, must be preceded by SViewController as that controller overwrites the rootcontroller
    //** which changes the app flow
    UIImageView *myImageView =[[UIImageView alloc]
                               initWithFrame:CGRectMake(0.0,0.0,self.window.frame.size.width,self.window.frame.size.height)];
    
    myImageView.image=[UIImage imageNamed:@"Default.png"];
    myImageView.tag=22;
    [self.window addSubview:myImageView ];
    [myImageView release];
    [self.window bringSubviewToFront:myImageView];
#endif
    
    //** OR make this thread stop and spin - not that effective as rest of app continues
    //volatile int dummy_side_effect;
    //
    //while (1) {  dummy_side_effect = 0; }
    //NSLog(@"Never prints.");


    //** recommend not EXITing as foresics can easily find exit(0) and replace with NOP
    //exit(0);
}



-(BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary*)options {
	[NSThread setThreadPriority:1.0];
    
    [self performLaunchSteps];
    
    return YES;
}

- (void)validUserAccess:(APViewController *)controller {
    NSLog(@"validUserAccess - Delegate");
    	
	NSDictionary *options = nil;
        
	
	// set path for log output to send home
	[self setImapErrorLogPath];
	
	// handle reset and clearing attachments
	// (the user can reset all data in iPhone > Settings)
	if([AppSettings reset]) {
		[self resetApp];
	}
	
	// we're not selling reMail any more, so we can just activate all purchases
	[self activateAllPurchasedFeatures];
	
	BOOL firstSync = [AppSettings firstSync];
	
	if(firstSync) {
		[AppSettings setDatastoreVersion:1];
		
		//Need to set up first account
		AccountTypeSelectViewController* accountTypeVC;
		accountTypeVC = [[AccountTypeSelectViewController alloc] initWithNibName:@"AccountTypeSelect" bundle:nil];
		
		accountTypeVC.firstSetup = YES;
		accountTypeVC.accountNum = 0;
		accountTypeVC.newAccount = YES;
		
		UINavigationController* navController = [[UINavigationController alloc] initWithRootViewController:accountTypeVC];
		[self.window addSubview:navController.view];
		[accountTypeVC release];
	} else {
		// already set up - let's go to the home screen
		HomeViewController *homeController = [[HomeViewController alloc] initWithNibName:@"HomeView" bundle:nil];
		UINavigationController* navController = [[UINavigationController alloc] initWithRootViewController:homeController];
		navController.navigationBarHidden = NO;
		[self.window addSubview:navController.view];
		
		if(options != nil) {
			[homeController loadIt];
			[homeController toolbarRefreshClicked:nil];
		}
		[homeController release];
	}
	
	[window makeKeyAndVisible];
	
	//removed after I cut out store
	//[[SKPaymentQueue defaultQueue] addTransactionObserver:[StoreObserver getSingleton]];
}

- (void)applicationWillTerminate:(UIApplication *)application {
   
	EmailProcessor *em = [EmailProcessor getSingleton];
	em.shuttingDown = YES;
	
	SearchRunner *sem = [SearchRunner getSingleton];
	[sem cancel];
	
	// write unwritten changes to user defaults to disk
	[NSUserDefaults resetStandardUserDefaults];
	
    [EmailProcessor clearPreparedStmts];
	[EmailProcessor finalClearPreparedStmts];
	[SearchRunner clearPreparedStmts];
    
	// Close the databases
	[[AddEmailDBAccessor sharedManager] close];
	[[SearchEmailDBAccessor sharedManager] close];
	[[ContactDBAccessor sharedManager] close];
	[[UidDBAccessor sharedManager] close];
}

- (void)applicationWillResignActive:(UIApplication *)application {
	//TODO(gabor): Cancel any ongoing sync, remember that a sync was ongoing
	NSLog(@"applicationWillResignActive");
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
	// If a sync was ongoing, restart it
	NSLog(@"applicationDidBecomeActive");

    [self performLaunchSteps];
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    NSLog(@"did enter background");
    //** blank out root window
    self.window.rootViewController = 0;
}

@end
