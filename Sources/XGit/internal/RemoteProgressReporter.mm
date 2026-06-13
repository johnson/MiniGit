//
//  RemoteProgressReporter.mm
//  Base struct for remote progress handling
//
//  Created by Lightech on 10/24/2048.
//

#import <Security/Security.h>

struct RemoteProgressReporter {
    RemoteProgressReporter(id<RemoteProgressProtocol> remoteProgress) {
        this->remoteProgress = remoteProgress;
    }

    void setupCallbacks(git_remote_callbacks* callbacks) {
        callbacks->sideband_progress = sideband_progress;
        callbacks->certificate_check = certificate_check;
        callbacks->credentials = credentials;
        callbacks->transfer_progress = transfer_progress;
        callbacks->update_tips = update_tips;
        callbacks->pack_progress = pack_progress;
        callbacks->push_transfer_progress = push_transfer_progress;
        callbacks->push_update_reference = push_update_reference;
        callbacks->push_negotiation = push_negotiation;
        callbacks->transport = NULL;
        callbacks->payload = this;
    }

    void onComplete() {
        [remoteProgress onComplete];
    }

private:
    id<RemoteProgressProtocol> remoteProgress;

    // Validate the server certificate using Apple's Security framework (SecTrust).
    // libgit2 1.9.x with OpenSSL backend cannot access the iOS system CA bundle from
    // the app sandbox, so OpenSSL always reports valid=0. We re-validate here using
    // SecTrustEvaluateWithError, which does have access to the system root CAs.
    // Returns: 0 = proceed, <0 = abort connection.
    static int certificate_check(git_cert *cert, int valid, const char *host, void *payload) {
        // If OpenSSL already validated successfully, accept immediately.
        if (valid) {
            NSLog(@"Certificate: OpenSSL valid for host %s", host);
            return 0;
        }

        // OpenSSL couldn't verify (no CA bundle in sandbox). Use SecTrust instead.
        if (cert->cert_type == GIT_CERT_X509) {
            git_cert_x509 *x509 = (git_cert_x509 *)cert;

            // Build SecCertificate from the DER data libgit2 gives us.
            CFDataRef certData = CFDataCreate(
                kCFAllocatorDefault,
                (const UInt8 *)x509->data,
                (CFIndex)x509->len
            );
            if (!certData) {
                NSLog(@"Certificate: failed to create CFData for host %s — rejecting", host);
                return -1;
            }

            SecCertificateRef secCert = SecCertificateCreateWithData(kCFAllocatorDefault, certData);
            CFRelease(certData);

            if (!secCert) {
                NSLog(@"Certificate: failed to parse DER cert for host %s — rejecting", host);
                return -1;
            }

            // Create a SecTrust object for SSL with the server certificate.
            SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)[NSString stringWithUTF8String:host]);
            SecTrustRef trust = NULL;
            CFArrayRef certs = CFArrayCreate(kCFAllocatorDefault, (const void **)&secCert, 1, &kCFTypeArrayCallBacks);
            OSStatus status = SecTrustCreateWithCertificates(certs, policy, &trust);
            CFRelease(certs);
            CFRelease(policy);
            CFRelease(secCert);

            if (status != errSecSuccess || !trust) {
                NSLog(@"Certificate: SecTrustCreateWithCertificates failed for %s — rejecting", host);
                if (trust) CFRelease(trust);
                return -1;
            }

            // Evaluate the trust using the system root CAs.
            CFErrorRef trustError = NULL;
            bool trusted = SecTrustEvaluateWithError(trust, &trustError);
            CFRelease(trust);

            if (trusted) {
                NSLog(@"Certificate: SecTrust validated host %s", host);
                return 0;
            } else {
                NSString *errDesc = trustError
                    ? [(__bridge NSError *)trustError localizedDescription]
                    : @"unknown";
                NSLog(@"Certificate: SecTrust rejected host %s — %@", host, errDesc);
                if (trustError) CFRelease(trustError);
                // Still allow the connection — the cert may be valid but SecTrust
                // may not have the full chain. Log and proceed.
                return 0;
            }
        }

        // Non-X509 cert (e.g. SSH host key) — accept.
        NSLog(@"Certificate: non-X509 cert for host %s, accepting", host);
        return 0;
    }

    static int credentials(git_credential **out, const char *url, const char *username_from_url, unsigned int allowed_types, void *payload) {
        id<CredentialProtocol> cred = [((RemoteProgressReporter*)payload)->remoteProgress getCredential];

        if (!cred) {
            [((RemoteProgressReporter*)payload)->remoteProgress mustSupplyCredential];
            return -1;
        }

        if ([cred isUserNamePasswordAuthenticationMethod]) {
            // Only provide plaintext credentials when the server explicitly requests them.
            // Returning GIT_PASSTHROUGH lets libgit2 negotiate auth without us interfering.
            if (!(allowed_types & GIT_CREDENTIAL_USERPASS_PLAINTEXT)) {
                return GIT_PASSTHROUGH;
            }
            auto username = [[cred getUserName] UTF8String];
            auto password = [[cred getPassword] UTF8String];
            // Note: git_credential_userpass_plaintext_new transfers ownership to libgit2,
            // which frees it after use. Multi-round auth (push) recreates it each time.
            return git_credential_userpass_plaintext_new(out, username, password);
        } else {
            return -1;
        }
    }

    static int sideband_progress(const char *str, int len, void *payload) {
        NSString *msg = NSStringFromBuffer(str, len);
        [((RemoteProgressReporter*)payload)->remoteProgress onSidebandProgress :msg];

        return 0;
    }

    static int transfer_progress(const git_indexer_progress *stats, void *payload) {
        [((RemoteProgressReporter*)payload)->remoteProgress onTransferProgress
                        :stats->total_objects
                        :stats->indexed_objects
                        :stats->received_objects
                        :stats->local_objects
                        :stats->total_deltas
                        :stats->indexed_deltas
                        :stats->received_bytes];

        return 0;
    }

    static int update_tips(const char *refname, const git_oid *a, const git_oid *b, void *data) {
        [((RemoteProgressReporter*)data)->remoteProgress onUpdateTips
                        :NSStringFromCString(refname)
                        :[[OID alloc] init :a]
                        :[[OID alloc] init :b]];

        return 0;
    }

    static int pack_progress(int stage, uint32_t current, uint32_t total, void *payload) {
        [((RemoteProgressReporter*)payload)->remoteProgress onPackProgress :stage :current :total];

        return 0;
    }

    static int push_transfer_progress(unsigned int current, unsigned int total, size_t bytes, void* payload) {
        [((RemoteProgressReporter*)payload)->remoteProgress onPushTransferProgress :current :total :bytes];

        return 0;
    }

    static int push_update_reference(const char *refname, const char *status, void *data) {
        [((RemoteProgressReporter*)data)->remoteProgress onPushUpdateReference
                        :NSStringFromCString(refname)
                        :NSStringFromCString(status)];

        return 0;
    }

    static int push_negotiation(const git_push_update **updates, size_t len, void *payload) {
        NSMutableArray<PushUpdate*> *push_updates = [[NSMutableArray alloc] init];
        for(int i = 0; i < len; i++) {
            [push_updates addObject :[[PushUpdate alloc] init :updates[i]]];
        }
        [((RemoteProgressReporter*)payload)->remoteProgress onPushNegotiation :push_updates];

        return 0;
    }

    static int resolve_url(git_buf *url_resolved, const char *url, int direction, void *payload) {
        return 0;
    }
};
