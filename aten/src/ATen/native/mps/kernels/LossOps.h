#pragma once
#include <c10/metal/common.h>

struct CTCLossParams {
  uint max_input_length;
  uint max_target_length;
  uint batch_size;
  int BLANK;
  long tg_target_stride;
  long log_probs_time_stride;
  long log_probs_batch_stride;
  long log_probs_char_stride;
  long log_alpha_batch_stride;
  long log_alpha_time_stride;
  long log_alpha_target_stride;
};
