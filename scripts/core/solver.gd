class_name SokobanSolver
extends RefCounted
## 推箱子求解器。
##
## 算法：以"推一次箱子"为扩展单位的 A*，代价 = 行走步数 + 推动次数，因此结果为步数最优。
##   - 状态：箱子位置集合 + 推箱后玩家所在格（推完后玩家位置是确定的）。
##   - 扩展：从当前状态 BFS 求玩家到各推箱位的步数，作为本次推箱的行走代价。
##   - 启发：每个箱子到最近目标的"推动距离"之和（可采纳且一致，首次出队的终局即最优）。
##   - 剪枝：死格（任何目标都拉不回来的格子）+ 2×2 冻结死锁。
## 可在后台线程中运行，通过 cancelled 标志中断。

enum Status { SOLVED, UNSOLVABLE, LIMIT, CANCELLED, INVALID }

const STATUS_TEXT := {
	Status.SOLVED: "可解",
	Status.UNSOLVABLE: "无解",
	Status.LIMIT: "超出搜索上限",
	Status.CANCELLED: "已取消",
	Status.INVALID: "关卡无效",
}

var max_states := 400000
var max_msec := 20000
## 由其它线程置为 true 可中断搜索
var cancelled := false

# ---- 结果 ----
var status: int = Status.INVALID
var solution := ""        ## LURD 记谱
var moves := 0
var pushes := 0
var expanded := 0
var elapsed_msec := 0

# ---- 内部数据（带 1 格外边框的展开网格，避免越界判断） ----
var _w := 0
var _h := 0
var _floor := PackedByteArray()
var _target := PackedByteArray()
var _htab := PackedInt32Array()       # 到最近目标的推动距离，-1 = 死格
var _offs := PackedInt32Array()       # 四个方向的下标偏移
var _floor_id := PackedInt32Array()   # 格子 → 紧凑地板编号（用于状态键）
var _key_base := 1
var _int_keys := true

# BFS 复用缓冲
var _occ := PackedByteArray()
var _stamp := PackedInt32Array()
var _dist := PackedInt32Array()
var _queue := PackedInt32Array()
var _cur_stamp := 0


## 从关卡初始局面求解。
func solve(level: LevelData) -> int:
	return solve_from(level, level.boxes, level.player)


## 从任意局面求解（用于游戏内提示）。
func solve_from(level: LevelData, boxes: Array[Vector2i], player: Vector2i) -> int:
	var t0 := Time.get_ticks_msec()
	status = Status.INVALID
	solution = ""
	moves = 0
	pushes = 0
	expanded = 0
	if boxes.is_empty() or boxes.size() != level.target_count() or not level.is_floor(player):
		return status
	_prepare(level)
	var start_boxes := PackedInt32Array()
	for b in boxes:
		start_boxes.append(_ci(b))
	start_boxes.sort()
	status = _search(start_boxes, _ci(player), t0)
	elapsed_msec = Time.get_ticks_msec() - t0
	return status


func status_text() -> String:
	return STATUS_TEXT.get(status, "")


# ---------------------------------------------------------------------------
# 预处理
# ---------------------------------------------------------------------------

func _ci(p: Vector2i) -> int:
	return (p.y + 1) * _w + (p.x + 1)


func _cv(i: int) -> Vector2i:
	return Vector2i(i % _w - 1, i / _w - 1)


func _prepare(level: LevelData) -> void:
	_w = level.width + 2
	_h = level.height + 2
	var n := _w * _h
	_floor.resize(n)
	_floor.fill(0)
	_target.resize(n)
	_target.fill(0)
	for y in level.height:
		for x in level.width:
			var p := Vector2i(x, y)
			if level.is_floor(p):
				_floor[_ci(p)] = 1
			if level.is_target(p):
				_target[_ci(p)] = 1
	_offs = PackedInt32Array([-_w, 1, _w, -1])

	# 紧凑编号与状态键编码方式
	_floor_id.resize(n)
	_floor_id.fill(-1)
	var fcount := 0
	for i in n:
		if _floor[i] != 0:
			_floor_id[i] = fcount
			fcount += 1
	_key_base = maxi(fcount, 2)
	var bits := 1
	while (1 << bits) < _key_base:
		bits += 1
	_int_keys = (level.target_count() + 1) * bits <= 62

	# 反向"拉箱"BFS：求每格到最近目标的推动距离，拉不到的就是死格
	_htab.resize(n)
	_htab.fill(-1)
	var queue := PackedInt32Array()
	for i in n:
		if _target[i] != 0:
			_htab[i] = 0
			queue.append(i)
	var head := 0
	while head < queue.size():
		var b := queue[head]
		head += 1
		for d in 4:
			var prev := b - _offs[d]          # 箱子原来的位置
			var stand := b - 2 * _offs[d]     # 推之前玩家站的位置
			if _floor[prev] != 0 and _floor[stand] != 0 and _htab[prev] < 0:
				_htab[prev] = _htab[b] + 1
				queue.append(prev)

	_occ.resize(n)
	_occ.fill(0)
	_stamp.resize(n)
	_stamp.fill(0)
	_dist.resize(n)
	_queue.resize(n)
	_cur_stamp = 0


# ---------------------------------------------------------------------------
# A* 搜索
# ---------------------------------------------------------------------------

func _key(boxes: PackedInt32Array, player: int) -> Variant:
	if _int_keys:
		var k := _floor_id[player]
		for b in boxes:
			k = k * _key_base + _floor_id[b]
		return k
	return "%d|%s" % [player, boxes]


func _heuristic(boxes: PackedInt32Array) -> int:
	var h := 0
	for b in boxes:
		var d := _htab[b]
		if d < 0:
			return -1
		h += d
	return h


func _search(start_boxes: PackedInt32Array, start_player: int, t0: int) -> int:
	var h0 := _heuristic(start_boxes)
	if h0 < 0:
		return Status.UNSOLVABLE
	# 节点表
	var n_boxes: Array[PackedInt32Array] = [start_boxes]
	var n_player := PackedInt32Array([start_player])
	var n_g := PackedInt32Array([0])
	var n_h := PackedInt32Array([h0])
	var n_parent := PackedInt32Array([-1])
	var n_push := PackedInt32Array([-1])   # 推之前箱子所在格 * 4 + 方向
	var best := {_key(start_boxes, start_player): 0}
	# 二叉堆，元素为打包后的优先级：f(高位) | 反向 g（同 f 时优先更深的节点）| 节点下标
	var heap := PackedInt64Array([_pack(h0, 0, 0)])

	while not heap.is_empty():
		if cancelled:
			return Status.CANCELLED
		var top := _heap_pop(heap)
		var node := int(top & 0xFFFFFF)
		var g := n_g[node]
		var boxes: PackedInt32Array = n_boxes[node]
		var player := n_player[node]
		if best.get(_key(boxes, player), -1) < g:
			continue  # 过期节点
		if n_h[node] == 0:
			_reconstruct(node, n_parent, n_push, n_boxes[0], n_player[0])
			return Status.SOLVED
		expanded += 1
		if expanded % 2000 == 0 and Time.get_ticks_msec() - t0 > max_msec:
			return Status.LIMIT
		if n_boxes.size() > max_states:
			return Status.LIMIT

		for b in boxes:
			_occ[b] = 1
		_bfs(player)
		var h := n_h[node]
		for i in boxes.size():
			var b := boxes[i]
			for d in 4:
				var off := _offs[d]
				var stand := b - off
				if _stamp[stand] != _cur_stamp:
					continue
				var dest := b + off
				if _floor[dest] == 0 or _occ[dest] != 0 or _htab[dest] < 0:
					continue
				if _is_frozen(dest, b):
					continue
				var nb := boxes.duplicate()
				nb[i] = dest
				nb.sort()
				var ng := g + _dist[stand] + 1
				var key: Variant = _key(nb, b)
				if best.get(key, 0x7FFFFFFF) <= ng:
					continue
				best[key] = ng
				var nh := h - _htab[b] + _htab[dest]
				var idx := n_boxes.size()
				n_boxes.append(nb)
				n_player.append(b)
				n_g.append(ng)
				n_h.append(nh)
				n_parent.append(node)
				n_push.append(b * 4 + d)
				_heap_push(heap, _pack(ng + nh, ng, idx))
		for b in boxes:
			_occ[b] = 0
	return Status.UNSOLVABLE


func _pack(f: int, g: int, node: int) -> int:
	return (f << 44) | ((0xFFFFF - mini(g, 0xFFFFF)) << 24) | node


func _bfs(from: int) -> void:
	_cur_stamp += 1
	var head := 0
	var tail := 0
	_queue[tail] = from
	tail += 1
	_stamp[from] = _cur_stamp
	_dist[from] = 0
	while head < tail:
		var p := _queue[head]
		head += 1
		var nd := _dist[p] + 1
		for d in 4:
			var q := p + _offs[d]
			if _floor[q] != 0 and _occ[q] == 0 and _stamp[q] != _cur_stamp:
				_stamp[q] = _cur_stamp
				_dist[q] = nd
				_queue[tail] = q
				tail += 1


## 箱子从 old_pos 推到 pos 后，检查 pos 所在的四个 2×2 方块是否形成冻结死锁。
func _is_frozen(pos: int, old_pos: int) -> bool:
	_occ[old_pos] = 0
	_occ[pos] = 1
	var frozen := false
	for corner in [0, -1, -_w, -_w - 1]:
		var a: int = pos + corner
		var cells := [a, a + 1, a + _w, a + _w + 1]
		var all_blocked := true
		var has_open_box := false
		for c in cells:
			if _floor[c] == 0:
				continue
			if _occ[c] == 0:
				all_blocked = false
				break
			if _target[c] == 0:
				has_open_box = true
		if all_blocked and has_open_box:
			frozen = true
			break
	_occ[pos] = 0
	_occ[old_pos] = 1
	return frozen


func _reconstruct(node: int, parents: PackedInt32Array, push_info: PackedInt32Array,
		start_boxes: PackedInt32Array, start_player: int) -> void:
	var chain: Array[int] = []
	var n := node
	while parents[n] >= 0:
		chain.push_front(push_info[n])
		n = parents[n]
	# 正向重放，补出每次推箱之间的行走路径
	for b in start_boxes:
		_occ[b] = 1
	var player := start_player
	var lurd := ""
	for info in chain:
		var box := info / 4
		var d := info % 4
		var stand := box - _offs[d]
		lurd += _walk_path(player, stand)
		lurd += SokobanState.DIR_CHARS[d].to_upper()
		_occ[box] = 0
		_occ[box + _offs[d]] = 1
		player = box
	for i in _occ.size():
		_occ[i] = 0
	solution = lurd
	moves = lurd.length()
	pushes = chain.size()


func _walk_path(from: int, to: int) -> String:
	if from == to:
		return ""
	_bfs(from)
	var path := ""
	var p := to
	while p != from:
		for d in 4:
			var q := p - _offs[d]
			if _stamp[q] == _cur_stamp and _dist[q] == _dist[p] - 1:
				path = SokobanState.DIR_CHARS[d] + path
				p = q
				break
	return path


# ---------------------------------------------------------------------------
# 二叉堆（最小堆）
# ---------------------------------------------------------------------------

static func _heap_push(heap: PackedInt64Array, v: int) -> void:
	heap.append(v)
	var i := heap.size() - 1
	while i > 0:
		var parent := (i - 1) >> 1
		if heap[parent] <= v:
			break
		heap[i] = heap[parent]
		i = parent
	heap[i] = v


static func _heap_pop(heap: PackedInt64Array) -> int:
	var top := heap[0]
	var last := heap[heap.size() - 1]
	heap.resize(heap.size() - 1)
	var n := heap.size()
	if n == 0:
		return top
	var i := 0
	while true:
		var l := i * 2 + 1
		if l >= n:
			break
		var r := l + 1
		var c := l
		if r < n and heap[r] < heap[l]:
			c = r
		if heap[c] >= last:
			break
		heap[i] = heap[c]
		i = c
	heap[i] = last
	return top
