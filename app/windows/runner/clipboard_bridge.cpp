#include "clipboard_bridge.h"

#include <objidl.h>
#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <cstring>
#include <cwctype>

// GDI+ headers use min/max, which NOMINMAX (set for the runner) removes.
namespace Gdiplus {
using std::max;
using std::min;
}  // namespace Gdiplus
#include <gdiplus.h>

#include "utils.h"

namespace clipboard_bridge {
namespace {

// {557CF406-1A04-11D3-9A73-0000F81EF32E}: the built-in GDI+ PNG encoder.
const CLSID kPngEncoder = {0x557cf406,
                           0x1a04,
                           0x11d3,
                           {0x9a, 0x73, 0x00, 0x00, 0xf8, 0x1e, 0xf3, 0x2e}};
constexpr DWORD kDropEffectCopy = 1;
// Larger pictures are still copied as a file, just not as a bitmap.
constexpr unsigned long long kMaximumDibPixels = 50ULL * 1000 * 1000;

// Another program may hold the clipboard for a moment; retry briefly.
class ClipboardLock {
 public:
  explicit ClipboardLock(HWND owner) {
    for (int attempt = 0; attempt < 10 && !open_; ++attempt) {
      open_ = ::OpenClipboard(owner) != FALSE;
      if (!open_) {
        ::Sleep(20);
      }
    }
  }
  ~ClipboardLock() {
    if (open_) {
      ::CloseClipboard();
    }
  }
  ClipboardLock(const ClipboardLock&) = delete;
  ClipboardLock& operator=(const ClipboardLock&) = delete;
  bool is_open() const { return open_; }

 private:
  bool open_ = false;
};

class GdiplusSession {
 public:
  GdiplusSession() {
    Gdiplus::GdiplusStartupInput input;
    ok_ = Gdiplus::GdiplusStartup(&token_, &input, nullptr) == Gdiplus::Ok;
  }
  ~GdiplusSession() {
    if (ok_) {
      Gdiplus::GdiplusShutdown(token_);
    }
  }
  GdiplusSession(const GdiplusSession&) = delete;
  GdiplusSession& operator=(const GdiplusSession&) = delete;
  bool ok() const { return ok_; }

 private:
  ULONG_PTR token_ = 0;
  bool ok_ = false;
};

UINT PngFormat() {
  static const UINT format = ::RegisterClipboardFormatW(L"PNG");
  return format;
}

std::wstring Utf16FromUtf8(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int length =
      ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) {
    return {};
  }
  std::wstring result(static_cast<size_t>(length), L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                        static_cast<int>(value.size()), result.data(), length);
  return result;
}

std::vector<uint8_t> GlobalBytes(HANDLE handle) {
  std::vector<uint8_t> bytes;
  if (handle == nullptr) {
    return bytes;
  }
  const SIZE_T size = ::GlobalSize(handle);
  const void* data = ::GlobalLock(handle);
  if (data != nullptr && size > 0) {
    const auto* begin = static_cast<const uint8_t*>(data);
    bytes.assign(begin, begin + size);
  }
  if (data != nullptr) {
    ::GlobalUnlock(handle);
  }
  return bytes;
}

std::vector<uint8_t> SaveAsPng(Gdiplus::Bitmap& bitmap) {
  std::vector<uint8_t> result;
  IStream* stream = nullptr;
  if (FAILED(::CreateStreamOnHGlobal(nullptr, TRUE, &stream))) {
    return result;
  }
  if (bitmap.Save(stream, &kPngEncoder, nullptr) == Gdiplus::Ok) {
    STATSTG stat{};
    if (SUCCEEDED(stream->Stat(&stat, STATFLAG_NONAME))) {
      result.resize(static_cast<size_t>(stat.cbSize.QuadPart));
      LARGE_INTEGER start{};
      stream->Seek(start, STREAM_SEEK_SET, nullptr);
      ULONG read = 0;
      stream->Read(result.data(), static_cast<ULONG>(result.size()), &read);
      result.resize(read);
    }
  }
  stream->Release();
  return result;
}

// CF_DIB to PNG. Going through a GDI bitmap handles every DIB layout
// (bottom-up/top-down, BI_BITFIELDS, palettes); alpha is ignored, which is
// what screenshots need.
std::vector<uint8_t> DibToPng(const std::vector<uint8_t>& dib) {
  if (dib.size() < sizeof(BITMAPINFOHEADER)) {
    return {};
  }
  const auto* info = reinterpret_cast<const BITMAPINFO*>(dib.data());
  const BITMAPINFOHEADER& header = info->bmiHeader;
  size_t offset = header.biSize;
  if (header.biCompression == BI_BITFIELDS &&
      header.biSize == sizeof(BITMAPINFOHEADER)) {
    offset += 3 * sizeof(DWORD);
  }
  size_t colors = header.biClrUsed;
  if (colors == 0 && header.biBitCount <= 8) {
    colors = size_t{1} << header.biBitCount;
  }
  offset += colors * sizeof(RGBQUAD);
  if (offset >= dib.size()) {
    return {};
  }
  HDC screen = ::GetDC(nullptr);
  HBITMAP bitmap_handle =
      ::CreateDIBitmap(screen, &header, CBM_INIT, dib.data() + offset, info,
                       DIB_RGB_COLORS);
  ::ReleaseDC(nullptr, screen);
  if (bitmap_handle == nullptr) {
    return {};
  }
  std::vector<uint8_t> png;
  {
    GdiplusSession session;
    if (session.ok()) {
      Gdiplus::Bitmap bitmap(bitmap_handle, nullptr);
      if (bitmap.GetLastStatus() == Gdiplus::Ok) {
        png = SaveAsPng(bitmap);
      }
    }
  }
  ::DeleteObject(bitmap_handle);
  return png;
}

bool IsPictureFile(const std::wstring& path) {
  const size_t dot = path.find_last_of(L'.');
  if (dot == std::wstring::npos) {
    return false;
  }
  std::wstring extension = path.substr(dot);
  std::transform(extension.begin(), extension.end(), extension.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  return extension == L".jpg" || extension == L".jpeg" ||
         extension == L".png" || extension == L".gif" || extension == L".bmp";
}

void ApplyExifOrientation(Gdiplus::Bitmap& bitmap) {
  constexpr PROPID kOrientation = 0x0112;
  const UINT size = bitmap.GetPropertyItemSize(kOrientation);
  if (size == 0) {
    return;
  }
  std::vector<uint8_t> buffer(size);
  auto* item = reinterpret_cast<Gdiplus::PropertyItem*>(buffer.data());
  if (bitmap.GetPropertyItem(kOrientation, size, item) != Gdiplus::Ok ||
      item->value == nullptr) {
    return;
  }
  switch (*static_cast<unsigned short*>(item->value)) {
    case 2:
      bitmap.RotateFlip(Gdiplus::RotateNoneFlipX);
      break;
    case 3:
      bitmap.RotateFlip(Gdiplus::Rotate180FlipNone);
      break;
    case 4:
      bitmap.RotateFlip(Gdiplus::Rotate180FlipX);
      break;
    case 5:
      bitmap.RotateFlip(Gdiplus::Rotate90FlipX);
      break;
    case 6:
      bitmap.RotateFlip(Gdiplus::Rotate90FlipNone);
      break;
    case 7:
      bitmap.RotateFlip(Gdiplus::Rotate270FlipX);
      break;
    case 8:
      bitmap.RotateFlip(Gdiplus::Rotate270FlipNone);
      break;
    default:
      break;
  }
}

// A picture file as a 24-bit bottom-up CF_DIB (transparent areas on white).
HGLOBAL PictureFileToDib(const std::wstring& path) {
  GdiplusSession session;
  if (!session.ok()) {
    return nullptr;
  }
  HGLOBAL result = nullptr;
  {
    Gdiplus::Bitmap source(path.c_str());
    if (source.GetLastStatus() != Gdiplus::Ok) {
      return nullptr;
    }
    ApplyExifOrientation(source);
    const UINT width = source.GetWidth();
    const UINT height = source.GetHeight();
    if (width == 0 || height == 0 ||
        static_cast<unsigned long long>(width) * height > kMaximumDibPixels) {
      return nullptr;
    }
    Gdiplus::Bitmap canvas(static_cast<INT>(width), static_cast<INT>(height),
                           PixelFormat24bppRGB);
    {
      Gdiplus::Graphics graphics(&canvas);
      graphics.Clear(Gdiplus::Color(255, 255, 255, 255));
      graphics.DrawImage(&source, 0, 0, static_cast<INT>(width),
                         static_cast<INT>(height));
    }
    Gdiplus::Rect rect(0, 0, static_cast<INT>(width), static_cast<INT>(height));
    Gdiplus::BitmapData data{};
    if (canvas.LockBits(&rect, Gdiplus::ImageLockModeRead, PixelFormat24bppRGB,
                        &data) != Gdiplus::Ok) {
      return nullptr;
    }
    const SIZE_T stride = (static_cast<SIZE_T>(width) * 3 + 3) & ~SIZE_T{3};
    result = ::GlobalAlloc(GMEM_MOVEABLE,
                           sizeof(BITMAPINFOHEADER) + stride * height);
    if (result != nullptr) {
      auto* header = static_cast<BITMAPINFOHEADER*>(::GlobalLock(result));
      *header = {};
      header->biSize = sizeof(BITMAPINFOHEADER);
      header->biWidth = static_cast<LONG>(width);
      header->biHeight = static_cast<LONG>(height);  // bottom-up
      header->biPlanes = 1;
      header->biBitCount = 24;
      header->biCompression = BI_RGB;
      header->biSizeImage = static_cast<DWORD>(stride * height);
      auto* pixels = reinterpret_cast<uint8_t*>(header + 1);
      for (UINT row = 0; row < height; ++row) {
        const auto* source_row = static_cast<const uint8_t*>(data.Scan0) +
                                 static_cast<ptrdiff_t>(data.Stride) * row;
        std::memcpy(pixels + stride * (height - 1 - row), source_row,
                    static_cast<size_t>(width) * 3);
      }
      ::GlobalUnlock(result);
    }
    canvas.UnlockBits(&data);
  }
  return result;
}

}  // namespace

Peek PeekClipboard() {
  Peek peek;
  peek.files = ::IsClipboardFormatAvailable(CF_HDROP) != FALSE;
  peek.text = ::IsClipboardFormatAvailable(CF_UNICODETEXT) != FALSE;
  const UINT png = PngFormat();
  peek.image = (png != 0 && ::IsClipboardFormatAvailable(png) != FALSE) ||
               ::IsClipboardFormatAvailable(CF_DIB) != FALSE ||
               ::IsClipboardFormatAvailable(CF_BITMAP) != FALSE;
  return peek;
}

std::vector<std::string> ReadClipboardFiles(int& skipped_folders) {
  skipped_folders = 0;
  std::vector<std::string> files;
  if (!::IsClipboardFormatAvailable(CF_HDROP)) {
    return files;
  }
  ClipboardLock lock(nullptr);
  if (!lock.is_open()) {
    return files;
  }
  auto drop = static_cast<HDROP>(::GetClipboardData(CF_HDROP));
  if (drop == nullptr) {
    return files;
  }
  const UINT count = ::DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT index = 0; index < count; ++index) {
    const UINT length = ::DragQueryFileW(drop, index, nullptr, 0);
    if (length == 0) {
      continue;
    }
    std::wstring path(static_cast<size_t>(length) + 1, L'\0');
    ::DragQueryFileW(drop, index, path.data(), length + 1);
    path.resize(length);
    const DWORD attributes = ::GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) {
      continue;
    }
    if (attributes & FILE_ATTRIBUTE_DIRECTORY) {
      ++skipped_folders;
      continue;
    }
    files.push_back(Utf8FromUtf16(path.c_str()));
  }
  return files;
}

std::vector<uint8_t> ReadClipboardImagePng() {
  ClipboardLock lock(nullptr);
  if (!lock.is_open()) {
    return {};
  }
  const UINT png = PngFormat();
  if (png != 0 && ::IsClipboardFormatAvailable(png)) {
    std::vector<uint8_t> bytes = GlobalBytes(::GetClipboardData(png));
    static const uint8_t kSignature[8] = {0x89, 'P',  'N',  'G',
                                          0x0D, 0x0A, 0x1A, 0x0A};
    if (bytes.size() > sizeof(kSignature) &&
        std::equal(std::begin(kSignature), std::end(kSignature),
                   bytes.begin())) {
      return bytes;
    }
  }
  if (::IsClipboardFormatAvailable(CF_DIB)) {
    return DibToPng(GlobalBytes(::GetClipboardData(CF_DIB)));
  }
  return {};
}

bool CopyFilesToClipboard(HWND owner, const std::vector<std::string>& paths) {
  std::wstring list;
  std::wstring single_path;
  for (const std::string& path : paths) {
    const std::wstring wide = Utf16FromUtf8(path);
    if (wide.empty()) {
      continue;
    }
    single_path = wide;
    list += wide;
    list.push_back(L'\0');
  }
  if (list.empty()) {
    return false;
  }
  list.push_back(L'\0');

  const SIZE_T drop_size = sizeof(DROPFILES) + list.size() * sizeof(wchar_t);
  HGLOBAL drop = ::GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, drop_size);
  if (drop == nullptr) {
    return false;
  }
  auto* drop_files = static_cast<DROPFILES*>(::GlobalLock(drop));
  drop_files->pFiles = sizeof(DROPFILES);
  drop_files->fWide = TRUE;
  std::memcpy(reinterpret_cast<uint8_t*>(drop_files) + sizeof(DROPFILES),
              list.data(), list.size() * sizeof(wchar_t));
  ::GlobalUnlock(drop);

  HGLOBAL effect = ::GlobalAlloc(GMEM_MOVEABLE, sizeof(DWORD));
  if (effect != nullptr) {
    *static_cast<DWORD*>(::GlobalLock(effect)) = kDropEffectCopy;
    ::GlobalUnlock(effect);
  }
  HGLOBAL dib = paths.size() == 1 && IsPictureFile(single_path)
                    ? PictureFileToDib(single_path)
                    : nullptr;

  ClipboardLock lock(owner);
  if (!lock.is_open()) {
    ::GlobalFree(drop);
    if (effect != nullptr) {
      ::GlobalFree(effect);
    }
    if (dib != nullptr) {
      ::GlobalFree(dib);
    }
    return false;
  }
  ::EmptyClipboard();
  // After a successful SetClipboardData the system owns the memory.
  const bool ok = ::SetClipboardData(CF_HDROP, drop) != nullptr;
  if (!ok) {
    ::GlobalFree(drop);
  }
  if (effect != nullptr &&
      ::SetClipboardData(::RegisterClipboardFormatW(L"Preferred DropEffect"),
                         effect) == nullptr) {
    ::GlobalFree(effect);
  }
  if (dib != nullptr && ::SetClipboardData(CF_DIB, dib) == nullptr) {
    ::GlobalFree(dib);
  }
  return ok;
}

}  // namespace clipboard_bridge
