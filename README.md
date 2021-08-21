# zwtwm
ZigWindowsTilingWindowManager: Tiling window manager for windows, inspired by dwm.

## Using the prebuilt binaries
- `zwtwm.exe` is a release build.
- `zwtwm_debug.exe` is a debug build (makes is easier to see log output and more stuff gets logged).

## Building yourself
1. Clone the repository using `git clone --recurse-submodules https://github.com/Nimaoth/zwtwm.git`
2. Install zig.  I developed using zig version `0.8.0-dev.1140+9270aae07`, might not build with other versions.
3. For a release build (logs to file instead of console, ReleaseFast configuration), run `zig build --prefix dist -Drelease`
4. For a debug build (logs to the console, Debug configuration), run `zig build --prefix dist -Dconsole`
5. Use files in `<zwtwm-repository>/dist/bin`

## Configuration
Some settings/keybindings can be changed in config.json, which must be in the same folder as the zwtwm executable.

## Default keybindings
| Key               | Function    |
| -----------       | ----------- |
| Win+Escape        | Terminate zwtwm (Can't be changed at the moment). |
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

## Config

Any changes to the config file required a restart of `zwtwm`.

| Key               | Type          | Default value | Description   |
| ----------------- | ------------- | ------------- | ------------- |
| `gap`             | integer       | 5             | The initial gap between windows. |
| `splitRatio`      | float         | 0.6           | The initial position of the horizontal split (0.5 would be a split in the middle, 0.75 would be on the right side). |
| `wrapMonitors`    | bool          | true          | When you are on the last monitor and you go to the next monitor wrap around to the first, and the other way around. |
| `wrapWindows`     | bool          | true          | When you are on the last window and you go to the next window wrap around to the first, and the other way around. |
| `disableOutlineForFullscreen`     | bool          | true          | Don't draw the outline for fullscreen windows. |
| `disableOutlineForSingleWindow`   | bool          | false         | Don't draw the outline for a window if it's the only window on the monitor or the layer is in full screen mode. |
| `noGapForSingleWindow`            | bool          | false         | Remove the gap for a window if it's the only window on the monitor or the layer is in full screen mode. Has no effect if `maximizeFullSizeWindows` is `true`. |
| `maximizeFullSizeWindows`         | bool          | false         | Maximize a window if it's the only window on the monitor or the layer is in full screen mode. |
| `monitorBorder`<br>`.thickness`<br>`.color`    | object<br>integer<br>string   | <br>2<br>'0xFF00FF' | Configure the outline for the monitor.<br>Thickness of the outline in pixels.<br>Color of the outline as a hex string. |
| `windowFocusedBorder`     | object    |               | Same as `monitorBorder` but for the current window. |
| `windowUnfocusedBorder`   | object    |               | Same as `monitorBorder` but for the current window if it doesn't have focus (because an unmanaged window has focus). |
| `ignoredPrograms`         | array of strings  | []    | List of executables that should not be managed by `zwtwm` (No window created by any of these programs will be managed). |
| `ignoredClasses`          | array of strings  | []    | List of window classes that should not be managed by `zwtwm` (No window which has any of these classes will be managed). |
| `ignoredTitles`           | array of strings  | []    | List of window titles that should not be managed by `zwtwm` (No window with any of these titles will be managed). |
| `hotkeys` | array of objects  | []    | List of hotkeys. If you change a hotkey you can look at the log file to see if that hotkey was successfully registered. |

Each hotkey has the following structure:
| Key               | Type          | Description   |
| ----------------- | ------------- | ------------- |
| `key`             | string        | Defines the key combination for that hotkey. |
| `command`         | string        | Which command to execute. |
| `args`            | string        | Optional arguments for that hotkey. |

Some commands take arguments which have the following structure:
| Key               | Type          | Default value |
| ----------------- | ------------- | ------------- |
| `intParam`        | integer       | 0             |
| `usizeParam`      | unsigned int  | 0             |
| `floatParam`      | float         | 0.0           |
| `boolParam`       | bool          | false         |
| `charParam`       | string        | "\0"          |

## Commands

| Command                           | Description |
| --------------------------------- | ------------- |
| `decreaseGap`                     | Decrease the gap between windows. Amount can be specified in `intParam`. |
| `increaseGap`                     | Increase the gap between windows. Amount can be specified in `intParam`. |
| `decreaseSplit`                   | Move the split to the left. Amount can be specified in `floatParam`. |
| `increaseSplit`                   | Move the split to the right. Amount can be specified in `floatParam`. |
| `selectPrevWindow`                | Select the previous windows. Wraps around if `wrapWindows` is `true`. |
| `selectNextWindow`                | Select the next windows. Wraps around if `wrapWindows` is `true`. |
| `moveWindowUp`                    | Move the current window up in the stack. Wraps around if `wrapWindows` is `true`. |
| `moveWindowDown`                  | Move the current window down in the stack. Wraps around if `wrapWindows` is `true`. |
| `toggleForegroundWindowManaged`   | Manage/Unmanage the focused window. |
| `moveCurrentWindowToTop`          | Move the current window to the top in the stack. |
| `moveNextWindowToLayer`           | The next `layerCommand` will move the current window to a layer. |
| `toggleNextWindowOnLayer`         | The next `layerCommand` will add/remove the current window an a layer. |
| `toggleWindowFullscreen`          | Toggle fullscreen mode for the current layer. In fullscreen mode the current window will cover the entire screen (except the taskbar). Behaviour can be configured using some settings. |
| `moveWindowToPrevMonitor`         | Move the current window to the previous monitor. Wraps around if `wrapMonitors` is `true`. |
| `moveWindowToNextMonitor`         | Move the current window to the next monitor. Wraps around if `wrapMonitors` is `true`. |
| `goToPrevMonitor`                 | Go to the previos monitor. Wraps around if `wrapMonitors` is `true`.  |
| `goToNextMonitor`                 | Go to the next monitor. Wraps around if `wrapMonitors` is `true`.  |
| `printForegroundWindowInfo`       | Write some information about the focused window to the log file. |
| `layerCommand`                    | If `moveNextWindowToLayer` was executed before this then move the current window to the layer specified by `args.usizeParam`.<br>If `toggleNextWindowOnLayer` was executed before this then toggle the current window on the layer specified by `args.usizeParam`.<br>Otherwise switch to the layer specified by `args.usizeParam`. If `args.boolParam` is `true` then switch layers on all monitors, otherwise only on the current monitor. |

