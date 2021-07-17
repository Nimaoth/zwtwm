#define WIN32_LEAN_AND_MEAN
#include <Windows.h>

struct GUID;

#if defined(__cplusplus)
extern "C" {
#endif

HRESULT GetWindowDesktopId(void* ComObj, HWND hwnd, GUID* result);
HRESULT IsWindowOnCurrentVirtualDesktop(void* ComObj, HWND hwnd, BOOL* result);
//HRESULT CreateVirtualDesktopManagerInstance(void** result);
void* CreateVirtualDesktopManagerInstance();

#if defined(__cplusplus)
}
#endif

