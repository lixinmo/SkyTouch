#import "OPStoragePaths.h"
#import "OPOriginalCloudTransport.h"
#import "OPOriginalContext.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#include <cmath>
#include <cstring>
#include <limits>
#include <vector>

using OPCloudSuccess=void(^)(id);
using OPCloudFailure=void(^)(NSError *);
using OPCloudCompletion=void(^)(id,NSInteger,NSError *);
using OPCloudHTTPMethod=void(*)(id,SEL,id,id,OPCloudSuccess,OPCloudFailure);
@class OPCloudRequest;

namespace op_cloud {
enum Error : NSInteger { InvalidRequest=1, InsecureRequest=2, Transport=3, HTTP=4, JSON=5,
    InvalidEnvelope=6, ServiceRejected=7, InvalidAccount=8, InvalidCloudList=9,
    LoginRequired=10, ABI=11, Redirect=12, TooLarge=13, AccountStorage=14, Cancelled=15,
    EmptyDownload=16, InvalidDownload=17, DownloadStorage=18, DownloadParse=19,
    DownloadImport=20, DownloadBusy=21, DownloadRollback=22, CloudSourceRequired=23,
    DownloadNotListed=24, DownloadURLFormat=25, DownloadItem=26 };
static NSString *const domain=@"com.lixinmo.skytouch.cloud";
static NSString *const passportOrigin=@"https://passport.flydigi.com";
static NSString *target,*documents;
static NSString *statusPath=OPRuntimePath(@"com.lixinmo.skytouch.cloud-status.plist");
static BOOL installed=NO,loginBusy=NO,networkVerified=NO,accountVerified=NO,restoredVerification=NO;
static NSString *verifiedUID;
static NSUInteger requests=0,completed=0,failures=0,loginAttempts=0,cloudRows=0;
static uint64_t authenticationGeneration=0;
static uint64_t cloudListGeneration=0;
// The native API returns complete file URLs. Its current validated response,
// not the separate web UI's historical CDN constants, authorizes downloads.
static NSDictionary<NSString *,NSSet<NSNumber *> *> *listedDownloadVersions;
static NSDictionary *lastStatus;
static OPCloudHTTPMethod originalPost=nullptr,originalGet=nullptr;
static void(*originalClear)(id,SEL)=nullptr;
static void(*originalShowCloud)(id,SEL)=nullptr;
static void(*originalShowLogin)(id,SEL)=nullptr;
static void(*originalCloudEntry)(id,SEL,id)=nullptr;
static dispatch_block_t cloudSourceRequiredHandler;
static OPCloudRequest *loginRequest;
static OPCloudRequest *downloadRequest;
static BOOL downloadBusy=NO,stagingDownload=NO;
static NSUInteger downloadAttempts=0,downloadSaved=0,downloadFailed=0,stagedWriteCount=0;
static NSInteger downloadedPlanType=0;
static NSData *stagedFDG;
static BOOL (*originalWriteFDG)(id,SEL,int,id)=nullptr;
static BOOL bundleValid(id value) {
    return [value isKindOfClass:NSString.class] && [value length]>0 && [value length]<=255 &&
        [value rangeOfString:@"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$" options:NSRegularExpressionSearch].length==[value length];
}
static BOOL signature(Class cls,BOOL classMethod,NSString *name,const char *result,NSArray<NSString *> *arguments) {
    Method method=classMethod ? class_getClassMethod(cls,NSSelectorFromString(name)) : class_getInstanceMethod(cls,NSSelectorFromString(name));
    NSMethodSignature *s=method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
    if(!s || s.numberOfArguments!=arguments.count+2 || std::strcmp(s.methodReturnType,result))return NO;
    for(NSUInteger i=0;i<arguments.count;++i)
        if(std::strcmp([s getArgumentTypeAtIndex:i+2],arguments[i].UTF8String))return NO;
    return YES;
}
static BOOL objectSignature(id object,NSString *name,const char *result,NSArray<NSString *> *arguments) {
    return object && signature(object_getClass(object),NO,name,result,arguments);
}
static id get(id object,NSString *name) {
    return objectSignature(object,name,"@",@[]) ? ((id(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name)) : nil;
}
static id preferences(void) { return get(NSClassFromString(@"FZPreferRecordTool"),@"sharedFZPreferRecordTool"); }
static NSError *issue(Error code) {
    // Never retain a network NSError or response message here: its userInfo
    // can contain a credential-bearing URL, account name or server response.
    return [NSError errorWithDomain:domain code:code userInfo:@{NSLocalizedDescriptionKey:@"飞智云请求未通过验证，请重新登录或稍后重试。"}];
}
static void record(NSString *operation,NSString *stage,NSInteger http,NSInteger errorCode,NSInteger serverCode=0) {
    // Only these fixed labels, counters, codes, booleans and profile identity
    // leave memory. Never add payload/error descriptions to this dictionary.
    lastStatus=@{@"operation":operation,@"stage":stage,@"httpStatus":@(http),@"errorCode":@(errorCode),
        @"pid":@(getpid()),@"time":@(NSDate.date.timeIntervalSince1970),
        @"serverCode":@(serverCode),@"requestCount":@(requests),@"completedCount":@(completed),
        @"failureCount":@(failures),@"loginAttemptCount":@(loginAttempts),@"cloudItemCount":@(cloudRows),
        @"targetBundleID":target ?: @"",@"networkVerified":@(networkVerified),
        @"accountVerified":@(accountVerified),@"previouslyVerified":@(restoredVerification),
        @"downloadBusy":@(downloadBusy),@"downloadAttemptCount":@(downloadAttempts),
        @"downloadSavedCount":@(downloadSaved),@"downloadFailureCount":@(downloadFailed),
        @"downloadedPlanType":@(downloadedPlanType)};
    if(statusPath.length){[lastStatus writeToFile:statusPath atomically:YES];chmod(statusPath.fileSystemRepresentation,0600);}
}
static NSString *decimal(id value,BOOL allowZero) {
    NSString *string=nil;
    if([value isKindOfClass:NSString.class])string=value;
    else if([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()) {
        NSNumber *n=value;
        // Reject binary floating-point IDs rather than round/truncate them.
        if(std::strchr("cCsSiIlLqQ",n.objCType[0]) || [n isKindOfClass:NSDecimalNumber.class])string=n.stringValue;
    }
    if(!string.length || string.length>128)return nil;
    BOOL positive=NO;
    for(NSUInteger i=0;i<string.length;++i){unichar c=[string characterAtIndex:i];if(c<'0'||c>'9')return nil;positive=positive||c!='0';}
    return (allowZero || positive) ? string : nil;
}
static BOOL smallInteger(id value,BOOL allowZero,NSInteger *out) {
    NSString *s=decimal(value,allowZero);if(!s)return NO;
    uint64_t n=0;
    for(NSUInteger i=0;i<s.length;++i){n=n*10+([s characterAtIndex:i]-'0');if(n>INT32_MAX)return NO;}
    if(out)*out=(NSInteger)n;return YES;
}
static NSString *escape(NSString *string) {
    NSData *bytes=[string dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];if(!bytes)return nil;
    NSMutableString *encoded=[NSMutableString string];const unsigned char *p=(const unsigned char *)bytes.bytes;
    for(NSUInteger i=0;i<bytes.length;++i){unsigned char c=p[i];
        if((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'||c=='~')
            [encoded appendFormat:@"%c",c];
        else [encoded appendFormat:@"%%%02X",c];
    }
    return encoded;
}
static NSData *form(id parameters) {
    if(!parameters)parameters=@{};
    if(![parameters isKindOfClass:NSDictionary.class] || [parameters count]>128)return nil;
    NSMutableArray *pairs=[NSMutableArray array];
    for(id key in parameters)if(![key isKindOfClass:NSString.class])return nil;
    for(NSString *key in [[parameters allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        id value=parameters[key];NSString *text=nil;
        if([value isKindOfClass:NSString.class])text=value;
        else if([value isKindOfClass:NSNumber.class])text=[value stringValue];
        if(!text || key.length>1024 || text.length>1024*1024)return nil;
        NSString *a=escape(key),*b=escape(text);if(!a||!b)return nil;
        [pairs addObject:[NSString stringWithFormat:@"%@=%@",a,b]];
    }
    return [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
}
static BOOL official(NSURL *url) {
    NSString *host=url.host.lowercaseString;
    return [host isEqual:@"passport.flydigi.com"] || [host isEqual:@"api.flydigi.com"];
}
static BOOL secureURL(NSURL *url) {
    return [url.scheme.lowercaseString isEqual:@"https"] && url.host.length && !url.user && !url.password &&
        (!url.port || url.port.integerValue==443) && !url.fragment;
}
static BOOL sensitiveKey(NSString *key) {
    NSString *k=key.lowercaseString;
    return [@[@"password",@"passwd",@"pwd",@"sign",@"token",@"authorization",@"email",@"uid"] containsObject:k];
}
static BOOL containsSecret(NSURL *url,id parameters) {
    if([parameters isKindOfClass:NSDictionary.class])for(id key in parameters)
        if([key isKindOfClass:NSString.class] && sensitiveKey(key))return YES;
    if(url.user || url.password)return YES;
    for(NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems)
        if(sensitiveKey(item.name))return YES;
    return NO;
}
static BOOL redirectAllowed(NSURLRequest *original,NSURLRequest *redirected,NSUInteger count) {
    return count<3 && secureURL(redirected.URL) && [original.URL.host.lowercaseString isEqual:redirected.URL.host.lowercaseString] &&
        [original.HTTPMethod isEqual:redirected.HTTPMethod];
}
static BOOL publicDownloadHost(NSString *host) {
    if(!host.length || host.length>253)return NO;
    NSString *name=host.lowercaseString;
    if([name hasSuffix:@"."])name=[name substringToIndex:name.length-1];
    for(NSString *suffix in @[@"localhost",@"local",@"internal",@"home.arpa",@"localdomain"])
        if([name isEqual:suffix] || [name hasSuffix:[@"." stringByAppendingString:suffix]])return NO;
    NSArray<NSString *> *labels=[name componentsSeparatedByString:@"."];
    if(labels.count<2)return NO;
    // Require a DNS name, excluding IP literals, shorthand numeric addresses,
    // percent-encoded authority tricks and single-label local hostnames.
    for(NSString *label in labels)
        if(!label.length || label.length>63 || [label rangeOfString:@"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$" options:NSRegularExpressionSearch].length!=label.length)return NO;
    NSString *last=labels.lastObject;
    return [last rangeOfString:@"^(?:[a-z]{2,63}|xn--[a-z0-9-]+[a-z0-9])$" options:NSRegularExpressionSearch].length==last.length;
}
static NSURL *downloadURL(id value) {
    if(![value isKindOfClass:NSString.class] || ![value length] || [value length]>8192)return nil;
    NSString *text=[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if([text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)return nil;
    auto hex=[](unichar c){return (c>='0'&&c<='9')||(c>='a'&&c<='f')||(c>='A'&&c<='F');};
    for(NSUInteger i=0;i<text.length;++i)if([text characterAtIndex:i]=='%') {
        // NSURLComponents may repair invalid escapes on newer SDKs. Refuse
        // them rather than silently changing a server-signed path or query.
        if(i+2>=text.length || !hex([text characterAtIndex:i+1]) || !hex([text characterAtIndex:i+2]))return nil;
        i+=2;
    }
    if([text hasPrefix:@"//"])text=[@"https:" stringByAppendingString:text];
    NSURLComponents *parts=[NSURLComponents componentsWithString:text];
    if(!publicDownloadHost(parts.host) || parts.user || parts.password || parts.fragment || !parts.path.length)return nil;
    if([parts.scheme.lowercaseString isEqual:@"http"] && (!parts.port || parts.port.integerValue==80)) {
        // Attempt the exact server-provided location over TLS. Never fall
        // back to cleartext and never rewrite path/query or guess a base URL.
        parts.scheme=@"https";parts.port=nil;
    }
    return secureURL(parts.URL) ? parts.URL : nil;
}
static BOOL downloadRedirectAllowed(NSURLRequest *redirected,NSUInteger count) {
    return count<3 && [redirected.HTTPMethod isEqual:@"GET"] && secureURL(redirected.URL) &&
        publicDownloadHost(redirected.URL.host) && redirected.URL.path.length;
}
static void clearListedDownloads(void) { listedDownloadVersions=nil;++cloudListGeneration; }
static void rememberListedDownloads(NSDictionary *JSON) {
    NSMutableDictionary<NSString *,NSMutableSet<NSNumber *> *> *versions=[NSMutableDictionary dictionary];
    for(NSDictionary *row in JSON[@"data"]) {
        NSString *url=row[@"url"];NSInteger version=0;
        if(!downloadURL(url) || !smallInteger(row[@"version"],YES,&version))continue;
        if(!versions[url])versions[url]=[NSMutableSet set];
        [versions[url] addObject:@(version)];
    }
    listedDownloadVersions=[versions copy];
}
static NSString *markerPath(void) { return [documents stringByAppendingPathComponent:@"skytouch-cloud-session.plist"]; }
static NSString *digest(NSString *uid,NSString *sign) {
    NSData *a=[uid dataUsingEncoding:NSUTF8StringEncoding],*b=[sign dataUsingEncoding:NSUTF8StringEncoding];
    if(!a || !b)return nil;
    NSMutableData *bytes=[NSMutableData data];
    [bytes appendData:[[NSString stringWithFormat:@"%lu:",(unsigned long)a.length] dataUsingEncoding:NSASCIIStringEncoding]];
    [bytes appendData:a];[bytes appendData:b];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,hash);
    NSMutableString *hex=[NSMutableString stringWithCapacity:64];for(unsigned char c:hash)[hex appendFormat:@"%02x",c];return hex;
}
static NSDictionary *readMarker(void) {
    int fd=open(markerPath().fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);if(fd<0)return nil;
    struct stat s{};if(fstat(fd,&s)!=0 || !S_ISREG(s.st_mode) || s.st_nlink!=1 || s.st_size<=0 || s.st_size>16384){close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)s.st_size];size_t offset=0;
    while(offset<data.length){ssize_t n=read(fd,(char *)data.mutableBytes+offset,data.length-offset);if(n<=0)break;offset+=(size_t)n;}close(fd);
    id object=offset==data.length ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}
static void invalidateVerification(void) {
    networkVerified=NO;accountVerified=NO;restoredVerification=NO;verifiedUID=nil;
    clearListedDownloads();
    if(documents.length)unlink(markerPath().fileSystemRepresentation);
}
static BOOL writeMarker(NSString *uid,NSString *sign) {
    NSString *hash=digest(uid,sign);if(!hash)return NO;
    NSDictionary *marker=@{@"version":@1,@"origin":passportOrigin,@"verifiedAt":@(NSDate.date.timeIntervalSince1970),@"credentialDigest":hash};
    BOOL written=[marker writeToFile:markerPath() atomically:YES];if(written)chmod(markerPath().fileSystemRepresentation,0600);return written;
}
static void restoreVerification(void) {
    // Existing vendor account data alone is NEVER evidence of a real login.
    NSDictionary *marker=readMarker();id t=marker[@"verifiedAt"];
    double stamp=[t isKindOfClass:NSNumber.class] ? [t doubleValue] : NAN;
    id version=marker[@"version"];
    if(marker.count!=4 || ![version isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)version)==CFBooleanGetTypeID() ||
        !std::strchr("cCsSiIlLqQ",[(NSNumber *)version objCType][0]) || [(NSNumber *)version doubleValue]!=1 ||
        ![t isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)t)==CFBooleanGetTypeID() || ![marker[@"origin"] isEqual:passportOrigin] ||
        !std::isfinite(stamp) || stamp<=0 || stamp>NSDate.date.timeIntervalSince1970 || ![marker[@"credentialDigest"] isKindOfClass:NSString.class])return;
    @try {
        id prefs=preferences();NSString *uid=decimal(get(prefs,@"getUserId"),NO);id sign=get(prefs,@"getUserSign");
        if(uid && [sign isKindOfClass:NSString.class] && [sign length] && [marker[@"credentialDigest"] isEqual:digest(uid,sign)]) {
            verifiedUID=[uid copy];accountVerified=YES;restoredVerification=YES; // not a fresh network verification
        }
    } @catch(__unused NSException *exception) { /* Do not print archive values. */ }
}
static NSDictionary *loginAccount(id JSON,NSInteger *serverError,NSString **message,NSError **error) {
    NSInteger code=0;
    if(![JSON isKindOfClass:NSDictionary.class] || !smallInteger(JSON[@"err"],YES,&code)) {if(error)*error=issue(InvalidEnvelope);return nil;}
    if(serverError)*serverError=code;
    if(code) {
        if(message)*message=[JSON[@"msg"] isKindOfClass:NSString.class] ? JSON[@"msg"] : @"账号或密码未通过服务器验证。";
        if(error)*error=issue(ServiceRejected);return nil;
    }
    id result=JSON[@"result"];
    if(![result isKindOfClass:NSDictionary.class]){if(error)*error=issue(InvalidEnvelope);return nil;}
    NSString *uid=decimal(result[@"uid"],NO);
    id name=result[@"username"],avatar=result[@"avatar"],email=result[@"email"],sign=result[@"sign"];
    if(!uid || ![name isKindOfClass:NSString.class] || ![name length] || ![avatar isKindOfClass:NSString.class] ||
        ![email isKindOfClass:NSString.class] || ![email length] || ![sign isKindOfClass:NSString.class] ||
        ![[sign stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length]) {
        if(error)*error=issue(InvalidAccount);return nil;
    }
    return @{@"uid":uid,@"username":name,@"avatar":avatar,@"email":email,@"sign":sign};
}
static BOOL validCloudList(id JSON,NSInteger *serverError,NSError **error) {
    NSInteger code=0;
    if(![JSON isKindOfClass:NSDictionary.class] || !smallInteger(JSON[@"err"],YES,&code)){if(error)*error=issue(InvalidEnvelope);return NO;}
    if(serverError)*serverError=code;
    if(code){if(error)*error=issue(ServiceRejected);return NO;}
    id rows=JSON[@"data"];
    if(![rows isKindOfClass:NSArray.class] || [rows count]>10000){if(error)*error=issue(InvalidCloudList);return NO;}
    // Original parser at 0x4c724..4c8a4: fid/version use intValue then int
    // setters; title/url/timestamp are NSString properties (timestamp=timestick).
    for(id row in rows) {
        if(![row isKindOfClass:NSDictionary.class] || !smallInteger(row[@"fid"],NO,nullptr) || !smallInteger(row[@"version"],YES,nullptr) ||
            ![row[@"title"] isKindOfClass:NSString.class] || ![row[@"url"] isKindOfClass:NSString.class] || ![row[@"url"] length] ||
            ![row[@"timestamp"] isKindOfClass:NSString.class]) {if(error)*error=issue(InvalidCloudList);return NO;}
    }
    cloudRows=[rows count];return YES;
}
static void toast(id view,NSString *message) {
    if(objectSignature(view,@"showToast:","v",@[@"@"]))((void(*)(id,SEL,id))objc_msgSend)(view,NSSelectorFromString(@"showToast:"),message);
}
} // namespace op_cloud

@interface OPCloudRequest:NSObject <NSURLSessionDataDelegate,NSURLSessionTaskDelegate>
@property(nonatomic) NSURLSession *session;
@property(nonatomic) NSURLSessionDataTask *task;
@property(nonatomic) NSMutableData *bytes;
@property(nonatomic) NSURLRequest *request;
@property(nonatomic) NSURL *effectiveURL;
@property(nonatomic,copy) OPCloudCompletion completion;
@property(nonatomic) NSError *rejection;
@property(nonatomic) NSInteger status;
@property(nonatomic) NSUInteger redirects;
@property(nonatomic) BOOL returnsBytes;
- (void)start;
- (void)cancel;
@end
@implementation OPCloudRequest
- (void)start {
    self.effectiveURL=self.request.URL;
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.URLCache=nil;config.URLCredentialStorage=nil;config.HTTPCookieStorage=nil;config.HTTPShouldSetCookies=NO;
    config.HTTPCookieAcceptPolicy=NSHTTPCookieAcceptPolicyNever;config.HTTPAdditionalHeaders=@{};
    config.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    config.timeoutIntervalForRequest=20;config.timeoutIntervalForResource=30;
    self.bytes=[NSMutableData data];
    self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
    self.task=[self.session dataTaskWithRequest:self.request];[self.task resume];
}
- (void)cancel { [self.task cancel]; }
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session;(void)task;
    if(![response isKindOfClass:NSHTTPURLResponse.class])self.rejection=op_cloud::issue(op_cloud::HTTP);
    else {
        self.status=((NSHTTPURLResponse *)response).statusCode;
        if(self.status<200 || self.status>=300)self.rejection=op_cloud::issue(op_cloud::HTTP);
        NSURL *expected=self.effectiveURL ?: self.request.URL;
        if(!op_cloud::secureURL(response.URL) || ![response.URL.host.lowercaseString isEqual:expected.host.lowercaseString])self.rejection=op_cloud::issue(op_cloud::Redirect);
        if(response.expectedContentLength>4*1024*1024)self.rejection=op_cloud::issue(op_cloud::TooLarge);
    }
    completionHandler(self.rejection ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    (void)session;
    if(data.length>4*1024*1024-self.bytes.length){self.rejection=op_cloud::issue(op_cloud::TooLarge);[task cancel];return;}
    [self.bytes appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    (void)session;(void)task;(void)response;
    BOOL allowed=self.returnsBytes ? op_cloud::downloadRedirectAllowed(request,self.redirects++) :
        op_cloud::redirectAllowed(self.request,request,self.redirects++);
    if(!allowed) {
        self.rejection=op_cloud::issue(op_cloud::Redirect);completionHandler(nil);return;
    }
    NSMutableURLRequest *safe=[request mutableCopy];safe.HTTPShouldHandleCookies=NO;
    [safe setValue:nil forHTTPHeaderField:@"Cookie"];[safe setValue:nil forHTTPHeaderField:@"Authorization"];
    if(self.returnsBytes) {
        [safe setValue:nil forHTTPHeaderField:@"Referer"];[safe setValue:nil forHTTPHeaderField:@"Origin"];
    }
    self.effectiveURL=safe.URL;
    completionHandler(safe);
}
// No authentication-challenge override: Foundation performs normal TLS/server
// trust verification. No custom trust, credentials, certificate or TLS bypass.
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)networkError {
    (void)task;
    NSError *error=self.rejection ?: (networkError ? op_cloud::issue(op_cloud::Transport) : nil);
    if(!error && (self.status<200 || self.status>=300))error=op_cloud::issue(op_cloud::HTTP);
    id JSON=nil;
    if(!error && self.returnsBytes) {
        if(!self.bytes.length)error=op_cloud::issue(op_cloud::EmptyDownload);
        else JSON=[self.bytes copy];
    } else if(!error){JSON=[NSJSONSerialization JSONObjectWithData:self.bytes options:0 error:nil];if(!JSON)error=op_cloud::issue(op_cloud::JSON);}
    OPCloudCompletion completion=self.completion;self.completion=nil;
    NSInteger status=self.status;
    self.request=nil;self.bytes=nil;self.task=nil;
    [session finishTasksAndInvalidate];self.session=nil;
    if(completion)completion(JSON,status,error); // delegateQueue is main
}
@end

namespace op_cloud {
static OPCloudRequest *perform(NSString *method,NSURL *url,id parameters,NSString *operation,OPCloudCompletion completion) {
    NSData *encoded=form(parameters);
    if(!secureURL(url) || !official(url) || !encoded) {
        record(operation,@"request-rejected",0,InvalidRequest);
        dispatch_async(dispatch_get_main_queue(),^{completion(nil,0,issue(InvalidRequest));});return nil;
    }
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    request.HTTPMethod=method;request.HTTPShouldHandleCookies=NO;
    [request setValue:nil forHTTPHeaderField:@"Cookie"];[request setValue:nil forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if([method isEqual:@"POST"]){request.HTTPBody=encoded;[request setValue:@"application/x-www-form-urlencoded;charset=utf-8" forHTTPHeaderField:@"Content-Type"];}
    else if(encoded.length) {
        NSURLComponents *parts=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSString *query=[[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
        parts.percentEncodedQuery=parts.percentEncodedQuery.length ? [parts.percentEncodedQuery stringByAppendingFormat:@"&%@",query] : query;
        request.URL=parts.URL;
    }
    ++requests;record(operation,@"request-started",0,0);
    OPCloudRequest *transfer=[OPCloudRequest new];transfer.request=request;
    transfer.completion=^(id JSON,NSInteger status,NSError *error){
        ++completed;
        record(operation,error ? @"transport-failed" : @"response-received",status,error.code);
        completion(JSON,status,error);
    };
    [transfer start];return transfer;
}
static void clearAccount(id self,SEL command) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{clearAccount(self,command);});return;}
    ++authenticationGeneration;[loginRequest cancel];loginRequest=nil;loginBusy=NO;[downloadRequest cancel];invalidateVerification();
    originalClear(self,command);
    record(@"account",@"verification-cleared",0,0);
}
static void showCloud(id self,SEL command) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{showCloud(self,command);});return;}
    // A cached getUserId used to skip login UI even without any verified
    // server response. Redirect only this original cloud-panel entry; do not
    // delete an account/archive here. showLogin (0x5f8584..0x5f8a30) creates or
    // fronts winLogin and does not recurse through showCloudSync.
    if(!accountVerified) {
        record(@"cloud-ui",@"fresh-login-required",0,LoginRequired);
        originalShowLogin(self,NSSelectorFromString(@"showLogin"));return;
    }
    originalShowCloud(self,command);
}
static BOOL localCloudSource(void) {
    return [target isEqual:@"com.lixinmo.skytouch.local"] || [target isEqual:@"com.lixinmo.skytouch.probe"];
}
static void requireCloudSource(id view) {
    record(@"cloud-ui",@"source-selection-required",0,CloudSourceRequired);
    if(cloudSourceRequiredHandler)cloudSourceRequiredHandler();
    else if(view)toast(view,@"请先选择云方案对应的游戏，再打开飞智云配置。");
}
static void cloudEntry(id self,SEL command,id sender) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{cloudEntry(self,command,sender);});return;}
    if(localCloudSource()){requireCloudSource(self);return;}
    originalCloudEntry(self,command,sender);
}
static void login(id view,SEL command) {
    (void)command;
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{login(view,command);});return;}
    if(loginBusy){toast(view,@"正在验证账号，请稍候。");return;}
    @try {
        id email=get(get(view,@"viewTextEmail"),@"text"),password=get(get(view,@"viewTextPassword"),@"text");
        id delegate=get(view,@"delegate");
        if(![email isKindOfClass:NSString.class] || ![password isKindOfClass:NSString.class] || ![email length] || ![password length]) {
            toast(view,@"请输入账号和密码。");record(@"login",@"input-required",0,InvalidRequest);return;
        }
        if(!objectSignature(delegate,@"onLoginFinish","v",@[])){toast(view,@"登录界面接口不可用，请重新打开配置。");record(@"login",@"delegate-ABI-rejected",0,ABI);return;}
        id prefs=preferences();if(!prefs){toast(view,@"原账号存储不可用。");record(@"login",@"account-storage-unavailable",0,AccountStorage);return;}
        // Only an explicit user login attempt clears a previous local account.
        // It never clears FDG files, and never invokes the vendor's leaking
        // onBtnLogin method or its permissive success callback.
        ((void(*)(id,SEL))objc_msgSend)(prefs,NSSelectorFromString(@"clearUserInfo"));
        loginBusy=YES;++loginAttempts;const uint64_t generation=authenticationGeneration;
        __weak id owner=view;__weak id recipient=delegate;
        loginRequest=perform(@"POST",[NSURL URLWithString:@"https://passport.flydigi.com/Account/Login"],
            @{@"email":email,@"password":password},@"login",^(id JSON,NSInteger status,NSError *error){
            if(generation!=authenticationGeneration)return;
            loginBusy=NO;loginRequest=nil;
            id current=owner,receiver=recipient;
            if(!current || !receiver){invalidateVerification();record(@"login",@"interface-closed",status,Cancelled);return;}
            NSInteger serverCode=0;NSString *message=nil;
            NSDictionary *account=error ? nil : loginAccount(JSON,&serverCode,&message,&error);
            if(!account){invalidateVerification();++failures;record(@"login",@"login-rejected",status,error.code,serverCode);
                toast(current,message ?: @"登录未通过服务器验证，请检查网络和账号密码。");return;}
            @try {
                id storage=preferences();
                ((void(*)(id,SEL,id,id,id,id,id))objc_msgSend)(storage,NSSelectorFromString(@"saveUserInfo:name:avatar:email:sign:"),
                    account[@"uid"],account[@"username"],account[@"avatar"],account[@"email"],account[@"sign"]);
                if(![get(storage,@"getUserId") isEqual:account[@"uid"]] || ![get(storage,@"getUserSign") isEqual:account[@"sign"]]) {
                    invalidateVerification();++failures;record(@"login",@"account-storage-failed",status,AccountStorage);
                    toast(current,@"服务器已验证，但原账号状态未能保存，请重试。");return;
                }
                verifiedUID=account[@"uid"];networkVerified=YES;accountVerified=YES;restoredVerification=NO;
                const BOOL persisted=writeMarker(account[@"uid"],account[@"sign"]);
                record(@"login",persisted ? @"login-verified" : @"login-verified-marker-not-saved",status,0);
                ((void(*)(id,SEL))objc_msgSend)(receiver,NSSelectorFromString(@"onLoginFinish"));
            } @catch(__unused NSException *exception) {
                invalidateVerification();++failures;record(@"login",@"account-callback-failed",status,AccountStorage);
                toast(current,@"账号状态处理失败，请重新登录。");
            }
        });
    } @catch(__unused NSException *exception) {
        loginBusy=NO;invalidateVerification();++failures;record(@"login",@"login-interface-failed",0,ABI);
        toast(view,@"登录接口未能完成，请重新打开配置。");
    }
}
static void HTTPRequest(id self,SEL command,id path,id parameters,OPCloudSuccess success,OPCloudFailure failure,BOOL post) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{HTTPRequest(self,command,path,parameters,success,failure,post);});return;}
    NSURL *url=[path isKindOfClass:NSString.class] ? [NSURL URLWithString:path] : nil;
    NSString *operation=post ? @"native-post" : @"native-get";
    const BOOL list=official(url) && [url.host.lowercaseString isEqual:@"api.flydigi.com"] && [url.path isEqual:@"/api/android"] &&
        [parameters isKindOfClass:NSDictionary.class] && [parameters[@"action"] isEqual:@"getUserConfigList"];
    const BOOL loginEndpoint=[url.host.lowercaseString isEqual:@"passport.flydigi.com"] && [url.path isEqual:@"/Account/Login"];
    if(list)operation=@"cloud-list";
    if(list)clearListedDownloads();
    const uint64_t listGeneration=cloudListGeneration;
    // Account callbacks and preserved menu paths can open the cloud panel
    // without going through onYunSyncClick:. Keep this boundary at the actual
    // request too: local aliases never become server package namespaces.
    // This is a source-selection failure, not an authentication failure.
    if(list && localCloudSource()) {
        ++failures;requireCloudSource(nil);
        if(failure)failure(issue(CloudSourceRequired));
        return;
    }
    auto reject=[&](Error code){++failures;record(operation,@"request-rejected",0,code);if(failure)failure(issue(code));};
    if(!secureURL(url)) {
        if(official(url) || containsSecret(url,parameters)){reject(InsecureRequest);return;}
        if(post)originalPost(self,command,path,parameters,success,failure);else originalGet(self,command,path,parameters,success,failure);return;
    }
    if(!official(url)){if(post)originalPost(self,command,path,parameters,success,failure);else originalGet(self,command,path,parameters,success,failure);return;}
    if(list) {
        // Use the exact native four-field contract. No guessed gid or sign.
        // Original isTencentSmoba/getBundleId intentionally normalizes suffix
        // variants in loadRemoteData. Match that unchanged caller's behavior.
        NSString *expectedPackage=[target hasPrefix:@"com.tencent.smoba"] ? @"com.tencent.smoba" : target;
        if(!post || [parameters count]!=4 || ![parameters[@"os"] isEqual:@"iOS"] || ![parameters[@"pkgname"] isEqual:expectedPackage]){reject(InvalidRequest);return;}
        NSString *uid=decimal(parameters[@"uid"],NO);
        if(!accountVerified || !uid || ![uid isEqual:verifiedUID]){reject(LoginRequired);return;}
    }
    const uint64_t generation=authenticationGeneration;
    perform(post ? @"POST" : @"GET",url,parameters,operation,^(id JSON,NSInteger status,NSError *error){
        NSInteger serverCode=0;
        if(((list || loginEndpoint) && generation!=authenticationGeneration) ||
           (list && listGeneration!=cloudListGeneration))error=issue(Cancelled);
        if(list && generation==authenticationGeneration && listGeneration==cloudListGeneration &&
           (status==401 || status==403))invalidateVerification();
        if(!error && list && !validCloudList(JSON,&serverCode,&error)) {
            if(serverCode)invalidateVerification();
        } else if(!error && loginEndpoint) {
            NSString *unused=nil;if(!loginAccount(JSON,&serverCode,&unused,&error))invalidateVerification();
        }
        if(error){++failures;record(operation,@"response-rejected",status,error.code,serverCode);if(failure)failure(error);}
        else {
            if(list)rememberListedDownloads(JSON);
            record(operation,@"response-validated",status,0);if(success)success(JSON);
        }
    });
}
static void post(id self,SEL command,id path,id params,OPCloudSuccess success,OPCloudFailure failure){HTTPRequest(self,command,path,params,success,failure,YES);}
static void getHTTP(id self,SEL command,id path,id params,OPCloudSuccess success,OPCloudFailure failure){HTTPRequest(self,command,path,params,success,failure,NO);}
// The vendor has a second HTTP stack for FDG files. Keeping its unchecked
// downloadCFG/callback chain would make a validated cloud list look like a
// completed download even when ATS, parsing, or the final write failed.
static NSDictionary *FDGJSON(NSData *data) {
    if(!data.length || data.length>16*1024*1024)return nil;
    id root=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![root isKindOfClass:NSDictionary.class])return nil;
    BOOL found=NO;
    for(NSString *key in @[@"gamepad_list",@"keyboard_mouse_list",@"v1_list"]) {
        id list=root[key];if(!list)continue;found=YES;
        if(![list isKindOfClass:NSArray.class] || [list count]>10000)return nil;
        for(id entry in list)if(![entry isKindOfClass:NSDictionary.class])return nil;
    }
    return found ? root : nil;
}
static id invokeObject(id object,NSString *name,id argument) {
    return ((id(*)(id,SEL,id))objc_msgSend)(object,NSSelectorFromString(name),argument);
}
static void assignObject(id object,NSString *name,id argument) {
    ((void(*)(id,SEL,id))objc_msgSend)(object,NSSelectorFromString(name),argument);
}
static void invokeVoid(id object,NSString *name) {
    ((void(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name));
}
static NSData *serializeFDG(id io,id entity) {
    id JSON=invokeObject(io,@"getWriteEntity:",entity);
    if(![JSON isKindOfClass:NSDictionary.class] || ![NSJSONSerialization isValidJSONObject:JSON])return nil;
    NSData *data=[NSJSONSerialization dataWithJSONObject:JSON options:0 error:nil];
    return FDGJSON(data) ? data : nil;
}
static BOOL stageWriteFDG(id io,SEL selector,int type,id entity) {
    if(!stagingDownload)return originalWriteFDG(io,selector,type,entity);
    // The vendor mutates its cache before writing. Stage exactly its own
    // serializer's result; commit once after verifying the current slots.
    ++stagedWriteCount;
    if(type!=0 || stagedWriteCount!=1)return NO;
    stagedFDG=serializeFDG(io,entity);
    if(!stagedFDG)return NO;
    assignObject(io,@"setCacheLocalCFG:",entity);return YES;
}
static NSData *readAt(int directory,const char *name,BOOL *missing) {
    if(missing)*missing=NO;
    int fd=openat(directory,name,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
    if(fd<0){if(missing && errno==ENOENT)*missing=YES;return nil;}
    struct stat info{};
    if(fstat(fd,&info) || !S_ISREG(info.st_mode) || info.st_nlink!=1 || info.st_size<0 || info.st_size>16*1024*1024){close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)info.st_size];size_t offset=0;
    while(offset<data.length){ssize_t count=read(fd,(char *)data.mutableBytes+offset,data.length-offset);if(count<0 && errno==EINTR)continue;if(count<=0)break;offset+=(size_t)count;}
    close(fd);return offset==data.length ? data : nil;
}
static BOOL writeAt(int directory,const char *name,NSData *data,BOOL replace) {
    if(!data.length || data.length>16*1024*1024)return NO;
    NSString *temporary=[NSString stringWithFormat:@".cloud-%@.tmp",NSUUID.UUID.UUIDString];
    const char *output=replace ? temporary.UTF8String : name;
    int fd=openat(directory,output,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0600);
    if(fd<0)return NO;
    size_t offset=0;
    while(offset<data.length){ssize_t count=write(fd,(const char *)data.bytes+offset,data.length-offset);if(count<0 && errno==EINTR)continue;if(count<=0)break;offset+=(size_t)count;}
    BOOL ok=offset==data.length && fsync(fd)==0;close(fd);
    if(ok && replace)ok=renameat(directory,output,directory,name)==0;
    if(!ok)unlinkat(directory,output,0);
    return ok;
}
static NSDictionary *defaultFDG(void) {
    NSString *path=[NSBundle.mainBundle pathForResource:@"default_config" ofType:@"fdg" inDirectory:@"FZKeymappingHelper.bundle"];
    return path ? FDGJSON([NSData dataWithContentsOfFile:path]) : nil;
}
static BOOL importDownload(NSData *bytes,int version,NSString *title,NSInteger *savedType,NSError **error) {
    int temporaryDirectory=-1,configurationDirectory=-1;
    NSString *temporaryName=nil;
    id io=get(NSClassFromString(@"FZCFGIOCenter"),@"sharedFZCFGIOCenter");
    id priorCache=get(io,@"cacheLocalCFG");
    NSData *priorCacheBytes=nil,*priorFile=nil;
    BOOL fileMissing=NO,committed=NO,cacheChanged=NO,success=NO;
    Error failure=DownloadParse;
    @try {
        do {
            priorCacheBytes=priorCache ? serializeFDG(io,priorCache) : nil;
            if(priorCache && !priorCacheBytes){failure=DownloadImport;break;}
            NSString *tmp=[documents stringByAppendingPathComponent:@"tmp"],*cfg=[documents stringByAppendingPathComponent:@"cfg"];
            temporaryDirectory=open(tmp.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
            configurationDirectory=open(cfg.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
            if(temporaryDirectory<0 || configurationDirectory<0){failure=DownloadStorage;break;}
            priorFile=readAt(configurationDirectory,"local.fdg",&fileMissing);
            if(!fileMissing && (!priorFile || !FDGJSON(priorFile))){failure=DownloadStorage;break;}
            if(version!=0 && !FDGJSON(bytes)){failure=InvalidDownload;break;}
            // Legacy parser receives its title separately. Its filename never
            // comes from a cloud title and deliberately does not end in .fdg.
            temporaryName=[NSUUID.UUID.UUIDString stringByAppendingString:version==0 ? @".legacy" : @".fdg"];
            if(!writeAt(temporaryDirectory,temporaryName.UTF8String,bytes,NO)){failure=DownloadStorage;break;}
            NSString *path=[tmp stringByAppendingPathComponent:temporaryName];
            id entity=nil;int type=1;
            NSArray *getters=@[@"gamepadList",@"keydMosList",@"v1List"];
            NSArray *setters=@[@"setGamepadList:",@"setKeydMosList:",@"setV1List:"];
            NSArray *keys=@[@"gamepad_list",@"keyboard_mouse_list",@"v1_list"];
            if(version==0)entity=((id(*)(id,SEL,id,id))objc_msgSend)(preferences(),NSSelectorFromString(@"readOldFDG:fileName:"),path,title);
            else {
                id list=invokeObject(io,@"readFDGByPath:",path);
                for(NSUInteger i=0;i<getters.count;++i){id entries=get(list,getters[i]);if([entries isKindOfClass:NSArray.class] && [entries count]){entity=entries[0];type=(int)i+1;break;}}
            }
            if(!entity){failure=DownloadParse;break;}
            // Serialize the parsed vendor entity through its real formatter,
            // so membership verification does not invent a second FDG format.
            id one=invokeObject(io,@"getReadEntity:",@{@"gamepad_list":@[],@"keyboard_mouse_list":@[],@"v1_list":@[]});
            assignObject(one,setters[(NSUInteger)type-1],[NSMutableArray arrayWithObject:entity]);
            NSDictionary *entityJSON=FDGJSON(serializeFDG(io,one));
            id expectedEntity=[entityJSON[keys[(NSUInteger)type-1]] firstObject];
            if(![expectedEntity isKindOfClass:NSDictionary.class]){failure=DownloadParse;break;}
            NSDictionary *base=priorCacheBytes ? FDGJSON(priorCacheBytes) : (priorFile ? FDGJSON(priorFile) : defaultFDG());
            if(!base){failure=DownloadImport;break;}
            NSMutableDictionary *prepared=[base mutableCopy];NSString *key=keys[(NSUInteger)type-1];
            if(![prepared[key] count]) {
                // The original local list hides slot zero. Seed only a missing
                // slot from the untouched bundled default, never the download.
                id defaults=defaultFDG()[key];
                if(![defaults isKindOfClass:NSArray.class] || ![defaults count]){failure=DownloadImport;break;}
                prepared[key]=@[[defaults firstObject]];
            }
            id working=invokeObject(io,@"getReadEntity:",prepared);
            if(!working){failure=DownloadImport;break;}
            cacheChanged=YES;
            assignObject(io,@"setCacheLocalCFG:",working);
            stagedWriteCount=0;stagedFDG=nil;stagingDownload=YES;
            @try {((void(*)(id,SEL,id,int))objc_msgSend)(preferences(),NSSelectorFromString(@"doSaveToLocal:version:"),entity,type);}
            @finally {stagingDownload=NO;}
            NSDictionary *candidate=FDGJSON(stagedFDG);
            id entries=candidate[key];
            BOOL containsSaved=NO;
            if([entries isKindOfClass:NSArray.class])for(NSUInteger i=1;i<[entries count];++i)if([entries[i] isEqual:expectedEntity])containsSaved=YES;
            BOOL unchanged=YES;
            for(NSString *listKey in keys) {
                NSArray *before=prepared[listKey] ?: @[],*after=candidate[listKey] ?: @[];
                if([listKey isEqual:key])unchanged=unchanged && before.count && after.count && [before[0] isEqual:after[0]];
                else unchanged=unchanged && [before isEqual:after];
            }
            if(stagedWriteCount!=1 || !candidate || !containsSaved || !unchanged){failure=DownloadImport;break;}
            if(!writeAt(configurationDirectory,"local.fdg",stagedFDG,YES)){failure=DownloadStorage;break;}
            committed=YES;
            NSData *saved=readAt(configurationDirectory,"local.fdg",nullptr);
            if(![saved isEqual:stagedFDG]){failure=DownloadStorage;break;}
            id reloaded=invokeObject(io,@"readFDGByPath:",[cfg stringByAppendingPathComponent:@"local.fdg"]);
            if(![FDGJSON(serializeFDG(io,reloaded)) isEqual:candidate]){failure=DownloadImport;break;}
            assignObject(io,@"setCacheLocalCFG:",reloaded);
            if(savedType)*savedType=type;
            success=YES;
        } while(false);
    } @catch(__unused NSException *exception) {failure=DownloadParse;}
    @finally {
        stagingDownload=NO;stagedFDG=nil;stagedWriteCount=0;
        if(!success) {
            if(committed) {
                BOOL restored=fileMissing ? unlinkat(configurationDirectory,"local.fdg",0)==0 : writeAt(configurationDirectory,"local.fdg",priorFile,YES);
                if(!restored)failure=DownloadRollback;
            }
            if(cacheChanged) {
                @try {assignObject(io,@"setCacheLocalCFG:",priorCacheBytes ? invokeObject(io,@"getReadEntity:",FDGJSON(priorCacheBytes)) : nil);}
                @catch(__unused NSException *exception){failure=DownloadRollback;}
            }
        }
        if(temporaryDirectory>=0){if(temporaryName)unlinkat(temporaryDirectory,temporaryName.UTF8String,0);close(temporaryDirectory);}
        if(configurationDirectory>=0)close(configurationDirectory);
    }
    if(!success && error)*error=issue(failure);
    return success;
}
static void downloadNotice(id view,NSString *message) {
    if(objectSignature(view,@"showDialogFunctionHelp:desc:","v",@[@"@",@"@"]))
        ((void(*)(id,SEL,id,id))objc_msgSend)(view,NSSelectorFromString(@"showDialogFunctionHelp:desc:"),@"云方案下载",message);
}
static NSString *downloadFailureMessage(NSInteger code) {
    switch(code) {
        case DownloadNotListed:return @"该方案不在当前已验证的云列表中；请刷新云列表后重试。本地方案未更改。";
        case DownloadURLFormat:case InvalidRequest:case InsecureRequest:return @"服务器返回的下载地址格式无法使用；没有修改本地方案。";
        case DownloadItem:return @"云方案条目的格式或版本无法读取；没有修改本地方案。";
        case HTTP:case Transport:case Redirect:return @"方案文件下载失败；没有修改本地方案。请检查网络后重试。";
        case EmptyDownload:case InvalidDownload:case DownloadParse:return @"下载文件为空或不是可读取的飞智方案；没有导入本地。";
        case DownloadStorage:return @"方案未能完整写入本地，下载没有完成。原本地方案已保留。";
        case DownloadRollback:return @"本地方案恢复校验失败。请退出配置并检查存储；不要应用本次下载。";
        case Cancelled:return @"下载已取消，本地方案未更改。请重新选择云方案。";
        default:return @"下载方案未通过本地保存校验，没有应用。请重新打开云配置后重试。";
    }
}
static void download(id view,SEL,id item) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{download(view,nullptr,item);});return;}
    if(downloadBusy){downloadNotice(view,@"正在下载方案，请等本次下载完成。");return;}
    id sourceURL=get(item,@"url");
    NSURL *url=downloadURL(sourceURL);
    int version=0;
    const BOOL validItem=objectSignature(item,@"version","i",@[]) && [get(item,@"title") isKindOfClass:NSString.class];
    if(validItem)version=((int(*)(id,SEL))objc_msgSend)(item,NSSelectorFromString(@"version"));
    auto fail=[&](Error code){++failures;++downloadFailed;record(@"cloud-download",@"download-failed",0,code);downloadNotice(view,downloadFailureMessage(code));
        ((void(*)(id,SEL,BOOL))objc_msgSend)(view,NSSelectorFromString(@"hideLocalLoading:"),YES);};
    if(!accountVerified){fail(LoginRequired);return;}
    if(!validItem || version<0){fail(DownloadItem);return;}
    if(!url){fail(DownloadURLFormat);return;}
    if(![listedDownloadVersions[sourceURL] containsObject:@(version)]){fail(DownloadNotListed);return;}
    id queue=get(view,@"syncRemoteList");
    if(![queue isKindOfClass:NSMutableArray.class] || [queue firstObject]!=item){fail(Cancelled);return;}
    downloadBusy=YES;++downloadAttempts;++requests;record(@"cloud-download",@"request-started",0,0);
    const uint64_t generation=authenticationGeneration;
    NSString *title=[get(item,@"title") copy];__weak id owner=view;
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    request.HTTPMethod=@"GET";request.HTTPShouldHandleCookies=NO;
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Accept"];
    OPCloudRequest *transfer=[OPCloudRequest new];transfer.request=request;transfer.returnsBytes=YES;downloadRequest=transfer;
    transfer.completion=^(id bytes,NSInteger status,NSError *error){
        ++completed;downloadRequest=nil;id current=owner;
        id pending=current ? get(current,@"syncRemoteList") : nil;
        if(!current || generation!=authenticationGeneration || ![pending isKindOfClass:NSMutableArray.class] || [pending firstObject]!=item)error=issue(Cancelled);
        NSInteger planType=0;
        if(!error && !importDownload(bytes,version,title,&planType,&error) && !error)error=issue(DownloadImport);
        downloadBusy=NO;
        if(error){++failures;++downloadFailed;record(@"cloud-download",@"download-failed",status,error.code);
            if(current){invokeVoid(current,@"loadLocalData");((void(*)(id,SEL,BOOL))objc_msgSend)(current,NSSelectorFromString(@"hideLocalLoading:"),YES);downloadNotice(current,downloadFailureMessage(error.code));}
            return;
        }
        ++downloadSaved;downloadedPlanType=planType;record(@"cloud-download",@"saved-and-read-back",status,0);
        [pending removeObjectAtIndex:0];
        // Continue only after a verified commit. The old failure path removed
        // queue entries unconditionally, concealing failed downloads.
        invokeVoid(current,@"doSyncDownload");
        if(![pending count])downloadNotice(current,@"已下载到本地。请在本地方案列表选择并应用，再启用全局映射。");
    };
    [transfer start];
}
} // namespace op_cloud

BOOL OPInstallOriginalCloudTransport(NSString *targetBundleID,NSString **error) {
    using namespace op_cloud;
    if(error)*error=nil;
    if(!NSThread.isMainThread || !bundleValid(targetBundleID)){if(error)*error=@"云传输必须在主线程为有效配置来源安装。";return NO;}
    if(installed){if([target isEqual:targetBundleID])return YES;if(error)*error=@"云传输配置来源已固定，不能在同进程切换。";return NO;}
    Class loginClass=NSClassFromString(@"FZCFGFloatingLogin"),httpClass=NSClassFromString(@"FZHttpTool"),prefs=NSClassFromString(@"FZPreferRecordTool");
    Class importClass=NSClassFromString(@"FZCFGImport"),cloudClass=NSClassFromString(@"FZCFGFloatingCloudSync");
    Class ioClass=NSClassFromString(@"FZCFGIOCenter"),listClass=NSClassFromString(@"FZCFGEntityList");
    BOOL valid=signature(loginClass,NO,@"onBtnLogin","v",@[]) && signature(loginClass,NO,@"showToast:","v",@[@"@"]) &&
        signature(prefs,YES,@"sharedFZPreferRecordTool","@",@[]) && signature(prefs,NO,@"saveUserInfo:name:avatar:email:sign:","v",@[@"@",@"@",@"@",@"@",@"@"]) &&
        signature(prefs,NO,@"clearUserInfo","v",@[]) && signature(importClass,NO,@"showCloudSync","v",@[]) &&
        signature(importClass,NO,@"showLogin","v",@[]) && signature(importClass,NO,@"onYunSyncClick:","v",@[@"@"]);
    for(NSString *name in @[@"viewTextEmail",@"viewTextPassword",@"delegate"])valid=valid && signature(loginClass,NO,name,"@",@[]);
    for(NSString *name in @[@"getUserId",@"getUserSign"])valid=valid && signature(prefs,NO,name,"@",@[]);
    for(NSString *name in @[@"postWithPath:params:success:failure:",@"getWithPath:params:success:failure:"])
        valid=valid && signature(httpClass,YES,name,"v",@[@"@",@"@",@"@?",@"@?"]);
    valid=valid && signature(cloudClass,NO,@"downloadCFG:","v",@[@"@"]) &&
        signature(cloudClass,NO,@"syncRemoteList","@",@[]) &&
        signature(cloudClass,NO,@"hideLocalLoading:","v",@[[NSString stringWithUTF8String:@encode(BOOL)]]) &&
        signature(cloudClass,NO,@"showDialogFunctionHelp:desc:","v",@[@"@",@"@"]) &&
        signature(cloudClass,NO,@"loadLocalData","v",@[]) && signature(cloudClass,NO,@"doSyncDownload","v",@[]) &&
        signature(prefs,NO,@"readOldFDG:fileName:","@",@[@"@",@"@"]) &&
        signature(prefs,NO,@"doSaveToLocal:version:","v",@[@"@",@"i"]) &&
        signature(ioClass,YES,@"sharedFZCFGIOCenter","@",@[]) &&
        signature(ioClass,NO,@"writeFDG:data:",@encode(BOOL),@[@"i",@"@"]) &&
        signature(ioClass,NO,@"cacheLocalCFG","@",@[]) && signature(ioClass,NO,@"setCacheLocalCFG:","v",@[@"@"]);
    for(NSString *name in @[@"readFDGByPath:",@"getReadEntity:",@"getWriteEntity:"])
        valid=valid && signature(ioClass,NO,name,"@",@[@"@"]);
    for(NSString *name in @[@"gamepadList",@"keydMosList",@"v1List"])
        valid=valid && signature(listClass,NO,name,"@",@[]);
    for(NSString *name in @[@"setGamepadList:",@"setKeydMosList:",@"setV1List:"])
        valid=valid && signature(listClass,NO,name,"v",@[@"@"]);
    if(!valid){if(error)*error=@"原登录／HTTP接口 ABI 不符，未替换传输。";return NO;}
    NSString *directory=OPOriginalDocumentsForTarget(targetBundleID);
    BOOL isDirectory=NO;if(!directory || ![NSFileManager.defaultManager fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) {
        if(error)*error=@"原云账号配置目录尚未准备好。";return NO;
    }
    struct Change {Method method;IMP next;IMP previous;};
    std::vector<Change> changes={
        {class_getInstanceMethod(loginClass,NSSelectorFromString(@"onBtnLogin")),(IMP)login,nullptr},
        {class_getClassMethod(httpClass,NSSelectorFromString(@"postWithPath:params:success:failure:")),(IMP)post,nullptr},
        {class_getClassMethod(httpClass,NSSelectorFromString(@"getWithPath:params:success:failure:")),(IMP)getHTTP,nullptr},
        {class_getInstanceMethod(prefs,NSSelectorFromString(@"clearUserInfo")),(IMP)clearAccount,nullptr},
        {class_getInstanceMethod(importClass,NSSelectorFromString(@"showCloudSync")),(IMP)showCloud,nullptr},
        {class_getInstanceMethod(cloudClass,NSSelectorFromString(@"downloadCFG:")),(IMP)download,nullptr},
        {class_getInstanceMethod(ioClass,NSSelectorFromString(@"writeFDG:data:")),(IMP)stageWriteFDG,nullptr},
        {class_getInstanceMethod(importClass,NSSelectorFromString(@"onYunSyncClick:")),(IMP)cloudEntry,nullptr}};
    for(auto &change:changes)change.previous=method_setImplementation(change.method,change.next);
    for(const auto &change:changes)if(!change.previous || method_getImplementation(change.method)!=change.next){
        for(auto it=changes.rbegin();it!=changes.rend();++it)if(it->previous)method_setImplementation(it->method,it->previous);
        if(error)*error=@"原云传输替换核验失败，已回退。";return NO;
    }
    originalPost=(OPCloudHTTPMethod)changes[1].previous;originalGet=(OPCloudHTTPMethod)changes[2].previous;originalClear=(void(*)(id,SEL))changes[3].previous;
    originalShowCloud=(void(*)(id,SEL))changes[4].previous;
    originalWriteFDG=(BOOL(*)(id,SEL,int,id))changes[6].previous;
    originalCloudEntry=(void(*)(id,SEL,id))changes[7].previous;
    originalShowLogin=(void(*)(id,SEL))class_getMethodImplementation(importClass,NSSelectorFromString(@"showLogin"));
    target=[targetBundleID copy];documents=[directory copy];installed=YES;
    restoreVerification();record(@"install",restoredVerification ? @"previously-verified-account-restored" : @"fresh-login-required",0,0);
    return YES;
}
BOOL OPOriginalCloudNetworkVerified(void) { return NSThread.isMainThread && op_cloud::networkVerified; }
BOOL OPOriginalCloudTransferInProgress(void) { return NSThread.isMainThread && (op_cloud::downloadBusy || op_cloud::loginBusy); }
void OPSetOriginalCloudSourceRequiredHandler(dispatch_block_t handler) {
    if(NSThread.isMainThread)op_cloud::cloudSourceRequiredHandler=[handler copy];
}
BOOL OPValidateOriginalCurrentPlanOnDisk(NSInteger deviceType,NSString **error) {
    using namespace op_cloud;
    if(error)*error=nil;
    if(!NSThread.isMainThread || !installed || !documents.length || deviceType<0 || deviceType>2) {
        if(error)*error=@"当前原版编辑会话或手柄方案类型尚未准备好。";return NO;
    }
    @try {
        id io=get(NSClassFromString(@"FZCFGIOCenter"),@"sharedFZCFGIOCenter");
        id cache=get(io,@"cacheLocalCFG");
        NSDictionary *memory=cache ? FDGJSON(serializeFDG(io,cache)) : nil;
        NSString *key=@[@"gamepad_list",@"keyboard_mouse_list",@"v1_list"][(NSUInteger)deviceType];
        id current=[memory[key] firstObject];
        if(![current isKindOfClass:NSDictionary.class] || ![current count]) {
            if(error)*error=@"当前手柄类型没有已应用的原版方案。请在原版本地列表选中并应用方案。";return NO;
        }
        NSString *cfg=[documents stringByAppendingPathComponent:@"cfg"];
        int directory=open(cfg.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
        NSData *data=directory>=0 ? readAt(directory,"local.fdg",nullptr) : nil;
        if(directory>=0)close(directory);
        NSDictionary *disk=FDGJSON(data);id saved=[disk[key] firstObject];
        if(![saved isKindOfClass:NSDictionary.class] || ![saved isEqual:current]) {
            if(error)*error=@"原版当前方案尚未成功保存，磁盘内容与编辑器不一致。请在原版界面保存或应用当前方案后重试；全局方案没有更改。";
            return NO;
        }
        return YES;
    } @catch(__unused NSException *exception) {
        if(error)*error=@"无法核对原版当前方案的保存结果。请在原版界面重新保存或应用后重试；全局方案没有更改。";
        return NO;
    }
}
NSDictionary *OPOriginalCloudStatus(void) {
    if(!NSThread.isMainThread)return @{@"stage":@"main-thread-required"};
    return op_cloud::lastStatus ?: @{@"stage":@"not-installed",@"networkVerified":@NO,@"accountVerified":@NO};
}
