.syntax unified
.global main, EXTI0_IRQHandler, EXTI3_IRQHandler, sender_status, sender_song
.include "libcomp2300/macros.S"


@ note on/off from PE14 (sender) to PD0 (receiver)
@ pitch change from PE15 (sender) to PB3 (receiver)

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

  @ GPIO setup
  GPIO_configure_output_pin E, 14   @ note on/off sender: PE14
  GPIO_configure_input_pin_it D, 0  @ note on/off receiver: PD0
  EXTI_set_rising_edge_trigger 0
  EXTI_set_falling_edge_trigger 0
  NVIC_set ISER 6
  GPIO_configure_output_pin E, 15   @ pitch change sender: PE15
  GPIO_configure_input_pin_it B, 3  @ pitch change receiver: PB3
  EXTI_set_rising_edge_trigger 3
  NVIC_set ISER 9

  @ should be at 0 initially
  GPIOx_ODR_clear E, 14
  GPIOx_ODR_clear E, 15

  @ timer set to 0.25 between interrupts
  mov r0, #10000
  mov r1, #2000
  bl tim7_init

  mov r4, 0 @ last value of sample in r4
  ldr r5, =receiver_status @ memory address of receiver status in r5
  ldr r6, =receiver_pitch_sequence @ memory address of pitch sequence in r6
 
  b loop
.size main, .-main

loop:
  nop

  @ get next receiver_status
  ldrb r2, [r5]
  bic r1, r2, 0b10000000 @ pitch index
  lsl r1, 1
  ldrh r1, [r6, r1] @ frequency from pitch sequence
  lsr r2, 7 @ on/off in most significant bit

  cmp r2, 0 @ check on/off
  beq loop_delay
  bl play_note_sawtooth @ on
  mov r4, r0
  b loop
loop_delay: @ off
  @ prev value is in r0 returned by play_note
  mov r0, r4
  bl delay
  b loop

@ note on/off change detected
.type EXTI0_IRQHandler, %function
EXTI0_IRQHandler:
  push {r4-r11, lr}

  GPIOx_IDR_read D, 0
  @ move on/off received to most significant bit in receiver_status
  lsl r0, 7 @ most significant bit
  ldr r1, =receiver_status
  ldrb r2, [r1]
  bic r2, 0b10000000
  orr r0, r2
  strb r0, [r1]
  
  EXTI_PR_clear_pending 0
  pop {r4-r11, lr}
  bx lr
.size EXTI0_IRQHandler, .-EXTI0_IRQHandler

@ pitch change detected
.type EXTI3_IRQHandler, %function
EXTI3_IRQHandler:
  push {r4-r11, lr}

  @ change pitch in receiver_status
  ldr r1, =receiver_status
  ldrb r2, [r1]
  bic r0, r2, 0b10000000 @ most significant bit is used for on/off
  bic r2, 0b01111111
  cmp r0, 7 @ check if max index has been reached
  ITE GE
  movge r0, 0 @ return back to index 0
  addlt r0, 1 @ increment index
  orr r0, r2
  strb r0, [r1]
  
  EXTI_PR_clear_pending 3
  pop {r4-r11, lr}
  bx lr
.size EXTI3_IRQHandler, .-EXTI3_IRQHandler


@ sawtooth wave 
@ derived from assignment 2 code (see statement of originality)
@ input r1: frequency
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
  mov r6, 0x7fff
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


@ input r0: value of last sample played (delay always follows a note), returned in r0 by play_note
delay:
  push {r4-r11, lr}
  bl BSP_AUDIO_OUT_Play_Sample
  pop {r4-r11, lr}
  bx lr


.data
.align 2 @ align memory addresses to a word boundry (leave here)
@ \/ memory entries go below \/

@ current status of the sound being played by the receiver.
@ most significant bit indicates on (1) or off (0),
@ other bits indicate pitch index
receiver_status:
  .byte 0b00000000

@ set of frequencies in 2 bytes, index reference
receiver_pitch_sequence:
  .hword 220 @ 0
  .hword 247 @ 1
  .hword 262 @ 2
  .hword 294 @ 3
  .hword 330 @ 4
  .hword 370 @ 5
  .hword 392 @ 6
  .hword 440 @ 7

@ --sender--
@ all sender functionality is using the timer in tim7.S and this data

@ stores the current status of the sender
sender_status:
  .byte 1 @ current offset for sender_song
  .byte 0 @ current pitch index

@ used by the sender to determine what signals to send.
@ stored in the same format as a receiver_status.
@ first byte indicates song length
sender_song:
  .byte 38 @ song length
  .byte 0b10000000 @ on, 0
  .byte 0          @ off
  .byte 0b10000010 @ on, 2
  .byte 0          @ off
  .byte 0b10000001 @ on, 1
  .byte 0          @ off
  .byte 0b10000011 @ on, 3
  .byte 0          @ off
  .byte 0b10000010 @ on, 2
  .byte 0          @ off
  .byte 0b10000100 @ on, 4
  .byte 0          @ off
  .byte 0b10000011 @ on, 3
  .byte 0          @ off
  .byte 0b10000101 @ on, 5
  .byte 0          @ off
  .byte 0b10000100 @ on, 4
  .byte 0          @ off
  .byte 0b10000110 @ on, 6
  .byte 0          @ off
  .byte 0b10000101 @ on, 5
  .byte 0          @ off
  .byte 0b10000111 @ on, 7
  .byte 0          @ off
  .byte 0b10000110 @ on, 6
  .byte 0          @ off
  .byte 0b10000101 @ on, 5
  .byte 0          @ off
  .byte 0b10000100 @ on, 4
  .byte 0          @ off
  .byte 0b10000011 @ on, 3
  .byte 0          @ off
  .byte 0b10000010 @ on, 2
  .byte 0          @ off
  .byte 0b10000001 @ on, 1
  .byte 0          @ off
  .byte 0b10000000 @ on, 0
  .byte 0          @ off