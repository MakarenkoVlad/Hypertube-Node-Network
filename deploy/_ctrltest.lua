return {
  stations = { {id="x",name="X"}, {id="y",name="Y"} },
  nodes = { x={monitor="right"}, y={monitor="right"} },
  links = {
    { a="x", b="y",
      a_controller="Create_RotationSpeedController_0", a_rpm=48,
      b_controller="Create_RotationSpeedController_0", b_rpm=48 },
  },
}
