class_name TilingWM
extends RefCounted

## A tiling window manager on the player's Mac (AeroSpace) sizes a tiled window itself: the
## reserve stood upright 9:16 was stretched straight back over the whole screen. Upright the
## game's window is taken out of the tiling - floated, its AeroSpace full screen off - so it keeps
## the shape it asks for; lying down again it goes back as it was. Without AeroSpace (another
## system, another Mac, a headless run) both do nothing. Nothing here reaches the simulation.
##
## The game never waits for AeroSpace, which when busy takes seconds to answer: every command
## runs in a shell of its own. That shell notes how AeroSpace held the window (the focused one -
## the game's, as F10 or the stream's start was just pressed in it) in a file of its own the first
## time, and the way back reads it.

const CLI_PATHS := ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]

const _RELEASE := """
AS="$1"; HELD="$2"; LOG="$2.log"
if [ ! -s "$HELD" ]; then
  "$AS" list-windows --focused --format '%{window-id}|%{window-layout}|%{window-is-fullscreen}' > "$HELD.new" \
    && mv -f "$HELD.new" "$HELD"
  echo "$(date '+%F %T') held $(cat "$HELD" 2>/dev/null)" >> "$LOG"
fi
IFS='|' read -r ID LAYOUT FULL < "$HELD" || exit 0
[ -n "$ID" ] || exit 0
"$AS" fullscreen off --window-id "$ID"
"$AS" layout floating --window-id "$ID"
"""

const _RESTORE := """
AS="$1"; HELD="$2"; LOG="$2.log"; shift 2
# The floats still under way finish first, or one would float the window again after this.
# (a finished one may linger unreaped as a zombie, "Z"; ten seconds at most in all)
N=0
for PID in "$@"; do
  while ST=$(ps -o stat= -p "$PID" 2>/dev/null) && [ -n "$ST" ] && [ "${ST#Z}" = "$ST" ] && [ $N -lt 100 ]; do
    sleep 0.1; N=$((N + 1))
  done
done
[ -s "$HELD" ] || exit 0
IFS='|' read -r ID LAYOUT FULL < "$HELD"
rm -f "$HELD"
[ -n "$ID" ] || exit 0
# Out of macOS full screen it goes back to AeroSpace's own, as game.sh keeps the game.
case "$LAYOUT" in macos_native_fullscreen) FULL=true ;; esac
[ "$LAYOUT" = "floating" ] || "$AS" layout tiling --window-id "$ID"
[ "$FULL" = "true" ] && "$AS" fullscreen on --window-id "$ID" --no-outer-gaps
echo "$(date '+%F %T') restored $ID: $LAYOUT, fullscreen $FULL -> $("$AS" list-windows --focused --format '%{window-layout}|%{window-is-fullscreen}')" >> "$LOG"
exit 0
"""

static var _released := false
## The shells floating the window that may still be running.
static var _release_pids: Array[int] = []


## Floats the game's window so it may size itself; again if AeroSpace has tiled it back since.
static func release() -> void:
	var cli := _cli()
	if cli == "":
		return
	if not _released:
		_released = true
		DirAccess.remove_absolute(_held_path())  # a note left by an earlier run is not this window's
		print("TilingWM: floating the game's window in AeroSpace")
	_release_pids.append(OS.create_process("/bin/sh", ["-c", _RELEASE, "tiling_wm", cli, _held_path()]))


## Takes the focused window out of macOS full screen when Godot has lost track that it is in.
static func leave_native_fullscreen() -> void:
	var cli := _cli()
	if cli == "":
		return
	print("TilingWM: taking the game's window out of macOS full screen")
	OS.create_process(cli, ["macos-native-fullscreen", "off"])


## Puts the window back the way `release` found it.
static func restore() -> void:
	if not _released:
		return
	_released = false
	var cli := _cli()
	if cli == "":
		return
	print("TilingWM: giving the game's window back to AeroSpace")
	var args := ["-c", _RESTORE, "tiling_wm", cli, _held_path()]
	for pid in _release_pids:
		if pid > 0:
			args.append(str(pid))
	_release_pids.clear()
	OS.create_process("/bin/sh", args)


static func _cli() -> String:
	if OS.get_name() != "macOS":
		return ""
	for path in CLI_PATHS:
		if FileAccess.file_exists(path):
			return path
	return ""


static func _held_path() -> String:
	return OS.get_user_data_dir().path_join("tiling_wm_held.txt")
