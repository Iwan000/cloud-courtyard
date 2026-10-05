class_name LevelData
extends RefCounted
## 关卡数据：网格、目标、箱子初始位置、玩家出生点，以及元信息。
##
## 纯数据，不包含任何运行时状态（运行时状态见 SokobanState）。
## 存储格式为 JSON，地图部分兼容推箱子社区标准 XSB 字符：
##   '#' 墙   '-'/'_' 地板   ' ' 虚空（或经典 XSB 中由玩家泛洪判定的地板）
##   '.' 目标  '$' 箱子  '*' 箱子在目标上  '@' 玩家  '+' 玩家在目标上

enum Cell { VOID = 0, FLOOR = 1, WALL = 2 }

const FORMAT_VERSION := 1
const MAX_SIZE := 16
const THEMES: PackedStringArray = ["dawn", "garden", "dusk", "lavender", "night"]

var id: String = ""
var name: String = "未命名"
var name_en: String = "Untitled"
var theme: String = "dawn"
## 程序化建筑的随机种子（JSON 字段名为 "seed"）
var decor_seed: int = 0
var par_moves: int = -1
var par_pushes: int = -1
var solution: String = ""

var width: int = 0
var height: int = 0
var cells: PackedByteArray = PackedByteArray()
var targets: PackedByteArray = PackedByteArray()
var boxes: Array[Vector2i] = []
var player: Vector2i = Vector2i(-1, -1)


static func create_empty(w: int, h: int) -> LevelData:
	var lvl := LevelData.new()
	lvl.width = w
	lvl.height = h
	lvl.cells.resize(w * h)
	lvl.cells.fill(Cell.VOID)
	lvl.targets.resize(w * h)
	lvl.targets.fill(0)
	return lvl


# ---------------------------------------------------------------------------
# 基础查询
# ---------------------------------------------------------------------------

func in_bounds(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < width and p.y < height


func index_of(p: Vector2i) -> int:
	return p.y * width + p.x


func get_cell(p: Vector2i) -> int:
	if not in_bounds(p):
		return Cell.VOID
	return cells[index_of(p)]


func set_cell(p: Vector2i, value: int) -> void:
	if in_bounds(p):
		cells[index_of(p)] = value


func is_floor(p: Vector2i) -> bool:
	return get_cell(p) == Cell.FLOOR


func is_wall(p: Vector2i) -> bool:
	return get_cell(p) == Cell.WALL


func is_target(p: Vector2i) -> bool:
	return in_bounds(p) and targets[index_of(p)] != 0


func set_target(p: Vector2i, on: bool) -> void:
	if in_bounds(p):
		targets[index_of(p)] = 1 if on else 0


func has_box(p: Vector2i) -> bool:
	return boxes.has(p)


func target_list() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for y in height:
		for x in width:
			if targets[y * width + x] != 0:
				result.append(Vector2i(x, y))
	return result


func target_count() -> int:
	var n := 0
	for t in targets:
		n += 1 if t != 0 else 0
	return n


func floor_count() -> int:
	var n := 0
	for c in cells:
		n += 1 if c == Cell.FLOOR else 0
	return n


func display_index() -> String:
	## 罗马数字章节号（内置关卡 id 为数字时）
	var n := id.to_int()
	if n <= 0:
		return ""
	const ROMAN := ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII"]
	return ROMAN[n] if n < ROMAN.size() else str(n)


func duplicate_level() -> LevelData:
	var lvl := LevelData.new()
	lvl.id = id
	lvl.name = name
	lvl.name_en = name_en
	lvl.theme = theme
	lvl.decor_seed = decor_seed
	lvl.par_moves = par_moves
	lvl.par_pushes = par_pushes
	lvl.solution = solution
	lvl.width = width
	lvl.height = height
	lvl.cells = cells.duplicate()
	lvl.targets = targets.duplicate()
	lvl.boxes = boxes.duplicate()
	lvl.player = player
	return lvl


## 地图内容（不含元信息）的指纹，用于判断关卡是否被修改过、par 是否仍然有效。
func content_hash() -> int:
	return "\n".join(to_rows()).hash()


# ---------------------------------------------------------------------------
# 编辑操作
# ---------------------------------------------------------------------------

## 改变地图尺寸。offset 为旧内容在新地图中的偏移。
func resized(new_w: int, new_h: int, offset: Vector2i = Vector2i.ZERO) -> LevelData:
	var lvl := LevelData.create_empty(new_w, new_h)
	lvl.id = id
	lvl.name = name
	lvl.name_en = name_en
	lvl.theme = theme
	lvl.decor_seed = decor_seed
	for y in height:
		for x in width:
			var np := Vector2i(x, y) + offset
			if lvl.in_bounds(np):
				lvl.set_cell(np, get_cell(Vector2i(x, y)))
				lvl.set_target(np, is_target(Vector2i(x, y)))
	for b in boxes:
		if lvl.in_bounds(b + offset):
			lvl.boxes.append(b + offset)
	if in_bounds(player) and lvl.in_bounds(player + offset):
		lvl.player = player + offset
	return lvl


## 裁掉四周全是虚空的行列。
func trimmed() -> LevelData:
	var min_p := Vector2i(width, height)
	var max_p := Vector2i(-1, -1)
	for y in height:
		for x in width:
			if cells[y * width + x] != Cell.VOID:
				min_p = Vector2i(mini(min_p.x, x), mini(min_p.y, y))
				max_p = Vector2i(maxi(max_p.x, x), maxi(max_p.y, y))
	if max_p.x < 0:
		return duplicate_level()
	var w := max_p.x - min_p.x + 1
	var h := max_p.y - min_p.y + 1
	var lvl := resized(w, h, -min_p)
	lvl.par_moves = par_moves
	lvl.par_pushes = par_pushes
	lvl.solution = solution
	return lvl


# ---------------------------------------------------------------------------
# 序列化：XSB 行
# ---------------------------------------------------------------------------

## 输出地图行。explicit_floor=true 时地板写作 '-'、虚空写作空格（本项目存档格式）；
## false 时输出标准 XSB（地板与虚空都写作空格）。
func to_rows(explicit_floor: bool = true) -> PackedStringArray:
	var rows := PackedStringArray()
	for y in height:
		var line := ""
		for x in width:
			var p := Vector2i(x, y)
			var c := get_cell(p)
			var t := is_target(p)
			var ch := " "
			if c == Cell.WALL:
				ch = "#"
			elif c == Cell.FLOOR:
				if p == player:
					ch = "+" if t else "@"
				elif has_box(p):
					ch = "*" if t else "$"
				else:
					ch = "." if t else ("-" if explicit_floor else " ")
			line += ch
		rows.append(line.rstrip(" "))
	# 去掉末尾空行
	while rows.size() > 0 and rows[rows.size() - 1] == "":
		rows.remove_at(rows.size() - 1)
	return rows


func to_xsb() -> String:
	return "\n".join(to_rows(false))


## 从地图行解析。空格按经典 XSB 规则：从玩家泛洪可达则为地板，否则为虚空。
static func from_rows(rows: PackedStringArray) -> LevelData:
	# 去掉首尾空行
	var lines: Array[String] = []
	for r in rows:
		lines.append(r.replace("\t", "    ").rstrip(" \r"))
	while lines.size() > 0 and lines[0].strip_edges() == "":
		lines.pop_front()
	while lines.size() > 0 and lines[lines.size() - 1].strip_edges() == "":
		lines.pop_back()
	var h := lines.size()
	var w := 0
	for l in lines:
		w = maxi(w, l.length())
	var lvl := LevelData.create_empty(w, h)
	var unknown := PackedByteArray()
	unknown.resize(w * h)
	unknown.fill(0)
	for y in h:
		var line: String = lines[y]
		for x in line.length():
			var p := Vector2i(x, y)
			var ch := line[x]
			match ch:
				"#":
					lvl.set_cell(p, Cell.WALL)
				"-", "_":
					lvl.set_cell(p, Cell.FLOOR)
				".":
					lvl.set_cell(p, Cell.FLOOR)
					lvl.set_target(p, true)
				"$":
					lvl.set_cell(p, Cell.FLOOR)
					lvl.boxes.append(p)
				"*":
					lvl.set_cell(p, Cell.FLOOR)
					lvl.set_target(p, true)
					lvl.boxes.append(p)
				"@":
					lvl.set_cell(p, Cell.FLOOR)
					lvl.player = p
				"+":
					lvl.set_cell(p, Cell.FLOOR)
					lvl.set_target(p, true)
					lvl.player = p
				" ":
					unknown[y * w + x] = 1
				_:
					pass
	# 行尾以外的格子同样视为未知
	for y in h:
		for x in range(lines[y].length(), w):
			unknown[y * w + x] = 1
	# 泛洪：从玩家出发，穿过非墙格子，到达的未知格判为地板
	if lvl.in_bounds(lvl.player):
		var seen := PackedByteArray()
		seen.resize(w * h)
		seen.fill(0)
		var queue: Array[Vector2i] = [lvl.player]
		seen[lvl.index_of(lvl.player)] = 1
		while not queue.is_empty():
			var p: Vector2i = queue.pop_back()
			if unknown[lvl.index_of(p)] != 0:
				lvl.set_cell(p, Cell.FLOOR)
			for d in SokobanState.DIRS:
				var q: Vector2i = p + d
				if not lvl.in_bounds(q):
					continue
				var qi := lvl.index_of(q)
				if seen[qi] != 0 or lvl.cells[qi] == Cell.WALL:
					continue
				if lvl.cells[qi] == Cell.VOID and unknown[qi] == 0:
					continue
				seen[qi] = 1
				queue.append(q)
	return lvl


static func from_xsb(text: String) -> LevelData:
	var rows := PackedStringArray()
	for line in text.replace("\r\n", "\n").split("\n"):
		# 忽略常见的注释/标题行（XSB 文件中以 ';' 开头）
		if line.begins_with(";"):
			continue
		rows.append(line)
	var lvl := from_rows(rows)
	lvl.name = "导入关卡"
	lvl.name_en = "Imported"
	return lvl.trimmed()


# ---------------------------------------------------------------------------
# 序列化：JSON
# ---------------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"format": FORMAT_VERSION,
		"id": id,
		"name": name,
		"name_en": name_en,
		"theme": theme,
		"seed": decor_seed,
		"par_moves": par_moves,
		"par_pushes": par_pushes,
		"solution": solution,
		"map": Array(to_rows(true)),
	}


static func from_dict(d: Dictionary) -> LevelData:
	var rows := PackedStringArray()
	for r in d.get("map", []):
		rows.append(str(r))
	var lvl := from_rows(rows)
	lvl.id = str(d.get("id", ""))
	lvl.name = str(d.get("name", "未命名"))
	lvl.name_en = str(d.get("name_en", ""))
	var th := str(d.get("theme", "dawn"))
	lvl.theme = th if THEMES.has(th) else "dawn"
	lvl.decor_seed = int(d.get("seed", 0))
	lvl.par_moves = int(d.get("par_moves", -1))
	lvl.par_pushes = int(d.get("par_pushes", -1))
	lvl.solution = str(d.get("solution", ""))
	return lvl


func to_json_string() -> String:
	# 手写 JSON 以保证地图每行一行，便于 diff 和人工阅读
	var d := to_dict()
	var out := "{\n"
	for key in ["format", "id", "name", "name_en", "theme", "seed", "par_moves", "par_pushes", "solution"]:
		out += "  %s: %s,\n" % [JSON.stringify(key), JSON.stringify(d[key])]
	out += "  \"map\": [\n"
	var rows: Array = d["map"]
	for i in rows.size():
		out += "    " + JSON.stringify(rows[i]) + ("," if i < rows.size() - 1 else "") + "\n"
	out += "  ]\n}\n"
	return out


static func load_file(path: String) -> LevelData:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("无法读取关卡文件: %s" % path)
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("关卡文件格式错误: %s" % path)
		return null
	return from_dict(parsed)


func save_file(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(to_json_string())
	return OK


# ---------------------------------------------------------------------------
# 校验（编辑器与加载时使用）
# ---------------------------------------------------------------------------

## 返回 { "errors": [String], "warnings": [String] }。errors 为空才可游玩。
func validate() -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	if not in_bounds(player) or not is_floor(player):
		errors.append("需要放置一名旅人（玩家）")
	var box_count := boxes.size()
	var tgt_count := target_count()
	if box_count == 0:
		errors.append("至少需要一个箱子")
	if box_count != tgt_count:
		errors.append("箱子数（%d）与目标数（%d）不一致" % [box_count, tgt_count])
	for b in boxes:
		if not is_floor(b):
			errors.append("有箱子没有放在地板上")
			break
	for t in target_list():
		if not is_floor(t):
			errors.append("有目标没有放在地板上")
			break
	if not errors.is_empty():
		return {"errors": errors, "warnings": warnings}

	# 可达性：忽略箱子阻挡，玩家所在连通区域必须包含所有箱子与目标
	var region := _reachable_region(player)
	for b in boxes:
		if not region.has(b):
			errors.append("有箱子位于旅人无法到达的区域")
			break
	for t in target_list():
		if not region.has(t):
			errors.append("有目标位于旅人无法到达的区域")
			break
	# 封闭性：可达区域旁边是虚空时给出提示（规则上虚空等同于墙）
	for p in region:
		var open_edge := false
		for d in SokobanState.DIRS:
			if get_cell(p + d) == Cell.VOID:
				open_edge = true
				break
		if open_edge:
			warnings.append("地图边缘未被墙封闭（平台边缘视为不可通行）")
			break
	# 初始死角：不在目标上的箱子卡在两面墙的夹角
	for b in boxes:
		if is_target(b):
			continue
		var corner := false
		for i in 4:
			var a: Vector2i = SokobanState.DIRS[i]
			var c: Vector2i = SokobanState.DIRS[(i + 1) % 4]
			if not is_floor(b + a) and not is_floor(b + c):
				corner = true
				break
		if corner:
			errors.append("有箱子一开始就卡在死角，无法推动")
			break
	var solved := box_count > 0
	for b in boxes:
		if not is_target(b):
			solved = false
	if solved:
		errors.append("所有箱子一开始就在目标上")
	return {"errors": errors, "warnings": warnings}


func _reachable_region(from: Vector2i) -> Dictionary:
	var region := {}
	if not is_floor(from):
		return region
	var queue: Array[Vector2i] = [from]
	region[from] = true
	while not queue.is_empty():
		var p: Vector2i = queue.pop_back()
		for d in SokobanState.DIRS:
			var q: Vector2i = p + d
			if is_floor(q) and not region.has(q):
				region[q] = true
				queue.append(q)
	return region
