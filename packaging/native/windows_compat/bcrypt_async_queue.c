/* SPDX-License-Identifier: Apache-2.0 */
#include "bcrypt_compat.h"

async_queue_t *async_queue_create(char *mutex_name, char *condvar_name) {
    async_queue_t *queue = enif_alloc(sizeof(*queue));
    if (queue == NULL) {
        abort();
    }
    queue->head = NULL;
    queue->tail = NULL;
    queue->waiting_threads = 0;
    queue->len = 0;
    queue->mutex = enif_mutex_create(mutex_name);
    queue->cond = enif_cond_create(condvar_name);
    if (queue->mutex == NULL || queue->cond == NULL) {
        abort();
    }
    return queue;
}

int async_queue_length(async_queue_t *queue) {
    int length;
    enif_mutex_lock(queue->mutex);
    length = queue->len - queue->waiting_threads;
    enif_mutex_unlock(queue->mutex);
    return length;
}

void *async_queue_pop(async_queue_t *queue) {
    notify_bcrypt_queue_entry_t *entry;
    void *data;

    enif_mutex_lock(queue->mutex);
    queue->waiting_threads += 1;
    while (queue->head == NULL) {
        enif_cond_wait(queue->cond, queue->mutex);
    }
    queue->waiting_threads -= 1;

    entry = queue->head;
    queue->head = entry->next;
    if (queue->head == NULL) {
        queue->tail = NULL;
    }
    queue->len -= 1;
    data = entry->data;
    enif_free(entry);
    enif_mutex_unlock(queue->mutex);
    return data;
}

void async_queue_push(async_queue_t *queue, void *data) {
    notify_bcrypt_queue_entry_t *entry = enif_alloc(sizeof(*entry));
    if (entry == NULL) {
        abort();
    }
    entry->data = data;
    entry->next = NULL;

    enif_mutex_lock(queue->mutex);
    if (queue->tail == NULL) {
        queue->head = entry;
    } else {
        queue->tail->next = entry;
    }
    queue->tail = entry;
    queue->len += 1;
    enif_cond_signal(queue->cond);
    enif_mutex_unlock(queue->mutex);
}

void async_queue_destroy(async_queue_t *queue) {
    notify_bcrypt_queue_entry_t *entry = queue->head;
    while (entry != NULL) {
        notify_bcrypt_queue_entry_t *next = entry->next;
        enif_free(entry);
        entry = next;
    }
    enif_cond_destroy(queue->cond);
    enif_mutex_destroy(queue->mutex);
    enif_free(queue);
}
