# X-Plane plugin "SlewMode"

## What it does

It allows to use your joystick to move and rotate your aircraft. It follows the terrain (when on the ground).

## Requirements

* [FlyWithLua](https://forums.x-plane.org/index.php?/files/file/82888-flywithlua-ng-next-generation-plus-edition-for-x-plane-12-win-lin-mac/)
* Tested with X-Plane 12 (maybe it works with 11)

## Installation

Put the .lua file into `./Resources/plugins/FlyWithLua/Scripts/`

## Usage

### Quickstart

* Bind the command `flightwusel/SlewMode/Toggle` to a key or joystick button.
* Press the key/button to enable Slew Mode. While active, it will announce the current mode on-screen ("free" or "following terrain").
  In terrain-following mode it will keep the plane sticked to the ground. You change the mode to "free" by increasing altitude. When you "hit" the ground again, terrain following mode is engaged.
* Use your joystick to move the aircraft:
  - Pitch axis -> move forward/backward
  - Roll axis -> move sideways
  - Yaw axis -> heading
  - While pressing <kbd>SPACE</kbd> (the "modifier key") you can roll the aircraft:
    - Pitch axis -> pitch
    - Roll axis -> roll
  - You can bind keys for increasing/decreasing altitude.
* Stop Slew Mode by pressing the key again.

### More commands

There are further commands available:
* for controlling altitude
* for setting roll and pitch to 0°

## Help

If you have problems, feedback or just want to talk you can open an issue here or use the
[thread on the x-plane.org forum](https://forums.x-plane.org/index.php?/forums/topic/283229-slew-reposition-mode/)
