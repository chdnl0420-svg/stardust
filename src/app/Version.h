// 이 빌드의 버전. 자동 업데이트가 저장소의 최신 버전과 견주는 기준값이다.
//
// 새 버전을 낼 때 여기를 올리고, 저장소에는 같은 번호로 태그(v0.1.0)를 단다.
// 둘이 어긋나면 앱이 자기보다 낮은 버전을 새 버전으로 알고 계속 내려받으려 든다.
#pragma once

#define STARDUST_VERSION "0.6.2"

// 배포 저장소. 업데이트를 여기서만 받는다 —
// 주소를 밖에서 바꿀 수 있게 두면 그것이 곧 임의의 실행 파일을 받아 오는 통로가 된다.
#define STARDUST_REPO_OWNER "chdnl0420-svg"
#define STARDUST_REPO_NAME  "stardust"
