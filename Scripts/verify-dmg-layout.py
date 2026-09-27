"""Check the actual packaged Finder layout, not just the source settings."""
from pathlib import Path
import sys

from ds_store import DSStore
from mac_alias import Alias

mount = Path(sys.argv[1])
assert (mount / "Media Converter.app/Contents/Resources/AppIcon.icns").is_file()
assert (mount / "Applications").is_symlink()
assert (mount / "Applications").readlink() == Path("/Applications")
assert (mount / ".background.tiff").is_file()
with DSStore.open(str(mount / ".DS_Store"), "r") as store:
    assert store["Media Converter.app"]["Iloc"] == (140, 120)
    assert store["Applications"]["Iloc"] == (500, 120)
    assert store["."]["icvl"] == (b"type", b"icnv")
    view = store["."]["icvp"]
    assert view["iconSize"] == 128
    assert view["backgroundType"] == 2
    assert Alias.from_bytes(view["backgroundImageAlias"]).target.filename == ".background.tiff"
    window = store["."]["bwsp"]
    assert window["ShowToolbar"] is False
    assert window["ShowSidebar"] is False
print("DMG layout verified: app (left), arrow background (center), Applications (right).")
