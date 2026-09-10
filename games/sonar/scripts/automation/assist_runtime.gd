class_name AssistRuntime
extends RefCounted
## assist_runtime.gd — S1-11 §3.1/§3.2 ASSIST 值班链运行器（D-11 / AT-56）。
##
## 每个自动化 tick：
##   1) 消费世界新增的 detected 被动测量 → AssistChain 自动 Mark + 跨帧关联；
##   2) 刷新受影响 Track 的概率分类（TrackClassification）；
##   3) 输出需要自动 Fit 的 track_id（按 evidence_revision 变化，绝不重抽样）。
##
## 纪律：
##   - MANUAL 模式不自动 Mark（仍然只推游标，不丢测量）；
##   - 自动化只产出"需要 Fit"的请求，绝不自动提交 System Solution、
##     不自动释放武器（发射仍由玩家/场景 ROE 决定）；
##   - 主动回波由 ActivePingController 批次结算，本类只消费 PASSIVE_BEARING，
##     避免同一测量被双喂（双 Track / 重复关联）。

const MIN_EVIDENCE_FOR_FIT := 4
const PASSIVE_TYPE := "PASSIVE_BEARING"

var chain: AssistChain = null

var _consumed: int = 0  # world.measurements 已消费下标
var _fitted_revision: Dictionary = {}  # track_id -> 已拟合 revision


func _init(tr: Tracker = null) -> void:
	chain = AssistChain.new(tr)


func reset() -> void:
	_consumed = 0
	_fitted_revision.clear()
	if chain != null:
		chain.reset()


## 消费新增被动测量。ASSIST/FULL_AUTO 自动 Mark；MANUAL 只推游标。
## 返回本 tick 自动 Mark 动作数（新建 + 追加）。
func consume_passive(measurements: Array, mode: int, now: float) -> int:
	if chain == null:
		return 0
	var batch: Array = []
	while _consumed < measurements.size():
		var mv: Variant = measurements[_consumed]
		_consumed += 1
		if mv is Measurement:
			var m: Measurement = mv
			if m.detected and str(m.measurement_type) == PASSIVE_TYPE:
				batch.append(m)
	if batch.is_empty() or mode == AutomationController.Mode.MANUAL:
		return 0
	var r: Dictionary = chain.ingest_measurements(batch, now)
	return int(r.get("created", 0)) + int(r.get("appended", 0))


## 刷新概率分类（只写 Track.classification_assessment，不改证据/不改选中）。
func classify_tracks(tracks: Array, now: float) -> void:
	for t in tracks:
		if t is Track:
			t.set_classification(TrackClassification.assess(t, now))


## 自动 Fit 请求：证据数达标且 evidence_revision 相比上次拟合已变化。
## 不重抽样、不重算缓存；调用方执行拟合后应调用 mark_fitted()。
func refit_requests(tracks: Array) -> Array:
	var out: Array = []
	for t in tracks:
		if not (t is Track):
			continue
		var tr: Track = t
		if tr.state != Track.TrackState.ACTIVE:
			continue
		if tr.evidence_count() < MIN_EVIDENCE_FOR_FIT:
			continue
		if int(_fitted_revision.get(tr.track_id, -1)) != tr.evidence_revision:
			out.append(tr.track_id)
	return out


## 拟合完成后登记当前 revision，避免同一证据重复请求。
func mark_fitted(track: Track) -> void:
	if track != null:
		_fitted_revision[track.track_id] = track.evidence_revision


func fitted_revision(track_id: String) -> int:
	return int(_fitted_revision.get(track_id, -1))
