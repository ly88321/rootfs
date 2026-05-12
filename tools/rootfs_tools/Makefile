CC = gcc

CFLAGS = -Wall -Wextra -O3 -std=c99
LDLIBS = -lcrypto

rootfs: md5.c rootfs.c
	@$(CC) $(CFLAGS) -o rootfs md5.c rootfs.c $(LDLIBS)

clean:
	@$(RM) rootfs
