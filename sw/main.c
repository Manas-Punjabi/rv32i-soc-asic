/* main.c — matrix-multiply benchmark: software vs the APB accelerator.
 *
 * Reports, over the UART, per multiply:
 *   software cycles            soft_matmul() on the core
 *   accelerator cycles         load + run + readback, and each phase separately
 *   bus-transfer share         (load + readback) / total
 *
 * Two things this measurement deliberately makes visible, because either one
 * hidden would flatter the accelerator:
 *
 *  1. The core implements RV32I with no M extension, so every `*` in
 *     soft_matmul is a call to libgcc's __mulsi3 (a shift-add loop). The
 *     speedup below is against software multiplication, not against a core
 *     with a hardware multiplier, and the report says so.
 *  2. Polling STATUS until done is itself APB traffic. It is timed as its own
 *     phase ("run (incl. polling)") instead of being folded into compute, so
 *     the data-movement figure is not understated.
 *
 * All timing comes from the timer peripheral's mtime, not rdcycle/rdinstret:
 * rv32i-soc-validation co-simulates this image against Spike, which cannot be made to
 * agree on CSR counters but is fed MMIO reads by the harness.
 */
#include "soc.h"

#define N     4
#define NN    (N * N)
#define REPS  16                /* averaged, so timer-read overhead is diluted */

/* ---- UART output ------------------------------------------------------- */
static void put_str(const char *s) { uart_puts(s); }

static void put_u32(uint32_t v)
{
    char buf[11];
    int  i = 0;
    if (v == 0) { uart_putc('0'); return; }
    while (v) { buf[i++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (i) uart_putc(buf[--i]);
}

/* one decimal place: prints num/den as d.d */
static void put_ratio(uint32_t num, uint32_t den)
{
    uint32_t t = den ? (num * 10u) / den : 0u;
    put_u32(t / 10u);
    uart_putc('.');
    put_u32(t % 10u);
}

/* percent with one decimal */
static void put_pct(uint32_t part, uint32_t whole)
{
    uint32_t t = whole ? (part * 1000u) / whole : 0u;
    put_u32(t / 10u);
    uart_putc('.');
    put_u32(t % 10u);
    uart_putc('%');
}

/* ---- benchmark --------------------------------------------------------- */
static uint32_t A[NN], B[NN], C_soft[NN], C_accel[NN];

/* accelerator run split into phases, so data movement and synchronization
 * are counted separately. Returns the three phase times. */
static void accel_phases(const uint32_t *a, const uint32_t *b, uint32_t *c,
                         uint32_t *t_load, uint32_t *t_run, uint32_t *t_read)
{
    uint32_t t0, t1, t2, t3;

    t0 = (uint32_t)timer_now();
    for (unsigned i = 0; i < NN; i++) {
        REG(ACCEL_A(i)) = a[i];
        REG(ACCEL_B(i)) = b[i];
    }
    t1 = (uint32_t)timer_now();

    REG(ACCEL_CTRL) = ACCEL_START;
    while (!(REG(ACCEL_STATUS) & ACCEL_DONE))
        ;
    t2 = (uint32_t)timer_now();

    for (unsigned i = 0; i < NN; i++)
        c[i] = REG(ACCEL_C(i));
    t3 = (uint32_t)timer_now();

    REG(ACCEL_STATUS) = ACCEL_DONE;     /* clear sticky done */

    *t_load = t1 - t0;
    *t_run  = t2 - t1;
    *t_read = t3 - t2;
}

int main(void)
{
    uint32_t seed = 12345u;
    uint32_t params, t0, t1, overhead;
    uint32_t soft_total = 0, load_total = 0, run_total = 0, read_total = 0;
    uint32_t soft, accel_total, data_total;

    REG(UART_DIV) = 16;                 /* matches tb_soc's monitor */

    put_str("rv32i-soc-asic matmul benchmark\r\n");

    params = REG(ACCEL_PARAMS);
    if ((params & 0xffu) != N) {
        put_str("FAIL: accelerator N mismatch\r\n");
        return 1;
    }

    /* cost of one timer_now() pair, subtracted from each phase below */
    t0 = (uint32_t)timer_now();
    t1 = (uint32_t)timer_now();
    overhead = t1 - t0;

    for (unsigned r = 0; r < REPS; r++) {
        uint32_t tl, tr, trd;

        for (unsigned i = 0; i < NN; i++) {
            seed = seed * 1103515245u + 12345u;     /* also via __mulsi3 */
            A[i] = (seed >> 16) & 0xffu;
            seed = seed * 1103515245u + 12345u;
            B[i] = (seed >> 16) & 0xffu;
        }

        t0 = (uint32_t)timer_now();
        soft_matmul(A, B, C_soft, N);
        t1 = (uint32_t)timer_now();
        soft_total += (t1 - t0) - overhead;

        accel_phases(A, B, C_accel, &tl, &tr, &trd);
        load_total += tl - overhead;
        run_total  += tr - overhead;
        read_total += trd - overhead;

        for (unsigned i = 0; i < NN; i++) {
            if (C_soft[i] != C_accel[i]) {
                put_str("FAIL: result mismatch at ");
                put_u32(i);
                put_str("\r\n");
                return 2;
            }
        }
    }

    soft        = soft_total / REPS;
    load_total /= REPS;
    run_total  /= REPS;
    read_total /= REPS;
    accel_total = load_total + run_total + read_total;
    data_total  = load_total + read_total;

    put_str("results match over ");
    put_u32(REPS);
    put_str(" runs, N=");
    put_u32(N);
    put_str("\r\ncycles per multiply (mtime, timer-read overhead removed)\r\n");

    put_str("  software (no M ext, __mulsi3): ");
    put_u32(soft);
    put_str("\r\n  accelerator total:             ");
    put_u32(accel_total);
    put_str("\r\n    load  32 writes:             ");
    put_u32(load_total);
    put_str("\r\n    run   (incl. polling):       ");
    put_u32(run_total);
    put_str("\r\n    read  16 reads:              ");
    put_u32(read_total);
    put_str("\r\n  speedup vs software multiply:  ");
    put_ratio(soft, accel_total);
    put_str("x\r\n  bus data movement:             ");
    put_pct(data_total, accel_total);
    put_str(" of the accelerated path\r\n");

    put_str("BENCH OK\r\n");
    return 0;
}
