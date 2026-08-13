// 라운드5 — 물리 충실도 제대로 재기
//  라운드4의 힘오차 측정은 무효였다: 정답지(직접합)는 고립 경계, PM은 주기 경계라
//  서로 다른 물리를 비교했다. 격자를 키워도 오차가 안 줄던 이유.
//
//  여기서는 PM을 고립 경계로 만든다 (Hockney-Eastwood):
//    - 격자를 2G x 2G 로 잡고 질량은 왼쪽아래 G x G 에만 넣는다 (zero padding)
//    - 실공간 그린함수 g(r) = -1/max(r,eps) 를 2G x 2G 에 깔고 FFT
//    - 주파수공간에서 rho_hat * g_hat 곱하고 역변환 -> 순환합성곱이 선형합성곱이 되어 고립 경계가 된다
//  이러면 1/r 퍼텐셜 = 1/r^2 힘 이 정확히 재현되고 직접합과 같은 물리가 된다.
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <cuda_runtime.h>
#include <cufft.h>

#define CK(x) do { cudaError_t e=(x); if(e!=cudaSuccess){ \
  printf("CUDA ERR %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(e)); exit(1);} } while(0)

__device__ __forceinline__ unsigned pcg(unsigned v){
  unsigned s=v*747796405u+2891336453u; unsigned w=((s>>((s>>28u)+4u))^s)*277803737u; return (w>>22u)^w; }
__device__ __forceinline__ float rnd01(unsigned s){ return pcg(s)*2.3283064365386963e-10f; }

// 파티클은 [0,1)^2 의 왼쪽아래 사분면 안쪽에 둔다 (패딩 영역을 남기려고)
__global__ void kInitBlob(float2* pos, int N, float lo, float hi){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  pos[i]=make_float2(lo+(hi-lo)*rnd01(i*2u+1u), lo+(hi-lo)*rnd01(i*2u+2u));
}

__global__ void kClearF(float* g,int n){ int i=blockIdx.x*blockDim.x+threadIdx.x; if(i<n) g[i]=0.f; }

// 질량을 패딩 격자(2G x 2G)의 좌하단에 CIC 로 뿌린다. 좌표는 [0,1) -> [0,G) 셀
__global__ void kScatterPad(const float2* pos, float* gm, int N, int G, int GP){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float2 p=pos[i];
  float gx=p.x*G, gy=p.y*G;
  int ix=(int)floorf(gx), iy=(int)floorf(gy);
  float fx=gx-ix, fy=gy-iy;
  #pragma unroll
  for(int k=0;k<4;k++){
    int ox=k&1, oy=(k>>1)&1;
    int cx=ix+ox, cy=iy+oy;
    if(cx<0||cy<0||cx>=G||cy>=G) continue;
    atomicAdd(&gm[cy*GP+cx], (ox?fx:1.f-fx)*(oy?fy:1.f-fy));
  }
}

// 실공간 그린함수: 2G x 2G 에 wrap 좌표로 -1/max(r,eps)
__global__ void kGreen(float* g, int GP, float cell, float eps){
  int x=blockIdx.x*blockDim.x+threadIdx.x, y=blockIdx.y*blockDim.y+threadIdx.y;
  if(x>=GP||y>=GP) return;
  int dx = (x < GP/2)? x : x-GP;
  int dy = (y < GP/2)? y : y-GP;
  float r = sqrtf((float)dx*dx + (float)dy*dy)*cell;
  g[y*GP+x] = -1.0f/fmaxf(r,eps);
}

__global__ void kMulSpec(cufftComplex* a, const cufftComplex* b, int n, float s){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=n) return;
  cufftComplex A=a[i], B=b[i];
  a[i]=make_cuFloatComplex((A.x*B.x-A.y*B.y)*s, (A.x*B.y+A.y*B.x)*s);
}

// 퍼텐셜 -> 가속도 (CIC 보간, 중심차분). 패딩 격자에서 읽되 좌하단 G x G 만 유효
__global__ void kAccelPad(const float* pot, const float2* pos, float2* acc, int N, int G, int GP){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float2 p=pos[i];
  float gx=p.x*G, gy=p.y*G;
  int ix=(int)floorf(gx), iy=(int)floorf(gy);
  float fx=gx-ix, fy=gy-iy;
  float ax=0.f, ay=0.f;
  #pragma unroll
  for(int k=0;k<4;k++){
    int ox=k&1, oy=(k>>1)&1;
    int cx=min(max(ix+ox,1),G-2), cy=min(max(iy+oy,1),G-2);
    float w=(ox?fx:1.f-fx)*(oy?fy:1.f-fy);
    ax += w * -(pot[cy*GP+cx+1]-pot[cy*GP+cx-1])*0.5f*G;
    ay += w * -(pot[(cy+1)*GP+cx]-pot[(cy-1)*GP+cx])*0.5f*G;
  }
  acc[i]=make_float2(ax,ay);
}

// 정답지: 직접 O(N^2), 1/r^2, 소프트닝 eps
__global__ void kDirect(const float2* pos, float2* f, int N, float eps2){
  int i=blockIdx.x*blockDim.x+threadIdx.x;
  __shared__ float2 sh[256];
  float2 p=(i<N)?pos[i]:make_float2(0.f,0.f);
  float ax=0.f, ay=0.f;
  for(int base=0;base<N;base+=256){
    int t=base+threadIdx.x;
    sh[threadIdx.x]=(t<N)?pos[t]:make_float2(1e30f,1e30f);
    __syncthreads();
    int lim=min(256,N-base);
    for(int j=0;j<lim;j++){
      float dx=sh[j].x-p.x, dy=sh[j].y-p.y;
      float r2=dx*dx+dy*dy+eps2;
      float inv=rsqrtf(r2), inv3=inv*inv*inv;
      ax+=dx*inv3; ay+=dy*inv3;
    }
    __syncthreads();
  }
  if(i<N) f[i]=make_float2(ax,ay);
}

struct Ev { cudaEvent_t a,b; Ev(){cudaEventCreate(&a);cudaEventCreate(&b);}
  void s(){cudaEventRecord(a);} float e(){cudaEventRecord(b);cudaEventSynchronize(b);
  float m;cudaEventElapsedTime(&m,a,b);return m;} };

int main(){
  const int BS=256;
  const int N=20000;
  float2 *dPos,*dFd,*dFp;
  CK(cudaMalloc(&dPos,sizeof(float2)*N));
  CK(cudaMalloc(&dFd,sizeof(float2)*N));
  CK(cudaMalloc(&dFp,sizeof(float2)*N));
  int gN=(N+BS-1)/BS;
  // 블롭을 격자 좌하단 중앙쯤에 둔다
  kInitBlob<<<gN,BS>>>(dPos,N,0.20f,0.80f);
  CK(cudaDeviceSynchronize());

  printf("고립경계 PM (zero-padding 2G + 실공간 그린함수) vs 직접 O(N^2) 1/r^2\n");
  printf("N=%d, 소프트닝은 격자 셀크기에 비례(1.5*cell)\n\n", N);
  printf("  격자     패딩격자   소프트닝    상대오차RMS   배율        FFT시간(ms)\n");

  Ev ev;
  for(int G : {256,512,1024,2048}){
    int GP=2*G, cellsP=GP*GP, W=GP/2+1;
    float cell=1.0f/G;
    float eps=1.5f*cell;

    // 정답지 (같은 소프트닝)
    kDirect<<<gN,BS>>>(dPos,dFd,N,eps*eps);
    CK(cudaDeviceSynchronize());

    float *dRho,*dGrn,*dPot;
    cufftComplex *dRhoS,*dGrnS;
    CK(cudaMalloc(&dRho,sizeof(float)*cellsP));
    CK(cudaMalloc(&dGrn,sizeof(float)*cellsP));
    CK(cudaMalloc(&dPot,sizeof(float)*cellsP));
    CK(cudaMalloc(&dRhoS,sizeof(cufftComplex)*W*GP));
    CK(cudaMalloc(&dGrnS,sizeof(cufftComplex)*W*GP));
    cufftHandle pf,pb;
    cufftPlan2d(&pf,GP,GP,CUFFT_R2C);
    cufftPlan2d(&pb,GP,GP,CUFFT_C2R);

    int gCP=(cellsP+BS-1)/BS;
    dim3 b2(16,16), g2((GP+15)/16,(GP+15)/16);

    // 그린함수는 한 번만 변환 (실사용 시에도 사전계산 1회)
    kGreen<<<g2,b2>>>(dGrn,GP,cell,eps);
    cufftExecR2C(pf,dGrn,dGrnS);

    kClearF<<<gCP,BS>>>(dRho,cellsP);
    kScatterPad<<<gN,BS>>>(dPos,dRho,N,G,GP);

    ev.s();
    cufftExecR2C(pf,dRho,dRhoS);
    kMulSpec<<<(W*GP+BS-1)/BS,BS>>>(dRhoS,dGrnS,W*GP,1.0f/(float)cellsP);
    cufftExecC2R(pb,dRhoS,dPot);
    float tf=ev.e();

    kAccelPad<<<gN,BS>>>(dPot,dPos,dFp,N,G,GP);
    CK(cudaDeviceSynchronize());

    std::vector<float2> hd(N),hp(N);
    CK(cudaMemcpy(hd.data(),dFd,sizeof(float2)*N,cudaMemcpyDeviceToHost));
    CK(cudaMemcpy(hp.data(),dFp,sizeof(float2)*N,cudaMemcpyDeviceToHost));
    double num=0,den=0;
    for(int i=0;i<N;i++){ num+=(double)hp[i].x*hd[i].x+(double)hp[i].y*hd[i].y;
                          den+=(double)hp[i].x*hp[i].x+(double)hp[i].y*hp[i].y; }
    double a=(den>0)?num/den:0.0;
    double se=0,sr=0;
    for(int i=0;i<N;i++){
      double ex=a*hp[i].x-hd[i].x, ey=a*hp[i].y-hd[i].y;
      se+=ex*ex+ey*ey; sr+=(double)hd[i].x*hd[i].x+(double)hd[i].y*hd[i].y;
    }
    double rms=sqrt(se/N)/sqrt(sr/N);
    printf("  %-7s  %-8s  %8.5f  %12.5f  %10.4g  %8.3f\n",
      (G==256?"256^2":G==512?"512^2":G==1024?"1024^2":"2048^2"),
      (GP==512?"512^2":GP==1024?"1024^2":GP==2048?"2048^2":"4096^2"),
      eps, rms, a, tf);

    cufftDestroy(pf);cufftDestroy(pb);
    cudaFree(dRho);cudaFree(dGrn);cudaFree(dPot);cudaFree(dRhoS);cudaFree(dGrnS);
  }

  // 주기경계 PM 의 FFT 비용과 비교 (고립경계는 격자 4배라 4배 비쌈)
  printf("\n참고: 고립경계는 패딩 때문에 FFT 격자가 4배가 된다. 위 FFT시간은 그 패딩 격자 기준.\n");

  cudaFree(dPos);cudaFree(dFd);cudaFree(dFp);
  printf("\nRESULT: DONE\n");
  return 0;
}
