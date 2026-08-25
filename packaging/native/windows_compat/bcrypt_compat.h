/* SPDX-License-Identifier: Apache-2.0 */
#ifndef NOTIFY_WINDOWS_BCRYPT_COMPAT_H
#define NOTIFY_WINDOWS_BCRYPT_COMPAT_H

#include <stdint.h>
#include <stdlib.h>
#include <erl_nif.h>

#define u_int8_t uint8_t
#define u_int16_t uint16_t
#define u_int32_t uint32_t
#define u_int64_t uint64_t

#define __ASYNC_QUEUE_H_INCLUDED__

typedef struct notify_bcrypt_queue_entry {
    void *data;
    struct notify_bcrypt_queue_entry *next;
} notify_bcrypt_queue_entry_t;

typedef struct __async_queue {
    notify_bcrypt_queue_entry_t *head;
    notify_bcrypt_queue_entry_t *tail;
    ErlNifMutex *mutex;
    ErlNifCond *cond;
    int waiting_threads;
    int len;
} async_queue_t;

async_queue_t *async_queue_create(char *mutex_name, char *condvar_name);
int async_queue_length(async_queue_t *queue);
void *async_queue_pop(async_queue_t *queue);
void async_queue_push(async_queue_t *queue, void *data);
void async_queue_destroy(async_queue_t *queue);

#define errx(exit_code, ...) \
    do { \
        (void)(exit_code); \
        abort(); \
    } while (0)

#endif
