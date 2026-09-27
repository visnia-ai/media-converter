"""Finder layout for the drag-to-install disk image; also used by headless CI."""

application = defines["app"]
format = "UDZO"
filesystem = "HFS+"
files = [application, defines["license"]]
symlinks = {"Applications": "/Applications"}
hide = ["LICENSE.txt"]
# Finder metadata on the signed app bundle would invalidate its strict signature.
hide_extensions = []
icon = defines["icon"]
background = "builtin-arrow"
window_rect = ((200, 200), (640, 280))
default_view = "icon-view"
include_icon_view_settings = True
include_list_view_settings = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
icon_size = 128
text_size = 14
icon_locations = {"Media Converter.app": (140, 120), "Applications": (500, 120)}
