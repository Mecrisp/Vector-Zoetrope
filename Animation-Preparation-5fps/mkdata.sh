#!/bin/sh

{
  for vectors in PATHS/*.vec
  do
    cat $vectors
    echo "end_of_frame\n\n"
  done

  echo "end_of_animation\n\n"
} > animation.s
