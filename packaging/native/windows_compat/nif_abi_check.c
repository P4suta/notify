/* SPDX-License-Identifier: Apache-2.0 */
#include <stddef.h>

#include "erl_nif.h"

/* The public Windows header maps these API names back to callback members. */
#undef enif_get_int64
#undef enif_get_uint64
#undef enif_is_exception
#undef enif_make_int64
#undef enif_make_uint64

#if !defined(_WIN64)
#error "Windows amd64 NIFs require the _WIN64 target"
#endif

#if SIZEOF_CHAR != 1
#error "unexpected Windows amd64 char size"
#endif
#if SIZEOF_SHORT != 2
#error "unexpected Windows amd64 short size"
#endif
#if SIZEOF_INT != 4
#error "unexpected Windows amd64 int size"
#endif
#if SIZEOF_LONG != 4
#error "unexpected Windows amd64 long size"
#endif
#if SIZEOF_LONG_LONG != 8
#error "unexpected Windows amd64 long long size"
#endif
#if SIZEOF_VOID_P != 8
#error "unexpected Windows amd64 pointer size"
#endif

_Static_assert(sizeof(char) == SIZEOF_CHAR, "ERTS char configuration drifted");
_Static_assert(sizeof(short) == SIZEOF_SHORT, "ERTS short configuration drifted");
_Static_assert(sizeof(int) == SIZEOF_INT, "ERTS int configuration drifted");
_Static_assert(sizeof(long) == SIZEOF_LONG, "ERTS long configuration drifted");
_Static_assert(
    sizeof(long long) == SIZEOF_LONG_LONG,
    "ERTS long long configuration drifted");
_Static_assert(
    sizeof(void *) == SIZEOF_VOID_P,
    "ERTS pointer configuration drifted");

/*
 * Windows ERTS passes this callback table to nif_init. The four 64-bit
 * callbacks exist only when SIZEOF_LONG is not 8, so an LP64 host header
 * would shift every callback that follows them and crash loaded NIFs.
 */
_Static_assert(
    offsetof(TWinDynNifCallbacks, enif_is_exception) ==
        offsetof(TWinDynNifCallbacks, enif_get_int64) +
            sizeof(((TWinDynNifCallbacks *)0)->enif_get_int64) +
            sizeof(((TWinDynNifCallbacks *)0)->enif_get_uint64) +
            sizeof(((TWinDynNifCallbacks *)0)->enif_make_int64) +
            sizeof(((TWinDynNifCallbacks *)0)->enif_make_uint64),
    "Windows ERTS 64-bit callback layout drifted");
