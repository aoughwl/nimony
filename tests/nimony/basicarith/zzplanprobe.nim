# temporary plan-vs-executed control; deleted immediately after
proc broken(x: int): int = x + "not an int"
echo broken(1)
