//
//  zsign.mm
//  feather
//
//  Created by HAHALOSAH on 5/22/24.
//

#include "zsign.hpp"
#include "common.h"
#include "openssl.h"
#include "macho.h"
#include "bundle.h"
#include "openssl.h"
#include "timer.h"
#include "archive.h"

#include <climits>
#include <vector>
#include "third-party/minizip/zip.h"
#include <fcntl.h>
#include <unistd.h>
#include "third-party/minizip/unzip.h"
#include <ctime>
#include <memory>

#include <openssl/cms.h>
#include <openssl/ocsp.h>
#include <openssl/x509.h>
#include <openssl/pem.h>
#include <openssl/bio.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/asn1.h>

extern "C" {



// Independently verify a detached Mach-O CMS signature.
// This checks cryptographic integrity, not certificate-chain trust.
BOOL KIVerifyDetachedCMS(
    NSData *codeDirectory,
    NSData *cmsSignature
) {
    if (codeDirectory == nil ||
        cmsSignature == nil ||
        codeDirectory.length == 0 ||
        cmsSignature.length == 0 ||
        codeDirectory.length > INT_MAX ||
        cmsSignature.length > INT_MAX) {
        return NO;
    }

    BIO *signatureInput = BIO_new_mem_buf(
        cmsSignature.bytes,
        static_cast<int>(cmsSignature.length)
    );

    if (signatureInput == nullptr) {
        return NO;
    }

    CMS_ContentInfo *cms = d2i_CMS_bio(
        signatureInput,
        nullptr
    );

    BIO_free(signatureInput);

    if (cms == nullptr) {
        return NO;
    }

    if (CMS_is_detached(cms) != 1) {
        CMS_ContentInfo_free(cms);
        return NO;
    }

    BIO *contentInput = BIO_new_mem_buf(
        codeDirectory.bytes,
        static_cast<int>(codeDirectory.length)
    );

    if (contentInput == nullptr) {
        CMS_ContentInfo_free(cms);
        return NO;
    }

    int verified = CMS_verify(
        cms,
        nullptr,
        nullptr,
        contentInput,
        nullptr,
        CMS_NO_SIGNER_CERT_VERIFY | CMS_BINARY
    );

    BIO_free(contentInput);
    CMS_ContentInfo_free(cms);

    return verified == 1 ? YES : NO;
}

NSData * KIExtractProvisioningProfile(NSData *profileData) {
    if (profileData == nil ||
        profileData.length == 0 ||
        profileData.length > INT_MAX) {
        return nil;
    }

    BIO *input = BIO_new_mem_buf(
        profileData.bytes,
        static_cast<int>(profileData.length)
    );

    if (input == nullptr) {
        return nil;
    }

    CMS_ContentInfo *cms = d2i_CMS_bio(input, nullptr);
    BIO_free(input);

    if (cms == nullptr) {
        return nil;
    }

    BIO *output = BIO_new(BIO_s_mem());

    if (output == nullptr) {
        CMS_ContentInfo_free(cms);
        return nil;
    }

    // Verify CMS signature and signed content integrity.
    // Signer certificate-chain trust is NOT verified here.
    int verified = CMS_verify(
        cms,
        nullptr,
        nullptr,
        nullptr,
        output,
        CMS_NO_SIGNER_CERT_VERIFY
    );

    NSData *result = nil;

    if (verified == 1) {
        BUF_MEM *buffer = nullptr;
        BIO_get_mem_ptr(output, &buffer);

        if (buffer != nullptr &&
            buffer->data != nullptr &&
            buffer->length > 0) {

            result = [NSData dataWithBytes:buffer->data
                                   length:buffer->length];
        }
    }

    BIO_free(output);
    CMS_ContentInfo_free(cms);

    return result;
}



NSArray<NSData *> * KIExtractProvisioningSignerCertificates(
    NSData *profileData
) {
    if (profileData == nil ||
        profileData.length == 0 ||
        profileData.length > INT_MAX) {
        return nil;
    }

    BIO *input = BIO_new_mem_buf(
        profileData.bytes,
        static_cast<int>(profileData.length)
    );

    if (input == nullptr) {
        return nil;
    }

    CMS_ContentInfo *cms = d2i_CMS_bio(input, nullptr);
    BIO_free(input);

    if (cms == nullptr) {
        return nil;
    }

    // Verify signature integrity before extracting certificates.
    BIO *output = BIO_new(BIO_s_mem());

    if (output == nullptr) {
        CMS_ContentInfo_free(cms);
        return nil;
    }

    int verified = CMS_verify(
        cms,
        nullptr,
        nullptr,
        nullptr,
        output,
        CMS_NO_SIGNER_CERT_VERIFY
    );

    BIO_free(output);

    if (verified != 1) {
        CMS_ContentInfo_free(cms);
        return nil;
    }

    NSMutableArray<NSData *> *certificates =
        [NSMutableArray array];

    STACK_OF(X509) *signers = CMS_get0_signers(cms);

    if (signers == nullptr || sk_X509_num(signers) < 1) {
        if (signers != nullptr) {
            sk_X509_free(signers);
        }
        CMS_ContentInfo_free(cms);
        return nil;
    }

    auto appendCertificate = [&](X509 *cert) {
        if (cert == nullptr) {
            return;
        }

        int length = i2d_X509(cert, nullptr);

        if (length <= 0) {
            return;
        }

        NSMutableData *data =
            [NSMutableData dataWithLength:length];

        unsigned char *pointer =
            static_cast<unsigned char *>(data.mutableBytes);

        if (i2d_X509(cert, &pointer) == length) {
            [certificates addObject:data];
        }
    };

    // First certificate is the actual CMS signer.
    appendCertificate(sk_X509_value(signers, 0));

    // Include embedded certificates for chain building.
    STACK_OF(X509) *embedded = CMS_get1_certs(cms);

    if (embedded != nullptr) {
        for (int i = 0; i < sk_X509_num(embedded); i++) {
            appendCertificate(sk_X509_value(embedded, i));
        }

        sk_X509_pop_free(embedded, X509_free);
    }

    // CMS_get0_signers returns a stack whose certificates
    // remain owned by the CMS object.
    sk_X509_free(signers);

    CMS_ContentInfo_free(cms);

    return certificates.count > 0 ? certificates : nil;
}


NSDictionary<NSString *, id> * KIInspectIPA(NSString *ipaPath) {
    if (ipaPath == nil || ipaPath.length == 0) {
        return nil;
    }

    unzFile archive = unzOpen64(ipaPath.UTF8String);
    if (archive == nullptr) {
        return nil;
    }

    unz_global_info64 globalInfo = {};
    if (unzGetGlobalInfo64(archive, &globalInfo) != UNZ_OK ||
        globalInfo.number_entry == 0 ||
        globalInfo.number_entry > 50000) {
        unzClose(archive);
        return nil;
    }

    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];
    NSString *infoPath = nil;
    NSData *infoData = nil;
    unsigned long long totalSize = 0;

    bool valid = true;

    for (uint64_t index = 0;
         index < globalInfo.number_entry;
         index++) {

        unz_file_info64 info = {};

        if (unzGetCurrentFileInfo64(
            archive, &info, nullptr, 0,
            nullptr, 0, nullptr, 0
        ) != UNZ_OK) {
            valid = false;
            break;
        }

        if (info.size_filename == 0 ||
            info.size_filename > 4096 ||
            (info.flag & 1) != 0) {
            valid = false;
            break;
        }

        std::vector<char> filename(info.size_filename + 1, 0);

        if (unzGetCurrentFileInfo64(
            archive, &info,
            filename.data(),
            static_cast<uLong>(filename.size()),
            nullptr, 0, nullptr, 0
        ) != UNZ_OK) {
            valid = false;
            break;
        }

        NSString *path = [NSString stringWithUTF8String:
            filename.data()];

        if (path == nil ||
            [path hasPrefix:@"/"] ||
            [path containsString:@"\\"]) {
            valid = false;
            break;
        }

        NSArray<NSString *> *parts =
            [path componentsSeparatedByString:@"/"];

        for (NSString *part in parts) {
            if ([part isEqualToString:@".."] ||
                [part isEqualToString:@"."]) {
                valid = false;
                break;
            }
        }

        if (!valid || [seenPaths containsObject:path]) {
            valid = false;
            break;
        }

        [seenPaths addObject:path];

        // Unix symbolic-link file type.
        unsigned long mode =
            (info.external_fa >> 16) & 0170000;

        if (mode == 0120000) {
            valid = false;
            break;
        }

        if (info.uncompressed_size > 1073741824ULL ||
            totalSize > 2147483648ULL -
                info.uncompressed_size) {
            valid = false;
            break;
        }

        totalSize += info.uncompressed_size;

        if ([path hasPrefix:@"Payload/"] &&
            [path hasSuffix:@".app/Info.plist"]) {

            if (infoPath != nil ||
                info.uncompressed_size > 1048576ULL) {
                valid = false;
                break;
            }

            infoPath = path;

            if (unzOpenCurrentFile(archive) != UNZ_OK) {
                valid = false;
                break;
            }

            NSMutableData *data = [NSMutableData data];
            char buffer[8192];
            int count = 0;

            while ((count = unzReadCurrentFile(
                archive, buffer, sizeof(buffer)
            )) > 0) {
                [data appendBytes:buffer length:count];

                if (data.length > 1048576) {
                    valid = false;
                    break;
                }
            }

            if (count < 0 ||
                unzCloseCurrentFile(archive) != UNZ_OK) {
                valid = false;
            }

            if (!valid) {
                break;
            }

            infoData = data;
        }

        if (index + 1 < globalInfo.number_entry &&
            unzGoToNextFile(archive) != UNZ_OK) {
            valid = false;
            break;
        }
    }

    unzClose(archive);

    if (!valid || infoData == nil) {
        return nil;
    }

    NSError *error = nil;

    NSDictionary *plist =
        [NSPropertyListSerialization
            propertyListWithData:infoData
            options:NSPropertyListImmutable
            format:nullptr
            error:&error];

    if (![plist isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString *bundleID = plist[@"CFBundleIdentifier"];
    NSString *version = plist[@"CFBundleShortVersionString"];
    NSString *build = plist[@"CFBundleVersion"];
    NSString *executable = plist[@"CFBundleExecutable"];

    if (![bundleID isKindOfClass:[NSString class]] ||
        ![version isKindOfClass:[NSString class]] ||
        ![build isKindOfClass:[NSString class]] ||
        ![executable isKindOfClass:[NSString class]]) {
        return nil;
    }

    NSString *name = plist[@"CFBundleDisplayName"];

    if (![name isKindOfClass:[NSString class]]) {
        name = plist[@"CFBundleName"];
    }

    if (![name isKindOfClass:[NSString class]]) {
        name = executable;
    }

    return @{
        @"name": name,
        @"bundleID": bundleID,
        @"version": version,
        @"build": build,
        @"executable": executable,
        @"entryCount": @(globalInfo.number_entry)
    };
}


BOOL KIExtractIPA(NSString *ipaPath, NSString *outputPath) {
    if (ipaPath.length == 0 || outputPath.length == 0) {
        return NO;
    }

    // Preliminary archive validation using the existing inspector.
    if (KIInspectIPA(ipaPath) == nil) {
        NSLog(@"KI_EXTRACT_DIAG: INSPECTION_FAILED");
        return NO;
    }

    unzFile archive = unzOpen64(ipaPath.UTF8String);
    if (archive == nullptr) {
        return NO;
    }

    unz_global_info64 globalInfo = {};
    if (unzGetGlobalInfo64(archive, &globalInfo) != UNZ_OK ||
        globalInfo.number_entry == 0 ||
        globalInfo.number_entry > 50000) {
        unzClose(archive);
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];

    if ([fm fileExistsAtPath:outputPath]) {
        unzClose(archive);
        return NO;
    }

    // Pass 1: Validate every entry before writing files.
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableSet<NSString *> *filePaths = [NSMutableSet set];
    NSMutableSet<NSString *> *directoryPaths = [NSMutableSet set];
    unsigned long long totalSize = 0;
    BOOL valid = YES;

    for (uint64_t i = 0; i < globalInfo.number_entry; i++) {
        unz_file_info64 info = {};

        if (unzGetCurrentFileInfo64(
            archive, &info, nullptr, 0,
            nullptr, 0, nullptr, 0
        ) != UNZ_OK ||
            info.size_filename == 0 ||
            info.size_filename > 4096 ||
            (info.flag & 1) != 0 ||
            (info.compression_method != 0 &&
             info.compression_method != 8)) {
            valid = NO;
            break;
        }

        std::vector<char> filename(info.size_filename + 1, 0);

        if (unzGetCurrentFileInfo64(
            archive, &info, filename.data(),
            static_cast<uLong>(filename.size()),
            nullptr, 0, nullptr, 0
        ) != UNZ_OK) {
            valid = NO;
            break;
        }

        NSString *name =
            [NSString stringWithUTF8String:filename.data()];

        if (name == nil ||
            [name hasPrefix:@"/"] ||
            [name containsString:@"\\"] ||
            [seen containsObject:name]) {
            valid = NO;
            break;
        }

        for (NSString *part in
             [name componentsSeparatedByString:@"/"]) {
            if ([part isEqualToString:@".."] ||
                [part isEqualToString:@"."]) {
                valid = NO;
                break;
            }
        }

        if (!valid) {
            break;
        }

        // KI_HARDENED_PATH_CHECK
        // Reject ambiguous and noncanonical archive paths.
        BOOL isDirectoryEntry = [name hasSuffix:@"/"];
        NSString *normalizedName = isDirectoryEntry
            ? [name substringToIndex:name.length - 1]
            : name;

        if (normalizedName.length == 0 ||
            [normalizedName hasPrefix:@"~"] ||
            [normalizedName containsString:@"//"] ||
            [normalizedName containsString:@":"] ||
            [normalizedName containsString:@"\\"] ||
            [normalizedName rangeOfCharacterFromSet:
                [NSCharacterSet controlCharacterSet]].location
                != NSNotFound) {
            valid = NO;
            break;
        }

        for (NSString *part in
             [normalizedName componentsSeparatedByString:@"/"]) {
            if (part.length == 0 ||
                [part isEqualToString:@"."] ||
                [part isEqualToString:@".."]) {
                valid = NO;
                break;
            }
        }

        if (!valid) {
            break;
        }

        // Reject a file and directory sharing the same name.
        if ([seen containsObject:normalizedName] ||
            [seen containsObject:
                [normalizedName stringByAppendingString:@"/"]]) {
            valid = NO;
            break;
        }

        // KI_PARENT_COLLISION_CHECK
        // A file cannot also be a directory or an ancestor
        // of another archive entry.
        if (isDirectoryEntry) {
            if ([filePaths containsObject:normalizedName]) {
                valid = NO;
                break;
            }
            [directoryPaths addObject:normalizedName];
        } else {
            if ([directoryPaths containsObject:normalizedName]) {
                valid = NO;
                break;
            }
            [filePaths addObject:normalizedName];
        }

        NSArray<NSString *> *components =
            [normalizedName componentsSeparatedByString:@"/"];

        NSMutableString *parent = [NSMutableString string];

        for (NSUInteger j = 0; j + 1 < components.count; j++) {
            if (j > 0) {
                [parent appendString:@"/"];
            }
            [parent appendString:components[j]];

            if ([filePaths containsObject:parent]) {
                valid = NO;
                break;
            }

            [directoryPaths addObject:[parent copy]];
        }

        if (!valid) {
            break;
        }

        // Reject a file that was previously used as an
        // implicit parent directory.
        if (!isDirectoryEntry &&
            [directoryPaths containsObject:normalizedName]) {
            valid = NO;
            break;
        }

        [seen addObject:normalizedName];

        unsigned long mode =
            (info.external_fa >> 16) & 0170000;

        if (mode != 0 &&
            mode != 0100000 &&
            mode != 0040000) {
            valid = NO;
            break;
        }

        if (info.uncompressed_size > 1073741824ULL ||
            totalSize > 2147483648ULL -
                info.uncompressed_size) {
            valid = NO;
            break;
        }

        totalSize += info.uncompressed_size;

        if (i + 1 < globalInfo.number_entry &&
            unzGoToNextFile(archive) != UNZ_OK) {
            valid = NO;
            break;
        }
    }

    if (!valid ||
        unzGoToFirstFile(archive) != UNZ_OK) {
        NSLog(@"KI_EXTRACT_DIAG: PASS1_FAILED");
        unzClose(archive);
        return NO;
    }

    NSError *error = nil;

    NSLog(@"KI_EXTRACT_DIAG: PASS1_PASSED");

    if (![fm createDirectoryAtPath:outputPath
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&error]) {
        unzClose(archive);
        return NO;
    }

    NSLog(@"KI_EXTRACT_DIAG: PASS2_BEGIN");

    // Pass 2: Extract files after successful validation.
    for (uint64_t i = 0; i < globalInfo.number_entry; i++) {
        unz_file_info64 info = {};

        if (unzGetCurrentFileInfo64(
            archive, &info, nullptr, 0,
            nullptr, 0, nullptr, 0
        ) != UNZ_OK) {
            NSLog(
                    @"KI_EXTRACT_PASS2_FAIL: line=%d entry=%llu",
                    __LINE__,
                    (unsigned long long)i
                );
                valid = NO;
            break;
        }

        std::vector<char> filename(info.size_filename + 1, 0);

        if (unzGetCurrentFileInfo64(
            archive, &info, filename.data(),
            static_cast<uLong>(filename.size()),
            nullptr, 0, nullptr, 0
        ) != UNZ_OK) {
            NSLog(
                    @"KI_EXTRACT_PASS2_FAIL: line=%d entry=%llu",
                    __LINE__,
                    (unsigned long long)i
                );
                valid = NO;
            break;
        }

        NSString *name =
            [NSString stringWithUTF8String:filename.data()];

        if (name == nil) {
            NSLog(
                    @"KI_EXTRACT_PASS2_FAIL: line=%d entry=%llu",
                    __LINE__,
                    (unsigned long long)i
                );
                valid = NO;
            break;
        }

        // KI_DESTINATION_CONTAINMENT_CHECK
        // KI_TVOS_CANONICAL_CONTAINMENT_FIX
        // Canonicalize the extraction root before constructing
        // destination paths, avoiding /var vs /private/var mismatches.
        NSString *root = [
            [outputPath stringByStandardizingPath]
            stringByResolvingSymlinksInPath
        ];

        root = [root stringByStandardizingPath];

        NSString *destination = [
            [root stringByAppendingPathComponent:name]
            stringByStandardizingPath
        ];

        NSString *rootPrefix =
            [root stringByAppendingString:@"/"];

        // KI_TVOS_CONTAINMENT_PATH_DIAG
        if (i == 0) {
            NSLog(@"KI_PATH_DIAG: name=%@", name);
            NSLog(@"KI_PATH_DIAG: root=%@", root);
            NSLog(@"KI_PATH_DIAG: destination=%@", destination);
            NSLog(@"KI_PATH_DIAG: rootPrefix=%@", rootPrefix);
        }

        if (![destination hasPrefix:rootPrefix]) {
            NSLog(
                    @"KI_EXTRACT_PASS2_FAIL: line=%d entry=%llu",
                    __LINE__,
                    (unsigned long long)i
                );
                valid = NO;
            break;
        }

        // Resolve existing filesystem links before writing.
        NSString *resolvedDestination =
            [destination stringByResolvingSymlinksInPath];

        if (![resolvedDestination hasPrefix:rootPrefix]) {
            NSLog(
                    @"KI_EXTRACT_PASS2_FAIL: line=%d entry=%llu",
                    __LINE__,
                    (unsigned long long)i
                );
                valid = NO;
            break;
        }

        BOOL isDirectory = [name hasSuffix:@"/"];

        if (isDirectory) {
            if (![fm createDirectoryAtPath:destination
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:&error]) {
                NSLog(
                    @"KI_EXTRACT_PASS2_FAIL: line=%d entry=%llu",
                    __LINE__,
                    (unsigned long long)i
                );
                valid = NO;
                break;
            }
        } else {
            NSString *parent =
                [destination stringByDeletingLastPathComponent];

            if (![fm createDirectoryAtPath:parent
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:&error]) {
                NSLog(
                    @"KI_EXTRACT_PASS2_FAIL: line=%d entry=%llu",
                    __LINE__,
                    (unsigned long long)i
                );
                valid = NO;
                break;
            }

            if (unzOpenCurrentFile(archive) != UNZ_OK) {
                NSLog(
                    @"KI_EXTRACT_PASS2_FAIL: line=%d entry=%llu",
                    __LINE__,
                    (unsigned long long)i
                );
                valid = NO;
                break;
            }

            if (![fm createFileAtPath:destination
                            contents:nil
                          attributes:nil]) {
                unzCloseCurrentFile(archive);
                NSLog(
                    @"KI_EXTRACT_PASS2_FAIL: line=%d entry=%llu",
                    __LINE__,
                    (unsigned long long)i
                );
                valid = NO;
                break;
            }

            NSFileHandle *handle =
                [NSFileHandle fileHandleForWritingAtPath:destination];

            if (handle == nil) {
                unzCloseCurrentFile(archive);
                NSLog(
                    @"KI_EXTRACT_PASS2_FAIL: line=%d entry=%llu",
                    __LINE__,
                    (unsigned long long)i
                );
                valid = NO;
                break;
            }

            char buffer[65536];
            int count = 0;
            unsigned long long written = 0;

            while ((count = unzReadCurrentFile(
                archive, buffer, sizeof(buffer)
            )) > 0) {
                written += count;

                if (written > info.uncompressed_size) {
                    NSLog(
                    @"KI_EXTRACT_PASS2_FAIL: line=%d entry=%llu",
                    __LINE__,
                    (unsigned long long)i
                );
                valid = NO;
                    break;
                }

                @try {
                    [handle writeData:
                        [NSData dataWithBytes:buffer length:count]];
                } @catch (NSException *exception) {
                    NSLog(
                    @"KI_EXTRACT_PASS2_FAIL: line=%d entry=%llu",
                    __LINE__,
                    (unsigned long long)i
                );
                valid = NO;
                    break;
                }
            }

            [handle closeFile];

            int closeResult = unzCloseCurrentFile(archive);

            if (!valid ||
                count < 0 ||
                closeResult != UNZ_OK ||
                written != info.uncompressed_size) {
                NSLog(
                    @"KI_EXTRACT_PASS2_FAIL: line=%d entry=%llu",
                    __LINE__,
                    (unsigned long long)i
                );
                valid = NO;
                break;
            }

            // Restore regular-file permissions, including executables.
            NSNumber *permissions = @(
                (info.external_fa >> 16) & 0777
            );

            if (permissions.unsignedIntValue != 0) {
                if (![fm setAttributes:@{
                    NSFilePosixPermissions: permissions
                } ofItemAtPath:destination error:&error]) {
                    NSLog(
                    @"KI_EXTRACT_PASS2_FAIL: line=%d entry=%llu",
                    __LINE__,
                    (unsigned long long)i
                );
                valid = NO;
                    break;
                }
            }
        }

        if (i + 1 < globalInfo.number_entry &&
            unzGoToNextFile(archive) != UNZ_OK) {
            NSLog(
                    @"KI_EXTRACT_PASS2_FAIL: line=%d entry=%llu",
                    __LINE__,
                    (unsigned long long)i
                );
                valid = NO;
            break;
        }
    }

    unzClose(archive);

    if (!valid) {
        NSLog(@"KI_EXTRACT_DIAG: PASS2_FAILED");
        [fm removeItemAtPath:outputPath error:nil];
        return NO;
    }

    NSLog(@"KI_EXTRACT_DIAG: EXTRACTION_SUCCESS");
    return YES;
}



// Open a relative workspace entry without following symbolic links.
// Caller owns the returned file descriptor and must close it.
static int KIOpenContainedEntry(
    int rootFD,
    NSString *relativePath,
    BOOL expectDirectory,
    struct stat *resultStat
) {
    if (rootFD < 0 ||
        relativePath.length == 0 ||
        resultStat == nullptr) {
        return -1;
    }

    NSArray<NSString *> *components =
        [relativePath componentsSeparatedByString:@"/"];

    int currentFD = dup(rootFD);

    if (currentFD < 0) {
        return -1;
    }

    for (NSUInteger index = 0; index < components.count; index++) {
        NSString *component = components[index];

        if (component.length == 0 ||
            [component isEqualToString:@"."] ||
            [component isEqualToString:@".."] ||
            [component containsString:@"/"]) {
            close(currentFD);
            return -1;
        }

        BOOL last = index + 1 == components.count;

        int flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC;

        if (!last || expectDirectory) {
            flags |= O_DIRECTORY;
        }

        int nextFD = openat(
            currentFD,
            component.fileSystemRepresentation,
            flags
        );

        close(currentFD);

        if (nextFD < 0) {
            return -1;
        }

        currentFD = nextFD;
    }

    if (fstat(currentFD, resultStat) != 0 ||
        (expectDirectory
            ? !S_ISDIR(resultStat->st_mode)
            : !S_ISREG(resultStat->st_mode))) {
        close(currentFD);
        return -1;
    }

    return currentFD;
}

// KI_IPA_PACKAGING_IMPLEMENTATION
// Package a previously signed workspace without modifying its contents.
BOOL KIPackageIPA(NSString *sourceDirectory, NSString *destinationIPA) {
    NSLog(@"KI_PACKAGE_TRACE: ENTER");
    NSLog(@"KI_PACKAGE_TRACE: source=%@", sourceDirectory);
    NSLog(@"KI_PACKAGE_TRACE: destination=%@", destinationIPA);

    if (sourceDirectory.length == 0 || destinationIPA.length == 0) {
        NSLog(@"KI_PACKAGE_FAIL: Empty source or destination");
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *root =
        [[sourceDirectory stringByStandardizingPath]
            stringByResolvingSymlinksInPath];

    NSString *requestedDestination =
        [destinationIPA stringByStandardizingPath];

    NSString *destinationParent =
        [[requestedDestination stringByDeletingLastPathComponent]
            stringByResolvingSymlinksInPath];

    NSString *destination =
        [destinationParent stringByAppendingPathComponent:
            requestedDestination.lastPathComponent];

    BOOL isDirectory = NO;

    if (![fm fileExistsAtPath:root isDirectory:&isDirectory] ||
        !isDirectory ||
        ![fm fileExistsAtPath:destinationParent
                isDirectory:&isDirectory] ||
        !isDirectory ||
        [fm fileExistsAtPath:destination] ||
        [destination isEqualToString:root] ||
        [destination hasPrefix:
            [root stringByAppendingString:@"/"]]) {
        return NO;
    }

    NSLog(@"KI_PACKAGE_TRACE: PATH_VALIDATION_PASS");

    NSString *payload = [root stringByAppendingPathComponent:@"Payload"];

    NSDictionary *payloadAttributes =
        [fm attributesOfItemAtPath:payload error:nil];

    if (payloadAttributes == nil ||
        ![payloadAttributes[NSFileType]
            isEqualToString:NSFileTypeDirectory]) {
        return NO;
    }

    NSLog(@"KI_PACKAGE_TRACE: PAYLOAD_VALIDATION_PASS");

    // Reject symbolic links before creating an archive.
    // Record enumeration errors so incomplete archives are rejected.
    __block BOOL enumerationFailed = NO;

    NSDirectoryEnumerator *enumerator =
        [fm enumeratorAtURL:[NSURL fileURLWithPath:root]
 includingPropertiesForKeys:@[
     NSURLIsDirectoryKey,
     NSURLIsRegularFileKey,
     NSURLIsSymbolicLinkKey,
     NSURLFileSizeKey
 ]
                    options:0
               errorHandler:^BOOL(NSURL *url, NSError *error) {
                   enumerationFailed = YES;
                   return NO;
               }];

    if (enumerator == nil) {
        return NO;
    }

    NSMutableArray<NSURL *> *entries = [NSMutableArray array];
    unsigned long long totalSize = 0;

    for (NSURL *url in enumerator) {
        NSNumber *isLink = nil;
        NSNumber *isFile = nil;
        NSNumber *isDir = nil;
        NSNumber *size = nil;

        if (![url getResourceValue:&isLink
                            forKey:NSURLIsSymbolicLinkKey error:nil] ||
            ![url getResourceValue:&isFile
                            forKey:NSURLIsRegularFileKey error:nil] ||
            ![url getResourceValue:&isDir
                            forKey:NSURLIsDirectoryKey error:nil]) {
            return NO;
        }

        if (isLink.boolValue ||
            (!isFile.boolValue && !isDir.boolValue)) {
            return NO;
        }

        if (isFile.boolValue) {
            if (![url getResourceValue:&size
                                forKey:NSURLFileSizeKey error:nil]) {
                return NO;
            }

            unsigned long long length = size.unsignedLongLongValue;

            if (length > 1073741824ULL ||
                totalSize > 2147483648ULL - length) {
                return NO;
            }

            totalSize += length;
        }

        if (entries.count >= 50000) {
            return NO;
        }

        [entries addObject:url];
    }

    if (enumerationFailed || entries.count == 0) {
        return NO;
    }

    NSLog(
        @"KI_PACKAGE_TRACE: ENUMERATION_PASS entries=%lu",
        (unsigned long)entries.count
    );

    [entries sortUsingComparator:^NSComparisonResult(
        NSURL *a, NSURL *b
    ) {
        return [a.path compare:b.path];
    }];

    NSLog(@"KI_PACKAGE_TRACE: ENUMERATION_SORTED");

    // Create a private staging directory beside the destination.
    // Minizip must never open the final destination directly.
    NSString *parent =
        [destination stringByDeletingLastPathComponent];

    NSString *stagingTemplate =
        [parent stringByAppendingPathComponent:
            @".khmerinstaller-ipa-XXXXXX"];

    char *templateBuffer = strdup(
        stagingTemplate.fileSystemRepresentation
    );

    if (templateBuffer == nullptr) {
        return NO;
    }

    char *createdDirectory = mkdtemp(templateBuffer);

    if (createdDirectory == nullptr) {
        free(templateBuffer);
        return NO;
    }

    NSString *stagingDirectory =
        [fm stringWithFileSystemRepresentation:createdDirectory
                                       length:strlen(createdDirectory)];

    free(templateBuffer);

    NSString *temporaryIPA =
        [stagingDirectory stringByAppendingPathComponent:@"signed.ipa"];

    NSLog(@"KI_PACKAGE_TRACE: STAGING_CREATED");

    zipFile archive = zipOpen64(temporaryIPA.UTF8String,
                                APPEND_STATUS_CREATE);

    if (archive == nullptr) {
        NSLog(@"KI_PACKAGE_FAIL: zipOpen64 errno=%d", errno);
        [fm removeItemAtPath:stagingDirectory error:nil];
        return NO;
    }

    // Anchor all subsequent file access to the workspace root.
    int rootFD = open(
        root.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    );

    BOOL success = rootFD >= 0;

    // Track sizes from actual opened filesystem objects.
    unsigned long long actualTotalSize = 0;

    if (success) {
        struct stat rootStat = {};
        if (fstat(rootFD, &rootStat) != 0 ||
            !S_ISDIR(rootStat.st_mode)) {
            success = NO;
        }
    }

    for (NSURL *url in entries) {
        if (!success) {
            break;
        }

        NSString *rootPrefix =
            [root stringByAppendingString:@"/"];

        // KI_TVOS_PACKAGE_PATH_DIAG
        if ([url isEqual:entries.firstObject]) {
            NSLog(@"KI_PACKAGE_PATH_DIAG: root=%@", root);
            NSLog(@"KI_PACKAGE_PATH_DIAG: entry=%@", url.path);
            NSLog(@"KI_PACKAGE_PATH_DIAG: prefix=%@", rootPrefix);
        }

        // KI_TVOS_PACKAGE_CANONICAL_PATH_FIX
        // Resolve the enumerated path into the same filesystem
        // representation as root before checking containment.
        NSString *canonicalEntry = [
            [url.path stringByStandardizingPath]
            stringByResolvingSymlinksInPath
        ];

        canonicalEntry = [
            canonicalEntry stringByStandardizingPath
        ];

        if (![canonicalEntry hasPrefix:rootPrefix]) {
            NSLog(@"KI_PACKAGE_FAIL: ENTRY_PATH_MISMATCH");
            success = NO;
            break;
        }

        NSString *relative =
            [canonicalEntry substringFromIndex:rootPrefix.length];

        if (relative.length == 0 ||
            [relative hasPrefix:@"/"] ||
            [relative containsString:@"//"] ||
            [relative containsString:@"\\"] ||
            [relative containsString:@":"] ||
            [relative rangeOfCharacterFromSet:
                [NSCharacterSet controlCharacterSet]].location
                    != NSNotFound) {
            success = NO;
            break;
        }

        NSArray<NSString *> *components =
            [relative componentsSeparatedByString:@"/"];

        for (NSString *component in components) {
            if (component.length == 0 ||
                [component isEqualToString:@"."] ||
                [component isEqualToString:@".."]) {
                success = NO;
                break;
            }
        }

        if (!success ||
            [relative lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
                > 4095) {
            success = NO;
            break;
        }

        // Open the actual entry through the trusted root descriptor.
        // Do not trust path-based metadata collected during enumeration.
        struct stat entryStat = {};

        NSNumber *directoryFlag = nil;

        if (![url getResourceValue:&directoryFlag
                            forKey:NSURLIsDirectoryKey
                             error:nil]) {
            success = NO;
            break;
        }

        BOOL isDirectoryEntry = directoryFlag.boolValue;

        int entryFD = KIOpenContainedEntry(
            rootFD,
            relative,
            isDirectoryEntry,
            &entryStat
        );

        if (entryFD < 0) {
            success = NO;
            break;
        }

        if (isDirectoryEntry) {
            relative = [relative stringByAppendingString:@"/"];
        }

        if ([relative lengthOfBytesUsingEncoding:NSUTF8StringEncoding]
                > 4096) {
            close(entryFD);
            success = NO;
            break;
        }

        if (!isDirectoryEntry) {
            if (entryStat.st_size < 0) {
                close(entryFD);
                success = NO;
                break;
            }

            unsigned long long fileSize =
                (unsigned long long)entryStat.st_size;

            if (fileSize > 1073741824ULL ||
                actualTotalSize > 2147483648ULL - fileSize) {
                close(entryFD);
                success = NO;
                break;
            }

            actualTotalSize += fileSize;
        }

        zip_fileinfo info = {};

        // Preserve Unix file type and permissions.
        info.external_fa =
            ((unsigned long)(entryStat.st_mode & 0177777)) << 16;

        // Use the modification time of the opened filesystem object.
        NSDate *modified = [NSDate dateWithTimeIntervalSince1970:
            entryStat.st_mtimespec.tv_sec];

        NSCalendar *calendar = [NSCalendar currentCalendar];

        NSDateComponents *date = [calendar components:
            NSCalendarUnitYear |
            NSCalendarUnitMonth |
            NSCalendarUnitDay |
            NSCalendarUnitHour |
            NSCalendarUnitMinute |
            NSCalendarUnitSecond
            fromDate:modified];

        info.tmz_date.tm_year = (int)date.year;
        info.tmz_date.tm_mon = (int)date.month - 1;
        info.tmz_date.tm_mday = (int)date.day;
        info.tmz_date.tm_hour = (int)date.hour;
        info.tmz_date.tm_min = (int)date.minute;
        info.tmz_date.tm_sec = (int)date.second;

        int result = zipOpenNewFileInZip4_64(
            archive,
            relative.UTF8String,
            &info,
            nullptr, 0,
            nullptr, 0,
            nullptr,
            Z_DEFLATED,
            Z_DEFAULT_COMPRESSION,
            0,
            -MAX_WBITS,
            DEF_MEM_LEVEL,
            Z_DEFAULT_STRATEGY,
            nullptr,
            0,
            0x031E, // Unix creator platform, ZIP version 3.0
            0,      // Default general-purpose flags
            1       // ZIP64
        );

        if (result != ZIP_OK) {
            NSLog(
                @"KI_PACKAGE_FAIL: zipOpenNewFile result=%d path=%@",
                result, relative
            );
            close(entryFD);
            success = NO;
            break;
        }

        if (!isDirectoryEntry) {
            unsigned char buffer[65536];
            ssize_t count = 0;
            unsigned long long written = 0;

            while ((count = read(
                entryFD, buffer, sizeof(buffer)
            )) > 0) {
                written += (unsigned long long)count;

                if (written >
                    (unsigned long long)entryStat.st_size ||
                    zipWriteInFileInZip(
                        archive,
                        buffer,
                        (unsigned int)count
                    ) != ZIP_OK) {
                    success = NO;
                    break;
                }
            }

            if (count < 0 ||
                written !=
                    (unsigned long long)entryStat.st_size) {
                success = NO;
            }
        }

        close(entryFD);

        int entryCloseResult = zipCloseFileInZip(archive);
        if (entryCloseResult != ZIP_OK) {
            NSLog(
                @"KI_PACKAGE_FAIL: zipCloseFile result=%d path=%@",
                entryCloseResult, relative
            );
            success = NO;
        }

        if (!success) {
            break;
        }
    }

    if (rootFD >= 0) {
        close(rootFD);
    }

    int archiveCloseResult = zipClose(archive, nullptr);
    if (archiveCloseResult != ZIP_OK) {
        NSLog(
            @"KI_PACKAGE_FAIL: zipClose result=%d",
            archiveCloseResult
        );
        success = NO;
    }

    if (success) {
        // link() publishes without replacing an existing destination.
        // Both paths are on the same filesystem.
        if (link(temporaryIPA.fileSystemRepresentation,
                 destination.fileSystemRepresentation) != 0) {
            NSLog(
                @"KI_PACKAGE_FAIL: link errno=%d",
                errno
            );
            success = NO;
        }
    }

    // Remove only our private staging directory.
    [fm removeItemAtPath:stagingDirectory error:nil];

    return success;
}

bool CheckIfSigned(NSString *filePath) {
	ZTimer gtimer;
	@autoreleasepool {
		std::string filePathStr = [filePath UTF8String];
		
		ZMachO machO;
		bool initSuccess = machO.Init(filePathStr.c_str());
		if (!initSuccess) {
			gtimer.Print(">>> Failed to initialize ZMachO.");
			return false;
		}
		
		bool success = machO.CheckSignature();
		
		machO.Free();
		
		if (success) {
			gtimer.Print(">>> MachO is signed!");
			return true;
		} else {
			gtimer.Print(">>> MachO is not signed.");
			return false;
		}
	}
}

bool InjectDyLib(NSString *filePath, NSString *dylibPath, bool weakInject) {
	ZTimer gtimer;
	@autoreleasepool {
		std::string filePathStr = [filePath UTF8String];
		std::string dylibPathStr = [dylibPath UTF8String];
		
		ZMachO machO;
		bool initSuccess = machO.Init(filePathStr.c_str());
		if (!initSuccess) {
			gtimer.Print(">>> Failed to initialize ZMachO.");
			return false;
		}
		
		bool success = machO.InjectDylib(weakInject, dylibPathStr.c_str());
		
		machO.Free();
		
		if (success) {
			gtimer.Print(">>> Dylib injected successfully!");
			return true;
		} else {
			gtimer.Print(">>> Failed to inject dylib.");
			return false;
		}
	}
}

bool UninstallDylibs(NSString *filePath, NSArray<NSString *> *dylibPathsArray) {
	ZTimer gtimer;
	@autoreleasepool {
		std::string filePathStr = [filePath UTF8String];
		std::set<std::string> dylibsToRemove;
		
		for (NSString *dylibPath in dylibPathsArray) {
			dylibsToRemove.insert([dylibPath UTF8String]);
		}
		
		ZMachO machO;
		bool initSuccess = machO.Init(filePathStr.c_str());
		if (!initSuccess) {
			gtimer.Print(">>> Failed to initialize ZMachO.");
			return false;
		}
		
		machO.RemoveDylibs(dylibsToRemove);
		
		machO.Free();
		
		gtimer.Print(">>> Dylibs uninstalled successfully!");
		return true;
	}
}

NSArray<NSString *> *ListDylibs(NSString *filePath) {
	ZTimer gtimer;
	@autoreleasepool {
		NSMutableArray<NSString *> *dylibPathsArray = [NSMutableArray array];
		
		std::string filePathStr = [filePath UTF8String];
		
		ZMachO machO;
		bool initSuccess = machO.Init(filePathStr.c_str());
		if (!initSuccess) {
			gtimer.Print(">>> Failed to initialize ZMachO.");
			return nil;
		}
		
		std::vector<std::string> dylibPaths = machO.ListDylibs();
		
		if (!dylibPaths.empty()) {
			gtimer.Print(">>> List of dylibs in the Mach-O file:");
			for (const std::string &dylibPath : dylibPaths) {
				NSString *dylibPathStr = [NSString stringWithUTF8String:dylibPath.c_str()];
				[dylibPathsArray addObject:dylibPathStr];
			}
		} else {
			gtimer.Print(">>> No dylibs found in the Mach-O file.");
		}
		
		machO.Free();
		
		return [dylibPathsArray copy];
	}
}

bool ChangeDylibPath(NSString *filePath, NSString *oldPath, NSString *newPath) {
	ZTimer gtimer;
	@autoreleasepool {
		std::string filePathStr = [filePath UTF8String];
		std::string oldPathStr = [oldPath UTF8String];
		std::string newPathStr = [newPath UTF8String];
		
		ZMachO machO;
		bool initSuccess = machO.Init(filePathStr.c_str());
		if (!initSuccess) {
			gtimer.Print(">>> Failed to initialize ZMachO.");
			return false;
		}
		
		bool success = machO.ChangeDylibPath(oldPathStr.c_str(), newPathStr.c_str());
		
		machO.Free();
		
		if (success) {
			gtimer.Print(">>> Dylib path changed successfully!");
			return true;
		} else {
			gtimer.Print(">>> Failed to change dylib path.");
			return false;
		}
	}
}

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
	bool excludeprovion,
	void(^completionHandler)(BOOL success)
) {
	ZTimer atimer;
	ZTimer gtimer;
	
	bool bForce = true;
	bool bWeakInject = false;
	bool bAdhoc = adhoc;
	// KI_SHA256_ONLY_TEST
    // Match Xcode's SHA-256-only CodeDirectory.
    bool bSHA256Only = true;
	
	string strCertFile;
	string strPKeyFile;
	string strProvFile;
	string strPassword;
	string strBundleId;
	string strBundleVersion;
	string strDisplayName;
	string strEntitleFile;
	vector<string> arrDylibFiles;
	vector<string> arrDisDylibFiles;
	
	strPKeyFile = [key cStringUsingEncoding:NSUTF8StringEncoding];
	strProvFile = [prov cStringUsingEncoding:NSUTF8StringEncoding];
	strPassword = [pass cStringUsingEncoding:NSUTF8StringEncoding];
	strEntitleFile = [entitlement cStringUsingEncoding:NSUTF8StringEncoding];
	
	strBundleId = [bundleid cStringUsingEncoding:NSUTF8StringEncoding];
	strDisplayName = [displayname cStringUsingEncoding:NSUTF8StringEncoding];
	strBundleVersion = [bundleversion cStringUsingEncoding:NSUTF8StringEncoding];
	
	string strPath = [app cStringUsingEncoding:NSUTF8StringEncoding];
	if (!ZFile::IsFileExists(strPath.c_str())) {
		ZLog::ErrorV(">>> Invalid path! %s\n", strPath.c_str());
		return -1;
	}
	
	ZSignAsset zsa;
	if (!zsa.Init(strCertFile, strPKeyFile, strProvFile, strEntitleFile, strPassword, bAdhoc, bSHA256Only, false)) {
		return -1;
	}
	
	bool bEnableCache = true;
	string strFolder = strPath;
	
	atimer.Reset();
	ZBundle bundle;
	bool bRet = bundle.SignFolder(&zsa, strFolder, strBundleId, strBundleVersion, strDisplayName, arrDylibFiles, arrDisDylibFiles, bForce, bWeakInject, bEnableCache, excludeprovion);
	ZLog::PrintV(">>> Signing:\t%s %s\n", strPath.c_str(), (bAdhoc ? " (Ad-hoc)" : ""));
	atimer.PrintResult(bRet, ">>> Signed %s!", bRet ? "OK" : "Failed");
	
	if (completionHandler != nil) {
        completionHandler(bRet);
    }
	
	gtimer.Print(">>> Done.");
	return bRet ? 0 : -1;
}


// KI_TVOS_MULTIPROFILE_BRIDGE
int zsignMultipleProfiles(
    NSString *app,
    NSArray<NSString *> *provisionPaths,
    NSString *key,
    NSString *password,
    void(^completionHandler)(BOOL success)
) {
    bool success = false;

    // Keep signing assets alive until SignFolder completes.
    do {
        if (app == nil || key == nil ||
            password == nil || provisionPaths == nil ||
            provisionPaths.count == 0) {
            break;
        }

        const string appPath = [app UTF8String];
        const string keyPath = [key UTF8String];
        const string keyPassword = [password UTF8String];

        if (!ZFile::IsFileExists(appPath.c_str()) ||
            !ZFile::IsFileExists(keyPath.c_str())) {
            break;
        }

        std::list<ZSignAsset> assets;
        bool allAssetsInitialized = true;

        for (NSString *profilePath in provisionPaths) {
            if (![profilePath isKindOfClass:[NSString class]] ||
                profilePath.length == 0) {
                break;
            }

            const string path = [profilePath UTF8String];

            if (!ZFile::IsFileExists(path.c_str())) {
                break;
            }

            // Construct directly inside the list.
            assets.emplace_back();

            if (!assets.back().Init(
                "",
                keyPath,
                path,
                "",
                keyPassword,
                false,
                true,
                false
            )) {
                assets.pop_back();
                allAssetsInitialized = false;
                break;
            }
        }

        if (!allAssetsInitialized ||
            assets.size() != provisionPaths.count) {
            break;
        }

        ZBundle bundle;

        const vector<string> emptyDylibs;

        success = bundle.SignFolder(
            &assets,
            appPath,
            "",
            "",
            "",
            emptyDylibs,
            emptyDylibs,
            true,
            false,
            false,
            false
        );

    } while (false);

    if (completionHandler != nil) {
        completionHandler(success);
    }

    return success ? 0 : -1;
}

int checkCert(
	NSString *prov,
	NSString *key,
	NSString *pass,
	void(^completionHandler)(int status, NSDate* expirationDate, NSString *error)
) {
	ZTimer gtimer;
	
	string strCertFile;
	string strPKeyFile;
	string strProvFile;
	string strPassword;
	string strEntitleFile;
		
	if (!key || !prov || !pass) {
		completionHandler(2, nil, @"One or more required paths or password is missing.");
		return -1;
	}
		
	strPKeyFile = [key cStringUsingEncoding:NSUTF8StringEncoding];
	strProvFile = [prov cStringUsingEncoding:NSUTF8StringEncoding];
	strPassword = [pass cStringUsingEncoding:NSUTF8StringEncoding];

	__block ZSignAsset zsa;
		
	if (!zsa.Init(strCertFile, strPKeyFile, strProvFile, strEntitleFile, strPassword, false, false, false)) {
		completionHandler(2, nil, @"Unable to initialize certificate. Please check your password.");
		return -1;
	}
		
	X509* cert = (X509*)zsa.m_x509Cert;
	if (!cert) {
		completionHandler(2, nil, @"Error loading certificate");
		return -4;
	}
	BIO *brother1;
	unsigned long issuerHash = X509_issuer_name_hash((X509*)cert);
	if (0x817d2f7a == issuerHash) {
		brother1 = BIO_new_mem_buf(ZSignAsset::s_szAppleDevCACert, (int)strlen(ZSignAsset::s_szAppleDevCACert));
	} else if (0x9b16b75c == issuerHash) {
		brother1 = BIO_new_mem_buf(ZSignAsset::s_szAppleDevCACertG3, (int)strlen(ZSignAsset::s_szAppleDevCACertG3));
	} else {
		completionHandler(2, nil, @"Unable to determine issuer of the certificate. It is signed by Apple Developer?");
		return -2;
	}
		
	if (!brother1)
	{
		completionHandler(2, nil, @"Unable to initialize issuer certificate.");
		return -3;
	}
		
	X509 *issuer = PEM_read_bio_X509(brother1, NULL, 0, NULL);
	
	if (!cert || !issuer) {
		completionHandler(2, nil, @"Error loading cert or issuer");
		return -4;
	}
	
	// Extract OCSP URL from cert
	STACK_OF(ACCESS_DESCRIPTION)* aia = (STACK_OF(ACCESS_DESCRIPTION)*)X509_get_ext_d2i((X509*)cert, NID_info_access, 0, 0);
	if (!aia) {
		completionHandler(2, nil, @"No AIA (OCSP) extension found in certificate");
		return -5;
	}
	
	ASN1_IA5STRING* uri = nullptr;
	for (int i = 0; i < sk_ACCESS_DESCRIPTION_num(aia); i++) {
		ACCESS_DESCRIPTION* ad = sk_ACCESS_DESCRIPTION_value(aia, i);
		if (OBJ_obj2nid(ad->method) == NID_ad_OCSP &&
			ad->location->type == GEN_URI) {
			uri = ad->location->d.uniformResourceIdentifier;
			
			break;
		}
	}
	
	if (!uri) {
		completionHandler(2, nil, @"No OCSP URI found in certificate.");
		return -6;
	}
	
	OCSP_REQUEST* req = OCSP_REQUEST_new();
	OCSP_CERTID* cert_id = OCSP_cert_to_id(nullptr, (X509*)cert, issuer);
	OCSP_request_add0_id(req, cert_id);
	cert_id = OCSP_cert_to_id(nullptr, (X509*)cert, issuer);
	unsigned char* der = 0;
	int len = i2d_OCSP_REQUEST(req, &der);
	
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithUTF8String:(const char *)uri->data]]];
	[request setHTTPMethod:@"POST"];
	[request setHTTPBody:[NSData dataWithBytes:der length:len]];
	[request setValue:@"application/ocsp-request" forHTTPHeaderField:@"Content-Type"];
	[request setValue:@"application/ocsp-response" forHTTPHeaderField:@"Accept"];
	
	OPENSSL_free(der);
	if (aia) {
		sk_ACCESS_DESCRIPTION_pop_free(aia, ACCESS_DESCRIPTION_free);
	}
	OCSP_REQUEST_free(req);
	X509_free(issuer);
	BIO_free(brother1);
	
	// Read the date before starting the request, so the asynchronous
	// completion does not need a borrowed certificate pointer.
	NSDate *expirationDate = nil;
	const ASN1_TIME *expirationTime = X509_get0_notAfter(cert);
	struct tm expirationComponents = {};
	if (expirationTime && ASN1_TIME_to_tm(expirationTime, &expirationComponents) == 1) {
		NSDateComponents *components = [[NSDateComponents alloc] init];
		components.year = expirationComponents.tm_year + 1900;
		components.month = expirationComponents.tm_mon + 1;
		components.day = expirationComponents.tm_mday;
		components.hour = expirationComponents.tm_hour;
		components.minute = expirationComponents.tm_min;
		components.second = expirationComponents.tm_sec;
		NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
		calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
		expirationDate = [calendar dateFromComponents:components];
	}

	// A copied completion block retains this ID, including on error/cancellation.
	const std::shared_ptr<OCSP_CERTID> responseCertID(cert_id, OCSP_CERTID_free);
	NSURLSession *session = [NSURLSession sharedSession];
	NSURLSessionDataTask *task = [session dataTaskWithRequest:request
		completionHandler:^(NSData * _Nullable data,
			NSURLResponse * _Nullable response,
			NSError * _Nullable error) {
		if (error) {
			completionHandler(2, nil, error.localizedDescription);
			return;
		}

		if (![response isKindOfClass:[NSHTTPURLResponse class]] ||
			[(NSHTTPURLResponse *)response statusCode] != 200 ||
			!data || data.length == 0 || data.length > LONG_MAX) {
			completionHandler(2, nil, @"Invalid response or no data");
			return;
		}

		const unsigned char *respBytes = static_cast<const unsigned char *>(data.bytes);
		const unsigned char *responseEnd = respBytes + data.length;
		// nullptr requests a new object; never pass an uninitialized output pointer.
		std::unique_ptr<OCSP_RESPONSE, decltype(&OCSP_RESPONSE_free)> resp(
			d2i_OCSP_RESPONSE(nullptr, &respBytes, static_cast<long>(data.length)),
			OCSP_RESPONSE_free);
		if (!resp || respBytes != responseEnd) {
			completionHandler(2, nil, @"Unable to decode OCSP response");
			return;
		}
		if (OCSP_response_status(resp.get()) != OCSP_RESPONSE_STATUS_SUCCESSFUL) {
			completionHandler(2, nil, @"OCSP responder returned an error");
			return;
		}

		std::unique_ptr<OCSP_BASICRESP, decltype(&OCSP_BASICRESP_free)> basic(
			OCSP_response_get1_basic(resp.get()), OCSP_BASICRESP_free);
		if (!basic || !responseCertID) {
			completionHandler(2, nil, @"Missing OCSP response details or certificate ID");
			return;
		}

		int status = V_OCSP_CERTSTATUS_UNKNOWN;
		int reason = 0;
		if (OCSP_resp_find_status(basic.get(), responseCertID.get(),
			&status, &reason, nullptr, nullptr, nullptr)) {
			completionHandler(status, expirationDate, nil);
		} else {
			completionHandler(2, expirationDate, @"Certificate not found in OCSP response");
		}
	}];

	[task resume];
	return 1;
}



}
