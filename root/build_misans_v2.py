import os, shutil, zipfile, io

B = os.path.dirname(os.path.abspath(__file__))   # this script lives in <repo>/root/
STAGE = os.path.join(B, "work", "module_misans_v2")
# Where the MiSans .ttf files live. Default: root/fonts/ next to this script.
# Override with SRC_TTF=/path/to/MiSans/ttf when they live elsewhere.
SRC_TTF = os.environ.get("SRC_TTF") or os.path.join(B, "fonts")
if not os.path.isdir(SRC_TTF):
    raise SystemExit(
        "MiSans TTFs not found in %s\n"
        "Put the .ttf files there, or point SRC_TTF at the directory holding them."
        % SRC_TTF)

# v2: shift the WHOLE ladder one step heavier.
# 400 (Android's default text weight) moves Regular -> Medium.
MAP = [
    (100, "MiSans-Light.ttf"),      # was Thin
    (300, "MiSans-Regular.ttf"),    # was Light
    (400, "MiSans-Medium.ttf"),     # was Regular  <-- the requested bump
    (500, "MiSans-Semibold.ttf"),   # was Medium
    (600, "MiSans-Bold.ttf"),       # was Semibold
    (700, "MiSans-Heavy.ttf"),      # was Bold
    (900, "MiSans-Heavy.ttf"),      # was Heavy
]

shutil.rmtree(STAGE, ignore_errors=True)
os.makedirs(os.path.join(STAGE, "system", "fonts"))
os.makedirs(os.path.join(STAGE, "system", "etc"))

src = io.open(os.path.join(B, "backup", "fonts_orig.xml"), encoding="utf-8").read()
anchor = '    <family name="sans-serif">\n'
assert src.count(anchor) == 1

block = [anchor]
block.append('        <!-- MiSans (Xiaomi), ladder shifted one step heavier so the default\n')
block.append('             400 weight renders as Medium instead of Regular. -->\n')
for w, fn in MAP:
    block.append('        <font weight="%d" style="normal">%s</font>\n' % (w, fn))
out = src.replace(anchor, "".join(block), 1)
io.open(os.path.join(STAGE, "system", "etc", "fonts.xml"), "w",
        encoding="utf-8", newline="\n").write(out)
print("fonts.xml written (%d entries)" % len(MAP))
for w, fn in MAP:
    print("   weight %-4d -> %s" % (w, fn))

used = sorted({fn for _, fn in MAP})
total = 0
for fn in used:
    shutil.copyfile(os.path.join(SRC_TTF, fn), os.path.join(STAGE, "system", "fonts", fn))
    total += os.path.getsize(os.path.join(STAGE, "system", "fonts", fn))
print("fonts copied: %d files, %.1f MB" % (len(used), total / 1048576))
print("MiSans-Thin dropped (unused):", "MiSans-Thin.ttf" not in used)

io.open(os.path.join(STAGE, "module.prop"), "w", encoding="utf-8", newline="\n").write(
    "id=misans\n"
    "name=MiSans (weight +1)\n"
    "version=2.0\n"
    "versionCode=2\n"
    "author=delbert\n"
    "description=MiSans as system sans-serif, whole weight ladder shifted one step heavier "
    "(default 400 -> Medium). Missing glyphs fall back to Roboto/Noto.\n")

io.open(os.path.join(STAGE, "customize.sh"), "w", encoding="utf-8", newline="\n").write(
    "#!/system/bin/sh\n"
    "set_perm_recursive $MODPATH/system/fonts 0 0 0755 0644\n"
    "set_perm_recursive $MODPATH/system/etc   0 0 0755 0644\n")

io.open(os.path.join(STAGE, "post-fs-data.sh"), "w", encoding="utf-8", newline="\n").write(
    "#!/system/bin/sh\n"
    "MODDIR=${0%/*}\n"
    'chmod 644 "$MODDIR"/system/fonts/*.ttf 2>/dev/null\n'
    'chmod 644 "$MODDIR"/system/etc/fonts.xml 2>/dev/null\n')

out_zip = os.path.join(B, "work", "misans_font_v2.zip")
order = ["module.prop", "customize.sh", "post-fs-data.sh", "system/etc/fonts.xml"] \
        + ["system/fonts/" + fn for fn in used]
with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as z:
    for rel in order:
        z.write(os.path.join(STAGE, rel.replace("/", os.sep)), rel)
print("built", out_zip, "%.1f MB" % (os.path.getsize(out_zip) / 1048576))
