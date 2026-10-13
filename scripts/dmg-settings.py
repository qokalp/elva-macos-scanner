# dmgbuild settings for Elva-Scanner.dmg (used by scripts/make-dmg.sh).
# Paths are passed with -D: app=…, background=…, icon=…
# Icon positions must match scripts/make-dmg-background.swift.

app = defines['app']                       # noqa: F821 (provided by dmgbuild)
appname = 'Elva Scanner.app'

format = 'UDZO'
compression_level = 9
filesystem = 'HFS+'

files = [app]
symlinks = {'Applications': '/Applications'}
icon = defines['icon']                     # noqa: F821  volume icon
background = defines['background']         # noqa: F821  HiDPI TIFF

# Window: 660×480. Finder on macOS 26 may still show its toolbar/path/status bars; the layout in the
# background fits the remaining space.
window_rect = ((200, 140), (660, 480))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
label_pos = 'bottom'
text_size = 13
icon_size = 128

icon_locations = {
    appname: (165, 170),
    'Applications': (495, 170),
}
