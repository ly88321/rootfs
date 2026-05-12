#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <getopt.h>
#include <time.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include "md5.h"

#ifdef _WIN32
#include <direct.h>
#endif

#if defined(_WIN32) || defined(_WIN64)
#  define SIZE_T_FMT "%Illu"   // MSVC / MinGW
#else
#  define SIZE_T_FMT "%zu"
#endif

// Hash tables for CRC32 calculation
static const uint8_t hash_table_old[] = {
    0x00, 0x00, 0x00, 0x00, 0x64, 0x10, 0xB7, 0x1D, 0xC8, 0x20, 0x6E, 0x3B, 0xAC, 0x30, 0xD9, 0x26, 
    0x90, 0x41, 0xDC, 0x76, 0xF4, 0x51, 0x6B, 0x6B, 0x58, 0x61, 0xB2, 0x4D, 0x3C, 0x71, 0x05, 0x50, 
    0x20, 0x83, 0xB8, 0xED, 0x44, 0x93, 0x0F, 0xF0, 0xE8, 0xA3, 0xD6, 0xD6, 0x8C, 0xB3, 0x61, 0xCB, 
    0xB0, 0xC2, 0x64, 0x9B, 0xD4, 0xD2, 0xD3, 0x86, 0x78, 0xE2, 0x0A, 0xA0, 0x1C, 0xF2, 0xBD, 0xBD
};

static const uint8_t hash_table_new[] = {
    0x00, 0x00, 0x00, 0x00, 0x64, 0x10, 0xB7, 0x1D, 0xC8, 0x20, 0x6E, 0x3B, 0xAC, 0x30, 0xD6, 0x26, 
    0x90, 0x41, 0xDE, 0x76, 0xF4, 0x51, 0x6B, 0x6B, 0x56, 0x61, 0xB2, 0x4D, 0x3C, 0x71, 0x05, 0x50, 
    0x20, 0x63, 0xB8, 0xED, 0x43, 0x93, 0x0F, 0xF0, 0xE8, 0xA3, 0xD6, 0xD6, 0x8C, 0xB3, 0x61, 0xCB, 
    0xB0, 0xC2, 0x64, 0x9B, 0xD4, 0xD2, 0xD4, 0x86, 0x78, 0xE2, 0x0A, 0xA0, 0x1C, 0xF2, 0xDD, 0xBD
};

// Default key for old rootfs format
static const uint8_t default_key[] = {
    0x77, 0xb1, 0xfa, 0x93, 0x74, 0x2c, 0xb3, 0x9d,
    0x33, 0x83, 0x55, 0x3e, 0x84, 0x8a, 0x52, 0x91
};

enum rootfs_format {
    ROOTFS_FORMAT_V1 = 1,
    ROOTFS_FORMAT_V2 = 2,
    ROOTFS_FORMAT_V3 = 3
};

#define ROOTFS_V2_KEY_SIZE 16
#define ROOTFS_V2_HASH_SIZE 4
#define ROOTFS_V2_TRAILER_SIZE (ROOTFS_V2_KEY_SIZE + ROOTFS_V2_HASH_SIZE)
#define ROOTFS_V3_KEY_SIZE 16
#define ROOTFS_V3_HASH_SIZE 4
#define ROOTFS_V3_SIGNATURE_SIZE 256
#define ROOTFS_V3_TRAILER_SIZE (ROOTFS_V3_KEY_SIZE + ROOTFS_V3_HASH_SIZE + ROOTFS_V3_SIGNATURE_SIZE)
#define ROOTFS_V3_EXT_KEY_SIZE 2048
#define ROOTFS_V3_PERM_SIZE 256
#define ROOTFS_V3_ROUNDS 3

// Function prototypes
uint32_t get_rootfs_hash(const uint8_t *data, size_t length, int format);
void generate_extended_key_v2(const uint8_t *base_key, uint8_t *ext_key);
void generate_random_key(uint8_t *key);
void generate_v3_context(const uint8_t *seed, uint8_t *ext_key, uint8_t *perm, uint8_t *inv_perm);
void generate_v2_key(uint8_t *key, uint8_t *data, size_t length);
int encode_rootfs(uint8_t *data, size_t *data_size, const uint8_t *key, const uint8_t *signature, int format);
int decode_rootfs(uint8_t *data, size_t *data_size, uint8_t *key, uint8_t *signature, int format);
int read_file(const char *filename, uint8_t **data, size_t *size);
int write_file(const char *filename, const uint8_t *data, size_t size);
int verify_v3_signature(const uint8_t *data, size_t file_size);
int sign_v3_signature(const uint8_t *data, size_t signed_size, uint8_t *signature);
void print_usage(const char *program_name);

int debug = 0;
const char *v3_private_key_file = NULL;
const char *v3_public_key_file = NULL;

#define __is_print(ch) ((unsigned int)((ch) - ' ') < 127u - ' ')
void hexdump(unsigned char *buf, int size)
{
    int i, j;

    for (i = 0; i < size; i += 16)
    {
        printf("%08X: ", i);

        for (j = 0; j < 16; j++)
        {
            if (i + j < size)
            {
                printf("%02X ", buf[i + j]);
            }
            else
            {
                printf("   ");
            }
        }
        printf(" ");

        for (j = 0; j < 16; j++)
        {
            if (i + j < size)
            {
                printf("%c", __is_print(buf[i + j]) ? buf[i + j] : '.');
            }
        }
        printf("\n");
    }
}

// Swap bytes for endianness conversion
uint32_t swap_bytes(uint32_t val) {
    return ((val << 24) & 0xFF000000) |
           ((val << 8)  & 0x00FF0000) |
           ((val >> 8)  & 0x0000FF00) |
           ((val >> 24) & 0x000000FF);
}

static int use_new_hash_table(int format)
{
    return format != ROOTFS_FORMAT_V1;
}

static uint8_t rotl8(uint8_t value, uint8_t shift)
{
    return (uint8_t)((value << shift) | (value >> (8 - shift)));
}

static uint8_t rotr8(uint8_t value, uint8_t shift)
{
    return (uint8_t)((value >> shift) | (value << (8 - shift)));
}

static void print_openssl_error(const char *prefix)
{
    unsigned long err = ERR_get_error();

    if (err == 0) {
        fprintf(stderr, "%s\n", prefix);
        return;
    }

    fprintf(stderr, "%s: %s\n", prefix, ERR_error_string(err, NULL));
}

static EVP_PKEY *load_public_key_from_memory(const uint8_t *data, size_t size)
{
    EVP_PKEY *pkey = NULL;
    BIO *bio;
    const unsigned char *cursor;

    bio = BIO_new_mem_buf(data, (int)size);
    if (!bio) {
        return NULL;
    }

    pkey = PEM_read_bio_PUBKEY(bio, NULL, NULL, NULL);
    if (pkey) {
        BIO_free(bio);
        return pkey;
    }

    BIO_free(bio);

    cursor = data;
    pkey = d2i_PUBKEY(NULL, &cursor, (long)size);
    if (pkey) {
        return pkey;
    }

    return NULL;
}

static EVP_PKEY *load_private_key_from_memory(const uint8_t *data, size_t size)
{
    EVP_PKEY *pkey = NULL;
    BIO *bio;
    const unsigned char *cursor = data;

    bio = BIO_new_mem_buf(data, (int)size);
    if (!bio) {
        return NULL;
    }

    pkey = PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL);
    BIO_free(bio);
    if (pkey) {
        return pkey;
    }

    return d2i_AutoPrivateKey(NULL, &cursor, (long)size);
}

static EVP_PKEY *load_v3_public_key(void)
{
    uint8_t *data = NULL;
    size_t size = 0;
    EVP_PKEY *pkey;

    if (!v3_public_key_file) {
        return NULL;
    }

    if (read_file(v3_public_key_file, &data, &size) != 0) {
        return NULL;
    }

    pkey = load_public_key_from_memory(data, size);
    free(data);
    return pkey;
}

static EVP_PKEY *load_v3_private_key(void)
{
    uint8_t *data = NULL;
    size_t size = 0;
    EVP_PKEY *pkey;

    if (!v3_private_key_file) {
        return NULL;
    }

    if (read_file(v3_private_key_file, &data, &size) != 0) {
        return NULL;
    }

    pkey = load_private_key_from_memory(data, size);
    free(data);
    return pkey;
}

static EVP_PKEY *load_v3_verification_key(void)
{
    if (v3_public_key_file) {
        return load_v3_public_key();
    }

    return load_v3_private_key();
}

static int verify_signature_with_key(EVP_PKEY *pkey, const uint8_t *data, size_t signed_size,
                                     const uint8_t *signature, size_t signature_size)
{
    EVP_MD_CTX *ctx = NULL;
    EVP_PKEY_CTX *pctx = NULL;
    int result = -1;

    ctx = EVP_MD_CTX_new();
    if (!ctx) {
        print_openssl_error("OpenSSL digest context allocation failed");
        goto cleanup;
    }

    if (EVP_DigestVerifyInit(ctx, &pctx, EVP_sha256(), NULL, pkey) != 1) {
        print_openssl_error("OpenSSL verify init failed");
        goto cleanup;
    }

    if (EVP_PKEY_CTX_set_rsa_padding(pctx, RSA_PKCS1_PADDING) != 1) {
        print_openssl_error("OpenSSL verify padding setup failed");
        goto cleanup;
    }

    if (EVP_DigestVerifyUpdate(ctx, data, signed_size) != 1) {
        print_openssl_error("OpenSSL verify update failed");
        goto cleanup;
    }

    result = EVP_DigestVerifyFinal(ctx, signature, signature_size);
    if (result != 1) {
        ERR_clear_error();
        result = -1;
        goto cleanup;
    }

    result = 0;

cleanup:
    EVP_MD_CTX_free(ctx);
    return result;
}

static int sign_signature_with_key(EVP_PKEY *pkey, const uint8_t *data, size_t signed_size, uint8_t *signature)
{
    EVP_MD_CTX *ctx = NULL;
    EVP_PKEY_CTX *pctx = NULL;
    size_t signature_size = ROOTFS_V3_SIGNATURE_SIZE;
    int result = -1;

    if ((size_t)EVP_PKEY_size(pkey) != ROOTFS_V3_SIGNATURE_SIZE) {
        fprintf(stderr, "Error: V3 private key must produce a %d-byte RSA signature\n", ROOTFS_V3_SIGNATURE_SIZE);
        return -1;
    }

    ctx = EVP_MD_CTX_new();
    if (!ctx) {
        print_openssl_error("OpenSSL digest context allocation failed");
        goto cleanup;
    }

    if (EVP_DigestSignInit(ctx, &pctx, EVP_sha256(), NULL, pkey) != 1) {
        print_openssl_error("OpenSSL sign init failed");
        goto cleanup;
    }

    if (EVP_PKEY_CTX_set_rsa_padding(pctx, RSA_PKCS1_PADDING) != 1) {
        print_openssl_error("OpenSSL sign padding setup failed");
        goto cleanup;
    }

    if (EVP_DigestSignUpdate(ctx, data, signed_size) != 1) {
        print_openssl_error("OpenSSL sign update failed");
        goto cleanup;
    }

    if (EVP_DigestSignFinal(ctx, signature, &signature_size) != 1) {
        print_openssl_error("OpenSSL sign final failed");
        goto cleanup;
    }

    if (signature_size != ROOTFS_V3_SIGNATURE_SIZE) {
        fprintf(stderr, "Error: Unexpected V3 signature size: " SIZE_T_FMT "\n", signature_size);
        goto cleanup;
    }

    result = 0;

cleanup:
    EVP_MD_CTX_free(ctx);
    return result;
}

int verify_v3_signature(const uint8_t *data, size_t file_size)
{
    EVP_PKEY *pkey;
    size_t signed_size;
    const uint8_t *signature;
    int result;

    if (file_size < ROOTFS_V3_SIGNATURE_SIZE) {
        fprintf(stderr, "Error: File too small for V3 signature verification\n");
        return -1;
    }

    if (!v3_public_key_file && !v3_private_key_file) {
        printf("Signature verification: SKIPPED\n");
        return 0;
    }

    pkey = load_v3_verification_key();
    if (!pkey) {
        print_openssl_error("OpenSSL verification key load failed");
        return -1;
    }

    signed_size = file_size - ROOTFS_V3_SIGNATURE_SIZE;
    signature = data + signed_size;
    result = verify_signature_with_key(pkey, data, signed_size, signature, ROOTFS_V3_SIGNATURE_SIZE);
    EVP_PKEY_free(pkey);

    if (result != 0) {
        fprintf(stderr, "Signature verification failed!\n");
        return -1;
    }

    printf("Signature verification: PASSED\n");
    return 0;
}

int sign_v3_signature(const uint8_t *data, size_t signed_size, uint8_t *signature)
{
    EVP_PKEY *pkey;
    int result;

    pkey = load_v3_private_key();
    if (!pkey) {
        print_openssl_error("OpenSSL private key load failed");
        return -1;
    }

    result = sign_signature_with_key(pkey, data, signed_size, signature);
    EVP_PKEY_free(pkey);
    return result;
}

int32_t hash(const uint8_t* data, uint32_t length, int format)
{
    const uint8_t *hash_table = use_new_hash_table(format) ? hash_table_new : hash_table_old;
    const uint32_t *hash_words = (const uint32_t *)hash_table;
    // 魔改版crc32
    uint64_t i = 0;
    uint32_t result = 0xffffffff;
    while (length != i) {
        uint8_t cur_byte = data[i++];
        uint32_t tmp = hash_words[(cur_byte ^ (uint8_t)result) & 0xf] ^ (result >> 4);
        result = hash_words[((uint8_t)tmp ^ (cur_byte >> 4)) & 0xf] ^ (tmp >> 4);
    }
    return result;
}

uint32_t get_rootfs_hash(const uint8_t *data, size_t length, int format) {
    // Calculate first hash
    uint32_t calculated_hash = hash(data, length, format);
    calculated_hash = (~calculated_hash) & 0xffffffff;
    calculated_hash = swap_bytes(calculated_hash);
    
    // Hash the hash
    uint8_t hash_bytes[4];
    memcpy(hash_bytes, &calculated_hash, 4);
    calculated_hash = hash(hash_bytes, 4, format);
    calculated_hash = (~calculated_hash) & 0xffffffff;
    calculated_hash = swap_bytes(calculated_hash);
    
    return calculated_hash;
}

void generate_extended_key_v2(const uint8_t *base_key, uint8_t *ext_key) {
    for (int i = 0; i < 1024; i++) {
        uint32_t val = base_key[i & 0xf] + (uint32_t)19916032  * ((int32_t)i + 1) / 131u;
        ext_key[i] = (uint8_t)val;
    }
}

void generate_random_key(uint8_t *key)
{
    static int seeded = 0;

#ifndef _WIN32
    FILE *urandom = fopen("/dev/urandom", "rb");
    if (urandom) {
        size_t bytes_read = fread(key, 1, ROOTFS_V3_KEY_SIZE, urandom);
        fclose(urandom);
        if (bytes_read == ROOTFS_V3_KEY_SIZE) {
            return;
        }
    }
#endif

    if (!seeded) {
        srand((unsigned int)(time(NULL) ^ (unsigned int)(uintptr_t)key));
        seeded = 1;
    }

    for (int i = 0; i < ROOTFS_V3_KEY_SIZE; i++) {
        key[i] = (uint8_t)(rand() & 0xff);
    }
}

void generate_v3_context(const uint8_t *seed, uint8_t *ext_key, uint8_t *perm, uint8_t *inv_perm)
{
    uint32_t j = 0;

    for (int i = 0; i < ROOTFS_V3_EXT_KEY_SIZE; i++) {
        uint64_t val = seed[i & 0xf] + ((uint64_t)19916032 * (uint64_t)(i + 1)) / 131u;
        ext_key[i] = (uint8_t)val;
    }

    for (int i = 0; i < ROOTFS_V3_EXT_KEY_SIZE; i++) {
        ext_key[i] ^= (uint8_t)(i + ext_key[(7 * i + 13) % ROOTFS_V3_EXT_KEY_SIZE]);
    }

    for (int i = 0; i < ROOTFS_V3_EXT_KEY_SIZE; i++) {
        uint8_t current = ext_key[i];
        uint8_t prev = ext_key[(ROOTFS_V3_EXT_KEY_SIZE + i - 1) % ROOTFS_V3_EXT_KEY_SIZE];
        uint8_t next = ext_key[(i + 1) % ROOTFS_V3_EXT_KEY_SIZE];
        ext_key[i] = (uint8_t)((prev + current + next) ^ rotl8(current, 1));
    }

    for (int i = 0; i < ROOTFS_V3_PERM_SIZE; i++) {
        perm[i] = (uint8_t)i;
    }

    for (int i = 0; i < ROOTFS_V3_PERM_SIZE; i++) {
        uint8_t tmp;

        j = (j + perm[i] + seed[i & 0xf]) & 0xff;
        tmp = perm[i];
        perm[i] = perm[j];
        perm[j] = tmp;
    }

    for (int i = 0; i < ROOTFS_V3_PERM_SIZE; i++) {
        inv_perm[perm[i]] = (uint8_t)i;
    }

    for (int i = 0; i < ROOTFS_V3_EXT_KEY_SIZE; i++) {
        uint8_t mask = (uint8_t)(0x10u >> ((i & 3) * 8));
        ext_key[i] = (uint8_t)(mask ^ perm[ext_key[i]]);
    }
}

void generate_v2_key(uint8_t *key, uint8_t *data, size_t length) {
    // Key = md5(md5(md5(rootfs) + crc32))

    MD5Context ctx;
    md5Init(&ctx);
    md5Update(&ctx, data, length);
    md5Finalize(&ctx);

    if (debug) {
        printf("Rootfs MD5: \n");
        hexdump(ctx.digest, 16);
    }

    uint8_t md5_result[20];

    uint32_t crc32 = get_rootfs_hash(data, length, ROOTFS_FORMAT_V2);

    if (debug) {
        printf("Rootfs CRC32: %08x\n", crc32);
    }

    memcpy(md5_result, ctx.digest + 8, 8); // Copy last 8 bytes
    memcpy(md5_result + 8, ctx.digest, 8); // Copy first 8 bytes
    memcpy(md5_result + 16, &crc32, 4);    // Append CRC32

    if (debug) {
        printf("MD5 + CRC32: \n");
        hexdump(md5_result, 20);
    }

    md5Init(&ctx);
    md5Update(&ctx, md5_result, 20);
    md5Finalize(&ctx);

    uint8_t md5[16];
    memcpy(md5, ctx.digest, 16);

    if (debug) {
        printf("Generated Key1: \n");
        hexdump(md5, 16);
    }

    md5Init(&ctx);
    md5Update(&ctx, md5, 16);
    md5Finalize(&ctx);

    if (debug) {
        printf("Generated Key2: \n");
        hexdump(ctx.digest, 16);
    }

    memcpy(key, ctx.digest, 16);
}

static int encode_rootfs_legacy(uint8_t *data, size_t *data_size, const uint8_t *key, int format)
{
    size_t original_size = *data_size;
    
    if (original_size < 1) {
        fprintf(stderr, "Error: File is empty\n");
        return -1;
    }
    
    // Generate extended key
    uint8_t ext_key[1024];
    generate_extended_key_v2(key, ext_key);
    
    // Calculate hash for the encoded data
    uint32_t calculated_hash = get_rootfs_hash(data, original_size, format);
    
    // Calculate parameters
    int8_t size_low_byte = (int8_t)original_size;
    
    // Encode the data (reverse of decode process)
    for (size_t iter_val = original_size; iter_val > 0; iter_val--) {
        uint32_t tmp_var = (uint32_t)(iter_val - 1);
        uint8_t new_low_byte = (uint8_t)(size_low_byte + ext_key[tmp_var % 1024]);
        tmp_var = (tmp_var & 0xffffff00) | new_low_byte;
        
        size_t target_index = iter_val - 1;
        if (target_index < original_size) {
            uint8_t current_byte = data[target_index];
            uint8_t tmp_var_byte = tmp_var & 0xff;
            uint8_t shift_amount = (tmp_var_byte % 7) + 1;
            
            // Reverse circular left shift (circular right shift)
            uint8_t rotated = (current_byte >> shift_amount) | (uint8_t)(current_byte << (8 - shift_amount));
            
            // Add instead of subtract (reverse of subtraction)
            uint8_t result = (uint8_t)(rotated + tmp_var_byte);
            data[target_index] = result;
        }
    }
    
    // Append key if new rootfs format
    if (format == ROOTFS_FORMAT_V2) {
        memcpy(data + original_size, key, 16);
        *data_size = original_size + ROOTFS_V2_TRAILER_SIZE;
    } else {
        *data_size = original_size + 4;
    }
    
    // Append hash to the end
    size_t hash_offset = format == ROOTFS_FORMAT_V2 ? original_size + ROOTFS_V2_KEY_SIZE : original_size;
    memcpy(data + hash_offset, &calculated_hash, 4);
    
    printf("Encrypt data size: " SIZE_T_FMT "\n", *data_size);
    return 0;
}

static int decode_rootfs_legacy(uint8_t *data, size_t *data_size, uint8_t *key, int format)
{
    size_t file_size = *data_size;
    
    if (file_size < 4) {
        fprintf(stderr, "Error: File too small (less than 4 bytes)\n");
        return -1;
    }
    
    // Extract hash from end of file
    uint32_t authentic_hash;
    memcpy(&authentic_hash, data + file_size - 4, 4);
    
    // Extract key and adjust data size
    size_t actual_data_size;
    if (format == ROOTFS_FORMAT_V2) {
        if (file_size < ROOTFS_V2_TRAILER_SIZE) {
            fprintf(stderr, "Error: File too small for new rootfs format\n");
            return -1;
        }
        memcpy(key, data + file_size - ROOTFS_V2_TRAILER_SIZE, ROOTFS_V2_KEY_SIZE);
        actual_data_size = file_size - ROOTFS_V2_TRAILER_SIZE;
    } else {
        memcpy(key, default_key, 16);
        actual_data_size = file_size - 4;
    }

    if (debug) {
        printf("Extracted Key: \n");
        hexdump(key, 16);
    }
    
    // Generate extended key
    uint8_t ext_key[1024];
    generate_extended_key_v2(key, ext_key);
    
    // Calculate parameters
    int8_t size_low_byte = (int8_t)actual_data_size;
    
    // Decode the data
    for (size_t iter_val = 0; iter_val < actual_data_size; iter_val++) {
        uint32_t tmp_var = (uint32_t)iter_val;
        uint8_t new_low_byte = (uint8_t)(size_low_byte + ext_key[tmp_var % 1024]);
        tmp_var = (tmp_var & 0xffffff00) | new_low_byte;
        
        if (iter_val < actual_data_size) {
            uint8_t current_byte = data[iter_val];
            uint8_t tmp_var_byte = tmp_var & 0xff;
            
            // Subtract and rotate
            uint8_t diff = (uint8_t)(current_byte - tmp_var_byte);
            uint8_t shift_amount = (tmp_var_byte % 7) + 1;
            
            // Circular left shift
            uint8_t rotated = (uint8_t)(diff << shift_amount) | (diff >> (8 - shift_amount));
            data[iter_val] = rotated;
        }
    }
    
    // Verify hash
    uint32_t calculated_hash = get_rootfs_hash(data, actual_data_size, format);
    
    if (calculated_hash != authentic_hash) {
        printf("Hash verification failed!\n");
        printf("Calculated: 0x%08x\n", calculated_hash);
        printf("Authentic:  0x%08x\n", authentic_hash);
        return -1;
    } else {
        printf("Hash verification: PASSED\n");
        if (debug) {
            printf("Calculated: 0x%08x\n", calculated_hash);
            printf("Authentic:  0x%08x\n", authentic_hash);
        }
    }
    
    *data_size = actual_data_size;
    return 0;
}

static int encode_rootfs_v3(uint8_t *data, size_t *data_size, const uint8_t *seed, const uint8_t *signature)
{
    size_t original_size = *data_size;
    size_t signed_size = original_size + ROOTFS_V3_KEY_SIZE + ROOTFS_V3_HASH_SIZE;
    uint8_t ext_key[ROOTFS_V3_EXT_KEY_SIZE];
    uint8_t perm[ROOTFS_V3_PERM_SIZE];
    uint8_t inv_perm[ROOTFS_V3_PERM_SIZE];
    uint8_t generated_signature[ROOTFS_V3_SIGNATURE_SIZE];
    uint32_t calculated_hash;
    const uint8_t *final_signature = signature;

    if (original_size < 1) {
        fprintf(stderr, "Error: File is empty\n");
        return -1;
    }

    if (original_size > UINT32_MAX - ROOTFS_V3_TRAILER_SIZE) {
        fprintf(stderr, "Error: File too large for v3 rootfs format\n");
        return -1;
    }

    generate_v3_context(seed, ext_key, perm, inv_perm);
    calculated_hash = get_rootfs_hash(data, original_size, ROOTFS_FORMAT_V3);

    if (debug) {
        printf("V3 Seed: \n");
        hexdump((unsigned char *)seed, ROOTFS_V3_KEY_SIZE);
    }

    for (int round = 0; round < ROOTFS_V3_ROUNDS; round++) {
        for (uint32_t index = 0; index < (uint32_t)original_size; index++) {
            uint32_t ext_value = ext_key[(17 * round + index) % ROOTFS_V3_EXT_KEY_SIZE];
            uint32_t mix = ext_value + (uint32_t)original_size + (uint32_t)round;
            uint8_t carry = (uint8_t)(mix >> 8);
            uint8_t shift = (uint8_t)((mix & 7u) + 1u);
            uint8_t value = perm[data[index]];

            value = (uint8_t)(value + (uint8_t)(mix + (uint32_t)round));
            value = rotl8(value, shift);
            value ^= carry;
            value = (uint8_t)(value + (uint8_t)round + carry);
            data[index] = value;
        }
    }

    memcpy(data + original_size, seed, ROOTFS_V3_KEY_SIZE);
    memcpy(data + original_size + ROOTFS_V3_KEY_SIZE, &calculated_hash, ROOTFS_V3_HASH_SIZE);

    if (!final_signature) {
        if (!v3_private_key_file) {
            fprintf(stderr, "Error: V3 encode requires -s SIGNATURE_FILE or -p PRIVATE_KEY_FILE\n");
            return -1;
        }

        if (sign_v3_signature(data, signed_size, generated_signature) != 0) {
            return -1;
        }

        final_signature = generated_signature;
    }

    memcpy(data + original_size + ROOTFS_V3_KEY_SIZE + ROOTFS_V3_HASH_SIZE,
           final_signature,
           ROOTFS_V3_SIGNATURE_SIZE);

    *data_size = original_size + ROOTFS_V3_TRAILER_SIZE;

    if (verify_v3_signature(data, *data_size) != 0) {
        return -1;
    }

    printf("Encrypt data size: " SIZE_T_FMT "\n", *data_size);
    return 0;
}

static int decode_rootfs_v3(uint8_t *data, size_t *data_size, uint8_t *seed, uint8_t *signature)
{
    size_t file_size = *data_size;
    uint8_t ext_key[ROOTFS_V3_EXT_KEY_SIZE];
    uint8_t perm[ROOTFS_V3_PERM_SIZE];
    uint8_t inv_perm[ROOTFS_V3_PERM_SIZE];
    uint32_t authentic_hash;

    if (file_size < ROOTFS_V3_TRAILER_SIZE) {
        fprintf(stderr, "Error: File too small for v3 rootfs format\n");
        return -1;
    }

    if (verify_v3_signature(data, file_size) != 0) {
        return -1;
    }

    size_t actual_data_size = file_size - ROOTFS_V3_TRAILER_SIZE;
    memcpy(seed, data + actual_data_size, ROOTFS_V3_KEY_SIZE);
    memcpy(&authentic_hash, data + actual_data_size + ROOTFS_V3_KEY_SIZE, ROOTFS_V3_HASH_SIZE);

    if (signature) {
        memcpy(signature,
               data + actual_data_size + ROOTFS_V3_KEY_SIZE + ROOTFS_V3_HASH_SIZE,
               ROOTFS_V3_SIGNATURE_SIZE);
    }

    if (debug) {
        printf("Extracted V3 Seed: \n");
        hexdump(seed, ROOTFS_V3_KEY_SIZE);
    }

    generate_v3_context(seed, ext_key, perm, inv_perm);

    for (int round = ROOTFS_V3_ROUNDS - 1; round >= 0; round--) {
        for (uint32_t index = 0; index < (uint32_t)actual_data_size; index++) {
            uint32_t ext_value = ext_key[(17 * round + index) % ROOTFS_V3_EXT_KEY_SIZE];
            uint32_t mix = ext_value + (uint32_t)actual_data_size + (uint32_t)round;
            uint8_t carry = (uint8_t)(mix >> 8);
            uint8_t shift = (uint8_t)((mix & 7u) + 1u);
            uint8_t value = data[index];

            value = (uint8_t)(value - (uint8_t)round - carry);
            value ^= carry;
            value = rotr8(value, shift);
            value = (uint8_t)(value - (uint8_t)(mix + (uint32_t)round));
            data[index] = inv_perm[value];
        }
    }

    uint32_t calculated_hash = get_rootfs_hash(data, actual_data_size, ROOTFS_FORMAT_V3);

    if (calculated_hash != authentic_hash) {
        printf("Hash verification failed!\n");
        printf("Calculated: 0x%08x\n", calculated_hash);
        printf("Authentic:  0x%08x\n", authentic_hash);
        return -1;
    } else {
        printf("Hash verification: PASSED\n");
        if (debug) {
            printf("Calculated: 0x%08x\n", calculated_hash);
            printf("Authentic:  0x%08x\n", authentic_hash);
        }
    }

    *data_size = actual_data_size;
    return 0;
}

int encode_rootfs(uint8_t *data, size_t *data_size, const uint8_t *key, const uint8_t *signature, int format)
{
    if (format == ROOTFS_FORMAT_V3) {
        return encode_rootfs_v3(data, data_size, key, signature);
    }

    return encode_rootfs_legacy(data, data_size, key, format);
}

int decode_rootfs(uint8_t *data, size_t *data_size, uint8_t *key, uint8_t *signature, int format)
{
    if (format == ROOTFS_FORMAT_V3) {
        return decode_rootfs_v3(data, data_size, key, signature);
    }

    return decode_rootfs_legacy(data, data_size, key, format);
}

int read_file(const char *filename, uint8_t **data, size_t *size) {
    FILE *file = fopen(filename, "rb");
    if (!file) {
        perror("Error opening input file");
        return -1;
    }
    
    // Get file size
    fseek(file, 0, SEEK_END);
    *size = ftell(file);
    fseek(file, 0, SEEK_SET);
    
    // Allocate buffer with extra space for encoding
    *data = malloc(*size + 1024);  // Extra space for key and hash
    if (!*data) {
        fprintf(stderr, "Memory allocation failed\n");
        fclose(file);
        return -1;
    }
    
    // Read file
    size_t bytes_read = fread(*data, 1, *size, file);
    fclose(file);
    
    if (bytes_read != *size) {
        fprintf(stderr, "Error reading file\n");
        free(*data);
        return -1;
    }
    
    return 0;
}

int write_file(const char *filename, const uint8_t *data, size_t size) {
    FILE *file = fopen(filename, "wb");
    if (!file) {
        perror("Error opening output file");
        return -1;
    }
    
    size_t bytes_written = fwrite(data, 1, size, file);
    fclose(file);
    
    if (bytes_written != size) {
        fprintf(stderr, "Error writing file\n");
        return -1;
    }
    
    return 0;
}


int create_directory(const char *path) {
#ifdef _WIN32
    return _mkdir(path);
#else
    return mkdir(path, 0755);
#endif
}

char *join_path(const char *dir, const char *filename) {
    size_t dir_len = strlen(dir);
    size_t filename_len = strlen(filename);
    char *path = malloc(dir_len + filename_len + 2);  // +2 for separator and null terminator
    
    if (!path) return NULL;
    
    strcpy(path, dir);
    if (dir_len > 0 && dir[dir_len - 1] != '/' && dir[dir_len - 1] != '\\') {
#ifdef _WIN32
        strcat(path, "\\");
#else
        strcat(path, "/");
#endif
    }
    strcat(path, filename);
    
    return path;
}


void print_usage(const char *program_name) {
    printf("Usage: %s <operation> <input_file> <output_dir|output_file> [OPTIONS]\n", program_name);
    printf("\nOperations:\n");
    printf("  decode       Decode format rootfs\n");
    printf("  encode       Encode format rootfs\n");
    printf("\nArguments:\n");
    printf("  input_file         Input rootfs file\n");
    printf("  output_dir         Output directory (decode operations)\n");
    printf("  output_file        Output file (encode operations)\n");
    printf("\nOptions:\n");
    printf("  -v1                Use v1 rootfs format (default)\n");
    printf("  -v2                Use v2 rootfs format\n");
    printf("  -v3                Use v3 rootfs format\n");
    printf("  -d                 Debug\n");
    printf("  -l LENGTH          Rootfs length\n");
    printf("  -a APPEND_FILE     File to append (encode operations)\n");
    printf("  -k KEY_FILE        Reuse decoded 16-byte key/seed for byte-exact encode\n");
    printf("  -p PRIVATE_KEY     V3 private key for signing or signature verification\n");
    printf("  -s SIGNATURE_FILE  Signature file for v3 encode operations\n");
    printf("  -u PUBLIC_KEY      Override v3 RSA public key for signature verification\n");
    printf("  -h                 Show this help message\n");
    printf("\nExamples:\n");
    printf("  %s decode rootfs output_dir\n", program_name);
    printf("  %s decode rootfs output_dir -v2\n", program_name);
    printf("  %s decode rootfs output_dir -v3\n", program_name);
    printf("  %s decode rootfs output_dir -v3 -p private.pem\n", program_name);
    printf("  %s decode rootfs output_dir -l 1048576\n", program_name);
    printf("  %s encode rootfs.img output.img -a end.img\n", program_name);
    printf("  %s encode rootfs.img.xz output.img -v2 -k key.bin\n", program_name);
    printf("  %s encode rootfs.img.xz output.img -v3 -k key.bin -s signature.bin\n", program_name);
    printf("  %s encode rootfs.img.xz output.img -v3 -k key.bin -p private.pem\n", program_name);
}

int main(int argc, char *argv[]) {
    if (argc < 4) {
        print_usage(argv[0]);
        return 1;
    }
    
    char *operation = argv[1];
    char *input_file = argv[2];
    char *output_path = argv[3];
    char *append_file = NULL;
    char *key_file = NULL;
    char *private_key_file = NULL;
    char *signature_file = NULL;
    char *public_key_file = NULL;
    size_t end_length = 0;
    int has_end_length = 0;
    int format = ROOTFS_FORMAT_V1;
    
    // Parse optional arguments
    for (int i = 4; i < argc; i++) {
        if (strcmp(argv[i], "-l") == 0 && i + 1 < argc) {
            end_length = strtoul(argv[++i], NULL, 10);
            has_end_length = 1;
        } else if (strcmp(argv[i], "-a") == 0 && i + 1 < argc) {
            append_file = argv[++i];
        } else if (strcmp(argv[i], "-k") == 0 && i + 1 < argc) {
            key_file = argv[++i];
        } else if (strcmp(argv[i], "-p") == 0 && i + 1 < argc) {
            private_key_file = argv[++i];
        } else if (strcmp(argv[i], "-v1") == 0) {
            format = ROOTFS_FORMAT_V1;
        } else if (strcmp(argv[i], "-v2") == 0) {
            format = ROOTFS_FORMAT_V2;
        } else if (strcmp(argv[i], "-v3") == 0) {
            format = ROOTFS_FORMAT_V3;
        } else if (strcmp(argv[i], "-s") == 0 && i + 1 < argc) {
            signature_file = argv[++i];
        } else if (strcmp(argv[i], "-u") == 0 && i + 1 < argc) {
            public_key_file = argv[++i];
        } else if (strcmp(operation, "encode") == 0 && append_file == NULL && argv[i][0] != '-') {
            append_file = argv[i];
        } else if (strcmp(argv[i], "-d") == 0) {
            debug = 1;
        } else if (strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            print_usage(argv[0]);
            return 1;
        }
    }
    
    // Validate operation
    int is_encode = strcmp(operation, "encode") == 0;
    int is_decode = strcmp(operation, "decode") == 0;
    
    if (!is_encode && !is_decode) {
        fprintf(stderr, "Error: Invalid operation. Must be decode, encode\n");
        return 1;
    }

    if (format == ROOTFS_FORMAT_V3 && has_end_length) {
        fprintf(stderr, "Error: -l is not supported with v3 rootfs format\n");
        return 1;
    }

    if (format == ROOTFS_FORMAT_V3 && append_file) {
        fprintf(stderr, "Error: -a is not supported with v3 rootfs format\n");
        return 1;
    }

    if (signature_file && (!is_encode || format != ROOTFS_FORMAT_V3)) {
        fprintf(stderr, "Error: -s is only supported for v3 encode operations\n");
        return 1;
    }

    if (private_key_file && format != ROOTFS_FORMAT_V3) {
        fprintf(stderr, "Error: -p is only supported for v3 rootfs format\n");
        return 1;
    }

    if (public_key_file && format != ROOTFS_FORMAT_V3) {
        fprintf(stderr, "Error: -u is only supported for v3 rootfs format\n");
        return 1;
    }

    if (key_file && !is_encode) {
        fprintf(stderr, "Error: -k is only supported for encode operations\n");
        return 1;
    }

    if (signature_file && private_key_file) {
        fprintf(stderr, "Error: -s and -p cannot be used together\n");
        return 1;
    }

    if (is_encode && format == ROOTFS_FORMAT_V3 && !signature_file && !private_key_file) {
        fprintf(stderr, "Error: V3 encode requires -s SIGNATURE_FILE or -p PRIVATE_KEY_FILE\n");
        return 1;
    }

    v3_private_key_file = private_key_file;
    v3_public_key_file = public_key_file;
    
    // Read input file
    uint8_t *data;
    size_t data_size;
    if (read_file(input_file, &data, &data_size) != 0) {
        return 1;
    }

    uint8_t signature[ROOTFS_V3_SIGNATURE_SIZE] = {0};
    int has_signature = 0;
    uint8_t provided_key[ROOTFS_V3_KEY_SIZE] = {0};
    int has_provided_key = 0;

    if (key_file) {
        uint8_t *key_data = NULL;
        size_t key_size = 0;

        if (read_file(key_file, &key_data, &key_size) != 0) {
            free(data);
            return 1;
        }

        if (key_size != ROOTFS_V3_KEY_SIZE) {
            fprintf(stderr, "Error: Key file must be %d bytes\n", ROOTFS_V3_KEY_SIZE);
            free(key_data);
            free(data);
            return 1;
        }

        memcpy(provided_key, key_data, ROOTFS_V3_KEY_SIZE);
        has_provided_key = 1;
        free(key_data);
    }

    if (signature_file) {
        uint8_t *signature_data = NULL;
        size_t signature_size = 0;

        if (read_file(signature_file, &signature_data, &signature_size) != 0) {
            free(data);
            return 1;
        }

        if (signature_size != ROOTFS_V3_SIGNATURE_SIZE) {
            fprintf(stderr, "Error: Signature file must be %d bytes\n", ROOTFS_V3_SIGNATURE_SIZE);
            free(signature_data);
            free(data);
            return 1;
        }

        memcpy(signature, signature_data, ROOTFS_V3_SIGNATURE_SIZE);
        has_signature = 1;
        free(signature_data);
    }
    
    // For decode operations, create output directory
    if (is_decode) {
        create_directory(output_path);
    }
    
    // Handle end extraction for decode operations
    if (is_decode && has_end_length && end_length < data_size) {
        // Extract end data
        size_t end_size = data_size - end_length;
        uint8_t *end_data = data + end_length;
        
        // Write end data file
        char *end_output = join_path(output_path, "end.gz");
        if (end_output) {
            if (write_file(end_output, end_data, end_size) == 0) {
                printf("Extracted end.gz (" SIZE_T_FMT " bytes)\n", end_size);
            }
            free(end_output);
        }
        
        // Adjust data size to exclude end data
        data_size = end_length;
    }
    
    // Prepare key
    uint8_t key[ROOTFS_V3_KEY_SIZE];
    if (is_encode) {
        if (has_provided_key) {
            memcpy(key, provided_key, ROOTFS_V3_KEY_SIZE);
        } else if (format == ROOTFS_FORMAT_V2) {
            generate_v2_key(key, data, data_size);
        } else if (format == ROOTFS_FORMAT_V3) {
            generate_random_key(key);
        } else {
            memcpy(key, default_key, ROOTFS_V3_KEY_SIZE);
        }
    } else {
        memcpy(key, default_key, ROOTFS_V3_KEY_SIZE);
    }
    
    // Perform operation
    int result;
    if (is_encode) {
        result = encode_rootfs(data, &data_size, key, has_signature ? signature : NULL, format);
    } else {
        result = decode_rootfs(data, &data_size, key, format == ROOTFS_FORMAT_V3 ? signature : NULL, format);
    }
    
    if (result != 0) {
        free(data);
        return 1;
    }

    if (is_decode) {
        char *key_output = join_path(output_path, "key.bin");
        if (key_output) {
            write_file(key_output, key, ROOTFS_V3_KEY_SIZE);
            free(key_output);
        }

        if (format == ROOTFS_FORMAT_V3) {
            char *signature_output = join_path(output_path, "signature.bin");
            if (signature_output) {
                write_file(signature_output, signature, ROOTFS_V3_SIGNATURE_SIZE);
                free(signature_output);
            }
        }
    }
    
    // Handle append file for encode operations
    if (is_encode && append_file) {
        uint8_t *append_data;
        size_t append_size;
        if (read_file(append_file, &append_data, &append_size) == 0) {
            // Reallocate data to include append file
            data = realloc(data, data_size + append_size);
            if (data) {
                memcpy(data + data_size, append_data, append_size);
                data_size += append_size;
                printf("Added %s (" SIZE_T_FMT " bytes)\n", append_file, append_size);
            }
            free(append_data);
        }
    }
    
    // Write output file
    char *final_output_path;
    if (is_decode) {
        final_output_path = join_path(output_path, "rootfs.ext2");
    } else {
        final_output_path = strdup(output_path);
    }
    
    if (final_output_path) {
        if (write_file(final_output_path, data, data_size) == 0) {
            printf("%s completed successfully: %s\n", operation, final_output_path);
        }
        free(final_output_path);
    }
    
    free(data);
    return 0;
}
