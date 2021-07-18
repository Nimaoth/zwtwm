# zwtwm
ZigWindowsTilingWindowManager: Tiling window manager for windows, inspired by dwm.

## Using the prebuilt binaries
- `zwtwm.exe` is a release build.
- `zwtwm_debug.exe` is a debug build (makes is easier to see log output and more stuff gets logged).

## Building yourself
1. Clone the repository using `git clone --recurse-submodules https://github.com/Nimaoth/zwtwm.git`
2. Install zig.  I developed using zig version `0.8.0-dev.1140+9270aae07`, might not build with other versions.
3. For a release build (logs to file instead of console, ReleaseFast configuration), run `zig build --prefix dist -Drelease`
4. For a debug build (logs to the console, Debug configuration), run `zig build --prefix dist`
5. Use files in `<zwtwm-repository>/dist/bin`

## Configuration
Some settings/keybindings can be changed in config.json, which must be in the same folder as the zwtwm executable.

## Default keybindings
| Key               | Function    |
| -----------       | ----------- |
| Ctrl+Alt+J        | Select previous window on current monitor. |
| Ctrl+Alt+L        | Select next window on current monitor. |
| Ctrl+Alt+Shift+J  | Move current window top previous slot. |
| Ctrl+Alt+Shift+L  | Move current window to next slot. |
| Ctrl+Alt+U        | Go to next monitor. |
| Ctrl+Alt+O        | Go to previous monitor. |
| Ctrl+Alt+Shift+U  | Move current window to next monitor. |
| Ctrl+Alt+Shift+O  | Move current window to previous monitor. |
| Ctrl+Alt+K        | Move current window to top of stack. |
| Ctrl+Alt+I        | Toggle fullscreen (Fullscreen shows the current window maximized). |
| Ctrl+Alt+Z        | Move the window split to the left. |
| Ctrl+Alt+P        | Move the window split to the right. |
| Ctrl+Alt+Shift+Z  | Decrease the gap between windows. |
| Ctrl+Alt+Shift+P  | Increase the gap between windows. |
| Ctrl+Alt+X        | Manage/unmanage the focus window. |
| Ctrl+Alt+M        | The next layer command move the current window to a different layer. Press again to cancel. |
| Ctrl+Alt+N        | The next layer command toggles the current window on a different layer. Press again to cancel. |
| Ctrl+Alt+Shift+G  | Print the executable, window class and title of the focus window to the log. |
| Ctrl+Alt+Win+[n]  | Switch to layer `n` on current monitor. If Ctrl+Alt+M has been pressed before this then move the current window to layer `n`. If Ctrl+Alt+N has been pressed then toggle the current window on layer `n`. |
| Ctrl+Alt+Win+Shift+[n] | Switch to layer `n` on all monitors. |
| Mouse             | You can drag around windows. If you drag a window and stop dragging with your mouse over the task bar then the window will be removed from the window manager. Use `Ctrl+Alt+X` to let **zwtwm** manage the window again. |

### Example
So if you want to move a window to layer 3 then press `Ctrl+Alt+M` `Ctrl+Alt+3`.
If you want to toggle a window on layer 3 then press `Ctrl+Alt+N` `Ctrl+Alt+3`.
Just pressing `Ctrl+Alt+3` activates layer 3, meaning that all windows on layer 3 will be made visible and all windows on the previous layer will be hidden (unless they're also on layer 3).

