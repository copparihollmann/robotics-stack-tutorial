/* B101 -- rope_s8 head-granularity hook: bit-exactness gate and instruction account.
 * Three builds of the SAME kernel linked together: the pre-change file, MBP_B101R=0, and
 * MBP_B101R=1 with a live hook that counts calls.  Encoder and decoder shapes. */
#include <stdint.h>
#include <stddef.h>
void htif_puts(const char *s); void htif_putu(uint64_t v); void htif_exit(int code);

void rope_pre(const int8_t *, const float *, const float *, int8_t *, int,int,int,int, float,float,int,int);
void rope_off(const int8_t *, const float *, const float *, int8_t *, int,int,int,int, float,float,int,int);
void rope_on (const int8_t *, const float *, const float *, int8_t *, int,int,int,int, float,float,int,int);
typedef void (*yfn)(void *);
void mbp_rope_set_yield(yfn, void *);

#define TMAX 200
#define HMAX 8
#define DMAX 40
#define NB (TMAX*HMAX*DMAX)
static int8_t xin[NB], ya[NB], yb[NB], yc[NB];
static float ctab[TMAX*32], stab[TMAX*32];
static uint64_t ycount;
static void ycb(void *p){ (void)p; ycount++; }
static inline uint64_t rd(void){ uint64_t v; __asm__ volatile("csrr %0, minstret":"=r"(v)); return v; }
static void line(const char *t, uint64_t v){ htif_puts(t); htif_putu(v); htif_puts("\n"); }
static float bits(uint32_t u){ float f; __builtin_memcpy(&f,&u,4); return f; }

static int cmp(const int8_t *p, const int8_t *q, int n){ int d=0,i; for(i=0;i<n;i++) if(p[i]!=q[i]) d++; return d; }

static void shape(const char *tag, int T,int H,int D,int R, float si, float so, int amin,int amax)
{
    int n=T*H*D, i; uint64_t a,b,ovh;
    for(i=0;i<n;i++) xin[i]=(int8_t)((i*37)%251-125);
    for(i=0;i<T*(R/2);i++){ ctab[i]=(float)(0.5+0.4*((i*29)%101)/101.0); stab[i]=(float)(-0.5+0.4*((i*53)%97)/97.0); }
    for(i=0;i<n;i++){ ya[i]=1; yb[i]=2; yc[i]=3; }
    mbp_rope_set_yield(0,0);
    rope_pre(xin,ctab,stab,ya,T,H,D,R,si,so,amin,amax);
    rope_off(xin,ctab,stab,yb,T,H,D,R,si,so,amin,amax);
    ycount=0; mbp_rope_set_yield(ycb,0);
    rope_on (xin,ctab,stab,yc,T,H,D,R,si,so,amin,amax);
    mbp_rope_set_yield(0,0);
    htif_puts(tag); htif_puts(" pre_vs_off_differing="); htif_putu((uint64_t)cmp(ya,yb,n));
    htif_puts(" pre_vs_ON_differing="); htif_putu((uint64_t)cmp(ya,yc,n));
    htif_puts(" yields="); htif_putu(ycount); htif_puts(" expected="); htif_putu((uint64_t)(T*H));
    htif_puts("\n");
    /* NEGATIVE CONTROL: the comparator must be able to see a difference. */
    yc[n/2] ^= 1;
    htif_puts(tag); htif_puts(" NEGCTL_one_byte_flipped_differing="); htif_putu((uint64_t)cmp(ya,yc,n)); htif_puts("\n");
    a=rd(); b=rd(); ovh=b-a;
    a=rd(); rope_off(xin,ctab,stab,yb,T,H,D,R,si,so,amin,amax); b=rd();
    htif_puts(tag); htif_puts(" instr_OFF="); htif_putu(b-a-ovh); htif_puts("\n");
    ycount=0; mbp_rope_set_yield(ycb,0);
    a=rd(); rope_on(xin,ctab,stab,yc,T,H,D,R,si,so,amin,amax); b=rd();
    mbp_rope_set_yield(0,0);
    htif_puts(tag); htif_puts(" instr_ON_hooked="); htif_putu(b-a-ovh); htif_puts("\n");
    a=rd(); rope_on(xin,ctab,stab,yc,T,H,D,R,si,so,amin,amax); b=rd();
    htif_puts(tag); htif_puts(" instr_ON_null="); htif_putu(b-a-ovh); htif_puts("\n");
}

int main(void)
{
    float si=bits(0x3C3F86DCu), so=bits(0x3CCA4B3Du);
    shape("ENC_T165_H8_D36_R32", 165,8,36,32, si,so,-128,127);
    shape("DEC_T1_H8_D36_R32",     1,8,36,32, si,so,-128,127);
    shape("ENC_clamped",         165,8,36,32, si,so,-100,100);
    htif_exit(0); return 0;
}
