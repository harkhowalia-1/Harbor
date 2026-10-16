// Keychain fallback. A locally signed app has no keychain-access-groups entitlement, so the
// data-protection keychain answers errSecMissingEntitlement (-34018) and login/session SDKs
// fail. When that happens, SecItem* calls are served from a per-app store in the container.
// Passwords, internet passwords and generic data items are supported; keys and certificates
// (SecKeyRef / SecCertificateRef values) still go to the real keychain.
#import "HBRuntime.h"
#import <Security/Security.h>

typedef struct {
    const void *replacement;
    const void *original;
} HBInterpose;

#define HB_INTERPOSE(replacement, original)                                                        \
    __attribute__((used)) static const HBInterpose hb_interpose_##original                          \
        __attribute__((section("__DATA,__interpose"))) = {(const void *)(uintptr_t)&replacement, \
                                                          (const void *)(uintptr_t)&original};

static NSString *const HBPersistentRefKey = @"harbor_ref";

@interface HBKeychainStore : NSObject
@property (class, readonly) HBKeychainStore *shared;
@property (atomic) BOOL active;
- (OSStatus)add:(NSDictionary *)attributes result:(CFTypeRef *)result;
- (OSStatus)copyMatching:(NSDictionary *)query result:(CFTypeRef *)result;
- (OSStatus)update:(NSDictionary *)query with:(NSDictionary *)changes;
- (OSStatus)delete:(NSDictionary *)query;
@end

@implementation HBKeychainStore {
    NSMutableArray<NSMutableDictionary *> *_items;
    NSString *_path;
}

+ (HBKeychainStore *)shared {
    static HBKeychainStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [[HBKeychainStore alloc] init]; });
    return store;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    NSString *folder = HBConfig.shared.containerFolder;
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    _path = [folder stringByAppendingPathComponent:@"Keychain.plist"];
    NSData *data = [NSData dataWithContentsOfFile:_path];
    id loaded = data ? [NSPropertyListSerialization propertyListWithData:data
                                                                 options:NSPropertyListMutableContainers
                                                                  format:nil
                                                                   error:nil]
                     : nil;
    _items = [loaded isKindOfClass:NSMutableArray.class] ? loaded : [NSMutableArray array];
    return self;
}

- (void)persist {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:_items
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:nil];
    [data writeToFile:_path options:NSDataWritingAtomic error:nil];
}

/// Keys that describe the item (as opposed to return/match/use options or values).
static BOOL HBIsAttribute(NSString *key) {
    static NSSet *ignored;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ignored = [NSSet setWithObjects:(__bridge id)kSecAttrAccessGroup, (__bridge id)kSecAttrAccessible,
                                        (__bridge id)kSecAttrAccessControl, (__bridge id)kSecAttrSynchronizable,
                                        (__bridge id)kSecUseDataProtectionKeychain, (__bridge id)kSecAttrIsPermanent,
                                        nil];
    });
    if (![key isKindOfClass:NSString.class] || [ignored containsObject:key]) return NO;
    for (NSString *prefix in @[@"r_", @"m_", @"u_", @"v_"]) {
        if ([key hasPrefix:prefix]) return NO;
    }
    return YES;
}

static BOOL HBSupportedClass(id cls) {
    return [cls isEqual:(__bridge id)kSecClassGenericPassword] || [cls isEqual:(__bridge id)kSecClassInternetPassword];
}

/// Attributes that make an item unique, per class (as the real keychain defines them).
static NSArray *HBPrimaryKeys(id cls) {
    if ([cls isEqual:(__bridge id)kSecClassInternetPassword]) {
        return @[(__bridge id)kSecAttrAccount, (__bridge id)kSecAttrServer, (__bridge id)kSecAttrProtocol,
                 (__bridge id)kSecAttrPort, (__bridge id)kSecAttrPath, (__bridge id)kSecAttrSecurityDomain,
                 (__bridge id)kSecAttrAuthenticationType];
    }
    return @[(__bridge id)kSecAttrAccount, (__bridge id)kSecAttrService];
}

- (NSArray<NSMutableDictionary *> *)itemsMatching:(NSDictionary *)query {
    id cls = query[(__bridge id)kSecClass];
    NSData *ref = query[(__bridge id)kSecValuePersistentRef];
    NSMutableArray *found = [NSMutableArray array];
    for (NSMutableDictionary *item in _items) {
        if (cls && ![item[(__bridge id)kSecClass] isEqual:cls]) continue;
        if (ref && ![item[HBPersistentRefKey] isEqual:ref]) continue;
        BOOL matches = YES;
        for (NSString *key in query) {
            if (!HBIsAttribute(key) || [key isEqual:(__bridge id)kSecClass]) continue;
            if (![item[key] isEqual:query[key]]) {
                matches = NO;
                break;
            }
        }
        if (matches) [found addObject:item];
    }
    return found;
}

- (id)resultFor:(NSDictionary *)item options:(NSDictionary *)options {
    BOOL wantData = [options[(__bridge id)kSecReturnData] boolValue];
    BOOL wantAttributes = [options[(__bridge id)kSecReturnAttributes] boolValue];
    BOOL wantRef = [options[(__bridge id)kSecReturnPersistentRef] boolValue];
    NSInteger wanted = wantData + wantAttributes + wantRef;
    if (wanted == 1 && wantData) return item[(__bridge id)kSecValueData] ?: [NSData data];
    if (wanted == 1 && wantRef) return item[HBPersistentRefKey];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in item) {
        if (HBIsAttribute(key) && ![key isEqual:HBPersistentRefKey]) result[key] = item[key];
    }
    if (wantData) result[(__bridge id)kSecValueData] = item[(__bridge id)kSecValueData] ?: [NSData data];
    if (wantRef) result[(__bridge id)kSecValuePersistentRef] = item[HBPersistentRefKey];
    return result;
}

static BOOL HBWantsResult(NSDictionary *options) {
    return [options[(__bridge id)kSecReturnData] boolValue] || [options[(__bridge id)kSecReturnAttributes] boolValue] ||
           [options[(__bridge id)kSecReturnPersistentRef] boolValue];
}

- (OSStatus)add:(NSDictionary *)attributes result:(CFTypeRef *)result {
    @synchronized(self) {
        id cls = attributes[(__bridge id)kSecClass];
        if (!HBSupportedClass(cls)) return errSecUnimplemented;
        NSMutableDictionary *key = [NSMutableDictionary dictionaryWithObject:cls forKey:(__bridge id)kSecClass];
        for (NSString *attribute in HBPrimaryKeys(cls)) key[attribute] = attributes[attribute] ?: @"";
        for (NSMutableDictionary *item in _items) {
            BOOL same = [item[(__bridge id)kSecClass] isEqual:cls];
            for (NSString *attribute in HBPrimaryKeys(cls)) {
                same = same && [(item[attribute] ?: @"") isEqual:key[attribute]];
            }
            if (same) return errSecDuplicateItem;
        }
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        for (NSString *k in attributes) {
            if (HBIsAttribute(k)) item[k] = attributes[k];
        }
        id value = attributes[(__bridge id)kSecValueData];
        if (value && ![value isKindOfClass:NSData.class]) return errSecParam;
        if (value) item[(__bridge id)kSecValueData] = value;
        NSDate *now = [NSDate date];
        item[(__bridge id)kSecAttrCreationDate] = now;
        item[(__bridge id)kSecAttrModificationDate] = now;
        item[HBPersistentRefKey] = [[NSUUID UUID].UUIDString dataUsingEncoding:NSUTF8StringEncoding];
        [_items addObject:item];
        [self persist];
        if (result && HBWantsResult(attributes)) *result = CFBridgingRetain([self resultFor:item options:attributes]);
        return errSecSuccess;
    }
}

- (OSStatus)copyMatching:(NSDictionary *)query result:(CFTypeRef *)result {
    @synchronized(self) {
        if (!HBSupportedClass(query[(__bridge id)kSecClass]) && !query[(__bridge id)kSecValuePersistentRef]) {
            return errSecItemNotFound;
        }
        NSArray *items = [self itemsMatching:query];
        if (items.count == 0) return errSecItemNotFound;
        if (!result) return errSecSuccess;
        id limit = query[(__bridge id)kSecMatchLimit];
        BOOL all = [limit isEqual:(__bridge id)kSecMatchLimitAll] ||
                   ([limit isKindOfClass:NSNumber.class] && [limit integerValue] > 1);
        if (!HBWantsResult(query)) return errSecSuccess;
        if (all) {
            NSMutableArray *results = [NSMutableArray array];
            for (NSDictionary *item in items) [results addObject:[self resultFor:item options:query]];
            *result = CFBridgingRetain(results);
        } else {
            *result = CFBridgingRetain([self resultFor:items.firstObject options:query]);
        }
        return errSecSuccess;
    }
}

- (OSStatus)update:(NSDictionary *)query with:(NSDictionary *)changes {
    @synchronized(self) {
        NSArray *items = [self itemsMatching:query];
        if (items.count == 0) return errSecItemNotFound;
        for (NSMutableDictionary *item in items) {
            for (NSString *key in changes) {
                if (HBIsAttribute(key) || [key isEqual:(__bridge id)kSecValueData]) item[key] = changes[key];
            }
            item[(__bridge id)kSecAttrModificationDate] = [NSDate date];
        }
        [self persist];
        return errSecSuccess;
    }
}

- (OSStatus)delete:(NSDictionary *)query {
    @synchronized(self) {
        NSArray *items = [self itemsMatching:query];
        if (items.count == 0) return errSecItemNotFound;
        [_items removeObjectsInArray:items];
        [self persist];
        return errSecSuccess;
    }
}

@end

#pragma mark - Interposed SecItem API

/// The real keychain is tried first; the first errSecMissingEntitlement switches the process
/// to the per-app store for good, so items never end up split between the two.
static BOOL HBShouldEmulate(OSStatus realStatus) {
    HBKeychainStore *store = HBKeychainStore.shared;
    if (store.active) return YES;
    if (realStatus == errSecMissingEntitlement && HBConfig.shared.keychainEmulation) {
        store.active = YES;
        HBLog(@"Keychain unavailable to a locally signed app (-34018); using Harbor's per-app keychain");
        return YES;
    }
    return NO;
}

static OSStatus hb_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (HBKeychainStore.shared.active) {
        OSStatus status = [HBKeychainStore.shared add:(__bridge NSDictionary *)attributes result:result];
        if (status != errSecUnimplemented) return status;
    }
    OSStatus status = SecItemAdd(attributes, result);
    if (status == errSecMissingEntitlement && HBShouldEmulate(status)) {
        OSStatus emulated = [HBKeychainStore.shared add:(__bridge NSDictionary *)attributes result:result];
        return emulated == errSecUnimplemented ? status : emulated;
    }
    return status;
}
HB_INTERPOSE(hb_SecItemAdd, SecItemAdd)

static OSStatus hb_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (HBKeychainStore.shared.active) return [HBKeychainStore.shared copyMatching:(__bridge NSDictionary *)query result:result];
    OSStatus status = SecItemCopyMatching(query, result);
    if (status == errSecMissingEntitlement && HBShouldEmulate(status)) {
        return [HBKeychainStore.shared copyMatching:(__bridge NSDictionary *)query result:result];
    }
    return status;
}
HB_INTERPOSE(hb_SecItemCopyMatching, SecItemCopyMatching)

static OSStatus hb_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef changes) {
    if (HBKeychainStore.shared.active) {
        return [HBKeychainStore.shared update:(__bridge NSDictionary *)query with:(__bridge NSDictionary *)changes];
    }
    OSStatus status = SecItemUpdate(query, changes);
    if (status == errSecMissingEntitlement && HBShouldEmulate(status)) {
        return [HBKeychainStore.shared update:(__bridge NSDictionary *)query with:(__bridge NSDictionary *)changes];
    }
    return status;
}
HB_INTERPOSE(hb_SecItemUpdate, SecItemUpdate)

static OSStatus hb_SecItemDelete(CFDictionaryRef query) {
    if (HBKeychainStore.shared.active) return [HBKeychainStore.shared delete:(__bridge NSDictionary *)query];
    OSStatus status = SecItemDelete(query);
    if (status == errSecMissingEntitlement && HBShouldEmulate(status)) {
        return [HBKeychainStore.shared delete:(__bridge NSDictionary *)query];
    }
    return status;
}
HB_INTERPOSE(hb_SecItemDelete, SecItemDelete)
