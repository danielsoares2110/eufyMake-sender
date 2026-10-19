#import <CommonCrypto/CommonCryptor.h>
#include <stdint.h>
#include <stddef.h>

// AES-CBC with PKCS7 padding. keyLen must be 16 or 32 (AES-128/256).
// Returns 0 on success, non-zero on failure. *outLen receives ciphertext/plaintext size.
int ANCryptoAESCBC(int encrypt, const uint8_t *key, size_t keyLen,
                   const uint8_t *iv, const uint8_t *in, size_t inLen,
                   uint8_t *out, size_t *outLen)
{
    CCCryptorRef ref = NULL;
    CCCryptorStatus st = CCCryptorCreate(encrypt ? kCCEncrypt : kCCDecrypt,
                                         keyLen == 32 ? kCCAlgorithmAES128 : kCCAlgorithmAES128,
                                         kCCOptionPKCS7Padding,
                                         key, keyLen, iv,
                                         &ref);
    if (st != kCCSuccess) return (int)st;

    size_t done = 0;
    size_t dataMoved = 0;
    uint8_t *buf = out;
    size_t bufLen = *outLen;

    st = CCCryptorUpdate(ref, in, inLen, buf, bufLen, &dataMoved);
    if (st != kCCSuccess) { CCCryptorRelease(ref); return (int)st; }
    done = dataMoved;
    st = CCCryptorFinal(ref, buf + done, bufLen - done, &dataMoved);
    if (st != kCCSuccess) { CCCryptorRelease(ref); return (int)st; }
    done += dataMoved;

    CCCryptorRelease(ref);
    *outLen = done;
    return 0;
}
