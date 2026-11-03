#include "window_size_store.h"

#include <flutter_windows.h>

namespace window_size_store {
namespace {

constexpr wchar_t kKey[] = L"Software\\MengrenKuaichuan";
constexpr wchar_t kWidth[] = L"WindowWidth";
constexpr wchar_t kHeight[] = L"WindowHeight";

// Same lower bound as the minimum size set from Dart; the upper bound only
// rejects corrupted values, the caller still fits the size to the screen.
constexpr DWORD kMinWidth = 380;
constexpr DWORD kMinHeight = 520;
constexpr DWORD kMaxSide = 10000;

bool ReadDword(const wchar_t* name, DWORD& value) {
  DWORD size = sizeof(value);
  return ::RegGetValueW(HKEY_CURRENT_USER, kKey, name, RRF_RT_REG_DWORD,
                        nullptr, &value, &size) == ERROR_SUCCESS;
}

bool Plausible(DWORD width, DWORD height) {
  return width >= kMinWidth && height >= kMinHeight && width <= kMaxSide &&
         height <= kMaxSide;
}

}  // namespace

bool Load(unsigned int& width, unsigned int& height) {
  DWORD saved_width = 0;
  DWORD saved_height = 0;
  if (!ReadDword(kWidth, saved_width) || !ReadDword(kHeight, saved_height) ||
      !Plausible(saved_width, saved_height)) {
    return false;
  }
  width = saved_width;
  height = saved_height;
  return true;
}

void Save(HWND window) {
  if (window == nullptr) {
    return;
  }
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (!::GetWindowPlacement(window, &placement)) {
    return;
  }
  // rcNormalPosition is the restored size even while maximised or minimised.
  const RECT& rect = placement.rcNormalPosition;
  HMONITOR monitor = ::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  if (scale <= 0) {
    return;
  }
  const DWORD width = static_cast<DWORD>((rect.right - rect.left) / scale + 0.5);
  const DWORD height = static_cast<DWORD>((rect.bottom - rect.top) / scale + 0.5);
  if (!Plausible(width, height)) {
    return;
  }
  ::RegSetKeyValueW(HKEY_CURRENT_USER, kKey, kWidth, REG_DWORD, &width,
                    sizeof(width));
  ::RegSetKeyValueW(HKEY_CURRENT_USER, kKey, kHeight, REG_DWORD, &height,
                    sizeof(height));
}

}  // namespace window_size_store
