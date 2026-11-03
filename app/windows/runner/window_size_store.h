#ifndef RUNNER_WINDOW_SIZE_STORE_H_
#define RUNNER_WINDOW_SIZE_STORE_H_

#include <windows.h>

// Remembers the window's normal (not maximised) size between launches in
// HKEY_CURRENT_USER\Software\MengrenKuaichuan, in logical (96 DPI) pixels.
namespace window_size_store {

// Returns false when nothing usable has been saved yet.
bool Load(unsigned int& width, unsigned int& height);

// Saves the current normal size of |window|; ignores implausible sizes.
void Save(HWND window);

}  // namespace window_size_store

#endif  // RUNNER_WINDOW_SIZE_STORE_H_
