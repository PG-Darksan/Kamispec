#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  //
  // |minimal| = the cursor-wrap resident (--cursor-wrap). In that mode we do
  // NOT register any plugin and never show the window, so the background
  // process stays as small as possible (the user asked for the resident to
  // stay light; the normal app loads ~20 plugins including ffmpeg and the
  // media stack, which is far too much just to move the mouse pointer).
  explicit FlutterWindow(const flutter::DartProject& project,
                         bool minimal = false);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // True for the cursor-wrap resident: no plugins, never shown.
  bool minimal_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
