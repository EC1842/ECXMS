;==============================================================================
;  ECXMS.SYS - XMS 2.0 driver for the EC-1842 PC
;  Copyright (C) 2026 A.V.L.
;
;  This program is free software: you can redistribute it and/or modify
;  it under the terms of the GNU General Public License version 3 as
;  published by the Free Software Foundation.
;
;  This program is distributed in the hope that it will be useful,
;  but WITHOUT ANY WARRANTY; without even the implied warranty of
;  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;  GNU General Public License for more details.
;
;  You should have received a copy of the GNU General Public License
;  along with this program.  If not, see <https://www.gnu.org/licenses/>.
;==============================================================================
;  ECXMS.SYS - ДРАЙВЕР РАСШИРЕННОЙ ПАМЯТИ (XMS 2.0) ДЛЯ ПЭВМ ЕС-1842
;  Редакция 1.21
;
;  Работает с памятью выше 1 Мбайт напрямую через контроллер виртуальной
;  памяти (КВП, порты 0C0h-0CFh), НЕ обращаясь к функции INT 15H AH=87h.
;  Даёт программам набор функций XMS версии 2.0, которым пользуются
;  SMARTDRV и RAMDRIVE из MS-DOS 6.0 и средства DR-DOS 6.0.
;
;  ЧЕГО ЭТА МАШИНА НЕ УМЕЕТ, и почему.
;    Области HMA нет и быть не может: у КМ1810ВМ86М сумматор адреса
;    20-разрядный, перенос из старшего разряда теряется внутри процессора
;    ещё до выхода на шину, и КВП его не восстановит. Вентиля A20 в машине
;    тоже нет - по п.4.2.1 ТО1 разряды SA20-SA22 в реальном режиме
;    аппаратурно дополняются нулями. Поэтому функция 00h возвращает DX=0,
;    функции 01h и 02h - ошибку 90h, и DOS остаётся в нижней памяти.
;    Верхних блоков (UMB) тоже нет: порт 73h переносит область 384 Кбайт
;    целиком за границу мегабайта, а не в дыры между C000h и EFFFh.
;
;  КАК УСТРОЕН ДОСТУП К ПАМЯТИ ВЫШЕ 1 Мбайт.
;    В кэш дескрипторов КВП заносятся 24-разрядные базы сегментов DS и ES,
;    затем разрядом VF порта 0C8h включается расширенная адресация,
;    и обычная REP MOVSW переносит данные. Так же поступает и сама БСУВВ
;    в функции INT 15H AH=87h, но там дескрипторы перенастраиваются на
;    каждый вызов и добавляются расходы на прерывание.
;
;  ПОЧЕМУ ОКНО ВЫНЕСЕНО В НИЖНЮЮ ПАМЯТЬ.
;    Пока VF=1, физический адрес складывается из базы дескриптора и
;    смещения. Это касается и выборки команд через дескриптор CS. Чтобы
;    код работал правильно при любой из двух возможных моделей поведения
;    КВП - участвует значение сегментного регистра в сложении или нет, -
;    перенос выполняет подпрограмма из 16 байт, вызываемая как
;    FAR 0000:адрес при базе дескриптора CS, равной нулю. Тогда адрес
;    выборки команд равен смещению при обеих моделях. Поэтому драйвер
;    обязан лежать ниже 64 Кбайт; при установке это проверяется,
;    и при неудаче драйвер в памяти не остаётся.
;
;  ПОВЕДЕНИЕ В АВАРИЙНЫХ СЛУЧАЯХ - см. раздел в конце файла.
;
;  Трансляция:
;       masm ecxms.asm, ecxms.obj;
;       link ecxms.obj;
;       exe2bin ecxms.exe ecxms.sys
;  Подключение:  DEVICE=ECXMS.SYS   в CONFIG.SYS.
;==============================================================================

CODE    SEGMENT
        ASSUME  CS:CODE, DS:CODE, ES:NOTHING, SS:NOTHING
        ORG     0

MAXHANDLES      EQU     32
CHUNK           EQU     4096            ; байт за одно открытие окна;
                                        ; при 8 МГц это около 5 мс запрета
                                        ; прерываний - меньше периода таймера

KVP_CTL         EQU     0C8h
PORT_B          EQU     061h
KVP_BASE_HI     EQU     0C0h
KVP_LIMIT       EQU     0C2h
KVP_BASE_LO     EQU     0C4h
SEL_ES          EQU     004h
SEL_CS          EQU     014h
SEL_DS          EQU     01Ch
SEL_SS          EQU     00Ch
VF_ON           EQU     006h
VF_OFF          EQU     004h
ACC_DATA        EQU     017h
ACC_CODE        EQU     013h
CMOS_PORT       EQU     070h

E_NOTIMPL       EQU     080h
E_NOHMA         EQU     090h
E_HMAINUSE      EQU     091h
E_HMANOTALLOC   EQU     093h
E_ALLALLOC      EQU     0A0h
E_NOHANDLES     EQU     0A1h
E_BADHANDLE     EQU     0A2h
E_BADSRCH       EQU     0A3h
E_BADSRCO       EQU     0A4h
E_BADDSTH       EQU     0A5h
E_BADDSTO       EQU     0A6h
E_BADLEN        EQU     0A7h
E_NOTLOCKED     EQU     0AAh
E_LOCKED        EQU     0ABh
E_LOCKOVF       EQU     0ACh
E_BUSY          EQU     0A9h
E_SMALLUMB      EQU     0B0h
E_NOUMB         EQU     0B1h
E_BADUMB        EQU     0B2h

;==============================================================================
;                        ЗАГОЛОВОК УСТРОЙСТВА
;==============================================================================
header:
        dd      -1
        dw      8000h                   ; символьное устройство
        dw      strategy
        dw      interrupt
        db      'XMSXXXX0'              ; имя, по которому драйвер узнают

req_ptr dd      0

strategy        PROC    FAR
        mov     WORD PTR cs:req_ptr,bx
        mov     WORD PTR cs:req_ptr+2,es
        retf                            ; DOS вызывает драйвер дальним вызовом
strategy        ENDP

interrupt       PROC    FAR
;  Драйвер обязан работать на СВОЁМ стеке. При обработке CONFIG.SYS DOS
;  отводит под стек очень мало места, а здесь кладутся девять регистров
;  и идут вложенные вызовы с обращениями к INT 21h. Переполнение портит
;  память рядом - именно туда, где в этот момент грузятся драйверы.
        cli
        mov     WORD PTR cs:save_ss,ss
        mov     WORD PTR cs:save_sp,sp
        mov     ax,cs
        mov     ss,ax                   ; следующая команда выполняется
        mov     sp,OFFSET drv_stack_top ; с запретом прерываний (правило 8086)
        sti
        push    ax
        push    bx
        push    cx
        push    dx
        push    ds
        push    es
        push    si
        push    di
        push    bp
        push    cs
        pop     ds
        les     bx,req_ptr
        cmp     BYTE PTR es:[bx+2],0    ; команда инициализации?
        jne     int_done
        call    do_init
int_done:
        les     bx,req_ptr
        mov     WORD PTR es:[bx+3],0100h        ; выполнено, ошибок нет
        pop     bp
        pop     di
        pop     si
        pop     es
        pop     ds
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        cli
        mov     ss,WORD PTR cs:save_ss  ; вернуть стек вызывающей программы
        mov     sp,WORD PTR cs:save_sp
        sti
        retf                            ; тоже дальний возврат
interrupt       ENDP

;==============================================================================
;  ЗАГЛУШКИ, ИСПОЛНЯЕМЫЕ ПРИ ВКЛЮЧЁННОМ VF
;  Обе лежат в постоянной части драйвера и вызываются как FAR 0000:адрес.
;  Внутри окна нет ни обращений к стеку, ни переходов, ни обращений
;  к данным драйвера: только порты и пересылка.
;==============================================================================
mover:                                  ; вход: SI, DI, CX (слов)
        xor     ax,ax
        mov     ds,ax                   ; при VF=1 значение сегментного
        mov     es,ax                   ; регистра роли не играет, но
        cld                             ; обнуляем, как и сама БСУВВ
        mov     al,VF_ON
        out     KVP_CTL,al
        rep     movsw
        mov     al,VF_OFF
        out     KVP_CTL,al
        retf

prober:                                 ; вход: ES, BX; выход: SI
        mov     al,VF_ON
        out     KVP_CTL,al
        mov     si,es:[bx]
        mov     al,VF_OFF
        out     KVP_CTL,al
        retf

filler:                                 ; вход: DI, CX (слов); заполняет нулями
        xor     ax,ax
        mov     es,ax
        cld
        mov     al,VF_ON
        out     KVP_CTL,al
        xor     ax,ax
        rep     stosw
        mov     al,VF_OFF
        out     KVP_CTL,al
        retf

writer:                                 ; вход: ES, BX, SI; выход: DI
        mov     al,VF_ON
        out     KVP_CTL,al
        mov     es:[bx],si
        mov     di,es:[bx]
        mov     al,VF_OFF
        out     KVP_CTL,al
        retf
stubs_end:

;==============================================================================
;                    РАБОТА С ДЕСКРИПТОРАМИ КВП
;==============================================================================
;  set_desc - запрограммировать один дескриптор.
;    вход: BL = код выбора, BH = байт правил доступа,
;          DL = база 23-16, AX = база 15-0
;    Вызывается при VF=0, на текущую адресацию не влияет.
set_desc        PROC    NEAR
        push    ax
        mov     al,bl
        out     KVP_CTL,al
        pop     ax
        out     KVP_BASE_LO,ax
        mov     al,bh
        mov     ah,dl
        out     KVP_BASE_HI,ax
        mov     ax,0FFFFh
        out     KVP_LIMIT,ax            ; граница всегда максимальная
        ret
set_desc        ENDP

;  kvp_enter - запретить прерывания и NMI, обнулить базы CS и SS.
;    Портит AX, BX, DX. Регистры CX, SI, DI, BP не трогает.
kvp_enter       PROC    NEAR
        cli
        xor     al,al
        out     CMOS_PORT,al            ; разр.7 = 0 запрещает NMI (п.4.12)
        mov     bl,SEL_CS
        mov     bh,ACC_CODE
        xor     dx,dx
        xor     ax,ax
        call    set_desc
        mov     bl,SEL_SS
        mov     bh,ACC_CODE
        xor     dx,dx
        xor     ax,ax
        call    set_desc
        ret
kvp_enter       ENDP

;  parity_reset - сбросить защёлки ошибки чётности ОЗУ и канала.
;    Взведённая защёлка даёт немаскируемое прерывание в тот миг, когда
;    NMI снова разрешается, и обработчик БСУВВ останавливает машину.
;    Последовательность та же, что в программе stgtst самой БСУВВ:
;    установить разряды 2 и 3 порта 61h и тут же сбросить.
parity_reset    PROC    NEAR
        in      al,PORT_B
        jmp     short $+2
        or      al,0Ch
        out     PORT_B,al
        jmp     short $+2
        and     al,0F3h
        out     PORT_B,al
        jmp     short $+2
        ret
parity_reset    ENDP

;  kvp_leave - вернуть дескриптор CS в состояние, оставленное БСУВВ
;    (база 0F0000h, граница 0), разрешить NMI и прерывания.
kvp_leave       PROC    NEAR
        mov     al,SEL_CS
        out     KVP_CTL,al
        mov     ax,0F00h+ACC_CODE
        out     KVP_BASE_HI,ax
        xor     ax,ax
        out     KVP_BASE_LO,ax
        out     KVP_LIMIT,ax
        call    parity_reset            ; снять защёлки до того, как NMI
        mov     al,80h                  ; будет снова разрешено
        out     CMOS_PORT,al
        sti
        ret
kvp_leave       ENDP

;==============================================================================
;  copy_chunk - перенести один участок длиной BP байт (чётное, <= CHUNK)
;    из cur_src в cur_dst. DS должен указывать на сегмент драйвера.
;==============================================================================
mon_mode        DB      0               ; 1 - под монитором M286: перенос через INT 15h AH=87h,
                                        ; КВП программе закрыт

;  Перенос куска под монитором: таблица для INT 15h AH=87h на стеке
copy_int15      PROC    NEAR
        push    bp
        push    es
        sub     sp,48
        mov     bp,sp
        push    ss
        pop     es
        mov     si,bp
        xor     ax,ax
        mov     cx,24
        mov     di,bp
        cld
        rep     stosw                   ; таблица - нули
        mov     ax,[bp+48+2+2]          ; (bp сохранён, es) - сверху лежит длина? нет: берём из cur_*
        mov     cx,WORD PTR cur_src
        mov     [bp+10h+2],cx           ; источник: база 0-15
        mov     al,BYTE PTR cur_src+2
        mov     [bp+10h+4],al           ; база 16-23
        mov     BYTE PTR [bp+10h+5],93h
        mov     cx,WORD PTR cur_dst
        mov     [bp+18h+2],cx
        mov     al,BYTE PTR cur_dst+2
        mov     [bp+18h+4],al
        mov     BYTE PTR [bp+18h+5],93h
        mov     ax,chunk_bytes
        dec     ax
        mov     [bp+10h],ax             ; границы
        mov     [bp+18h],ax
        mov     cx,chunk_bytes
        shr     cx,1                    ; слов
        mov     si,bp
        mov     ah,87h
        int     15h
        add     sp,48
        pop     es
        pop     bp
        ret
copy_int15      ENDP
chunk_bytes     DW      0

copy_chunk      PROC    NEAR
        push    bp
        mov     chunk_bytes,bp
        cmp     mon_mode,0
        je      cc_kvp
        pop     bp
        jmp     copy_int15
cc_kvp:
        ; источник: база выравнивается вниз до чётной, младший разряд
        ; уходит в начальное смещение
        mov     ax,WORD PTR cur_src
        mov     dx,WORD PTR cur_src+2
        mov     si,ax
        and     si,1
        and     ax,0FFFEh
        mov     bl,SEL_DS
        mov     bh,ACC_DATA
        call    set_desc
        ; приёмник
        mov     ax,WORD PTR cur_dst
        mov     dx,WORD PTR cur_dst+2
        mov     di,ax
        and     di,1
        and     ax,0FFFEh
        mov     bl,SEL_ES
        mov     bh,ACC_DATA
        call    set_desc
        pop     bp
        mov     cx,bp
        shr     cx,1                    ; число слов
        push    ds
        push    es
        call    kvp_enter               ; CX, SI, DI сохраняются
        call    DWORD PTR cs:mover_ptr
        call    kvp_leave
        pop     es
        pop     ds
        ret
copy_chunk      ENDP

;==============================================================================
;  do_move - перенос произвольной длины.
;    Читает src_phys, dst_phys, mv_len, rev_flag, chunk_sz.
;    Между участками прерывания разрешены, поэтому длинный перенос
;    не съедает тики таймера.
;==============================================================================
do_move         PROC    NEAR
        cmp     rev_flag,0
        je      dm_fwd
        ; обратный порядок: указатели ставим на конец областей
        mov     ax,WORD PTR src_phys
        mov     dx,WORD PTR src_phys+2
        add     ax,WORD PTR mv_len
        adc     dx,WORD PTR mv_len+2
        mov     WORD PTR cur_src,ax
        mov     WORD PTR cur_src+2,dx
        mov     ax,WORD PTR dst_phys
        mov     dx,WORD PTR dst_phys+2
        add     ax,WORD PTR mv_len
        adc     dx,WORD PTR mv_len+2
        mov     WORD PTR cur_dst,ax
        mov     WORD PTR cur_dst+2,dx
        jmp     dm_loop
dm_fwd:
        mov     ax,WORD PTR src_phys
        mov     dx,WORD PTR src_phys+2
        mov     WORD PTR cur_src,ax
        mov     WORD PTR cur_src+2,dx
        mov     ax,WORD PTR dst_phys
        mov     dx,WORD PTR dst_phys+2
        mov     WORD PTR cur_dst,ax
        mov     WORD PTR cur_dst+2,dx
dm_loop:
        mov     ax,WORD PTR mv_len
        or      ax,WORD PTR mv_len+2
        jz      dm_exit
        mov     bp,chunk_sz
        cmp     WORD PTR mv_len+2,0
        jne     dm_full                 ; осталось больше 64 Кбайт
        mov     ax,WORD PTR mv_len
        cmp     ax,bp
        jae     dm_full
        mov     bp,ax                   ; остаток меньше участка
dm_full:
        cmp     rev_flag,0
        je      dm_go
        mov     ax,bp                   ; при обратном порядке сначала
        sub     WORD PTR cur_src,ax     ; отступаем назад
        sbb     WORD PTR cur_src+2,0
        sub     WORD PTR cur_dst,ax
        sbb     WORD PTR cur_dst+2,0
dm_go:
        push    bp
        call    copy_chunk
        pop     bp
        mov     ax,bp
        sub     WORD PTR mv_len,ax
        sbb     WORD PTR mv_len+2,0
        cmp     rev_flag,0
        jne     dm_loop
        mov     ax,bp
        add     WORD PTR cur_src,ax
        adc     WORD PTR cur_src+2,0
        add     WORD PTR cur_dst,ax
        adc     WORD PTR cur_dst+2,0
        jmp     dm_loop
dm_exit:
        ret
do_move         ENDP

;==============================================================================
;                  ТОЧКА ВХОДА XMS (дальний вызов, функция в AH)
;==============================================================================
xms_entry:
        jmp     SHORT xms_dispatch      ; так же начинается точка входа HIMEM
        nop
        nop
        nop

xms_dispatch:
        push    dx                      ; входные DX, BX и номер функции -
        push    bx                      ; чтобы вернуть вызывающему всё, что
        push    ax                      ; функция по описанию XMS не меняет
        push    cx                      ; по описанию XMS все регистры,
        push    si                      ; кроме возвращающих значение,
        push    di                      ; должны сохраняться
        push    bp
        push    ds
        push    es
        mov     cs:sv_ds,ds             ; запомнить, где лежит описание
        mov     cs:sv_si,si             ; переноса для функции 0Bh
        push    cs
        pop     ds
        cmp     ah,11h
        ja      xd_bad
        cmp     ah,0Bh                  ; только перенос пользуется общими
        jne     xd_nobusy               ; переменными и потому не допускает
        cmp     busy,0                  ; повторного входа
        jne     xd_busy
        mov     busy,1
xd_nobusy:
        mov     sv_bx,bx                ; BX - входной параметр функции 11h,
        mov     bl,ah                   ; поэтому под указатель в таблице
        xor     bh,bh                   ; берём DI, а BX возвращаем на место
        shl     bx,1
        mov     di,bx
        mov     bx,sv_bx
        call    WORD PTR fn_table[di]
        mov     busy,0
xd_out:
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     cx
;  Вернуть DX и BX, которые функция по описанию XMS не возвращает. Функции
;  пользуются BX и DX как рабочими, а программы (например, загрузчики
;  оверлеев) держат в них свои значения между вызовами.
;    DX возвращают только 00h, 08h, 09h, 0Ch, 0Eh, 10h;
;    BX - 00h, 0Ch, 0Eh, 10h; остальные при ошибке дают код в BL (BH - прежний),
;    при успехе BX прежний; 07h и 08h при успехе дают BL = 0.
        push    bp
        mov     bp,sp                   ; [bp+2] AX, [bp+4] BX, [bp+6] DX на входе
        push    ax                      ; [bp-2] итог функции
        mov     al,[bp+3]               ; номер функции
        cmp     al,00h
        je      xr_dx
        cmp     al,08h
        je      xr_dx
        cmp     al,09h
        je      xr_dx
        cmp     al,0Ch
        je      xr_dx
        cmp     al,0Eh
        je      xr_dx
        cmp     al,10h
        je      xr_dx
        mov     dx,[bp+6]               ; DX - прежний
xr_dx:
        cmp     al,00h
        je      xr_bx
        cmp     al,0Ch
        je      xr_bx
        cmp     al,0Eh
        je      xr_bx
        cmp     al,10h
        je      xr_bx
        mov     ah,[bp+5]               ; BH на входе
        cmp     WORD PTR [bp-2],0
        je      xr_bh                   ; ошибка: код в BL остаётся
        cmp     al,07h
        je      xr_bl0
        cmp     al,08h
        je      xr_bl0
        mov     bl,[bp+4]               ; успех: BX целиком прежний
        jmp     SHORT xr_bh
xr_bl0:
        xor     bl,bl
xr_bh:
        mov     bh,ah
xr_bx:
        pop     ax
        pop     bp
        add     sp,6                    ; снять AX, BX, DX, сохранённые на входе
        retf
xd_bad:
        xor     ax,ax
        mov     bl,E_NOTIMPL
        jmp     xd_out
xd_busy:
        xor     ax,ax
        mov     bl,E_BUSY
        jmp     xd_out

fn_table        dw      fn_version, fn_reqhma, fn_relhma, fn_a20on
                dw      fn_a20off, fn_a20lon, fn_a20loff, fn_a20query
                dw      fn_query, fn_alloc, fn_free, fn_move
                dw      fn_lock, fn_unlock, fn_info, fn_realloc
                dw      fn_requmb, fn_relumb

;------ 00h: версия --------------------------------------------------------
fn_version:
        mov     ax,0200h                ; XMS 2.0
        mov     bx,0260h                ; версия драйвера - как у HIMEM 2.60: WIN.COM требует не ниже
        mov     dx,1                    ; HMA есть - и занята (никому не отдаём)
        ret

;------ 01h, 02h: HMA ------------------------------------------------------
fn_reqhma:
        xor     ax,ax
        mov     bl,E_HMAINUSE           ; занята: ни DOS, ни Windows туда не лезут
        ret
fn_relhma:
        xor     ax,ax
        mov     bl,E_HMANOTALLOC
        ret

;------ 03h-07h: вентиль A20 -----------------------------------------------
;  Вентиля в машине нет. Функции ведут учёт запросов и сообщают об успехе,
;  чтобы не ломать программы, которые включают A20 перед пересылкой.
;  Области HMA мы не обещаем, поэтому обращаться к FFFF:xxxx им незачем.
fn_a20on:
        mov     a20_global,1
        jmp     a20_ok
fn_a20off:
        mov     a20_global,0
        jmp     a20_ok
fn_a20lon:
        cmp     a20_local,0FFh
        je      a20_ovf
        inc     a20_local
        jmp     a20_ok
fn_a20loff:
        cmp     a20_local,0
        je      a20_ok
        dec     a20_local
a20_ok:
        mov     ax,1
        xor     bl,bl
        ret
a20_ovf:
        xor     ax,ax
        mov     bl,E_LOCKOVF
        ret
fn_a20query:
        xor     ax,ax
        cmp     a20_global,0
        jne     a20_q1
        cmp     a20_local,0
        je      a20_q0
a20_q1: mov     ax,1
a20_q0: xor     bl,bl
        ret

;------ 08h: сколько свободно ----------------------------------------------
fn_query:
        call    calc_free               ; AX = наибольший кусок, DX = всего
        xor     bl,bl
        or      dx,dx
        jnz     fq_done
        mov     bl,E_ALLALLOC
fq_done:
        ret

;------ 09h: выделить блок -------------------------------------------------
fn_alloc:
        mov     bp,dx                   ; сколько килобайт просят
        call    find_handle             ; BX = индекс свободного описателя
        jc      fa_nohandle
        push    bx
        mov     ax,bp
        call    find_space              ; AX = начало, CF=1 если нет места
        pop     bx
        jc      fa_nospace
        mov     si,bx
        shl     si,1
        shl     si,1
        shl     si,1
        mov     BYTE PTR h_flags[si],1
        mov     BYTE PTR h_lock[si],0
        mov     WORD PTR h_start[si],ax
        mov     WORD PTR h_size[si],bp
        mov     dx,bx
        inc     dx
        shl     dx,1
        shl     dx,1
        shl     dx,1                    ; описатели: 8, 16, 24, ...
        mov     ax,1
        xor     bl,bl
        ret
fa_nohandle:
        xor     ax,ax
        mov     bl,E_NOHANDLES
        ret
fa_nospace:
        xor     ax,ax
        mov     bl,E_ALLALLOC
        ret

;------ 0Ah: освободить блок -----------------------------------------------
fn_free:
        call    chk_handle
        jc      fh_bad
        cmp     BYTE PTR h_lock[si],0
        jne     ff_locked
        mov     BYTE PTR h_flags[si],0
        mov     ax,1
        xor     bl,bl
        ret
fh_bad:
        xor     ax,ax
        mov     bl,E_BADHANDLE
        ret
ff_locked:
        xor     ax,ax
        mov     bl,E_LOCKED
        ret

;------ 0Bh: перенести блок ------------------------------------------------
;  Описание переноса лежит по адресу, сохранённому в sv_ds:sv_si:
;    +0  длина в байтах (dword, должна быть чётной)
;    +4  описатель источника (0 - обычная память)
;    +6  адрес источника (dword)
;    +10 описатель приёмника
;    +12 адрес приёмника
fn_move:
        mov     es,sv_ds
        mov     bx,sv_si
        mov     ax,es:[bx]              ; длина
        mov     dx,es:[bx+2]
        test    al,1
        jnz     fm_badlen               ; нечётная длина недопустима
        mov     WORD PTR mv_len,ax
        mov     WORD PTR mv_len+2,dx
        mov     cx,ax
        or      cx,dx
        jz      fm_ok                   ; нулевая длина - работы нет
        mov     si,es:[bx+4]            ; описатель источника
        mov     ax,es:[bx+6]
        mov     dx,es:[bx+8]
        mov     di,0                    ; разбираем источник
        call    calc_addr
        jc      fm_err
        mov     WORD PTR src_phys,ax
        mov     WORD PTR src_phys+2,dx
        mov     es,sv_ds
        mov     bx,sv_si
        mov     si,es:[bx+10]           ; описатель приёмника
        mov     ax,es:[bx+12]
        mov     dx,es:[bx+14]
        mov     di,1                    ; разбираем приёмник
        call    calc_addr
        jc      fm_err
        mov     WORD PTR dst_phys,ax
        mov     WORD PTR dst_phys+2,dx
        ; выбрать направление обхода
        mov     rev_flag,0
        mov     ax,def_chunk
        mov     chunk_sz,ax
        mov     ax,WORD PTR dst_phys
        mov     dx,WORD PTR dst_phys+2
        sub     ax,WORD PTR src_phys
        sbb     dx,WORD PTR src_phys+2
        jc      fm_go                   ; приёмник ниже источника - вперёд
        mov     cx,ax
        or      cx,dx
        jz      fm_ok                   ; адреса совпали - переносить нечего
        or      dx,dx
        jnz     fm_go                   ; расстояние больше 64 Кбайт -
                                        ; при участке 4 Кбайт наложения нет
        cmp     WORD PTR mv_len+2,0
        jne     fm_overlap              ; длина больше 64 Кбайт, а
                                        ; расстояние меньше - наложение есть
        cmp     ax,WORD PTR mv_len
        jae     fm_go                   ; расстояние не меньше длины
fm_overlap:
        mov     rev_flag,1              ; идти с конца
        cmp     ax,def_chunk
        jae     fm_go                   ; участок и так короче расстояния
        and     ax,0FFFEh               ; округлить вниз до чётного
        jnz     fm_setchunk
        mov     ax,2                    ; расстояние в один байт: при обходе
                                        ; с конца участок в два байта
                                        ; безопасен, см. примечание 7
fm_setchunk:
        mov     chunk_sz,ax
fm_go:
        call    do_move
fm_ok:
        mov     ax,1
        xor     bl,bl
        ret
fm_badlen:
        xor     ax,ax
        mov     bl,E_BADLEN
        ret
fm_err:
        xor     ax,ax
        mov     bl,bh                   ; calc_addr вернула код в BH
        ret

;------ 0Ch: запереть блок -------------------------------------------------
fn_lock:
        call    chk_handle
        jc      fh_bad
        cmp     BYTE PTR h_lock[si],0FFh
        je      fl_ovf
        inc     BYTE PTR h_lock[si]
        mov     ax,WORD PTR h_start[si]
        call    kb_to_phys              ; DX:AX = физический адрес
        mov     bx,ax
        mov     ax,1
        ret
fl_ovf:
        xor     ax,ax
        mov     bl,E_LOCKOVF
        ret

;------ 0Dh: отпереть блок -------------------------------------------------
fn_unlock:
        call    chk_handle
        jc      fh_bad
        cmp     BYTE PTR h_lock[si],0
        je      fu_notlocked
        dec     BYTE PTR h_lock[si]
        mov     ax,1
        xor     bl,bl
        ret
fu_notlocked:
        xor     ax,ax
        mov     bl,E_NOTLOCKED
        ret

;------ 0Eh: сведения о блоке ----------------------------------------------
fn_info:
        call    chk_handle
        jc      fh_bad
        mov     dx,WORD PTR h_size[si]
        mov     bh,BYTE PTR h_lock[si]
        call    count_free_handles
        mov     bl,al
        mov     ax,1
        ret

;------ 0Fh: изменить размер блока -----------------------------------------
fn_realloc:
        call    chk_handle
        jc      fh_bad
        cmp     BYTE PTR h_lock[si],0
        jne     fr_locked
        mov     ax,bx                   ; новый размер в килобайтах
        cmp     ax,WORD PTR h_size[si]
        ja      fr_grow
        mov     WORD PTR h_size[si],ax           ; уменьшение возможно всегда
        mov     ax,1
        xor     bl,bl
        ret
fr_locked:
        xor     ax,ax
        mov     bl,E_LOCKED
        ret
fr_grow:
        mov     rl_new,ax
        mov     rl_h,si
        call    find_space              ; старый блок ещё помечен занятым,
        jc      fr_nospace              ; поэтому новое место с ним не сойдётся
        mov     rl_dst,ax
        mov     si,rl_h                 ; перенести содержимое
        mov     ax,WORD PTR h_start[si]
        call    kb_to_phys
        mov     WORD PTR src_phys,ax
        mov     WORD PTR src_phys+2,dx
        mov     ax,rl_dst
        call    kb_to_phys
        mov     WORD PTR dst_phys,ax
        mov     WORD PTR dst_phys+2,dx
        mov     si,rl_h
        mov     ax,WORD PTR h_size[si]
        call    kb_to_bytes             ; DX:AX = старый размер в байтах
        mov     WORD PTR mv_len,ax
        mov     WORD PTR mv_len+2,dx
        mov     rev_flag,0
        mov     ax,def_chunk
        mov     chunk_sz,ax
        call    do_move
        mov     si,rl_h
        mov     ax,rl_dst
        mov     WORD PTR h_start[si],ax
        mov     ax,rl_new
        mov     WORD PTR h_size[si],ax
        mov     ax,1
        xor     bl,bl
        ret
fr_nospace:
        xor     ax,ax
        mov     bl,E_ALLALLOC
        ret

;------ 10h, 11h: верхние блоки --------------------------------------------
;  Верхний блок появляется, только если при установке заданы ключи /U
;  и проба показала, что в окне 0E000h действительно отзывается память.
fn_requmb:
        mov     ax,umb_para
        or      ax,ax
        jz      fu_none                 ; окна нет вовсе
        cmp     umb_used,0
        jne     fu_none                 ; уже роздан
        cmp     dx,ax
        ja      fu_small                ; просят больше, чем есть
        mov     umb_used,1
        mov     dx,ax                   ; отдаём весь блок целиком
        mov     bx,umb_seg
        mov     ax,1
        ret
fu_small:
        xor     ax,ax
        mov     dx,umb_para             ; сообщить, сколько есть
        mov     bl,E_SMALLUMB
        ret
fu_none:
        xor     ax,ax
        xor     dx,dx
        mov     bl,E_NOUMB
        ret
fn_relumb:
;  По описанию XMS 2.0 сегмент освобождаемого блока передаётся в DX.
        cmp     umb_used,0
        je      fr_badumb
        cmp     dx,umb_seg
        jne     fr_badumb
        mov     umb_used,0
        mov     ax,1
        xor     bl,bl
        ret
fr_badumb:
        xor     ax,ax
        mov     bl,E_BADUMB
        ret

;==============================================================================
;                        ВСПОМОГАТЕЛЬНЫЕ ПОДПРОГРАММЫ
;==============================================================================
;  chk_handle - проверить описатель в DX; SI = смещение записи, CF=1 если плох
chk_handle      PROC    NEAR
        mov     si,dx
        or      si,si
        jz      ch_bad
        test    si,7
        jnz     ch_bad
        shr     si,1
        shr     si,1
        shr     si,1
        dec     si
        cmp     si,nhandles
        jae     ch_bad
        shl     si,1
        shl     si,1
        shl     si,1
        cmp     BYTE PTR h_flags[si],0
        je      ch_bad
        clc
        ret
ch_bad:
        stc
        ret
chk_handle      ENDP

;  chk_handle_si - то же, но описатель приходит в SI
chk_handle_si   PROC    NEAR
        push    dx
        mov     dx,si
        call    chk_handle
        pop     dx
        ret
chk_handle_si   ENDP

;  find_handle - BX = индекс свободного описателя, CF=1 если свободных нет
find_handle     PROC    NEAR
        xor     bx,bx
fh_l:
        mov     si,bx
        shl     si,1
        shl     si,1
        shl     si,1
        cmp     BYTE PTR h_flags[si],0
        je      fh_found
        inc     bx
        cmp     bx,nhandles
        jb      fh_l
        stc
        ret
fh_found:
        clc
        ret
find_handle     ENDP

;  count_free_handles - AL = число свободных описателей
count_free_handles PROC NEAR
        push    bx
        push    si
        xor     al,al
        xor     bx,bx
cfh_l:
        mov     si,bx
        shl     si,1
        shl     si,1
        shl     si,1
        cmp     BYTE PTR h_flags[si],0
        jne     cfh_n
        inc     al
cfh_n:
        inc     bx
        cmp     bx,nhandles
        jb      cfh_l
        pop     si
        pop     bx
        ret
count_free_handles ENDP

;  find_space - найти место под AX килобайт.
;    выход: AX = начало (в килобайтах от границы 1 Мбайт), CF=1 если нет.
;    Пробу двигаем за конец каждого занятого блока, который её пересекает,
;    и начинаем сначала. Не больше 32 сдвигов, значит цикл конечен.
find_space      PROC    NEAR
        push    bx
        push    cx
        push    dx
        push    si
        mov     cx,ax                   ; сколько нужно
        xor     dx,dx                   ; начало пробы
fs_restart:
        mov     ax,dx
        add     ax,cx
        jc      fs_no                   ; переполнение разрядной сетки
        cmp     ax,total_kb
        ja      fs_no                   ; не помещается до конца памяти
        xor     bx,bx
fs_scan:
        mov     si,bx
        shl     si,1
        shl     si,1
        shl     si,1
        cmp     BYTE PTR h_flags[si],0
        je      fs_next
        mov     ax,WORD PTR h_start[si]
        add     ax,WORD PTR h_size[si]           ; конец занятого блока
        cmp     dx,ax
        jae     fs_next                 ; проба целиком выше блока
        push    ax
        mov     ax,dx
        add     ax,cx                   ; конец пробы
        cmp     ax,WORD PTR h_start[si]
        pop     ax
        jbe     fs_next                 ; проба целиком ниже блока
        mov     dx,ax                   ; пересеклись: сдвинуть пробу
        jmp     fs_restart
fs_next:
        inc     bx
        cmp     bx,nhandles
        jb      fs_scan
        mov     ax,dx                   ; место нашлось
        clc
        jmp     fs_out
fs_no:
        stc
fs_out:
        pop     si
        pop     dx
        pop     cx
        pop     bx
        ret
find_space      ENDP

;  calc_free - AX = наибольший свободный кусок, DX = всего свободно (Кбайт)
;    Пробными началами служат ноль и концы всех занятых блоков:
;    не больше 32 на 32 сравнений.
calc_free       PROC    NEAR
        push    bx
        push    cx
        push    si
        push    di
        mov     dx,total_kb
        xor     bx,bx
cf_sum:
        mov     si,bx
        shl     si,1
        shl     si,1
        shl     si,1
        cmp     BYTE PTR h_flags[si],0
        je      cf_sn
        sub     dx,WORD PTR h_size[si]
cf_sn:
        inc     bx
        cmp     bx,nhandles
        jb      cf_sum
        push    dx                      ; сохранить "всего свободно"
        xor     di,di                   ; лучший найденный кусок
        xor     cx,cx                   ; пробное начало
cf_probe:
        call    gap_at                  ; AX = длина куска, начиная с CX
        cmp     ax,di
        jbe     cf_pn
        mov     di,ax
cf_pn:
        call    next_start              ; следующее пробное начало
        jnc     cf_probe
        mov     ax,di
        pop     dx
        pop     di
        pop     si
        pop     cx
        pop     bx
        ret
calc_free       ENDP

;  gap_at - длина свободного куска, начинающегося с CX килобайт. Выход: AX.
gap_at          PROC    NEAR
        push    bx
        push    si
        push    dx
        mov     dx,total_kb
        cmp     cx,dx
        jae     ga_zero
        xor     bx,bx
ga_l:
        mov     si,bx
        shl     si,1
        shl     si,1
        shl     si,1
        cmp     BYTE PTR h_flags[si],0
        je      ga_n
        mov     ax,WORD PTR h_start[si]
        cmp     ax,cx
        jb      ga_inside
        cmp     ax,dx
        jae     ga_n
        mov     dx,ax                   ; ближайшее начало блока справа
        jmp     ga_n
ga_inside:
        add     ax,WORD PTR h_size[si]
        cmp     ax,cx
        jbe     ga_n                    ; блок целиком левее пробы
        mov     dx,cx                   ; проба внутри занятого блока
ga_n:
        inc     bx
        cmp     bx,nhandles
        jb      ga_l
        mov     ax,dx
        sub     ax,cx
        jmp     ga_out
ga_zero:
        xor     ax,ax
ga_out:
        pop     dx
        pop     si
        pop     bx
        ret
gap_at          ENDP

;  next_start - наименьший конец блока, который больше CX. CF=1, если нет.
next_start      PROC    NEAR
        push    bx
        push    si
        push    dx
        mov     dx,0FFFFh
        xor     bx,bx
ns_l:
        mov     si,bx
        shl     si,1
        shl     si,1
        shl     si,1
        cmp     BYTE PTR h_flags[si],0
        je      ns_n
        mov     ax,WORD PTR h_start[si]
        add     ax,WORD PTR h_size[si]
        cmp     ax,cx
        jbe     ns_n
        cmp     ax,dx
        jae     ns_n
        mov     dx,ax
ns_n:
        inc     bx
        cmp     bx,nhandles
        jb      ns_l
        cmp     dx,0FFFFh
        je      ns_none
        mov     cx,dx
        clc
        jmp     ns_out
ns_none:
        stc
ns_out:
        pop     dx
        pop     si
        pop     bx
        ret
next_start      ENDP

;  kb_to_bytes - AX килобайт -> DX:AX байт
kb_to_bytes     PROC    NEAR
        push    cx
        xor     dx,dx
        mov     cx,10
kb_l:
        shl     ax,1
        rcl     dx,1
        loop    kb_l
        pop     cx
        ret
kb_to_bytes     ENDP

;  kb_to_phys - AX килобайт от границы 1 Мбайт -> DX:AX физический адрес
kb_to_phys      PROC    NEAR
        call    kb_to_bytes
        add     dx,0010h                ; плюс 1 Мбайт
        ret
kb_to_phys      ENDP

;  calc_addr - перевести пару "описатель + адрес" в физический адрес
;    вход:  SI = описатель (0 - обычная память), DX:AX = адрес,
;           DI = 0 для источника, 1 для приёмника (влияет на код ошибки);
;           mv_len уже заполнена.
;    выход: DX:AX = физический адрес, CF=0;
;           CF=1 и BH = код ошибки.
calc_addr       PROC    NEAR
        or      si,si
        jnz     ca_ext
        ; обычная память: сегмент (в DX) на 16 плюс смещение (в AX)
        push    ax
        mov     ax,dx
        mov     cl,12
        shr     dx,cl                   ; старшие разряды сегмента
        mov     cl,4
        shl     ax,cl
        pop     cx
        add     ax,cx
        adc     dx,0
        clc
        ret
ca_ext:
        push    ax
        push    dx
        call    chk_handle_si           ; SI = смещение записи описателя
        pop     dx
        pop     ax
        jc      ca_badh
        ; смещение вместе с длиной не должно выходить за размер блока
        push    ax
        push    dx
        push    si
        mov     ax,WORD PTR h_size[si]
        call    kb_to_bytes             ; DX:AX = размер блока в байтах
        mov     bx,ax
        mov     cx,dx
        pop     si
        pop     dx
        pop     ax
        push    ax
        push    dx
        push    si
        add     ax,WORD PTR mv_len
        adc     dx,WORD PTR mv_len+2
        cmp     dx,cx
        ja      ca_bado
        jb      ca_okoff
        cmp     ax,bx
        ja      ca_bado
ca_okoff:
        pop     si
        pop     dx
        pop     ax
        push    ax
        push    dx
        mov     ax,WORD PTR h_start[si]
        call    kb_to_phys              ; DX:AX = начало блока
        mov     bx,ax
        mov     cx,dx
        pop     dx
        pop     ax
        add     ax,bx
        adc     dx,cx
        clc
        ret
ca_bado:
        pop     si
        pop     dx
        pop     ax
        or      di,di
        jnz     ca_bado_d
        mov     bh,E_BADSRCO
        stc
        ret
ca_bado_d:
        mov     bh,E_BADDSTO
        stc
        ret
ca_badh:
        or      di,di
        jnz     ca_badh_d
        mov     bh,E_BADSRCH
        stc
        ret
ca_badh_d:
        mov     bh,E_BADDSTH
        stc
        ret
calc_addr       ENDP

;==============================================================================
;                    ПЕРЕХВАТ INT 2Fh - КАК НАЙТИ ДРАЙВЕР
;==============================================================================
int2f           PROC    FAR
        cmp     ah,43h
        jne     i2f_chain
        cmp     al,00h
        je      i2f_present
        cmp     al,10h
        je      i2f_entry
i2f_chain:
        jmp     DWORD PTR cs:old_int2f
i2f_present:
        mov     al,80h
        iret
i2f_entry:
        push    cs
        pop     es
        mov     bx,OFFSET xms_entry
        iret
int2f           ENDP

;==============================================================================
;  ПЕРЕХВАТ INT 15H
;
;  После установки драйвера расширенная память принадлежит ему. Если
;  оставить функцию AH=88h отвечать правдиво, любая программа, не знающая
;  об XMS, возьмёт память в обход и затопчет чужие блоки. Поэтому AH=88h
;  отвечает нулём, как делает и HIMEM. Всё остальное уходит прежнему
;  обработчику без изменений.
;==============================================================================
int15           PROC    FAR
        cmp     ah,88h
        jne     i15_chain
        sti                             ; команда RETF 2 признаки НЕ
                                        ; восстанавливает, а прерывания
                                        ; запрещены входом в прерывание -
                                        ; разрешить их обратно самим
        xor     ax,ax                   ; расширенной памяти "нет"
        clc
        retf    2                       ; признаки возвращаются текущие,
                                        ; сохранённые в стеке отбрасываются
i15_chain:
        jmp     DWORD PTR cs:old_int15
int15           ENDP

;==============================================================================
;                              ДАННЫЕ ДРАЙВЕРА
;==============================================================================
mover_ptr       dd      0
prober_ptr      dd      0
writer_ptr      dd      0
filler_ptr      dd      0
old73           db      0
wc_got1         dw      0
wc_got2         dw      0
old_int2f       dd      0
old_int15       dd      0
busy            db      0
umb_seg         dw      0
umb_para        dw      0
umb_used        db      0
total_kb        dw      0
a20_global      db      0
a20_local       db      0
sv_ds           dw      0
sv_si           dw      0
sv_bx           dw      0
src_phys        dd      0
dst_phys        dd      0
cur_src         dd      0
cur_dst         dd      0
mv_len          dd      0
chunk_sz        dw      0
def_chunk       dw      CHUNK           ; размер участка, ключ /C:
rev_flag        db      0
rl_new          dw      0
rl_dst          dw      0
rl_h            dw      0

;  Стек драйвера. Растёт ВНИЗ от drv_stack_top, поэтому ниже него лежит
;  сторож: если он окажется испорчен, значит стека не хватило, и об этом
;  будет сказано прямо при установке, а не проявится порчей данных.
;  Ячейки save_ss и save_sp намеренно вынесены ВЫШЕ вершины стека -
;  переполнение до них не достанет, и возврат к вызывающей программе
;  останется цел при любом раскладе.
stack_guard     dw      0A5A5h
                dw      1024 DUP(0)     ; 2048 байт стека
drv_stack_top   EQU     $
save_ss         dw      0
save_sp         dw      0

nhandles        dw      MAXHANDLES
h_table         db      MAXHANDLES*8 DUP(0)
h_flags         EQU     h_table+0
h_lock          EQU     h_table+1
h_start         EQU     h_table+2
h_size          EQU     h_table+4

resident_end:

;==============================================================================
;   ВСЁ, ЧТО НИЖЕ, РАБОТАЕТ ТОЛЬКО ПРИ УСТАНОВКЕ И В ПАМЯТИ НЕ ОСТАЁТСЯ
;==============================================================================
do_init         PROC    NEAR
;------ 0. Разобрать параметры из строки CONFIG.SYS -------------------------
;  Указатель на строку лежит в заголовке запроса по смещению 18.
;  Строка содержит и путь к файлу, поэтому ищем только знаки "/".
        call    parse_cmdline
        cmp     opt_quiet,0
        jne     no_banner
        mov     dx,OFFSET m_banner
        call    puts
no_banner:

;------ 1. Не установлен ли уже драйвер XMS ---------------------------------
        mov     ax,4300h
        int     2Fh
        cmp     al,80h
        je      init_already

;------ 1а. Под монитором M286? Тогда КВП закрыт - перенос через INT 15h ------
        mov     ax,4D32h
        int     15h
        cmp     ax,324Dh
        jne     no_mon
        mov     mon_mode,1
        cmp     opt_quiet,0
        jne     no_mon
        mov     dx,OFFSET m_mon
        call    puts
no_mon:

;------ 2. Есть ли расширенная память ---------------------------------------
        mov     ah,88h
        int     15h
        mov     total_kb,ax             ; сохранить ДО любых других действий
        mov     raw_kb,ax               ; и отдельно - исходное, до ключа /M
        push    ax
        cmp     opt_quiet,0
        jne     no_raw_msg
        mov     dx,OFFSET m_raw
        call    puts
        pop     ax
        push    ax
        call    put_dec
        call    crlf
no_raw_msg:
        pop     ax
        or      ax,ax
        jz      init_nomem
        mov     bx,opt_limit            ; ключ /M: ограничивает объём
        or      bx,bx
        jz      no_limit
        cmp     bx,ax
        jae     no_limit
        mov     total_kb,bx
no_limit:
        cmp     opt_quiet,0
        jne     no_found_msg
        mov     dx,OFFSET m_found
        call    puts
        mov     ax,total_kb
        call    put_dec
        mov     dx,OFFSET m_kb
        call    puts
no_found_msg:

;------ 2а. Окно 0E000h трогается только по ключу /U ------------------------
;  Прежде здесь стояла безусловная проверка окна. Она опасна: при
;  выключенном окне по адресу 0E000h:0000 памяти нет, обращение туда даёт
;  ошибку чётности, а обработчик NMI из БСУВВ останавливает машину.
;  Теперь окно трогается только там, где его сначала включают, - в probe_umb,
;  и всё это под запретом NMI со сбросом защёлок.

;------ 3. Лежит ли драйвер ниже 64 Кбайт -----------------------------------
        cmp     mon_mode,0              ; под монитором заглушки КВП не нужны
        je      chk_low
        jmp     init_steps
chk_low:
        mov     ax,cs
        mov     dx,ax
        mov     cl,12
        shr     dx,cl
        or      dx,dx
        jnz     init_toohigh            ; сегмент сам по себе выше 64 Кбайт
        mov     cl,4
        shl     ax,cl                   ; физический адрес начала драйвера
        mov     bx,ax
        add     ax,OFFSET stubs_end     ; обе заглушки должны поместиться
        jc      init_toohigh
        cmp     ax,0FFF0h
        ja      init_toohigh
        mov     ax,bx
        add     ax,OFFSET mover
        mov     WORD PTR mover_ptr,ax
        mov     WORD PTR mover_ptr+2,0
        mov     ax,bx
        add     ax,OFFSET prober
        mov     WORD PTR prober_ptr,ax
        mov     WORD PTR prober_ptr+2,0
        mov     ax,bx
        add     ax,OFFSET writer
        mov     WORD PTR writer_ptr,ax
        mov     WORD PTR writer_ptr+2,0
        mov     ax,bx
        add     ax,OFFSET filler
        mov     WORD PTR filler_ptr,ax
        mov     WORD PTR filler_ptr+2,0
        cmp     opt_quiet,0
        jne     no_stub_msg
        mov     dx,OFFSET m_stub
        call    puts
        mov     ax,WORD PTR mover_ptr
        call    put_hex16
        call    crlf
no_stub_msg:

;  Пробы поведения КВП здесь нет: оно измерено на машине и одинаково
;  всегда - адрес = база + младшие 16 разрядов (сегмент*16 + смещение),
;  базы всех дескрипторов
;  действуют одновременно. Драйвер на этом и построен.
init_steps:
        cmp     mon_mode,0              ; под монитором: без проб через КВП
        je      no_mon_skip
        jmp     init_hook
no_mon_skip:

;------ 4а. Не занята ли память драйвером VDISK -----------------------------
;  Проверка обращается к памяти через окно КВП, поэтому может стоять
;  только после того, как настроены указатели на заглушки и пройдена
;  проба КВП.
        call    vdisk_here
        jnc     no_vdisk
        jmp     init_vdisk
no_vdisk:

;------ 4б. Опыт с расширенной памятью по ключу /T --------------------------
        cmp     opt_test,0
        je      no_selftest
        call    self_test
no_selftest:

;------ 4в. Верхний блок по ключу /U ----------------------------------------
        cmp     opt_umb,0
        je      no_umb_probe
        call    probe_umb
no_umb_probe:

;------ 4г. Установить чётность в непроверенных 384 Кбайт --------------------
        call    init_top384

;------ 5. Перехватить INT 2Fh ----------------------------------------------
init_hook:
        mov     al,opt_handles          ; ключ /H:nn
        or      al,al
        jz      no_hcount
        xor     ah,ah
        mov     nhandles,ax
no_hcount:
        push    es
        mov     ax,352Fh
        int     21h
        mov     WORD PTR old_int2f,bx
        mov     WORD PTR old_int2f+2,es
        mov     ax,3515h
        int     21h
        mov     WORD PTR old_int15,bx
        mov     WORD PTR old_int15+2,es
        pop     es
        cmp     opt_nohook,0
        jne     no_15_hook
        push    ds
        push    cs
        pop     ds
        mov     dx,OFFSET int15
        mov     ax,2515h
        int     21h
        pop     ds
no_15_hook:
        push    ds
        push    cs
        pop     ds
        mov     dx,OFFSET int2f
        mov     ax,252Fh
        int     21h
        pop     ds

        cmp     mon_mode,0
        je      no_mon_tell
        mov     ax,4D33h                ; монитору: XMS есть, INT 15h AH=88h -> 0
        int     15h
        jmp     short no_guard
no_mon_tell:
        call    check_guard
no_guard:
        cmp     opt_quiet,0
        jne     no_ok_msg
        mov     dx,OFFSET m_ok
        cmp     umb_para,0
        je      ok_msg_go
        mov     dx,OFFSET m_ok_umb
ok_msg_go:
        call    puts
no_ok_msg:
        les     bx,req_ptr
        mov     WORD PTR es:[bx+14],OFFSET resident_end
        mov     WORD PTR es:[bx+16],cs
        ret

init_already:
        mov     dx,OFFSET m_already
        jmp     init_fail
init_vdisk:
        mov     dx,OFFSET m_vdisk
        jmp     init_fail
init_nomem:
        mov     dx,OFFSET m_nomem
        jmp     init_fail
init_toohigh:
        mov     dx,OFFSET m_toohigh
        jmp     init_fail
init_fail:
        call    puts
        call    check_guard
        mov     dx,OFFSET m_notinst
        call    puts
        les     bx,req_ptr
        mov     WORD PTR es:[bx+14],0   ; в памяти не остаёмся
        mov     WORD PTR es:[bx+16],cs
        ret
do_init         ENDP

;==============================================================================
;  parse_cmdline - разобрать строку из CONFIG.SYS
;    /M:nnn  ограничить объём расширенной памяти nnn килобайтами
;    /C:nnn  размер участка переноса в байтах (от 64 до 16384, чётный)
;    /Q      не выводить сообщений, кроме сообщений об отказе
;    /N      не выполнять пробу поведения КВП
;  Неизвестные ключи и путь к файлу пропускаются молча.
;==============================================================================
parse_cmdline   PROC    NEAR
        push    ds
        les     bx,req_ptr
        mov     ax,es:[bx+18]
        mov     dx,es:[bx+20]
        mov     cx,ax
        or      cx,dx
        jz      pc_none                 ; указателя нет - параметров нет
        mov     si,ax
        mov     ds,dx
        mov     cx,200                  ; строка не может быть длиннее этого:
pc_l:                                   ; иначе указатель испорчен
        or      cx,cx
        jz      pc_end
        dec     cx
        mov     al,[si]
        or      al,al
        jz      pc_end
        cmp     al,0Dh
        je      pc_end
        cmp     al,0Ah
        je      pc_end
        inc     si
        cmp     al,'/'
        jne     pc_l
        mov     al,[si]
        or      al,al
        jz      pc_end                  ; строка кончилась сразу после косой
        cmp     al,0Dh
        je      pc_end
        cmp     al,0Ah
        je      pc_end
        inc     si
        and     al,0DFh
        cmp     al,'Q'
        je      pc_q
        cmp     al,'M'
        je      pc_m
        cmp     al,'C'
        je      pc_c
        cmp     al,'K'
        je      pc_k
        cmp     al,'U'
        je      pc_u
        cmp     al,'T'
        je      pc_t
        cmp     al,'H'
        je      pc_h
        cmp     al,'Z'
        je      pc_z
        jmp     pc_l
pc_q:
        mov     BYTE PTR cs:opt_quiet,1
        jmp     pc_l
pc_k:
        mov     BYTE PTR cs:opt_nohook,1
        jmp     pc_l
pc_u:
        mov     BYTE PTR cs:opt_umb,1
        jmp     pc_l
pc_t:
        mov     BYTE PTR cs:opt_test,1
        jmp     pc_l
pc_h:
        call    pc_colon
        call    pc_dec
        or      ax,ax
        jz      pc_l
        cmp     ax,MAXHANDLES
        ja      pc_l
        mov     cs:opt_handles,al
        jmp     pc_l
pc_z:
        mov     BYTE PTR cs:opt_nofill,1
        jmp     pc_l
pc_m:
        call    pc_colon
        call    pc_dec
        mov     cs:opt_limit,ax
        jmp     pc_l
pc_c:
        call    pc_colon
        call    pc_dec
        cmp     ax,64
        jb      pc_l                    ; слишком мало - оставить как было
        cmp     ax,16384
        ja      pc_l                    ; слишком много - оставить как было
        and     ax,0FFFEh               ; участок должен быть чётным
        mov     cs:opt_chunk,ax
        jmp     pc_l
pc_none:
pc_end:
        pop     ds
        mov     ax,cs:opt_chunk
        or      ax,ax
        jz      pc_ret
        mov     def_chunk,ax
pc_ret:
        ret
pc_colon:
        cmp     BYTE PTR ds:[si],':'
        jne     pcc_ret
        inc     si
pcc_ret:
        ret
pc_dec:
        push    bx
        push    cx
        push    dx
        xor     bx,bx
pcd_l:
        mov     al,ds:[si]
        cmp     al,'0'
        jb      pcd_done
        cmp     al,'9'
        ja      pcd_done
        sub     al,'0'
        xor     ah,ah
        mov     cx,ax
        mov     ax,bx
        mov     dx,10
        mul     dx
        add     ax,cx
        mov     bx,ax
        inc     si
        jmp     pcd_l
pcd_done:
        mov     ax,bx
        pop     dx
        pop     cx
        pop     bx
        ret
parse_cmdline   ENDP

;==============================================================================
;  check_guard - не переполнился ли стек за время установки
;==============================================================================
check_guard     PROC    NEAR
        cmp     stack_guard,0A5A5h
        je      cg_ok
        mov     dx,OFFSET m_guardbad
        call    puts
        ret
cg_ok:
        cmp     opt_quiet,0
        jne     cg_ret
        mov     dx,OFFSET m_guardok
        call    puts
cg_ret:
        ret
check_guard     ENDP

;==============================================================================
;  self_test - записать образец в первый и последний килобайт расширенной
;    памяти, прочитать обратно и сверить. Ловит неисправный модуль сразу.
;==============================================================================
self_test       PROC    NEAR
        mov     dx,OFFSET m_test
        call    puts
        ; первый килобайт: физический 100000h
        mov     WORD PTR src_phys,0
        mov     WORD PTR src_phys+2,0010h
        call    st_one
        jc      st_bad
        ; последний килобайт
        mov     ax,total_kb
        dec     ax
        call    kb_to_phys
        mov     WORD PTR src_phys,ax
        mov     WORD PTR src_phys+2,dx
        call    st_one
        jc      st_bad
        mov     dx,OFFSET m_testok
        call    puts
        ret
st_bad:
        mov     dx,OFFSET m_testbad
        call    puts
        ret
self_test       ENDP

;  st_one - записать и прочитать слово по адресу src_phys. CF=1 - не сошлось.
st_one          PROC    NEAR
        push    es
        mov     ax,WORD PTR src_phys
        and     ax,0FFFEh
        mov     dx,WORD PTR src_phys+2
        call    kvp_enter
        mov     bl,SEL_ES
        mov     bh,ACC_DATA
        mov     dx,WORD PTR src_phys+2
        mov     ax,WORD PTR src_phys
        and     ax,0FFFEh
        call    set_desc
        xor     ax,ax
        mov     es,ax
        xor     bx,bx
        mov     si,05A5Ah
        call    DWORD PTR cs:writer_ptr
        call    kvp_leave
        pop     es
        cmp     di,05A5Ah
        jne     st_fail
        clc
        ret
st_fail:
        stc
        ret
st_one          ENDP

;==============================================================================
;  init_top384 - пройти записью по верхним 384 Кбайт расширенной памяти
;
;  Эти 384 Кбайт - часть первого мегабайта на плате процессора, с контролем
;  чётности. Самотестирование проверяет их вместе со всей расширенной
;  памятью (ext_test_start), но проверку можно прервать клавишей Esc -
;  тогда непроверенные блоки остаются без установленных разрядов чётности,
;  и первое же чтение оттуда даст ошибку чётности. Заполнение - страховка
;  на этот случай; при полной проверке оно безвредно.
;
;  Признак того, что область прибавлена: остаток от деления объёма
;  на 1024 равен 384. Подпрограмма add_384k срабатывает только когда
;  объём до неё был кратен мегабайту.
;==============================================================================
init_top384     PROC    NEAR
        cmp     window_on,0
        jne     it_ret                  ; область в окне, её заполнил /U
        cmp     opt_nofill,0
        jne     it_ret
;  Признак берётся из ИСХОДНОГО значения БСУВВ. По урезанному ключом /M
;  его не определить: при /M:4400 остаток был бы 304, заполнение
;  пропускалось бы, а часть неинициализированной области раздавалась бы.
        mov     ax,raw_kb
        mov     dx,ax
        and     dx,03FFh                ; остаток от деления на 1024
        cmp     dx,384
        jne     it_ret                  ; область не прибавлялась
        sub     ax,384                  ; начало области в килобайтах
        cmp     total_kb,ax
        jbe     it_ret                  ; /M отрезал область целиком -
                                        ; раздаваться она не будет
        mov     dx,OFFSET m_top384
        call    puts
        call    kb_to_phys              ; DX:AX = физический адрес
        mov     WORD PTR cur_dst,ax
        mov     WORD PTR cur_dst+2,dx
        mov     cx,384/4                ; 96 кусков по 4 Кбайт
it_loop:
        push    cx
        mov     ax,WORD PTR cur_dst
        mov     dx,WORD PTR cur_dst+2
        and     ax,0FFFEh
        mov     bl,SEL_ES
        mov     bh,ACC_DATA
        call    set_desc
        xor     di,di
        mov     cx,2048                 ; 2048 слов = 4 Кбайт
        push    ds
        push    es
        call    kvp_enter
        call    DWORD PTR cs:filler_ptr
        call    kvp_leave
        pop     es
        pop     ds
        mov     ax,4096
        add     WORD PTR cur_dst,ax
        adc     WORD PTR cur_dst+2,0
        pop     cx
        loop    it_loop
        mov     dx,OFFSET m_top384ok
        call    puts
it_ret:
        ret
init_top384     ENDP

;==============================================================================
;  vdisk_here - не занял ли расширенную память драйвер VDISK
;
;  По описанию XMS признак VDISK лежит по физическому адресу 100012h.
;  Если он там есть, память уже роздана, и драйвер XMS ставиться не должен.
;==============================================================================
vdisk_here      PROC    NEAR
        push    es
        call    kvp_enter
        mov     bl,SEL_ES
        mov     bh,ACC_DATA
        mov     dx,0010h
        xor     ax,ax
        call    set_desc
        xor     ax,ax
        mov     es,ax
        mov     bx,12h
        call    DWORD PTR cs:prober_ptr ; SI = слово по 100012h
        call    kvp_leave
        pop     es
        cmp     si,4956h                ; 'VI' - первые два знака VDISK
        jne     vd_no
        stc
        ret
vd_no:
        clc
        ret
vdisk_here      ENDP

;==============================================================================
;  window_check - подана ли область 384 Кбайт в окно 0E000h
;
;  Порт 73h драйвер НЕ трогает: окно включает эмулятор команд 286, которому
;  оно нужно, чтобы разместиться по адресу 0E800h. Драйверу остаётся лишь
;  узнать, включено оно или нет.
;
;  Проверка: записать по 0E000h:0000 два разных образца и сверить. Два
;  нужны, чтобы отличить память от ПЗУ и от пустоты. Прежнее содержимое
;  возвращается на место.
;    Выход: CF=0 - окно включено, память там есть.
;==============================================================================
window_check    PROC    NEAR
        push    es
        push    cx
        push    dx
        mov     ax,0E000h
        mov     es,ax
        mov     cx,es:[0]               ; запомнить прежнее содержимое
        mov     dx,es:[2]
;  Проверка двумя СОСЕДНИМИ ячейками. Если памяти нет, чтение с шины
;  часто отдаёт последнее, что по ней проезжало, и проба "записал-прочёл"
;  по одному адресу такое не отличает. Здесь в две соседние ячейки
;  записываются разные значения, и каждая должна сохранить своё.
        mov     WORD PTR es:[0],05A5Ah
        mov     WORD PTR es:[2],0A5A5h
        jmp     short $+2
        mov     ax,es:[0]               ; запомнить для отчёта
        mov     cs:wc_got1,ax
        mov     ax,es:[2]
        mov     cs:wc_got2,ax
        cmp     WORD PTR es:[0],05A5Ah
        jne     wc_no
        cmp     WORD PTR es:[2],0A5A5h
        jne     wc_no
        mov     WORD PTR es:[0],0A5A5h  ; и наоборот, чтобы исключить ПЗУ
        mov     WORD PTR es:[2],05A5Ah
        jmp     short $+2
        cmp     WORD PTR es:[0],0A5A5h
        jne     wc_no
        cmp     WORD PTR es:[2],05A5Ah
        jne     wc_no
        mov     es:[0],cx               ; вернуть прежнее содержимое
        mov     es:[2],dx
        pop     dx
        pop     cx
        pop     es
        clc
        ret
wc_no:
        mov     es:[0],cx
        mov     es:[2],dx
        pop     dx
        pop     cx
        pop     es
        stc
        ret
window_check    ENDP

;==============================================================================
;  probe_umb - отдать свободную часть окна как верхний блок (ключ /U)
;==============================================================================
probe_umb       PROC    NEAR
;  Немаскируемое прерывание запрещается на ВСЁ время пробы и разрешается
;  единственный раз, в самом конце, после сброса защёлок ошибки чётности.
;  Прерывания процессора при этом остаются разрешёнными: вывод сообщений
;  идёт через DOS. Прежде NMI разрешалось посреди пробы, и защёлка,
;  взведённая обращением к несуществующей памяти, срабатывала именно там.
        mov     umb_para,0
        mov     dx,OFFSET m_umbsw
        call    puts
        xor     al,al
        out     CMOS_PORT,al            ; NMI запрещено до самого конца
        jmp     short $+2
        in      al,73h
        jmp     short $+2
;  Разряд 4 порта 73h ЧИТАЕТСЯ - проверено на машине: после записи F4h
;  чтение даёт F4h, после восстановления снова E4h. По схеме разряды 0-3
;  выдаёт на шину буфер DD78, а разряд 4 - отдельный буфер DD140 (К555ЛП8)
;  по тому же сигналу 73RD. Поэтому состояние окна можно не угадывать, а
;  прочитать, и порт восстанавливается точно таким, каким был. Разряды 5-7
;  в регистре отсутствуют и читаются единицами - их отбрасываем.
        and     al,01Fh
        mov     old73,al
        mov     subbed,0
        test    al,010h                 ; окно уже включено?
        jz      pu_off
        mov     window_on,1
pu_off:
        cmp     window_on,0
        jne     pu_on                   ; окно уже включено кем-то
;------ включить окно: разряд 4 в единицу, разряды 1-3 в ноль --------------
        and     al,01h                  ; разряд 0 сохранить
        or      al,10h
        out     73h,al
        jmp     short $+2
        call    window_check
        jc      pu_failed
        mov     window_on,1
;  Сколько расширенной памяти остаётся, когда область 384 Кбайт ушла
;  в окно. Считать от ИСХОДНОГО значения БСУВВ, а не от урезанного ключом
;  /M: область лежит на самом верху, и если /M уже отрезал её, вычитать
;  нечего. Если же БСУВВ область не прибавляла вовсе (объём не был кратен
;  мегабайту), то и из расширенной памяти ей уходить неоткуда.
        mov     ax,raw_kb
        mov     dx,ax
        and     dx,03FFh
        cmp     dx,384
        jne     pu_said                 ; БСУВВ область не прибавляла
        sub     ax,384                  ; предел без области
        cmp     total_kb,ax
        jbe     pu_said                 ; /M уже ограничил сильнее
        mov     bx,total_kb
        mov     prev_total,bx           ; для отката
        mov     total_kb,ax
        mov     subbed,1
pu_said:
        mov     dx,OFFSET m_umbcost
        call    puts
        mov     ax,total_kb
        call    put_dec
        mov     dx,OFFSET m_kb
        call    puts
pu_on:
        call    m286_here               ; эмулятор 286 владеет окном целиком
        jnc     pu_free
        mov     dx,OFFSET m_umb286
        call    puts
        jmp     pu_undo                 ; вернуть всё как было
pu_free:
        mov     umb_limit,4             ; всё окно, 4 блока по 16 Кбайт
        call    umb_prepare
        or      ax,ax
        jz      pu_empty
        mov     umb_seg,0E000h
        mov     umb_para,ax
        mov     dx,OFFSET m_umbfill
        call    puts
        mov     dx,OFFSET m_umbok
        call    puts
        mov     ax,umb_para
        mov     cl,6
        shr     ax,cl                   ; параграфы -> килобайты
        call    put_dec
        mov     dx,OFFSET m_umbkb
        call    puts
        mov     dx,OFFSET m_umbwarn
        call    puts
        jmp     short pu_done
;------ неудача: вернуть порт, объём памяти и признак окна ------------------
pu_empty:
        mov     dx,OFFSET m_umbno
        call    puts
        jmp     short pu_undo
pu_failed:
        mov     dx,OFFSET m_umboff
        call    puts
        mov     dx,OFFSET m_wcgot       ; что именно прочиталось из окна
        call    puts
        mov     ax,wc_got1
        call    put_hex16
        mov     dx,OFFSET m_wcand
        call    puts
        mov     ax,wc_got2
        call    put_hex16
        mov     dx,OFFSET m_wcexp
        call    puts
pu_undo:
        mov     al,old73                ; порт 73h - как был
        out     73h,al
        jmp     short $+2
        mov     window_on,0
        mov     umb_para,0
        cmp     subbed,0
        je      pu_done
        mov     bx,prev_total           ; вернуть прежний объём
        mov     total_kb,bx
        mov     subbed,0
        mov     dx,OFFSET m_umbgiveback
        call    puts
        mov     ax,total_kb
        call    put_dec
        mov     dx,OFFSET m_kb
        call    puts
;------ единственное место, где NMI разрешается обратно --------------------
pu_done:
        call    parity_reset            ; снять защёлки ошибки чётности
        mov     al,80h
        out     CMOS_PORT,al            ; и только теперь разрешить NMI
        jmp     short $+2
        ret
probe_umb       ENDP


;==============================================================================
;  m286_here - похоже ли, что эмулятор команд 286 уже загружен.
;    Его обработчик INT 06h находится в сегменте 0E800h.
;    Выход: CF=1 - похоже, что стоит. AX сохраняется.
;==============================================================================
m286_here       PROC    NEAR
        push    ax
        push    ds
        xor     ax,ax
        mov     ds,ax
        mov     ax,ds:[06h*4+2]         ; сегмент обработчика INT 06h
        pop     ds
        cmp     ax,0E000h
        jb      m2_no
        cmp     ax,0EFFFh
        ja      m2_no
        pop     ax
        stc
        ret
m2_no:
        pop     ax
        clc
        ret
m286_here       ENDP

;==============================================================================
;  umb_prepare - подготовить окно к раздаче и заодно проверить память
;
;  Заполнение - страховка. У памяти с контролем чётности, в которую
;  ни разу не писали после включения питания, разряды чётности не
;  установлены, и первое же ЧТЕНИЕ даёт ошибку чётности: при разрешённом
;  NMI - остановку машины обработчиком БСУВВ. Записью разряд чётности
;  устанавливается, и дальше ячейка читается нормально.
;
;  Самотестирование проверяет эти 384 Кбайт вместе со всей расширенной
;  памятью, пока они стоят выше мегабайта. Но проверку можно прервать
;  клавишей Esc, а при горячей перезагрузке она не выполняется вовсе.
;  Поэтому драйвер, подав область в окно, проходит по ней записью сам:
;  при полной проверке это безвредно, при пропущенной - необходимо.
;
;  Ровно это делает и загрузчик эмулятора команд 286: он заполняет все
;  64 Кбайт числом 55h и лишь потом кладёт туда себя.
;
;    вход:  umb_limit - сколько блоков по 16 Кбайт брать
;    выход: AX = размер годной памяти в параграфах
;==============================================================================
umb_prepare     PROC    NEAR
        push    es
        xor     bx,bx                   ; число готовых блоков
        mov     dx,0E000h
up_l:
        mov     es,dx
        cld
        xor     di,di                   ; заполнить блок нулями: этим
        xor     ax,ax                   ; устанавливаются разряды чётности
        mov     cx,2000h                ; 8192 слова = 16 Кбайт
        rep     stosw
        xor     di,di                   ; и убедиться, что всё легло
        xor     ax,ax
        mov     cx,2000h
        repe    scasw
        jne     up_done                 ; ячейка не сохранила записанное
        or      cx,cx
        jnz     up_done
        inc     bx
        add     dx,400h                 ; следующие 16 Кбайт
        mov     al,umb_limit
        xor     ah,ah
        cmp     bx,ax
        jb      up_l
up_done:
        mov     ax,bx
        mov     cl,10
        shl     ax,cl                   ; блоки по 16К -> параграфы
        pop     es
        ret
umb_prepare     ENDP


;------ вывод сообщений при установке ---------------------------------------
puts            PROC    NEAR
        push    ax
        push    ds
        push    cs
        pop     ds
        mov     ah,9
        int     21h
        pop     ds
        pop     ax
        ret
puts            ENDP

crlf            PROC    NEAR
        push    dx
        mov     dx,OFFSET m_crlf
        call    puts
        pop     dx
        ret
crlf            ENDP

putc            PROC    NEAR
        push    ax
        push    dx
        mov     dl,al
        mov     ah,2
        int     21h
        pop     dx
        pop     ax
        ret
putc            ENDP

put_dec         PROC    NEAR
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx,10
        xor     cx,cx
pd1:    xor     dx,dx
        div     bx
        push    dx
        inc     cx
        or      ax,ax
        jnz     pd1
pd2:    pop     ax
        add     al,'0'
        call    putc
        loop    pd2
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
put_dec         ENDP

put_hex16       PROC    NEAR
        push    ax
        push    cx
        mov     cx,4
ph_l:   rol     ax,1
        rol     ax,1
        rol     ax,1
        rol     ax,1
        push    ax
        and     al,0Fh
        add     al,'0'
        cmp     al,'9'
        jbe     ph_ok
        add     al,7
ph_ok:  call    putc
        pop     ax
        loop    ph_l
        mov     al,'h'
        call    putc
        pop     cx
        pop     ax
        ret
put_hex16       ENDP

opt_limit       dw      0
opt_chunk       dw      0
opt_quiet       db      0
opt_nohook      db      0
opt_umb         db      0
opt_test        db      0
opt_handles     db      0
opt_nofill      db      0
umb_limit       db      4
m286_seen       db      0
window_on       db      0
raw_kb          dw      0
prev_total      dw      0
subbed          db      0

m_crlf          db      13,10,'$'
m_banner        db      13,10,'ECXMS 1.21 - EC-1842 extended memory via the KVP',13,10,'$'
m_mon           db      'M286 monitor found: moves via INT 15h, HMA reported busy',13,10,'$'
m_raw           db      'INT 15H AH=88h returned: $'
m_found         db      'Extended memory found: $'
m_kb            db      ' KB',13,10,'$'
m_stub          db      'Move window placed at physical address $'
m_ok            db      'Driver installed. HMA and UMB are not available.',13,10,'$'
m_ok_umb        db      'Driver installed with an upper memory block. HMA is not',13,10
                db      'available on this machine.',13,10,'$'
m_already       db      'An XMS driver is already installed.',13,10,'$'
m_nomem         db      'No extended memory found.',13,10,'$'
m_vdisk         db      'A VDISK driver already owns the extended memory.',13,10,'$'
m_top384        db      'Top 384 KB: setting parity bits (the memory test may have been skipped)... $'
m_top384ok      db      'done.',13,10,'$'
m_help          db      'Switches: /M:nnn limit memory, /C:nnn move chunk size,',13,10
                db      '          /U upper memory block, /T self test, /H:nn handles,',13,10
                db      '          /K keep INT 15H, /Z skip filling the top 384 KB, /Q quiet.',13,10,'$'
m_test          db      'Self test of extended memory... $'
m_testok        db      'passed.',13,10,'$'
m_testbad       db      'FAILED. The memory does not read back what was written.',13,10,'$'
m_win           db      'The 384 KB block is in the 0E000h window, so it is NOT extended',13,10
                db      'memory. Extended memory corrected to $'
m_umbsw         db      'Switching the 384 KB block into the 0E000h window...',13,10,'$'
m_umbcost       db      'The whole 384 KB left extended memory for it. Extended is now $'
m_umboff        db      'No UMB: the window stayed empty, port 73h restored.',13,10,'$'
m_umbno         db      'No UMB: nothing usable answered in the window.',13,10,'$'
m_umbgiveback   db      'Everything put back. Extended memory is again $'
m_wcgot         db      'Window test read back $'
m_wcand         db      ' and $'
m_wcexp         db      ' (expected 5A5Ah and A5A5h).',13,10,'$'
m_umbfill       db      'Window filled with zeroes: parity bits set, memory verified.',13,10,'$'
m_umbok         db      'Upper memory block at 0E000h, $'
m_umbkb         db      ' KB.',13,10,'$'
m_umb286        db      'No UMB: the 286 instruction emulator owns the whole 0E000h',13,10
                db      'window - it fills all 64 KB with 55h when it loads.',13,10,'$'
m_umbwarn       db      'Do NOT run M286.COM while this block is in use: it fills the',13,10
                db      'whole 0E000h window with 55h before loading itself.',13,10,'$'
m_toohigh       db      'Driver loaded above 64 KB, there is nowhere to put the move',13,10
                db      'window. Move this line earlier in CONFIG.SYS.',13,10,'$'
m_notinst       db      'Driver NOT installed.',13,10,'$'
m_guardok       db      'Stack guard intact.',13,10,'$'
m_guardbad      db      'WARNING: stack guard damaged, more than 2048 bytes of',13,10
                db      'stack were used. Report this.',13,10,'$'

;==============================================================================
;  ПОВЕДЕНИЕ В АВАРИЙНЫХ СЛУЧАЯХ
;
;  1. Расширенной памяти нет. INT 15H AH=88h вернёт 0, драйвер сообщит
;     об этом и не останется в памяти: поле адреса конца в заголовке
;     запроса ставится в CS:0000.
;
;  2. Драйвер загружен выше 64 Кбайт. Окно переноса разместить негде,
;     драйвер отказывается устанавливаться. Проверяется и сам сегмент,
;     и адрес конца обеих заглушек, и переполнение при сложении.
;
;  3. КВП не отвечает или отвечает иначе. Первая проба читает из ПЗУ
;     слово, которое там заведомо лежит. Если прочиталось не оно,
;     драйвер не устанавливается. Проба только читает и только из ПЗУ,
;     испортить ничего не может.
;
;  4. Другой драйвер XMS уже установлен. Проверяется через INT 2Fh
;     AX=4300h до всякой работы с оборудованием.
;
;  5. Неверный описатель или смещение в функции переноса. Проверяются
;     до единого обращения к КВП: описатель должен быть ненулевым,
;     кратным восьми, в пределах таблицы и помеченным занятым; смещение
;     вместе с длиной переноса не должно выходить за размер блока.
;     Возвращается код ошибки, память не трогается.
;
;  6. Нечётная длина переноса. Отвергается кодом 0A7h до обращения
;     к оборудованию: пересылка идёт словами.
;
;  7. Наложение областей. Если приёмник выше источника и расстояние
;     между ними меньше длины, обход идёт с конца, а участок берётся
;     не длиннее расстояния - тогда участок не может налезть сам на себя.
;     При расстоянии в один байт участок берётся в два байта: при обходе
;     с конца это безопасно, потому что второй байт участка уже прочитан
;     в регистр, а третий принадлежит уже перенесённой части.
;
;  8. Прерывание во время открытого окна. Невозможно: прерывания
;     запрещены командой CLI, немаскируемое - записью нуля в порт 70h.
;     Окно закрывается раньше, чем разрешаются прерывания. Длина окна
;     не больше 4 Кбайт, то есть около 5 мс при 8 МГц - меньше периода
;     системного таймера, поэтому тики не теряются.
;
;  9. Обращение к стеку при открытом окне. Внутри окна нет ни одной
;     команды, работающей со стеком: ни push, ни pop, ни call, ни ret.
;     Дальний возврат выполняется уже после закрытия окна.
;
; 10. Уход выборки команд "не туда". Заглушка вызывается как
;     FAR 0000:адрес при нулевой базе дескриптора CS. Физический адрес
;     выборки равен смещению при обеих возможных моделях поведения КВП.
;
; 11. Состояние КВП после работы. Дескриптор CS возвращается в то
;     состояние, в каком его оставляет KVP_init БСУВВ (база 0F0000h,
;     граница 0), иначе следующий вызов INT 15H AH=87h из БСУВВ
;     работал бы неправильно. Разряд VF снимается до возврата.
;
; 12. Переполнение счётчика запираний блока. При 255 возвращается
;     ошибка 0ACh, счётчик не переполняется.
;
; 13. Освобождение запертого блока. Возвращается ошибка 0ABh,
;     блок остаётся на месте.
;
; 14. Изменение размера запертого блока. Возвращается ошибка 0ABh.
;     При увеличении сначала ищется новое место, и только если оно
;     найдено, содержимое переносится; при неудаче старый блок остаётся
;     нетронутым.
;
; 15. Зацикливание в поиске места. Проба сдвигается только вперёд и
;     только за конец занятого блока; занятых блоков не больше 32,
;     поэтому число сдвигов ограничено.
;==============================================================================

CODE    ENDS
        END
