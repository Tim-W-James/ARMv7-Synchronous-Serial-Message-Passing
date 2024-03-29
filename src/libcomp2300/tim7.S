.syntax unified

@ ------------------------ TIM7 ------------------------
@ Timer 7 features a 16-bit prescaler and a 16-bit counter.
@ The prescaler divides the main clock (which runs at 80MHz according to definition in HAL),
@ and the counter counts up according to the divided clock.
@ When the counter counts up to the reload value,
@ an update event is triggered and an interrupt is fired.

@ --------------------- Module Interface --------------------
.global tim7_init, TIM7_IRQHandler

@ --------------------- Implementation --------------------
.include "libcomp2300/macros.S"

.set CK_PSC, 80000000

.type tim7_init, %function
@ tim7_init takes two parameters, clock divisor and count (in each case, only the lower 16-bits will be used)
@
@ the clock divisor determines how many CPU cycles per TIM7 tick
@ the count determines how many TIM7 ticks between the TIM7 interrupts firing
@
@ Remember that in the assignment template, the main clock is at 80MHz
@ so, for example, clock divisor = 10000 and count = 8000 will give a 1Hz interrupt
@ 
@ In short, (seconds between interrupts) = (clock divisor * count) / 80000000
@
@ --parameters--
@ r0: clock divisor (prescaler + 1)
@ r1: count
tim7_init:
  push {r4-r5, lr}
  mov r4, r0
  mov r5, r1

  @ enable peripheral clock
  @ RCC_APB1ENR_set 5
  ldr r0, =ADR_RCC
  ldr r1, =OFS_RCC_APB1ENR
  ldr r2, =5
  bl set_bit

  @ Set prescaler
  @ the counter clock frequency f(CK_CNT) = f(CK_PSC) / (prescaler + 1)
  @ since clock divisor = prescaler + 1,
  @ subtract 1 here to get the prescaler
  @ See Section 29.4.7
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_PSC
  sub r4, 1
  strh r4, [r0, r1]

  @ set counter reload value (Section 29.4.8)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_ARR
  strh r5, [r0, r1]

  @ TIM7_EGR (Section 29.4.5)
  ldr r0, =ADR_TIM7
  ldr r1, =0x14
  ldr r2, [r0, r1]
  orr r2, 0b1
  str r2, [r0, r1]

  @ clear interrupt (Section 29.4.4)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_SR
  mov r2, 0
  bl clear_bit

  @ enable timer 7  (Section 29.4.1s)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_CR1
  mov r2, 0
  bl set_bit

  @ enable TIM7 DMA/interrupt (Section 29.4.3)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_DIER
  mov r2, 0
  bl set_bit

  @ enable TIM7 interrupt in NVIC
  NVIC_set ISER 55  @ TIM7 is at position 55

  @ set debug freeze (Section 44.16.4)
  ldr r0, =ADR_DBGMCU_APB1FZR1
  mov r1, 0
  mov r2, 5
  bl set_bit

  @ NOTE: you MAY want to configure the priority of TIM7.
  @ put your code here if that's the case
  mov r0, 55
  mov r1, 0b1111
  bl NVIC_IPR_set_priority @ lowest priority
  
  bl sync
  pop {r4-r5, lr}
  bx lr
.size tim7_init, .-tim7_init

.type TIM7_IRQHandler, %function
@ --parameters--
@ none
TIM7_IRQHandler:
  push {r4-r11, lr}

  @ --sender--

  ldr r0, =sender_status
  ldr r1, =sender_song
  ldrb r4, [r0, 1]       @ current pitch index in r4
  ldrb r5, [r0]          @ current offset in r5
  ldrb r6, [r1]          @ song length in r6

  cmp r5, r6
  ble get_note
  mov r5, 1 @ return to beginning of song if length has been reached

get_note:
  ldrb r8, [r1, r5]      @ current note
  bic r7, r8, 0b10000000 @ target pitch index in r7
  lsr r8, 7              @ on/off in r8
  add r5, 1
  strb r5, [r0] @ increment current note

  @ send on/off signal
  cmp r8, 0
  beq send_off
send_on:
  GPIOx_ODR_set E, 14 @ on
  b change_pitch
send_off:
  GPIOx_ODR_clear E, 14 @ off
  b store_pitch

change_pitch:
  @ increment pitch until it equals target
  cmp r4, r7
  beq store_pitch
  GPIOx_ODR_set E, 15 @ send rising edge to increment pitch index (GPIO has higher priority)
  GPIOx_ODR_clear E, 15 
  cmp r4, 7
  ITE GE @ increment if < 7, otherwise return to initial index
  movge r4, 0
  addlt r4, 1
  b change_pitch
store_pitch:
  ldr r0, =sender_status
  strb r4, [r0, 1] @ store new pitch index
  
  @ Clear interrupt (Section 29.4.4)
  ldr r0, =ADR_TIM7
  ldr r1, =OFS_TIMx_SR
  mov r2, 0
  bl clear_bit

  bl sync
  
  pop {r4-r11, lr}
  bx lr
.size TIM7_IRQHandler, .-TIM7_IRQHandler
