/* B59 host gate: the M=1 specialisation against the shipping kernel and against the
 * general (unspecialised) nest, BYTE FOR BYTE, at the decoder's shapes and at random ones. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

void mmb_a(const int8_t*, const int8_t*, int8_t*, int,int,int,int, float,float,float, int,float, int,int);
void mmb_b(const int8_t*, const int8_t*, int8_t*, int,int,int,int, float,float,float, int,float, int,int);
void mmb_c(const int8_t*, const int8_t*, int8_t*, int,int,int,int, float,float,float, int,float, int,int);

static uint64_t rs = 0x243f6a8885a308d3ull;
static uint32_t rnd(void){ rs ^= rs<<13; rs ^= rs>>7; rs ^= rs<<17; return (uint32_t)(rs>>32); }

static int8_t *A, *Bm, *OA, *OB, *OC;
static long ncase, nbad;

static int one(int B,int M,int K,int N,int tb,float sa,float sb,float so,float sd,int lo,int hi,const char *tag)
{
    size_t na=(size_t)B*M*K, nb=(size_t)B*K*N, no=(size_t)B*M*N, i;
    for(i=0;i<na;i++) A[i]=(int8_t)(rnd()&0xff);
    for(i=0;i<nb;i++) Bm[i]=(int8_t)(rnd()&0xff);
    memset(OA,0x5a,no); memset(OB,0x5a,no); memset(OC,0x5a,no);
    mmb_a(A,Bm,OA,B,M,K,N,sa,sb,so,tb,sd,lo,hi);
    mmb_b(A,Bm,OB,B,M,K,N,sa,sb,so,tb,sd,lo,hi);
    mmb_c(A,Bm,OC,B,M,K,N,sa,sb,so,tb,sd,lo,hi);
    ncase++;
    int bad=0; size_t first=0; int da=0,dc=0;
    for(i=0;i<no;i++){
        if(OA[i]!=OB[i]||OA[i]!=OC[i]){ if(!bad){first=i;da=OA[i]-OB[i];dc=OA[i]-OC[i];} bad++; }
    }
    if(bad){ nbad++; printf("FAIL %-10s B=%d M=%d K=%d N=%d tb=%d bad=%d/%zu first=%zu a-b=%d a-c=%d\n",
            tag,B,M,K,N,tb,bad,no,first,da,dc); }
    return bad;
}

int main(void)
{
    A=malloc(1<<22); Bm=malloc(1<<22); OA=malloc(1<<22); OB=malloc(1<<22); OC=malloc(1<<22);
    /* 1. the decoder's own dispatches, scales verbatim from gen/model.c */
    one(8,1,36,1,   1, 0.02616488f,0.0518032201f,0.0337884985f,6.0f,-128,127,"dec.self.qk");
    one(8,1,1,36,   0, 0.00787401572f,0.000594942016f,0.000594942016f,1.0f,-128,127,"dec.self.pv");
    one(8,1,36,165, 1, 0.0463244766f,0.0231922641f,0.0595385246f,6.0f,-128,127,"dec.cross.qk");
    one(8,1,165,36, 0, 0.00787401572f,0.0115726721f,0.005805308f,1.0f,-128,127,"dec.cross.pv");
    /* the same product after ir_vlayout flips V's last two axes (B62) -- the shape that
     * ships once --vlayout is on, and the one B68's unrolled word loop runs at T = 21/22 */
    one(8,1,165,36, 1, 0.00787401572f,0.0115726721f,0.005805308f,1.0f,-128,127,"dec.cross.pv.tb1");
    /* the growing self-attention cache, every step the run actually issues */
    for(int n=1;n<=24;n++) one(8,1,36,n,1,0.0463244766f,0.0231922641f,0.0595385246f,6.0f,-128,127,"dec.self.qk.N");
    for(int k=1;k<=24;k++) one(8,1,k,36,0,0.00787401572f,0.0115726721f,0.005805308f,1.0f,-128,127,"dec.self.pv.K");
    /* 2. the encoder's shapes, which must NOT take the new path */
    one(8,165,36,165,1, 0.0756474882f,0.0984255448f,0.280755699f,6.0f,-128,127,"enc.qk");
    one(8,165,165,36,0, 0.00787401572f,0.0473036319f,0.0288662519f,1.0f,-128,127,"enc.pv");
    /* 3. every K from 1..80 at M=1, both transposes, and every alignment of B's base:
     *    the phase set is 8/gcd(K,8) so this walks all of them. */
    for(int K=1;K<=80;K++)
        for(int tb=0;tb<2;tb++)
            for(int off=0;off<8;off++){
                int N = tb ? 19 : 19;
                size_t na=(size_t)8*1*K, nb=(size_t)8*K*N, no=(size_t)8*1*N, i;
                for(i=0;i<na+8;i++) A[i]=(int8_t)(rnd()&0xff);
                for(i=0;i<nb+16;i++) Bm[i]=(int8_t)(rnd()&0xff);
                memset(OA,0x5a,no); memset(OB,0x5a,no); memset(OC,0x5a,no);
                float sa=0.0463244766f,sb=0.0231922641f,so=0.0595385246f,sd=6.0f;
                mmb_a(A+off,Bm+off,OA,8,1,K,N,sa,sb,so,tb,sd,-128,127);
                mmb_b(A+off,Bm+off,OB,8,1,K,N,sa,sb,so,tb,sd,-128,127);
                mmb_c(A+off,Bm+off,OC,8,1,K,N,sa,sb,so,tb,sd,-128,127);
                ncase++;
                int bad=0; for(i=0;i<no;i++) if(OA[i]!=OB[i]||OA[i]!=OC[i]) bad++;
                if(bad){ nbad++; printf("FAIL align K=%d tb=%d off=%d bad=%d/%zu\n",K,tb,off,bad,no); }
            }
    /* 4. random shapes and random scales, including tie-heavy and slow-path-heavy ones */
    for(int t=0;t<4000;t++){
        int B=1+(rnd()%4), M=(rnd()%8)?1:(1+(rnd()%3)), K=1+(rnd()%200), N=1+(rnd()%200), tb=rnd()&1;
        float sa,sb,so,sd;
        int mode=rnd()%4;
        if(mode==0){ sa=1.0f/(1<<(rnd()%10)); sb=1.0f/(1<<(rnd()%10)); so=1.0f/(1<<(rnd()%10)); sd=1.0f; }
        else if(mode==1){ sa=0.5f; sb=0.5f; so=0.25f; sd=(float)(1+(rnd()%8)); }
        else { sa=(float)(rnd()%100000+1)/1e6f; sb=(float)(rnd()%100000+1)/1e6f;
               so=(float)(rnd()%100000+1)/1e6f; sd=(rnd()&1)?1.0f:6.0f; }
        int lo=-128,hi=127;
        if((rnd()&7)==0){ lo=0; hi=127; }          /* not clip8: must fall to the general path */
        one(B,M,K,N,tb,sa,sb,so,sd,lo,hi,"rand");
    }
    printf("B59_GATE cases=%ld failing=%ld verdict=%s\n", ncase, nbad, nbad?"FAIL":"PASS");
    return nbad?1:0;
}
