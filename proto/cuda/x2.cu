// 라운드4 — 점수표를 채우는 네 가지 측정
//  A. 정렬 주기 K       : 줄 세운 뒤 몇 스텝까지 재사용 가능한가 (X1 총비용의 나머지 절반)
//  B. SPH 현실적 비용   : 셀당 파티클을 늘려 이웃 20~30개를 채운 조건에서의 밀도+힘
//  C. 힘 오차 RMS       : 직접 O(N^2) 대비 격자 PM 의 상대오차 (물리 충실도 축)
//  D. 에너지 표류       : 장시간 적분에서 에너지가 얼마나 흘러가는가
//
// 중요: 2D 격자에서 3D형 1/r^2 중력을 얻으려면 주파수공간에서 1/k 를 곱한다.
//       1/k^2 는 "진짜 2D 우주"의 중력(1/r 힘)이라 원하는 그림이 아니다.
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <cuda_runtime.h>
#include <cufft.h>
#include <cub/cub.cuh>

#define CK(x) do { cudaError_t e=(x); if(e!=cudaSuccess){ \
  printf("CUDA ERR %s:%d %s\n",__FILE__,__LINE__,cudaGetErrorString(e)); exit(1);} } while(0)

__device__ __forceinline__ unsigned pcg(unsigned v){
  unsigned s = v*747796405u + 2891336453u;
  unsigned w = ((s >> ((s>>28u)+4u)) ^ s) * 277803737u;
  return (w>>22u) ^ w;
}
__device__ __forceinline__ float rnd01(unsigned s){ return pcg(s) * 2.3283064365386963e-10f; }

// 회전 원반 2개 — 실제로 움직이는 초기조건 (정렬 주기 측정용)
__global__ void kInitDisks(float2* pos, float2* vel, int N){
  int i = blockIdx.x*blockDim.x + threadIdx.x; if(i>=N) return;
  float u1=rnd01(i*3u+1u), u2=rnd01(i*3u+2u), u3=rnd01(i*3u+3u);
  float r = sqrtf(u1)*0.16f;
  float th = u2*6.2831853f;
  float side = (u3>0.5f)? 1.f : -1.f;
  float cx = 0.5f + side*0.17f, cy = 0.5f;
  pos[i] = make_float2(cx + r*cosf(th), cy + r*sinf(th));
  float vt = 0.55f*sqrtf(fmaxf(r,1e-4f));
  vel[i] = make_float2(-sinf(th)*vt - side*0.06f, cosf(th)*vt);
}

// 중앙 영역 균일 — 힘 오차 측정용 (주기 이미지 영향을 줄이려 가운데로 모은다)
__global__ void kInitCentral(float2* pos, int N, float half){
  int i = blockIdx.x*blockDim.x + threadIdx.x; if(i>=N) return;
  pos[i] = make_float2(0.5f + (rnd01(i*2u+1u)-0.5f)*2.f*half,
                       0.5f + (rnd01(i*2u+2u)-0.5f)*2.f*half);
}

__global__ void kCellKey(const float2* pos, unsigned* key, unsigned* val, int N, int G){
  int i = blockIdx.x*blockDim.x + threadIdx.x; if(i>=N) return;
  float2 p = pos[i];
  int cx = min(max((int)(p.x*G),0),G-1), cy = min(max((int)(p.y*G),0),G-1);
  key[i] = (unsigned)(cy*G+cx); val[i] = (unsigned)i;
}
__global__ void kReorder2(const float2* sp, const float2* sv, float2* dp, float2* dv,
                          const unsigned* val, int N){
  int i = blockIdx.x*blockDim.x + threadIdx.x; if(i>=N) return;
  unsigned s=val[i]; dp[i]=sp[s]; dv[i]=sv[s];
}
__global__ void kClearF(float* g, int n){ int i=blockIdx.x*blockDim.x+threadIdx.x; if(i<n) g[i]=0.f; }
__global__ void kClearU(unsigned* g, int n, unsigned v){ int i=blockIdx.x*blockDim.x+threadIdx.x; if(i<n) g[i]=v; }

__global__ void kScatterCIC(const float2* pos, float* gm, int N, int G){
  int i = blockIdx.x*blockDim.x + threadIdx.x; if(i>=N) return;
  float2 p=pos[i];
  float gx=p.x*G, gy=p.y*G;
  int ix=(int)floorf(gx), iy=(int)floorf(gy);
  float fx=gx-ix, fy=gy-iy;
  #pragma unroll
  for(int k=0;k<4;k++){
    int ox=k&1, oy=(k>>1)&1;
    int cx=min(max(ix+ox,0),G-1), cy=min(max(iy+oy,0),G-1);
    atomicAdd(&gm[cy*G+cx], (ox?fx:1.f-fx)*(oy?fy:1.f-fy));
  }
}

// 주파수공간 커널.  mode=1 -> 1/k (3D형 1/r^2 힘),  mode=2 -> 1/k^2 (진짜 2D, 1/r 힘)
__global__ void kPoisson(cufftComplex* F, int G, float scale, int mode){
  int x=blockIdx.x*blockDim.x+threadIdx.x, y=blockIdx.y*blockDim.y+threadIdx.y;
  int W=G/2+1; if(x>=W||y>=G) return;
  int idx=y*W+x;
  if(x==0&&y==0){ F[idx].x=0.f; F[idx].y=0.f; return; }
  float kx=(float)x, ky=(float)(y<=G/2 ? y : y-G);
  float k2=kx*kx+ky*ky;
  float d = (mode==1)? sqrtf(k2) : k2;
  float f = -scale/d;
  F[idx].x*=f; F[idx].y*=f;
}

// 퍼텐셜 격자 -> 파티클 가속도 (CIC 보간, 중심차분)
__global__ void kAccel(const float* pot, const float2* pos, float2* acc, int N, int G, float norm){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float2 p=pos[i];
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
  acc[i]=make_float2(ax,ay);
}

__global__ void kIntegrate(float2* pos, float2* vel, const float2* acc, int N, float dt){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float2 v=vel[i], p=pos[i], a=acc[i];
  v.x+=a.x*dt; v.y+=a.y*dt;
  p.x+=v.x*dt; p.y+=v.y*dt;
  p.x-=floorf(p.x); p.y-=floorf(p.y);
  vel[i]=v; pos[i]=p;
}

// 정답지: 직접 O(N^2), 1/r^2 힘 (소프트닝 eps)
__global__ void kDirect(const float2* pos, float2* f, int N, float eps2){
  int i=blockIdx.x*blockDim.x+threadIdx.x;
  __shared__ float2 sh[256];
  float2 p = (i<N)? pos[i] : make_float2(0.f,0.f);
  float ax=0.f, ay=0.f;
  for(int base=0; base<N; base+=256){
    int t=base+threadIdx.x;
    sh[threadIdx.x] = (t<N)? pos[t] : make_float2(1e30f,1e30f);
    __syncthreads();
    int lim = min(256, N-base);
    for(int j=0;j<lim;j++){
      float dx=sh[j].x-p.x, dy=sh[j].y-p.y;
      float r2=dx*dx+dy*dy+eps2;
      float inv=rsqrtf(r2); float inv3=inv*inv*inv;
      ax+=dx*inv3; ay+=dy*inv3;
    }
    __syncthreads();
  }
  if(i<N) f[i]=make_float2(ax,ay);
}

// 셀 시작/끝 (정렬된 key 배열에서)
__global__ void kCellRange(const unsigned* key, unsigned* cs, unsigned* ce, int N){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  unsigned k=key[i];
  if(i==0) cs[k]=0;
  else { unsigned kp=key[i-1]; if(k!=kp){ cs[k]=i; ce[kp]=i; } }
  if(i==N-1) ce[k]=N;
}

__global__ void kSphDensity(const float2* pos, float* dens, const unsigned* cs, const unsigned* ce,
                            int N, int G, float h2, unsigned* nbrCount){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float2 p=pos[i];
  int cx=min(max((int)(p.x*G),0),G-1), cy=min(max((int)(p.y*G),0),G-1);
  float rho=0.f; unsigned cnt=0;
  for(int dy=-1;dy<=1;dy++) for(int dx=-1;dx<=1;dx++){
    int nx=min(max(cx+dx,0),G-1), ny=min(max(cy+dy,0),G-1);
    unsigned c=(unsigned)(ny*G+nx);
    unsigned s=cs[c]; if(s==0xFFFFFFFFu) continue;
    unsigned e=ce[c];
    for(unsigned j=s;j<e;j++){
      float2 q=pos[j];
      float ddx=q.x-p.x, ddy=q.y-p.y;
      float r2=ddx*ddx+ddy*ddy;
      if(r2<h2){ float t=1.f-r2/h2; rho+=t*t*t; cnt++; }
    }
  }
  dens[i]=rho;
  if(nbrCount) nbrCount[i]=cnt;
}

__global__ void kSphForce(const float2* pos, const float* dens, float2* vel,
                          const unsigned* cs, const unsigned* ce, int N, int G, float h, float h2, float dt){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float2 p=pos[i]; float ri=fmaxf(dens[i],1e-6f);
  int cx=min(max((int)(p.x*G),0),G-1), cy=min(max((int)(p.y*G),0),G-1);
  float fx=0.f, fy=0.f;
  for(int dy=-1;dy<=1;dy++) for(int dx=-1;dx<=1;dx++){
    int nx=min(max(cx+dx,0),G-1), ny=min(max(cy+dy,0),G-1);
    unsigned c=(unsigned)(ny*G+nx);
    unsigned s=cs[c]; if(s==0xFFFFFFFFu) continue;
    unsigned e=ce[c];
    for(unsigned j=s;j<e;j++){
      float2 q=pos[j];
      float ddx=p.x-q.x, ddy=p.y-q.y;
      float r2=ddx*ddx+ddy*ddy;
      if(r2<h2 && r2>1e-14f){
        float r=sqrtf(r2);
        float w=(h-r)*(h-r);
        float s2=w*(ri+fmaxf(dens[j],1e-6f))*0.5f/r;
        fx+=ddx*s2; fy+=ddy*s2;
      }
    }
  }
  float2 v=vel[i]; v.x+=fx*dt*1e-6f; v.y+=fy*dt*1e-6f; vel[i]=v;
}

struct Ev { cudaEvent_t a,b; Ev(){cudaEventCreate(&a);cudaEventCreate(&b);}
  void s(){cudaEventRecord(a);} float e(){cudaEventRecord(b);cudaEventSynchronize(b);
  float m;cudaEventElapsedTime(&m,a,b);return m;} };

int main(){
  cudaDeviceProp prop; CK(cudaGetDeviceProperties(&prop,0));
  printf("GPU: %s CC %d.%d SM=%d L2=%dKB\n", prop.name,prop.major,prop.minor,
         prop.multiProcessorCount, prop.l2CacheSize/1024);
  const int BS=256;
  Ev ev;

  // ============ A. 정렬 주기 K ============
  printf("\n===== A. 정렬 주기 — 줄 세운 뒤 몇 스텝까지 성능이 유지되나 (N=10M, 2048^2) =====\n");
  {
    int N=10000000, G=2048, cells=G*G, W=G/2+1;
    float2 *dPos,*dVel,*dPos2,*dVel2,*dAcc; float *dGrid,*dPot; cufftComplex* dSpec;
    unsigned *dKey,*dKeyO,*dVal,*dValO;
    CK(cudaMalloc(&dPos,sizeof(float2)*N)); CK(cudaMalloc(&dVel,sizeof(float2)*N));
    CK(cudaMalloc(&dPos2,sizeof(float2)*N));CK(cudaMalloc(&dVel2,sizeof(float2)*N));
    CK(cudaMalloc(&dAcc,sizeof(float2)*N));
    CK(cudaMalloc(&dGrid,sizeof(float)*cells)); CK(cudaMalloc(&dPot,sizeof(float)*cells));
    CK(cudaMalloc(&dSpec,sizeof(cufftComplex)*W*G));
    CK(cudaMalloc(&dKey,sizeof(unsigned)*N)); CK(cudaMalloc(&dKeyO,sizeof(unsigned)*N));
    CK(cudaMalloc(&dVal,sizeof(unsigned)*N)); CK(cudaMalloc(&dValO,sizeof(unsigned)*N));
    void* dTmp=nullptr; size_t tb=0;
    cub::DeviceRadixSort::SortPairs(nullptr,tb,dKey,dKeyO,dVal,dValO,N,0,24);
    CK(cudaMalloc(&dTmp,tb));
    cufftHandle pf,pb; cufftPlan2d(&pf,G,G,CUFFT_R2C); cufftPlan2d(&pb,G,G,CUFFT_C2R);
    int gN=(N+BS-1)/BS, gC=(cells+BS-1)/BS; dim3 pbk(16,16), pgk((W+15)/16,(G+15)/16);
    float dt=0.0020f, norm=1.f/cells;

    kInitDisks<<<gN,BS>>>(dPos,dVel,N); CK(cudaDeviceSynchronize());
    // 최초 정렬
    kCellKey<<<gN,BS>>>(dPos,dKey,dVal,N,G);
    cub::DeviceRadixSort::SortPairs(dTmp,tb,dKey,dKeyO,dVal,dValO,N,0,24);
    kReorder2<<<gN,BS>>>(dPos,dVel,dPos2,dVel2,dValO,N);
    CK(cudaMemcpy(dPos,dPos2,sizeof(float2)*N,cudaMemcpyDeviceToDevice));
    CK(cudaMemcpy(dVel,dVel2,sizeof(float2)*N,cudaMemcpyDeviceToDevice));
    CK(cudaDeviceSynchronize());

    printf("  경과스텝 |  scatter(ms)  전체스텝(ms)   FPS\n");
    int marks[]={0,5,10,20,40,80,160}; int mi=0;
    for(int step=0; step<=160; ++step){
      if(mi<7 && step==marks[mi]){
        // 이 시점의 scatter 비용만 10회 평균으로 측정
        ev.s(); for(int r=0;r<10;r++){ kClearF<<<gC,BS>>>(dGrid,cells); kScatterCIC<<<gN,BS>>>(dPos,dGrid,N,G); }
        float ts=ev.e()/10.f;
        ev.s(); for(int r=0;r<10;r++){
          kClearF<<<gC,BS>>>(dGrid,cells); kScatterCIC<<<gN,BS>>>(dPos,dGrid,N,G);
          cufftExecR2C(pf,dGrid,dSpec); kPoisson<<<pgk,pbk>>>(dSpec,G,1.f,1); cufftExecC2R(pb,dSpec,dPot);
          kAccel<<<gN,BS>>>(dPot,dPos,dAcc,N,G,norm);
        }
        float tt=ev.e()/10.f;
        printf("  %8d | %10.3f  %11.3f  %7.1f\n", step, ts, tt, 1000.f/tt);
        mi++;
      }
      // 실제 한 스텝 진행
      kClearF<<<gC,BS>>>(dGrid,cells); kScatterCIC<<<gN,BS>>>(dPos,dGrid,N,G);
      cufftExecR2C(pf,dGrid,dSpec); kPoisson<<<pgk,pbk>>>(dSpec,G,1.f,1); cufftExecC2R(pb,dSpec,dPot);
      kAccel<<<gN,BS>>>(dPot,dPos,dAcc,N,G,norm);
      kIntegrate<<<gN,BS>>>(dPos,dVel,dAcc,N,dt);
    }
    CK(cudaDeviceSynchronize());
    cudaFree(dPos);cudaFree(dVel);cudaFree(dPos2);cudaFree(dVel2);cudaFree(dAcc);
    cudaFree(dGrid);cudaFree(dPot);cudaFree(dSpec);
    cudaFree(dKey);cudaFree(dKeyO);cudaFree(dVal);cudaFree(dValO);cudaFree(dTmp);
    cufftDestroy(pf);cufftDestroy(pb);
  }

  // ============ B. SPH 현실적 이웃수 ============
  printf("\n===== B. SPH 비용 — 셀당 파티클을 늘려 이웃 20~30개를 채운 조건 =====\n");
  printf("  N          격자    평균이웃   정렬(ms)  밀도(ms)  압력힘(ms)  SPH합(ms)\n");
  {
    struct Cs { int N,G; } cs[] = { {1000000,512}, {10000000,1024}, {10000000,1448}, {10000000,2048} };
    for(auto& c : cs){
      int N=c.N, G=c.G, cells=G*G;
      float2 *dPos,*dVel,*dPos2,*dVel2; float* dDens;
      unsigned *dKey,*dKeyO,*dVal,*dValO,*dCS,*dCE,*dNbr;
      CK(cudaMalloc(&dPos,sizeof(float2)*N)); CK(cudaMalloc(&dVel,sizeof(float2)*N));
      CK(cudaMalloc(&dPos2,sizeof(float2)*N));CK(cudaMalloc(&dVel2,sizeof(float2)*N));
      CK(cudaMalloc(&dDens,sizeof(float)*N)); CK(cudaMalloc(&dNbr,sizeof(unsigned)*N));
      CK(cudaMalloc(&dKey,sizeof(unsigned)*N)); CK(cudaMalloc(&dKeyO,sizeof(unsigned)*N));
      CK(cudaMalloc(&dVal,sizeof(unsigned)*N)); CK(cudaMalloc(&dValO,sizeof(unsigned)*N));
      CK(cudaMalloc(&dCS,sizeof(unsigned)*cells)); CK(cudaMalloc(&dCE,sizeof(unsigned)*cells));
      void* dTmp=nullptr; size_t tb=0;
      cub::DeviceRadixSort::SortPairs(nullptr,tb,dKey,dKeyO,dVal,dValO,N,0,24);
      CK(cudaMalloc(&dTmp,tb));
      int gN=(N+BS-1)/BS, gC=(cells+BS-1)/BS;
      float h=1.f/G, h2=h*h;

      kInitDisks<<<gN,BS>>>(dPos,dVel,N); CK(cudaDeviceSynchronize());

      // 정렬 1회 (비용 측정 포함)
      ev.s();
      for(int r=0;r<5;r++){
        kCellKey<<<gN,BS>>>(dPos,dKey,dVal,N,G);
        cub::DeviceRadixSort::SortPairs(dTmp,tb,dKey,dKeyO,dVal,dValO,N,0,24);
        kReorder2<<<gN,BS>>>(dPos,dVel,dPos2,dVel2,dValO,N);
      }
      float tSort=ev.e()/5.f;
      // 정렬 결과 확정
      kCellKey<<<gN,BS>>>(dPos,dKey,dVal,N,G);
      cub::DeviceRadixSort::SortPairs(dTmp,tb,dKey,dKeyO,dVal,dValO,N,0,24);
      kReorder2<<<gN,BS>>>(dPos,dVel,dPos2,dVel2,dValO,N);
      CK(cudaMemcpy(dPos,dPos2,sizeof(float2)*N,cudaMemcpyDeviceToDevice));
      CK(cudaMemcpy(dVel,dVel2,sizeof(float2)*N,cudaMemcpyDeviceToDevice));
      kClearU<<<gC,BS>>>(dCS,cells,0xFFFFFFFFu); kClearU<<<gC,BS>>>(dCE,cells,0u);
      kCellKey<<<gN,BS>>>(dPos,dKey,dVal,N,G);
      cub::DeviceRadixSort::SortPairs(dTmp,tb,dKey,dKeyO,dVal,dValO,N,0,24);
      kCellRange<<<gN,BS>>>(dKeyO,dCS,dCE,N);
      CK(cudaDeviceSynchronize());

      // 워밍업
      for(int r=0;r<3;r++){ kSphDensity<<<gN,BS>>>(dPos,dDens,dCS,dCE,N,G,h2,dNbr);
                            kSphForce<<<gN,BS>>>(dPos,dDens,dVel,dCS,dCE,N,G,h,h2,0.001f); }
      CK(cudaDeviceSynchronize());
      ev.s(); for(int r=0;r<10;r++) kSphDensity<<<gN,BS>>>(dPos,dDens,dCS,dCE,N,G,h2,dNbr); float tD=ev.e()/10.f;
      ev.s(); for(int r=0;r<10;r++) kSphForce<<<gN,BS>>>(dPos,dDens,dVel,dCS,dCE,N,G,h,h2,0.001f); float tF=ev.e()/10.f;

      // 평균 이웃 수 (앞쪽 100만 개 샘플)
      int sample = min(N,1000000);
      std::vector<unsigned> hn(sample);
      CK(cudaMemcpy(hn.data(),dNbr,sizeof(unsigned)*sample,cudaMemcpyDeviceToHost));
      double avg=0; for(int i=0;i<sample;i++) avg+=hn[i]; avg/=sample;

      printf("  %-10d %-7s %8.1f %9.3f %9.3f %10.3f %10.3f\n",
        N, (G==512?"512^2":G==1024?"1024^2":G==1448?"1448^2":"2048^2"),
        avg, tSort, tD, tF, tD+tF);

      cudaFree(dPos);cudaFree(dVel);cudaFree(dPos2);cudaFree(dVel2);cudaFree(dDens);cudaFree(dNbr);
      cudaFree(dKey);cudaFree(dKeyO);cudaFree(dVal);cudaFree(dValO);cudaFree(dCS);cudaFree(dCE);cudaFree(dTmp);
    }
  }

  // ============ C. 힘 오차 (직접 O(N^2) 대비) ============
  printf("\n===== C. 힘 오차 — 직접 O(N^2) 1/r^2 를 정답지로, 격자 PM 의 상대오차 RMS =====\n");
  printf("  격자     소프트닝    상대오차RMS   비고\n");
  {
    int N=20000; float half=0.25f;   // 중앙 절반 영역에 배치 -> 주기 이미지 영향 축소
    float2 *dPos,*dFd,*dFp;
    CK(cudaMalloc(&dPos,sizeof(float2)*N));
    CK(cudaMalloc(&dFd,sizeof(float2)*N)); CK(cudaMalloc(&dFp,sizeof(float2)*N));
    int gN=(N+BS-1)/BS;
    kInitCentral<<<gN,BS>>>(dPos,N,half); CK(cudaDeviceSynchronize());

    for(int G : {512,1024,2048,4096}){
      int cells=G*G, W=G/2+1;
      float eps = 1.5f/G;                 // 소프트닝을 격자 셀 크기에 맞춘다
      kDirect<<<gN,BS>>>(dPos,dFd,N,eps*eps); CK(cudaDeviceSynchronize());

      float *dGrid,*dPot; cufftComplex* dSpec;
      CK(cudaMalloc(&dGrid,sizeof(float)*cells)); CK(cudaMalloc(&dPot,sizeof(float)*cells));
      CK(cudaMalloc(&dSpec,sizeof(cufftComplex)*W*G));
      cufftHandle pf,pb; cufftPlan2d(&pf,G,G,CUFFT_R2C); cufftPlan2d(&pb,G,G,CUFFT_C2R);
      int gC=(cells+BS-1)/BS; dim3 pbk(16,16), pgk((W+15)/16,(G+15)/16);
      kClearF<<<gC,BS>>>(dGrid,cells);
      kScatterCIC<<<gN,BS>>>(dPos,dGrid,N,G);
      cufftExecR2C(pf,dGrid,dSpec);
      kPoisson<<<pgk,pbk>>>(dSpec,G,1.f,1);
      cufftExecC2R(pb,dSpec,dPot);
      kAccel<<<gN,BS>>>(dPot,dPos,dFp,N,G,1.f/cells);
      CK(cudaDeviceSynchronize());

      std::vector<float2> hd(N), hp(N);
      CK(cudaMemcpy(hd.data(),dFd,sizeof(float2)*N,cudaMemcpyDeviceToHost));
      CK(cudaMemcpy(hp.data(),dFp,sizeof(float2)*N,cudaMemcpyDeviceToHost));
      // PM 은 스케일 상수가 다르므로 최소자승으로 배율을 맞춘 뒤 오차를 잰다
      double num=0, den=0;
      for(int i=0;i<N;i++){ num += (double)hp[i].x*hd[i].x + (double)hp[i].y*hd[i].y;
                            den += (double)hp[i].x*hp[i].x + (double)hp[i].y*hp[i].y; }
      double a = (den>0)? num/den : 0.0;
      double se=0, sr=0;
      for(int i=0;i<N;i++){
        double ex=a*hp[i].x-hd[i].x, ey=a*hp[i].y-hd[i].y;
        se += ex*ex+ey*ey;
        sr += (double)hd[i].x*hd[i].x + (double)hd[i].y*hd[i].y;
      }
      double rms = sqrt(se/ N) / sqrt(sr/ N);
      printf("  %-7s  %8.5f  %12.5f   배율=%.4g\n",
        (G==512?"512^2":G==1024?"1024^2":G==2048?"2048^2":"4096^2"), eps, rms, a);

      cufftDestroy(pf);cufftDestroy(pb);
      cudaFree(dGrid);cudaFree(dPot);cudaFree(dSpec);
    }
    cudaFree(dPos);cudaFree(dFd);cudaFree(dFp);
  }

  // ============ D. 에너지 표류 ============
  printf("\n===== D. 에너지 표류 — N=100,000, 1024^2, 1000스텝 =====\n");
  {
    int N=100000, G=1024, cells=G*G, W=G/2+1;
    float2 *dPos,*dVel,*dAcc; float *dGrid,*dPot;
    cufftComplex* dSpec;
    CK(cudaMalloc(&dPos,sizeof(float2)*N)); CK(cudaMalloc(&dVel,sizeof(float2)*N));
    CK(cudaMalloc(&dAcc,sizeof(float2)*N));
    CK(cudaMalloc(&dGrid,sizeof(float)*cells)); CK(cudaMalloc(&dPot,sizeof(float)*cells));
    CK(cudaMalloc(&dSpec,sizeof(cufftComplex)*W*G));
    cufftHandle pf,pb; cufftPlan2d(&pf,G,G,CUFFT_R2C); cufftPlan2d(&pb,G,G,CUFFT_C2R);
    int gN=(N+BS-1)/BS, gC=(cells+BS-1)/BS; dim3 pbk(16,16), pgk((W+15)/16,(G+15)/16);
    float dt=0.0015f, norm=1.f/cells;
    kInitDisks<<<gN,BS>>>(dPos,dVel,N); CK(cudaDeviceSynchronize());

    auto energy = [&]()->double{
      std::vector<float2> hv(N); CK(cudaMemcpy(hv.data(),dVel,sizeof(float2)*N,cudaMemcpyDeviceToHost));
      double ke=0; for(int i=0;i<N;i++) ke += 0.5*((double)hv[i].x*hv[i].x + (double)hv[i].y*hv[i].y);
      return ke;
    };
    double e0=energy();
    for(int s=0;s<1000;s++){
      kClearF<<<gC,BS>>>(dGrid,cells); kScatterCIC<<<gN,BS>>>(dPos,dGrid,N,G);
      cufftExecR2C(pf,dGrid,dSpec); kPoisson<<<pgk,pbk>>>(dSpec,G,1.f,1); cufftExecC2R(pb,dSpec,dPot);
      kAccel<<<gN,BS>>>(dPot,dPos,dAcc,N,G,norm);
      kIntegrate<<<gN,BS>>>(dPos,dVel,dAcc,N,dt);
    }
    CK(cudaDeviceSynchronize());
    double e1=energy();
    printf("  운동에너지 초기=%.6g  1000스텝후=%.6g  변화율=%.4f\n", e0, e1, (e1-e0)/e0);
    printf("  (참고: 중력계는 수축하며 운동에너지가 커지는 게 정상이라 이 값 자체가 오차는 아니다)\n");
    cudaFree(dPos);cudaFree(dVel);cudaFree(dAcc);cudaFree(dGrid);cudaFree(dPot);cudaFree(dSpec);
    cufftDestroy(pf);cufftDestroy(pb);
  }

  printf("\nRESULT: DONE\n");
  return 0;
}
