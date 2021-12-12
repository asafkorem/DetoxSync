//
//  DispatchQueue+DTXSpy.m
//  DetoxSync
//
//  Created by Leo Natan (Wix) on 7/28/19.
//  Copyright © 2019 wix. All rights reserved.
//

/**
 *    ██╗    ██╗ █████╗ ██████╗ ███╗   ██╗██╗███╗   ██╗ ██████╗
 *    ██║    ██║██╔══██╗██╔══██╗████╗  ██║██║████╗  ██║██╔════╝
 *    ██║ █╗ ██║███████║██████╔╝██╔██╗ ██║██║██╔██╗ ██║██║  ███╗
 *    ██║███╗██║██╔══██║██╔══██╗██║╚██╗██║██║██║╚██╗██║██║   ██║
 *    ╚███╔███╔╝██║  ██║██║  ██║██║ ╚████║██║██║ ╚████║╚██████╔╝
 *     ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═══╝ ╚═════╝
 *
 *
 * WARNING: This file compiles with ARC disabled! Take extra care when modifying or adding functionality.
 */

#import "DispatchQueue+DTXSpy.h"
#import "DTXDispatchQueueSyncResource-Private.h"
#import "fishhook.h"
#import "DTXOrigDispatch.h"
#import "DTXSyncManager-Private.h"
#import "dispatch_time.h"

@import Darwin;

#define unlikely dtx_unlikely

DTX_ALWAYS_INLINE
void __detox_sync_dispatch_wrapper(void (*func)(dispatch_queue_t param1, dispatch_block_t param2), NSString* name, BOOL copy, dispatch_queue_t param1, dispatch_block_t _param2)
{
	dispatch_block_t param2 = copy ? [_param2 copy] : (id)_param2;
    NSLog(@"------ copy block with address: %@\n--------- new address: %@", _param2, param2);
	
	DTXDispatchQueueSyncResource* sr = [DTXDispatchQueueSyncResource _existingSyncResourceWithQueue:param1];
	NSString* identifier = [sr addWorkBlock:param2 operation:name moreInfo:nil];
	
	func(param1, ^ {
		param2();
		[sr removeWorkBlock:param2 operation:name identifier:identifier];
		
		if(copy == YES)
		{
            NSLog(@"------ release copied block with address(param2): %@", param2);
			[param2 release];
		}
	});
}

DTX_ALWAYS_INLINE
void __detox_sync_dispatch_group_wrapper(void (*func)(dispatch_group_t param1, dispatch_queue_t param2, dispatch_block_t param3), NSString* name, BOOL copy, dispatch_group_t param1, dispatch_queue_t param2, dispatch_block_t _param3)
{
	dispatch_block_t param3 = copy ? [_param3 copy] : (id)_param3;
  NSLog(@"------ copy block with address: %@\n--------- new address (param3): %@", _param3, param3);
	
	DTXDispatchQueueSyncResource* sr = [DTXDispatchQueueSyncResource _existingSyncResourceWithQueue:param2];
	NSString* identifier = [sr addWorkBlock:param3 operation:name moreInfo:nil];
	func(param1, param2, ^ {
		param3();
		[sr removeWorkBlock:param3 operation:name identifier:identifier];
		
		if(copy == YES)
		{
			[param3 release];
        NSLog(@"------ release copied block with address (param3): %@", param3);
		}
	});
}

static void (*__orig_dispatch_sync)(dispatch_queue_t queue, dispatch_block_t block);
static void __detox_sync_dispatch_sync(dispatch_queue_t queue, dispatch_block_t block)
{
	__detox_sync_dispatch_wrapper(__orig_dispatch_sync, @"dispatch_sync", NO, queue, block);
}

static void (*__orig_dispatch_async)(dispatch_queue_t queue, dispatch_block_t block);
static void __detox_sync_dispatch_async(dispatch_queue_t queue, dispatch_block_t block)
{
	__detox_sync_dispatch_wrapper((void*)__orig_dispatch_async, @"dispatch_async", YES, queue, block);
}

static void (*__orig_dispatch_async_and_wait)(dispatch_queue_t queue, dispatch_block_t block);
static void __detox_sync_dispatch_async_and_wait(dispatch_queue_t queue, dispatch_block_t block)
{
	__detox_sync_dispatch_wrapper((void*)__orig_dispatch_async_and_wait, @"dispatch_async_and_wait", YES, queue, block);
}

static void (*__orig_dispatch_after)(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block);
static void __detox_sync_dispatch_after(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t _block)
{
	DTXDispatchQueueSyncResource* sr = [DTXDispatchQueueSyncResource _existingSyncResourceWithQueue:queue];
	
	BOOL shouldTrack = sr != nil;
	
	uint64_t nanosecondsSinceEpoch = _dispatch_time_nanoseconds_since_epoch(when);
	NSTimeInterval secondsSinceEpoch = (double)nanosecondsSinceEpoch / (double)1000000000;
	NSTimeInterval timeFromNow = secondsSinceEpoch - [NSDate.date timeIntervalSince1970];
	
	if(shouldTrack && isinf(DTXSyncManager.maximumAllowedDelayedActionTrackingDuration) == NO)
	{
		shouldTrack = DTXSyncManager.maximumAllowedDelayedActionTrackingDuration >= timeFromNow;
		
		if(shouldTrack == NO)
		{
			DTXSyncResourceVerboseLog(@"⏲ Ignoring dispatch_after with work block “%@”; failure reason: \"%@\"", [_block debugDescription], [NSString stringWithFormat:@"duration>%@", @(DTXSyncManager.maximumAllowedDelayedActionTrackingDuration)]);
		}
	}
	
	dispatch_block_t block = [_block copy];
	
	NSString* identifier = nil;
	if(shouldTrack)
	{
		identifier = [sr addWorkBlock:block operation:@"dispatch_after" moreInfo:@(DTXDoubleWithMaxFractionLength(timeFromNow, 3)).description];
	}
	
	__orig_dispatch_after(when, queue, ^{
		block();
		
		if(shouldTrack)
		{
			[sr removeWorkBlock:block operation:@"dispatch_after" identifier:identifier];
		}
		
		[block release];
	});
}
void untracked_dispatch_after(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block)
{
	__orig_dispatch_after(when, queue, block);
}

static void (*__orig_dispatch_group_async)(dispatch_group_t group, dispatch_queue_t queue, dispatch_block_t block);
static void __detox_sync_dispatch_group_async(dispatch_group_t group, dispatch_queue_t queue, dispatch_block_t block)
{
	__detox_sync_dispatch_group_wrapper(__orig_dispatch_group_async, @"dispatch_group_async", YES, group, queue, block);
}

static void (*__orig_dispatch_group_notify)(dispatch_group_t group, dispatch_queue_t queue, dispatch_block_t block);
static void __detox_sync_dispatch_group_notify(dispatch_group_t group, dispatch_queue_t queue, dispatch_block_t block)
{
	__detox_sync_dispatch_group_wrapper(__orig_dispatch_group_notify, @"dispatch_group_notify", YES, group, queue, block);
}

static dispatch_queue_t (*__orig_dispatch_queue_create)(const char *_Nullable label, dispatch_queue_attr_t _Nullable attr);
dispatch_queue_t __detox_sync_dispatch_queue_create(const char *_Nullable label, dispatch_queue_attr_t _Nullable attr)
{
	return __orig_dispatch_queue_create(label, attr);
}


__attribute__((constructor))
static void _install_dispatchqueue_spy(void)
{
	struct rebinding r[] = (struct rebinding[]) {
		"dispatch_async", __detox_sync_dispatch_async, (void**)&__orig_dispatch_async,
		"dispatch_sync", __detox_sync_dispatch_sync, (void**)&__orig_dispatch_sync,
		"dispatch_async_and_wait", __detox_sync_dispatch_async_and_wait, (void**)&__orig_dispatch_async_and_wait,
		"dispatch_after", __detox_sync_dispatch_after, (void**)&__orig_dispatch_after,
		"dispatch_group_async", __detox_sync_dispatch_group_async, (void**)&__orig_dispatch_group_async,
		"dispatch_group_notify", __detox_sync_dispatch_group_notify, (void**)&__orig_dispatch_group_notify,
		"dispatch_queue_create", __detox_sync_dispatch_queue_create, (void**)&__orig_dispatch_queue_create,
	};
	rebind_symbols(r, sizeof(r) / sizeof(struct rebinding));
}
