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

  @ timer set to 0.25 between interrupts
  mov r0, #10000
  mov r1, #2000
  bl tim7_init

  mov r4, 0 @ last value of sample in r4
  ldr r5, =receiver_current @ memory address of receiver status in r5
 
  b loop
.size main, .-main

loop:
  nop

  @ get receiver current frequency
  ldrh r1, [r5]

  cmp r1, 0 @ check on/off
  beq loop_delay
  bl play_note_sawtooth @ on
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
  ldrh r7, [r4]
  mov r8, 0
  GPIOx_IDR_read D, 0
  ITT EQ
  strheq r7, [r5]
  strbeq r8, [r6] @ reset status bit index to zero

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
  ldrh r6, [r5] @ next note
  ldrb r1, [r4] @ status
  lsr r2, r1, 7 @ most significant bit is used for control
  cmp r2, 0
  beq handler_3_cleanup @ do not read if control is 0
  bic r7, r1, 0b10000000 @ current bit index

  @ clear (data = 0) or set (data = 1) bit in receiver next note
  mov r8, 1
  lsl r8, r7
  GPIOx_IDR_read H, 1 @ read data line
  ITE EQ
  biceq r6, r8 @ clear at index
  orrne r6, r8 @ set at index
  strh r6, [r5]

  add r7, 1 @ increment bit index
  orr r7, 0b10000000
  strb r7, [r4] @ update bit index
handler_3_cleanup:
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

@ stores the current status of the reader
receiver_status:
  @ most significant bit indicates whether the control line is active or not, 
  @ (1 = reading, 0 = finished).
  @ other bits are used for the current bit index for reading data
  .byte 0 

@ stores data required to play the current note in 2 bytes
receiver_current:
  .hword 0 
@ stores data required to play the next note in 2 bytes.
@ is read bit by bit from the sender data line, 
@ then replaces receiver_current after sending is complete
receiver_next:
  .hword 0 

@ --sender--
@ all sender functionality is using the timer in tim7.S and this data

@ stores the current status of the sender
sender_status:
  .byte 1 @ current offset for sender_song

@ used by the sender to determine what signals to send.
@ stored in the same format as a receiver_status.
@ first byte indicates song length
sender_song:
  .byte 72 @ song length in bytes
  .hword 220 @ on, 0
  .hword 0          @ off
  .hword 261 @ on, 2
  .hword 0          @ off
  .hword 246 @ on, 1
  .hword 0          @ off
  .hword 293 @ on, 3
  .hword 0          @ off
  .hword 261 @ on, 2
  .hword 0          @ off
  .hword 329 @ on, 4
  .hword 0          @ off
  .hword 293 @ on, 3
  .hword 0          @ off
  .hword 369 @ on, 5
  .hword 0          @ off
  .hword 339 @ on, 4
  .hword 0          @ off
  .hword 392 @ on, 6
  .hword 0          @ off
  .hword 369 @ on, 5
  .hword 0          @ off
  .hword 440 @ on, 7
  .hword 0          @ off
  .hword 392 @ on, 6
  .hword 0          @ off
  .hword 369 @ on, 5
  .hword 0          @ off
  .hword 329 @ on, 4
  .hword 0          @ off
  .hword 293 @ on, 3
  .hword 0          @ off
  .hword 261 @ on, 2
  .hword 0          @ off
  .hword 246 @ on, 1
  .hword 0          @ off
  .hword 220 @ on, 0
  .hword 0          @ off