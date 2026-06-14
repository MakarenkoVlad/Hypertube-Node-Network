return {
  stations = { {id="x",name="X"}, {id="y",name="Y"}, {id="z",name="Z"} },
  nodes = { x={monitor="right"}, y={monitor="right"}, z={monitor="right"} },
  links = {
    { a="x", b="y", a_relay="redstone_relay_0", a_side="back", b_relay="redstone_relay_0", b_side="back" },
    { a="y", b="z", a_relay="redstone_relay_1", a_side="back", b_relay="redstone_relay_0", b_side="back" },
  },
}
