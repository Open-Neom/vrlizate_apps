// Copyright 2026 The VRlizate SDK Authors.
// Licensed under the Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0).
//
// Portable POSIX zero-unpack file descriptor & mmap C ABI declarations parsed
// by `package:ffigen` (`dart run tool/ffigen.dart`).

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void* malloc(size_t size);
void free(void* ptr);
int open(const char* path, int flags, ...);
int close(int fd);
int fcntl(int fd, int cmd, ...);
int64_t lseek(int fd, int64_t offset, int whence);
int64_t lseek64(int fd, int64_t offset, int whence);
intptr_t pread(int fd, void* buf, size_t count, int64_t offset);
intptr_t pread64(int fd, void* buf, size_t count, int64_t offset);
void* mmap(void* addr, size_t len, int prot, int flags, int fd, int64_t offset);
void* mmap64(void* addr, size_t len, int prot, int flags, int fd, int64_t offset);
int munmap(void* addr, size_t len);

#ifdef __cplusplus
}
#endif
