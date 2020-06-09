.syntax unified
.global main, EXTI0_IRQHandler, EXTI3_IRQHandler, sender_status, sender_song
.include "libcomp2300/macros.S"


@ data from PE13 (sender) to PH1 (receiver)
@ control from PE14 (sender) to PD0 (receiver)
@ clock from PE15 (sender) to PB3 (receiver)

@ --receiver--
.type main, %function
main:
  nop

  @ audio setup
  bl init
  bl BSP_AUDIO_Buffer

  @ enable SYSCFG clock
  RCC_APB2ENR_set 0

  @ turn on GPIO clocks
  GPIOx_clock_enable B
  GPIOx_clock_enable D
  GPIOx_clock_enable E
  GPIOx_clock_enable H

  @ GPIO setup
  GPIO_configure_output_pin E, 13   @ data sender: PE13
  GPIO_configure_input_pin H, 1     @ data receiver: PH1
  GPIO_configure_output_pin E, 14   @ control sender: PE14
  GPIO_configure_input_pin_it D, 0  @ control receiver: PD0
  EXTI_set_rising_edge_trigger 0
  EXTI_set_falling_edge_trigger 0
  NVIC_set ISER 6
  GPIO_configure_output_pin E, 15   @ clock sender: PE15
  GPIO_configure_input_pin_it B, 3  @ clock receiver: PB3
  EXTI_set_rising_edge_trigger 3
  NVIC_set ISER 9

  @ initial values
  GPIOx_ODR_clear E, 13
  GPIOx_ODR_clear E, 14
  GPIOx_ODR_set E, 15

  @ timer set to 1/32 between interrupts
  mov r0, #10000
  mov r1, #250
  bl tim7_init

  mov r4, 0 @ last value of sample in r4
  ldr r5, =receiver_current @ memory address of receiver status in r5
 
  b loop
.size main, .-main

loop:
  nop

  @ get note mode
  ldrb r1, [r5]

  cmp r1, 0 @ delay if mode is 0, play note otherwise
  beq loop_delay
  bl play_note @ on
  mov r4, r0
  b loop
loop_delay: @ off
  @ prev value is in r0 returned by play_note
  mov r0, r4
  bl delay
  b loop

@ control change detected
.type EXTI0_IRQHandler, %function
EXTI0_IRQHandler:
  push {r4-r11, lr}

  @ update current note with received bits from next note once completed
  ldr r4, =receiver_next
  ldr r5, =receiver_current
  ldr r6, =receiver_status
  ldrb r7, [r4]
  ldr r8, [r4, 1]
  mov r9, 0
  GPIOx_IDR_read D, 0
  ITTT EQ
  strbeq r7, [r5]
  streq r8, [r5, 1]
  strbeq r9, [r6] @ reset status bit index to zero

  @ change control bit to indicate reading/finished
  ldrb r1, [r6]
  lsl r2, r0, 7
  orr r1, r2
  strb r1, [r6]

  EXTI_PR_clear_pending 0
  pop {r4-r11, lr}
  bx lr
.size EXTI0_IRQHandler, .-EXTI0_IRQHandler

@ clock rising edge detected
.type EXTI3_IRQHandler, %function
EXTI3_IRQHandler:
  push {r4-r11, lr}

  ldr r4, =receiver_status
  ldr r5, =receiver_next
  ldrb r1, [r4] @ status
  lsr r2, r1, 7 @ most significant bit is used for control
  cmp r2, 0
  beq handler_3_cleanup @ do not read if control is 0
  bic r7, r1, 0b10000000 @ current bit index

  cmp r7, 8
  blt read_mode
read_note:
  ldr r6, [r5, 1] @ next mode
  @ clear (data = 0) or set (data = 1) bit in receiver next note
  mov r8, 1
  sub r0, r7, 8
  lsl r8, r0
  GPIOx_IDR_read H, 1 @ read data line
  ITE EQ
  biceq r6, r8 @ clear at index
  orrne r6, r8 @ set at index
  str r6, [r5, 1]
  b incr_index
read_mode:
  ldrb r6, [r5] @ next note
  @ clear (data = 0) or set (data = 1) bit in receiver next note
  mov r8, 1
  lsl r8, r7
  GPIOx_IDR_read H, 1 @ read data line
  ITE EQ
  biceq r6, r8 @ clear at index
  orrne r6, r8 @ set at index
  strb r6, [r5]
incr_index:
  add r7, 1 @ increment bit index
  orr r7, 0b10000000
  strb r7, [r4] @ update bit index
handler_3_cleanup:
  EXTI_PR_clear_pending 3
  pop {r4-r11, lr}
  bx lr
.size EXTI3_IRQHandler, .-EXTI3_IRQHandler

@ play a note depending on the waveform
play_note:
  mov r3, r5 @ copy address
  push {r4-r11, lr}
  mov r4, r1 @ note waveform
  ldrh r1, [r3, 1] @ frequency
  ldrh r2, [r3, 3] @ loudness/amplitude

  @ waveform 1 - sawtooth
  cmp r4, 1
  IT EQ
  bleq play_note_sawtooth
  cmp r4, 1
  beq note_cleanup

  @ waveform 2 - sine
  cmp r4, 2
  IT EQ
  bleq play_note_sine
  cmp r4, 2
  beq note_cleanup

  @ default waveform - triangle
  bl play_note_triangle
note_cleanup:
  pop {r4-r11, lr}
  bx lr


@ sawtooth wave 
@ derived from assignment 2 code (see statement of originality)
@ input r1: frequency
@ input r2: loudness/amplitude
.type play_note_sawtooth, %function
play_note_sawtooth:
  @ setup
  push {r4-r11, lr}

  @ customize the wave with r5 and r6.
  @ use a frequency of 440Hz (note A),
  @ and amplitude/2 of 0x7fff for full dynamic range (max volume).
  @ customize the duration with r10, 1000 = 1 second

  @ r5 stores the frequency (Hz)
  mov r5, r1

  @ r6 stores amplitude/2 (volume) or the max bound
  mov r6, r2
  @ r7 stores the min bound
  rsb r7, r6, #0
  sub r7, #1 @ account for 0

  @ r8 stores difference between each sample point 
  mov r0, #48000 @ output sample rate of board (48kHz)
  udiv r0, r5 @ samples per period
  add r1, r6, #1 @ account for 0
  lsl r1, #1 @ amplitude
  udiv r8, r1, r0 @ defined by amplitude and frequency
  mov r0, #0
  mov r1, #0
  
  @ use r4 for current sample, moved to r0 before samples are played
  mov r4, r7

@ first half of period, r6 (upper) to r7 (lower)
loop_sample_sawtooth:
  adds r4, r8
  bmi skip_sawtooth @ only make check when above 0
  cmp r4, r6
  bge sawtooth_cleanup @ check duration if upper bound is reached (full cycle complete)
skip_sawtooth:
  mov r0, r4
  bl BSP_AUDIO_OUT_Play_Sample
  b loop_sample_sawtooth

@ cycle complete
sawtooth_cleanup:
  sub r0, r4, r8 @ return the last sample played in r0
  pop {r4-r11, lr}
  bx lr 
.size play_note_sawtooth, .-play_note_sawtooth


@ triangle wave
@ derived from assignment 2 code (see statement of originality)
@ input r1: frequency
@ input r2: loudness/amplitude
.type play_note_triangle, %function
play_note_triangle:
  @ setup
  push {r4-r11, lr}

  @ triangle wave.
  @ customize the wave with r5 and r6.
  @ use a frequency of 440Hz (note A),
  @ and amplitude/2 of 0x7fff for full dynamic range (max volume).
  @ customize the duration with r10, 1000 = 1 second.
  @ amplitude will shift from initial to final amplitude

  @ r5 stores the frequency (Hz)
  mov r5, r1

  @ r6 stores current amplitude/2 (volume) or the max bound
  mov r6, r2

  @ r7 stores the min bound
  rsb r7, r6, #0
  sub r7, #1 @ account for 0

  @ r8 stores difference between each sample point 
  mov r0, #48000 @ output sample rate of board (48kHz)
  udiv r0, r5 @ samples per period
  lsr r0, #1 @ samples per half period
  add r1, r6, #1 @ account for 0
  lsl r1, #1 @ amplitude
  udiv r8, r1, r0 @ defined by amplitude and frequency

  mov r0, #0
  mov r1, #0

  @ r4 stores current sample

@ first half of period, r6 (upper) to r7 (lower)
triangle_decend_start:
  nop
  mov r4, r6
triangle_decend_loop:
  subs r4, r8
  bpl triangle_decend_skip @ only make check when below 0
  cmp r4, r7 
  ble triangle_ascend_start @ start ascending if lower bound is reached
triangle_decend_skip:
  mov r0, r4
  bl BSP_AUDIO_OUT_Play_Sample
  b triangle_decend_loop

@ second half of period, r7 (lower) to r6 (upper)
triangle_ascend_start:
  nop
  mov r4, r7
triangle_ascend_loop:
  adds r4, r8
  bmi triangle_ascend_skip @ only make check when above 0
  cmp r4, r6
  bge triangle_cleanup @ (full cycle complete)
triangle_ascend_skip:
  mov r0, r4
  bl BSP_AUDIO_OUT_Play_Sample
  b triangle_ascend_loop

triangle_cleanup:
  sub r0, r4, r8 @ return the last sample played in r0
  pop {r4-r11, lr}
  bx lr
.size play_note_triangle, .-play_note_triangle


@ sine wave
@ derived from assignment 2 code (see statement of originality)
@ input r1: frequency
@ input r2: loudness/amplitude
.type play_note_sine, %function
play_note_sine:
  @ setup
  push {r4-r11, lr}

  @ approximation of sine wave via Bhaskara I's sine approximation formula

  @ customize the wave with r5 and r6.
  @ use a base frequency of 440Hz (note A),
  @ and amplitude/2 of 0x7fff for full dynamic range (max volume).
  @ amplitude will shift from initial to final amplitude

  @ r5 stores the frequency (Hz)
  mov r5, r1

  @ r6 stores current amplitude/2 (volume) or the max bound
  mov r6, r2

  @ r7 stores samples per half period
  mov r7, #48000 @ output sample rate of board (48kHz)
  udiv r7, r5 @ samples per period
  lsr r7, #1

  @ r8 stores factor to convert to degrees
  @ shifted twice for precision
  mov r8, #180
  lsl r8, #2
  lsl r0, r7, #2
  udiv r8, r7
  mov r0, #0

  @ use r4 to measure time (x axis), increments every sample

@ first half of period, positive values peaking at r6
sine_upper_start:  
  nop
  mov r4, #0
sine_upper_loop:
  add r4, #1 @ increase time value
  bl sine_calculate_sample
  cmp r7, r4
  blt sine_lower_start @ start second half of period
  bl BSP_AUDIO_OUT_Play_Sample
  b sine_upper_loop

@ second half of period, negative values, trough at -r6
sine_lower_start:
  nop
  mov r4, #0
sine_lower_loop:
  add r4, #1 @ increase time value
  bl sine_calculate_sample
  rsb r0, #0
  cmp r7, r4
  blt sine_cleanup @ (full cycle complete)
  bl BSP_AUDIO_OUT_Play_Sample
  b sine_lower_loop

@ calculates sample value (y axis) based on time (x axis, r4) and amplitude/2 (r6).
@ puts result in r0, ready for sample.
@ uses Bhaskara I's sine approximation formula,
@ (4x(180-x))/(40500-x(180-x)) in addition to scaling for amplitude
sine_calculate_sample:
  mul r1, r4, r8 @ convert to degrees (x in r1)
  lsr r1, #2
  mov r2, #180
  sub r2, r1
  mul r2, r1 @ x(180-x)
  mov r3, #4
  mul r0, r2, r3 @ 4x(180-x)
  mov r3, #40500
  sub r2, r3, r2 @ 40500-x(180-x)
  mul r0, r6 @ scale for amplitude
  udiv r0, r0, r2 @ result
  mov r1, #0
  mov r2, #0
  mov r3, #0
  bx lr

sine_cleanup:
  mov r0, r4 @ return the last sample played in r0
  pop {r4-r11, lr}
  bx lr 
.size play_note_sine, .-play_note_sine


@ delay
@ input r0: value of last sample played (delay always follows a note), returned in r0 by play_note
delay:
  push {r4-r11, lr}
  bl BSP_AUDIO_OUT_Play_Sample
  pop {r4-r11, lr}
  bx lr


.data
.align 2 @ align memory addresses to a word boundry (leave here)
@ \/ memory entries go below \/

@ stores the current status of the reader
receiver_status:
  @ most significant bit indicates whether the control line is active or not, 
  @ (1 = reading, 0 = finished).
  @ other bits are used for the current bit index for reading data
  .byte 0 

@ stores data required to play the current note/delay (see format in sender_song)
receiver_current:
  .byte 0
  .hword 0, 0 
@ stores data required to play the next note/delay (see format in sender_song)
@ is read bit by bit from the sender data line, 
@ then replaces receiver_current after sending is complete
receiver_next:
  .byte 0
  .hword 0, 0

@ --sender--
@ all sender functionality is using the timer in tim7.S and this data

@ stores the current status of the sender
sender_status:
  .hword 2 @ current offset for sender_song

@ used by the sender to determine what signals to send.
@ stored in the same format as a receiver_status.
@ first byte indicates song length
sender_song:
  .hword 417 @ song length in bytes + 1

  @ format:
  @ first byte indicates waveform/delay: 0 = delay, 1 = sawtooth, 2 = sine, 3 = triangle
  @ next half word indicates frequency
  @ final half word indicates loudness/amplitude (max: 0x7fff)
  @ NOTE: delays are only 1 byte

  @ sine, 294Hz, rise/fall envelope, 0.25s (40 bytes)
  .byte 2
  .hword 294, 0x1fff
  .byte 2
  .hword 294, 0x3fff
  .byte 2
  .hword 294, 0x7fff
  .byte 1 @ sawtooth instrument for texture
  .hword 294, 0x5fff
  .byte 1 @ sawtooth instrument for texture
  .hword 294, 0x4fff
  .byte 2
  .hword 294, 0x3fff
  .byte 2
  .hword 294, 0x2fff
  .byte 2
  .hword 294, 0x1fff

  @ delay 0.25
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0

  @ sine, 349Hz, rise/fall envelope, 0.25s (40 bytes)
  .byte 2
  .hword 349, 0x1fff
  .byte 2
  .hword 349, 0x3fff
  .byte 2
  .hword 349, 0x7fff
  .byte 1 @ sawtooth instrument for texture
  .hword 349, 0x5fff
  .byte 1 @ sawtooth instrument for texture
  .hword 349, 0x4fff
  .byte 2
  .hword 349, 0x3fff
  .byte 2
  .hword 349, 0x2fff
  .byte 2
  .hword 349, 0x1fff

  @ delay 0.25
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0

  @ sine, 392Hz, rise/fall envelope, 0.5s (80 bytes)
  .byte 2
  .hword 392, 0x1fff
  .byte 2
  .hword 392, 0x2fff
  .byte 2
  .hword 392, 0x3fff
  .byte 2
  .hword 392, 0x4fff
  .byte 2
  .hword 392, 0x7fff
  .byte 2
  .hword 392, 0x7fff
  .byte 1 @ sawtooth instrument for texture
  .hword 392, 0x5fff
  .byte 1 @ sawtooth instrument for texture
  .hword 392, 0x4fff
  .byte 1 @ sawtooth instrument for texture
  .hword 392, 0x37ff
  .byte 1 @ sawtooth instrument for texture
  .hword 392, 0x3fff
  .byte 2
  .hword 392, 0x27ff
  .byte 2
  .hword 392, 0x2fff
  .byte 2
  .hword 392, 0x17ff
  .byte 2
  .hword 392, 0x1fff
  .byte 2
  .hword 392, 0x07ff
  .byte 2
  .hword 392, 0x07ff

  @ delay 0.25
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0

  @ sine, 294Hz, rise/fall envelope, 0.25s (40 bytes)
  .byte 2
  .hword 294, 0x1fff
  .byte 2
  .hword 294, 0x3fff
  .byte 2
  .hword 294, 0x7fff
  .byte 1 @ sawtooth instrument for texture
  .hword 294, 0x5fff
  .byte 1 @ sawtooth instrument for texture
  .hword 294, 0x4fff
  .byte 2
  .hword 294, 0x3fff
  .byte 2
  .hword 294, 0x2fff
  .byte 2
  .hword 294, 0x1fff

  @ delay 0.25
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0

  @ sine, 349Hz, rise/fall envelope, 0.25s (40 bytes)
  .byte 2
  .hword 349, 0x1fff
  .byte 2
  .hword 349, 0x3fff
  .byte 2
  .hword 349, 0x7fff
  .byte 1 @ sawtooth instrument for texture
  .hword 349, 0x5fff
  .byte 1 @ sawtooth instrument for texture
  .hword 349, 0x4fff
  .byte 2
  .hword 349, 0x3fff
  .byte 2
  .hword 349, 0x2fff
  .byte 2
  .hword 349, 0x1fff

  @ delay 0.25
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0

  @ sine, 415Hz, rise/fall envelope, 0.25s (40 bytes)
  .byte 2
  .hword 415, 0x1fff
  .byte 2
  .hword 415, 0x3fff
  .byte 2
  .hword 415, 0x7fff
  .byte 1 @ sawtooth instrument for texture
  .hword 415, 0x5fff
  .byte 1 @ sawtooth instrument for texture
  .hword 415, 0x4fff
  .byte 2
  .hword 415, 0x3fff
  .byte 2
  .hword 415, 0x2fff
  .byte 2
  .hword 415, 0x1fff

  @ sine, 392Hz, rise/fall envelope, 0.5s (80 bytes)
  .byte 2
  .hword 392, 0x1fff
  .byte 2
  .hword 392, 0x2fff
  .byte 2
  .hword 392, 0x3fff
  .byte 2
  .hword 392, 0x4fff
  .byte 2
  .hword 392, 0x7fff
  .byte 2
  .hword 392, 0x7fff
  .byte 1 @ sawtooth instrument for texture
  .hword 392, 0x5fff
  .byte 1 @ sawtooth instrument for texture
  .hword 392, 0x4fff
  .byte 1 @ sawtooth instrument for texture
  .hword 392, 0x37ff
  .byte 1 @ sawtooth instrument for texture
  .hword 392, 0x3fff
  .byte 2
  .hword 392, 0x27ff
  .byte 2
  .hword 392, 0x2fff
  .byte 2
  .hword 392, 0x17ff
  .byte 2
  .hword 392, 0x1fff
  .byte 2
  .hword 392, 0x07ff
  .byte 2
  .hword 392, 0x07ff

  @ delay 0.5
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0
  .byte 0