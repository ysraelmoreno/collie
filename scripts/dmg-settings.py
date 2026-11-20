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
# Content area 660x420 (the background is 660x420 pt). The height dmgbuild takes includes the 28 pt title bar: measured
# on a real window, 420 gave ~390 pt of content and cut the caption.
WINDOW_ORIGIN = (200, 120)
WINDOW_SIZE = (660, 448)
# Icon positions are icon centres, in content coordinates. Measured on a real window built by dmgbuild: the centre
# lands exactly on the y given (the 36 pt offset of the old Finder/AppleScript layout does not exist here), so
# y=190 puts the icons on the background's arrow and their names on its tags.
ICON_Y = 190
APP_X = 180
APPLICATIONS_X = 480
# The background file (.background.tiff) is a hidden dotfile; far below the window in case hidden files are shown.
# For someone who shows hidden files this makes the window scrollable (a scrollbar may show); an icon in the middle of
# the picture would be worse.
BACKGROUND_POS = (330, 900)

window_rect = (WINDOW_ORIGIN, WINDOW_SIZE)
icon_locations = {
    name: (APP_X, ICON_Y),
    "Applications": (APPLICATIONS_X, ICON_Y),
    ".background.tiff": BACKGROUND_POS,
}
