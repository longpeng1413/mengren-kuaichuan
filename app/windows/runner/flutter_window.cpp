#include <winsock2.h>
#include <ws2tcpip.h>

#include <iphlpapi.h>

#include "flutter_window.h"

#include <cstdint>
#include <optional>
#include <vector>

#include <flutter/standard_method_codec.h>

#include "clipboard_bridge.h"
#include "flutter/generated_plugin_registrant.h"
#include "utils.h"
#include "window_size_store.h"

namespace {

constexpr char kPlatformChannel[] =
    "com.personal.lantransfer.lan_transfer/files";

flutter::EncodableList GetWindowsNetworkInterfaces() {
  ULONG buffer_size = 15 * 1024;
  std::vector<unsigned char> buffer(buffer_size);
  auto* adapters =
      reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  ULONG result = GetAdaptersAddresses(
      AF_INET,
      GAA_FLAG_INCLUDE_PREFIX | GAA_FLAG_SKIP_ANYCAST |
          GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
      nullptr, adapters, &buffer_size);
  if (result == ERROR_BUFFER_OVERFLOW) {
    buffer.resize(buffer_size);
    adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    result = GetAdaptersAddresses(
        AF_INET,
        GAA_FLAG_INCLUDE_PREFIX | GAA_FLAG_SKIP_ANYCAST |
            GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
        nullptr, adapters, &buffer_size);
  }

  flutter::EncodableList values;
  if (result != NO_ERROR) {
    return values;
  }

  for (auto* adapter = adapters; adapter != nullptr; adapter = adapter->Next) {
    if (adapter->OperStatus != IfOperStatusUp ||
        adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK) {
      continue;
    }
    const std::string interface_name = Utf8FromUtf16(adapter->FriendlyName);
    for (auto* unicast = adapter->FirstUnicastAddress; unicast != nullptr;
         unicast = unicast->Next) {
      if (unicast->Address.lpSockaddr == nullptr ||
          unicast->Address.lpSockaddr->sa_family != AF_INET) {
        continue;
      }
      const auto* socket_address = reinterpret_cast<const sockaddr_in*>(
          unicast->Address.lpSockaddr);
      char address_buffer[INET_ADDRSTRLEN] = {};
      if (InetNtopA(AF_INET, &socket_address->sin_addr, address_buffer,
                    INET_ADDRSTRLEN) == nullptr) {
        continue;
      }

      const unsigned int prefix_length = unicast->OnLinkPrefixLength;
      flutter::EncodableMap entry{
          {flutter::EncodableValue("name"),
           flutter::EncodableValue(interface_name)},
          {flutter::EncodableValue("address"),
           flutter::EncodableValue(std::string(address_buffer))},
          {flutter::EncodableValue("prefixLength"),
           flutter::EncodableValue(static_cast<int>(prefix_length))},
      };

      if (prefix_length < 32) {
        const std::uint32_t host_address =
            ntohl(socket_address->sin_addr.s_addr);
        const std::uint32_t mask = prefix_length == 0
                                       ? 0
                                       : 0xffffffffu << (32 - prefix_length);
        in_addr broadcast_address{};
        broadcast_address.s_addr =
            htonl((host_address & mask) | (~mask));
        char broadcast_buffer[INET_ADDRSTRLEN] = {};
        if (InetNtopA(AF_INET, &broadcast_address, broadcast_buffer,
                      INET_ADDRSTRLEN) != nullptr) {
          entry[flutter::EncodableValue("broadcast")] =
              flutter::EncodableValue(std::string(broadcast_buffer));
        }
      }
      values.emplace_back(std::move(entry));
    }
  }
  return values;
}

}  // namespace

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
  platform_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kPlatformChannel,
          &flutter::StandardMethodCodec::GetInstance());
  platform_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "networkInterfaces") {
          result->Success(flutter::EncodableValue(
              GetWindowsNetworkInterfaces()));
          return;
        }
        if (method == "clipboardPeek") {
          const clipboard_bridge::Peek peek = clipboard_bridge::PeekClipboard();
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("files"),
               flutter::EncodableValue(peek.files)},
              {flutter::EncodableValue("image"),
               flutter::EncodableValue(peek.image)},
              {flutter::EncodableValue("text"),
               flutter::EncodableValue(peek.text)},
          }));
          return;
        }
        if (method == "clipboardFiles") {
          int skipped_folders = 0;
          flutter::EncodableList files;
          for (const std::string& path :
               clipboard_bridge::ReadClipboardFiles(skipped_folders)) {
            files.emplace_back(path);
          }
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("files"), flutter::EncodableValue(files)},
              {flutter::EncodableValue("skippedFolders"),
               flutter::EncodableValue(skipped_folders)},
          }));
          return;
        }
        if (method == "clipboardImagePng") {
          std::vector<uint8_t> png = clipboard_bridge::ReadClipboardImagePng();
          if (png.empty()) {
            result->Success();
          } else {
            result->Success(flutter::EncodableValue(std::move(png)));
          }
          return;
        }
        if (method == "copyFilesToClipboard") {
          std::vector<std::string> paths;
          if (const auto* arguments =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            const auto found = arguments->find(flutter::EncodableValue("paths"));
            if (found != arguments->end()) {
              if (const auto* list =
                      std::get_if<flutter::EncodableList>(&found->second)) {
                for (const auto& item : *list) {
                  if (const auto* path = std::get_if<std::string>(&item)) {
                    paths.push_back(*path);
                  }
                }
              }
            }
          }
          result->Success(flutter::EncodableValue(
              clipboard_bridge::CopyFilesToClipboard(GetHandle(), paths)));
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!start_hidden_) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  platform_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Remember the size after the user finishes resizing and when the app
  // quits. Observed before plugins, which may consume these messages.
  if (message == WM_EXITSIZEMOVE || message == WM_DESTROY) {
    if (remember_size_) {
      window_size_store::Save(hwnd);
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
