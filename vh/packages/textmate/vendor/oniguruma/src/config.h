/* Visual Haskell portable Oniguruma configuration.
 *
 * The upstream build normally generates this header with configure/CMake.
 * Visual Haskell builds the reviewed sources directly through Cabal, so the
 * small platform split is kept here instead. Keep it in sync when updating
 * the pinned Oniguruma release.
 */
#ifndef VISUAL_HASKELL_ONIG_CONFIG_H
#define VISUAL_HASKELL_ONIG_CONFIG_H

#define PACKAGE "onig"
#define PACKAGE_NAME "onig"
#define PACKAGE_TARNAME "onig"
#define PACKAGE_VERSION "6.9.10"
#define VERSION "6.9.10"
#define SIZEOF_INT 4
#define SIZEOF_LONG_LONG 8

#if defined(_WIN32)
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_ALLOCA 1
#define SIZEOF_LONG 4
#if defined(_WIN64)
#define SIZEOF_VOIDP 8
#else
#define SIZEOF_VOIDP 4
#endif
#else
#define HAVE_ALLOCA 1
#define HAVE_ALLOCA_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIMES_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define STDC_HEADERS 1
#define SIZEOF_LONG 8
#define SIZEOF_VOIDP 8
#endif

#endif
