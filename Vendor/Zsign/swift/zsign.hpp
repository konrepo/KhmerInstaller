//
//  zsign.hpp
//  feather
//
//  Created by HAHALOSAH on 5/22/24.
//

#ifndef zsign_hpp
#define zsign_hpp

#include <stdio.h>
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL KIVerifyDetachedCMS(NSData * _Nonnull codeDirectory, NSData * _Nonnull cmsSignature);
NSData * _Nullable KIExtractProvisioningProfile(NSData * _Nonnull profileData);
NSArray<NSData *> * _Nullable KIExtractProvisioningSignerCertificates(NSData * _Nonnull profileData);
NSDictionary<NSString *, id> * _Nullable KIInspectIPA(NSString * _Nonnull ipaPath);
BOOL KIExtractIPA(NSString * _Nonnull ipaPath, NSString * _Nonnull outputPath);

// Packages a validated, signed IPA workspace.
BOOL KIPackageIPA(NSString * _Nonnull sourceDirectory,
                  NSString * _Nonnull destinationIPA);
bool CheckIfSigned(NSString *filePath);
bool InjectDyLib(NSString *filePath, NSString *dylibPath, bool weakInject);
bool UninstallDylibs(NSString *filePath, NSArray<NSString *> *dylibPathsArray);
NSArray<NSString *> *ListDylibs(NSString *filePath);
bool ChangeDylibPath(NSString *filePath, NSString *oldPath, NSString *newPath);

int zsign(
	NSString *app,
	NSString *prov,
	NSString *key,
	NSString *pass,
	NSString *entitlement,
	NSString *bundleid,
	NSString *displayname,
	NSString *bundleversion,
	bool adhoc,
	bool dontGenerateEmbeddedMobileProvision,
	void(^completionHandler)(BOOL success)
);

// Sign an application with multiple provisioning profiles.
// Every app/extension must match exactly one validated profile.
int zsignMultipleProfiles(
    NSString * _Nonnull app,
    NSArray<NSString *> * _Nonnull provisionPaths,
    NSString * _Nonnull key,
    NSString * _Nonnull password,
    void(^ _Nullable completionHandler)(BOOL success)
);

int checkCert(
	NSString *prov,
	NSString *key,
	NSString *pass,
	void(^completionHandler)(int status, NSDate* expirationDate, NSString *error)
);

#ifdef __cplusplus
}
#endif

#endif /* zsign_hpp */
