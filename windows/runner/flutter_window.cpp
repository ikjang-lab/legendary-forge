#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  if (forge_) forge_->Stop();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) return false;

  RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) return false;

  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // ── Forge 자동화 초기화 ───────────────────────────────────────────────────
  forge_ = std::make_unique<ForgeAutomation>(GetHandle());
  forge_->Initialize();

  // ── Platform Channel 설정 ─────────────────────────────────────────────────
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "com.ikjang.legendary_forge/forge",
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const std::string& method = call.method_name();
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        auto getInt = [&](const char* key, int def = 0) -> int {
          if (!args) return def;
          auto it = args->find(flutter::EncodableValue(key));
          if (it == args->end()) return def;
          if (auto* v = std::get_if<int>(&it->second)) return *v;
          return def;
        };

        if (method == "startAutomation") {
          forge_->targetLevel = getInt("targetLevel", forge_->targetLevel);
          forge_->Start();
          result->Success();
        } else if (method == "stopAutomation") {
          forge_->Stop();
          result->Success();
        } else if (method == "getIsRunning") {
          result->Success(flutter::EncodableValue(forge_->isRunning.load()));
        } else if (method == "saveTargetLevel") {
          forge_->targetLevel = getInt("level", 10);
          result->Success();
        } else if (method == "getTargetLevel") {
          result->Success(flutter::EncodableValue(forge_->targetLevel));
        } else if (method == "setCurrentLevel") {
          forge_->currentLevel = getInt("level", 0);
          result->Success();
        } else if (method == "isAccessibilityEnabled") {
          // Windows는 별도 접근성 권한 불필요
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });
  flutter_controller_->ForceRedraw();
  return true;
}

void FlutterWindow::OnDestroy() {
  if (forge_) forge_->Stop();
  flutter_controller_ = nullptr;
  Win32Window::OnDestroy();
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                                       WPARAM const wparam,
                                       LPARAM const lparam) noexcept {
  // 자동화 상태 업데이트 → Flutter로 전달
  if (message == WM_FORGE_STATUS) {
    auto* s = reinterpret_cast<ForgeStatus*>(lparam);
    if (s && channel_) {
      flutter::EncodableMap map{
          {flutter::EncodableValue("text"),  flutter::EncodableValue(s->text)},
          {flutter::EncodableValue("color"), flutter::EncodableValue(s->color)},
          {flutter::EncodableValue("level"), flutter::EncodableValue(s->level)},
          {flutter::EncodableValue("gold"),  flutter::EncodableValue((int64_t)s->gold)},
      };
      channel_->InvokeMethod("onStatus",
                              std::make_unique<flutter::EncodableValue>(map));
    }
    delete s;
    return 0;
  }

  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam);
    if (result) return *result;
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
