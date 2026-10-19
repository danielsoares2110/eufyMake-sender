#import <CommonCrypto/CommonCryptor.h>
#include <stdint.h>
#include <stddef.h>

// AES-CBC with PKCS7 padding, keyLen 16 (AES-128) or 32 (AES-256).
// Returns 0 on success; *outLen receives output size. Buffer must be big enough.
int ANCryptoAESCBC(int encrypt, const uint8_t *key, size_t keyLen,
                   const uint8_t *iv, const uint8_t *in, size_t inLen,
                   uint8_t *out, size_t *outLen);
