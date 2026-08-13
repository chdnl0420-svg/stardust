// 라운드6 — X1 완전판 (중력 FFT + 격자 압력) 으로 "결과의 그림" 4종 확인
//   1) 나선팔      : 회전 원반 하나가 중력 불안정으로 나선 구조를 만드는가
//   2) 조석 꼬리   : 두 덩어리가 스쳐 지날 때 물질이 길게 끌려 나오는가
//   3) 충격파 전선 : 두 가스 덩어리가 정면충돌할 때 밀도 불연속이 서는가
//   4) 구조 형성   : 균일 난수 + 작은 요동에서 필라멘트/덩어리가 저절로 생기는가
//
// X1 한 스텝:
//   격자클리어 -> CIC 산란(질량) -> FFT 포아송(1/k, 3D형 1/r^2) -> 격자에서 압력구배
//   -> 중력+압력 가속도를 CIC 보간 -> 적분
// 압력은 중력과 "같은 격자"에서 나온다. 이것이 X1의 핵심 (이웃 탐색이 없다).
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

// scene 0: 회전 원반 1개 / 1: 스치는 두 덩어리 / 2: 정면충돌 / 3: 균일+요동
__global__ void kInit(float2* pos, float2* vel, int N, int scene){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float u1=rnd01(i*4u+1u), u2=rnd01(i*4u+2u), u3=rnd01(i*4u+3u), u4=rnd01(i*4u+4u);
  if(scene==0){
    float r = sqrtf(u1)*0.22f;
    float th= u2*6.2831853f;
    float vt= 1.15f*sqrtf(fmaxf(r,2e-3f));
    pos[i]=make_float2(0.5f+r*cosf(th), 0.5f+r*sinf(th));
    // 약간의 난수 속도를 섞어 불안정 씨앗을 준다
    vel[i]=make_float2(-sinf(th)*vt + (u3-0.5f)*0.02f, cosf(th)*vt + (u4-0.5f)*0.02f);
  } else if(scene==1){
    float side=(u3>0.5f)?1.f:-1.f;
    float r=sqrtf(u1)*0.11f, th=u2*6.2831853f;
    float cx=0.5f+side*0.19f, cy=0.5f-side*0.07f;
    float vt=0.85f*sqrtf(fmaxf(r,2e-3f));
    pos[i]=make_float2(cx+r*cosf(th), cy+r*sinf(th));
    vel[i]=make_float2(-sinf(th)*vt + side*0.30f, cosf(th)*vt + side*0.05f);
  } else if(scene==2){
    float side=(u3>0.5f)?1.f:-1.f;
    float r=sqrtf(u1)*0.10f, th=u2*6.2831853f;
    pos[i]=make_float2(0.5f+side*0.20f+r*cosf(th), 0.5f+r*sinf(th));
    vel[i]=make_float2(-side*0.55f, (u4-0.5f)*0.01f);
  } else {
    // 균일 + 작은 속도 요동 (구조 형성 씨앗)
    pos[i]=make_float2(u1,u2);
    vel[i]=make_float2((u3-0.5f)*0.03f,(u4-0.5f)*0.03f);
  }
}

__global__ void kClearF(float* g,int n){ int i=blockIdx.x*blockDim.x+threadIdx.x; if(i<n) g[i]=0.f; }

__global__ void kScatterCIC(const float2* pos, float* gm, int N, int G){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float2 p=pos[i];
  float gx=p.x*G, gy=p.y*G;
  int ix=(int)floorf(gx), iy=(int)floorf(gy);
  float fx=gx-ix, fy=gy-iy;
  #pragma unroll
  for(int k=0;k<4;k++){
    int ox=k&1, oy=(k>>1)&1;
    int cx=(ix+ox)&(G-1), cy=(iy+oy)&(G-1);   // G는 2의 거듭제곱 -> 주기 wrap
    atomicAdd(&gm[cy*G+cx], (ox?fx:1.f-fx)*(oy?fy:1.f-fy));
  }
}

// 1/k 커널 -> 3D형 1/r^2 중력
__global__ void kPoisson(cufftComplex* F,int G,float scale){
  int x=blockIdx.x*blockDim.x+threadIdx.x, y=blockIdx.y*blockDim.y+threadIdx.y;
  int W=G/2+1; if(x>=W||y>=G) return;
  int idx=y*W+x;
  if(x==0&&y==0){ F[idx].x=0.f; F[idx].y=0.f; return; }
  float kx=(float)x, ky=(float)(y<=G/2?y:y-G);
  float f=-scale/sqrtf(kx*kx+ky*ky);
  F[idx].x*=f; F[idx].y*=f;
}

// 격자에서 압력 계산: P = K * rho^gamma  (같은 격자, 이웃 탐색 없음)
__global__ void kPressure(const float* rho, float* prs, int n, float K, float gamma){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=n) return;
  prs[i] = K * powf(fmaxf(rho[i],0.f), gamma);
}

// 중력퍼텐셜 + 압력 을 합쳐 격자 가속도장을 만든다
__global__ void kGridAccel(const float* pot, const float* prs, const float* rho,
                           float2* acc, int G, float potNorm){
  int x=blockIdx.x*blockDim.x+threadIdx.x, y=blockIdx.y*blockDim.y+threadIdx.y;
  if(x>=G||y>=G) return;
  int xm=(x-1)&(G-1), xp=(x+1)&(G-1), ym=(y-1)&(G-1), yp=(y+1)&(G-1);
  int idx=y*G+x;
  float gx = -(pot[y*G+xp]-pot[y*G+xm])*0.5f*G*potNorm;
  float gy = -(pot[yp*G+x]-pot[ym*G+x])*0.5f*G*potNorm;
  float r = fmaxf(rho[idx],1e-6f);
  float px = -(prs[y*G+xp]-prs[y*G+xm])*0.5f*G / r;
  float py = -(prs[yp*G+x]-prs[ym*G+x])*0.5f*G / r;
  acc[idx]=make_float2(gx+px, gy+py);
}

__global__ void kGatherIntegrate(const float2* gacc, float2* pos, float2* vel,
                                 int N, int G, float dt, float damp){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float2 p=pos[i];
  float gx=p.x*G, gy=p.y*G;
  int ix=(int)floorf(gx), iy=(int)floorf(gy);
  float fx=gx-ix, fy=gy-iy;
  float ax=0.f, ay=0.f;
  #pragma unroll
  for(int k=0;k<4;k++){
    int ox=k&1, oy=(k>>1)&1;
    int cx=(ix+ox)&(G-1), cy=(iy+oy)&(G-1);
    float w=(ox?fx:1.f-fx)*(oy?fy:1.f-fy);
    float2 a=gacc[cy*G+cx];
    ax+=w*a.x; ay+=w*a.y;
  }
  float2 v=vel[i];
  v.x=(v.x+ax*dt)*damp; v.y=(v.y+ay*dt)*damp;
  p.x+=v.x*dt; p.y+=v.y*dt;
  p.x-=floorf(p.x); p.y-=floorf(p.y);
  vel[i]=v; pos[i]=p;
}

static void dumpRaw(const char* path, const std::vector<float>& v){
  FILE* f=fopen(path,"wb");
  if(!f){ printf("파일 열기 실패: %s\n", path); return; }
  fwrite(v.data(), sizeof(float), v.size(), f);
  fclose(f);
}

int main(int argc, char** argv){
  const int BS=256;
  const int N   = 2000000;
  const int G   = 1024;
  const int cells=G*G, W=G/2+1;

  float2 *dPos,*dVel,*dAcc; float *dRho,*dPot,*dPrs;
  CK(cudaMalloc(&dPos,sizeof(float2)*N)); CK(cudaMalloc(&dVel,sizeof(float2)*N));
  CK(cudaMalloc(&dAcc,sizeof(float2)*cells));
  CK(cudaMalloc(&dRho,sizeof(float)*cells));
  CK(cudaMalloc(&dPot,sizeof(float)*cells));
  CK(cudaMalloc(&dPrs,sizeof(float)*cells));
  cufftComplex* dSpec; CK(cudaMalloc(&dSpec,sizeof(cufftComplex)*W*G));
  cufftHandle pf,pb; cufftPlan2d(&pf,G,G,CUFFT_R2C); cufftPlan2d(&pb,G,G,CUFFT_C2R);
  int gN=(N+BS-1)/BS, gC=(cells+BS-1)/BS;
  dim3 b2(16,16), g2((G+15)/16,(G+15)/16), gs((W+15)/16,(G+15)/16);

  std::vector<float> host(cells);

  struct Scene { const char* name; int scene; float gravK; float presK; float gamma; float dt; int steps; int shots[4]; };
  Scene scenes[] = {
    {"spiral",   0, 3.0e-6f, 2.0e-9f, 1.6f, 0.0016f, 2400, {  300,  900, 1600, 2400}},
    {"tidal",    1, 3.0e-6f, 1.0e-9f, 1.6f, 0.0016f, 1800, {  200,  600, 1100, 1800}},
    {"shock",    2, 1.0e-6f, 8.0e-9f, 1.6f, 0.0010f, 1400, {  150,  400,  700, 1400}},
    {"structure",3, 6.0e-6f, 1.0e-9f, 1.6f, 0.0016f, 3000, {  400, 1200, 2000, 3000}},
  };

  for(auto& S : scenes){
    printf("[%s] 시작 N=%d G=%d steps=%d\n", S.name, N, G, S.steps);
    kInit<<<gN,BS>>>(dPos,dVel,N,S.scene);
    CK(cudaDeviceSynchronize());
    int shotIdx=0;
    for(int step=1; step<=S.steps; ++step){
      kClearF<<<gC,BS>>>(dRho,cells);
      kScatterCIC<<<gN,BS>>>(dPos,dRho,N,G);
      // 중력
      cufftExecR2C(pf,dRho,dSpec);
      kPoisson<<<gs,b2>>>(dSpec,G,1.0f);
      cufftExecC2R(pb,dSpec,dPot);
      // 압력 (같은 격자)
      kPressure<<<gC,BS>>>(dRho,dPrs,cells,S.presK,S.gamma);
      // 중력+압력 합성
      kGridAccel<<<g2,b2>>>(dPot,dPrs,dRho,dAcc,G,S.gravK/(float)cells);
      kGatherIntegrate<<<gN,BS>>>(dAcc,dPos,dVel,N,G,S.dt,0.99995f);

      if(shotIdx<4 && step==S.shots[shotIdx]){
        CK(cudaMemcpy(host.data(),dRho,sizeof(float)*cells,cudaMemcpyDeviceToHost));
        char path[256];
        snprintf(path,sizeof(path),"D:\\Project\\Nbody\\proto\\out\\%s_%d.raw",S.name,shotIdx);
        dumpRaw(path,host);
        printf("   step %5d -> %s\n", step, path);
        shotIdx++;
      }
    }
    CK(cudaDeviceSynchronize());
  }

  cudaFree(dPos);cudaFree(dVel);cudaFree(dAcc);cudaFree(dRho);cudaFree(dPot);cudaFree(dPrs);cudaFree(dSpec);
  cufftDestroy(pf);cufftDestroy(pb);
  printf("\nGRID=%d\nRESULT: DONE\n", G);
  return 0;
}
