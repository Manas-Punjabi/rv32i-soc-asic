# KLayout batch script: render the routed GDS to PNG with a chip-scale layer set.
#   klayout -z -r scripts/render_layout.py -rd gds=<file> -rd out=<png>
import pya
gds, out = globals()["gds"], globals()["out"]
lv = pya.LayoutView()
lv.load_layout(gds, True)
lv.clear_layers()
lv.set_config("background-color", "#ffffff")
lv.set_config("grid-visible", "false")
# (layer, datatype, name, color, dither) -- drawn in this order, later on top
layers = [
    (64, 20, "nwell", "#e8e8e8", 0),   # solid light grey: shows the placement rows / core
    (67, 20, "li1",   "#b0b0b0", 5),
    (68, 20, "met1",  "#3a7bd5", 7),
    (69, 20, "met2",  "#d5443a", 6),
    (70, 20, "met3",  "#2e9e5b", 5),
    (71, 20, "met4",  "#d98c1f", 3),
    (72, 20, "met5",  "#7b3fb0", 1),
]
for l, d, name, col, dither in layers:
    lp = pya.LayerPropertiesNode()
    lp.source = f"{l}/{d}@1"
    lp.name = name
    lp.fill_color = int(col[1:], 16)
    lp.frame_color = int(col[1:], 16)
    lp.dither_pattern = dither
    lp.width = 1
    lv.insert_layer(lv.end_layers(), lp)
lv.max_hier_levels = 20
lv.zoom_fit()
lv.save_image(out, 2000, 2000)
print("wrote", out)
