// 라운드8 (X1 시각화 3회차) — x5의 실패 두 건을 고친다
//   x5 결함A: tidal/shock 에 접근속도를 과하게 줘서 두 덩어리가 서로 통과해 경계로 흩어졌다
//             -> 조석꼬리는 "중력에 붙잡혀 감기며" 생기므로 상대속도를 크게 낮추고 충돌변수(offset)를 준다
//   x5 결함B: 두 원반의 자체 회전을 전체 중심(0.5,0.5) 기준으로 줬다
//             -> 가까운 원반 중심을 각자 골라 그 기준으로 회전시킨다
//   추가: spiral 은 원반이 뜨거워져 나선이 풀렸다 -> dt 축소 + 소프트닝 확대로 차갑게 유지
//   structure 는 x5에서 성공했으므로 재실행하지 않는다.
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

__global__ void kPlace(float2* pos,float2* vel,int N,int scene,
                       float c0x,float c0y,float c1x,float c1y,float rad){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float u1=rnd01(i*4u+1u), u2=rnd01(i*4u+2u), u3=rnd01(i*4u+3u);
  float r=sqrtf(u1)*rad, th=u2*6.2831853f;
  if(scene==0){
    pos[i]=make_float2(c0x+r*cosf(th), c0y+r*sinf(th));
  } else {
    int right=(u3>0.5f);
    float cx=right?c1x:c0x, cy=right?c1y:c0y;
    pos[i]=make_float2(cx+r*cosf(th), cy+r*sinf(th));
  }
  vel[i]=make_float2(0.f,0.f);
}

__global__ void kClearF(float* g,int n){ int i=blockIdx.x*blockDim.x+threadIdx.x; if(i<n) g[i]=0.f; }

__global__ void kScatterI(const float2* pos,float* gm,int N,int G,int GP){
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
__global__ void kPressure(const float* rho,float* prs,int n,float K,float gamma){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=n) return;
  prs[i]=K*powf(fmaxf(rho[i],0.f),gamma);
}
__global__ void kGridAccel(const float* pot,const float* prs,const float* rho,
                           float2* acc,int G,int GP,float potScale,int usePressure){
  int x=blockIdx.x*blockDim.x+threadIdx.x, y=blockIdx.y*blockDim.y+threadIdx.y;
  if(x>=G||y>=G) return;
  int xm=max(x-1,0), xp=min(x+1,G-1), ym=max(y-1,0), yp=min(y+1,G-1);
  float ax=-(pot[y*GP+xp]-pot[y*GP+xm])*0.5f*G*potScale;
  float ay=-(pot[yp*GP+x]-pot[ym*GP+x])*0.5f*G*potScale;
  if(usePressure){
    float r=fmaxf(rho[y*GP+x],1e-6f);
    ax += -(prs[y*GP+xp]-prs[y*GP+xm])*0.5f*G/r;
    ay += -(prs[yp*GP+x]-prs[ym*GP+x])*0.5f*G/r;
  }
  acc[y*G+x]=make_float2(ax,ay);
}
__device__ __forceinline__ float2 sampleAcc(const float2* ga,int G,float2 p){
  float gx=p.x*G, gy=p.y*G;
  int ix=(int)floorf(gx), iy=(int)floorf(gy);
  float fx=gx-ix, fy=gy-iy;
  float ax=0.f, ay=0.f;
  #pragma unroll
  for(int k=0;k<4;k++){
    int ox=k&1,oy=(k>>1)&1;
    int cx=min(max(ix+ox,0),G-1), cy=min(max(iy+oy,0),G-1);
    float w=(ox?fx:1.f-fx)*(oy?fy:1.f-fy);
    float2 a=ga[cy*G+cx]; ax+=w*a.x; ay+=w*a.y;
  }
  return make_float2(ax,ay);
}

// 가까운 중심을 각자 골라 그 기준으로 회전시킨다. 두 원반을 독립적으로 스핀시키는 것이 핵심.
__global__ void kSetOrbitNearest(const float2* ga,const float2* pos,float2* vel,int N,int G,
                                 float c0x,float c0y,float c1x,float c1y,int dual,
                                 float fudge,float approach,float shear){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float2 p=pos[i];
  float d0=hypotf(p.x-c0x,p.y-c0y);
  float cx=c0x, cy=c0y; float sign=-1.f;
  if(dual){
    float d1=hypotf(p.x-c1x,p.y-c1y);
    if(d1<d0){ cx=c1x; cy=c1y; sign=1.f; }
  }
  float dx=p.x-cx, dy=p.y-cy;
  float r=sqrtf(dx*dx+dy*dy);
  float vx=0.f, vy=0.f;
  if(r>1e-5f){
    float2 a=sampleAcc(ga,G,p);
    float ar=-(a.x*dx+a.y*dy)/r;
    float v=(ar>0.f)? sqrtf(ar*r)*fudge : 0.f;
    vx=-dy/r*v; vy=dx/r*v;
  }
  if(dual){
    // 아주 작은 접근속도 + 접선 전단 -> 정면충돌이 아니라 감기는 궤도가 된다
    vx += sign*approach;
    vy += sign*shear;
  }
  vel[i]=make_float2(vx,vy);
}

__global__ void kIntegrate(const float2* ga,float2* pos,float2* vel,int N,int G,float dt){
  int i=blockIdx.x*blockDim.x+threadIdx.x; if(i>=N) return;
  float2 p=pos[i], v=vel[i];
  float2 a=sampleAcc(ga,G,p);
  v.x+=a.x*dt; v.y+=a.y*dt;
  p.x+=v.x*dt; p.y+=v.y*dt;
  p.x=fminf(fmaxf(p.x,0.003f),0.997f);
  p.y=fminf(fmaxf(p.y,0.003f),0.997f);
  pos[i]=p; vel[i]=v;
}
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
  const int cells=G*G, cellsP=GP*GP, WP=GP/2+1;
  float2 *dPos,*dVel,*dAcc;
  float *dRho,*dGrn,*dPot,*dPrs,*dCrop;
  cufftComplex *dRhoS,*dGrnS;
  CK(cudaMalloc(&dPos,sizeof(float2)*N)); CK(cudaMalloc(&dVel,sizeof(float2)*N));
  CK(cudaMalloc(&dAcc,sizeof(float2)*cells));
  CK(cudaMalloc(&dRho,sizeof(float)*cellsP)); CK(cudaMalloc(&dGrn,sizeof(float)*cellsP));
  CK(cudaMalloc(&dPot,sizeof(float)*cellsP)); CK(cudaMalloc(&dPrs,sizeof(float)*cellsP));
  CK(cudaMalloc(&dCrop,sizeof(float)*cells));
  CK(cudaMalloc(&dRhoS,sizeof(cufftComplex)*WP*GP));
  CK(cudaMalloc(&dGrnS,sizeof(cufftComplex)*WP*GP));
  cufftHandle pf,pb; cufftPlan2d(&pf,GP,GP,CUFFT_R2C); cufftPlan2d(&pb,GP,GP,CUFFT_C2R);
  int gN=(N+BS-1)/BS, gCP=(cellsP+BS-1)/BS;
  dim3 b2(16,16), gG((G+15)/16,(G+15)/16), gGP((GP+15)/16,(GP+15)/16);
  float cell=1.0f/G;

  std::vector<float> host(cells);

  struct S { const char* name; int scene; int dual; int pressure;
             float c0x,c0y,c1x,c1y,rad;
             float gravK,presK,gamma,dt,eps_cells,fudge,approach,shear;
             int steps; int shots[4]; };
  S scenes[] = {
    // 나선팔: dt 절반, 소프트닝 3셀 -> 원반이 덜 뜨거워져 나선이 오래 남는다
    {"spiral", 0,0,0, 0.5f,0.5f, 0.f,0.f, 0.19f,
     2.0e-4f, 0.f, 1.6f, 0.0013f, 3.0f, 0.95f, 0.f, 0.f, 3000, {500,1200,2100,3000}},
    // 조석꼬리: 접근속도를 x5의 0.16 -> 0.012 로 낮추고 접선 전단을 줘 감기게 한다
    {"tidal",  1,1,0, 0.36f,0.56f, 0.64f,0.44f, 0.085f,
     2.0e-4f, 0.f, 1.6f, 0.0016f, 2.5f, 0.90f, 0.012f, 0.030f, 2600, {600,1300,1950,2600}},
    // 충격파: 정면충돌. 접근속도를 0.30 -> 0.055 로 낮추고 압력을 켠다
    {"shock",  2,1,1, 0.34f,0.50f, 0.66f,0.50f, 0.080f,
     1.6e-4f, 3.0e-9f, 1.6f, 0.0013f, 2.5f, 0.0f, 0.055f, 0.f, 2000, {500,900,1250,2000}},
  };

  for(auto& S_ : scenes){
    float eps = S_.eps_cells*cell;
    kGreen<<<gGP,b2>>>(dGrn,GP,cell,eps);
    cufftExecR2C(pf,dGrn,dGrnS);
    CK(cudaDeviceSynchronize());

    printf("[%s] dual=%d pressure=%s eps=%.1f cells steps=%d\n",
      S_.name, S_.dual, S_.pressure?"on":"off", S_.eps_cells, S_.steps);

    kPlace<<<gN,BS>>>(dPos,dVel,N,S_.scene,S_.c0x,S_.c0y,S_.c1x,S_.c1y,S_.rad);
    CK(cudaDeviceSynchronize());

    auto solve=[&](){
      kClearF<<<gCP,BS>>>(dRho,cellsP);
      kScatterI<<<gN,BS>>>(dPos,dRho,N,G,GP);
      cufftExecR2C(pf,dRho,dRhoS);
      kMulSpec<<<(WP*GP+BS-1)/BS,BS>>>(dRhoS,dGrnS,WP*GP,1.0f/(float)cellsP);
      cufftExecC2R(pb,dRhoS,dPot);
      if(S_.pressure) kPressure<<<gCP,BS>>>(dRho,dPrs,cellsP,S_.presK,S_.gamma);
      kGridAccel<<<gG,b2>>>(dPot,dPrs,dRho,dAcc,G,GP,S_.gravK,S_.pressure);
    };

    solve(); CK(cudaDeviceSynchronize());
    kSetOrbitNearest<<<gN,BS>>>(dAcc,dPos,dVel,N,G,S_.c0x,S_.c0y,S_.c1x,S_.c1y,
                                S_.dual,S_.fudge,S_.approach,S_.shear);
    CK(cudaDeviceSynchronize());

    int si=0;
    for(int step=1; step<=S_.steps; ++step){
      solve();
      kIntegrate<<<gN,BS>>>(dAcc,dPos,dVel,N,G,S_.dt);
      if(si<4 && step==S_.shots[si]){
        kCrop<<<gG,b2>>>(dRho,dCrop,G,GP);
        CK(cudaMemcpy(host.data(),dCrop,sizeof(float)*cells,cudaMemcpyDeviceToHost));
        char path[256];
        snprintf(path,sizeof(path),"D:\\Project\\Nbody\\proto\\out3\\%s_%d.raw",S_.name,si);
        dumpRaw(path,host);
        printf("   step %5d -> %s_%d.raw\n", step, S_.name, si);
        si++;
      }
    }
    CK(cudaDeviceSynchronize());
  }

  cudaFree(dPos);cudaFree(dVel);cudaFree(dAcc);cudaFree(dRho);cudaFree(dGrn);
  cudaFree(dPot);cudaFree(dPrs);cudaFree(dCrop);cudaFree(dRhoS);cudaFree(dGrnS);
  cufftDestroy(pf);cufftDestroy(pb);
  printf("\nRESULT: DONE\n");
  return 0;
}
