#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include <algorithm>
#include <cwchar>
#include <iterator>

#include "flutter_window.h"
#include "utils.h"
#include "window_size_store.h"

namespace {

constexpr wchar_t kWindowTitle[] = L"\u731B\u4EBA\u5FEB\u4F20 v1.12.0";
constexpr wchar_t kWindowTitlePrefix[] = L"\u731B\u4EBA\u5FEB\u4F20 v";
// Picture window (--image-viewer): "<app name> <picture viewer>". It must
// not start with kWindowTitlePrefix, or the single-instance check would
// mistake it for the main window.
constexpr wchar_t kViewerTitle[] = L"\u731B\u4EBA\u5FEB\u4F20 \u56FE\u7247\u67E5\u770B";
constexpr char kImageViewerArgument[] = "--image-viewer";
constexpr unsigned int kViewerWidth = 960;
constexpr unsigned int kViewerHeight = 720;

constexpr wchar_t kSingleInstanceMutex[] =
    L"Local\\MengrenLanTransfer.SingleInstance";

BOOL CALLBACK FindMengrenWindow(HWND window, LPARAM result) {
  wchar_t title[256] = {};
  if (::GetWindowTextW(window, title, static_cast<int>(std::size(title))) <= 0) {
    return TRUE;
  }
  if (::wcsncmp(title, kWindowTitlePrefix,
                std::size(kWindowTitlePrefix) - 1) == 0) {
    *reinterpret_cast<HWND*>(result) = window;
    return FALSE;
  }
  return TRUE;
}

HWND FindExistingMengrenWindow() {
  HWND window = nullptr;
  ::EnumWindows(FindMengrenWindow, reinterpret_cast<LPARAM>(&window));
  return window;
}

void RestoreExistingWindow(HWND window) {
  if (window == nullptr) {
    return;
  }
  ::ShowWindowAsync(window, SW_RESTORE);
  ::ShowWindowAsync(window, SW_SHOW);
  ::SetForegroundWindow(window);
}

// First-launch size; afterwards the size the user left the window at is
// restored (see window_size_store).
constexpr unsigned int kWindowWidth = 750;
constexpr unsigned int kWindowHeight = 760;

// Centres the window on the primary monitor's work area and shrinks it on
// small screens. Win32Window::Create takes logical (96 DPI) coordinates.
void CenterOnPrimaryMonitor(Win32Window::Point& origin,
                            Win32Window::Size& size) {
  HMONITOR monitor = ::MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (monitor == nullptr || !::GetMonitorInfoW(monitor, &info)) {
    return;
  }
  const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  const double work_left = info.rcWork.left / scale;
  const double work_top = info.rcWork.top / scale;
  const double work_width = (info.rcWork.right - info.rcWork.left) / scale;
  const double work_height = (info.rcWork.bottom - info.rcWork.top) / scale;
  const double width = (std::min)(static_cast<double>(size.width),
                                  work_width - 40);
  const double height = (std::min)(static_cast<double>(size.height),
                                   work_height - 40);
  if (width < 200 || height < 200) {
    return;
  }
  size = Win32Window::Size(static_cast<unsigned int>(width),
                           static_cast<unsigned int>(height));
  origin = Win32Window::Point(
      static_cast<unsigned int>(work_left + (work_width - width) / 2),
      static_cast<unsigned int>(work_top + (work_height - height) / 2));
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  // The chat process starts a second copy of itself as the picture window
  // (like WeChat for PC). That copy skips the single-instance check, the
  // tray and the network; Dart sees the same argument.
  const bool image_viewer =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                kImageViewerArgument) != command_line_arguments.end();

  // Closing the Flutter window hides it in the tray. Clicking a desktop
  // shortcut again must restore that process instead of starting another
  // receiver which would compete for TCP port 53318. Looking for older titles
  // also makes an accidental launch during an upgrade harmless.
  if (!image_viewer) {
    if (HWND existing = FindExistingMengrenWindow(); existing != nullptr) {
      RestoreExistingWindow(existing);
      return EXIT_SUCCESS;
    }
  }

  HANDLE single_instance =
      image_viewer ? nullptr
                   : ::CreateMutexW(nullptr, FALSE, kSingleInstanceMutex);
  if (single_instance != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    RestoreExistingWindow(FindExistingMengrenWindow());
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // The login entry adds --silent when silent start is on: tray only.
  const bool start_hidden =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--silent") != command_line_arguments.end();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.set_start_hidden(start_hidden && !image_viewer);
  // The picture window has its own default size and must not overwrite the
  // chat window's remembered size.
  window.set_remember_size(!image_viewer);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(image_viewer ? kViewerWidth : kWindowWidth,
                         image_viewer ? kViewerHeight : kWindowHeight);
  unsigned int saved_width = 0;
  unsigned int saved_height = 0;
  if (!image_viewer && window_size_store::Load(saved_width, saved_height)) {
    size = Win32Window::Size(saved_width, saved_height);
  }
  CenterOnPrimaryMonitor(origin, size);
  if (!window.Create(image_viewer ? kViewerTitle : kWindowTitle, origin,
                     size)) {
    if (single_instance != nullptr) {
      ::CloseHandle(single_instance);
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance != nullptr) {
    ::CloseHandle(single_instance);
  }
  return EXIT_SUCCESS;
}
