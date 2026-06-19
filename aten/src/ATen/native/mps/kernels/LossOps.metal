#include <ATen/native/mps/kernels/LossOps.h>
#include <metal_stdlib>

using namespace metal;

// Augmented target lookup: l'[idx] is BLANK for even idx, l[idx/2] for odd.
template <typename target_t>
inline int get_target_prime(
    const device target_t* targets,
    long stride,
    long idx,
    int BLANK) {
  return (idx % 2 == 0) ? BLANK : (int)targets[stride * (idx / 2)];
}

template <typename T, typename target_t>
kernel void ctc_loss_log_alpha_kernel(
    device T* log_alpha [[buffer(0)]],
    const device T* log_probs [[buffer(1)]],
    const device long* input_lengths [[buffer(2)]],
    const device long* target_lengths [[buffer(3)]],
    const device target_t* targets [[buffer(4)]],
    const device long* tg_batch_offsets [[buffer(5)]],
    device T* neg_log_likelihood [[buffer(6)]],
    constant CTCLossParams& params [[buffer(7)]],
    uint tid [[thread_position_in_threadgroup]],
    uint tgid [[threadgroup_position_in_grid]],
    uint tptg [[threads_per_threadgroup]]) {
  constexpr T neginf = -numeric_limits<T>::infinity();

  long batch = (long)tgid;
  if (batch >= (long)params.batch_size)
    return;

  long input_length = input_lengths[batch];
  long target_length = target_lengths[batch];

  targets += tg_batch_offsets[batch];
  log_alpha += batch * params.log_alpha_batch_stride;
  log_probs += batch * params.log_probs_batch_stride;

  if (input_length == 0) {
    if (tid == 0)
      neg_log_likelihood[batch] = (target_length == 0) ? T(0) : T(INFINITY);
    return;
  }

  long S_max = 2 * params.max_target_length + 1;

  // Initialize first time step
  for (uint s = tid; s < S_max; s += tptg) {
    T la;
    switch (s) {
      case 0:
        la = log_probs[0];
        break;
      case 1:
        la = (target_length == 0)
            ? neginf
            : log_probs[params.log_probs_char_stride * targets[0]];
        break;
      default:
        la = neginf;
    }
    if (s < 2 * params.max_target_length + 1)
      log_alpha[params.log_alpha_target_stride * s] = la;
  }

  for (uint s = tid; s < S_max; s += tptg) {
    int current_char;
    bool have_three;

    if ((long)s < 2 * target_length + 1 && target_length > 0) {
      current_char = get_target_prime(
          targets, params.tg_target_stride, (long)s, params.BLANK);
      have_three = ((long)s > 1) &&
          (get_target_prime(
               targets, params.tg_target_stride, (long)s - 2, params.BLANK) !=
           current_char);
    } else {
      current_char = params.BLANK;
      have_three = false;
    }

    for (uint t = 1; t < params.max_input_length; t++) {
      threadgroup_barrier(mem_flags::mem_device);
      if ((long)t < input_length && (long)s < 2 * target_length + 1) {
        T la1 = log_alpha
            [params.log_alpha_time_stride * (t - 1) +
             params.log_alpha_target_stride * s];
        T lamax = la1;
        T la2 = ((long)s > 0) ? log_alpha
                                    [params.log_alpha_time_stride * (t - 1) +
                                     params.log_alpha_target_stride * (s - 1)]
                              : neginf;
        T la3 = have_three ? log_alpha
                                 [params.log_alpha_time_stride * (t - 1) +
                                  params.log_alpha_target_stride * (s - 2)]
                           : neginf;
        if (la2 > lamax)
          lamax = la2;
        if (la3 > lamax)
          lamax = la3;
        if (lamax == neginf)
          lamax = T(0);
        log_alpha
            [params.log_alpha_time_stride * t +
             params.log_alpha_target_stride * s] =
                precise::log(
                    precise::exp(la1 - lamax) + precise::exp(la2 - lamax) +
                    precise::exp(la3 - lamax)) +
            lamax +
            log_probs
                [(long)t * params.log_probs_time_stride +
                 params.log_probs_char_stride * current_char];
      } else if (s < 2 * params.max_target_length + 1) {
        log_alpha
            [params.log_alpha_time_stride * t +
             params.log_alpha_target_stride * s] = neginf;
      }
    }
  }

  threadgroup_barrier(mem_flags::mem_device);

  if (tid == 0) {
    T l1 = log_alpha
        [params.log_alpha_time_stride * (input_length - 1) +
         params.log_alpha_target_stride * (target_length * 2)];
    T l2 = (target_length > 0)
        ? log_alpha
              [params.log_alpha_time_stride * (input_length - 1) +
               params.log_alpha_target_stride * (target_length * 2 - 1)]
        : neginf;
    T m = (l1 > l2) ? l1 : l2;
    if (m == neginf)
      m = T(0);
    neg_log_likelihood[batch] =
        -(precise::log(precise::exp(l1 - m) + precise::exp(l2 - m)) + m);
  }
}

#define INSTANTIATE_CTC_ALPHA(DTYPE, TTYPE)                       \
  template [[host_name("ctc_loss_log_alpha_" #DTYPE "_" #TTYPE)]] \
  kernel void ctc_loss_log_alpha_kernel<DTYPE, TTYPE>(            \
      device DTYPE*,                                              \
      const device DTYPE*,                                        \
      const device long*,                                         \
      const device long*,                                         \
      const device TTYPE*,                                        \
      const device long*,                                         \
      device DTYPE*,                                              \
      constant CTCLossParams&,                                    \
      uint,                                                       \
      uint,                                                       \
      uint);

INSTANTIATE_CTC_ALPHA(float, int);
INSTANTIATE_CTC_ALPHA(float, long);
