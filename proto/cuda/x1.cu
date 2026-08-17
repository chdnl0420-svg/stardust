// X1 단일격자융합 — CUDA 실측
//  목적 1: 진짜 FFT 포아송 중력 비용 (cuFFT R2C/C2R)
//  목적 2: 정렬 비용 (CUB radix sort) — X1은 주기적, SPH는 매 스텝
//  목적 3: S1(네이티브 CUDA) 스택 점수
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cuda_runtime.h>
#include <cufft.h>
#include <cub/cub.cuh>

#define CK(x) do { cudaError_t e=(x); if(e!=cudaSuccess){ \
  printf("CUDA ERR %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(e)); exit(1);} } while(0)
#define FK(x) do { cufftResult r=(x); if(r!=CUFFT_SUCCESS){ \
  printf("CUFFT ERR %s:%d code=%d\n",__FILE__,__LINE__,(int)r); exit(1);} } while(0)

__device__ __forceinline__ unsigned pcg(unsigned v){
  unsigned state = v*747796405u + 2891336453u;
  unsigned word = ((state >> ((state>>28u)+4u)) ^ state) * 277803737u;
  return (word>>22u) ^ word;
}
__device__ __forceinline__ float rnd01(unsigned s){ return pcg(s) * 2.3283064365386963e-10f; }

__global__ void kInitUniform(float2* pos, float2* vel, int N){
  int i = blockIdx.x*blockDim.x + threadIdx.x; if(i>=N) return;
  pos[i] = make_float2(rnd01(i*2u+1u), rnd01(i*2u+2u));
  vel[i] = make_float2(0.f,0.f);
}

// 정렬 생성: 파티클 i를 셀 c=i/perCell 안에 둔다 (완전 정렬 상태)
__global__ void kInitSorted(float2* pos, float2* vel, int N, int G, int perCell){
  int i = blockIdx.x*blockDim.x + threadIdx.x; if(i>=N) return;
  int c = i/perCell; int cx = c % G; int cy = c / G;
  if(cy>=G){ cx=G-1; cy=G-1; }
  pos[i] = make_float2((cx + rnd01(i*2u+1u))/G, (cy + rnd01(i*2u+2u))/G);
  vel[i] = make_float2(0.f,0.f);
}

__global__ void kCellKey(const float2* pos, unsigned* key, unsigned* val, int N, int G){
  int i = blockIdx.x*blockDim.x + threadIdx.x; if(i>=N) return;
  float2 p = pos[i];
  int cx = min(max((int)(p.x*G),0),G-1);
  int cy = min(max((int)(p.y*G),0),G-1);
  key[i] = (unsigned)(cy*G+cx);
  val[i] = (unsigned)i;
}

__global__ void kReorder2(const float2* sp, const float2* sv, float2* dp, float2* dv,
                          const unsigned* val, int N){
  int i = blockIdx.x*blockDim.x + threadIdx.x; if(i>=N) return;
  unsigned s = val[i]; dp[i]=sp[s]; dv[i]=sv[s];
}

__global__ void kClearF(float* g, int n){
  int i = blockIdx.x*blockDim.x + threadIdx.x; if(i<n) g[i]=0.f;
}

// CUDA는 float atomicAdd를 네이티브 지원 — WebGPU의 고정소수점 변환이 불필요
__global__ void kScatterCIC(const float2* pos, float* gm, int N, int G){
  int i = blockIdx.x*blockDim.x + threadIdx.x; if(i>=N) return;
  float2 p = pos[i];
  float gx = p.x*G, gy = p.y*G;
  int ix = (int)floorf(gx), iy = (int)floorf(gy);
  float fx = gx-ix, fy = gy-iy;
  #pragma unroll
  for(int k=0;k<4;k++){
    int ox=k&1, oy=(k>>1)&1;
    int cx = min(max(ix+ox,0),G-1), cy = min(max(iy+oy,0),G-1);
    float w = (ox? fx : 1.f-fx) * (oy? fy : 1.f-fy);
    atomicAdd(&gm[cy*G+cx], w);
  }
}

// 주파수 공간 포아송: phi_k = -scale * rho_k / k^2
__global__ void kPoisson(cufftComplex* F, int G, float scale){
  int x = blockIdx.x*blockDim.x + threadIdx.x;
  int y = blockIdx.y*blockDim.y + threadIdx.y;
  int W = G/2+1;
  if(x>=W || y>=G) return;
  int idx = y*W+x;
  if(x==0 && y==0){ F[idx].x=0.f; F[idx].y=0.f; return; }
  float kx = (float)x;
  float ky = (float)(y<=G/2 ? y : y-G);
  float f = -scale / (kx*kx + ky*ky);
  F[idx].x *= f; F[idx].y *= f;
}

__global__ void kGradGather(const float* pot, const float2* pos, float2* vel,
                            float2* posOut, int N, int G, float dt, float norm){
  int i = blockIdx.x*blockDim.x + threadIdx.x; if(i>=N) return;
  float2 p = pos[i];
  float gx=p.x*G, gy=p.y*G;
  int ix=(int)floorf(gx), iy=(int)floorf(gy);
  float fx=gx-ix, fy=gy-iy;
  float ax=0.f, ay=0.f;
  #pragma unroll
  for(int k=0;k<4;k++){
    int ox=k&1, oy=(k>>1)&1;
    int cx=min(max(ix+ox,0),G-1), cy=min(max(iy+oy,0),G-1);
    float w=(ox?fx:1.f-fx)*(oy?fy:1.f-fy);
    int xm=max(cx-1,0), xp=min(cx+1,G-1), ym=max(cy-1,0), yp=min(cy+1,G-1);
    ax += w * -(pot[cy*G+xp]-pot[cy*G+xm])*0.5f*G*norm;
    ay += w * -(pot[yp*G+cx]-pot[ym*G+cx])*0.5f*G*norm;
  }
  float2 v = vel[i];
  v.x += ax*dt; v.y += ay*dt;
  float2 np = make_float2(p.x+v.x*dt, p.y+v.y*dt);
  np.x -= floorf(np.x); np.y -= floorf(np.y);
  vel[i]=v; posOut[i]=np;
}

struct Timer {
  cudaEvent_t a,b;
  Timer(){ cudaEventCreate(&a); cudaEventCreate(&b); }
  void start(){ cudaEventRecord(a); }
  float stop(){ cudaEventRecord(b); cudaEventSynchronize(b); float ms; cudaEventElapsedTime(&ms,a,b); return ms; }
};

int main(int argc, char** argv){
  int dev=0; cudaDeviceProp prop; CK(cudaGetDeviceProperties(&prop,dev));
  // CUDA 13에서 cudaDeviceProp::memoryClockRate가 제거되어 버스폭만 출력한다
  printf("GPU: %s  CC %d.%d  SM=%d  L2=%d KB  busWidth=%d bit\n",
    prop.name, prop.major, prop.minor, prop.multiProcessorCount,
    prop.l2CacheSize/1024, prop.memoryBusWidth);

  const int Ns[]  = {100000, 1000000, 10000000};
  const int Gs[]  = {1024, 2048, 4096};
  const int REP   = 30;
  const int BS    = 256;

  printf("\n%-10s %-7s | %-8s %-8s %-8s %-8s %-8s | %-9s %-9s\n",
    "N","grid","key+sort","reorder","clr+sct","fft+poi","gather","무정렬합","정렬포함");
  printf("%s\n", "-----------------------------------------------------------------------------------------------------");

  for(int gi=0; gi<3; ++gi){
    int G = Gs[gi];
    int cells = G*G;
    int W = G/2+1;

    float *dGrid=nullptr, *dPot=nullptr;
    cufftComplex* dSpec=nullptr;
    CK(cudaMalloc(&dGrid, sizeof(float)*cells));
    CK(cudaMalloc(&dPot,  sizeof(float)*cells));
    CK(cudaMalloc(&dSpec, sizeof(cufftComplex)*W*G));

    cufftHandle planF, planB;
    FK(cufftPlan2d(&planF, G, G, CUFFT_R2C));
    FK(cufftPlan2d(&planB, G, G, CUFFT_C2R));

    for(int ni=0; ni<3; ++ni){
      int N = Ns[ni];
      float2 *dPos,*dVel,*dPos2,*dVel2;
      unsigned *dKey,*dKeyO,*dVal,*dValO;
      CK(cudaMalloc(&dPos,  sizeof(float2)*N));
      CK(cudaMalloc(&dVel,  sizeof(float2)*N));
      CK(cudaMalloc(&dPos2, sizeof(float2)*N));
      CK(cudaMalloc(&dVel2, sizeof(float2)*N));
      CK(cudaMalloc(&dKey,  sizeof(unsigned)*N));
      CK(cudaMalloc(&dKeyO, sizeof(unsigned)*N));
      CK(cudaMalloc(&dVal,  sizeof(unsigned)*N));
      CK(cudaMalloc(&dValO, sizeof(unsigned)*N));

      void* dTmp=nullptr; size_t tmpBytes=0;
      cub::DeviceRadixSort::SortPairs(nullptr,tmpBytes,dKey,dKeyO,dVal,dValO,N,0,24);
      CK(cudaMalloc(&dTmp,tmpBytes));

      int gridN = (N+BS-1)/BS, gridC = (cells+BS-1)/BS;
      dim3 pb(16,16), pg((W+15)/16,(G+15)/16);

      kInitUniform<<<gridN,BS>>>(dPos,dVel,N);
      CK(cudaDeviceSynchronize());

      Timer t;
      float tKey=0,tSort=0,tReo=0,tScat=0,tFft=0,tGat=0;

      // 워밍업
      for(int r=0;r<5;r++){
        kClearF<<<gridC,BS>>>(dGrid,cells);
        kScatterCIC<<<gridN,BS>>>(dPos,dGrid,N,G);
        cufftExecR2C(planF,dGrid,dSpec);
        kPoisson<<<pg,pb>>>(dSpec,G,1.0f);
        cufftExecC2R(planB,dSpec,dPot);
        kGradGather<<<gridN,BS>>>(dPot,dPos,dVel,dPos2,N,G,0.0015f,1.0f/cells);
      }
      CK(cudaDeviceSynchronize());

      // 1) key 생성
      t.start(); for(int r=0;r<REP;r++) kCellKey<<<gridN,BS>>>(dPos,dKey,dVal,N,G); tKey=t.stop()/REP;
      // 2) radix sort (24bit)
      t.start(); for(int r=0;r<REP;r++) cub::DeviceRadixSort::SortPairs(dTmp,tmpBytes,dKey,dKeyO,dVal,dValO,N,0,24); tSort=t.stop()/REP;
      // 3) 재배치
      t.start(); for(int r=0;r<REP;r++) kReorder2<<<gridN,BS>>>(dPos,dVel,dPos2,dVel2,dValO,N); tReo=t.stop()/REP;

      // 정렬된 상태로 교체하고 이후 패스를 잰다
      kCellKey<<<gridN,BS>>>(dPos,dKey,dVal,N,G);
      cub::DeviceRadixSort::SortPairs(dTmp,tmpBytes,dKey,dKeyO,dVal,dValO,N,0,24);
      kReorder2<<<gridN,BS>>>(dPos,dVel,dPos2,dVel2,dValO,N);
      CK(cudaMemcpy(dPos,dPos2,sizeof(float2)*N,cudaMemcpyDeviceToDevice));
      CK(cudaMemcpy(dVel,dVel2,sizeof(float2)*N,cudaMemcpyDeviceToDevice));
      CK(cudaDeviceSynchronize());

      // 4) clear + scatter
      t.start();
      for(int r=0;r<REP;r++){ kClearF<<<gridC,BS>>>(dGrid,cells); kScatterCIC<<<gridN,BS>>>(dPos,dGrid,N,G); }
      tScat=t.stop()/REP;
      // 5) FFT + poisson + iFFT
      t.start();
      for(int r=0;r<REP;r++){ cufftExecR2C(planF,dGrid,dSpec); kPoisson<<<pg,pb>>>(dSpec,G,1.0f); cufftExecC2R(planB,dSpec,dPot); }
      tFft=t.stop()/REP;
      // 6) gather + integrate
      t.start();
      for(int r=0;r<REP;r++) kGradGather<<<gridN,BS>>>(dPot,dPos,dVel,dPos2,N,G,0.0015f,1.0f/cells);
      tGat=t.stop()/REP;

      float noSort = tScat+tFft+tGat;
      float withSort = noSort+tKey+tSort+tReo;
      printf("%-10d %-7s | %8.3f %8.3f %8.3f %8.3f %8.3f | %9.3f %9.3f\n",
        N, (G==1024?"1024^2":G==2048?"2048^2":"4096^2"),
        tKey+tSort, tReo, tScat, tFft, tGat, noSort, withSort);

      cudaFree(dPos);cudaFree(dVel);cudaFree(dPos2);cudaFree(dVel2);
      cudaFree(dKey);cudaFree(dKeyO);cudaFree(dVal);cudaFree(dValO);cudaFree(dTmp);
    }
    cufftDestroy(planF); cufftDestroy(planB);
    cudaFree(dGrid); cudaFree(dPot); cudaFree(dSpec);
  }
  printf("\nRESULT: DONE\n");
  return 0;
}
