/* SPDX-License-Identifier: Apache-2.0 */
/* B86 -- retired instructions in the two attention image builders, at the ENCODER's own head
 * shape (M=165, Dk=Dv=36, S=165 -> gs=5, qs=42, gp=21, qp=9).  Both arms are the SHIPPED
 * kernel's own builders, extracted at gate time into builders.inc and compiled twice.
 * Driven by b86_attn_gate.sh; see B86_ATTN_BAND.md. */
#include <stdint.h>
#include <stddef.h>
void htif_puts(const char *s); void htif_putu(uint64_t v); void htif_exit(int code);

#define mbxa_build_q bq_ship
#define mbxa_build_w bw_ship
#define mbxa_width wd_s
#define mbxa_run rn_s
#define mbxa_zrun zr_s
#define mbxa_u32 u32_s
#define mbxa_u64 u64_s
#define MBP_B86 0
#include "builders.inc"
#undef mbxa_build_q
#undef mbxa_build_w
#undef mbxa_width
#undef mbxa_run
#undef mbxa_zrun
#undef mbxa_u32
#undef mbxa_u64
#undef MBP_B86
#define mbxa_build_q bq_b86
#define mbxa_build_w bw_b86
#define mbxa_width wd_b
#define mbxa_run rn_b
#define mbxa_zrun zr_b
#define mbxa_u32 u32_b
#define mbxa_u64 u64_b
#define MBP_B86 1
#include "builders.inc"

static int8_t q[200*64] __attribute__((aligned(64)));
static int8_t k[1100*64] __attribute__((aligned(64)));
static int8_t v[1100*64] __attribute__((aligned(64)));
static int8_t qi[1024*8] __attribute__((aligned(64)));
static int8_t wi[4*512*8] __attribute__((aligned(64)));
static uint64_t rs=0x9E3779B97F4A7C15ull;
static uint64_t rnd(void){rs^=rs<<13;rs^=rs>>7;rs^=rs<<17;return rs;}
static inline uint64_t mi(void){uint64_t x;__asm__ volatile("csrr %0, minstret":"=r"(x));return x;}
static uint64_t ovh;
static void row(const char*a,const char*p,uint64_t n){
  htif_puts("MB_B86_ATTN arm=");htif_puts(a);htif_puts(" part=");htif_puts(p);
  htif_puts(" instret=");htif_putu(n);htif_puts("\n");}
#define T_(c,a,p) do{uint64_t t0=mi();c;uint64_t t1=mi();row(a,p,t1-t0-ovh);}while(0)

int main(void){
  int i; int64_t b = (int64_t)1 << 40;
  for(i=0;i<8;i++){uint64_t x=mi(),y=mi(); if((int64_t)(y-x)<b) b=(int64_t)(y-x);} ovh=b;
  for(i=0;i<200*64;i++) q[i]=(int8_t)(rnd()&0xff);
  for(i=0;i<1100*64;i++) k[i]=(int8_t)(rnd()&0xff);
  for(i=0;i<1100*64;i++) v[i]=(int8_t)(rnd()&0xff);
  /* the ENCODER's head shape: M=165, Dk=Dv=36, S=165 -> gs=5 qs=42 gp=21 qp=9 */
  {int T=165,D=36,N=165,gs=5,qs=42,gp=21,qp=9,lgpw=9,kb=0,vt=252;
   T_(bq_ship(q,T,D,gs,qi),"ship","q");
   T_(bq_b86 (q,T,D,gs,qi),"b86","q");
   T_(bw_ship(k,v,N,D,gs,qs,gp,qp,lgpw,kb,vt,wi),"ship","w");
   T_(bw_b86 (k,v,N,D,gs,qs,gp,qp,lgpw,kb,vt,wi),"b86","w");}
  htif_exit(0); return 0;
}
