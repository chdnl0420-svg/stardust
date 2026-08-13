cmake_minimum_required(VERSION 3.24)
project(nbody LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

# RTX 3070 Ti = compute capability 8.6 (Ampere)
set(CMAKE_CUDA_ARCHITECTURES 86)

if(MSVC)
  # CCCL(CUB/Thrust)이 MSVC 표준 전처리기를 요구한다. 기본값(traditional)이면 컴파일 자체가 막힌다.
  # /utf-8 은 한글 주석·문자열이 CP949 로 잘못 읽히는 것을 막는다.
  add_compile_options(
    $<$<COMPILE_LANGUAGE:CXX>:/Zc:preprocessor>
    $<$<COMPILE_LANGUAGE:CXX>:/utf-8>
    $<$<COMPILE_LANGUAGE:CXX>:/W3>
    $<$<COMPILE_LANGUAGE:CUDA>:-Xcompiler=/Zc:preprocessor,/utf-8>
  )
endif()

find_package(CUDAToolkit REQUIRED)

# ---------------------------------------------------------------------------
# Core 층 — 순수 계산. Win32·OpenGL·ImGui 를 전혀 참조하지 않는다.
#          그래서 창 없이 콘솔 테스트로 검증할 수 있다.
# ---------------------------------------------------------------------------
add_library(nbody_sim STATIC
  src/sim/Sim.cu
)
target_include_directories(nbody_sim PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_link_libraries(nbody_sim PUBLIC CUDA::cufft CUDA::cudart)
# 분리 컴파일(relocatable device code)은 .cu 가 여러 개로 갈릴 때만 필요하다.
# 지금은 Sim.cu 하나라 끄고, 켤 경우 순수 C++ 실행파일에서 device link 가 빠져 LNK2019 가 난다.
set_target_properties(nbody_sim PROPERTIES
  CUDA_SEPARABLE_COMPILATION OFF
  POSITION_INDEPENDENT_CODE ON
)

# ---------------------------------------------------------------------------
# 회귀 테스트 — 코어만 링크한다
# ---------------------------------------------------------------------------
# .cpp 로 둔다 — nvcc 의 전처리는 UTF-8 한글 문자열 리터럴에서 깨지고, MSVC 는 /utf-8 로 정상 처리한다.
# Sim.h 가 CUDA 헤더를 노출하지 않는 Pimpl 이라 순수 C++ 로 컴파일해도 문제없다.
add_executable(sim_tests tests/sim_tests.cpp)
target_link_libraries(sim_tests PRIVATE nbody_sim)

# ---------------------------------------------------------------------------
# 앱 — Win32 창 + OpenGL + Dear ImGui
# ---------------------------------------------------------------------------
set(IMGUI_DIR ${CMAKE_CURRENT_SOURCE_DIR}/extern/imgui)

# UI 층은 증분 1 후반에 붙는다. 소스가 아직 없을 때 configure 가 죽지 않도록 존재할 때만 타깃을 만든다.
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/src/main.cpp)
add_executable(nbody WIN32
  src/main.cpp
  src/app/App.cpp
  src/gfx/GLContext.cpp
  src/gfx/RenderField.cpp
  src/ui/Board.cpp
  src/ui/Hud.cpp
  ${IMGUI_DIR}/imgui.cpp
  ${IMGUI_DIR}/imgui_draw.cpp
  ${IMGUI_DIR}/imgui_tables.cpp
  ${IMGUI_DIR}/imgui_widgets.cpp
  ${IMGUI_DIR}/backends/imgui_impl_win32.cpp
  ${IMGUI_DIR}/backends/imgui_impl_opengl3.cpp
)
target_include_directories(nbody PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/src
  ${IMGUI_DIR}
  ${IMGUI_DIR}/backends
)
target_link_libraries(nbody PRIVATE
  nbody_sim
  opengl32
  dwmapi
)
endif()
