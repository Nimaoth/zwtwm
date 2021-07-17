#define WIN32_LEAN_AND_MEAN
#include <Windows.h>
#include <shobjidl_core.h>
#include <guiddef.h>

EXTERN_C const CLSID CLSID_VirtualDesktopManager;
class DECLSPEC_UUID("aa509086-5ca9-4c25-8f95-589d3c07b48a") VirtualDesktopManager;

#if defined(__cplusplus)
extern "C" {
#endif

HRESULT GetWindowDesktopId(void* ComObj, HWND hwnd, GUID* result) {
    IVirtualDesktopManager* vdm = (IVirtualDesktopManager*) ComObj;
    return vdm->GetWindowDesktopId(hwnd, result);
}

HRESULT IsWindowOnCurrentVirtualDesktop(void* ComObj, HWND hwnd, BOOL* result) {
    IVirtualDesktopManager* vdm = (IVirtualDesktopManager*) ComObj;
    return vdm->IsWindowOnCurrentVirtualDesktop(hwnd, result);
}

IVirtualDesktopManager* CreateVirtualDesktopManagerInstance() {
    IVirtualDesktopManager* result;
    unsigned char guidBytes[] = {0x86, 0x90, 0x50, 0xaa, 0xa9, 0x5c, 0x25, 0x4c, 0x8f, 0x95, 0x58, 0x9d, 0x3c, 0x07, 0xb4, 0x8a };
    GUID guid;
    memcpy(&guid, guidBytes, sizeof(GUID));
    if (CoCreateInstance(guid, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&result)) != 0) {
    //if (CoCreateInstance(CLSID_VirtualDesktopManager, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&result)) != 0) {
        return nullptr;
    }
    return result;
}

#if defined(__cplusplus)
}
#endif
