#ifndef VISUAL_HASKELL_TEXTMATE_H
#define VISUAL_HASKELL_TEXTMATE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *VisualHaskellTextMateRegexRef;

int32_t visual_haskell_textmate_compile(
    const uint8_t *pattern,
    size_t pattern_length,
    VisualHaskellTextMateRegexRef *result,
    int32_t *capture_count,
    char *error_message,
    size_t error_capacity);

void visual_haskell_textmate_regex_free(VisualHaskellTextMateRegexRef regex);

int32_t visual_haskell_textmate_search(
    VisualHaskellTextMateRegexRef regex,
    const uint8_t *subject,
    size_t subject_length,
    size_t start_offset,
    int32_t *capture_pairs,
    size_t capture_pair_capacity,
    int32_t *capture_count,
    char *error_message,
    size_t error_capacity);

const char *visual_haskell_textmate_oniguruma_version(void);

#ifdef __cplusplus
}
#endif

#endif

