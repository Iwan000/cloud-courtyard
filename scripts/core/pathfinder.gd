class_name Pathfinder
extends RefCounted
## 点击移动用的寻路（BFS，只走空地，不推箱子）。


## 返回从玩家当前位置走到 goal 的方向序列；goal 不可达或就是当前位置时返回空数组。
static func find_path(state: SokobanState, goal: Vector2i) -> Array[int]:
	var result: Array[int] = []
	if goal == state.player or not state.is_walkable(goal):
		return result
	var came_from := {state.player: -1}
	var queue: Array[Vector2i] = [state.player]
	var head := 0
	while head < queue.size():
		var p: Vector2i = queue[head]
		head += 1
		if p == goal:
			break
		for dir in 4:
			var q: Vector2i = p + SokobanState.DIRS[dir]
			if not came_from.has(q) and state.is_walkable(q):
				came_from[q] = dir
				queue.append(q)
	if not came_from.has(goal):
		return result
	var p := goal
	while p != state.player:
		var dir: int = came_from[p]
		result.push_front(dir)
		p -= SokobanState.DIRS[dir]
	return result


## 玩家当前可以走到的所有格子（不推箱子）。
static func reachable(state: SokobanState) -> Dictionary:
	var seen := {state.player: true}
	var queue: Array[Vector2i] = [state.player]
	var head := 0
	while head < queue.size():
		var p: Vector2i = queue[head]
		head += 1
		for d in SokobanState.DIRS:
			var q: Vector2i = p + d
			if not seen.has(q) and state.is_walkable(q):
				seen[q] = true
				queue.append(q)
	return seen
