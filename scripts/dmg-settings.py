# dmgbuild settings for the Collie DMG (design "Tinta": docs/pages/dmg-opcoes). Driven by scripts/make-dmg.sh, which
# passes -D app=<Collie.app> -D background=<Resources/dmg-background.tiff>. dmgbuild writes the .DS_Store itself:
# no Finder, no AppleScript.
import os.path

app = defines["app"]  # noqa: F821 (injected by dmgbuild)
name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
background = defines["background"]  # noqa: F821

show_sidebar = False
show_toolbar = False
show_status_bar = False
show_pathbar = False
icon_size = 112
text_size = 13

# ---- Window layout: the ONLY place to tune it (scripts/make-dmg.sh checks these same values in the built .DS_Store).
# Content area 660x420 (the background is 660x420 pt).
WINDOW_ORIGIN = (200, 120)
WINDOW_SIZE = (660, 420)
# Icon positions are icon centres, in content coordinates. History: with the Finder/AppleScript layout the centres
# landed 36 pt below the y asked (so y=154 put them on the arrow at y=190). Whether dmgbuild's .DS_Store has the same
# offset is NOT measured yet: if the icons look too high/low in a screenshot, change ICON_Y only (target: centres on
# the background's arrow, y=190).
ICON_Y = 154
APP_X = 180
APPLICATIONS_X = 480
# The background file (.background.tiff) is a hidden dotfile; far below the window in case hidden files are shown.
BACKGROUND_POS = (330, 900)

window_rect = (WINDOW_ORIGIN, WINDOW_SIZE)
icon_locations = {
    name: (APP_X, ICON_Y),
    "Applications": (APPLICATIONS_X, ICON_Y),
    ".background.tiff": BACKGROUND_POS,
}
