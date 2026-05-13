#include "logger.hpp"
#include <cstdio>
#include <cstdarg>

#ifdef _WIN32
#  include <io.h>
#  define isatty   _isatty
#  define fileno   _fileno
#else
#  include <unistd.h>
#endif

namespace {

bool g_debug = false;

// ANSI escape codes
static const char *COL_RESET   = "\033[0m";
static const char *COL_BOLD_RED= "\033[1;31m";
static const char *COL_GREEN   = "\033[1;32m";
static const char *COL_YELLOW  = "\033[33m";
static const char *COL_DIM     = "\033[2m";
static const char *COL_BOLD    = "\033[1m";

inline bool color_stdout() { return isatty(fileno(stdout))  != 0; }
inline bool color_stderr() { return isatty(fileno(stderr)) != 0; }

void vprint(FILE *stream, const char *pre, const char *post, bool use_col,
            const char *fmt, va_list ap) {
    if (use_col && pre)  fputs(pre,  stream);
    vfprintf(stream, fmt, ap);
    if (use_col && post) fputs(post, stream);
    fputc('\n', stream);
}

} // namespace

void Log::set_debug(bool enabled) { g_debug = enabled; }
bool Log::is_debug()              { return g_debug; }

void Log::info(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vprint(stdout, nullptr, nullptr, false, fmt, ap);
    va_end(ap);
}

void Log::success(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vprint(stdout, COL_GREEN, COL_RESET, color_stdout(), fmt, ap);
    va_end(ap);
}

void Log::warn(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vprint(stdout, COL_YELLOW, COL_RESET, color_stdout(), fmt, ap);
    va_end(ap);
}

void Log::error(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vprint(stderr, COL_BOLD_RED, COL_RESET, color_stderr(), fmt, ap);
    va_end(ap);
}

void Log::debug(const char *fmt, ...) {
    if (!g_debug) return;
    va_list ap; va_start(ap, fmt);
    vprint(stdout, COL_DIM, COL_RESET, color_stdout(), fmt, ap);
    va_end(ap);
}

void Log::hexdump(const char *label, const uint8_t *buf, int size) {
    bool col = color_stdout();
    if (label && *label) {
        if (col) fputs(COL_BOLD, stdout);
        printf("%s:", label);
        if (col) fputs(COL_RESET, stdout);
        putchar('\n');
    }
    if (col) fputs(COL_DIM, stdout);
    for (int i = 0; i < size; i += 16) {
        printf("%08X: ", i);
        for (int j = 0; j < 16; j++) {
            if (i + j < size) printf("%02X ", buf[i + j]);
            else               printf("   ");
        }
        printf(" ");
        for (int j = 0; j < 16; j++) {
            if (i + j < size) {
                uint8_t c = buf[i + j];
                printf("%c", (c >= ' ' && c < 127) ? c : '.');
            }
        }
        putchar('\n');
    }
    if (col) fputs(COL_RESET, stdout);
}
