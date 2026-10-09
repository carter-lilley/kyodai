class_name GridScrollAnchor
extends RefCounted

## Three-slot scroll anchor: (index, sub-line fraction, viewport edge).
## Captured BEFORE a geometry change (zoom / resize / content-count change),
## restored after the recalc, so the scroll survives in content space instead
## of re-interpreting the old pixel offset against the new stride (which
## teleports the buffer window and forces a full card rebuild).
##
## edge = FAR means the view was pinned to the content end at capture (scroll
## at max). The restore honors the pin only for inline captures (resize,
## library shrink) — zoom-path captures pass allow_end_pin=false because the
## focused card is the better zoom anchor.

enum Edge { NEAR, FAR }

var index: int = -1        ## anchor virtual index (-1 = unset)
var frac: float = 0.0      ## intra-line fraction of the scroll past the slot start
var edge: int = Edge.NEAR  ## FAR = pin the restore to the content end

func valid() -> bool:
	return index >= 0
