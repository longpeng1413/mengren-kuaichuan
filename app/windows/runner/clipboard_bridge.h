#ifndef RUNNER_CLIPBOARD_BRIDGE_H_
#define RUNNER_CLIPBOARD_BRIDGE_H_

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

// Clipboard access for the chat input (paste picture/file) and the bubble
// menu (copy). Everything runs on the platform thread; each call opens and closes
// the clipboard so other programs are never blocked.
namespace clipboard_bridge {

struct Peek {
  bool files = false;  // CF_HDROP: files copied in Explorer
  bool image = false;  // "PNG" or CF_DIB: screenshots, "copy image"
  bool text = false;   // CF_UNICODETEXT
};

Peek PeekClipboard();

// Regular files from CF_HDROP (UTF-8 paths). Folders are counted in
// |skipped_folders| and left out because they cannot be sent.
std::vector<std::string> ReadClipboardFiles(int& skipped_folders);

// The clipboard bitmap as PNG bytes: the "PNG" format when an app provides
// it (keeps transparency), otherwise CF_DIB converted with GDI+. Empty when
// there is no picture.
std::vector<uint8_t> ReadClipboardImagePng();

// Puts the files on the clipboard as CF_HDROP (paste into Explorer/WeChat).
// A single picture additionally goes in as CF_DIB so Paint, Word or QQ can
// paste it as an image. |owner| must be a window of this process.
bool CopyFilesToClipboard(HWND owner, const std::vector<std::string>& paths);

}  // namespace clipboard_bridge

#endif  // RUNNER_CLIPBOARD_BRIDGE_H_
