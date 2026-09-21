/* exact-sized allocations + byte-for-byte, over the whole small-shape corner where the
 * aligned window leaves the tensor and several rows share a word. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
void mmb_a(const int8_t*, const int8_t*, int8_t*, int,int,int,int, float,float,float, int,float, int,int);
void mmb_c(const int8_t*, const int8_t*, int8_t*, int,int,int,int, float,float,float, int,float, int,int);
static uint64_t rs=0x9e3779b97f4a7c15ull;
static uint32_t rnd(void){ rs^=rs<<13; rs^=rs>>7; rs^=rs<<17; return (uint32_t)(rs>>32);} 
int main(void){
    long n=0,bad=0;
    for(int K=1;K<=40;K++) for(int N=1;N<=20;N++) for(int B=1;B<=3;B++)
      for(int tb=0;tb<2;tb++) for(int off=0;off<8;off++){
        size_t na=(size_t)B*K, nb=(size_t)B*K*N, no=(size_t)B*N;
        int8_t *A=malloc(na+off), *Bb=malloc(nb+off), *OA=malloc(no), *OC=malloc(no);
        for(size_t i=0;i<na+off;i++) A[i]=(int8_t)(rnd()&0xff);
        for(size_t i=0;i<nb+off;i++) Bb[i]=(int8_t)(rnd()&0xff);
        mmb_a(A+off,Bb+off,OA,B,1,K,N,0.0463244766f,0.0231922641f,0.0595385246f,tb,6.0f,-128,127);
        mmb_c(A+off,Bb+off,OC,B,1,K,N,0.0463244766f,0.0231922641f,0.0595385246f,tb,6.0f,-128,127);
        if(memcmp(OA,OC,no)){ bad++; if(bad<5) printf("FAIL K=%d N=%d B=%d tb=%d off=%d\n",K,N,B,tb,off); }
        free(A);free(Bb);free(OA);free(OC); n++;
      }
    printf("SAN2 cases=%ld failing=%ld verdict=%s\n",n,bad,bad?"FAIL":"PASS"); return bad?1:0;
}
