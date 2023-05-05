#!/bin/bash
{
  for vectors in {4593..4799} # Choose frames here
  do
    cat PATHS/frame$vectors.vec
    printf "end_of_frame\n\n\n"
  done

  printf "end_of_animation\n\n\n"
} > animation.s
