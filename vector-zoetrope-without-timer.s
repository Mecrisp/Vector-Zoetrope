
# -----------------------------------------------------------------------------
#
#    Vector Zoetrope - Animated vector graphics player for GD32VF103
#    Copyright (C) 2023  Matthias Koch
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# -----------------------------------------------------------------------------

.option norelax
.option rvc

.equ RamStart,  0x20000000  # Start of RAM
.equ RamEnd,    0x20008000  # End   of RAM, 32 kb.

.equ RING_MASK, 0x000001FF  # Ring buffer size: 512 Bytes

.equ framecycles, 108000000 / framerate # Pixels per frame to hold frame rate

# -----------------------------------------------------------------------------
#  Peripheral IO registers
# -----------------------------------------------------------------------------

  .equ RCU_BASE,     0x40021000
  .equ RCU_CTL,           0x000
  .equ RCU_CFG0,          0x004
  .equ RCU_APB2EN,        0x018
  .equ RCU_APB1EN,        0x01C

  .equ DAC_BASE,     0x40007000
  .equ DAC_CTL,           0x400
  .equ DACC_R12DH,        0x420

# -----------------------------------------------------------------------------
Reset:
# -----------------------------------------------------------------------------

  li x14, RCU_BASE
  li x3,  DAC_BASE

  li x15,  -1
  sw x15,  RCU_APB1EN(x14) # Enable DAC and everything else
  sw x15,  RCU_APB2EN(x14) # Enable power for something that is necessary for PLL and everything else

  li x15, 0x00010001       # Enable both DAC channels by setting DEN0 and DEN1
  sw x15, DAC_CTL(x3)

pll_initialisation:

  #  1 << 29  PLL factor high bit
  # 10 << 18  PLL factor: 8/2 MHz * 27 = 108 MHz = HCLK = PCLK2
  #  4 <<  8  PCLK1 = HCLK/2 = 54 MHz. Maximum is 54 MHz.
  #  3 << 14  ADCPRE = PCLK2/8 = 13.5 MHz. Maximum is 14 MHz.
  #  2 <<  0  PLL is the system clock

  li x15, 1 << 29 | 10 << 18 | 4 << 8 | 3 << 14 | 2  # Config for 108 MHz
  sw x15, RCU_CFG0(x14)

  li x15, (1<<24) >> 16  # Set PLLEN to enable freshly configured PLL
  sh x15, RCU_CTL+2(x14) # Halfword access because low part of register needs to be kept on reset values

# -----------------------------------------------------------------------------

constant_initialisation:

  la x23, end_of_data # For detecting end of animation
  li x29, framecycles # Cycles for drawing pixels per frame

# -----------------------------------------------------------------------------
# Time to start drawing!

  .macro unpackpixeldelta data, x, y, oldx, oldy
    slli \x, \data, 32-7
    srai \x, \x, 32-7
    add  \x, \x, \oldx
    slli \y, \data, 32-7-8
    srai \y, \y, 32-7
    add  \y, \y, \oldy
  .endm

  .macro unpackpixel lowpart, highpart, x, y
    slli \x, \lowpart, 32-12
    srli \x, \x, 32-12
    slli \y, \highpart, 32-12
    srli \y, \y, 32-12
  .endm

  .macro insert_ring  # Pixel coordinates in x10, x11
    slli x9, x11, 16     # Combine x and y in the format
    or   x9, x9, x10     # expected by the DAC register

    sw x9, DACC_R12DH(x3)    # Set DACs
  .endm

# -----------------------------------------------------------------------------
#  Notes on register usage:
#
#   x1: Unused
#   x2: Unused
#   x3: Constant: DAC_BASE
#   x4: Unused
#   x5: Unused
#   x6: Unused
#   x7: Unused
#
#   x8: Scratch
#   x9: Scratch
#
#  x10: Current x
#  x11: Current y
#  x12: Destination x
#  x13: Destination y
#  x14-x19: Scratch for Bresenham line algorithm
#
#  x20: Frame data pointer
#  x21: Start of current frame pointer
#  x22: Cycles to reach before displaying next frame
#  x23: Constant: End of animation data
#
#  x24: Unused
#  x25: Unused
#  x26: Unused
#  x27: Unused
#  x28: Unused
#  x29: Constant: Cycles for drawing pixels per frame
#  x30: Unused
#  x31: Unused
#
# -----------------------------------------------------------------------------

  rdcycle x22  # Get current time

start_animation:
  li x20, 512  # Pointer to current data source

nextframe:
  beq x20, x23, start_animation # Reached end of animation data?
  mv x21, x20                   # Update start of frame pointer
  add x22, x22, x29             # Set cycles to spend drawing per frame

nextelement:
  lh x9, 0(x20) # Fetch next element to display, 16 bit format
  bge x9, zero, shortencoding

  lh x8, 2(x20) # Fetch next element to display, high part of 32 bit format
  addi x20, x20, 4

# -----------------------------------------------------------------------------

nextpixel:
  bge x8, zero, pixellineto

pixelmoveto:
  unpackpixel x9, x8, x10, x11   # Update current coordinates
  insert_ring
  j nextelement

pixellineto:
  unpackpixel x9, x8, x12, x13   # Update destination coordinates and draw line
  j bresenham

# -----------------------------------------------------------------------------

shortencoding:
  addi x20, x20, 2
  bnez x9, pixellinetodelta # Check for end-of-frame marker 0

doneframe:                  # Repeat until enough pixels have been drawn.
  rdcycle x28               # Get current time
  sub x28, x28, x22         # Elapsed time, handles overflow gracefully
  bge x28, zero, nextframe  # Using a known clock frequency, this sets the frame rate.

repeatframe:
  mv x20, x21
  j nextelement

pixellinetodelta:
  unpackpixeldelta x9, x12, x13, x10, x11

# -----------------------------------------------------------------------------
bresenham: # ( x10, x11 ) --> ( x12, x13 ) Inlined here for speed
# -----------------------------------------------------------------------------
  sub x14, x12, x10
  bge x14, zero, 1f
    sub x14, zero, x14
1:
  sub x15, x13, x11
  blt x15, zero, 1f
    sub x15, zero, x15
1:

  slt x16, x10, x12
  add x16, x16, x16
  addi x16, x16, -1

  slt x17, x11, x13
  add x17, x17, x17
  addi x17, x17, -1

  add x18, x14, x15

bresenham_loop:

  # Usually, pixel is drawn here

  bne x10, x12, 1f
  beq x11, x13, nextelement
1:
  add x19, x18, x18
  bge x15, x19, 1f
    add x18, x18, x15
    add x10, x10, x16
1:
  bge x19, x14, 1f
    add x18, x18, x14
    add x11, x11, x17
1:

  insert_ring # Moved here in order not to draw the first point, as this one
  j bresenham_loop # is already drawn by "moveto" or the end of the line before.

# -----------------------------------------------------------------------------

/*

void line(int x0, int y0, int x1, int y1)
{
    int dx =  abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    int dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
    int err = dx + dy, e2; // error value e_xy

    while (1) {
        setPixel(x0, y0);
        if (x0 == x1 && y0 == y1) break;
        e2 = 2 * err;
        if (e2 > dy) { err += dy; x0 += sx; } // e_xy+e_x > 0
        if (e2 < dx) { err += dx; y0 += sy; } // e_xy+e_y < 0
    }
}

*/

# -----------------------------------------------------------------------------
# signature: .byte 'M', 'e', 'c', 'r', 'i', 's', 'p', '.'
# -----------------------------------------------------------------------------

.p2align 9   # Align on 512 byte boundary

  .set currentx, 0
  .set currenty, 0

  .macro moveto x y
    .hword 0x8000 | \x, 0x8000 | \y
  .endm

  .macro lineto x y

    .if ((\x - currentx) != 0) || ((\y - currenty) != 0) # Do not encode a line if there is no movement
    .if (-64 <= (\x - currentx)) && ((\x - currentx) <= 63) && (-64 <= (\y - currenty)) && ((\y - currenty) <= 63)
      .byte 0x7F & (\x - currentx), 0x7F & (\y - currenty)
    .else
      .hword 0x8000 | \x, \y
    .endif
    .endif

    .set currentx, \x
    .set currenty, \y
  .endm

  .macro end_of_frame
    .hword 0x0000
  .endm

  .macro end_of_animation
    # No marker necessary anymore
  .endm

begin_of_data:
  .include "animation.s"
end_of_data:
