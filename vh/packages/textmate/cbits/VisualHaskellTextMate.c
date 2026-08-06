#include "VisualHaskellTextMate.h"

#include <limits.h>
#include <stdio.h>
#include <string.h>

#include "oniguruma.h"

static void visual_haskell_textmate_copy_error(
    int code,
    const OnigErrorInfo *info,
    char *destination,
    size_t capacity) {
  if (destination == NULL || capacity == 0) {
    return;
  }
  OnigUChar buffer[ONIG_MAX_ERROR_MESSAGE_LEN];
  if (info == NULL) {
    onig_error_code_to_str(buffer, code);
  } else {
    onig_error_code_to_str(buffer, code, info);
  }
  snprintf(destination, capacity, "%s", (const char *)buffer);
}

int32_t visual_haskell_textmate_compile(
    const uint8_t *pattern,
    size_t pattern_length,
    VisualHaskellTextMateRegexRef *result,
    int32_t *capture_count,
    char *error_message,
    size_t error_capacity) {
  if (pattern == NULL || result == NULL || capture_count == NULL ||
      pattern_length > (size_t)INT_MAX) {
    return ONIGERR_INVALID_ARGUMENT;
  }

  OnigEncoding encodings[] = {ONIG_ENCODING_UTF8};
  int code = onig_initialize(encodings, 1);
  if (code != ONIG_NORMAL) {
    visual_haskell_textmate_copy_error(
        code, NULL, error_message, error_capacity);
    return code;
  }

  OnigRegex compiled = NULL;
  OnigErrorInfo info;
  code = onig_new(
      &compiled,
      pattern,
      pattern + pattern_length,
      ONIG_OPTION_CAPTURE_GROUP,
      ONIG_ENCODING_UTF8,
      ONIG_SYNTAX_ONIGURUMA,
      &info);
  if (code != ONIG_NORMAL) {
    visual_haskell_textmate_copy_error(
        code, &info, error_message, error_capacity);
    return code;
  }

  *result = (VisualHaskellTextMateRegexRef)compiled;
  *capture_count = (int32_t)onig_number_of_captures(compiled);
  return ONIG_NORMAL;
}

void visual_haskell_textmate_regex_free(VisualHaskellTextMateRegexRef regex) {
  if (regex != NULL) {
    onig_free((OnigRegex)regex);
  }
}

int32_t visual_haskell_textmate_search(
    VisualHaskellTextMateRegexRef regex,
    const uint8_t *subject,
    size_t subject_length,
    size_t start_offset,
    int32_t *capture_pairs,
    size_t capture_pair_capacity,
    int32_t *capture_count,
    char *error_message,
    size_t error_capacity) {
  if (regex == NULL || subject == NULL || capture_pairs == NULL ||
      capture_count == NULL || start_offset > subject_length ||
      subject_length > (size_t)INT_MAX) {
    return ONIGERR_INVALID_ARGUMENT;
  }

  OnigRegion *region = onig_region_new();
  if (region == NULL) {
    return ONIGERR_MEMORY;
  }

  int code = onig_search(
      (OnigRegex)regex,
      subject,
      subject + subject_length,
      subject + start_offset,
      subject + subject_length,
      region,
      ONIG_OPTION_NONE);
  if (code >= 0) {
    size_t required = (size_t)region->num_regs * 2;
    if (required > capture_pair_capacity) {
      onig_region_free(region, 1);
      return ONIGERR_INVALID_ARGUMENT;
    }
    for (int index = 0; index < region->num_regs; index += 1) {
      capture_pairs[index * 2] = (int32_t)region->beg[index];
      capture_pairs[index * 2 + 1] = (int32_t)region->end[index];
    }
    *capture_count = (int32_t)region->num_regs;
    onig_region_free(region, 1);
    return 1;
  }

  onig_region_free(region, 1);
  if (code == ONIG_MISMATCH) {
    *capture_count = 0;
    return 0;
  }
  visual_haskell_textmate_copy_error(code, NULL, error_message, error_capacity);
  return code;
}

const char *visual_haskell_textmate_oniguruma_version(void) {
  return onig_version();
}
