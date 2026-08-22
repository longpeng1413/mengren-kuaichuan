#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cwchar>
#include <iterator>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kWindowTitle[] = L"\u731B\u4EBA\u5FEB\u4F20 v1.6.0";
constexpr wchar_t kWindowTitlePrefix[] = L"\u731B\u4EBA\u5FEB\u4F20 v";
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

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Closing the Flutter window hides it in the tray. Clicking a desktop
  // shortcut again must restore that process instead of starting another
  // receiver which would compete for TCP port 53318. Looking for older titles
  // also makes an accidental launch during an upgrade harmless.
  if (HWND existing = FindExistingMengrenWindow(); existing != nullptr) {
    RestoreExistingWindow(existing);
    return EXIT_SUCCESS;
  }

  HANDLE single_instance =
      ::CreateMutexW(nullptr, FALSE, kSingleInstanceMutex);
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

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(kWindowTitle, origin, size)) {
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
