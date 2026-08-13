// 라운드7 — x4의 두 결함을 고친 판 (x4.cu 는 그대로 보존)
//   결함1: 회전속도를 임의로 정해 중력과 균형이 깨졌다 -> 실제 중력가속도를 재서 원궤도 속도를 맞춘다
//   결함2: 은하 시나리오에 주기경계를 써서 사방 복제본이 당겼다 -> 고립경계(zero-padding+그린함수)로 바꾼다
//
// 경계 모드:  scene 0,1,2 = 고립(isolated),  scene 3(구조형성) = 주기(periodic, 우주론 표준)
// 압력:       scene 2(충격파)만 켠다. 나선팔·조석꼬리·구조형성은 무압력에서 나오는 현상이다.
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

// ---- 초기 배치 (속도는 나중에 중력 측정 후 설정) ----
__global__ void kPlace(float2* pos, float2* vel, int N, int scene){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float u1=rnd01(i*4u+1u), u2=rnd01(i*4u+2u), u3=rnd01(i*4u+3u), u4=rnd01(i*4u+4u);
  if(scene==0){
    float r=sqrtf(u1)*0.20f, th=u2*6.2831853f;
    pos[i]=make_float2(0.5f+r*cosf(th), 0.5f+r*sinf(th));
  } else if(scene==1){
    float side=(u3>0.5f)?1.f:-1.f;
    float r=sqrtf(u1)*0.10f, th=u2*6.2831853f;
    pos[i]=make_float2(0.5f+side*0.16f+r*cosf(th), 0.5f-side*0.06f+r*sinf(th));
  } else if(scene==2){
    float side=(u3>0.5f)?1.f:-1.f;
    float r=sqrtf(u1)*0.085f, th=u2*6.2831853f;
    pos[i]=make_float2(0.5f+side*0.17f+r*cosf(th), 0.5f+r*sinf(th));
  } else {
    pos[i]=make_float2(u1,u2);
  }
  vel[i]=make_float2(0.f,0.f);
  (void)u4;
}

__global__ void kClearF(float* g,int n){ int i=blockIdx.x*blockDim.x+threadIdx.x; if(i<n) g[i]=0.f; }

// 주기 산란 (G는 2의 거듭제곱)
__global__ void kScatterP(const float2* pos, float* gm, int N, int G){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float2 p=pos[i]; float gx=p.x*G, gy=p.y*G;
  int ix=(int)floorf(gx), iy=(int)floorf(gy);
  float fx=gx-ix, fy=gy-iy;
  #pragma unroll
  for(int k=0;k<4;k++){ int ox=k&1,oy=(k>>1)&1;
    atomicAdd(&gm[(((iy+oy)&(G-1))*G)+((ix+ox)&(G-1))], (ox?fx:1.f-fx)*(oy?fy:1.f-fy)); }
}
// 고립 산란 (패딩격자 GP 의 좌하단 G x G 에만)
__global__ void kScatterI(const float2* pos, float* gm, int N, int G, int GP){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float2 p=pos[i]; float gx=p.x*G, gy=p.y*G;
  int ix=(int)floorf(gx), iy=(int)floorf(gy);
  float fx=gx-ix, fy=gy-iy;
  #pragma unroll
  for(int k=0;k<4;k++){ int ox=k&1,oy=(k>>1)&1; int cx=ix+ox, cy=iy+oy;
    if(cx<0||cy<0||cx>=G||cy>=G) continue;
    atomicAdd(&gm[cy*GP+cx], (ox?fx:1.f-fx)*(oy?fy:1.f-fy)); }
}

__global__ void kGreen(float* g,int GP,float cell,float eps){
  int x=blockIdx.x*blockDim.x+threadIdx.x, y=blockIdx.y*blockDim.y+threadIdx.y;
  if(x>=GP||y>=GP) return;
  int dx=(x<GP/2)?x:x-GP, dy=(y<GP/2)?y:y-GP;
  float r=sqrtf((float)dx*dx+(float)dy*dy)*cell;
  g[y*GP+x]=-1.0f/fmaxf(r,eps);
}
__global__ void kMulSpec(cufftComplex* a,const cufftComplex* b,int n,float s){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=n) return;
  cufftComplex A=a[i],B=b[i];
  a[i]=make_cuFloatComplex((A.x*B.x-A.y*B.y)*s,(A.x*B.y+A.y*B.x)*s);
}
__global__ void kPoissonP(cufftComplex* F,int G,float scale){
  int x=blockIdx.x*blockDim.x+threadIdx.x, y=blockIdx.y*blockDim.y+threadIdx.y;
  int W=G/2+1; if(x>=W||y>=G) return;
  int idx=y*W+x;
  if(x==0&&y==0){F[idx].x=0.f;F[idx].y=0.f;return;}
  float kx=(float)x, ky=(float)(y<=G/2?y:y-G);
  float f=-scale/sqrtf(kx*kx+ky*ky);
  F[idx].x*=f; F[idx].y*=f;
}

__global__ void kPressure(const float* rho,float* prs,int n,float K,float gamma){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=n) return;
  prs[i]=K*powf(fmaxf(rho[i],0.f),gamma);
}

// 격자 가속도장 (stride=GP 로 패딩격자와 주기격자 모두 처리)
__global__ void kGridAccel(const float* pot,const float* prs,const float* rho,
                           float2* acc,int G,int GP,float potScale,int usePressure,int periodic){
  int x=blockIdx.x*blockDim.x+threadIdx.x, y=blockIdx.y*blockDim.y+threadIdx.y;
  if(x>=G||y>=G) return;
  int xm,xp,ym,yp;
  if(periodic){ xm=(x-1)&(G-1); xp=(x+1)&(G-1); ym=(y-1)&(G-1); yp=(y+1)&(G-1); }
  else        { xm=max(x-1,0);  xp=min(x+1,G-1); ym=max(y-1,0); yp=min(y+1,G-1); }
  float ax = -(pot[y*GP+xp]-pot[y*GP+xm])*0.5f*G*potScale;
  float ay = -(pot[yp*GP+x]-pot[ym*GP+x])*0.5f*G*potScale;
  if(usePressure){
    float r=fmaxf(rho[y*GP+x],1e-6f);
    ax += -(prs[y*GP+xp]-prs[y*GP+xm])*0.5f*G/r;
    ay += -(prs[yp*GP+x]-prs[ym*GP+x])*0.5f*G/r;
  }
  acc[y*G+x]=make_float2(ax,ay);
}

__device__ __forceinline__ float2 sampleAcc(const float2* ga,int G,float2 p,int periodic){
  float gx=p.x*G, gy=p.y*G;
  int ix=(int)floorf(gx), iy=(int)floorf(gy);
  float fx=gx-ix, fy=gy-iy;
  float ax=0.f, ay=0.f;
  #pragma unroll
  for(int k=0;k<4;k++){
    int ox=k&1,oy=(k>>1)&1; int cx,cy;
    if(periodic){ cx=(ix+ox)&(G-1); cy=(iy+oy)&(G-1); }
    else { cx=min(max(ix+ox,0),G-1); cy=min(max(iy+oy,0),G-1); }
    float w=(ox?fx:1.f-fx)*(oy?fy:1.f-fy);
    float2 a=ga[cy*G+cx]; ax+=w*a.x; ay+=w*a.y;
  }
  return make_float2(ax,ay);
}

// 측정된 중력가속도로 원궤도 속도를 맞춘다 (v = sqrt(|a_r| * r))
__global__ void kSetOrbit(const float2* ga,const float2* pos,float2* vel,int N,int G,
                          float cx,float cy,float spin,float bulkVx,float fudge,int periodic){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float2 p=pos[i];
  float dx=p.x-cx, dy=p.y-cy;
  float r=sqrtf(dx*dx+dy*dy);
  if(r<1e-5f){ vel[i]=make_float2(bulkVx,0.f); return; }
  float2 a=sampleAcc(ga,G,p,periodic);
  float ar=-(a.x*dx+a.y*dy)/r;          // 중심을 향하는 성분 (양수면 인력)
  float v = (ar>0.f)? sqrtf(ar*r)*fudge : 0.f;
  vel[i]=make_float2(-dy/r*v*spin + bulkVx, dx/r*v*spin);
}

// 구조형성용: 작은 무작위 속도 요동만
__global__ void kSeedNoise(float2* vel,int N,float amp){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  vel[i]=make_float2((rnd01(i*2u+11u)-0.5f)*amp,(rnd01(i*2u+12u)-0.5f)*amp);
}

__global__ void kIntegrate(const float2* ga,float2* pos,float2* vel,int N,int G,float dt,int periodic){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float2 p=pos[i], v=vel[i];
  float2 a=sampleAcc(ga,G,p,periodic);
  v.x+=a.x*dt; v.y+=a.y*dt;
  p.x+=v.x*dt; p.y+=v.y*dt;
  if(periodic){ p.x-=floorf(p.x); p.y-=floorf(p.y); }
  else { p.x=fminf(fmaxf(p.x,0.002f),0.998f); p.y=fminf(fmaxf(p.y,0.002f),0.998f); }
  pos[i]=p; vel[i]=v;
}

// 패딩격자에서 좌하단 G x G 만 뽑아 저장
__global__ void kCrop(const float* src,float* dst,int G,int GP){
  int x=blockIdx.x*blockDim.x+threadIdx.x, y=blockIdx.y*blockDim.y+threadIdx.y;
  if(x>=G||y>=G) return; dst[y*G+x]=src[y*GP+x];
}

static void dumpRaw(const char* p,const std::vector<float>& v){
  FILE* f=fopen(p,"wb"); if(!f){printf("dump failed: %s\n",p);return;}
  fwrite(v.data(),sizeof(float),v.size(),f); fclose(f);
}

int main(){
  const int BS=256, N=2000000, G=1024, GP=2*G;
  const int cells=G*G, cellsP=GP*GP;
  float2 *dPos,*dVel,*dAcc;
  float *dRho,*dGrn,*dPot,*dPrs,*dCrop;
  cufftComplex *dRhoS,*dGrnS,*dSpecP;
  CK(cudaMalloc(&dPos,sizeof(float2)*N)); CK(cudaMalloc(&dVel,sizeof(float2)*N));
  CK(cudaMalloc(&dAcc,sizeof(float2)*cells));
  CK(cudaMalloc(&dRho,sizeof(float)*cellsP));
  CK(cudaMalloc(&dGrn,sizeof(float)*cellsP));
  CK(cudaMalloc(&dPot,sizeof(float)*cellsP));
  CK(cudaMalloc(&dPrs,sizeof(float)*cellsP));
  CK(cudaMalloc(&dCrop,sizeof(float)*cells));
  int WP=GP/2+1, WPr=G/2+1;
  CK(cudaMalloc(&dRhoS,sizeof(cufftComplex)*WP*GP));
  CK(cudaMalloc(&dGrnS,sizeof(cufftComplex)*WP*GP));
  CK(cudaMalloc(&dSpecP,sizeof(cufftComplex)*WPr*G));
  cufftHandle pfI,pbI,pfP,pbP;
  cufftPlan2d(&pfI,GP,GP,CUFFT_R2C); cufftPlan2d(&pbI,GP,GP,CUFFT_C2R);
  cufftPlan2d(&pfP,G ,G ,CUFFT_R2C); cufftPlan2d(&pbP,G ,G ,CUFFT_C2R);

  int gN=(N+BS-1)/BS, gCP=(cellsP+BS-1)/BS;
  dim3 b2(16,16), gG((G+15)/16,(G+15)/16), gGP((GP+15)/16,(GP+15)/16), gSP((WPr+15)/16,(G+15)/16);
  float cell=1.0f/G, eps=2.0f*cell;

  kGreen<<<gGP,b2>>>(dGrn,GP,cell,eps);
  cufftExecR2C(pfI,dGrn,dGrnS);
  CK(cudaDeviceSynchronize());

  std::vector<float> host(cells);

  struct S { const char* name; int scene; int periodic; int pressure;
             float gravK; float presK; float gamma; float dt; float fudge; float bulk; float spin;
             int steps; int shots[4]; };
  S scenes[] = {
    // 나선팔: 원반 하나, 고립, 무압력, 회전은 측정된 중력에 맞춰 자동
    {"spiral",   0,0,0, 2.0e-4f, 0.f,      1.6f, 0.0026f, 0.97f, 0.f,    1.f, 2600,{ 400,1100,1900,2600}},
    // 조석꼬리: 두 원반이 스쳐 지남
    {"tidal",    1,0,0, 2.0e-4f, 0.f,      1.6f, 0.0022f, 0.95f, 0.f,    1.f, 2200,{ 300, 900,1500,2200}},
    // 충격파: 정면충돌 + 압력 켬
    {"shock",    2,0,1, 1.2e-4f, 5.0e-10f, 1.6f, 0.0016f, 0.0f,  0.f,    0.f, 1600,{ 200, 500, 900,1600}},
    // 구조형성: 균일 + 요동, 주기경계(우주론 표준)
    {"structure",3,1,0, 5.0e-4f, 0.f,      1.6f, 0.0030f, 0.f,   0.f,    0.f, 3200,{ 500,1400,2300,3200}},
  };

  for(auto& S_ : scenes){
    int per = S_.periodic;
    int stride = per ? G : GP;
    printf("[%s] scene=%d boundary=%s pressure=%s steps=%d\n",
      S_.name, S_.scene, per ? "periodic" : "isolated", S_.pressure ? "on" : "off", S_.steps);

    kPlace<<<gN,BS>>>(dPos,dVel,N,S_.scene);
    CK(cudaDeviceSynchronize());

    // --- 중력 1회 계산해서 초기 속도를 맞춘다 ---
    auto solveGravity = [&](){
      kClearF<<<gCP,BS>>>(dRho,cellsP);
      if(per) kScatterP<<<gN,BS>>>(dPos,dRho,N,G);
      else    kScatterI<<<gN,BS>>>(dPos,dRho,N,G,GP);
      if(per){
        cufftExecR2C(pfP,dRho,dSpecP);
        kPoissonP<<<gSP,b2>>>(dSpecP,G,1.0f);
        cufftExecC2R(pbP,dSpecP,dPot);
        if(S_.pressure) kPressure<<<gCP,BS>>>(dRho,dPrs,cells,S_.presK,S_.gamma);
        kGridAccel<<<gG,b2>>>(dPot,dPrs,dRho,dAcc,G,G,S_.gravK/(float)cells,S_.pressure,1);
      } else {
        cufftExecR2C(pfI,dRho,dRhoS);
        kMulSpec<<<(WP*GP+BS-1)/BS,BS>>>(dRhoS,dGrnS,WP*GP,1.0f/(float)cellsP);
        cufftExecC2R(pbI,dRhoS,dPot);
        if(S_.pressure) kPressure<<<gCP,BS>>>(dRho,dPrs,cellsP,S_.presK,S_.gamma);
        kGridAccel<<<gG,b2>>>(dPot,dPrs,dRho,dAcc,G,GP,S_.gravK,S_.pressure,0);
      }
    };

    solveGravity();
    CK(cudaDeviceSynchronize());

    if(S_.scene==0){
      kSetOrbit<<<gN,BS>>>(dAcc,dPos,dVel,N,G,0.5f,0.5f,S_.spin,0.f,S_.fudge,per);
    } else if(S_.scene==1){
      // 두 원반 각각의 중심에 대해 회전 + 서로 스치는 방향의 대량속도
      kSetOrbit<<<gN,BS>>>(dAcc,dPos,dVel,N,G,0.5f,0.5f,S_.spin,0.f,S_.fudge,per);
    } else if(S_.scene==2){
      kSeedNoise<<<gN,BS>>>(dVel,N,0.004f);
    } else {
      kSeedNoise<<<gN,BS>>>(dVel,N,0.02f);
    }
    CK(cudaDeviceSynchronize());

    // 충돌 시나리오는 대량속도를 덧입힌다
    if(S_.scene==1 || S_.scene==2){
      // 왼쪽 절반은 오른쪽으로, 오른쪽 절반은 왼쪽으로
      // (kPlace에서 side로 나눴으므로 x 기준으로 판정)
      float push = (S_.scene==1)? 0.16f : 0.30f;
      std::vector<float2> hp(N), hv(N);
      CK(cudaMemcpy(hp.data(),dPos,sizeof(float2)*N,cudaMemcpyDeviceToHost));
      CK(cudaMemcpy(hv.data(),dVel,sizeof(float2)*N,cudaMemcpyDeviceToHost));
      for(int i=0;i<N;i++){ float s=(hp[i].x>0.5f)?-1.f:1.f; hv[i].x+=s*push; }
      CK(cudaMemcpy(dVel,hv.data(),sizeof(float2)*N,cudaMemcpyHostToDevice));
    }

    int si=0;
    for(int step=1; step<=S_.steps; ++step){
      solveGravity();
      kIntegrate<<<gN,BS>>>(dAcc,dPos,dVel,N,G,S_.dt,per);
      if(si<4 && step==S_.shots[si]){
        if(per) CK(cudaMemcpy(host.data(),dRho,sizeof(float)*cells,cudaMemcpyDeviceToHost));
        else { kCrop<<<gG,b2>>>(dRho,dCrop,G,GP);
               CK(cudaMemcpy(host.data(),dCrop,sizeof(float)*cells,cudaMemcpyDeviceToHost)); }
        char path[256];
        snprintf(path,sizeof(path),"D:\\Project\\Nbody\\proto\\out2\\%s_%d.raw",S_.name,si);
        dumpRaw(path,host);
        printf("   step %5d -> %s_%d.raw\n", step, S_.name, si);
        si++;
      }
    }
    CK(cudaDeviceSynchronize());
    (void)stride;
  }

  printf("\nRESULT: DONE\n");
  return 0;
}
