#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <desktop_multi_window/desktop_multi_window_plugin.h>
#include <fvp/fvp_plugin_c_api.h>
#include <url_launcher_windows/url_launcher_windows.h>
#include <window_manager/window_manager_plugin.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // The cursor-wrap resident (--cursor-wrap) must stay as small as possible:
  // no plugins, no window. See FlutterWindow's |minimal| flag.
  // NOTE: the vector is moved into the project on the next line, so this
  // check has to happen here.
  bool minimal = false;
  for (const auto& a : command_line_arguments) {
    if (a == "--cursor-wrap") {
      minimal = true;
      break;
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // Register plugins for desktop_multi_window sub-windows. Without this the
  // sub-window engines get no plugins at all, so the floating memo's
  // always-on-top (window_manager) would silently do nothing.
  //
  // NOTE: webview_windows is deliberately NOT registered here.
  //
  // Sub-windows never host a WebView of their own -- they hand the work back
  // to the main window (see 'openFloatingAi' / 'openFloatingWeb' in
  // lib/main.dart). Registering the plugin anyway made the plugin build a
  // second WebView2 host bound to the sub-window's engine, and tearing that
  // engine down when the sub-window closed left the process unable to create
  // any further WebView: every later attempt in the MAIN window failed with
  //   CreateCoreWebView2CompositionController failed (HRESULT 0x80070057)
  // which broke the split browser, the docked Google search and the in-app
  // viewers for the rest of the session. Reproduced reliably by opening the
  // floating memo once, closing it, then opening the split browser.
  // Sub-windows are never created by the resident, so skip this too.
  if (!minimal)
  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    auto *engine = flutter_view_controller->engine();
    WindowManagerPluginRegisterWithRegistrar(
        engine->GetRegistrarForPlugin("WindowManagerPlugin"));
    UrlLauncherWindowsRegisterWithRegistrar(
        engine->GetRegistrarForPlugin("UrlLauncherWindows"));
    // fvp: the screen-recorder sub-window plays the finished recording
    // inside itself (video_player backed by fvp). Unlike webview_windows,
    // fvp keeps no process-wide host that breaks on engine teardown --
    // each texture/player belongs to its own engine.
    FvpPluginCApiRegisterWithRegistrar(
        engine->GetRegistrarForPlugin("FvpPluginCApi"));
  });

  FlutterWindow window(project, minimal);
  // The resident's window is 1x1 and parked far off-screen. It is never
  // shown (FlutterWindow skips the show callback), so this is only a
  // belt-and-braces measure in case something else calls ShowWindow.
  Win32Window::Point origin(minimal ? -32000 : 10, minimal ? -32000 : 10);
  Win32Window::Size size(minimal ? 1 : 1280, minimal ? 1 : 720);
  if (!window.Create(L"HisatorNotebook", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
