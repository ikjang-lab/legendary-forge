# ⚔️ 대장간 자동강화

카카오톡 대장간 게임봇의 `/강화` 명령어를 자동으로 반복 실행하는 도구입니다.  
목표 강화 수치에 도달하면 자동으로 중지됩니다.

## 지원 플랫폼

| 플랫폼 | 방식 | 상태 |
|--------|------|------|
| Android | AccessibilityService + 오버레이 UI | ✅ |
| macOS | AXUIElement 접근성 API | ✅ |
| Windows | UI Automation API | ✅ |

---

## 사용 방법

### Android
1. 앱 설치 후 **접근성 서비스** 권한 허용
2. **다른 앱 위에 표시** 권한 허용
3. 카카오톡 대장간 채팅방 진입
4. 화면 오른쪽에 나타나는 오버레이 패널에서 목표 강화 수치 설정
5. 🔨 **시작** 버튼 클릭

### macOS
1. 앱 실행 후 **시스템 설정 → 개인 정보 보호 → 손쉬운 사용**에서 앱 허용
2. 카카오톡 Mac 앱에서 대장간 채팅방 열기
3. 앱에서 목표 강화 수치 설정 후 **🔨 시작** 클릭

### Windows
1. 앱 실행 (별도 권한 설정 불필요)
2. 카카오톡 PC 앱에서 대장간 채팅방 열기
3. 앱에서 목표 강화 수치 설정 후 **🔨 시작** 클릭

---

## 빌드 방법

### Android APK
```bash
flutter build apk --release
# 결과: build/app/outputs/flutter-apk/app-release.apk
```

### macOS App
```bash
flutter build macos --release
# 결과: build/macos/Build/Products/Release/legendary_forge.app
```

### Windows EXE
Windows 환경에서:
```bash
flutter build windows --release
# 결과: build/windows/x64/runner/Release/legendary_forge.exe
```

또는 **GitHub Actions**를 통해 자동 빌드 (Actions 탭 → Run workflow)

---

## 동작 원리

```
/강화 전송
    ↓
봇 응답 감지 (성공 / 유지 / 파괴)
    ↓
현재 레벨 업데이트
    ↓
목표 달성? → 중지
아니오?   → 0.8초 후 재시도
```

- **강화 성공**: 레벨 +1, 계속 진행
- **강화 유지**: 레벨 유지, 계속 진행
- **강화 파괴**: 레벨 0 리셋, 계속 진행

---

## 주의사항

- 이 도구는 개인 학습 및 자동화 실험 목적으로 제작되었습니다.
- 게임 운영 정책에 따라 사용이 제한될 수 있습니다.
