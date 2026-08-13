#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // ── 閉じる保険 (= ユーザー報告: アプリを終了させられない事がある) ──
  // × (WM_CLOSE) を受けたら、 Dart 側の終了処理が固まっていても 4 秒後に
  // 必ずプロセスを終える監視スレッドを立てる。 2 回目の × は即終了。
  // この下の HandleTopLevelWindowProc で window_manager (preventClose) が
  // WM_CLOSE を横取りするため、 最上流のここで仕掛ける。
  if (message == WM_CLOSE) {
    static LONG close_count = 0;
    if (::InterlockedIncrement(&close_count) >= 2) {
      ::TerminateProcess(::GetCurrentProcess(), 0);
    }
    HANDLE watchdog = ::CreateThread(
        nullptr, 0,
        [](LPVOID) -> DWORD {
          ::Sleep(4000);
          ::TerminateProcess(::GetCurrentProcess(), 0);
          return 0;
        },
        nullptr, 0, nullptr);
    if (watchdog) {
      ::CloseHandle(watchdog);
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
