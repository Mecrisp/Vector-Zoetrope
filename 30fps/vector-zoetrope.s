
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

.option norelax
.option rvc

.equ RamStart,  0x20000000  # Start of RAM
.equ RamEnd,    0x20008000  # End   of RAM, 32 kb.

.equ RING_MASK, 0x000001FF  # Ring buffer size: 512 Bytes

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

  li x8,  -1
  sw x8,  RCU_APB1EN(x14) # Enable DAC and everything else
  sw x8,  RCU_APB2EN(x14) # Enable power for something that is necessary for PLL and everything else

  li x15, 0x00010001      # Enable both DAC channels by setting DEN0 and DEN1
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
# memory_initialisation:
#
#    li sp, RamEnd       # Initialise stack pointer
#
#    li x31, 0x20000000  # Start of RAM
#    li x14, 0x20008000  # End of RAM
#
# 1: addi x14, x14, -4   # Traverse memory backwards
#    sw zero, 0(x14)     # to clear it
#    bne x14, x31, 1b
#
# -----------------------------------------------------------------------------

ring_buffer_initialisation:

  li x4, 0
  li x5, 0

# -----------------------------------------------------------------------------

irq_initialisation:

  # Initialise special registers for interrupt handling

  # Disable interrupts
  csrrci zero, mstatus, 8    # MSTATUS: Clear Machine Interrupt Enable Bit

  li x15, 3                  #        Set interrupt mode to ECLIC mode.
  csrrw zero, 0x305, x15     # MTVEC: Store address of exception handler (none) and ECLIC mode in CSR mtvec.

  # Non-vectored interrupt setting
  la x15, interrupt          #         Make sure address is 4-aligned.
  ori x15, x15, 1            #         Set LSB to 1: Indicates that this register (mtvt2)
  csrrw zero, 0x7EC, x15     # MTVT2:  contains the address of non-vectored interrupts.

timer_initialisation:

  li  x14, 0x7F020100  # Enabled, rising edge, level 127
  lui x15, 0xD2001     # VECTORCONFIG_BASE: Starting address of 87*4 ECLIC configuration registers
  sw  x14, 7*4(x15)    # Vector 7: Timer

  li  x14, 1
  lui x15, 0xD1001     # Timer mstop
  sw  x14, -8 (x15)

  lui x15, 0xD1000     # Clear mtime and mtimecmp
  sw  zero, 0x0 (x15)
  sw  zero, 0x4 (x15)
  sw  zero, 0x8 (x15)
  sw  zero, 0xC (x15)

  lui x15, 0xD1001     # Release Timer mstop
  sw  zero, -8 (x15)

  csrrsi zero, mstatus, 8 # Enable interrupts --> Interrupt will trigger immediately

# -----------------------------------------------------------------------------
# Time to start drawing!

  .macro unpackpixeldelta dac, x, y, oldx, oldy
    slli \x, \dac, 32-7
    srai \x, \x, 32-7
    add  \x, \x, \oldx
    slli \y, \dac, 32-7-8
    srai \y, \y, 32-7
    add  \y, \y, \oldy
  .endm

  .macro unpackpixel dac, x, y
    slli \x, \dac, 32-12
    srli \x, \x, 32-12
    slli \y, \dac, 32-12-16
    srli \y, \y, 32-12
  .endm

  .macro packpixel dac, x, y
    slli \dac, \y, 16
    or \dac, \dac, \x
  .endm

# -----------------------------------------------------------------------------
#  Notes on register usage:
#
#   x3: Constant DAC_BASE
#   x4: Ring buffer write index
#   x5: Ring buffer read  index
#
#   x7: Scratch
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
#
#  x24-x28: Scratch for interrupt handler
#  x29: Pixel counter for keeping the frame rate
#
# -----------------------------------------------------------------------------

/*
test: # Draw a diagonal line
  mv x10, x29
  mv x11, x29
  call insert_ring
  j test
*/

start_animation:
  la x20, data  # Pointer to current data source

nextframe:
  mv x21, x20   # Update start of frame pointer
  li x29, 0     # Clear pixel counter

nextelement:
  lw x9, 0(x20) # Fetch next element to display
  slli x15, x9, 16
  bge x15, zero, pixellinetodelta
  addi x20, x20, 4

  li x15, -2    # End of animation marker reached?
  beq x15, x9, start_animation

  li x15, -1    # End of frame marker
  bne x15, x9, nextpixel

# -----------------------------------------------------------------------------

doneframe:
  li x15, 50000            # Repeat until at least 50000 pixels have been drawn.
  bgeu x29, x15, nextframe # Using a pixel clock of 1.5 MHz, this sets the frame rate to 30 Hz.

repeatframe:
  mv x20, x21
  j nextelement

# -----------------------------------------------------------------------------

nextpixel:
  bge x9, zero, pixellineto # Comment this out to display dots only

pixelmoveto:
  unpackpixel x9, x10, x11   # Update current coordinates
  call insert_ring
  j nextelement

pixellineto:
  unpackpixel x9, x12, x13   # Update destination coordinates and draw line
  j bresenham

pixellinetodelta:
  addi x20, x20, 2
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

  call insert_ring # Moved here in order not to draw the first point, as this one
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
insert_ring: # Pixel coordinates in x10, x11
# -----------------------------------------------------------------------------

  packpixel x7, x10, x11

  addi x8, x4, 4
  andi x8, x8, RING_MASK

wait:
  beq x8, x5, wait     # Wait until the interrupt handler consumed enough data for this to continue

  li  x9, RamStart     # Pixel ring buffer at beginning of RAM
  add x9, x9, x4       # Add write index
  sw  x7, 0(x9)        # Set pixel data

  mv x4, x8            # Update write index for interrupt handler to see

  ret

# -----------------------------------------------------------------------------
.p2align 2 # Interrupt handler needs to be on a 4-even address
interrupt:
# -----------------------------------------------------------------------------

  addi x29, x29, 1           # Count elapsed pixel times for this frame
  beq x4, x5, nopixels       # Fresh pixels available in the ring buffer?

    li  x25, RamStart          # Pixel ring buffer at beginning of RAM
    add x25, x25, x5           # Add read index
    lw  x25, 0(x25)            # Get pixel data
    sw  x25, DACC_R12DH(x3)    # Set DACs

    addi x5, x5, 4
    andi x5, x5, RING_MASK

#   j pixeldone              # OK, data was available in time.
nopixels:                    # This is mostly for checking execution speed.
# sw  zero, DACC_R12DH(x3)   # Set DAC to lower left corner in empty frames.
pixeldone:                   # Looks good to keep the last drawn pixel instead!

  # Prepare next interrupt by adjusting 64 bit value mtimecmp

  lui x25, 0xD1000     # Fetch mtimecmp in x26:x24
  lw  x24, 0x8 (x25)
  lw  x26, 0xC (x25)

# li x28, 54           # How many cycles?  108 MHz / 4 / 54 -->  500 kHz pixel clock
# li x28, 27           # How many cycles?  108 MHz / 4 / 27 -->    1 MHz pixel clock
  li x28, 18           # How many cycles?  108 MHz / 4 / 18 -->  1.5 MHz pixel clock

  add  x24, x24, x28   # Add to 64 bit value, with carry
  sltu x27, x24, x28
  add  x26, x26, x27

  li  x27, -1          # See Volume II: RISC-V Privileged Architectures V1.10, 3.1.15: Machine Timer Registers
  sw  x27, 0x8(x25)    # Set low  part to maximum to avoid glitching
  sw  x26, 0xC(x25)    # Set high part
  sw  x24, 0x8(x25)    # Set low  part

  lui x25, 0xD2001     # VECTORCONFIG_BASE: Starting address of 87*4 ECLIC configuration registers
  sb  zero, 7*4(x25)   # Clear pending for vector 7: Timer

  mret

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
    .if (-64 <= (\x - currentx)) && ((\x - currentx) <= 63) && (-64 <= (\y - currenty)) && ((\y - currenty) <= 63)
      .byte 0x7F & (\x - currentx), 0x7F & (\y - currenty)
    .else
      .hword 0x8000 | \x, \y
    .endif

    .set currentx, \x
    .set currenty, \y
  .endm

  .macro end_of_frame
    .hword 0xFFFF, 0xFFFF
  .endm

  .macro end_of_animation
    .hword 0xFFFE, 0xFFFF
  .endm

data:
  .include "animation.s"
