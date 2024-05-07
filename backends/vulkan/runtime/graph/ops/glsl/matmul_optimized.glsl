/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#version 450 core

// To convince the SPIR-V compiler to unroll the loops optimally, need this
// macro
#define FOUR 4

#define PRECISION ${PRECISION}

#include "indexing_utils.h"

layout(set = 0, binding = 0, ${IMAGE_FORMAT[DTYPE]}) uniform PRECISION restrict writeonly image3D im_out;
layout(set = 0, binding = 1) uniform PRECISION ${SAMPLER_T[NDIM][DTYPE]} im_mat1;
layout(set = 0, binding = 2) uniform PRECISION ${SAMPLER_T[NDIM][DTYPE]} im_mat2;

layout(set = 0, binding = 3) uniform PRECISION restrict OutLimits {
  ivec3 out_limits;
};

layout(set = 0, binding = 4) uniform PRECISION restrict StepSize {
  int step_size;
};

layout(set = 0, binding = 5) uniform PRECISION restrict Reminder {
  int reminder;
};

layout(set = 0, binding = 6) uniform PRECISION restrict BatchSize {
  int batch_size;
};

layout(local_size_x_id = 0, local_size_y_id = 1, local_size_z_id = 2) in;

void main() {
  const ivec3 pos = ivec3(gl_GlobalInvocationID);

  if (any(greaterThanEqual(pos, out_limits))) {
    return;
  }

  // we avoid mat4 and vec4 usage here as they compile to much less efficient
  // SPIR-V
  float results[FOUR][FOUR][FOUR];
  for (int i = 0; i < FOUR; i++) {
    for (int j = 0; j < FOUR; j++) {
      for (int k = 0; k < FOUR; k++) {
        results[i][j][k] = 0.0f;
      }
    }
  }

  // read and cache 4x4 tile of im_mat1 (4 adjacent rows)
  vec4 im_mat1_partial_rows[FOUR];
  vec4 im_mat2_partial_cols[FOUR];

  for (int c = 0; c < FOUR; c++) {
    if (FOUR * pos.z + c >= batch_size) {
      break;
    }
    for (int j = 0; j < step_size; j++) {
      for (int k = 0; k < FOUR; k++) {
        const int pos_y_offset = (FOUR * pos.y) + k;
        const ivec3 pos_rd = ivec3(j, pos_y_offset, FOUR * pos.z + c);
        im_mat1_partial_rows[k] = texelFetch(im_mat1, pos_rd, 0);
        // set the value out of the boundary to be 0
        if (j == step_size - 1 && reminder > 0) {
          for (int kk = 0; kk < 4 - reminder; kk++) {
            im_mat1_partial_rows[k][3 - kk] = 0;
          }
        }
      }
      // read and cache 4x4 tile of im_mat2 (4 adjacent columns)
      for (int k = 0; k < FOUR; k++) {
        const int pos_x_offset = (FOUR * pos.x) + k;
        const ivec3 pos_rd = ivec3(pos_x_offset, j, FOUR * pos.z + c);
        im_mat2_partial_cols[k] = texelFetch(im_mat2, pos_rd, 0);
        // set the value out of the boundary to be 0
        if (j == step_size - 1 && reminder > 0) {
          for (int kk = 0; kk < 4 - reminder; kk++) {
            im_mat2_partial_cols[k][3 - kk] = 0;
          }
        }
      }
      // perform partial dot products and add partial result to results
      for (int idx_r = 0; idx_r < FOUR; idx_r++) {
        for (int idx_c = 0; idx_c < FOUR; idx_c++) {
          results[idx_r][idx_c][c] +=
              dot(im_mat1_partial_rows[idx_r], im_mat2_partial_cols[idx_c]);
        }
      }
    }
  }

  // results is in transposed order w.r.t. the desired output
  for (int idx_c = 0; idx_c < FOUR; idx_c++) {
    for (int idx_r = 0; idx_r < FOUR; idx_r++) {
      const ivec3 out_pos =
          ivec3(idx_r + FOUR * pos.x, idx_c + FOUR * pos.y, pos.z);
      imageStore(
          im_out,
          out_pos,
          vec4(
              results[idx_c][idx_r][0],
              results[idx_c][idx_r][1],
              results[idx_c][idx_r][2],
              results[idx_c][idx_r][3]));
    }
  }
}