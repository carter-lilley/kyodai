class_name OverlayLayers
extends RefCounted

## Central registry of the canvas-layer stack. Higher layers render above
## lower ones. M3 addon components (M3Sheet, M3Dialog, M3Menu, M3Tooltip,
## M3Snackbar) carry their own defaults; these constants document the intended
## stack and are used wherever app code assigns or overrides a layer.
##
## Structural layers are reparented by DualScreenSubManager on DS mode shifts:
## UILayer (with its transition overlays) follows the main viewport, the
## on-screen keyboard moves to the second viewport. M3 overlays attach to
## whichever node is in the "m3_overlay_parent" group (see M3Overlay).

# CanvasLayer.layer stack
const SHEET := 85
const SEARCH := 85
const DIALOG := 90
const MENU := 95
const TOOLTIP := 110
const UI_LAYER := 1000
const SNACKBAR := 1100
## Above UILayer so critical dialogs stay visible and clickable over the
## launch transition overlay.
const LAUNCH_CRITICAL := 1101

# z_index within UILayer (layer 1000)
const VIEW_TRANSITION_Z := 900
const LAUNCH_TITLE_Z := 1001
const KEYBOARD_Z := 4096

# z_index within the root layout
const TOOLBAR_Z := 10
