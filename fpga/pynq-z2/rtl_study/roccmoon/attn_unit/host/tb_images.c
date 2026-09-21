/* Do the IMAGE BUILDERS satisfy s2.2's contract?  Read the images back exactly as the array
 * does -- q row t at word t*gs, plane c quad j = [bias | row 4j+c] -- and check the two
 * products against a direct reference.  This is the half of the kernel a host can check;
 * the unit itself is checked by attn_unit/run_tb.sh against the RTL. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "builders.c"
static int8_t q[200*64], k[1100*64], v[1100*64], qi[1024*8], wi[4*512*8];
int main(void){
  int fails=0, cases=0;
  int shapes[][3] = {{165,36,165},{165,36,64},{64,16,64},{33,24,97},{165,36,1},{8,16,8}};
  for (unsigned s=0; s<sizeof shapes/sizeof*shapes; s++){
    int T=shapes[s][0], D=shapes[s][1], N=shapes[s][2];
    int gs=(D+7)/8, qs=(N+3)/4, gp=(N+7)/8, qp=(D+3)/4, lgpw=9;
    int kbase=0, vtbase=qs*(gs+1);
    if (vtbase+qp*(gp+1) > (1<<lgpw)) { printf("  skip %dx%dx%d (planes)\n",T,D,N); continue; }
    srand(100+s);
    for(int i=0;i<T*D;i++) q[i]=(int8_t)(rand()%255-127);
    for(int i=0;i<N*D;i++) k[i]=(int8_t)(rand()%255-127);
    for(int i=0;i<N*D;i++) v[i]=(int8_t)(rand()%255-127);
    memset(qi,0xAA,sizeof qi); memset(wi,0xAA,sizeof wi);
    mbxa_build_q(q,T,D,gs,qi);
    mbxa_build_w(k,v,N,D,gs,qs,gp,qp,lgpw,kbase,vtbase,wi);
    /* q . k^T through the images, the way the array reads them */
    long bad=0;
    for(int t=0;t<T;t++) for(int j=0;j<N;j++){
      int quad=j/4, c=j%4; const int8_t *P=wi+(size_t)c*(1<<lgpw)*8;
      const int8_t *kw=P+(size_t)(kbase+quad*(gs+1))*8+8;
      const int8_t *qw=qi+(size_t)t*gs*8;
      long a=0,r=0; for(int d=0;d<gs*8;d++) a+=(long)qw[d]*kw[d];
      for(int d=0;d<D;d++) r+=(long)q[(size_t)t*D+d]*k[(size_t)j*D+d];
      if(a!=r) bad++;
    }
    /* the bias words must be ZERO -- precondition 4, a silent wrong answer otherwise */
    long nz=0;
    for(int c=0;c<4;c++){ const int8_t *P=wi+(size_t)c*(1<<lgpw)*8;
      for(int j=0;j<qs;j++) for(int b=0;b<8;b++) if(P[(size_t)(kbase+j*(gs+1))*8+b]) nz++;
      for(int j=0;j<qp;j++) for(int b=0;b<8;b++) if(P[(size_t)(vtbase+j*(gp+1))*8+b]) nz++; }
    /* probs . v through the v^T image */
    long bad2=0;
    for(int t=0;t<T;t++) for(int o=0;o<D;o++){
      int quad=o/4,c=o%4; const int8_t *P=wi+(size_t)c*(1<<lgpw)*8;
      const int8_t *vw=P+(size_t)(vtbase+quad*(gp+1))*8+8;
      long a=0,r=0;
      for(int n2=0;n2<gp*8;n2++) a+=(long)((n2<N)?k[(size_t)n2*D+0]:0)*vw[n2];  /* any probs stand-in */
      for(int n2=0;n2<N;n2++)   r+=(long)k[(size_t)n2*D+0]*v[(size_t)n2*D+o];
      if(a!=r) bad2++;
    }
    cases++;
    if(bad||bad2||nz){ fails++; printf("  FAIL %dx%dx%d: qk %ld, av %ld, nonzero bias %ld\n",T,D,N,bad,bad2,nz); }
    else printf("  ok   T=%-4d D=%-3d N=%-4d  q %d words, planes %d/%d words\n",T,D,N,T*gs,vtbase+qp*(gp+1),1<<lgpw);
  }
  printf("\n%s: %d shapes, %d failing\n", fails?"FAILED":"PASS", cases, fails);
  return fails?1:0;
}
